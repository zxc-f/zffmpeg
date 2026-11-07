// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/decode.c (decode_simple_internal, discard_samples),
// fftools/ffmpeg_dec.c (packet_decode, the error rate) and the ffmpeg
// program's input opening (avformat_find_stream_info, then the decoder) at
// the pinned reference revision describe the behavior, restated here.
//! An ADTS stream decoded as the ffmpeg program decodes it (TODO.md T30b):
//! the aac demuxer through libavformat's generic layer (whose read-ahead runs
//! the decoder for the stream's parameters), FFmpeg's float AAC decoder
//! (`codec/aacdec.zig`) opened with them over each packet as decode.c calls
//! it, frame after frame until the packet is used up, and libavcodec's
//! discarding of the samples a faac stream asks to skip, delivered as
//! interleaved f32le.
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
const aacdec = @import("../codec/aacdec.zig");
const aac = @import("aac.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");
const decoded = @import("decoded.zig");
const codecs = @import("../codec/registry.zig");

/// What reading the samples can fail with.
pub const ReadError = aac.Error || error{
    /// The stream decodes to another sample count than counted ahead.
    FrameCountMismatch,
    /// More than two thirds of the decodes failed: the ffmpeg program's
    /// `-max_error_rate` (2/3), which fails the decoding.
    DecodeErrorRate,
    /// A frame whose channel count, layout or sample rate differs from
    /// the stream's, or an object type or tool the decoder does not port
    /// (notes.md "AAC decoder scope").
    UnsupportedFormat,
};

/// What opening can fail with, and reading.
pub const Error = ReadError;

const Layer = demux.Layer(aac.Demuxer);

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    sink: ?diagnostics.Sink,
    demuxer: ?*aac.Demuxer = null,
    layer: ?Layer = null,
    decoder: ?*aacdec.Decoder = null,
    /// The output's channels and rate: the first kept frame's, as the
    /// ffmpeg program configures its filter graph from the first decoded
    /// frame (the stream's when none decodes); every later frame keeps
    /// them (`opened`).
    channels: u32 = 0,
    mask: u64 = 0,
    sample_rate: u32 = 0,
    opened: bool = false,
    /// The current packet's bytes not yet decoded (borrowed from the layer
    /// until its next packet), its skip-samples side data, and whether it has given a frame yet.
    packet: struct {
        data: []const u8 = &.{},
        skip: ?[2]u32 = null,
        returned: bool = false,
    } = .{},
    /// The current frame's samples not yet delivered: a range of the
    /// decoder's planes.
    pending: [2]u32 = .{ 0, 0 },
    /// The current frame's planes (the decoder's, until its next frame).
    frame_planes: []const []const f32 = &.{},
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
    pub const max_frame: u32 = 1024;

    /// Reads `reader` from its start; `seeker`, when the input can seek,
    /// moves it there and lets the demuxer read its durations.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker, sink: ?diagnostics.Sink) DecodedReader {
        return .{ .gpa = gpa, .reader = reader, .seeker = seeker, .sink = sink };
    }

    pub fn deinit(r: *DecodedReader) void {
        if (r.decoder) |d| {
            d.deinit();
            r.gpa.destroy(d);
        }
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
            r.demuxer = try aac.Demuxer.initSeekable(r.gpa, r.reader, sk, .{});
        } else r.demuxer = try aac.Demuxer.init(r.gpa, r.reader, .{});
        r.layer = .init(r.gpa, r.demuxer.?);
        const layer = &r.layer.?;
        try layer.findStreamInfo();
        const params = try layer.codecParams(0);
        // A stream no frame of which decoded in the read-ahead has no rate:
        // the program fails to configure its output.
        if (params.channels == 0 or params.sample_rate == 0) return error.UnsupportedFormat;
        const decoder = try r.gpa.create(aacdec.Decoder);
        decoder.* = aacdec.Decoder.init(r.gpa, params.sample_rate, params.channels) catch |err| {
            r.gpa.destroy(decoder);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.UnsupportedFormat,
            };
        };
        // `deinit` frees it from here on.
        r.decoder = decoder;
        r.channels = params.channels;
        r.mask = params.mask;
        r.sample_rate = params.sample_rate;
        r.expected = counted;
        // The first frame, which sets the output's format; `readData`
        // still returns it first.
        _ = try r.nextFrame();
        r.opened = true;
        const layout: audio.ChannelLayout = if (r.mask != 0) .{ .native = r.mask } else .{ .unspecified = std.math.cast(u8, r.channels) orelse return error.UnsupportedFormat };
        const format = audio.Format.initLayout(r.sample_rate, layout, .flt) catch return error.UnsupportedFormat;
        return .{ .stream = .aac, .codec = .f32le, .format = format, .frame_count = counted, .bits = 32 };
    }

    /// The input's tags (ID3v1, else APE, else ID3v2), under FFmpeg's
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
    pub fn readData(r: *DecodedReader, output: []u8) ReadError![]u8 {
        while (r.pendingFrames() == 0) {
            if (!try r.nextFrame()) return output[0..0];
        }
        const frame_bytes = 4 * @as(usize, r.channels);
        const frames = @min(output.len / frame_bytes, r.pendingFrames());
        std.debug.assert(frames > 0);
        if (r.expected) |expected| {
            if (r.delivered + frames > expected) return error.FrameCountMismatch;
        }
        decoded.interleave(output, r.frame_planes, r.pending[0], frames);
        r.pending[0] += @intCast(frames);
        r.delivered += frames;
        return output[0 .. frames * frame_bytes];
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
                r.packet = .{ .data = p.data, .skip = p.skip };
                continue;
            }
            const got = d.decode(r.packet.data) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnsupportedFeature => return error.UnsupportedFormat,
                else => {
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
            r.packet.data = r.packet.data[@min(got.consumed, r.packet.data.len)..];
            // A faac stream's skip: decode_fill sets avci->skip_samples,
            // which discard_samples applies to the next frame returned.
            if (d.skip_samples != 0) {
                r.discard.skip = d.skip_samples;
                d.skip_samples = 0;
            }
            const frame = got.frame orelse continue;
            const kept = r.discard.apply(frame.samples, r.packet.skip) orelse continue;
            // The ffmpeg program reconfigures its filter graph for a frame
            // whose channels or rate differ, which the port refuses
            // (notes.md "AAC decoder scope").
            const channels: u32 = @intCast(frame.planes.len);
            if (!r.opened) {
                r.channels = channels;
                r.mask = frame.mask;
                r.sample_rate = frame.sample_rate;
                r.opened = true;
            } else if (channels != r.channels or frame.mask != r.mask or frame.sample_rate != r.sample_rate) return error.UnsupportedFormat;
            r.frame_planes = frame.planes;
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

/// Opens `r` and reads every sample into `out`, then finishes.
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

/// The samples FFmpeg's decoder gives for fixture `name`
/// (vectors/aac_decode.txt's D lines).
fn vectorSamples(name: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, @embedFile("../testing/vectors/aac_decode.txt"), '\n');
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
    inline for (.{ "aac_ffmpeg_lc_44k_stereo", "aac_ffmpeg_mono_8k", "aac_ffmpeg_5point1", "aac_ffmpeg_7point1_wide", "aac_ffmpeg_short" }) |name| {
        const bytes = fixtures.aac.bytes(name);
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
        try testing.expectEqual(header.format, seeked_header.format);
    }
}

test "a stream none of whose packets decodes has no rate and does not open" {
    const gpa = testing.allocator;
    inline for (.{ "aac_lc_stereo_44k", "aac_main_96k", "aac_ltp_7350_8ch", "aac_pce_mpeg2" }) |name| {
        for ([_]bool{ false, true }) |seekable| {
            var reader: std.Io.Reader = .fixed(fixtures.aac.bytes(name));
            var r = DecodedReader.init(gpa, &reader, if (seekable) .fixed(&reader) else null, null);
            defer r.deinit();
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            try testing.expectError(error.UnsupportedFormat, decodeAll(&r, &out));
        }
    }
}

test "the output opens with the first frame's channels and rate; a later change is refused" {
    const gpa = testing.allocator;
    // The mono 8 kHz fixture's frames, then the stereo 44.1 kHz one's: the
    // decoder reconfigures, and the ffmpeg program its filter graph, which
    // the port refuses.
    const joined = try std.mem.concat(gpa, u8, &.{ fixtures.aac.bytes("aac_ffmpeg_mono_8k"), fixtures.aac.bytes("aac_ffmpeg_lc_44k_stereo") });
    defer gpa.free(joined);
    var reader: std.Io.Reader = .fixed(joined);
    var r = DecodedReader.init(gpa, &reader, null, null);
    defer r.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try testing.expectError(error.UnsupportedFormat, decodeAll(&r, &out));
    try testing.expectEqual(try vectorSamples("aac_ffmpeg_mono_8k"), r.delivered);
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

test "an ADTS stream decoded frees everything under every allocation and remap failure" {
    const cases = .{ .{ "aac_ffmpeg_short", true, hostile.Remaps.both }, .{ "aac_ffmpeg_5point1", false, hostile.Remaps.fail } };
    inline for (cases) |case| {
        const input: SweepInput = .{ .bytes = fixtures.aac.bytes(case[0]), .seekable = case[1] };
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
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_short"), &.{ 1, 0 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_mono_8k"), &.{ 0, 0 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_pns_22k"), &.{ 1, 1 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_ffmpeg_5point1"), &.{ 0, 1 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_id3v2_between"), &.{ 1, 0 }),
    hostile.fuzzSeed(fixtures.aac.bytes("aac_pce_mpeg2"), &.{ 1, 0 }),
};

test "fuzz: an ADTS stream decoded from arbitrary input" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: an ADTS stream decoded from mutated input" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 24, 0x61616364);
}
