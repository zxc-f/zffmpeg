// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/decode.c (decode_simple_internal), fftools/ffmpeg_dec.c
// (packet_decode, the error rate, "corrupt decoded frame") and the ffmpeg
// program's input opening (avformat_find_stream_info, then the decoder) at
// the pinned reference revision describe the behavior, restated here.
//! A raw AC-3 stream decoded as the ffmpeg program decodes it (TODO.md
//! T32a): the ac3 demuxer through libavformat's generic layer (whose
//! read-ahead takes the parser's parameters), FFmpeg's float AC-3 decoder
//! (`codec/ac3dec.zig`) opened with them over each packet as decode.c
//! calls it, frame after frame until the packet is used up, delivered as
//! interleaved f32le. A frame the decoder conceals counts as decoded, as
//! the program only warns about it.
//!
//! On a seekable input, unless the caller clears `count_ahead`, the stream
//! is decoded once ahead to count its samples, the count FFmpeg's muxers
//! write when they rewrite a header at the end, as `format/aacdecode.zig`
//! does for ADTS. Without seeking there is no count. Reading checks the
//! count unless the caller takes the samples as they come (`expected` set
//! to null).

const std = @import("std");
const audio = @import("../core/audio.zig");
const diagnostics = @import("../core/diagnostics.zig");
const ac3dec = @import("../codec/ac3dec.zig");
const ac3 = @import("ac3.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");
const decoded = @import("decoded.zig");
const codecs = @import("../codec/registry.zig");

/// What reading the samples can fail with.
pub const ReadError = ac3.Error || error{
    /// The stream decodes to another sample count than counted ahead.
    FrameCountMismatch,
    /// More than two thirds of the decodes failed: the ffmpeg program's
    /// `-max_error_rate` (2/3), which fails the decoding.
    DecodeErrorRate,
    /// A frame whose channel count, layout or sample rate differs from
    /// the stream's (notes.md "AC-3"), or a stream whose parameters the
    /// read-ahead did not find.
    UnsupportedFormat,
};

/// What opening can fail with, and reading.
pub const Error = ReadError;

const Layer = demux.Layer(ac3.Demuxer);

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    sink: ?diagnostics.Sink,
    demuxer: ?*ac3.Demuxer = null,
    layer: ?Layer = null,
    decoder: ?*ac3dec.Decoder = null,
    /// The output's channels and rate: the first kept frame's, as the
    /// ffmpeg program configures its filter graph from the first decoded
    /// frame (the stream's when none decodes); every later frame keeps
    /// them (`opened`).
    channels: u32 = 0,
    mask: u64 = 0,
    sample_rate: u32 = 0,
    opened: bool = false,
    /// The first frame's downmix info, which the ffmpeg program's
    /// aresample takes as libswresample's mix levels.
    downmix: ?ac3dec.Downmix = null,
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
    /// The current frame's planes (the decoder's, until its next frame);
    /// sliced when used, as the reader moves (no slice into itself).
    planes: [ac3dec.max_channels][]const f32 = undefined,
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
    pub const max_frame: u32 = 6 * ac3dec.block_size;

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
            r.demuxer = try ac3.Demuxer.initSeekable(r.gpa, r.reader, sk);
        } else r.demuxer = try ac3.Demuxer.init(r.gpa, r.reader);
        r.layer = .init(r.gpa, r.demuxer.?);
        const layer = &r.layer.?;
        try layer.findStreamInfo();
        const params = try layer.codecParams(0);
        // A stream no frame of which decoded in the read-ahead has no rate:
        // the program fails to configure its output.
        if (params.channels == 0 or params.sample_rate == 0) return error.UnsupportedFormat;
        const decoder = try r.gpa.create(ac3dec.Decoder);
        decoder.* = ac3dec.Decoder.init(r.gpa, params.sample_rate) catch |err| {
            r.gpa.destroy(decoder);
            return err;
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
        return .{ .stream = .ac3, .codec = .f32le, .format = format, .frame_count = counted, .bits = 32 };
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
        decoded.interleave(output, r.planes[0..r.channels], r.pending[0], frames);
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
            const got = d.decode(r.packet.data) catch |err| {
                // av_err2str's text: an AC3_PARSE_ERROR_* code has none.
                var text: [48]u8 = undefined;
                const what = switch (err) {
                    error.InvalidData => "Invalid data found when processing input",
                    error.Unsupported => "Function not implemented",
                    else => std.fmt.bufPrint(&text, "Error number {d} occurred", .{ac3dec.errorCode(err)}) catch unreachable,
                };
                // avcodec_send_packet fails while the packet has given no
                // frame; once it has, avcodec_receive_frame does.
                if (r.packet.returned)
                    diagnostics.report(r.sink, .err, "Decoding error: {s}", .{what})
                else
                    diagnostics.report(r.sink, .err, "Error submitting packet to decoder: {s}", .{what});
                r.errors.decode_errors += 1;
                r.packet.data = &.{};
                continue;
            };
            r.packet.data = r.packet.data[@min(got.consumed, r.packet.data.len)..];
            const frame = got.frame orelse continue;
            const kept = r.discard.apply(frame.samples, r.packet.skip) orelse continue;
            if (frame.concealed) diagnostics.report(r.sink, .warning, "corrupt decoded frame", .{});
            // The ffmpeg program reconfigures its filter graph for a frame
            // whose channels or rate differ, which the port refuses
            // (notes.md "AC-3").
            const channels: u32 = frame.channels;
            if (!r.opened) {
                r.channels = channels;
                r.mask = frame.channel_layout;
                r.sample_rate = frame.sample_rate;
                r.downmix = frame.downmix;
                r.opened = true;
            } else if (channels != r.channels or frame.channel_layout != r.mask or frame.sample_rate != r.sample_rate) return error.UnsupportedFormat;
            r.planes = frame.planes;
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
const detect = @import("detect.zig");

/// One packet decoded as decode.c feeds it, frame after frame, its D lines
/// written (ac3_vectors.c's).
fn decodeLines(w: *std.Io.Writer, d: *ac3dec.Decoder, packet: []const u8) !void {
    var rest = packet;
    while (rest.len > 0) {
        const got = d.decode(rest) catch |err| {
            switch (err) {
                error.InvalidData => try w.writeAll("D INVALIDDATA\n"),
                error.Unsupported => try w.writeAll("D ENOSYS\n"),
                else => try w.print("D {d}\n", .{ac3dec.errorCode(err)}),
            }
            return;
        };
        if (got.frame) |f| {
            var md5: std.crypto.hash.Md5 = .init(.{});
            for (f.planes[0..f.channels]) |plane| for (plane) |v| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(v), .little);
                md5.update(&b);
            };
            var digest: [16]u8 = undefined;
            md5.final(&digest);
            try w.print("D 0 {d} {d} {x} {d} {d} {x}\n", .{ f.samples, f.channels, f.channel_layout, f.sample_rate, @intFromBool(f.concealed), &digest });
        }
        rest = rest[got.consumed..];
    }
}

/// vectors/ac3_decode.txt rendered from the port: detection, the demuxer
/// and parser's packets, and two decoders, the second on the mutations
/// the M lines name.
fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer, expected: []const u8) !void {
    inline for (fixtures.ac3.all) |fixture| {
        const bytes = fixtures.ac3.bytes(fixture.name);
        try w.print("F {s}\n", .{fixture.name});
        var reader: std.Io.Reader = .fixed(bytes);
        var input: detect.Input = undefined;
        const opened = if (input.open(&reader, .{ .file_name = fixture.name ++ ".ac3", .gpa = gpa })) |_| true else |_| false;
        defer if (opened) input.deinit();
        if (!opened or input.container != .ac3) {
            try w.writeAll("O error\n");
        } else {
            const demuxer = try ac3.Demuxer.init(gpa, input.reader());
            defer demuxer.deinit();
            var layer = Layer.init(gpa, demuxer);
            defer layer.deinit();
            try layer.findStreamInfo();
            const rate = (try layer.codecParams(0)).sample_rate;
            var d = try ac3dec.Decoder.init(gpa, rate);
            defer d.deinit();
            var m = try ac3dec.Decoder.init(gpa, rate);
            defer m.deinit();
            // The M lines of this fixture's block, in order.
            var mlines = std.mem.splitScalar(u8, expected, '\n');
            var in_block = false;
            while (try layer.next()) |p| {
                try w.print("P {d} {d}\n", .{ p.pos, p.data.len });
                try decodeLines(w, &d, p.data);
                const mline = while (mlines.next()) |l| {
                    if (std.mem.startsWith(u8, l, "F ")) in_block = std.mem.eql(u8, l[2..], fixture.name);
                    if (in_block and std.mem.startsWith(u8, l, "M ")) break l;
                } else return error.TestUnexpectedResult;
                try w.print("{s}\n", .{mline});
                var f = std.mem.tokenizeScalar(u8, mline[2..], ' ');
                var rng: signals.Rng = .{ .state = try std.fmt.parseInt(u32, f.next().?, 10) };
                const flips = try std.fmt.parseInt(u32, f.next().?, 10);
                const cut = try std.fmt.parseInt(i64, f.next().?, 10);
                const data = try gpa.dupe(u8, p.data);
                defer gpa.free(data);
                for (0..flips) |_| {
                    const bit = rng.next() % @as(u32, @intCast(data.len * 8));
                    data[bit / 8] ^= @as(u8, 0x80) >> @intCast(bit % 8);
                }
                try decodeLines(w, &m, data[0..if (cut >= 0) @intCast(cut) else data.len]);
            }
        }
    }
}

const signals = @import("../testing/signals.zig");

test "every AC-3 fixture's packets and frames are FFmpeg's (vectors/ac3_decode.txt)" {
    const gpa = testing.allocator;
    const expected = @embedFile("../testing/vectors/ac3_decode.txt");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderVectors(gpa, &out.writer, expected);
    try testing.expectEqualStrings(expected, out.written());
}

fn decodeAllBytes(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, out: *std.ArrayList(u8)) !DecodedReader.Header {
    var reader: std.Io.Reader = .fixed(bytes);
    var r = DecodedReader.init(gpa, &reader, if (seekable) .fixed(&reader) else null, null);
    defer r.deinit();
    const header = try r.readHeader();
    var scratch: [8192]u8 = undefined;
    while (true) {
        const got = try r.readData(&scratch);
        if (got.len == 0) break;
        try out.appendSlice(gpa, got);
    }
    try r.finish();
    return header;
}

test "a non-seekable AC-3 input decodes to the seekable decoding's samples and count" {
    const gpa = testing.allocator;
    inline for (.{ "ac3_ffmpeg_stereo_48k", "ac3_ffmpeg_51side_44k", "ac3_damaged", "ac3_junk_between_long" }) |name| {
        var a: std.ArrayList(u8) = .empty;
        defer a.deinit(gpa);
        const streamed = try decodeAllBytes(gpa, fixtures.ac3.bytes(name), false, &a);
        try testing.expectEqual(null, streamed.frame_count);
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(gpa);
        const seeked = try decodeAllBytes(gpa, fixtures.ac3.bytes(name), true, &b);
        try testing.expectEqualSlices(u8, b.items, a.items);
        try testing.expectEqual(seeked.frame_count.?, b.items.len / 4 / seeked.format.channelCount());
    }
}

const SweepInput = struct { bytes: []const u8, seekable: bool };

fn decodeUnderFailures(gpa: std.mem.Allocator, input: SweepInput) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = decodeAllBytes(gpa, input.bytes, input.seekable, &out) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
}

test "AC-3 decoded frees everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, SweepInput{ .bytes = fixtures.ac3.bytes("ac3_ffmpeg_short"), .seekable = true }, decodeUnderFailures);
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.fail, SweepInput{ .bytes = fixtures.ac3.bytes("ac3_ffmpeg_mono_32k")[0..1024], .seekable = false }, decodeUnderFailures);
}

/// The fuzz entry's input: a raw AC-3 stream, then whether it seeks, as 0
/// or 1: opened and decoded as the ffmpeg program does, or refused.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [8192 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const seekable = smith.valueRangeAtMost(u8, 0, 1) == 1;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = decodeAllBytes(testing.allocator, input[0..len], seekable, &out) catch |err| return if (err == error.OutOfMemory) err else {};
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.ac3.bytes("ac3_junk_prefix")[0..1600], &.{0}),
    hostile.fuzzSeed(fixtures.ac3.bytes("ac3_byteswapped")[0..1536], &.{1}),
    hostile.fuzzSeed(fixtures.ac3.bytes("ac3_ffmpeg_short"), &.{1}),
    hostile.fuzzSeed(fixtures.ac3.bytes("ac3_half_rate")[0..1536], &.{0}),
};

test "fuzz: raw AC-3 decoded" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: raw AC-3 decoded" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 32, 0x61633366);
}
