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

pub const nopts: i64 = std.math.minInt(i64);
/// libavformat's base for timestamps counted before the first is known.
pub const relative_ts_base: i64 = std.math.maxInt(i64) - (1 << 48);

fn isRelative(ts: i64) bool {
    return ts > relative_ts_base - (1 << 48);
}

/// avformat_find_stream_info's defaults.
const probesize = 5_000_000;
const max_analyze_duration = 5 * 1_000_000;
const max_ts_probe = 50;

/// What the layer needs to know of a stream.
pub const Setup = struct {
    /// False for a stream whose codec is unknown (`AV_CODEC_ID_NONE`).
    known: bool,
    time_base: rational.Rational,
    sample_rate: u32,
    channels: u8,
    /// FLAC in a container: FFmpeg's FLAC parser reads each packet's
    /// frame header (AVSTREAM_PARSE_HEADERS).
    parse_flac: bool = false,
    /// MPEG audio read raw: FFmpeg's mpegaudio parser splits the bytes into
    /// frames and fills the codec parameters (AVSTREAM_PARSE_FULL_RAW).
    parse_mpegaudio: bool = false,
    /// A codec whose frame size libavformat could determine
    /// (`determinable_frame_size`) with no decoder to give it: the
    /// parameters never complete, so the read-ahead runs to its end.
    frame_size_unknown: bool = false,
    /// The gapless counts in samples: `start_skip_samples`, skipped from
    /// the packet at timestamp 0, and the discard window
    /// `first_discard_sample` to `last_discard_sample` (none when 0).
    start_skip_samples: i64 = 0,
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
};

pub const key_flag: u32 = 1;

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
    /// FFmpeg's mpegaudio parser (`sti->parser`), closed by a flush, and
    /// the codec context it fills (`sti->avctx`), which stays.
    mpa: ?MpaParser = null,
    codec: ?mpegaudio.Context = null,
    /// The samples the next packet's skip-samples side data discards,
    /// and the request a seek leaves for it (`seek_discard`,
    /// `seek_to_start`).
    skip_samples: i64 = 0,
    seek_discard: bool = false,
    seek_to_start: bool = false,
};

/// A parser with `av_parser_parse2`'s byte offsets.
const MpaParser = struct {
    parser: mpegaudio.Parser = .{},
    cur_offset: i64,
    next_frame_offset: i64,
    frame_offset: i64 = 0,

    fn deinit(p: *MpaParser, gpa: std.mem.Allocator) void {
        p.parser.deinit(gpa);
    }
};

/// A stream's codec parameters as libavformat's codec context has them:
/// the demuxer's, then the parser's.
pub const CodecParams = struct {
    /// The MPEG audio codec, when the parser chose one.
    mpa_codec: ?mpegaudio.Codec,
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
                if (s.mpa) |*p| p.deinit(l.gpa);
            }
            l.states.deinit(l.gpa);
        }

        /// The stream's codec parameters (`codecpar`, which follows the
        /// parser's codec context).
        pub fn codecParams(l: *Self, i: usize) Error!CodecParams {
            const setup = l.src.setup(i);
            const s = try l.state(i);
            if (s.codec) |c| return .{ .mpa_codec = c.codec, .sample_rate = c.sample_rate, .channels = c.channels, .bit_rate = c.bit_rate };
            return .{ .mpa_codec = null, .sample_rate = setup.sample_rate, .channels = setup.channels, .bit_rate = setup.bit_rate };
        }

        fn state(l: *Self, i: usize) Error!*StreamState {
            while (l.states.items.len <= i) try l.states.append(l.gpa, .{});
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
            while (true) {
                var all = true;
                for (0..l.src.streamCount()) |i| {
                    const s = try l.state(i);
                    const setup = l.src.setup(i);
                    if (!hasCodecParameters(setup, s.*)) {
                        all = false;
                        break;
                    }
                    if (s.first_dts == nopts and s.codec_info_nb_frames < max_ts_probe) {
                        all = false;
                        break;
                    }
                }
                if (all) break;
                if (read_size >= probesize) break;
                var h = try l.readFrameInternal() orelse break;
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
                    if (t >= max_analyze_duration) break;
                    if (pkt.duration > 0 and pkt.duration < std.math.maxInt(i64) - s.codec_info_duration) s.codec_info_duration += pkt.duration;
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
                    }
                }
                if (setup.decoder == .flac and !s.decoded and setup.parse_flac and validFlacFrame(pkt.data)) s.decoded = true;
                s.codec_info_nb_frames += 1;
            }
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

        /// update_stream_timings over audio streams (none of them text).
        fn updateStreamTimings(l: *Self, file_size: i64) void {
            var start_time: i64 = std.math.maxInt(i64);
            var end_time: i64 = std.math.minInt(i64);
            var duration: i64 = std.math.minInt(i64);
            for (0..l.src.streamCount()) |i| {
                const tb = l.src.setup(i).time_base;
                const st_start = l.src.startTime(i).*;
                const st_duration = l.src.durationOf(i).*;
                if (st_start != nopts and tb.den != 0) {
                    const start1 = rational.rescaleQ(st_start, tb, time_base_q);
                    start_time = @min(start_time, start1);
                    var end1 = rational.rescaleQRnd(st_duration, tb, time_base_q, .{ .mode = .near_inf, .pass_minmax = true });
                    if (end1 != nopts and (if (end1 > 0) start1 <= std.math.maxInt(i64) - end1 else start1 >= std.math.minInt(i64) - end1)) {
                        end1 += start1;
                        end_time = @max(end_time, end1);
                    }
                }
                if (st_duration != nopts) duration = @max(duration, rational.rescaleQ(st_duration, tb, time_base_q));
            }
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
                    const rate = if (i < l.states.items.len) if (l.states.items[i].codec) |c| c.bit_rate else l.src.setup(i).bit_rate else l.src.setup(i).bit_rate;
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

        /// has_codec_parameters for an audio stream.
        fn hasCodecParameters(setup: Setup, s: StreamState) bool {
            if (!setup.known) return false;
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
                if (setup.parse_flac) {
                    try l.parseFlac(&h, setup);
                    continue;
                }
                if (setup.parse_mpegaudio) {
                    defer h.deinit(l.gpa);
                    try l.parseMpa(h.stream, h.data, h.pos, setup);
                    continue;
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
            if (s.codec) |c| return c.sample_rate;
            const rate = l.src.setup(i).sample_rate;
            return if (rate != 0) rate else s.parser_rate;
        }

        /// read_frame_internal at the end (or an error): parse_packet with
        /// `flush` for every open parser, then the parser closed.
        fn flushParsers(l: *Self) Error!void {
            for (0..l.states.items.len) |i| {
                const s = &l.states.items[i];
                if (s.mpa == null) continue;
                try l.parseMpa(i, &.{}, -1, l.src.setup(i));
                if (s.mpa) |*p| p.deinit(l.gpa);
                s.mpa = null;
            }
        }

        /// parse_packet with FFmpeg's mpegaudio parser
        /// (AVSTREAM_PARSE_FULL_RAW): each frame a packet at the parser's
        /// frame offset, its duration the parser's frame (rounded down in
        /// the time base), timestamps from compute_pkt_fields; the codec
        /// context follows the frames. `data` empty flushes.
        fn parseMpa(l: *Self, stream: usize, data_in: []const u8, pos: i64, setup: Setup) Error!void {
            const s = try l.state(stream);
            if (s.codec == null) s.codec = .{ .sample_rate = setup.sample_rate, .channels = setup.channels, .bit_rate = setup.bit_rate };
            if (s.mpa == null) {
                if (data_in.len == 0) return;
                // PARSER_FLAG_FETCHED_OFFSET: the first packet's position.
                s.mpa = .{ .cur_offset = pos, .next_frame_offset = pos };
            }
            const flushing = data_in.len == 0;
            var data = data_in;
            var got_output = flushing;
            while (data.len > 0 or (flushing and got_output)) {
                const p = &s.mpa.?;
                const res = try p.parser.parse(l.gpa, &s.codec.?, data);
                data = data[res.consumed..];
                got_output = res.frame != null;
                const frame = res.frame orelse {
                    p.cur_offset += @intCast(res.consumed);
                    continue;
                };
                p.frame_offset = p.next_frame_offset;
                p.next_frame_offset = p.cur_offset + @as(i64, @intCast(res.consumed));
                p.cur_offset += @intCast(res.consumed);
                const ctx = s.codec.?;
                var h: Held = .{
                    .stream = stream,
                    .data = try l.gpa.dupe(u8, frame),
                    .pts = nopts,
                    .dts = nopts,
                    .duration = 0,
                    .flags = 0,
                    .pos = p.frame_offset,
                    .skip = null,
                    .new_extradata = null,
                    .new_metadata = null,
                };
                errdefer h.deinit(l.gpa);
                if (ctx.sample_rate > 0 and p.parser.duration > 0) {
                    h.duration = rational.rescaleQRnd(p.parser.duration, .{ .num = 1, .den = @intCast(ctx.sample_rate) }, setup.time_base, .{ .mode = .down });
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
                const duration = @max(0, rational.rescale(h.duration, setup.time_base.num * @as(i64, rate), setup.time_base.den));
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
                        skip = @max(skip, setup.seek_preroll);
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
            h.flags &= 2; // DISCARD and CORRUPT pass; the key flag is set below
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
            if (pkt.duration <= 0) if (s.codec) |ctx| {
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
            // Every supported audio codec is intra-only.
            if (setup.known) pkt.flags |= key_flag;
        }

        /// update_initial_timestamps: the first real timestamp makes the
        /// held relative ones absolute and sets the start time.
        fn updateInitialTimestamps(l: *Self, stream: usize, s: *StreamState, setup: Setup, dts: i64, pts_in: i64) void {
            _ = setup;
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
                if (start.* == nopts and h.pts != nopts) start.* = h.pts;
            }
            // update_dts_from_pts with no delay: a dts from the pts.
            it = l.held();
            while (it.next()) |h| {
                if (h.stream == stream and h.pts != nopts and h.dts == nopts) h.dts = h.pts;
            }
            if (start.* == nopts) start.* = pts;
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
                if (s.mpa) |*p| p.deinit(l.gpa);
                s.mpa = null;
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
                if (!setup.known or setup.seek_preroll == 0 or rate == 0) continue;
                const v = rational.rescaleQRnd(setup.seek_preroll, .{ .num = 1, .den = @intCast(rate) }, unit, .{ .mode = .up });
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
