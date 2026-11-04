// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/demux.c (read_frame_internal, parse_packet, compute_pkt_fields,
// update_initial_timestamps, update_initial_durations, select_from_pts_buffer,
// update_dts_from_pts, av_read_frame, avformat_find_stream_info's read-ahead,
// has_codec_parameters) and libavcodec/flac_parser.c's complete-frames path
// at the pinned reference revision describe the behavior, restated here.
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

const std = @import("std");
const flac = @import("../codec/flac.zig");
const bits = @import("../codec/bits.zig");
const rational = @import("../core/rational.zig");

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
    /// The reference build has a decoder for the codec, which
    /// avformat_find_stream_info runs; without one, a known rate and
    /// channel count are the codec parameters it needs.
    has_decoder: bool = false,
    /// `codecpar->bit_rate`, 0 when unknown.
    bit_rate: i64 = 0,
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
    /// try_decode_frame: 0 untried, 1 a decoder ran and set the format,
    /// -1 no decoder.
    found_decoder: i8 = 0,
    decoded: bool = false,
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
                // try_decode_frame: a decoder sets the sample format from
                // a frame it decodes; without one, the stream needs none.
                if (s.found_decoder == 0) s.found_decoder = if (setup.has_decoder) 1 else -1;
                if (setup.has_decoder and !s.decoded and setup.parse_flac and validFlacFrame(pkt.data)) s.decoded = true;
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
            if (setup.channels == 0) return false;
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
        /// parser or compute_pkt_fields; null at the end.
        fn readFrameInternal(l: *Self) Error!?Held {
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
                return h;
            }
            if (l.parse_queue.items.len == 0) return null;
            return l.parse_queue.orderedRemove(0);
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
