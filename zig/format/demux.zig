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
    /// The samples the next packet's skip-samples side data discards,
    /// and the request a seek leaves for it (`seek_discard`,
    /// `seek_to_start`).
    skip_samples: i64 = 0,
    seek_discard: bool = false,
    seek_to_start: bool = false,
};

pub fn Layer(comptime Source: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        src: *Source,
        states: std.ArrayList(StreamState) = .empty,
        /// avformat_find_stream_info's packets, returned first.
        packet_buffer: std.ArrayList(Held) = .empty,
        /// The parser's output (FLAC streams), before it is returned.
        parse_queue: std.ArrayList(Held) = .empty,
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
            for (l.packet_buffer.items) |*h| h.deinit(l.gpa);
            for (l.parse_queue.items) |*h| h.deinit(l.gpa);
            l.packet_buffer.deinit(l.gpa);
            l.parse_queue.deinit(l.gpa);
            if (l.current) |*h| h.deinit(l.gpa);
            for (l.states.items) |*s| s.index.deinit(l.gpa);
            l.states.deinit(l.gpa);
        }

        fn state(l: *Self, i: usize) Error!*StreamState {
            while (l.states.items.len <= i) try l.states.append(l.gpa, .{});
            return &l.states.items[i];
        }

        /// The packets compute_pkt_fields' look-backs reach: the
        /// read-ahead's, else the parser's.
        fn heldList(l: *Self) []Held {
            return if (l.packet_buffer.items.len > 0) l.packet_buffer.items else l.parse_queue.items;
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
                const h = try l.readFrameInternal() orelse break;
                try l.packet_buffer.append(l.gpa, h);
                const pkt = &l.packet_buffer.items[l.packet_buffer.items.len - 1];
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
                    const rate = l.src.setup(i).bit_rate;
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
            const h = if (l.packet_buffer.items.len > 0)
                l.packet_buffer.orderedRemove(0)
            else
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
            while (l.parse_queue.items.len == 0) {
                if (l.eof) return null;
                const raw = l.src.next() catch |err| {
                    // The parsers flushed (nothing for complete frames),
                    // then the error, unless the parser still holds a
                    // packet, which goes first.
                    if (l.parse_queue.items.len > 0) break;
                    return err;
                } orelse {
                    l.eof = true;
                    break;
                };
                var h = try l.own(raw);
                errdefer h.deinit(l.gpa);
                const setup = l.src.setup(h.stream);
                if (setup.parse_flac) {
                    try l.parseFlac(&h, setup);
                    continue;
                }
                try l.computePktFields(&h, setup);
                // AVFMT_GENERIC_INDEX, which every format here has.
                if (h.flags & key_flag != 0 and h.dts != nopts) try l.addIndexEntry(h.stream, h.pos, h.dts);
                return h;
            }
            if (l.parse_queue.items.len == 0) return null;
            return l.parse_queue.orderedRemove(0);
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
            const rate = l.src.setup(i).sample_rate;
            return if (rate != 0) rate else s.parser_rate;
        }

        /// read_frame_internal's skip samples: after a seek, the priming
        /// before the start time, the initial padding on the stream's
        /// first packet, else the decoder's pre-roll, made side data with
        /// what the demuxer set (the formats here set no discard range).
        fn injectSkip(l: *Self, h: *Held) Error!void {
            const s = try l.state(h.stream);
            const setup = l.src.setup(h.stream);
            if (s.seek_discard) {
                const rate = l.sampleRate(h.stream, s);
                if (setup.known and rate > 0) {
                    const start = l.src.startTime(h.stream).*;
                    const first = h.dts != nopts and s.first_dts != nopts and h.dts <= s.first_dts;
                    const in_priming = h.pts != nopts and start != nopts and h.pts < start;
                    var skip: i64 = 0;
                    // ts_to_samples: the priming ends at the start time.
                    if (in_priming) skip = rational.rescale(start - h.pts, setup.time_base.num * @as(i64, rate), setup.time_base.den);
                    if (first) {
                        if (setup.initial_padding > 0) skip = setup.initial_padding;
                    } else if (!(s.seek_to_start and h.pts != nopts and !in_priming)) {
                        skip = @max(skip, setup.seek_preroll);
                    }
                    s.skip_samples = @max(s.skip_samples, @min(skip, std.math.maxInt(i32)));
                }
                s.seek_discard = false;
            }
            s.skip_samples = @max(0, s.skip_samples);
            if (s.skip_samples == 0) return;
            var padding: u32 = 0;
            if (h.skip) |kept| {
                // FFmpeg reads the demuxer's count as an int.
                const demuxer_skip: i32 = @bitCast(kept[0]);
                s.skip_samples = @max(s.skip_samples, demuxer_skip);
                padding = kept[1];
            }
            h.skip = .{ @intCast(s.skip_samples), padding };
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
            try l.parse_queue.append(l.gpa, h.*);
        }

        /// compute_pkt_fields for a stream without reordering
        /// (`has_b_frames` 0) and without a parser's reordering.
        fn computePktFields(l: *Self, pkt: *Held, setup: Setup) Error!void {
            const s = try l.state(pkt.stream);
            // compute_frame_duration gives nothing for the supported
            // codecs, whose frames vary in size.
            if (pkt.duration > 0 and l.heldList().len > 0) l.updateInitialDurations(pkt.stream, s, pkt.duration);
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
                const inc = rational.mul(.{ .num = @truncate(pkt.duration), .den = 1 }, setup.time_base);
                if (pkt.pts != nopts and inc.num >= 0) s.cur_dts = rational.addStable(setup.time_base, pkt.pts, inc, 1);
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
            for (l.heldList()) |*h| {
                if (h.stream != stream) continue;
                if (isRelative(h.pts)) h.pts +%= shift;
                if (isRelative(h.dts)) h.dts +%= shift;
                if (start.* == nopts and h.pts != nopts) start.* = h.pts;
            }
            // update_dts_from_pts with no delay: a dts from the pts.
            for (l.heldList()) |*h| {
                if (h.stream == stream and h.pts != nopts and h.dts == nopts) h.dts = h.pts;
            }
            if (start.* == nopts) start.* = pts;
        }

        /// update_initial_durations: the held packets without timestamps
        /// get them, counted back from the first.
        fn updateInitialDurations(l: *Self, stream: usize, s: *StreamState, duration: i64) void {
            const list = l.heldList();
            var cur_dts: i64 = relative_ts_base;
            var start_index: usize = 0;
            if (s.first_dts != nopts) {
                if (s.update_initial_durations_done) return;
                s.update_initial_durations_done = true;
                cur_dts = s.first_dts;
                var found: ?usize = null;
                for (list, 0..) |*h, idx| {
                    if (h.stream != stream) continue;
                    if (h.pts != h.dts or h.dts != nopts or h.duration != 0) {
                        found = idx;
                        break;
                    }
                    cur_dts -%= duration;
                }
                const f = found orelse return;
                if (list[f].dts != s.first_dts) return;
                s.first_dts = cur_dts;
                start_index = 0;
            } else if (s.cur_dts != relative_ts_base) return;
            var reached_end = true;
            for (list[start_index..]) |*h| {
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
            for (l.packet_buffer.items) |*h| h.deinit(l.gpa);
            for (l.parse_queue.items) |*h| h.deinit(l.gpa);
            l.packet_buffer.clearRetainingCapacity();
            l.parse_queue.clearRetainingCapacity();
            for (l.states.items) |*s| {
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
