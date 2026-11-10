// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/demux.c (read_frame_internal, parse_packet, compute_pkt_fields,
// update_initial_timestamps, update_initial_durations, select_from_pts_buffer,
// update_dts_from_pts, av_read_frame, avformat_find_stream_info's read-ahead,
// has_codec_parameters), libavformat/seek.c (av_seek_frame,
// avformat_seek_file, seek_frame_generic, ff_seek_frame_binary,
// ff_read_frame_flush, request_seek_discard) and libavcodec/flac_parser.c's
// complete-frames path at the pinned reference revision describe the
// behavior, restated here.
//! libavformat's generic layer over a demuxer (TODO.md T27a): what
//! `av_read_frame` does to the packets a demuxer gives before the caller
//! sees them, for streams of audio without frame reordering, which is
//! every stream the port reads.
//!
//! The demuxer gives packets with its own timestamps (or none); this
//! layer fills in the missing ones from the running timestamp, keeps them
//! relative (from `relative_ts_base`) until the first real one fixes the
//! start, then shifts the packets still held. `avformat_find_stream_info`
//! reads ahead and holds packets until every stream has its codec
//! parameters and a first timestamp, or 5 seconds of packets, 5 MB, or the
//! end; the held packets are returned first. FLAC streams in a container
//! (`AVSTREAM_PARSE_HEADERS`) pass through FFmpeg's FLAC parser in its
//! complete-frames mode, which only reads each frame's header for its
//! duration.
//!
//! `Source` is the demuxer: `next() !?SourcePacket`, `streamCount()`,
//! `setup(i) Setup`, `startTime(i) *i64` and `durationOf(i) *i64` (the
//! stream's start time and duration, which the demuxer and this layer
//! both set, as both set FFmpeg's `AVStream`), `fileSize() ?u64` and
//! `dataOffset() i64`.
//!
//! Seeking is libavformat's too: `seekFrame` (`av_seek_frame`) and
//! `seekFile` (`avformat_seek_file`, with its pre-roll target and the
//! skip samples it asks the next packets for) over the index of returned
//! keyframes (AVFMT_GENERIC_INDEX). For them the source also has
//! `reposition(pos)`, `ioRepositioned()` (it resets on its next read),
//! `readTimestamp(i, *pos, pos_limit) !i64` for the binary search, and
//! `readSeek(layer, i, ts, flags) !bool`, its own `read_seek`.

const std = @import("std");
const flac = @import("../codec/flac.zig");
const bits = @import("../codec/bits.zig");
const rational = @import("../core/rational.zig");
const seek = @import("seek.zig");
const mpegaudio = @import("../codec/mpegaudio.zig");
const adts = @import("../codec/adts.zig");
const ac3 = @import("../codec/ac3.zig");
const ac3dec = @import("../codec/ac3dec.zig");
const id3v2 = @import("id3v2.zig");
const aacdec = @import("../codec/aacdec.zig");
const mp3dec = @import("../codec/mp3dec.zig");

pub const nopts: i64 = std.math.minInt(i64);
/// libavformat's base for timestamps counted before the first is known.
pub const relative_ts_base: i64 = std.math.maxInt(i64) - (1 << 48);

fn isRelative(ts: i64) bool {
    return ts > relative_ts_base - (1 << 48);
}

/// avformat_find_stream_info's defaults.
const probesize = 5_000_000;
const max_analyze_duration = 5 * 1_000_000;
/// `max_subtitle_analyze_duration`'s default, a subtitle stream's limit.
const max_subtitle_analyze_duration = 30 * 1_000_000;
const max_ts_probe = 50;

/// What the layer needs to know of a stream.
pub const Setup = struct {
    /// False for a stream whose codec is unknown (`AV_CODEC_ID_NONE`).
    known: bool,
    /// The stream's media type: audio, data (a data stream needs no codec
    /// parameters, its packets are keyframes, and its timings count as a
    /// text stream's) or subtitle (as data, but its packets keep their
    /// flags and its read-ahead has the subtitle limit).
    media: Media = .audio,
    /// The codec's descriptor has `AV_CODEC_PROP_INTRA_ONLY`: every packet
    /// is a keyframe.
    intra_only: bool = true,
    time_base: rational.Rational,
    sample_rate: u32,
    channels: u8,
    /// The parser libavformat puts before the stream (`need_parsing`).
    parser: ParserKind = .none,
    /// A codec whose frame size libavformat could determine
    /// (`determinable_frame_size`) with no decoder to give it: the
    /// parameters never complete, so the read-ahead runs to its end.
    frame_size_unknown: bool = false,
    /// The gapless counts in samples: `start_skip_samples`, skipped from
    /// the packet at timestamp 0, and the discard window
    /// `first_discard_sample` to `last_discard_sample` (none when 0).
    start_skip_samples: i64 = 0,
    /// The demuxer's `skip_samples` at the start (mov's initial padding of
    /// AAC): the first packet's skip-samples side data, and the start
    /// time, which libavformat moves past them.
    skip_samples: i64 = 0,
    first_discard_sample: i64 = 0,
    last_discard_sample: i64 = 0,
    /// What the reference build's decoder does when
    /// avformat_find_stream_info opens it.
    decoder: Decoder = .none,
    /// `codecpar->bit_rate`, 0 when unknown.
    bit_rate: i64 = 0,
    /// `codecpar->initial_padding` and `seek_preroll`, in samples.
    initial_padding: u32 = 0,
    seek_preroll: u32 = 0,
    /// `codecpar->frame_size`, which bounds the discard window's packet
    /// duration from below.
    frame_size: u32 = 0,
    /// `codecpar->extradata`, which the AAC decoder opens with.
    extradata: []const u8 = &.{},
    /// The MPEG audio codec the stream starts as, which the parser may
    /// change (MP3 when null).
    mpa_codec: ?mpegaudio.Codec = null,
};

pub const Media = enum {
    audio,
    data,
    subtitle,

    /// A text stream's timings (update_stream_timings' `is_text`).
    fn isText(m: Media) bool {
        return m != .audio;
    }
};

/// A stream's parser, as its demuxer asks for one.
pub const ParserKind = enum {
    none,
    /// FLAC in a container: FFmpeg's FLAC parser reads each packet's
    /// frame header (AVSTREAM_PARSE_HEADERS).
    flac_headers,
    /// MPEG audio read raw: FFmpeg's mpegaudio parser splits the bytes into
    /// frames and fills the codec parameters (AVSTREAM_PARSE_FULL_RAW).
    mpegaudio,
    /// ADTS read raw: FFmpeg's AAC parser splits the bytes into frames,
    /// marks keyframes and fills the profile and bit rate
    /// (AVSTREAM_PARSE_FULL_RAW).
    aac,
    /// AC-3 read raw (T32a): FFmpeg's AC-3 parser splits the bytes into
    /// frames and fills the rate, channels, layout, frame durations and
    /// bit rate (AVSTREAM_PARSE_FULL_RAW).
    ac3,
    /// AC-3 and E-AC-3 in MP4 (T33a1): the same parser on packets with
    /// timestamps, which it passes to its frames (AVSTREAM_PARSE_FULL).
    ac3_full,
    /// MPEG audio in QuickTime files (T33a1), AVSTREAM_PARSE_FULL.
    mpegaudio_full,

    fn full(k: ParserKind) bool {
        return k == .ac3_full or k == .mpegaudio_full;
    }
};

/// The reference build's decoder for a stream, as try_decode_frame meets it.
pub const Decoder = enum {
    /// None: a known rate and channel count are the parameters needed.
    none,
    /// FLAC's: the sample format is known once a frame decodes.
    flac,
    /// Sets the sample format when it opens (Vorbis).
    format_at_open,
    /// Refuses the stream's headers: avcodec_open2 fails and leaves the
    /// context without a channel count, so the parameters never complete
    /// and the read-ahead runs to its end.
    refuses,
    /// FFmpeg's AAC decoder (T30b), run on the read-ahead's packets as
    /// try_decode_frame runs it: the rate, channels and frame size are
    /// what it decodes (the channels even from frames it then refuses).
    aac,
    /// FFmpeg's AC-3 decoder (T32a), which sets the sample format when it
    /// opens and, with AV_CODEC_CAP_CHANNEL_CONF, decodes the first packet
    /// (and more while a parameter is missing), writing the rate and
    /// layout into the codec context the parser fills.
    ac3,
    /// FFmpeg's float MPEG audio decoders (T33a1): the sample format at
    /// open; each frame decoded sets the layout from its header, the bit
    /// rate when none is known, and its frame size, then its rate once it
    /// decodes.
    mpegaudio,
};

/// What a decoder run in the read-ahead left in libavformat's codec
/// context.
pub const DecodedParams = struct {
    sample_rate: u32 = 0,
    channels: u32 = 0,
    /// The channel mask, 0 for an unspecified order.
    mask: u64 = 0,
    frame_size: u32 = 0,
    seek_preroll: u32 = 0,
    /// `avctx->profile`, null for unknown.
    profile: ?i32 = null,
};

pub const WindowError = error{ IoFailure, OutOfMemory };

/// A demuxer's source with a window of bytes read ahead (the MP3 and
/// ADTS demuxers'), standing in for FFmpeg's buffered `AVIOContext`: `window` holds the bytes
/// from `window_start` up to where the reader is.
pub const Window = struct {
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    window: std.ArrayList(u8) = .empty,
    window_start: i64 = 0,
    eof: bool = false,

    pub fn deinit(s: *Window, gpa: std.mem.Allocator) void {
        s.window.deinit(gpa);
    }

    pub fn windowEnd(s: *const Window) i64 {
        return s.window_start + @as(i64, @intCast(s.window.items.len));
    }

    /// Reads ahead until the window reaches `end` or the input ends.
    pub fn fill(s: *Window, gpa: std.mem.Allocator, end: i64) WindowError!void {
        while (!s.eof and s.windowEnd() < end) {
            const want: usize = @intCast(@min(end - s.windowEnd(), 64 * 1024));
            const old = s.window.items.len;
            try s.window.resize(gpa, old + want);
            const n = s.reader.readSliceShort(s.window.items[old..]) catch return error.IoFailure;
            s.window.shrinkRetainingCapacity(old + n);
            if (n < want) s.eof = true;
        }
    }

    /// The bytes at `pos`, at most `len`: fewer at the end of the input.
    /// `pos` must not be before the window.
    pub fn bytesAt(s: *Window, gpa: std.mem.Allocator, pos: i64, len: usize) WindowError![]const u8 {
        std.debug.assert(pos >= s.window_start);
        try s.fill(gpa, pos + @as(i64, @intCast(len)));
        if (pos >= s.windowEnd()) return &.{};
        const at: usize = @intCast(pos - s.window_start);
        return s.window.items[at..][0..@min(len, s.window.items.len - at)];
    }

    /// Forgets the window's bytes before `pos`.
    pub fn drop(s: *Window, pos: i64) void {
        if (pos <= s.window_start) return;
        const n: usize = @intCast(@min(pos - s.window_start, @as(i64, @intCast(s.window.items.len))));
        std.mem.copyForwards(u8, s.window.items[0 .. s.window.items.len - n], s.window.items[n..]);
        s.window.shrinkRetainingCapacity(s.window.items.len - n);
        s.window_start += @intCast(n);
    }

    /// `avio_seek` on a seekable source; `IoFailure` on a pipe.
    pub fn seekTo(s: *Window, pos: i64) WindowError!void {
        const seeker = s.seeker orelse return error.IoFailure;
        seeker.seekTo(std.math.cast(u64, pos) orelse return error.IoFailure) catch return error.IoFailure;
        s.window.clearRetainingCapacity();
        s.window_start = pos;
        s.eof = false;
    }

    /// The bytes at `pos`, at most `len`, read by seeking there and back,
    /// as a demuxer reads a tag at the end of a seekable file; the window
    /// is left as it was. `IoFailure` on a pipe.
    pub fn readElsewhere(s: *Window, gpa: std.mem.Allocator, pos: i64, len: usize, out: *std.ArrayList(u8)) WindowError!void {
        const before = s.window_start;
        const kept = try gpa.dupe(u8, s.window.items);
        defer gpa.free(kept);
        const was_eof = s.eof;
        try s.seekTo(pos);
        try out.appendSlice(gpa, try s.bytesAt(gpa, pos, len));
        try s.seekTo(before + @as(i64, @intCast(kept.len)));
        s.window_start = before;
        try s.window.appendSlice(gpa, kept);
        s.eof = was_eof;
    }

    /// avformat_open_input's `ff_id3v2_read_dict` from `pos`: the ID3v2
    /// tags that follow each other, into `id3` (then finished), `pos`
    /// after them; a tag over `max_bytes` is `LimitExceeded`.
    pub fn readId3v2Tags(s: *Window, gpa: std.mem.Allocator, pos: *i64, max_bytes: u32, id3: *id3v2.Reader) (WindowError || error{LimitExceeded})!void {
        while (true) {
            const head = try s.bytesAt(gpa, pos.*, id3v2.header_size);
            if (head.len < id3v2.header_size or !id3v2.match(head)) break;
            const header = head[0..id3v2.header_size].*;
            const body_len = id3v2.bodyLen(&header);
            if (body_len > max_bytes) return error.LimitExceeded;
            const body = try s.bytesAt(gpa, pos.* + id3v2.header_size, body_len);
            pos.* += id3v2.header_size + @as(i64, @intCast(try id3.parseTag(&header, body)));
            s.drop(@min(pos.*, s.windowEnd()));
        }
        try id3.finish();
    }
};

/// A packet as the demuxer gives it.
pub const SourcePacket = struct {
    stream: usize,
    data: []const u8,
    pts: i64,
    dts: i64,
    duration: i64,
    flags: u32,
    pos: i64,
    skip: ?[2]u32 = null,
    new_extradata: ?[]const u8 = null,
    new_metadata: ?[]const u8 = null,
};

/// The bytes after a packet's data that `Packet.tail` keeps: a decoder's
/// checked reader stops 8 bits past the end and reads 4 bytes there, so
/// MPEG audio sees up to 5 bytes past a frame (FFmpeg's buffers have 64,
/// AV_INPUT_BUFFER_PADDING_SIZE).
pub const tail_len = 8;

/// A packet as `av_read_frame` returns it: borrowed until the next call.
pub const Packet = struct {
    stream: usize,
    data: []const u8,
    /// Null when unset.
    pts: ?i64,
    dts: ?i64,
    duration: i64,
    flags: u32,
    pos: i64,
    skip: ?[2]u32 = null,
    new_extradata: ?[]const u8 = null,
    new_metadata: ?[]const u8 = null,
    /// What FFmpeg's memory holds after `data`, which a decoder reading
    /// past the end sees: zeros (a packet's padding) except for the first
    /// frame the mpegaudio parser cuts from a raw packet without copying
    /// it (parse_packet then references the raw packet, `out_pkt->data ==
    /// pkt->data`), which is followed by the rest of that raw packet.
    tail: [tail_len]u8 = @splat(0),
};

pub const key_flag: u32 = 1;
pub const corrupt_flag: u32 = 2;
pub const discard_flag: u32 = 4;

/// The timestamps and position `av_parser_parse2` is given with a packet.
const RawPosition = struct { pts: i64, dts: i64, pos: i64 };

/// A packet held by the layer, its bytes owned.
const Held = struct {
    stream: usize,
    data: []u8,
    pts: i64,
    dts: i64,
    duration: i64,
    flags: u32,
    pos: i64,
    skip: ?[2]u32,
    new_extradata: ?[]u8,
    new_metadata: ?[]u8,
    tail: [tail_len]u8 = @splat(0),

    fn deinit(h: *Held, gpa: std.mem.Allocator) void {
        gpa.free(h.data);
        if (h.new_extradata) |b| gpa.free(b);
        if (h.new_metadata) |b| gpa.free(b);
    }
};

/// A `PacketList`: packets taken from the front in constant time, so
/// draining millions of held packets stays linear.
const HeldQueue = std.Deque(Held);

fn freeQueue(q: *HeldQueue, gpa: std.mem.Allocator) void {
    while (q.popFront()) |h| {
        var held = h;
        held.deinit(gpa);
    }
}

/// get_next_pkt's walk: the read-ahead's packets, then from its tail on
/// into the parser's queue.
const HeldIterator = struct {
    queues: [2]*const HeldQueue,
    queue: usize = 0,
    index: usize = 0,

    fn next(it: *HeldIterator) ?*Held {
        while (it.queue < it.queues.len) {
            const q = it.queues[it.queue];
            if (it.index < q.len) {
                defer it.index += 1;
                return q.atPtr(it.index);
            }
            it.queue += 1;
            it.index = 0;
        }
        return null;
    }
};

/// `FFStream`'s timing state.
const StreamState = struct {
    cur_dts: i64 = relative_ts_base,
    first_dts: i64 = nopts,
    last_ip_pts: i64 = nopts,
    last_ip_duration: i64 = 0,
    update_initial_durations_done: bool = false,
    /// The parser's sample rate (`avctx->sample_rate`), which the FLAC
    /// parser fills from a frame header when the container gave none.
    parser_rate: u32 = 0,
    // avformat_find_stream_info's per-stream info.
    codec_info_nb_frames: u32 = 0,
    codec_info_duration: i64 = 0,
    fps_first_dts: i64 = nopts,
    fps_first_dts_idx: u32 = 0,
    fps_last_dts: i64 = nopts,
    fps_last_dts_idx: u32 = 0,
    /// try_decode_frame: 0 untried, 1 a decoder opened, -1 none (or one
    /// that refused the stream).
    found_decoder: i8 = 0,
    /// The decoder set the sample format.
    decoded: bool = false,
    /// A refused open cleared the channel count.
    no_channels: bool = false,
    /// The index AVFMT_GENERIC_INDEX builds from the returned keyframes.
    index: seek.Index = .{},
    /// A full-raw parser (`sti->parser`), closed by a flush, and the codec
    /// context it fills (`sti->avctx`), which stays.
    raw: ?RawParser = null,
    codec: ?ParserContext = null,
    /// The AAC decoder try_decode_frame opened, and what it decoded.
    aac: ?*aacdec.Decoder = null,
    /// The AC-3 decoder try_decode_frame opened.
    ac3: ?*ac3dec.Decoder = null,
    /// The MPEG audio decoder try_decode_frame opened, and the codec
    /// context fields it set.
    mpa: ?*mp3dec.Decoder = null,
    mpa_params: MpaParams = .{},
    decoded_params: DecodedParams = .{},
    /// The samples the next packet's skip-samples side data discards,
    /// and the request a seek leaves for it (`seek_discard`,
    /// `seek_to_start`).
    skip_samples: i64 = 0,
    seek_discard: bool = false,
    seek_to_start: bool = false,
};

/// What the MPEG audio decoder left in the codec context.
pub const MpaParams = struct {
    /// The channels of the last frame's header (the layout set from it).
    channels: u32 = 0,
    frame_size: u32 = 0,
    /// The rate of the last frame that decoded.
    sample_rate: u32 = 0,
    /// The first header's bit rate, when the context had none.
    bit_rate: i64 = 0,
};

/// A parser with `av_parser_parse2`'s byte offsets and timestamps.
const RawParser = struct {
    parser: union(enum) {
        mpa: mpegaudio.Parser,
        aac: adts.Parser,
        ac3: ac3.Parser,
    },
    cur_offset: i64,
    next_frame_offset: i64,
    frame_offset: i64 = 0,
    /// The packets the parser was given (`AV_PARSER_PTS_NB` of them):
    /// where each starts and ends in the parser's byte count, and its
    /// timestamps and position.
    cur_frame_start_index: u2 = 0,
    cur_frame_offset: [4]i64 = @splat(0),
    cur_frame_end: [4]i64 = @splat(0),
    cur_frame_pts: [4]i64 = @splat(0),
    cur_frame_dts: [4]i64 = @splat(0),
    cur_frame_pos: [4]i64 = @splat(0),
    fetch_timestamp: bool = true,
    /// The current frame's timestamps and position (`ff_fetch_timestamp`).
    pts: i64 = 0,
    dts: i64 = 0,
    pos: i64 = 0,

    /// ff_fetch_timestamp without an offset, fuzziness or removal.
    fn fetchTimestamp(p: *RawParser) void {
        p.dts = nopts;
        p.pts = nopts;
        p.pos = -1;
        for (0..4) |i| {
            if (p.cur_offset >= p.cur_frame_offset[i] and
                (p.frame_offset < p.cur_frame_offset[i] or (p.frame_offset == 0 and p.next_frame_offset == 0)) and
                p.cur_frame_end[i] != 0)
            {
                p.dts = p.cur_frame_dts[i];
                p.pts = p.cur_frame_pts[i];
                p.pos = p.cur_frame_pos[i];
                if (p.cur_offset < p.cur_frame_end[i]) break;
            }
        }
    }

    fn deinit(p: *RawParser, gpa: std.mem.Allocator) void {
        switch (p.parser) {
            inline else => |*parser| parser.deinit(gpa),
        }
    }
};

/// The codec context a full-raw parser fills.
const ParserContext = union(enum) {
    mpa: mpegaudio.Context,
    aac: adts.Context,
    ac3: ac3.ParserContext,

    fn bitRate(c: ParserContext) i64 {
        return switch (c) {
            inline else => |ctx| ctx.bit_rate,
        };
    }
};

/// The codec context fields the read-ahead's parser and decoders set
/// (`Layer.contextParams`); null fields are the demuxer's.
pub const ContextParams = struct {
    /// avcodec_open2 succeeded on the stream.
    decoder_opened: bool,
    sample_rate: ?u32 = null,
    channels: ?u32 = null,
    /// A native layout's mask.
    mask: ?u64 = null,
    /// The decoder left the layout unspecified (`channels` of them).
    unspecified: bool = false,
    frame_size: ?u32 = null,
    bit_rate: ?i64 = null,
    /// `avctx->profile`, null for unknown.
    profile: ?i32 = null,
    seek_preroll: ?u32 = null,
    mpa_codec: ?mpegaudio.Codec = null,
    eac3: bool = false,
    service_type: ?u8 = null,
};

/// A stream's codec parameters as libavformat's codec context has them:
/// the demuxer's, then the parser's.
pub const CodecParams = struct {
    /// The MPEG audio codec, when the parser chose one.
    mpa_codec: ?mpegaudio.Codec,
    /// The channel mask a decoder set, 0 when none or unspecified.
    mask: u64 = 0,
    /// The AAC parser's profile, when it set one.
    profile: ?u8 = null,
    /// The AC-3 parser met an E-AC-3 frame: the codec is `eac3`.
    eac3: bool = false,
    sample_rate: u32,
    channels: u8,
    bit_rate: i64,
};

pub fn Layer(comptime Source: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        src: *Source,
        states: std.ArrayList(StreamState) = .empty,
        /// avformat_find_stream_info's packets, returned first.
        packet_buffer: HeldQueue = .empty,
        /// The parser's output (FLAC streams), before it is returned.
        parse_queue: HeldQueue = .empty,
        /// The packet returned last.
        current: ?Held = null,
        eof: bool = false,
        /// The format's start time, duration (`AV_TIME_BASE` units) and
        /// bit rate after estimate_timings.
        start_time: i64 = nopts,
        duration: i64 = nopts,
        bit_rate: i64 = 0,

        pub const Error = Source.ReadError;

        pub fn init(gpa: std.mem.Allocator, src: *Source) Self {
            return .{ .gpa = gpa, .src = src };
        }

        pub fn deinit(l: *Self) void {
            freeQueue(&l.packet_buffer, l.gpa);
            freeQueue(&l.parse_queue, l.gpa);
            l.packet_buffer.deinit(l.gpa);
            l.parse_queue.deinit(l.gpa);
            if (l.current) |*h| h.deinit(l.gpa);
            for (l.states.items) |*s| {
                s.index.deinit(l.gpa);
                if (s.raw) |*p| p.deinit(l.gpa);
                l.closeDecoder(s);
            }
            l.states.deinit(l.gpa);
        }

        /// The stream's codec parameters (`codecpar`, which follows the
        /// parser's codec context).
        pub fn codecParams(l: *Self, i: usize) Error!CodecParams {
            const setup = l.src.setup(i);
            const s = try l.state(i);
            if (setup.decoder == .aac and s.found_decoder > 0) {
                const p = s.decoded_params;
                const bit_rate = if (s.codec) |c| c.bitRate() else setup.bit_rate;
                const profile: ?u8 = if (s.codec) |c| switch (c) {
                    .aac => |a| a.profile,
                    else => null,
                } else null;
                return .{ .mpa_codec = null, .profile = profile, .sample_rate = p.sample_rate, .channels = @min(p.channels, 255), .mask = p.mask, .bit_rate = bit_rate };
            }
            if (s.codec) |codec| switch (codec) {
                .mpa => |c| return .{ .mpa_codec = c.codec, .sample_rate = c.sample_rate, .channels = c.channels, .bit_rate = c.bit_rate },
                .aac => |c| return .{ .mpa_codec = null, .profile = c.profile, .sample_rate = setup.sample_rate, .channels = setup.channels, .bit_rate = c.bit_rate },
                .ac3 => |c| return .{ .mpa_codec = null, .sample_rate = c.sample_rate, .channels = c.channels, .mask = c.channel_layout, .bit_rate = c.bit_rate, .eac3 = c.eac3 },
            };
            return .{ .mpa_codec = null, .sample_rate = setup.sample_rate, .channels = setup.channels, .bit_rate = setup.bit_rate };
        }

        fn state(l: *Self, i: usize) Error!*StreamState {
            while (l.states.items.len <= i) try l.states.append(l.gpa, .{ .skip_samples = l.src.setup(l.states.items.len).skip_samples });
            return &l.states.items[i];
        }

        /// The packets compute_pkt_fields' look-backs reach: the
        /// read-ahead's, then the parser's, as get_next_pkt walks them.
        fn held(l: *const Self) HeldIterator {
            return .{ .queues = .{ &l.packet_buffer, &l.parse_queue } };
        }

        /// avformat_find_stream_info's read-ahead.
        pub fn findStreamInfo(l: *Self) Error!void {
            var read_size: u64 = 0;
            var eof_reached = false;
            while (true) {
                var all = true;
                for (0..l.src.streamCount()) |i| {
                    const s = try l.state(i);
                    const setup = l.src.setup(i);
                    if (!hasCodecParameters(setup, s.*)) {
                        all = false;
                        break;
                    }
                    if (s.first_dts == nopts and s.codec_info_nb_frames < max_ts_probe and setup.media == .audio) {
                        all = false;
                        break;
                    }
                }
                if (all) break;
                if (read_size >= probesize) break;
                // "EOF or error": a demuxer's error ends the read-ahead as
                // its end does (eof_reached), and the file opens; the next
                // read goes on after the refused packet. Running out of
                // memory, and an input that cannot be read, still fail.
                const next_held = l.readFrameInternal() catch |err| {
                    if (err == error.OutOfMemory or err == error.IoFailure) return err;
                    eof_reached = true;
                    break;
                };
                var h = next_held orelse {
                    eof_reached = true;
                    break;
                };
                l.packet_buffer.pushBack(l.gpa, h) catch |err| {
                    h.deinit(l.gpa);
                    return err;
                };
                const pkt = l.packet_buffer.atPtr(l.packet_buffer.len - 1);
                const s = try l.state(pkt.stream);
                const setup = l.src.setup(pkt.stream);
                read_size += pkt.data.len;
                if (pkt.dts != nopts and s.codec_info_nb_frames > 1) {
                    if (s.fps_last_dts != nopts and s.fps_last_dts >= pkt.dts) {
                        s.fps_first_dts = nopts;
                        s.fps_last_dts = nopts;
                    }
                    if (s.fps_last_dts != nopts and s.fps_last_dts_idx > s.fps_first_dts_idx) {
                        const gap: u64 = @bitCast(pkt.dts -% s.fps_last_dts);
                        const span: u64 = @bitCast(s.fps_last_dts -% s.fps_first_dts);
                        if (gap / 1000 > span / (s.fps_last_dts_idx - s.fps_first_dts_idx)) {
                            s.fps_first_dts = nopts;
                            s.fps_last_dts = nopts;
                        }
                    }
                    if (s.fps_first_dts == nopts) {
                        s.fps_first_dts = pkt.dts;
                        s.fps_first_dts_idx = s.codec_info_nb_frames;
                    }
                    s.fps_last_dts = pkt.dts;
                    s.fps_last_dts_idx = s.codec_info_nb_frames;
                }
                if (s.codec_info_nb_frames > 1) {
                    var t: i64 = 0;
                    if (setup.time_base.den > 0) t = rational.rescaleQ(s.codec_info_duration, setup.time_base, .{ .num = 1, .den = 1_000_000 });
                    if (t == 0 and s.codec_info_nb_frames > 30 and s.fps_first_dts != nopts and s.fps_last_dts != nopts) {
                        const dur = rational.satSub(s.fps_last_dts, s.fps_first_dts);
                        t = @max(t, rational.rescaleQ(dur, setup.time_base, .{ .num = 1, .den = 1_000_000 }));
                    }
                    const limit: i64 = if (setup.media == .subtitle) max_subtitle_analyze_duration else max_analyze_duration;
                    if (t >= limit) break;
                    if (pkt.duration > 0 and pkt.duration < std.math.maxInt(i64) - s.codec_info_duration) {
                        const start = l.src.startTime(pkt.stream).*;
                        // A subtitle's analyzed duration is at most its
                        // time since the start.
                        if (setup.media == .subtitle and pkt.pts != nopts and start != nopts and pkt.pts >= start and
                            @as(u64, @bitCast(pkt.pts)) -% @as(u64, @bitCast(start)) < std.math.maxInt(i64))
                        {
                            s.codec_info_duration = @min(pkt.pts - start, s.codec_info_duration + pkt.duration);
                        } else s.codec_info_duration += pkt.duration;
                    }
                }
                // try_decode_frame: the decoder opens once, setting the
                // sample format at once (Vorbis) or from a frame it
                // decodes (FLAC); without one the stream needs none.
                if (s.found_decoder == 0) {
                    switch (setup.decoder) {
                        .none => s.found_decoder = -1,
                        .flac => s.found_decoder = 1,
                        .format_at_open => {
                            s.found_decoder = 1;
                            s.decoded = true;
                        },
                        .refuses => {
                            s.found_decoder = -1;
                            s.no_channels = true;
                        },
                        // Opened by tryDecodeAac, tryDecodeAc3 and tryDecodeMpa.
                        .aac, .ac3, .mpegaudio => {},
                    }
                }
                if (setup.decoder == .flac and !s.decoded and setup.parser == .flac_headers and validFlacFrame(pkt.data)) s.decoded = true;
                if (setup.decoder == .aac) try l.tryDecodeAac(s, setup, pkt.data);
                if (setup.decoder == .ac3) try l.tryDecodeAc3(s, setup, pkt.data);
                if (setup.decoder == .mpegaudio) try l.tryDecodeMpa(s, setup, pkt.data, &pkt.tail);
                s.codec_info_nb_frames += 1;
            }
            // At the end, a stream still without its parameters whose
            // decoder never opened gets it opened (and nothing decoded).
            if (eof_reached) for (0..l.src.streamCount()) |i| {
                const s = try l.state(i);
                const setup = l.src.setup(i);
                if (hasCodecParameters(setup, s.*) or s.found_decoder != 0) continue;
                try l.openDecoder(s, setup);
            };
            // The decoders opened for the read-ahead close; what they set
            // stays.
            for (l.states.items) |*s| l.closeDecoder(s);
            l.estimateTimings();
        }

        const time_base_q: rational.Rational = .{ .num = 1, .den = 1_000_000 };

        /// estimate_timings for a format without its own PTS estimate:
        /// the streams' timings for all, else the bit rate's.
        fn estimateTimings(l: *Self) void {
            const file_size: i64 = if (l.src.fileSize()) |n| std.math.cast(i64, n) orelse std.math.maxInt(i64) else 0;
            var has_duration = l.duration != nopts;
            for (0..l.src.streamCount()) |i| {
                if (l.src.durationOf(i).* != nopts) has_duration = true;
            }
            if (has_duration) {
                l.updateStreamTimings(file_size);
                for (0..l.src.streamCount()) |i| {
                    const start = l.src.startTime(i);
                    if (start.* != nopts) continue;
                    const tb = l.src.setup(i).time_base;
                    if (l.start_time != nopts) start.* = rational.rescaleQ(l.start_time, time_base_q, tb);
                    if (l.duration != nopts) l.src.durationOf(i).* = rational.rescaleQ(l.duration, time_base_q, tb);
                }
            } else {
                l.estimateFromBitRate(file_size);
            }
            l.updateStreamTimings(file_size);
        }

        /// update_stream_timings: audio streams, and data streams as text.
        fn updateStreamTimings(l: *Self, file_size: i64) void {
            const max = std.math.maxInt(i64);
            const min = std.math.minInt(i64);
            var start_time: i64 = max;
            var end_time: i64 = min;
            var duration: i64 = min;
            var start_time_text: i64 = max;
            var end_time_text: i64 = min;
            var duration_text: i64 = min;
            for (0..l.src.streamCount()) |i| {
                const setup = l.src.setup(i);
                const tb = setup.time_base;
                const is_text = setup.media.isText();
                const st_start = l.src.startTime(i).*;
                const st_duration = l.src.durationOf(i).*;
                if (st_start != nopts and tb.den != 0) {
                    const start1 = rational.rescaleQ(st_start, tb, time_base_q);
                    if (is_text) start_time_text = @min(start_time_text, start1) else start_time = @min(start_time, start1);
                    var end1 = rational.rescaleQRnd(st_duration, tb, time_base_q, .{ .mode = .near_inf, .pass_minmax = true });
                    if (end1 != nopts and (if (end1 > 0) start1 <= max - end1 else start1 >= min - end1)) {
                        end1 += start1;
                        if (is_text) end_time_text = @max(end_time_text, end1) else end_time = @max(end_time, end1);
                    }
                }
                if (st_duration != nopts) {
                    const duration1 = rational.rescaleQ(st_duration, tb, time_base_q);
                    if (is_text) duration_text = @max(duration_text, duration1) else duration = @max(duration, duration1);
                }
            }
            const second: u64 = 1_000_000;
            if (start_time == max or (start_time > start_time_text and @as(u64, @bitCast(start_time)) -% @as(u64, @bitCast(start_time_text)) < second)) start_time = start_time_text;
            if (end_time == min or (end_time < end_time_text and @as(u64, @bitCast(end_time_text)) -% @as(u64, @bitCast(end_time)) < second)) end_time = end_time_text;
            if (duration == min or (duration < duration_text and @as(u64, @bitCast(duration_text)) -% @as(u64, @bitCast(duration)) < second)) duration = duration_text;
            if (start_time != std.math.maxInt(i64)) {
                l.start_time = start_time;
                if (end_time != std.math.minInt(i64) and end_time >= start_time) {
                    const span: u64 = @as(u64, @bitCast(end_time)) -% @as(u64, @bitCast(start_time));
                    if (span <= std.math.maxInt(i64)) duration = @max(duration, end_time - start_time);
                }
            }
            if (duration != std.math.minInt(i64) and duration > 0 and l.duration == nopts) l.duration = duration;
            if (file_size > 0 and l.duration > 0) {
                const rate = @as(f64, @floatFromInt(file_size)) * 8.0 * 1_000_000.0 / @as(f64, @floatFromInt(l.duration));
                if (rate >= 0 and rate <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) l.bit_rate = @intFromFloat(rate);
            }
        }

        /// estimate_timings_from_bit_rate: the streams' bit rates summed,
        /// then each stream's duration from the data's size.
        fn estimateFromBitRate(l: *Self, file_size_in: i64) void {
            if (l.bit_rate <= 0) {
                var sum: i64 = 0;
                for (0..l.src.streamCount()) |i| {
                    const rate = if (i < l.states.items.len) if (l.states.items[i].codec) |c| c.bitRate() else l.src.setup(i).bit_rate else l.src.setup(i).bit_rate;
                    if (rate > 0) {
                        if (std.math.maxInt(i64) - rate < sum) {
                            sum = 0;
                            break;
                        }
                        sum += rate;
                    }
                }
                l.bit_rate = sum;
            }
            if (l.duration != nopts or l.bit_rate == 0) return;
            var file_size = file_size_in;
            const data_offset = l.src.dataOffset();
            if (file_size <= data_offset) return;
            file_size -= data_offset;
            for (0..l.src.streamCount()) |i| {
                const tb = l.src.setup(i).time_base;
                const d = l.src.durationOf(i);
                if (tb.num <= @divTrunc(std.math.maxInt(i64), l.bit_rate) and d.* == nopts) {
                    d.* = rational.rescale(file_size, 8 * @as(i64, tb.den), l.bit_rate * tb.num);
                }
            }
        }

        /// try_decode_frame with FFmpeg's AAC decoder: opened on the first
        /// packet with the demuxer's rate and channels; each packet's
        /// frames decoded in order while the parameters are incomplete (and
        /// for the first packet, AV_CODEC_CAP_CHANNEL_CONF), up to a
        /// refused frame.
        fn tryDecodeAac(l: *Self, s: *StreamState, setup: Setup, data_in: []const u8) Error!void {
            if (s.found_decoder == 0) {
                const d = try l.gpa.create(aacdec.Decoder);
                d.* = aacdec.Decoder.initExtradata(l.gpa, setup.extradata, setup.sample_rate, setup.channels) catch |err| {
                    l.gpa.destroy(d);
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    s.found_decoder = -1;
                    return;
                };
                // avcodec_parameters_to_context: the container's frame
                // size and pre-roll; the decoder's sample rate stays the
                // container's until a frame sets it.
                if (setup.extradata.len > 0) {
                    d.frame_size = setup.frame_size;
                    d.seek_preroll = @max(d.seek_preroll, setup.seek_preroll);
                }
                s.aac = d;
                s.found_decoder = 1;
                s.decoded_params = .{ .channels = d.channels, .mask = d.mask, .seek_preroll = d.seek_preroll, .sample_rate = if (setup.extradata.len > 0) d.sample_rate else 0, .frame_size = if (setup.extradata.len > 0) d.frame_size else 0, .profile = d.profile };
            }
            const d = s.aac orelse return;
            var data = data_in;
            while (data.len > 0 and (!hasCodecParameters(setup, s.*) or s.codec_info_nb_frames == 0)) {
                const got = d.decode(data) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    s.decoded_params.channels = d.channels;
                    s.decoded_params.mask = d.mask;
                    return;
                };
                s.decoded_params = .{ .sample_rate = d.sample_rate, .channels = d.channels, .mask = d.mask, .frame_size = d.frame_size, .seek_preroll = d.seek_preroll, .profile = d.profile };
                if (got.consumed == 0) return;
                data = data[@min(got.consumed, data.len)..];
            }
        }

        /// try_decode_frame for AC-3: the decoder opened with the codec
        /// context's rate (the parser's so far), then run on the packet
        /// while the parameters are incomplete or no frame has been read;
        /// each frame it gives sets the context's rate and layout.
        fn tryDecodeAc3(l: *Self, s: *StreamState, setup: Setup, data_in: []const u8) Error!void {
            const ctx = if (s.codec) |*c| switch (c.*) {
                .ac3 => |*a| a,
                else => return,
            } else return;
            if (s.found_decoder == 0) {
                const d = try l.gpa.create(ac3dec.Decoder);
                d.* = ac3dec.Decoder.init(l.gpa, ctx.sample_rate) catch |err| {
                    l.gpa.destroy(d);
                    return err;
                };
                s.ac3 = d;
                s.found_decoder = 1;
                s.decoded = true;
            }
            const d = s.ac3 orelse return;
            var data = data_in;
            while (data.len > 0 and (!hasCodecParameters(setup, s.*) or s.codec_info_nb_frames == 0)) {
                const got = d.decode(data) catch {
                    // A packet that fails after a frame's channel
                    // configuration leaves avctx's layout set.
                    if (d.ch_layout != 0) {
                        ctx.channels = @popCount(d.ch_layout);
                        ctx.channel_layout = d.ch_layout;
                    }
                    return;
                };
                if (got.frame) |f| {
                    ctx.sample_rate = f.sample_rate;
                    ctx.channels = f.channels;
                    ctx.channel_layout = f.channel_layout;
                    // A good frame's bit rate replaces the parser's average.
                    if (!f.concealed) if (d.bit_rate) |rate| {
                        ctx.bit_rate = rate;
                    };
                }
                data = data[@min(got.consumed, data.len)..];
            }
        }

        /// avcodec_open2 alone, as find_stream_info calls it at the end of
        /// the input for a stream that had no packet.
        fn openDecoder(l: *Self, s: *StreamState, setup: Setup) Error!void {
            switch (setup.decoder) {
                .none => {},
                .flac => s.found_decoder = 1,
                .format_at_open => {
                    s.found_decoder = 1;
                    s.decoded = true;
                },
                .refuses => {
                    s.found_decoder = -1;
                    s.no_channels = true;
                },
                .aac => try l.tryDecodeAac(s, setup, &.{}),
                .ac3 => {
                    const d = try l.gpa.create(ac3dec.Decoder);
                    d.* = ac3dec.Decoder.init(l.gpa, setup.sample_rate) catch |err| {
                        l.gpa.destroy(d);
                        return err;
                    };
                    s.ac3 = d;
                    s.found_decoder = 1;
                    s.decoded = true;
                },
                .mpegaudio => try l.tryDecodeMpa(s, setup, &.{}, &.{}),
            }
        }

        /// try_decode_frame with FFmpeg's float MPEG audio decoder: opened
        /// on the first packet (the sample format set), then one frame
        /// decoded a packet while the parameters are incomplete or no frame
        /// has been read; its header sets the layout, the bit rate when the
        /// context has none and the frame size, a frame that decodes the
        /// rate.
        fn tryDecodeMpa(l: *Self, s: *StreamState, setup: Setup, data: []const u8, tail: []const u8) Error!void {
            if (s.found_decoder == 0) {
                const d = try l.gpa.create(mp3dec.Decoder);
                d.* = .init;
                s.mpa = d;
                s.found_decoder = 1;
                s.decoded = true;
            }
            const d = s.mpa orelse return;
            if (hasCodecParameters(setup, s.*) and s.codec_info_nb_frames != 0) return;
            var skipped: usize = 0;
            while (skipped < data.len and data[skipped] == 0) skipped += 1;
            const buf = data[skipped..];
            if (buf.len < 4) return;
            const header = std.mem.readInt(u32, buf[0..4], .big);
            if (header >> 8 == 0x544147) return; // an ID3v1 tag
            const hdr = mpegaudio.decodeHeader(header) orelse return;
            if (hdr.freeFormat()) return;
            s.mpa_params.channels = hdr.nb_channels;
            const context_rate = if (s.codec) |c| c.bitRate() else setup.bit_rate;
            if (context_rate == 0 and s.mpa_params.bit_rate == 0) s.mpa_params.bit_rate = hdr.bit_rate;
            if (hdr.frame_size == 0) return; // "incomplete frame"
            s.mpa_params.frame_size = switch (hdr.layer) {
                1 => 384,
                2 => 1152,
                else => if (hdr.lsf) 576 else 1152,
            };
            const got = d.decodeFrame(data, tail) catch return;
            if (got.frame != null) s.mpa_params.sample_rate = hdr.sample_rate;
        }

        /// What the parser and the decoders the read-ahead ran left in the
        /// codec context (`avcodec_parameters_from_context`), field by
        /// field; null where they changed nothing.
        pub fn contextParams(l: *Self, i: usize) Error!ContextParams {
            const s = try l.state(i);
            var c: ContextParams = .{ .decoder_opened = s.found_decoder > 0 };
            if (s.codec) |codec| switch (codec) {
                .mpa => |m| {
                    c.mpa_codec = m.codec;
                    c.sample_rate = m.sample_rate;
                    c.channels = m.channels;
                    c.bit_rate = m.bit_rate;
                },
                .ac3 => |a| {
                    if (a.sample_rate != 0) c.sample_rate = a.sample_rate;
                    if (a.channel_layout != 0) c.mask = a.channel_layout;
                    c.bit_rate = a.bit_rate;
                    c.eac3 = a.eac3;
                    c.service_type = a.audio_service_type;
                },
                .aac => |a| {
                    c.bit_rate = a.bit_rate;
                    if (a.profile) |p| c.profile = p;
                },
            };
            const setup = l.src.setup(i);
            if (setup.decoder == .aac and s.found_decoder > 0) {
                const p = s.decoded_params;
                if (p.sample_rate != 0) c.sample_rate = p.sample_rate;
                c.channels = p.channels;
                c.mask = p.mask;
                c.unspecified = p.mask == 0;
                if (p.frame_size != 0) c.frame_size = p.frame_size;
                c.seek_preroll = p.seek_preroll;
                c.profile = p.profile;
            }
            if (setup.decoder == .mpegaudio and s.found_decoder > 0) {
                const p = s.mpa_params;
                if (p.channels != 0) c.mask = if (p.channels == 1) 0x4 else 0x3;
                if (p.frame_size != 0) c.frame_size = p.frame_size;
                if (p.sample_rate != 0) c.sample_rate = p.sample_rate;
                if (p.bit_rate != 0) c.bit_rate = p.bit_rate;
            }
            return c;
        }

        fn closeDecoder(l: *Self, s: *StreamState) void {
            if (s.aac) |d| {
                d.deinit();
                l.gpa.destroy(d);
            }
            s.aac = null;
            if (s.ac3) |d| {
                d.deinit();
                l.gpa.destroy(d);
            }
            s.ac3 = null;
            if (s.mpa) |d| l.gpa.destroy(d);
            s.mpa = null;
        }

        /// `codecpar->seek_preroll`: the demuxer's, or the one a decoder
        /// opened in the read-ahead set.
        fn streamPreroll(setup: Setup, s: StreamState) u32 {
            if (setup.decoder == .aac and s.found_decoder > 0) return @max(setup.seek_preroll, s.decoded_params.seek_preroll);
            return setup.seek_preroll;
        }

        /// has_codec_parameters for an audio stream.
        fn hasCodecParameters(setup: Setup, s: StreamState) bool {
            // A data stream needs nothing, a subtitle stream (of the
            // codecs here) neither.
            if (setup.media != .audio) return true;
            if (!setup.known) return false;
            if (setup.decoder == .mpegaudio) {
                // The frame size is determinable: a decoded header gives it.
                if (s.mpa_params.frame_size == 0) return false;
                if (s.found_decoder == 0) return false;
                const rate = if (s.mpa_params.sample_rate != 0) s.mpa_params.sample_rate else if (s.codec) |c| switch (c) {
                    .mpa => |m| m.sample_rate,
                    else => setup.sample_rate,
                } else setup.sample_rate;
                const channels = if (s.mpa_params.channels != 0) s.mpa_params.channels else if (s.codec) |c| switch (c) {
                    .mpa => |m| m.channels,
                    else => setup.channels,
                } else setup.channels;
                return rate != 0 and channels != 0;
            }
            if (setup.decoder == .aac) {
                // The sample format is unknown until the decoder opens.
                if (s.found_decoder == 0) return false;
                if (s.found_decoder < 0) return setup.sample_rate != 0 and setup.channels != 0;
                return s.decoded_params.sample_rate != 0 and s.decoded_params.channels != 0;
            }
            if (setup.decoder == .ac3) {
                // The decoder sets the sample format when it opens; the
                // codec context holds the parser's and decoder's values.
                if (s.found_decoder == 0) return false;
                const ctx = if (s.codec) |c| switch (c) {
                    .ac3 => |a| a,
                    else => return false,
                } else return false;
                return ctx.sample_rate != 0 and ctx.channels != 0;
            }
            if (setup.frame_size_unknown) return false;
            if (setup.sample_rate == 0 and s.parser_rate == 0) return false;
            if (setup.channels == 0 or s.no_channels) return false;
            // A decoder that has not decoded yet leaves the sample format
            // unknown.
            if (s.found_decoder >= 0 and !s.decoded) return false;
            return true;
        }

        /// av_read_frame without genpts.
        pub fn next(l: *Self) Error!?Packet {
            if (l.current) |*h| h.deinit(l.gpa);
            l.current = null;
            const h = l.packet_buffer.popFront() orelse
                try l.readFrameInternal() orelse return null;
            l.current = h;
            // av_read_frame's return_packet indexes every keyframe again,
            // its timestamps now fixed.
            if (h.flags & key_flag != 0) try l.addIndexEntry(h.stream, h.pos, h.dts);
            var pts = h.pts;
            var dts = h.dts;
            if (isRelative(dts)) dts -= relative_ts_base;
            if (isRelative(pts)) pts -= relative_ts_base;
            return .{
                .stream = h.stream,
                .data = h.data,
                .pts = if (pts == nopts) null else pts,
                .dts = if (dts == nopts) null else dts,
                .duration = h.duration,
                .flags = h.flags,
                .pos = h.pos,
                .skip = h.skip,
                .new_extradata = h.new_extradata,
                .new_metadata = h.new_metadata,
                .tail = h.tail,
            };
        }

        /// read_frame_internal: the demuxer's next packet through the
        /// parser or compute_pkt_fields, with the skip samples a seek
        /// asked for; null at the end.
        fn readFrameInternal(l: *Self) Error!?Held {
            var h = try l.nextParsed() orelse return null;
            errdefer h.deinit(l.gpa);
            try l.injectSkip(&h);
            return h;
        }

        /// read_frame_internal's packet, before its skip samples.
        fn nextParsed(l: *Self) Error!?Held {
            while (l.parse_queue.len == 0) {
                if (l.eof) return null;
                const raw = l.src.next() catch |err| {
                    // The parsers flushed (nothing for complete frames),
                    // then the error, unless the parser still holds a
                    // packet, which goes first.
                    if (err == error.OutOfMemory) return err;
                    try l.flushParsers();
                    if (l.parse_queue.len > 0) break;
                    return err;
                } orelse {
                    l.eof = true;
                    try l.flushParsers();
                    break;
                };
                var h = try l.own(raw);
                errdefer h.deinit(l.gpa);
                const setup = l.src.setup(h.stream);
                switch (setup.parser) {
                    .none => {},
                    .flac_headers => {
                        try l.parseFlac(&h, setup);
                        continue;
                    },
                    .mpegaudio, .aac, .ac3, .ac3_full, .mpegaudio_full => {
                        // The parser copies its frames out of the raw
                        // packet, which is freed here once parsed; on an
                        // error the errdefer above frees it, and only it.
                        try l.parseRaw(h.stream, h.data, .{ .pts = h.pts, .dts = h.dts, .pos = h.pos }, h.flags, setup);
                        h.deinit(l.gpa);
                        continue;
                    },
                }
                try l.computePktFields(&h, setup);
                // AVFMT_GENERIC_INDEX, which every format here has.
                if (h.flags & key_flag != 0 and h.dts != nopts) try l.addIndexEntry(h.stream, h.pos, h.dts);
                return h;
            }
            return l.parse_queue.popFront();
        }

        /// av_add_index_entry for a keyframe: a relative timestamp is
        /// taken as it is, less the relative base.
        fn addIndexEntry(l: *Self, stream: usize, pos: i64, dts: i64) Error!void {
            const s = try l.state(stream);
            try s.index.add(l.gpa, pos, if (isRelative(dts)) dts - relative_ts_base else dts);
        }

        /// The codec parameters' sample rate: the demuxer's, else the
        /// parser's.
        fn sampleRate(l: *Self, i: usize, s: *const StreamState) u32 {
            if (l.src.setup(i).decoder == .aac and s.found_decoder > 0) return s.decoded_params.sample_rate;
            if (s.codec) |codec| switch (codec) {
                .mpa => |c| return c.sample_rate,
                .ac3 => |c| return c.sample_rate,
                .aac => {},
            };
            const rate = l.src.setup(i).sample_rate;
            return if (rate != 0) rate else s.parser_rate;
        }

        /// read_frame_internal at the end (or an error): parse_packet with
        /// `flush` for every open parser, then the parser closed.
        fn flushParsers(l: *Self) Error!void {
            for (0..l.states.items.len) |i| {
                const s = &l.states.items[i];
                if (s.raw == null) continue;
                try l.parseRaw(i, &.{}, .{ .pts = nopts, .dts = nopts, .pos = -1 }, 0, l.src.setup(i));
                if (s.raw) |*p| p.deinit(l.gpa);
                s.raw = null;
            }
        }

        /// parse_packet with a full-raw parser (AVSTREAM_PARSE_FULL_RAW):
        /// FFmpeg's mpegaudio or AAC parser. Each frame is a packet at the
        /// parser's frame offset, a keyframe when the parser says so (the
        /// AAC parser, for a frame whose header parsed) or the raw packet
        /// was one, its duration the mpegaudio parser's frame (rounded down
        /// in the time base; the AAC parser gives none), timestamps from
        /// compute_pkt_fields; the codec context follows the frames.
        /// `data` empty flushes.
        fn parseRaw(l: *Self, stream: usize, data_in: []const u8, at: RawPosition, raw_flags: u32, setup: Setup) Error!void {
            const s = try l.state(stream);
            const is_ac3 = setup.parser == .ac3 or setup.parser == .ac3_full;
            if (s.codec == null) s.codec = if (setup.parser == .aac)
                .{ .aac = .{ .bit_rate = setup.bit_rate } }
            else if (is_ac3)
                .{ .ac3 = .{ .bit_rate = setup.bit_rate, .sample_rate = if (setup.parser == .ac3_full) setup.sample_rate else 0, .channels = if (setup.parser == .ac3_full) setup.channels else 0 } }
            else
                .{ .mpa = .{ .codec = setup.mpa_codec orelse .mp3, .sample_rate = setup.sample_rate, .channels = setup.channels, .bit_rate = setup.bit_rate } };
            if (s.raw == null) {
                if (data_in.len == 0) return;
                // PARSER_FLAG_FETCHED_OFFSET: the first packet's position.
                s.raw = .{
                    .parser = if (setup.parser == .aac) .{ .aac = .{} } else if (is_ac3) .{ .ac3 = .{} } else .{ .mpa = .{} },
                    .cur_offset = at.pos,
                    .next_frame_offset = at.pos,
                };
            }
            const flushing = data_in.len == 0;
            var data = data_in;
            var got_output = flushing;
            var call_at = at;
            while (data.len > 0 or (flushing and got_output)) {
                const p = &s.raw.?;
                // av_parser_parse2: a packet descriptor for new bytes, then
                // the timestamps of the frame that starts here.
                if (data.len > 0 and p.cur_offset + @as(i64, @intCast(data.len)) != p.cur_frame_end[p.cur_frame_start_index]) {
                    p.cur_frame_start_index +%= 1;
                    const i = p.cur_frame_start_index;
                    p.cur_frame_offset[i] = p.cur_offset;
                    p.cur_frame_end[i] = p.cur_offset + @as(i64, @intCast(data.len));
                    p.cur_frame_pts[i] = call_at.pts;
                    p.cur_frame_dts[i] = call_at.dts;
                    p.cur_frame_pos[i] = call_at.pos;
                }
                if (p.fetch_timestamp) {
                    p.fetch_timestamp = false;
                    p.fetchTimestamp();
                }
                // parse_packet: later calls on the same packet pass none.
                call_at = .{ .pts = nopts, .dts = nopts, .pos = -1 };
                // av_parser_parse2: the parser's index, which the AAC
                // parser may give negative (bytes it reads again).
                var index: i64 = undefined;
                var key = false;
                var duration: u32 = 0;
                const frame_or_null: ?[]const u8 = switch (p.parser) {
                    .mpa => |*mpa| blk: {
                        const res = try mpa.parse(l.gpa, &s.codec.?.mpa, data);
                        index = @intCast(res.consumed);
                        duration = mpa.duration;
                        break :blk res.frame;
                    },
                    .aac => |*aac| blk: {
                        const res = try aac.parse(l.gpa, &s.codec.?.aac, data);
                        index = res.index;
                        key = res.key;
                        break :blk res.frame;
                    },
                    .ac3 => |*a| blk: {
                        const res = try a.parse(l.gpa, &s.codec.?.ac3, data);
                        index = res.index;
                        // key_frame stays -1, the picture type I.
                        key = true;
                        duration = a.duration;
                        break :blk res.frame;
                    },
                };
                // The MPEG audio parser leaves key_frame -1 and the picture
                // type I too.
                if (p.parser == .mpa and setup.parser.full()) key = true;
                const consumed: usize = @intCast(@max(index, 0));
                data = data[consumed..];
                got_output = frame_or_null != null;
                const frame = frame_or_null orelse {
                    p.cur_offset += @intCast(consumed);
                    continue;
                };
                p.frame_offset = p.next_frame_offset;
                p.next_frame_offset = p.cur_offset + index;
                p.fetch_timestamp = true;
                p.cur_offset += @intCast(consumed);
                const full = setup.parser.full();
                var h: Held = .{
                    .stream = stream,
                    .data = try l.gpa.dupe(u8, frame),
                    .pts = if (full) p.pts else nopts,
                    .dts = if (full) p.dts else nopts,
                    .duration = 0,
                    // A parser keyframe, or (key_frame -1 without a
                    // picture type) the raw packet's flag; the packet's
                    // discard and corrupt flags pass.
                    .flags = (if (key or raw_flags & key_flag != 0) key_flag else 0) | (raw_flags & (discard_flag | corrupt_flag)),
                    // AVSTREAM_PARSE_FULL_RAW positions frames by bytes;
                    // FULL gives the packet's position.
                    .pos = if (full) p.pos else p.frame_offset,
                    .skip = null,
                    .new_extradata = null,
                    .new_metadata = null,
                };
                errdefer h.deinit(l.gpa);
                // A frame at the very start of the raw packet that the
                // parser did not copy (`out_pkt->data == pkt->data`):
                // FFmpeg's packet references the raw one, so the rest of
                // it follows the frame. Others are copied, then zeros.
                if (frame.len != 0 and frame.ptr == data_in.ptr) {
                    const rest = data_in[frame.len..];
                    const n = @min(rest.len, tail_len);
                    @memcpy(h.tail[0..n], rest[0..n]);
                }
                // The parser's duration in the time base, at the codec
                // context's rate.
                const ctx_rate: u32 = switch (s.codec.?) {
                    .mpa => |c| c.sample_rate,
                    .ac3 => |c| c.sample_rate,
                    .aac => 0,
                };
                if (ctx_rate > 0 and duration > 0) {
                    h.duration = rational.rescaleQRnd(duration, .{ .num = 1, .den = @intCast(ctx_rate) }, setup.time_base, .{ .mode = .down });
                }
                try l.computePktFields(&h, setup);
                try l.parse_queue.pushBack(l.gpa, h);
            }
        }

        /// read_frame_internal's skip samples: after a seek, the priming
        /// before the start time, the initial padding on the stream's
        /// first packet, else the decoder's pre-roll, made side data with
        /// what the demuxer set (the formats here set no discard range).
        fn injectSkip(l: *Self, h: *Held) Error!void {
            const s = try l.state(h.stream);
            const setup = l.src.setup(h.stream);
            // An int in FFmpeg; the int64_t arithmetic below wraps as the
            // reference build's does (notes.md "Follow the reference build").
            var discard_padding: i32 = 0;
            if (setup.first_discard_sample != 0 and h.pts != nopts) {
                const rate = l.sampleRate(h.stream, s);
                const pts = h.pts - if (isRelative(h.pts)) relative_ts_base else 0;
                // ts_to_samples; codecpar->frame_size is 0 without a
                // decoder.
                const sample = rational.rescale(pts, setup.time_base.num * @as(i64, rate), setup.time_base.den);
                const duration = @max(@as(i64, setup.frame_size), rational.rescale(h.duration, setup.time_base.num * @as(i64, rate), setup.time_base.den));
                const end_sample = sample +% duration;
                if (duration > 0 and end_sample >= setup.first_discard_sample and sample < setup.last_discard_sample)
                    discard_padding = @truncate(@min(end_sample -% setup.first_discard_sample, duration));
            }
            if (s.seek_discard) {
                const rate = l.sampleRate(h.stream, s);
                if (setup.known and rate > 0) {
                    const start = l.src.startTime(h.stream).*;
                    const first = h.dts != nopts and s.first_dts != nopts and h.dts <= s.first_dts;
                    const in_priming = h.pts != nopts and start != nopts and h.pts < start;
                    var skip: i64 = 0;
                    // ts_to_samples: the priming ends at the start time.
                    if (in_priming) skip = rational.rescale(start -% h.pts, setup.time_base.num * @as(i64, rate), setup.time_base.den);
                    if (first) {
                        if (setup.initial_padding > 0) skip = setup.initial_padding;
                    } else if (!(s.seek_to_start and h.pts != nopts and !in_priming)) {
                        skip = @max(skip, streamPreroll(setup, s.*));
                    }
                    s.skip_samples = @max(s.skip_samples, @min(skip, std.math.maxInt(i32)));
                }
                s.seek_discard = false;
            }
            if (setup.start_skip_samples != 0 and (h.pts == 0 or h.pts == relative_ts_base)) s.skip_samples = setup.start_skip_samples;
            s.skip_samples = @max(0, s.skip_samples);
            if (s.skip_samples == 0 and discard_padding == 0) return;
            var padding: u32 = @bitCast(discard_padding);
            if (h.skip) |kept| {
                // FFmpeg reads the demuxer's count as an int, and compares
                // the padding with the demuxer's as unsigned (an int against
                // AV_RL32's uint32_t).
                const demuxer_skip: i32 = @bitCast(kept[0]);
                s.skip_samples = @max(s.skip_samples, demuxer_skip);
                padding = @max(padding, kept[1]);
            }
            h.skip = .{ @truncate(@as(u64, @bitCast(s.skip_samples))), padding };
            s.skip_samples = 0;
        }

        fn own(l: *Self, raw: SourcePacket) Error!Held {
            const data = try l.gpa.dupe(u8, raw.data);
            errdefer l.gpa.free(data);
            const extradata: ?[]u8 = if (raw.new_extradata) |b| try l.gpa.dupe(u8, b) else null;
            errdefer if (extradata) |b| l.gpa.free(b);
            const md: ?[]u8 = if (raw.new_metadata) |b| try l.gpa.dupe(u8, b) else null;
            return .{
                .stream = raw.stream,
                .data = data,
                .pts = raw.pts,
                .dts = raw.dts,
                .duration = raw.duration,
                .flags = raw.flags,
                .pos = raw.pos,
                .skip = raw.skip,
                .new_extradata = extradata,
                .new_metadata = md,
            };
        }

        /// parse_packet with FFmpeg's FLAC parser in its complete-frames
        /// mode: the packet as it is, its duration from a valid frame
        /// header (the parser's rate filled from it when unknown).
        fn parseFlac(l: *Self, h: *Held, setup: Setup) Error!void {
            if (h.data.len == 0) {
                h.deinit(l.gpa);
                return;
            }
            const s = try l.state(h.stream);
            var parser_duration: i64 = 0;
            if (flacFrameHeader(h.data)) |fi| {
                parser_duration = fi.blocksize;
                if (s.parser_rate == 0) s.parser_rate = if (setup.sample_rate != 0) setup.sample_rate else fi.sample_rate;
            } else if (s.parser_rate == 0) s.parser_rate = setup.sample_rate;
            // COMPLETE_FRAMES keeps the demuxer's duration; else the
            // parser's, from the parser's rate, rounded down.
            if (h.duration == 0 and s.parser_rate > 0 and parser_duration > 0) {
                h.duration = rational.rescaleQRnd(parser_duration, .{ .num = 1, .den = @intCast(s.parser_rate) }, setup.time_base, .{ .mode = .down });
            }
            h.flags &= discard_flag | corrupt_flag; // the key flag is set below
            try l.computePktFields(h, setup);
            try l.parse_queue.pushBack(l.gpa, h.*);
        }

        /// compute_pkt_fields for a stream without reordering
        /// (`has_b_frames` 0) and without a parser's reordering.
        fn computePktFields(l: *Self, pkt: *Held, setup: Setup) Error!void {
            const s = try l.state(pkt.stream);
            // The duration as a fraction of a second, which the running
            // timestamp advances by.
            var inc: ?rational.Rational = null;
            // compute_frame_duration: av_get_audio_frame_duration's fixed
            // frame of an MPEG audio codec at the codec context's rate; for
            // the other supported codecs, whose frames vary in size, none.
            // A decoder's frame size (av_get_audio_frame_duration's
            // frame_size for a codec with no table of its own).
            if (pkt.duration <= 0 and setup.decoder == .aac and s.decoded_params.frame_size > 0 and s.decoded_params.sample_rate > 0 and pkt.data.len > 0) {
                const frame: i64 = s.decoded_params.frame_size;
                const rate: i64 = s.decoded_params.sample_rate;
                inc = .{ .num = @intCast(frame), .den = @intCast(rate) };
                pkt.duration = rational.rescaleRnd(1, frame * setup.time_base.den, rate * setup.time_base.num, .down);
            }
            if (pkt.duration <= 0) if (s.codec) |codec| if (codec == .mpa) {
                const ctx = codec.mpa;
                const frame: i64 = switch (ctx.codec) {
                    .mp1 => 384,
                    .mp2 => 1152,
                    .mp3 => if (ctx.sample_rate == 0) 0 else if (ctx.sample_rate <= 24000) 576 else 1152,
                };
                if (frame > 0 and ctx.sample_rate > 0) {
                    inc = .{ .num = @intCast(frame), .den = @intCast(ctx.sample_rate) };
                    pkt.duration = rational.rescaleRnd(1, frame * setup.time_base.den, @as(i64, ctx.sample_rate) * setup.time_base.num, .down);
                }
            };
            if (pkt.duration > 0 and (l.packet_buffer.len > 0 or l.parse_queue.len > 0)) l.updateInitialDurations(pkt.stream, s, pkt.duration);
            const presentation_delayed = pkt.dts != nopts and pkt.pts != nopts and pkt.pts > pkt.dts;
            if (presentation_delayed) {
                if (pkt.dts == nopts) pkt.dts = s.last_ip_pts;
                l.updateInitialTimestamps(pkt.stream, s, setup, pkt.dts, pkt.pts);
                if (pkt.dts == nopts) pkt.dts = s.cur_dts;
                if (s.last_ip_duration == 0 and pkt.duration >= 0 and pkt.duration <= std.math.maxInt(i32)) s.last_ip_duration = pkt.duration;
                if (pkt.dts != nopts) s.cur_dts = rational.satAdd(pkt.dts, s.last_ip_duration);
                if (pkt.duration >= 0 and pkt.duration <= std.math.maxInt(i32)) s.last_ip_duration = pkt.duration;
                s.last_ip_pts = pkt.pts;
            } else if (pkt.pts != nopts or pkt.dts != nopts or pkt.duration > 0) {
                if (pkt.pts == nopts) pkt.pts = pkt.dts;
                l.updateInitialTimestamps(pkt.stream, s, setup, pkt.pts, pkt.pts);
                if (pkt.pts == nopts) pkt.pts = s.cur_dts;
                pkt.dts = pkt.pts;
                // The duration in seconds: av_mul_q of `(AVRational){
                // pkt->duration, 1}`, whose int numerator truncates.
                const step = inc orelse rational.mul(.{ .num = @truncate(pkt.duration), .den = 1 }, setup.time_base);
                if (pkt.pts != nopts and step.num >= 0) s.cur_dts = rational.addStable(setup.time_base, pkt.pts, step, 1);
            }
            // The pts buffer of no delay: dts, else the pts.
            if (pkt.pts != nopts and pkt.dts == nopts) pkt.dts = pkt.pts;
            if (pkt.dts > s.cur_dts) s.cur_dts = pkt.dts;
            if (setup.media == .data or (setup.known and setup.intra_only)) pkt.flags |= key_flag;
        }

        /// update_initial_timestamps: the first real timestamp makes the
        /// held relative ones absolute and sets the start time.
        fn updateInitialTimestamps(l: *Self, stream: usize, s: *StreamState, setup: Setup, dts: i64, pts_in: i64) void {
            if (s.first_dts != nopts or dts == nopts or s.cur_dts == nopts or
                s.cur_dts < std.math.minInt(i32) + relative_ts_base or
                dts < std.math.minInt(i32) + (s.cur_dts - relative_ts_base) or isRelative(dts)) return;
            s.first_dts = dts - (s.cur_dts - relative_ts_base);
            s.cur_dts = dts;
            const shift: i64 = s.first_dts -% relative_ts_base;
            var pts = pts_in;
            if (isRelative(pts)) pts +%= shift;
            const start = l.src.startTime(stream);
            var it = l.held();
            while (it.next()) |h| {
                if (h.stream != stream) continue;
                if (isRelative(h.pts)) h.pts +%= shift;
                if (isRelative(h.dts)) h.dts +%= shift;
                if (start.* == nopts and h.pts != nopts) start.* = skipStart(setup, s.*, h.pts);
            }
            // update_dts_from_pts with no delay: a dts from the pts.
            it = l.held();
            while (it.next()) |h| {
                if (h.stream == stream and h.pts != nopts and h.dts == nopts) h.dts = h.pts;
            }
            if (start.* == nopts) start.* = skipStart(setup, s.*, pts);
        }

        /// An audio stream's start time from its first pts: past the
        /// samples the demuxer skips (saturating, so a missing pts with a
        /// skip becomes a value, as FFmpeg's does).
        fn skipStart(setup: Setup, s: StreamState, pts: i64) i64 {
            if (setup.media != .audio) return pts;
            const rate = std.math.cast(i32, setup.sample_rate) orelse return pts;
            if (rate == 0) return pts;
            return rational.satAdd(pts, rational.rescaleQ(s.skip_samples, .{ .num = 1, .den = rate }, setup.time_base));
        }

        /// update_initial_durations: the held packets without timestamps
        /// get them, counted back from the first.
        fn updateInitialDurations(l: *Self, stream: usize, s: *StreamState, duration: i64) void {
            var cur_dts: i64 = relative_ts_base;
            if (s.first_dts != nopts) {
                if (s.update_initial_durations_done) return;
                s.update_initial_durations_done = true;
                cur_dts = s.first_dts;
                var scan = l.held();
                const first = while (scan.next()) |h| {
                    if (h.stream != stream) continue;
                    if (h.pts != h.dts or h.dts != nopts or h.duration != 0) break h;
                    cur_dts -%= duration;
                } else return;
                if (first.dts != s.first_dts) return;
                s.first_dts = cur_dts;
            } else if (s.cur_dts != relative_ts_base) return;
            var reached_end = true;
            var it = l.held();
            while (it.next()) |h| {
                if (h.stream != stream) continue;
                if ((h.pts == h.dts or h.pts == nopts) and
                    (h.dts == nopts or h.dts == s.first_dts or h.dts == relative_ts_base) and
                    h.duration == 0 and rational.satAdd(cur_dts, duration) == cur_dts +% duration)
                {
                    h.dts = cur_dts;
                    h.pts = cur_dts;
                    h.duration = duration;
                } else {
                    reached_end = false;
                    break;
                }
                cur_dts = h.dts +% h.duration;
            }
            if (reached_end) s.cur_dts = cur_dts;
        }

        // Seeking (libavformat/seek.c). The source repositions itself
        // (`reposition`, `ioRepositioned` for its next read), reads a
        // timestamp for the binary search (`readTimestamp`) and runs its
        // own `read_seek` (`readSeek`, which may call `seekFrameBinary`).

        /// What a seek fails with.
        pub const SeekError = Error || error{
            /// A stream index neither -1 nor the input's (`AVERROR(EINVAL)`).
            InvalidStream,
            /// `min > ts` or `max < ts` in `seekFile` (-1).
            InvalidRange,
            /// No position was found (-1).
            SeekFailed,
        };

        /// Every stream's state exists, as FFmpeg's streams all do.
        fn ensureStates(l: *Self) Error!void {
            if (l.src.streamCount() > 0) _ = try l.state(l.src.streamCount() - 1);
        }

        /// ff_read_frame_flush: the held packets dropped and each
        /// stream's running timestamp unknown (relative before any).
        pub fn flush(l: *Self) void {
            freeQueue(&l.packet_buffer, l.gpa);
            freeQueue(&l.parse_queue, l.gpa);
            for (l.states.items) |*s| {
                // The parsers closed; the codec context stays.
                if (s.raw) |*p| p.deinit(l.gpa);
                s.raw = null;
                s.last_ip_pts = nopts;
                s.cur_dts = if (s.first_dts == nopts) relative_ts_base else nopts;
                s.skip_samples = 0;
                s.seek_discard = false;
            }
            l.eof = false;
        }

        /// avpriv_update_cur_dts: every stream's running timestamp from
        /// `timestamp` in stream `ref`'s time base.
        fn updateCurDts(l: *Self, ref: usize, timestamp: i64) void {
            const ref_tb = l.src.setup(ref).time_base;
            for (l.states.items, 0..) |*s, i| {
                const tb = l.src.setup(i).time_base;
                s.cur_dts = rational.rescale(timestamp, tb.den * @as(i64, ref_tb.num), tb.num * @as(i64, ref_tb.den));
            }
        }

        fn fileSizeOrMax(l: *Self) i64 {
            const size = l.src.fileSize() orelse return std.math.maxInt(i64);
            return std.math.cast(i64, size) orelse std.math.maxInt(i64);
        }

        const SearchContext = struct {
            l: *Self,
            stream: usize,

            fn readTimestamp(c: SearchContext, pos: *i64, pos_limit: i64) Error!i64 {
                return c.l.src.readTimestamp(c.stream, pos, pos_limit);
            }
        };

        const Search = seek.Search(SearchContext, Error, SearchContext.readTimestamp);

        /// ff_seek_frame_binary over the source's `readTimestamp`, from
        /// the bounds the index gives: false where FFmpeg's gives -1.
        pub fn seekFrameBinary(l: *Self, stream: usize, target: i64, flags: seek.Flags) Error!bool {
            try l.ensureStates();
            const bounds = l.states.items[stream].index.bounds(target, flags.any);
            const found = try Search.genSearch(.{ .l = l, .stream = stream }, l.src.dataOffset(), l.fileSizeOrMax(), target, bounds, flags.backward) orelse return false;
            try l.src.reposition(found.pos);
            l.flush();
            l.updateCurDts(stream, found.ts);
            return true;
        }

        /// av_find_default_stream_index over audio streams.
        fn defaultStream(l: *Self) ?usize {
            if (l.src.streamCount() == 0) return null;
            var best: usize = 0;
            var best_score: i32 = std.math.minInt(i32);
            for (0..l.src.streamCount()) |i| {
                const s = &l.states.items[i];
                var score: i32 = 200; // not discarded
                if (l.src.setup(i).known and l.sampleRate(i, s) != 0) score += 50;
                if (s.codec_info_nb_frames > 0) score += 12;
                if (score > best_score) {
                    best_score = score;
                    best = i;
                }
            }
            return best;
        }

        /// `av_seek_frame` (seek_frame_internal): by byte position, else
        /// the demuxer's own seek, else seek_frame_generic over the index.
        pub fn seekFrame(l: *Self, stream: i32, timestamp: i64, flags: seek.Flags) SeekError!void {
            if (stream < -1 or stream >= l.src.streamCount()) return error.InvalidStream;
            try l.ensureStates();
            if (flags.byte) {
                l.flush();
                return l.seekFrameByte(timestamp);
            }
            var index: usize = undefined;
            var ts = timestamp;
            if (stream < 0) {
                index = l.defaultStream() orelse return error.SeekFailed;
                ts = seek.defaultStreamTimestamp(ts, l.src.setup(index).time_base);
            } else index = @intCast(stream);
            l.flush();
            if (try l.src.readSeek(l, index, ts, flags)) return;
            // AVFMT_NOBINSEARCH: the generic search.
            l.flush();
            return l.seekFrameGeneric(index, ts, flags);
        }

        /// seek_frame_byte: the position clamped to the data.
        fn seekFrameByte(l: *Self, pos_in: i64) Error!void {
            var pos = pos_in;
            const pos_min = l.src.dataOffset();
            const pos_max = l.fileSizeOrMax() - 1;
            if (pos < pos_min) {
                pos = pos_min;
            } else if (pos > pos_max) {
                pos = pos_max;
            }
            try l.src.reposition(pos);
            l.src.ioRepositioned();
        }

        /// seek_frame_generic: the index entry for `timestamp`, read
        /// forward from the last one (or the data's start) when it is
        /// not there yet.
        fn seekFrameGeneric(l: *Self, stream: usize, timestamp: i64, flags: seek.Flags) SeekError!void {
            var found = l.states.items[stream].index.search(timestamp, flags);
            const count = l.states.items[stream].index.entries.items.len;
            if (found == null and count > 0 and timestamp < l.states.items[stream].index.entries.items[0].timestamp) return error.SeekFailed;
            if (found == null or found.? == count - 1) {
                if (count > 0) {
                    const ie = l.states.items[stream].index.entries.items[count - 1];
                    try l.src.reposition(ie.pos);
                    l.src.ioRepositioned();
                    l.updateCurDts(stream, ie.timestamp);
                } else {
                    try l.src.reposition(l.src.dataOffset());
                    l.src.ioRepositioned();
                }
                var nonkey: u32 = 0;
                while (true) {
                    // A read error ends the scan, as the end does.
                    const p = (l.next() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => break,
                    }) orelse break;
                    const dts = p.dts orelse continue;
                    if (p.stream == stream and dts > timestamp) {
                        if (p.flags & key_flag != 0) break;
                        nonkey += 1;
                        if (nonkey > 1001) break;
                    }
                }
                try l.ensureStates();
                found = l.states.items[stream].index.search(timestamp, flags);
            }
            const index = found orelse return error.SeekFailed;
            l.flush();
            if (try l.src.readSeek(l, stream, timestamp, flags)) return;
            const ie = l.states.items[stream].index.entries.items[index];
            try l.src.reposition(ie.pos);
            l.src.ioRepositioned();
            l.updateCurDts(stream, ie.timestamp);
        }

        /// seek_preroll: the largest audio pre-roll, in the seek's units.
        fn seekPreroll(l: *Self, stream: i32) i64 {
            const unit: rational.Rational = if (stream >= 0) l.src.setup(@intCast(stream)).time_base else .{ .num = 1, .den = seek.time_base_units };
            var preroll: i64 = 0;
            for (0..l.src.streamCount()) |i| {
                const setup = l.src.setup(i);
                const rate = l.sampleRate(i, &l.states.items[i]);
                const samples = streamPreroll(setup, l.states.items[i]);
                if (!setup.known or samples == 0 or rate == 0) continue;
                const v = rational.rescaleQRnd(samples, .{ .num = 1, .den = @intCast(rate) }, unit, .{ .mode = .up });
                preroll = @max(preroll, v);
            }
            return preroll;
        }

        /// `avformat_seek_file`: aimed early by the pre-roll (not before
        /// `min_ts`, nor before the start unless `ts` is), through
        /// seek_file's fallback onto `seekFrame`, again at `ts` when that
        /// fails; then each stream's first packet discards what the seek
        /// asks (request_seek_discard).
        pub fn seekFile(l: *Self, stream: i32, min_ts: i64, ts: i64, max_ts: i64, flags_in: seek.Flags) SeekError!void {
            if (min_ts > ts or max_ts < ts) return error.InvalidRange;
            if (stream < -1 or stream >= l.src.streamCount()) return error.InvalidStream;
            try l.ensureStates();
            var flags = flags_in;
            flags.backward = false;
            var target = ts;
            var target_max = max_ts;
            if (!flags.byte) {
                const preroll = l.seekPreroll(stream);
                const start = if (stream >= 0) l.src.startTime(@intCast(stream)).* else l.start_time;
                target = @max(rational.satSub(ts, preroll), min_ts);
                if (start != nopts) target = @max(target, @min(start, ts));
                if (max_ts != std.math.maxInt(i64)) target_max = rational.satSub(max_ts, rational.satSub(ts, target));
            }
            _ = seek.seekFile(l, seekFrameForFile, stream, min_ts, target, target_max, flags) catch |err| retry: {
                if (err == error.OutOfMemory or target == ts) return err;
                target = ts;
                break :retry try seek.seekFile(l, seekFrameForFile, stream, min_ts, ts, max_ts, flags);
            };
            l.requestSeekDiscard(stream, target, flags);
        }

        fn seekFrameForFile(l: *Self, stream: i32, ts: i64, flags: seek.Flags) SeekError!void {
            return l.seekFrame(stream, ts, flags);
        }

        /// request_seek_discard: each stream's next packet discards its
        /// pre-roll, unless the seek went to the stream's start.
        fn requestSeekDiscard(l: *Self, stream: i32, ts: i64, flags: seek.Flags) void {
            const tb: rational.Rational = if (stream >= 0) l.src.setup(@intCast(stream)).time_base else .{ .num = 1, .den = seek.time_base_units };
            for (l.states.items, 0..) |*s, i| {
                const start = l.src.startTime(i).*;
                s.seek_discard = true;
                s.seek_to_start = !flags.byte and start != nopts and rational.compareTs(ts, tb, start, l.src.setup(i).time_base) <= 0;
            }
        }
    };
}

/// The frame header FFmpeg's FLAC parser accepts (frame_header_is_valid).
fn flacFrameHeader(data: []const u8) ?flac.FrameInfo {
    var r = bits.BitReader.init(data) catch return null;
    return switch (flac.decodeFrameHeader(&r)) {
        .ok => |fi| fi,
        else => null,
    };
}

fn validFlacFrame(data: []const u8) bool {
    return flacFrameHeader(data) != null;
}

test "packets held across the read-ahead and the parser's queue get their timestamps as one list" {
    const gpa = std.testing.allocator;
    const mp3 = @import("mp3.zig");
    const fixtures = @import("../testing/fixtures.zig");
    // 70000 bytes of junk before mp3_mpeg1_l3_stereo: the read-ahead
    // stops with the first frames' packets, none with a timestamp yet,
    // split between its buffer and the parser's queue.
    const frames = fixtures.mp3.bytes("mp3_mpeg1_l3_stereo");
    const junk = 70000;
    const bytes = try gpa.alloc(u8, junk + frames.len);
    defer gpa.free(bytes);
    for (bytes[0..junk], 0..) |*b, i| b.* = @intCast(i % 7);
    @memcpy(bytes[junk..], frames);
    var reader: std.Io.Reader = .fixed(bytes);
    const d = try mp3.Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
    defer d.deinit();
    var layer = Layer(mp3.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    // `ffmpeg -i <bytes> -c copy -f framecrc`: 24 packets, the first
    // holding the junk, each 368640 ticks of 1/14112000 from 0.
    var count: i64 = 0;
    while (try layer.next()) |p| : (count += 1) {
        if (count == 0) try std.testing.expectEqual(70418, p.data.len);
        try std.testing.expectEqual(count * 368640, p.pts);
        try std.testing.expectEqual(count * 368640, p.dts);
        try std.testing.expectEqual(368640, p.duration);
    }
    try std.testing.expectEqual(24, count);
}

const test_support = struct {
    const mp3 = @import("mp3.zig");
    const ogg = @import("ogg.zig");
    const fixtures = @import("../testing/fixtures.zig");
    const hostile = @import("../testing/hostile.zig");
    const TestPlan = hostile.TestPlan;
    const drawTestPlan = hostile.drawTestPlan;
    const seedValues = hostile.seedValues;
    const runTestPlan = hostile.runTestPlan;

    fn openMp3(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, plan: TestPlan) error{OutOfMemory}!u32 {
        var reader: std.Io.Reader = .fixed(bytes);
        const opened = if (seekable) mp3.Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{}) else mp3.Demuxer.init(gpa, &reader, .{});
        const d = opened catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return 0,
        };
        defer d.deinit();
        return runTestPlan(mp3.Demuxer, gpa, d, plan);
    }

    fn openOgg(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, plan: TestPlan) error{OutOfMemory}!u32 {
        var reader: std.Io.Reader = .fixed(bytes);
        const opened = if (seekable) ogg.Demuxer.initSeekable(gpa, &reader, .fixed(&reader)) else ogg.Demuxer.init(gpa, &reader);
        const d = opened catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return 0,
        };
        defer d.deinit();
        return runTestPlan(ogg.Demuxer, gpa, d, plan);
    }

    /// The bytes as MP3 or Ogg (the first value), from a file or a pipe
    /// (the second), then `drawTestPlan`'s plan.
    fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
        _ = context;
        _ = try fuzzRun(smith);
    }

    fn fuzzRun(smith: *std.testing.Smith) error{OutOfMemory}!u32 {
        var input: [16710 + hostile.max_growth]u8 = undefined;
        const len = smith.slice(&input);
        const is_ogg = smith.value(bool);
        const seekable = !smith.value(bool);
        const plan = drawTestPlan(smith, seekable);
        const bytes = input[0..len];
        return if (is_ogg)
            openOgg(std.testing.allocator, bytes, seekable, plan)
        else
            openMp3(std.testing.allocator, bytes, seekable, plan);
    }

    /// A seed: the bytes, the format (1 Ogg), 1 for a pipe, the seek.
    fn seed(comptime bytes: []const u8, comptime is_ogg: bool, comptime pipe: bool, comptime s: ?TestPlan.Seek) []const u8 {
        return hostile.fuzzSeed(bytes, &([2]u64{ @intFromBool(is_ogg), @intFromBool(pipe) } ++ seedValues(s)));
    }

    const corpus: []const []const u8 = &.{
        seed(fixtures.mp3.bytes("mp3_six_frames"), false, false, .{ .ts = 3 * 368640 }),
        seed(fixtures.mp3.bytes("mp3_junk_between"), false, false, .{ .ts = 10 * 368640, .flags = .{ .backward = true } }),
        seed(fixtures.mp3.bytes("mp3_layer_change"), false, true, null),
        seed(fixtures.mp3.bytes("mp3_xing_lame"), false, false, .{ .file = false, .stream = 0, .ts = 5000, .flags = .{ .byte = true } }),
        seed(fixtures.mp3.bytes("mp3_itunsmpb"), false, false, .{ .file = false, .stream = 0, .ts = 0, .flags = .{ .any = true } }),
        seed(fixtures.ogg.bytes("ogg_flac_stereo"), true, true, null),
        seed(fixtures.ogg.bytes("ogg_multiplexed"), true, false, .{ .ts = 2000, .stream = 1 }),
        seed(fixtures.ogg.bytes("ogg_chained_opus"), true, false, .{ .ts = 4000 }),
        seed(fixtures.ogg.bytes("ogg_opus_empty_first_packet"), true, true, null),
        seed(fixtures.ogg.bytes("ogg_flac_comment_twice"), true, true, null),
        seed(fixtures.ogg.bytes("ogg_vorbis_stereo"), true, false, .{ .file = false, .stream = 0, .ts = 1000, .flags = .{ .backward = true } }),
    };
};

test "a failed MPEG audio parse frees the demuxer's packet once (allocation failures, review M2)" {
    const support = test_support;
    inline for (.{ "mp3_six_frames", "mp3_junk_between", "mp3_layer_change" }) |name| {
        const bytes = support.fixtures.mp3.bytes(name);
        try support.hostile.checkAll(support.openMp3, .{ bytes, false, support.TestPlan{} });
        try support.hostile.checkAll(support.openMp3, .{ bytes, true, support.TestPlan{ .seek = .{ .ts = 4 * 368640, .exact = true } } });
        try support.hostile.checkAll(support.openMp3, .{ bytes, true, support.TestPlan{ .seek = .{ .file = false, .stream = 0, .ts = 2000, .flags = .{ .byte = true } } } });
    }
}

test "the read-ahead ends at a packet the demuxer refuses, and reading goes on after it (review M3)" {
    const support = test_support;
    const bytes = support.fixtures.ogg.bytes("ogg_opus_empty_first_packet");
    var reader: std.Io.Reader = .fixed(bytes);
    const d = try support.ogg.Demuxer.init(std.testing.allocator, &reader);
    defer d.deinit();
    var l = Layer(support.ogg.Demuxer).init(std.testing.allocator, d);
    defer l.deinit();
    try l.findStreamInfo();
    // vectors/ogg.txt: twelve packets, the first at -312.
    var count: usize = 0;
    while (try l.next()) |p| : (count += 1) {
        if (count == 0) try std.testing.expectEqual(-312, p.pts);
    }
    try std.testing.expectEqual(12, count);
    try support.hostile.checkAll(support.openOgg, .{ bytes, false, support.TestPlan{} });
    try support.hostile.checkAll(support.openOgg, .{ bytes, true, support.TestPlan{ .seek = .{ .ts = 5000, .exact = true } } });
}

test "fuzz: the generic layer over MP3 and Ogg input, from a file or a pipe, with a seek" {
    try std.testing.fuzz({}, test_support.fuzzOne, .{ .corpus = test_support.corpus });
}

test "every seed of the generic layer's fuzz entry opens and returns packets" {
    for (test_support.corpus, 0..) |seed, i| {
        errdefer std.debug.print("generic layer fuzz seed {d}\n", .{i});
        var smith: std.testing.Smith = .{ .in = seed };
        try std.testing.expect(try test_support.fuzzRun(&smith) > 0);
    }
}

test "mutation smoke: the generic layer over mutated MP3 and Ogg seeds" {
    try test_support.hostile.mutationSmoke({}, test_support.fuzzOne, test_support.corpus, 256, 0x64656d7578);
}

fn checkFlacFlags(gpa: std.mem.Allocator) !void {
    const ogg = @import("ogg.zig");
    const fixture = @import("../testing/fixtures.zig").ogg.bytes("ogg_flac_stereo");
    for ([_]u32{ 0, corrupt_flag, discard_flag, corrupt_flag | discard_flag }) |flags| {
        for ([_]bool{ false, true }) |read_ahead| {
            var reader: std.Io.Reader = .fixed(fixture);
            const source = try ogg.Demuxer.init(gpa, &reader);
            defer source.deinit();
            var layer = Layer(ogg.Demuxer).init(gpa, source);
            defer layer.deinit();
            var raw = (try source.next()).?;
            raw.flags = flags;
            try std.testing.expect(validFlacFrame(raw.data));
            var held = try layer.own(raw);
            layer.parseFlac(&held, source.setup(raw.stream)) catch |err| {
                held.deinit(gpa);
                return err;
            };
            if (read_ahead) try layer.findStreamInfo();
            const packet = (try layer.next()).?;
            try std.testing.expectEqual(flags | key_flag, packet.flags);
        }
    }
}

test "review: FLAC header parsing preserves discard and corrupt through queues" {
    try checkFlacFlags(std.testing.allocator);
    try @import("../testing/hostile.zig").checkAll(checkFlacFlags, .{});
}
