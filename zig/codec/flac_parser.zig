// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/flac_parser.c (flac_parse and its header search, scoring and
// fifo) and parser.c (av_parser_parse2's timestamp fetching) at the pinned
// reference revision describe the behavior, restated here.
//! FFmpeg's FLAC parser (TODO.md T26a): splits a raw FLAC byte stream into
//! frames the way libavformat's FLAC demuxer gets them, junk included.
//!
//! Every sync code is checked as a frame header (CRC-8 and a plausible first
//! subframe), and the headers found are scored: a header earns points for
//! each following header whose CRC-16 checks out across the bytes between
//! them and whose frame number follows, and loses points for changes in
//! rate, sample size, blocking strategy and channel count. Ten headers are
//! buffered before the best-scoring chain gives its first frame. Bytes
//! before the best header come out as a junk packet; a header the scoring
//! passes over is dropped with its bytes, as FFmpeg drops it.
//!
//! FFmpeg keeps the bytes in a ring buffer; this keeps them in a linear one,
//! and records the ring's capacity only for FFmpeg's "full of junk" check.
//! One difference remains: at the very end of the buffered bytes before end
//! of input, a 16-byte header's subframe byte lies past them, where FFmpeg
//! reads a stale byte of its ring and this reads 0.

const std = @import("std");
const bits = @import("bits.zig");
const flac = @import("flac.zig");

const max_sequential_headers = 4;
const min_headers = 10;
const avg_frame_size = 8192;
const header_base_score = 10;
const header_changed_penalty = 7;
const header_crc_fail_penalty = 50;
const header_not_penalized_yet = 100000;
const header_not_scored_yet = -100000;
const max_frame_header_size = 16;
const max_frame_verify_size = max_frame_header_size + 1;

const Header = struct {
    /// Byte offset from the start of the buffered bytes.
    offset: usize,
    /// Scores between this header and the ones 1 to 4 headers later.
    link_penalty: [max_sequential_headers]i32 = @splat(header_not_penalized_yet),
    max_score: i32 = 0,
    fi: flac.FrameInfo,
    /// The index of the following header this one scores best with.
    best_child: ?usize = null,
};

/// What one call gives, av_parser_parse2's results.
pub const Output = struct {
    /// Input bytes consumed.
    consumed: usize,
    /// A frame or junk, borrowed until the next call; null for none.
    frame: ?[]const u8 = null,
    /// The frame's timestamp in samples, when the parser knows it.
    pts: ?i64 = null,
    /// The frame's samples, 0 for junk (`AVCodecParserContext.duration`).
    duration: u32 = 0,
    /// The frame header's rate, 0 for none (what the parser sets the codec
    /// context's rate to).
    sample_rate: u32 = 0,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    /// The buffered bytes are `buffer.items[head..]`.
    buffer: std.ArrayList(u8) = .empty,
    head: usize = 0,
    /// FFmpeg's ring size, which only grows.
    capacity: usize = (min_headers + 3) * avg_frame_size,
    headers: std.ArrayList(Header) = .empty,
    best_header: ?usize = null,
    nb_headers_found: usize = 0,
    nb_headers_buffered: usize = 0,
    best_header_valid: bool = false,
    end_padded: bool = false,
    last_fi: flac.FrameInfo = .{},
    last_fi_valid: bool = false,
    /// `AVCodecParserContext.duration`, kept between calls as FFmpeg keeps it.
    duration: u32 = 0,
    /// The frame header rate the last frame set.
    sample_rate: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Parser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Parser) void {
        p.buffer.deinit(p.gpa);
        p.headers.deinit(p.gpa);
        p.* = undefined;
    }

    fn data(p: *const Parser) []const u8 {
        return p.buffer.items[p.head..];
    }

    fn fifoSize(p: *const Parser) usize {
        return p.buffer.items.len - p.head;
    }

    fn fifoWrite(p: *Parser, bytes: []const u8) error{OutOfMemory}!void {
        const size = p.fifoSize();
        if (p.capacity - size < bytes.len) p.capacity += @max(size, bytes.len);
        if (p.head > 0 and p.head >= p.buffer.items.len / 2) {
            // Reclaim the drained front before growing.
            const live = p.buffer.items[p.head..];
            std.mem.copyForwards(u8, p.buffer.items[0..live.len], live);
            p.buffer.items.len = live.len;
            p.head = 0;
        }
        try p.buffer.appendSlice(p.gpa, bytes);
    }

    fn fifoDrain(p: *Parser, n: usize) void {
        std.debug.assert(n <= p.fifoSize());
        p.head += n;
    }

    /// Removes the first `n` headers, keeping indices consistent.
    fn removeHeaders(p: *Parser, n: usize) void {
        const items = p.headers.items;
        std.mem.copyForwards(Header, items[0 .. items.len - n], items[n..]);
        p.headers.items.len -= n;
        for (p.headers.items) |*h| {
            if (h.best_child) |c| h.best_child = if (c >= n) c - n else null;
        }
        if (p.best_header) |b| p.best_header = if (b >= n) b - n else null;
    }

    /// frame_header_is_valid: a header with its CRC-8 and a plausible first
    /// subframe type.
    fn frameHeaderIsValid(bytes: []const u8) ?flac.FrameInfo {
        var r = bits.BitReader.init(bytes[0..@min(bytes.len, max_frame_verify_size)]) catch return null;
        const fi = switch (flac.decodeFrameHeader(&r)) {
            .ok => |fi| fi,
            .invalid => return null,
        };
        if (r.bit() != 0) return null;
        const subframe_type = r.bits(6);
        if (!(subframe_type == 0 or subframe_type == 1 or (subframe_type >= 8 and subframe_type <= 12) or subframe_type >= 32)) return null;
        return fi;
    }

    /// find_new_headers: checks every sync code from `search_start` to 15
    /// bytes before the end; returns the headers buffered.
    fn findNewHeaders(p: *Parser, search_start: usize) error{OutOfMemory}!usize {
        p.nb_headers_found = 0;
        const bytes = p.data();
        if (bytes.len >= max_frame_header_size - 1) {
            const search_end = bytes.len - (max_frame_header_size - 1);
            var i = search_start;
            while (i < search_end) : (i += 1) {
                if (bytes[i] != 0xff or bytes[i + 1] & 0xfe != 0xf8) continue;
                if (frameHeaderIsValid(bytes[i..])) |fi| {
                    try p.headers.append(p.gpa, .{ .offset = i, .fi = fi });
                    p.nb_headers_found += 1;
                }
            }
        }
        return p.headers.items.len;
    }

    fn checkHeaderFiMismatch(header_fi: flac.FrameInfo, child_fi: flac.FrameInfo) i32 {
        var deduction: i32 = 0;
        if (child_fi.sample_rate != header_fi.sample_rate) deduction += header_changed_penalty;
        if (child_fi.bps != header_fi.bps) deduction += header_changed_penalty;
        // Changing the blocking strategy is not allowed by the format.
        if (child_fi.is_var_size != header_fi.is_var_size) deduction += header_base_score;
        if (child_fi.channels != header_fi.channels) deduction += header_changed_penalty;
        return deduction;
    }

    /// check_header_mismatch: the penalty between header `h` and the header
    /// `c` after it, CRC-16 checks included.
    fn checkHeaderMismatch(p: *Parser, h: usize, c: usize) i32 {
        const headers = p.headers.items;
        const header_fi = headers[h].fi;
        const child_fi = headers[c].fi;
        var deduction = checkHeaderFiMismatch(header_fi, child_fi);
        var deduction_expected = false;
        if (child_fi.frame_or_sample_num -% header_fi.frame_or_sample_num != header_fi.blocksize and
            child_fi.frame_or_sample_num != header_fi.frame_or_sample_num +% 1)
        {
            // Frames in the middle that pass a CRC account for the jump.
            var expected_frame_num = header_fi.frame_or_sample_num;
            var expected_sample_num = header_fi.frame_or_sample_num;
            var curr = h;
            while (curr != c) : (curr += 1) {
                for (headers[curr].link_penalty) |penalty| {
                    if (penalty < header_crc_fail_penalty) {
                        expected_frame_num +%= 1;
                        expected_sample_num +%= headers[curr].fi.blocksize;
                        break;
                    }
                }
            }
            if (expected_frame_num == child_fi.frame_or_sample_num or expected_sample_num == child_fi.frame_or_sample_num) {
                deduction_expected = deduction == 0;
            }
            deduction += header_changed_penalty;
        }

        var check_crc: bool = undefined;
        if (p.last_fi.is_var_size == header_fi.is_var_size) {
            if (p.last_fi.is_var_size and p.last_fi.frame_or_sample_num +% p.last_fi.blocksize == header_fi.frame_or_sample_num) {
                check_crc = false;
            } else if (!p.last_fi.is_var_size and p.last_fi.frame_or_sample_num +% 1 == header_fi.frame_or_sample_num) {
                check_crc = false;
            } else {
                check_crc = deduction == 0 and !deduction_expected;
            }
        } else {
            check_crc = deduction == 0 and !deduction_expected;
        }

        if (check_crc or (deduction != 0 and !deduction_expected)) {
            var crc: u16 = 1;
            var inverted_test = false;
            // The distance index of `c` from `h`.
            const i = c - h - 1;
            std.debug.assert(i < max_sequential_headers);
            if (headers[h].link_penalty[i] < header_crc_fail_penalty or
                headers[h].link_penalty[i] == header_not_penalized_yet)
            {
                var start = h;
                var end = c;
                if (i > 0 and headers[h].link_penalty[i - 1] >= header_crc_fail_penalty) {
                    start = c - 1;
                    inverted_test = true;
                } else if (i > 0 and headers[h + 1].link_penalty[i - 1] >= header_crc_fail_penalty) {
                    end = h + 1;
                    inverted_test = true;
                }
                crc = bits.Crc16.hash(p.data()[headers[start].offset..headers[end].offset]);
            }
            // `!crc ^ !inverted_test` in flac_parser.c: a failed CRC, or a
            // passing one where the inverted test expects a failure.
            if ((crc == 0) == inverted_test) deduction += header_crc_fail_penalty;
        }
        return deduction;
    }

    /// score_header: the header's best chain score, computed once per
    /// scoring pass.
    fn scoreHeader(p: *Parser, h: usize) i32 {
        if (p.headers.items[h].max_score != header_not_scored_yet) return p.headers.items[h].max_score;
        var base_score: i32 = header_base_score;
        if (p.last_fi_valid) base_score -= checkHeaderFiMismatch(p.last_fi, p.headers.items[h].fi);
        p.headers.items[h].max_score = base_score;
        var dist: usize = 0;
        var child = h + 1;
        while (dist < max_sequential_headers and child < p.headers.items.len) : ({
            dist += 1;
            child += 1;
        }) {
            if (p.headers.items[h].link_penalty[dist] == header_not_penalized_yet) {
                p.headers.items[h].link_penalty[dist] = p.checkHeaderMismatch(h, child);
            }
            const child_score = p.scoreHeader(child) - p.headers.items[h].link_penalty[dist];
            if (header_base_score + child_score > p.headers.items[h].max_score) {
                // Keep the child, because the scoring is dynamic.
                p.headers.items[h].best_child = child;
                p.headers.items[h].max_score = base_score + child_score;
            }
        }
        return p.headers.items[h].max_score;
    }

    fn scoreSequences(p: *Parser) void {
        for (p.headers.items) |*h| h.max_score = header_not_scored_yet;
        var best_score: i32 = header_not_scored_yet;
        for (0..p.headers.items.len) |h| {
            if (p.scoreHeader(h) > best_score) {
                p.best_header = h;
                best_score = p.headers.items[h].max_score;
            }
        }
    }

    /// get_best_header: the best header's frame, up to its best child or
    /// the end of the buffered bytes. Returns flac_parse's (non-positive)
    /// index.
    fn getBestHeader(p: *Parser, out: *Output) i64 {
        const best = p.best_header.?;
        const header = p.headers.items[best];
        const size = if (header.best_child) |c| p.headers.items[c].offset - header.offset else p.fifoSize() - header.offset;
        p.duration = header.fi.blocksize;
        p.sample_rate = header.fi.sample_rate;
        out.frame = p.data()[header.offset..][0..size];
        // PARSER_FLAG_USE_CODEC_TS, which libavformat sets for raw FLAC.
        if (header.fi.is_var_size) {
            out.pts = header.fi.frame_or_sample_num;
        } else if (header.best_child != null) {
            out.pts = header.fi.frame_or_sample_num *% header.fi.blocksize;
        }
        p.best_header_valid = false;
        p.last_fi_valid = true;
        p.last_fi = header.fi;
        if (header.best_child) |c| {
            const offset = signedDistance(p.headers.items[c].offset, p.fifoSize());
            if (offset > -(1 << 28)) return offset;
        }
        return 0;
    }

    /// flac_parse, then av_parser_parse2's bookkeeping. `input` empty
    /// flushes at the end of the stream. The frame stays valid until the
    /// next call.
    pub fn parse(p: *Parser, input: []const u8) error{OutOfMemory}!Output {
        var out: Output = .{ .consumed = 0 };
        const index = try p.parseFrame(input, &out);
        out.consumed = @intCast(@max(index, 0));
        if (out.frame) |frame| {
            if (frame.len == 0) out.frame = null;
        }
        if (out.frame != null) {
            out.duration = p.duration;
            out.sample_rate = p.sample_rate;
        } else {
            out.pts = null;
        }
        return out;
    }

    fn parseFrame(p: *Parser, buf: []const u8, out: *Output) error{OutOfMemory}!i64 {
        if (p.best_header_valid and p.nb_headers_buffered >= min_headers) return p.getBestHeader(out);

        // Remove the frame returned last time with its bytes.
        if (p.best_header) |best| {
            if (p.headers.items[best].best_child) |child| {
                const child_offset = p.headers.items[child].offset;
                p.nb_headers_buffered -= child;
                p.fifoDrain(child_offset);
                for (p.headers.items[child + 1 ..]) |*h| h.offset -= child_offset;
                p.headers.items[child].offset = 0;
                p.best_header = null;
                p.removeHeaders(child);
                if (p.nb_headers_buffered >= min_headers) {
                    p.best_header = 0;
                    return p.getBestHeader(out);
                }
            } else {
                // No following frame, probably the end: drop the headers up
                // to it, but not their bytes.
                p.nb_headers_buffered -= best + 1;
                p.best_header = null;
                p.removeHeaders(best + 1);
            }
        }

        // Find and score new headers. An empty input flushes once, padded
        // with 16 zeros to check the last bytes for headers.
        var read_start: usize = 0;
        var read_end: ?usize = 0;
        while ((buf.len != 0 and read_end.? < buf.len and p.nb_headers_buffered < min_headers) or
            (buf.len == 0 and !p.end_padded))
        {
            var written: usize = undefined;
            if (buf.len == 0) {
                p.end_padded = true;
                written = max_frame_header_size;
            } else {
                const nb_desired = min_headers - p.nb_headers_buffered + 1;
                read_end = read_end.? + @min(buf.len - read_end.?, nb_desired * avg_frame_size);
                written = read_end.? - read_start;
            }
            if (p.capacity == p.fifoSize() and p.fifoSize() / avg_frame_size > p.nb_headers_buffered * 20) {
                // Less than one header per 20 frames' worth of bytes: most
                // likely not FLAC.
                return if (buf.len != 0) @intCast(read_end.?) else 0;
            }
            if (buf.len != 0) {
                try p.fifoWrite(buf[read_start..read_end.?]);
            } else {
                const pad: [max_frame_header_size]u8 = @splat(0);
                try p.fifoWrite(&pad);
            }
            const start_offset = p.fifoSize() -| (written + (max_frame_header_size - 1));
            p.nb_headers_buffered = try p.findNewHeaders(start_offset);
            // Wait for enough headers before returning a frame.
            if (!p.end_padded and p.nb_headers_buffered < min_headers) {
                if (read_end.? < buf.len) {
                    read_start = read_end.?;
                    continue;
                }
                return @intCast(read_end.?);
            }
            if (p.end_padded or p.nb_headers_found != 0) p.scoreSequences();
            if (p.end_padded) {
                // Drop the padding again.
                p.buffer.items.len -= max_frame_header_size;
                read_end = null;
            }
        }

        for (p.headers.items, 0..) |h, i| {
            if (p.best_header == null or h.max_score > p.headers.items[p.best_header.?].max_score) p.best_header = i;
        }
        if (p.best_header) |best| {
            if (p.headers.items[best].max_score <= 0) {
                // Only accept a bad header when nothing else can continue.
                if (buf.len == 0 or read_end != @as(?usize, 0) or p.nb_headers_buffered < min_headers) p.best_header = null;
            }
        }
        if (p.best_header) |best| {
            p.best_header_valid = true;
            const offset = p.headers.items[best].offset;
            if (offset > 0) {
                // Bytes before the best header: a junk frame of unknown
                // duration.
                p.duration = 0;
                out.frame = p.data()[0..offset];
                if (buf.len != 0) return @intCast(read_end.?);
                return signedDistance(offset, p.fifoSize());
            }
            if (buf.len == 0) return p.getBestHeader(out);
        }
        return if (buf.len != 0) @intCast(read_end.?) else 0;
    }
};

/// `a - b` as FFmpeg's int arithmetic gives it; both are buffer offsets.
fn signedDistance(a: usize, b: usize) i64 {
    const sa: i64 = @intCast(a);
    const sb: i64 = @intCast(b);
    return sa - sb;
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");

/// Feeds `stream` in `chunk`-byte reads, as parse_packet loops, and returns
/// the frames' sizes.
fn frameSizes(gpa: std.mem.Allocator, stream: []const u8, chunk: usize) ![]usize {
    var p: Parser = .init(gpa);
    defer p.deinit();
    var sizes: std.ArrayList(usize) = .empty;
    errdefer sizes.deinit(gpa);
    var at: usize = 0;
    while (at < stream.len) {
        var piece = stream[at..@min(stream.len, at + chunk)];
        at += piece.len;
        while (piece.len > 0) {
            const out = try p.parse(piece);
            piece = piece[out.consumed..];
            if (out.frame) |f| try sizes.append(gpa, f.len);
        }
    }
    while (true) {
        const out = try p.parse(&.{});
        const f = out.frame orelse break;
        try sizes.append(gpa, f.len);
    }
    return sizes.toOwnedSlice(gpa);
}

test "the frames of a valid stream come out whole, whatever the reads" {
    const gpa = testing.allocator;
    const file = fixtures.flac.bytes("flac_many_frames");
    // The frames start after fLaC and STREAMINFO.
    const stream = file[4 + 4 + flac.streaminfo_size ..];
    const whole = try frameSizes(gpa, stream, stream.len);
    defer gpa.free(whole);
    try testing.expectEqual(300, whole.len);
    var total: usize = 0;
    for (whole) |s| total += s;
    try testing.expectEqual(stream.len, total);
    for ([_]usize{ 1, 7, 1024 }) |chunk| {
        const sizes = try frameSizes(gpa, stream, chunk);
        defer gpa.free(sizes);
        try testing.expectEqualSlices(usize, whole, sizes);
    }
}
