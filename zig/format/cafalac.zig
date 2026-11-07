// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/cafdec.c (read_packet's skip-samples side data),
// libavcodec/decode.c (discard_samples) and fftools/ffmpeg_dec.c (the
// decode error rate) at the pinned reference revision describe the
// behavior, restated here.
//! ALAC in CAF decoded as the ffmpeg program decodes it (TODO.md T31b): the
//! CAF parser's packets, as its packet table cuts them, each decoded by
//! FFmpeg's ALAC decoder (`codec/alac.zig`), the first packet's priming
//! frames and the last one's remainder dropped as libavcodec drops a
//! packet's skip-samples side data, delivered as interleaved s16le (16-bit
//! streams) or s32le (20, 24 and 32 bits, at the top of the sample).

const std = @import("std");
const audio = @import("../core/audio.zig");
const diagnostics = @import("../core/diagnostics.zig");
const alac = @import("../codec/alac.zig");
const caf = @import("caf.zig");
const decoded = @import("decoded.zig");
const seek = @import("seek.zig");

/// What reading the samples can fail with: the CAF parser's errors,
/// `UnsupportedFormat` for a stream FFmpeg's decoder does not open (no
/// magic cookie, a sample size or channel count it does not take), and
/// the decoding's.
pub const ReadError = caf.Error || error{
    /// The stream decodes to another sample count than its packet table
    /// gives, which a header written first declared.
    FrameCountMismatch,
    /// More than two thirds of the decodes failed: the ffmpeg program's
    /// `-max_error_rate` (2/3), which fails the decoding.
    DecodeErrorRate,
};

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    /// The CAF parser, past its header; its `nextPacket` gives the packets.
    parser: caf.Parser,
    info: caf.Info,
    sink: ?diagnostics.Sink,
    decoder: alac.Decoder,
    /// One packet (owned).
    packet_buf: []u8,
    /// The current frame's planes (the decoder's) and its samples not yet
    /// delivered.
    planes: []const []const i32 = &.{},
    pending: [2]u32 = .{ 0, 0 },
    discard: decoded.Discard = .{},
    delivered: u64 = 0,
    expected: ?u64 = null,
    ended: bool = false,
    /// Report the packet table's count, for a header written before the
    /// samples on an output that cannot be rewritten; a caller that needs
    /// no count clears it before `readHeader`.
    count_ahead: bool = true,
    errors: decoded.ErrorRate = .{},

    pub const Header = decoded.Header;

    /// Takes over `parser`, whose `readHeader` gave `info` (an ALAC
    /// stream), and opens FFmpeg's decoder; its refusal is
    /// `UnsupportedFormat`, as the ffmpeg program fails to open it. On
    /// success `deinit` frees the parser's packet table; on failure the
    /// caller still owns the parser.
    pub fn init(gpa: std.mem.Allocator, parser: caf.Parser, info: caf.Info, sink: ?diagnostics.Sink) ReadError!DecodedReader {
        const a = info.alac.?; // the caller dispatches on it
        const cookie = a.cookie orelse return error.UnsupportedFormat; // "extradata is too small"
        const config = alac.Config.parse(&cookie, a.channels) catch return error.UnsupportedFormat;
        const packet_buf = try gpa.alloc(u8, @max(a.max_packet, 1));
        return .{
            .gpa = gpa,
            .parser = parser,
            .info = info,
            .sink = sink,
            .decoder = .init(gpa, config),
            .packet_buf = packet_buf,
        };
    }

    pub fn deinit(r: *DecodedReader) void {
        r.decoder.deinit();
        r.gpa.free(r.packet_buf);
        r.parser.deinit();
        r.* = undefined;
    }

    fn wide(r: *const DecodedReader) bool {
        return r.decoder.config.sample_size > 16;
    }

    /// The decoded stream: interleaved s16 or s32, the decoder's channels
    /// and layout, and, when `count_ahead` asks for one, its count: on a
    /// seekable input the stream decoded once ahead (the packet table's
    /// count can be wrong: FFmpeg's own muxer records the last frame's
    /// padding as remainder frames, which the decoder then drops), else
    /// the table's.
    pub fn readHeader(r: *DecodedReader) ReadError!Header {
        const counted: ?u64 = if (!r.count_ahead) null else if (r.parser.seeker) |sk| try r.countAhead(sk) else r.info.frame_count;
        r.expected = counted;
        var format = r.info.format;
        format.sample_format = if (r.wide()) .s32 else .s16;
        return .{ .stream = .alac, .codec = if (r.wide()) .s32le else .s16le, .format = format, .frame_count = counted, .bits = r.decoder.config.sample_size };
    }

    /// The counting pass: the stream from its start through a second
    /// parser and decoder, then back to this parser's data.
    fn countAhead(r: *DecodedReader, sk: seek.Seeker) ReadError!u64 {
        const resume_at = sk.position();
        sk.seekTo(0) catch return error.IoFailure;
        var parser: caf.Parser = .init(r.parser.reader, r.parser.limits);
        parser.enableAlac(r.gpa, sk);
        const info = parser.readHeader() catch |err| {
            parser.deinit();
            return err;
        };
        var pass = init(r.gpa, parser, info, null) catch |err| {
            parser.deinit();
            return err;
        };
        defer pass.deinit();
        pass.count_ahead = false;
        _ = try pass.readHeader();
        var scratch: [8192]u8 = undefined;
        while ((try pass.readData(&scratch)).len != 0) {}
        // A decoding the program fails, failed before any output.
        try pass.errors.check();
        sk.seekTo(resume_at) catch return error.IoFailure;
        return pass.delivered;
    }

    /// The decoder's largest frame (the cookie's frame size).
    pub fn maxFrame(r: *const DecodedReader) u32 {
        return r.decoder.config.max_samples_per_frame;
    }

    /// The first decoded frame's sample count, after discarding (the
    /// ffmpeg program's FLAC encoder takes it as its block size); null for
    /// a stream without one. `readData` still returns it first.
    pub fn firstFrameSamples(r: *DecodedReader) ReadError!?u32 {
        std.debug.assert(r.delivered == 0);
        if (r.pendingFrames() == 0 and !try r.nextFrame()) return null;
        return r.pendingFrames();
    }

    fn pendingFrames(r: *const DecodedReader) u32 {
        return r.pending[1] - r.pending[0];
    }

    /// Whole frames of samples into `output`, at least one while any
    /// remain; empty at the end. An output too small for one frame is
    /// `OutputTooSmall`.
    pub fn readData(r: *DecodedReader, output: []u8) ReadError![]u8 {
        while (r.pendingFrames() == 0) {
            if (!try r.nextFrame()) return output[0..0];
        }
        const channels = r.planes.len;
        const width: usize = if (r.wide()) 4 else 2;
        const frame_bytes = width * channels;
        const frames = @min(output.len / frame_bytes, r.pendingFrames());
        if (frames == 0) return error.OutputTooSmall;
        if (r.expected) |expected| {
            if (r.delivered + frames > expected) return error.FrameCountMismatch;
        }
        for (0..frames) |f| {
            for (r.planes, 0..) |plane, c| {
                const v = plane[r.pending[0] + f];
                const at = output[(f * channels + c) * width ..];
                if (width == 2) std.mem.writeInt(i16, at[0..2], @intCast(v), .little) else std.mem.writeInt(i32, at[0..4], v, .little);
            }
        }
        r.pending[0] += @intCast(frames);
        r.delivered += frames;
        return output[0 .. frames * frame_bytes];
    }

    /// The next frame the decoder gives, after libavcodec's discarding;
    /// false at the end of the data. A packet the decoder refuses is
    /// reported and dropped, as decode.c and the ffmpeg program drop it.
    fn nextFrame(r: *DecodedReader) ReadError!bool {
        if (r.ended) return false;
        while (true) {
            const packet = try r.parser.nextPacket(r.packet_buf) orelse {
                r.ended = true;
                return false;
            };
            // read_packet's skip-samples side data: the priming on the
            // first packet, the remainder on the last.
            const priming: u32 = if (packet.first) r.info.alac.?.priming else 0;
            const remainder: u32 = if (packet.last) r.info.alac.?.remainder else 0;
            const side: ?[2]u32 = if (priming > 0 or remainder > 0) .{ priming, remainder } else null;
            const frame = r.decoder.decode(packet.data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    diagnostics.report(r.sink, .err, "Error submitting packet to decoder: Invalid data found when processing input", .{});
                    r.errors.decode_errors += 1;
                    continue;
                },
            } orelse continue; // "Failed to decode all channels": no frame
            r.errors.frames_decoded += 1;
            const kept = r.discard.apply(frame.samples, side) orelse continue;
            r.planes = frame.planes;
            r.pending = kept;
            return true;
        }
    }

    /// The rest of the CAF stream (`caf.Parser.finish`), then the
    /// decoding's error rate and the count `readHeader` reported.
    pub fn finish(r: *DecodedReader) ReadError!void {
        std.debug.assert(r.pendingFrames() == 0);
        try r.parser.finish();
        try r.errors.check();
        if (r.expected) |expected| {
            if (r.delivered != expected) return error.FrameCountMismatch;
        }
    }
};

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const hostile = @import("../testing/hostile.zig");
const detect = @import("detect.zig");

/// What FFmpeg makes of each ALAC fixture (alac_caf_vectors.sh).
const vectors = @embedFile("../testing/vectors/alac_caf.txt");

/// The port's errors for the fixtures it does not open or decode: where
/// FFmpeg fails too, and the differences notes.md "ALAC in CAF" records
/// (packets past the data or the table, constant-size packets, unknown
/// length by default).
const Refusal = struct { name: []const u8, probe: ?anyerror, decode: anyerror };
const refusals = [_]Refusal{
    .{ .name = "alac_all_damaged", .probe = null, .decode = error.DecodeErrorRate },
    .{ .name = "alac_32bit_stereo", .probe = null, .decode = error.DecodeErrorRate },
    .{ .name = "alac_no_kuki", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "alac_no_pakt", .probe = error.InvalidCaf, .decode = error.InvalidCaf },
    .{ .name = "alac_9ch_cookie", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "alac_pakt_short", .probe = error.InvalidCaf, .decode = error.InvalidCaf },
    .{ .name = "alac_pakt_count_past_body", .probe = error.InvalidCaf, .decode = error.InvalidCaf },
    .{ .name = "alac_zero_duration", .probe = error.InvalidCaf, .decode = error.InvalidCaf },
    .{ .name = "alac_packet_size_zero", .probe = error.InvalidCaf, .decode = error.InvalidCaf },
    .{ .name = "alac_data_past_table", .probe = error.InvalidCaf, .decode = error.InvalidCaf },
    .{ .name = "alac_table_past_data", .probe = error.InvalidCaf, .decode = error.InvalidCaf },
    .{ .name = "alac_constant_packets", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "alac_data_size_unknown", .probe = error.UnsupportedStreamingSize, .decode = error.UnsupportedStreamingSize },
};

fn refusalOf(name: []const u8) ?Refusal {
    for (refusals) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

fn vectorLines(name: []const u8) !struct { s: []const u8, d: []const u8 } {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "F ") and std.mem.eql(u8, line[2..], name)) {
            const s = lines.next() orelse break;
            const d = lines.next() orelse break;
            return .{ .s = s, .d = d };
        }
    }
    return error.TestUnexpectedResult;
}

/// Opens fixture bytes as ALAC in CAF, seekable or not, and decodes every
/// sample into `out` as interleaved s32le (16-bit samples at the top, as
/// the ffmpeg program's pcm_s32le gives them), without a count or with
/// the table's.
fn decodeBytes(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, counted: bool, out: *std.ArrayList(u8)) !DecodedReader.Header {
    var reader: std.Io.Reader = .fixed(bytes);
    var parser: caf.Parser = .init(&reader, .{});
    parser.enableAlac(gpa, if (seekable) seek.Seeker.fixed(&reader) else null);
    const info = parser.readHeader() catch |err| {
        parser.deinit();
        return err;
    };
    if (info.alac == null) {
        parser.deinit();
        return error.TestUnexpectedResult;
    }
    var r = DecodedReader.init(gpa, parser, info, null) catch |err| {
        parser.deinit();
        return err;
    };
    defer r.deinit();
    r.count_ahead = counted;
    const header = try r.readHeader();
    var scratch: [8192]u8 = undefined;
    while (true) {
        const got = try r.readData(&scratch);
        if (got.len == 0) break;
        if (header.codec == .s16le) {
            var i: usize = 0;
            while (i < got.len) : (i += 2) {
                const v: i32 = std.mem.readInt(i16, got[i..][0..2], .little);
                var wide: [4]u8 = undefined;
                std.mem.writeInt(i32, &wide, v << 16, .little);
                try out.appendSlice(gpa, &wide);
            }
        } else try out.appendSlice(gpa, got);
    }
    try r.finish();
    return header;
}

test "every ALAC fixture gives FFmpeg's stream and samples (vectors/alac_caf.txt), or the port's error" {
    const gpa = testing.allocator;
    inline for (fixtures.alac.all) |fixture| {
        errdefer std.debug.print("fixture {s}\n", .{fixture.name});
        const bytes = fixtures.alac.bytes(fixture.name);
        const refusal = refusalOf(fixture.name);
        try testing.expectEqual(fixture.expected == .reject, refusal != null);
        const lines = try vectorLines(fixture.name);
        var probe_reader: std.Io.Reader = .fixed(bytes);
        const options: detect.Options = .{ .gpa = gpa, .source = .{ .seeker = .fixed(&probe_reader) } };
        if (refusal) |r| if (r.probe) |want| {
            try testing.expectError(want, detect.probeWith(&probe_reader, .{}, options));
        };
        if (refusal == null or refusal.?.probe == null) {
            const probed = try detect.probeWith(&probe_reader, .{}, options);
            var text: [128]u8 = undefined;
            const s = try std.fmt.bufPrint(&text, "S {s} {s} {d} {d} {d}", .{
                probed.codec.name(),       probed.format.sample_format.name(), probed.format.channelCount(),
                probed.format.sample_rate, probed.frame_count.?,
            });
            try testing.expectEqualStrings(lines.s, s);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        if (refusal) |r| {
            try testing.expectError(r.decode, decodeBytes(gpa, bytes, true, false, &out));
        } else {
            const header = try decodeBytes(gpa, bytes, true, false, &out);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(out.items, &digest, .{});
            var text: [128]u8 = undefined;
            const d = try std.fmt.bufPrint(&text, "D {d} {s}", .{ out.items.len / 4 / header.format.channelCount(), &std.fmt.bytesToHex(digest, .lower) });
            try testing.expectEqualStrings(lines.d, d);
        }
    }
}

test "a table after the samples needs a seekable input; one before them does not" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // As FFmpeg on a pipe: "Missing packet table".
    try testing.expectError(error.InvalidCaf, decodeBytes(gpa, fixtures.alac.bytes("alac_pakt_after_data"), false, false, &out));
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(gpa);
    _ = try decodeBytes(gpa, fixtures.alac.bytes("alac_pakt_before_data"), false, false, &before);
    var after: std.ArrayList(u8) = .empty;
    defer after.deinit(gpa);
    _ = try decodeBytes(gpa, fixtures.alac.bytes("alac_pakt_after_data"), true, false, &after);
    try testing.expectEqualSlices(u8, before.items, after.items);
}

test "the count ahead is the decoded one; from a pipe the table's, which a failing packet or a remainder cut contradicts" {
    const gpa = testing.allocator;
    inline for (.{ "alac_pakt_before_data", "alac_priming", "alac_ffmpeg_stereo_44k", "alac_damaged_packet", "alac_remainder_cut", "alac_20bit" }) |name| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const header = try decodeBytes(gpa, fixtures.alac.bytes(name), true, true, &out);
        try testing.expectEqual(header.frame_count.?, out.items.len / 4 / header.format.channelCount());
    }
    // From a pipe: the table's count, which a packet the decoder refuses or
    // a remainder cutting the last frame makes wrong (notes.md "ALAC in
    // CAF").
    var good: std.ArrayList(u8) = .empty;
    defer good.deinit(gpa);
    _ = try decodeBytes(gpa, fixtures.alac.bytes("alac_priming"), false, true, &good);
    inline for (.{ "alac_damaged_packet", "alac_remainder_cut" }) |name| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try testing.expectError(error.FrameCountMismatch, decodeBytes(gpa, fixtures.alac.bytes(name), false, true, &out));
    }
}

const SweepInput = struct { bytes: []const u8, seekable: bool };

fn decodeUnderFailures(gpa: std.mem.Allocator, input: SweepInput) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = decodeBytes(gpa, input.bytes, input.seekable, true, &out) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
}

test "ALAC in CAF decoded frees everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, SweepInput{ .bytes = fixtures.alac.bytes("alac_ffmpeg_one_sample"), .seekable = true }, decodeUnderFailures);
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.fail, SweepInput{ .bytes = fixtures.alac.bytes("alac_pakt_before_data"), .seekable = false }, decodeUnderFailures);
}

/// The fuzz entry's input: a CAF stream, then whether it seeks, whether
/// data of unknown length is accepted and whether the reader reports its
/// count, as 0 or 1.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [24576 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const seekable = smith.valueRangeAtMost(u8, 0, 1) == 1;
    const unknown_length = smith.valueRangeAtMost(u8, 0, 1) == 1;
    const counted = smith.valueRangeAtMost(u8, 0, 1) == 1;
    const gpa = testing.allocator;
    var reader: std.Io.Reader = .fixed(input[0..len]);
    var parser: caf.Parser = .init(&reader, .{ .unknown_length = unknown_length });
    parser.enableAlac(gpa, if (seekable) seek.Seeker.fixed(&reader) else null);
    const info = parser.readHeader() catch |err| {
        parser.deinit();
        return if (err == error.OutOfMemory) err else {};
    };
    if (info.alac == null) {
        parser.deinit();
        return;
    }
    var r = DecodedReader.init(gpa, parser, info, null) catch |err| {
        parser.deinit();
        return if (err == error.OutOfMemory) err else {};
    };
    defer r.deinit();
    r.count_ahead = counted;
    _ = r.readHeader() catch |err| return if (err == error.OutOfMemory) err else {};
    var scratch: [8192]u8 = undefined;
    while (true) {
        const got = r.readData(&scratch) catch |err| return if (err == error.OutOfMemory) err else {};
        if (got.len == 0) break;
    }
    r.finish() catch {};
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.alac.bytes("alac_pakt_before_data"), &.{ 0, 0, 1 }),
    hostile.fuzzSeed(fixtures.alac.bytes("alac_pakt_after_data"), &.{ 1, 0, 0 }),
    hostile.fuzzSeed(fixtures.alac.bytes("alac_new_kuki"), &.{ 1, 1, 1 }),
    hostile.fuzzSeed(fixtures.alac.bytes("alac_priming"), &.{ 1, 0, 1 }),
    hostile.fuzzSeed(fixtures.alac.bytes("alac_ffmpeg_one_sample"), &.{ 1, 0, 0 }),
    hostile.fuzzSeed(fixtures.alac.bytes("alac_ffmpeg_level1"), &.{ 1, 0, 1 }),
    hostile.fuzzSeed(fixtures.alac.bytes("alac_data_size_unknown"), &.{ 0, 1, 0 }),
};

test "fuzz: ALAC in CAF decoded from arbitrary input" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: ALAC in CAF decoded from mutated input" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 24, 0x63616661);
}
