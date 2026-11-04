// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/flacdec.c (flac_read_header, flac_probe, raw_flac_probe),
// rawdec.c (ff_raw_read_partial_packet), demux.c (read_frame_internal,
// parse_packet, compute_pkt_fields, update_initial_timestamps,
// update_initial_durations, avformat_find_stream_info's read-ahead,
// av_read_frame) and libavcodec/flac.c at the pinned reference revision
// describe the behavior, restated here; see
// zig/testing/fixtures/flac/README.md.
//! The FLAC demuxer (TODO.md T26a): native FLAC's metadata, then packets as
//! libavformat gives them to the ffmpeg program.
//!
//! The header is `fLaC` and metadata blocks, STREAMINFO first; the contract
//! in zig/testing/fixtures/flac/README.md says which are accepted. The
//! frames that follow go through FFmpeg's FLAC parser (flac_parser.zig) in
//! 1024-byte reads, and each packet gets libavformat's timestamps for a
//! parsed raw stream: the parser's frame-number timestamp where it has
//! one, otherwise the running time, kept relative until the first real
//! timestamp, as avformat_find_stream_info's read-ahead and av_read_frame
//! leave them.
//!
//! The demuxer allocates its parser's buffer, which holds about ten frames,
//! and the packets it has read ahead; a returned packet is borrowed until the
//! next call.

const std = @import("std");
const flac = @import("../codec/flac.zig");
const flac_parser = @import("../codec/flac_parser.zig");
const packet = @import("../core/packet.zig");
const time = @import("../core/time.zig");
const channel_layout = @import("../core/channel_layout.zig");

/// Contract errors (see the FLAC fixture README), plus `IoFailure` for a
/// failing reader and `OutOfMemory`.
pub const Error = error{
    InvalidFlac,
    Truncated,
    UnsupportedFormat,
    IoFailure,
    OutOfMemory,
};

/// The stream STREAMINFO describes.
pub const Info = struct {
    stream_info: flac.StreamInfo,
    layout: channel_layout.Layout,
    /// 1 / the sample rate.
    time_base: time.TimeBase,
    /// Samples per channel, when STREAMINFO gives them.
    duration: ?u64,
};

/// FFmpeg's `RAW_PACKET_SIZE`: the demuxer's reads.
pub const raw_packet_size = 1024;

/// The most bytes `probeScore` reads.
pub const probe_bytes = 4 + 4 + 13;

/// FFmpeg's content probe (flac_probe, raw_flac_probe), for the first bytes
/// of a stream: `fLaC` and a plausible STREAMINFO score 100, other `fLaC`
/// input 50, and a frame header at the start 13.
pub fn probeScore(head: []const u8) u8 {
    // The probe reads a zero-padded buffer.
    var padded: [probe_bytes]u8 = @splat(0);
    @memcpy(padded[0..@min(head.len, probe_bytes)], head[0..@min(head.len, probe_bytes)]);
    if (head.len > 0 and std.mem.readInt(u16, padded[0..2], .big) & 0xfffe == 0xfff8) {
        if (padded[2] & 0xf0 == 0) return 0; // block size code
        if (padded[2] & 0x0f == 0x0f) return 0; // sample rate code
        if (padded[3] & 0xf0 >= (flac.max_channels + 2) << 4) return 0; // channel mode
        if (padded[3] & 0x06 == 0x06) return 0; // sample size code
        if (padded[3] & 0x01 == 0x01) return 0; // reserved bit
        return 50 / 4 + 1;
    }
    if (head.len < probe_bytes or !std.mem.eql(u8, head[0..4], "fLaC")) return 0;
    const block_type = head[4] & 0x7f;
    const size = std.mem.readInt(u24, head[5..8], .big);
    const min_block = std.mem.readInt(u16, head[8..10], .big);
    const max_block = std.mem.readInt(u16, head[10..12], .big);
    const rate = std.mem.readInt(u24, head[18..21], .big) >> 4;
    if (block_type == 0 and size == flac.streaminfo_size and min_block >= 16 and max_block >= min_block and
        rate != 0 and rate <= 655350) return 100;
    return 50;
}

const metadata_streaminfo = 0;

/// Reads `fLaC` and the metadata blocks, STREAMINFO checked.
pub fn readHeader(reader: *std.Io.Reader) Error!Info {
    var marker: [4]u8 = undefined;
    readExact(reader, &marker) catch |err| return err;
    // FFmpeg reads input without fLaC as frames: its headerless mode.
    if (!std.mem.eql(u8, &marker, "fLaC")) return error.UnsupportedFormat;
    var info: ?flac.StreamInfo = null;
    while (true) {
        var block: [4]u8 = undefined;
        try readExact(reader, &block);
        const last = block[0] & 0x80 != 0;
        const block_type = block[0] & 0x7f;
        const size = std.mem.readInt(u24, block[1..4], .big);
        if (block_type == metadata_streaminfo) {
            // STREAMINFO comes once, with 34 bytes.
            if (info != null or size != flac.streaminfo_size) return error.InvalidFlac;
            var body: [flac.streaminfo_size]u8 = undefined;
            try readExact(reader, &body);
            info = flac.StreamInfo.parse(&body);
        } else {
            // STREAMINFO must come first. FFmpeg also accepts SEEKTABLE,
            // CUESHEET and PICTURE before it, which it reads and T26b will.
            if (info == null) return error.InvalidFlac;
            reader.discardAll(size) catch |err| return switch (err) {
                error.EndOfStream => error.Truncated,
                error.ReadFailed => error.IoFailure,
            };
        }
        if (last) break;
    }
    const si = info orelse return error.InvalidFlac;
    // ff_flac_parse_streaminfo refuses these, and the decoder with them.
    if (si.max_blocksize < flac.min_blocksize) return error.InvalidFlac;
    // T26b: other sample sizes, and a rate only the frames give.
    if (si.bps != 16 or si.sample_rate == 0) return error.UnsupportedFormat;
    return .{
        .stream_info = si,
        .layout = flac.channelLayout(si.channels),
        .time_base = time.TimeBase.ofSampleRate(si.sample_rate) catch return error.UnsupportedFormat,
        .duration = if (si.samples > 0) si.samples else null,
    };
}

fn readExact(reader: *std.Io.Reader, buffer: []u8) Error!void {
    reader.readSliceAll(buffer) catch |err| return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

/// libavformat's base for timestamps it counts before knowing the first.
const relative_ts_base: i64 = std.math.maxInt(i64) - (1 << 48);
const nopts: i64 = std.math.minInt(i64);

fn isRelative(ts: i64) bool {
    return ts > relative_ts_base - (1 << 48);
}

/// A packet libavformat holds before returning it, timestamps in its
/// representation (`nopts` for none).
const Queued = struct {
    data: []u8,
    pts: i64,
    dts: i64,
    duration: i64,
};

/// avformat_find_stream_info reads at most this many packets ahead
/// (`max_ts_probe`) while the first timestamp is unknown, and at most
/// `probesize` bytes.
const max_ts_probe = 50;
const probesize = 5_000_000;

pub const Demuxer = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    info: Info,
    parser: flac_parser.Parser,
    /// avformat_find_stream_info's packets, then the parser's queue: what
    /// the timestamp fix-ups reach.
    packet_buffer: std.ArrayList(Queued) = .empty,
    parse_queue: std.ArrayList(Queued) = .empty,
    /// The packet returned last, freed on the next call.
    current: ?[]u8 = null,
    cur_dts: i64 = relative_ts_base,
    first_dts: i64 = nopts,
    durations_done: bool = false,
    /// The stream's start time, once a timestamp sets it.
    start_time: ?i64 = null,
    probing: bool = true,
    eof: bool = false,

    /// Reads the header; packets follow with `next`.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader) Error!Demuxer {
        const info = try readHeader(reader);
        return .{ .gpa = gpa, .reader = reader, .info = info, .parser = .init(gpa) };
    }

    pub fn deinit(d: *Demuxer) void {
        for (d.packet_buffer.items) |q| d.gpa.free(q.data);
        for (d.parse_queue.items) |q| d.gpa.free(q.data);
        d.packet_buffer.deinit(d.gpa);
        d.parse_queue.deinit(d.gpa);
        if (d.current) |c| d.gpa.free(c);
        d.parser.deinit();
        d.* = undefined;
    }

    /// The next packet, borrowed until the next call; null at the end.
    pub fn next(d: *Demuxer) Error!?packet.Packet {
        if (d.current) |c| d.gpa.free(c);
        d.current = null;
        if (d.probing) {
            // avformat_find_stream_info: read ahead until a timestamp sets
            // the stream's first.
            var count: usize = 0;
            var bytes: u64 = 0;
            while (d.first_dts == nopts and count < max_ts_probe and bytes < probesize) {
                const q = try d.readFrameInternal() orelse break;
                try d.packet_buffer.append(d.gpa, q);
                count += 1;
                bytes += q.data.len;
            }
            d.probing = false;
        }
        const q = if (d.packet_buffer.items.len > 0)
            d.packet_buffer.orderedRemove(0)
        else
            try d.readFrameInternal() orelse return null;
        d.current = q.data;
        var pts = q.pts;
        var dts = q.dts;
        if (isRelative(dts)) dts -= relative_ts_base;
        if (isRelative(pts)) pts -= relative_ts_base;
        return .{
            .data = q.data,
            .time_base = d.info.time_base,
            .pts = if (pts == nopts) null else pts,
            .dts = if (dts == nopts) null else dts,
            .duration = if (q.duration == 0) null else q.duration,
            .flags = .{ .key = true },
        };
    }

    /// read_frame_internal: the parser's next packet, reading and parsing
    /// as needed; at the end of the input the parser is flushed.
    fn readFrameInternal(d: *Demuxer) Error!?Queued {
        while (d.parse_queue.items.len == 0) {
            if (d.eof) {
                // FFmpeg flushes again on every read after the end.
                try d.parsePacket(&.{}, true);
                break;
            }
            var chunk: [raw_packet_size]u8 = undefined;
            const n = d.reader.readSliceShort(&chunk) catch return error.IoFailure;
            if (n == 0) {
                d.eof = true;
                try d.parsePacket(&.{}, true);
                break;
            }
            try d.parsePacket(chunk[0..n], false);
        }
        if (d.parse_queue.items.len == 0) return null;
        return d.parse_queue.orderedRemove(0);
    }

    /// parse_packet: everything the parser makes of `input`, into the
    /// parse queue with its timestamps.
    fn parsePacket(d: *Demuxer, input: []const u8, flush: bool) Error!void {
        var rest = input;
        var got_output = flush;
        while (rest.len > 0 or (flush and got_output)) {
            const out = try d.parser.parse(rest);
            rest = rest[out.consumed..];
            const frame = out.frame orelse {
                got_output = false;
                continue;
            };
            got_output = true;
            var duration: i64 = 0;
            if (out.sample_rate > 0 and out.duration > 0) {
                // av_rescale_q_rnd from 1/rate to the time base, rounding down.
                duration = @intCast(@as(u64, out.duration) * d.info.stream_info.sample_rate / out.sample_rate);
            }
            const data = try d.gpa.dupe(u8, frame);
            errdefer d.gpa.free(data);
            var q: Queued = .{ .data = data, .pts = out.pts orelse nopts, .dts = nopts, .duration = duration };
            d.computePktFields(&q);
            try d.parse_queue.append(d.gpa, q);
        }
    }

    fn queued(d: *Demuxer) bool {
        return d.packet_buffer.items.len > 0 or d.parse_queue.items.len > 0;
    }

    /// compute_pkt_fields for an audio stream without reordering.
    fn computePktFields(d: *Demuxer, q: *Queued) void {
        if (q.duration > 0 and d.queued()) d.updateInitialDurations(q.duration);
        if (q.pts != nopts or q.dts != nopts or q.duration > 0) {
            // Presentation is not delayed: pts and dts are the same.
            if (q.pts == nopts) q.pts = q.dts;
            d.updateInitialTimestamps(q.pts, q.pts);
            if (q.pts == nopts) q.pts = d.cur_dts;
            q.dts = q.pts;
            if (q.pts != nopts) d.cur_dts = q.pts +% q.duration;
        }
        if (q.dts > d.cur_dts) d.cur_dts = q.dts;
    }

    /// Every packet libavformat still holds, in order.
    fn heldPackets(d: *Demuxer) [2][]Queued {
        return .{ d.packet_buffer.items, d.parse_queue.items };
    }

    /// update_initial_timestamps: the first real timestamp fixes the
    /// relative ones held so far, and the start time.
    fn updateInitialTimestamps(d: *Demuxer, dts: i64, pts_in: i64) void {
        const int_min: i64 = std.math.minInt(i32);
        if (d.first_dts != nopts or dts == nopts or d.cur_dts == nopts or
            d.cur_dts < int_min + relative_ts_base or
            dts < int_min + (d.cur_dts - relative_ts_base) or isRelative(dts)) return;
        d.first_dts = dts - (d.cur_dts - relative_ts_base);
        d.cur_dts = dts;
        const shift: i64 = d.first_dts -% relative_ts_base;
        var pts = pts_in;
        if (isRelative(pts)) pts +%= shift;
        for (d.heldPackets()) |list| for (list) |*held| {
            if (isRelative(held.pts)) held.pts +%= shift;
            if (isRelative(held.dts)) held.dts +%= shift;
            if (d.start_time == null and held.pts != nopts) d.start_time = held.pts;
        };
        // update_dts_from_pts: without reordering, a held packet's missing
        // dts becomes its pts.
        for (d.heldPackets()) |list| for (list) |*held| {
            if (held.pts != nopts and held.dts == nopts) held.dts = held.pts;
        };
        if (d.start_time == null) d.start_time = if (pts == nopts) null else pts;
    }

    /// update_initial_durations: held packets with neither timestamps nor a
    /// duration get the first known duration, counted back from the first
    /// timestamp.
    fn updateInitialDurations(d: *Demuxer, duration: i64) void {
        var cur_dts: i64 = relative_ts_base;
        var list_index: usize = 0;
        var item: usize = 0;
        const held = d.heldPackets();
        if (d.first_dts != nopts) {
            if (d.durations_done) return;
            d.durations_done = true;
            cur_dts = d.first_dts;
            // Count back over the leading packets without timestamps.
            var found: ?*Queued = null;
            outer: for (held) |list| for (list) |*p| {
                if (p.pts != p.dts or p.dts != nopts or p.duration != 0) {
                    found = p;
                    break :outer;
                }
                cur_dts -%= duration;
            };
            const first = found orelse return;
            if (first.dts != d.first_dts) return;
            d.first_dts = cur_dts;
        } else if (d.cur_dts != relative_ts_base) return;
        var reached_end = true;
        outer: while (list_index < held.len) : ({
            list_index += 1;
            item = 0;
        }) {
            while (item < held[list_index].len) : (item += 1) {
                const p = &held[list_index][item];
                if ((p.pts == p.dts or p.pts == nopts) and
                    (p.dts == nopts or p.dts == d.first_dts or p.dts == relative_ts_base) and
                    p.duration == 0 and !addOverflows(cur_dts, duration))
                {
                    p.dts = cur_dts;
                    p.pts = cur_dts;
                    p.duration = duration;
                } else {
                    reached_end = false;
                    break :outer;
                }
                cur_dts = p.dts +% p.duration;
            }
        }
        if (reached_end) d.cur_dts = cur_dts;
    }
};

fn addOverflows(a: i64, b: i64) bool {
    _ = std.math.add(i64, a, b) catch return true;
    return false;
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");

test "the probe scores FFmpeg's way" {
    try testing.expectEqual(100, probeScore(fixtures.flac.bytes("flac_constant_mono_8k")));
    try testing.expectEqual(50, probeScore(fixtures.flac.bytes("flac_no_streaminfo")));
    try testing.expectEqual(13, probeScore(fixtures.flac.bytes("flac_no_marker")));
    try testing.expectEqual(0, probeScore("RIFF"));
    try testing.expectEqual(0, probeScore(""));
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try testing.expectError(error.IoFailure, readHeader(&reader));
}

const vectors = @embedFile("../testing/vectors/flac.txt");

/// The oracle's lines for fixture `name`, without the `F` line.
fn vectorBlock(name: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "F ")) {
            const at = @intFromPtr(line.ptr) - @intFromPtr(vectors.ptr);
            if (start) |s| return vectors[s..at];
            if (std.mem.eql(u8, line[2..], name)) start = at + line.len + 1;
        }
    }
    if (start) |s| return vectors[s..];
    return null;
}

fn formatTs(buf: []u8, ts: ?i64) []const u8 {
    return if (ts) |t| std.fmt.bufPrint(buf, "{d}", .{t}) catch unreachable else "N";
}

/// The `P` lines the demuxer gives for `bytes`, as flac_vectors.c prints
/// them.
fn packetLines(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var d = try Demuxer.init(gpa, &reader);
    defer d.deinit();
    while (try d.next()) |p| {
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        const line = try std.fmt.allocPrint(gpa, "P {d} {s} {s} {d} 0x{x} 0x{x:0>8}\n", .{
            p.data.len,
            formatTs(&a, p.pts),
            formatTs(&b, p.dts),
            p.duration orelse 0,
            @as(u32, if (p.flags.key) 1 else 0),
            std.hash.Adler32.permute(0, p.data),
        });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
}

test "every fixture's packets equal FFmpeg's (vectors/flac.txt)" {
    const gpa = testing.allocator;
    inline for (fixtures.flac.all) |fixture| {
        const bytes = fixtures.flac.bytes(fixture.name);
        const block = vectorBlock(fixture.name) orelse return error.MissingVector;
        switch (fixture.expected) {
            .reject => |failure| {
                var reader: std.Io.Reader = .fixed(bytes);
                const expected: Error = switch (failure) {
                    .InvalidFlac => error.InvalidFlac,
                    .Truncated => error.Truncated,
                    .UnsupportedFormat => error.UnsupportedFormat,
                };
                try testing.expectError(expected, readHeader(&reader));
            },
            .accept, .damaged => {
                var expected: std.ArrayList(u8) = .empty;
                defer expected.deinit(gpa);
                var lines = std.mem.splitScalar(u8, block, '\n');
                while (lines.next()) |line| {
                    if (!std.mem.startsWith(u8, line, "P ")) continue;
                    try expected.appendSlice(gpa, line);
                    try expected.append(gpa, '\n');
                }
                var actual: std.ArrayList(u8) = .empty;
                defer actual.deinit(gpa);
                try packetLines(gpa, bytes, &actual);
                testing.expectEqualStrings(expected.items, actual.items) catch |err| {
                    std.debug.print("fixture {s}\n", .{fixture.name});
                    return err;
                };
            },
        }
    }
}

test "the demuxer's packets do not depend on the reader's buffer" {
    const gpa = testing.allocator;
    const bytes = fixtures.flac.bytes("flac_junk_between_frames");
    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(gpa);
    try packetLines(gpa, bytes, &whole);
    var reader: std.testing.Reader = .init(&.{}, &.{.{ .buffer = bytes }});
    reader.artificial_limit = .limited(1);
    var d = try Demuxer.init(gpa, &reader.interface);
    defer d.deinit();
    var count: usize = 0;
    while (try d.next()) |_| count += 1;
    try testing.expectEqual(std.mem.count(u8, whole.items, "\n"), count);
}
