// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/decode.c (decode_simple_internal, discard_samples),
// fftools/ffmpeg_dec.c (packet_decode, the error rate) and the ffmpeg
// program's input opening (avformat_find_stream_info, then the decoder) at
// the pinned reference revision describe the behavior, restated here.
//! An MPEG audio stream decoded as the ffmpeg program decodes it (TODO.md
//! T29b, T29c): the mp3 demuxer through libavformat's generic layer, FFmpeg's
//! float decoder for the stream's codec (mp1float, mp2float or mp3float, one
//! decoder for every layer: `codec/mp3dec.zig`) over each packet as
//! decode.c calls it,
//! frame after frame until the packet is used up, and libavcodec's
//! discarding of the samples the demuxer's gapless side data asks to skip,
//! delivered as interleaved f32le.
//!
//! On a seekable input, unless the caller clears `count_ahead`, the stream
//! is decoded once ahead to count its samples, the count FFmpeg's muxers
//! write when they rewrite a header at the end, as `format/oggdecode.zig`
//! does for Ogg. Without seeking there is no count. Reading checks the count unless the caller takes the
//! samples as they come (`expected` set to null).

const std = @import("std");
const audio = @import("../core/audio.zig");
const metadata = @import("../core/metadata.zig");
const diagnostics = @import("../core/diagnostics.zig");
const mp3dec = @import("../codec/mp3dec.zig");
const mp3 = @import("mp3.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");
const decoded = @import("decoded.zig");
const codecs = @import("../codec/registry.zig");

/// What reading the samples can fail with.
pub const ReadError = mp3.Error || decoded.DeliveryError || error{
    /// The stream decodes to another sample count than counted ahead.
    FrameCountMismatch,
    /// More than two thirds of the decodes failed: the ffmpeg program's
    /// `-max_error_rate` (2/3), which fails the decoding.
    DecodeErrorRate,
    /// A frame whose channel count or sample rate differs from the
    /// stream's (notes.md "MP3 decoding").
    UnsupportedFormat,
};

/// What opening can fail with, and reading.
pub const Error = ReadError;

const Layer = demux.Layer(mp3.Demuxer);

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    sink: ?diagnostics.Sink,
    demuxer: ?*mp3.Demuxer = null,
    layer: ?Layer = null,
    /// Allocated: its frame state is about 40 KiB.
    decoder: ?*mp3dec.Decoder = null,
    /// The output's channels and rate: the first kept frame's, as the
    /// ffmpeg program configures its filter graph from the first decoded
    /// frame (the stream's when none decodes); every later frame keeps
    /// them (`opened`).
    channels: u2 = 0,
    sample_rate: u32 = 0,
    opened: bool = false,
    /// The decoder context's sample rate, which the next frame carries:
    /// mp3float allocates a frame (ff_get_buffer stamps it with the
    /// context's rate) before it sets the context's rate from the frame's
    /// header, so each frame carries the rate of the last frame decoded,
    /// the stream's before the first (notes.md "MP3 decoding").
    context_rate: u32 = 0,
    /// The current packet's bytes not yet decoded (borrowed from the layer
    /// until its next packet), what follows it in FFmpeg's memory, its
    /// skip-samples side data, and whether it has given a frame yet.
    packet: struct {
        data: []const u8 = &.{},
        tail: [demux.tail_len]u8 = @splat(0),
        skip: ?[2]u32 = null,
        returned: bool = false,
    } = .{},
    /// The current frame's samples not yet delivered: a range of the
    /// decoder's planes.
    pending: [2]u32 = .{ 0, 0 },
    discard: decoded.Discard = .{},
    delivered: u64 = 0,
    expected: ?u64 = null,
    ended: bool = false,
    /// This reader is the counting pass of another.
    counting: bool = false,
    /// Count the samples ahead on a seekable input, for a header written
    /// before the samples on an output that cannot be rewritten; a caller
    /// that needs no count clears it before `readHeader` and decodes once.
    count_ahead: bool = true,
    /// The ffmpeg program's decoder statistics.
    errors: decoded.ErrorRate = .{},

    pub const Header = decoded.Header;

    /// The decoder's largest frame (the ffmpeg program's packets).
    pub const max_frame: u32 = mp3dec.max_samples;

    /// Reads `reader` from its start; `seeker`, when the input can seek,
    /// moves it there and lets the demuxer read its durations.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker, sink: ?diagnostics.Sink) DecodedReader {
        return .{ .gpa = gpa, .reader = reader, .seeker = seeker, .sink = sink };
    }

    pub fn deinit(r: *DecodedReader) void {
        if (r.decoder) |d| r.gpa.destroy(d);
        if (r.layer) |*l| l.deinit();
        if (r.demuxer) |d| d.deinit();
        r.* = undefined;
    }

    /// The demuxer, avformat_find_stream_info and the decoder opened, as
    /// the ffmpeg program opens an input.
    pub fn readHeader(r: *DecodedReader) Error!Header {
        std.debug.assert(r.demuxer == null);
        // The counting pass, from the start, before this one.
        var counted: ?u64 = null;
        if (r.seeker != null and r.count_ahead and !r.counting) {
            var pass = init(r.gpa, r.reader, r.seeker, null);
            pass.counting = true;
            defer pass.deinit();
            _ = try pass.readHeader();
            var scratch: [4096]u8 = undefined;
            while ((try pass.readData(&scratch)).len != 0) {}
            // A decoding the program fails, failed before any output.
            try pass.errors.check();
            counted = pass.delivered;
        }
        if (r.seeker) |sk| {
            sk.seekTo(0) catch return error.IoFailure;
            r.demuxer = try mp3.Demuxer.initSeekable(r.gpa, r.reader, sk, .{});
        } else r.demuxer = try mp3.Demuxer.init(r.gpa, r.reader, .{});
        r.layer = .init(r.gpa, r.demuxer.?);
        const layer = &r.layer.?;
        try layer.findStreamInfo();
        const params = try layer.codecParams(0);
        // The parser names the layer, which picks FFmpeg's decoder; all
        // three decode every layer.
        const stream: codecs.Codec = switch (params.mpa_codec orelse .mp3) {
            .mp1 => .mp1,
            .mp2 => .mp2,
            .mp3 => .mp3,
        };
        const channels = std.math.cast(u2, params.channels) orelse return error.UnsupportedFormat;
        if (channels == 0 or params.sample_rate == 0) return error.UnsupportedFormat;
        const decoder = try r.gpa.create(mp3dec.Decoder);
        decoder.* = .init;
        r.decoder = decoder;
        r.channels = channels;
        r.sample_rate = params.sample_rate;
        r.context_rate = params.sample_rate;
        r.expected = counted;
        // The first frame, which sets the output's format; `readData`
        // still returns it first.
        _ = try r.nextFrame();
        r.opened = true;
        const format = audio.Format.initLayout(r.sample_rate, .default(r.channels), .flt) catch return error.UnsupportedFormat;
        return .{ .stream = stream, .codec = .f32le, .format = format, .frame_count = counted, .bits = 32 };
    }

    /// The input's tags (ID3v2, else ID3v1, and APE), under FFmpeg's
    /// names: the format's, from `readHeader`.
    pub fn tags(r: *const DecodedReader) *const metadata.Dictionary {
        return &r.demuxer.?.tags;
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
    /// remain (a frame fits in 4 bytes a channel); empty at the end.
    /// Insufficient space returns `OutputTooSmall` and preserves samples.
    pub fn readData(r: *DecodedReader, output: []u8) ReadError![]u8 {
        while (r.pendingFrames() == 0) {
            if (!try r.nextFrame()) return output[0..0];
        }
        const d = r.decoder.?;
        var planes: [2][]const f32 = undefined;
        for (0..r.channels) |c| planes[c] = &d.output[c];
        return decoded.readFloat(output, planes[0..r.channels], &r.pending, &r.delivered, r.expected);
    }

    /// The next frame libavcodec returns into `pending`; false at the end.
    /// A frame the decoder refuses is reported and the rest of its packet
    /// dropped, as the ffmpeg program and decode.c drop it.
    fn nextFrame(r: *DecodedReader) ReadError!bool {
        if (r.ended) return false;
        const d = r.decoder.?;
        while (true) {
            if (r.packet.data.len == 0) {
                const p = try r.layer.?.next() orelse {
                    r.ended = true;
                    return false;
                };
                r.packet = .{ .data = p.data, .tail = p.tail, .skip = p.skip };
                continue;
            }
            const got = d.decodeFrame(r.packet.data, &r.packet.tail) catch |err| switch (err) {
                error.InvalidData => {
                    // avcodec_send_packet fails while the packet has given
                    // no frame; once it has, avcodec_receive_frame does.
                    if (r.packet.returned)
                        diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{})
                    else
                        diagnostics.report(r.sink, .err, "Error submitting packet to decoder: Invalid data found when processing input", .{});
                    r.errors.decode_errors += 1;
                    r.packet.data = &.{};
                    continue;
                },
            };
            r.packet.data = r.packet.data[got.consumed..];
            const frame = got.frame orelse continue;
            const frame_rate = r.context_rate;
            r.context_rate = frame.sample_rate;
            const kept = r.discard.apply(frame.samples, r.packet.skip) orelse continue;
            // The ffmpeg program reconfigures its filter graph for a frame
            // whose channels or rate differ, which the port refuses
            // (notes.md "MP3 decoding").
            if (!r.opened) {
                r.channels = frame.channels;
                r.sample_rate = frame_rate;
                r.opened = true;
            } else if (frame.channels != r.channels or frame_rate != r.sample_rate) return error.UnsupportedFormat;
            r.packet.returned = true;
            r.errors.frames_decoded += 1;
            r.pending = kept;
            return true;
        }
    }

    /// Checks the decoding's error rate, and that the stream decoded to
    /// the count found ahead.
    pub fn finish(r: *DecodedReader) ReadError!void {
        std.debug.assert(r.pendingFrames() == 0);
        try r.errors.check();
        if (r.expected) |expected| {
            if (r.delivered != expected) return error.FrameCountMismatch;
        }
    }
};

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const hostile = @import("../testing/hostile.zig");

/// Every sample `r` decodes, as `readData` gives them.
fn decodeAll(r: *DecodedReader, out: *std.ArrayList(u8)) !DecodedReader.Header {
    const header = try r.readHeader();
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = try r.readData(&scratch);
        if (got.len == 0) break;
        try out.appendSlice(testing.allocator, got);
    }
    try r.finish();
    return header;
}

/// The samples FFmpeg's decoder keeps for `name`: the sum of the `D`
/// lines of its block in vectors/mp3_decode.txt.
fn vectorSamples(name: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, @embedFile("../testing/vectors/mp3_decode.txt"), '\n');
    var in_block = false;
    var total: u64 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "F ")) {
            if (in_block) break;
            in_block = std.mem.eql(u8, line[2..], name);
        } else if (in_block and std.mem.startsWith(u8, line, "D ")) {
            var fields = std.mem.splitScalar(u8, line[2..], ' ');
            total += try std.fmt.parseInt(u64, fields.next().?, 10);
        }
    }
    return total;
}

test "a non-seekable input decodes to the seekable decoding's samples, FFmpeg's count" {
    const gpa = testing.allocator;
    inline for (.{ "mp3_l3_long_stereo", "mp3_l3_reservoir_mono", "mp3_l3_mpeg2_24k_switch", "mp3_l3_bad_big_values", "mp1_layer1_joint_crc", "mp2_layer2_44k_dual", "mp2_layer2_mpeg2_joint", "mp3_layer_change" }) |name| {
        const bytes = fixtures.mp3.bytes(name);
        var streamed: std.ArrayList(u8) = .empty;
        defer streamed.deinit(gpa);
        var stream_reader: std.Io.Reader = .fixed(bytes);
        var r = DecodedReader.init(gpa, &stream_reader, null, null);
        defer r.deinit();
        const header = try decodeAll(&r, &streamed);
        // Without seeking there is no count ahead.
        try testing.expectEqual(null, header.frame_count);

        var seeked: std.ArrayList(u8) = .empty;
        defer seeked.deinit(gpa);
        var file_reader: std.Io.Reader = .fixed(bytes);
        var s = DecodedReader.init(gpa, &file_reader, .fixed(&file_reader), null);
        defer s.deinit();
        const seeked_header = try decodeAll(&s, &seeked);

        try testing.expect(streamed.items.len > 0);
        try testing.expectEqualSlices(u8, seeked.items, streamed.items);
        try testing.expectEqual(seeked_header.frame_count, r.delivered);
        try testing.expectEqual(try vectorSamples(name), r.delivered);
    }
}

test "a gapless stream keeps its end padding from a pipe, as FFmpeg's does" {
    const gpa = testing.allocator;
    const bytes = fixtures.mp3.bytes("mp3_l3_gapless");
    // From a file the demuxer reads the end and asks to drop the encoder's
    // padding; from a pipe it cannot (FFmpeg: 267640 bytes of f32le
    // stereo, 263040 from the file).
    for ([_]bool{ false, true }) |seekable| {
        var reader: std.Io.Reader = .fixed(bytes);
        var r = DecodedReader.init(gpa, &reader, if (seekable) .fixed(&reader) else null, null);
        defer r.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        _ = try decodeAll(&r, &out);
        try testing.expectEqual(@as(usize, if (seekable) 263040 else 267640), out.items.len);
        if (seekable) try testing.expectEqual(try vectorSamples("mp3_l3_gapless"), r.delivered);
    }
}

test "a damaged stream fails the error rate; free format does not open" {
    const gpa = testing.allocator;
    const cases = [_]struct { bytes: []const u8, err: Error }{
        .{ .bytes = fixtures.mp3.bytes("mp3_free_format"), .err = error.InvalidMp3 },
        // 23 of its 24 frames fail (FFmpeg: "Decode error rate 0.958333").
        .{ .bytes = fixtures.mp3.bytes("mp3_rate_change"), .err = error.DecodeErrorRate },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |seekable| {
            var reader: std.Io.Reader = .fixed(case.bytes);
            var r = DecodedReader.init(gpa, &reader, if (seekable) .fixed(&reader) else null, null);
            defer r.deinit();
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            try testing.expectError(case.err, decodeAll(&r, &out));
        }
    }
}

test "the output opens with the first frame's channels; a later change is refused" {
    const gpa = testing.allocator;
    // The mono fixture's frames, then the stereo fixture's. ffprobe
    // reports 2 channels; the ffmpeg program writes mono, from the first
    // frame, and downmixes the stereo frames, which the port refuses.
    const mono = fixtures.mp3.bytes("mp3_l3_reservoir_mono");
    const stereo = fixtures.mp3.bytes("mp3_l3_long_stereo");
    const joined = try std.mem.concat(gpa, u8, &.{ mono, stereo });
    defer gpa.free(joined);
    var reader: std.Io.Reader = .fixed(joined);
    var r = DecodedReader.init(gpa, &reader, null, null);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectError(error.UnsupportedFormat, decodeAll(&r, &out));
    try testing.expect(r.delivered > 0);
}

const SweepInput = struct { bytes: []const u8, seekable: bool };

/// Opens and decodes `input.bytes` through a fresh demuxer and decoder,
/// seekable (the counting pass included) or not; any error but an
/// allocation failure fails the test.
fn decodeUnderFailures(gpa: std.mem.Allocator, input: SweepInput) !void {
    var reader: std.Io.Reader = .fixed(input.bytes);
    var r = DecodedReader.init(gpa, &reader, if (input.seekable) .fixed(&reader) else null, null);
    defer r.deinit();
    _ = r.readHeader() catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = r.readData(&scratch) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
        if (got.len == 0) break;
    }
    r.finish() catch return error.TestUnexpectedResult;
}

test "an MP3 stream decoded frees everything under every allocation and remap failure" {
    // With remaps allowed, whether a growing buffer's remap succeeds in
    // place depends on the testing allocator's heap after the earlier runs,
    // so a run's allocation count can differ from the counting run's
    // (`NondeterministicMemoryUsage` for mp3_l3_short_ms in ReleaseSafe);
    // the second stream runs with every remap failing only, as the Ogg
    // sweep's longer inputs do.
    const cases = .{ .{ "mp3_l3_gapless", true, hostile.Remaps.both }, .{ "mp3_l3_short_ms", false, hostile.Remaps.fail } };
    inline for (cases) |case| {
        const input: SweepInput = .{ .bytes = fixtures.mp3.bytes(case[0]), .seekable = case[1] };
        try hostile.checkAllocationFailuresWith(testing.allocator, case[2], input, decodeUnderFailures);
    }
}

/// The fuzz entry's input: the file, then whether the input seeks (the
/// counting pass and the durations) and whether the reader takes the
/// samples as they come (`expected` cleared), as 0 or 1.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [16384 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const seekable = smith.valueRangeAtMost(u8, 0, 1) == 1;
    const uncounted = smith.valueRangeAtMost(u8, 0, 1) == 1;
    var reader: std.Io.Reader = .fixed(input[0..len]);
    var r = DecodedReader.init(testing.allocator, &reader, if (seekable) .fixed(&reader) else null, null);
    defer r.deinit();
    _ = r.readHeader() catch |err| return if (err == error.OutOfMemory) err else {};
    if (uncounted) r.expected = null;
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = r.readData(&scratch) catch |err| return if (err == error.OutOfMemory) err else {};
        if (got.len == 0) break;
    }
    r.finish() catch {};
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_gapless"), &.{ 1, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_reservoir_mono"), &.{ 0, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_intensity_ms"), &.{ 1, 1 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_l3_truncated"), &.{ 0, 1 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp3_xing_lame"), &.{ 1, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp2_layer2_joint_crc"), &.{ 1, 0 }),
    hostile.fuzzSeed(fixtures.mp3.bytes("mp1_layer1_mono_32k"), &.{ 0, 1 }),
};

test "fuzz: an MP3 stream decoded from arbitrary input" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: an MP3 stream decoded from mutated input" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 24, 0x6d703364);
}
