// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/wavdec.c (wav_read_packet), libavcodec/decode.c
// (decode_simple_internal), encode.c (pad_last_frame), adpcmenc.c's
// registration (mono and stereo, no small last frame) and fftools/
// ffmpeg_dec.c (the decode error rate) at the pinned reference revision
// describe the behavior, restated here.
//! ADPCM in WAV (TODO.md T31a), as the ffmpeg program reads and writes it:
//! `DecodedReader` decodes the blocks of an IMA WAV or Microsoft ADPCM
//! stream with FFmpeg's decoders (`codec/adpcm.zig`), packet by packet as
//! the WAV demuxer reads them and frame by frame as decode.c calls the
//! decoder, delivered as interleaved s16le; `Writer` encodes 16-bit samples
//! with FFmpeg's encoders into a WAV file, in frames of the encoder's
//! `frame_size`, the last one padded with silence.

const std = @import("std");
const audio = @import("../core/audio.zig");
const diagnostics = @import("../core/diagnostics.zig");
const adpcm = @import("../codec/adpcm.zig");
const wav = @import("wav.zig");
const seek = @import("seek.zig");
const decoded = @import("decoded.zig");

/// What reading the samples can fail with: the WAV parser's errors,
/// `UnsupportedFormat` for a stream FFmpeg's decoder does not open (too
/// many channels, IMA WAV bits outside 2 to 5), and the decoding's.
pub const ReadError = wav.Error || error{
    /// The stream decodes to another sample count than its blocks give
    /// when every header is valid, which a header written first declared.
    FrameCountMismatch,
    /// More than two thirds of the decodes failed: the ffmpeg program's
    /// `-max_error_rate` (2/3), which fails the decoding.
    DecodeErrorRate,
};

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    /// The WAV parser, past its header; its `readData` gives the packets.
    parser: wav.Parser,
    adpcm: wav.Adpcm,
    format: audio.Format,
    sink: ?diagnostics.Sink,
    decoder: adpcm.Decoder,
    /// One packet of the demuxer's (owned), and its bytes not yet decoded.
    packet_buf: []u8,
    packet: []const u8 = &.{},
    /// Whether the current packet has given a frame.
    returned: bool = false,
    /// Each channel's samples of the current frame (owned storage).
    plane_buf: []i16,
    planes: [6][]i16 = undefined,
    /// The current frame's samples not yet delivered.
    pending: [2]u32 = .{ 0, 0 },
    delivered: u64 = 0,
    /// The count `readHeader` reported, checked by `readData` and `finish`.
    expected: ?u64 = null,
    ended: bool = false,
    /// Report the stream's sample count from its blocks' sizes, for a
    /// header written before the samples on an output that cannot be
    /// rewritten; a caller that needs no count clears it before
    /// `readHeader`, and a block that fails to decode is then not an error.
    count_ahead: bool = true,
    errors: decoded.ErrorRate = .{},

    pub const Header = decoded.Header;

    /// Takes over `parser`, whose `readHeader` gave `info` (an ADPCM
    /// stream), and opens FFmpeg's decoder; its refusal is
    /// `UnsupportedFormat`, as the ffmpeg program fails to open it.
    pub fn init(gpa: std.mem.Allocator, parser: wav.Parser, info: wav.Info, sink: ?diagnostics.Sink) ReadError!DecodedReader {
        const a = info.adpcm.?; // the caller dispatches on it
        const decoder = adpcm.Decoder.init(a.params) catch return error.UnsupportedFormat;
        const packet_buf = try gpa.alloc(u8, a.packet_len);
        errdefer gpa.free(packet_buf);
        // The largest frame: a whole block, or the packet when it is
        // shorter (samplesIn takes at most `block_align` bytes; past
        // INT_MAX / 14 it finds none, so a longer packet would size
        // nothing for its shorter last one).
        const most: usize = a.params.samplesIn(@min(a.packet_len, a.params.block_align));
        const channels: usize = a.params.channels;
        const plane_buf = try gpa.alloc(i16, most * channels);
        var r: DecodedReader = .{
            .gpa = gpa,
            .parser = parser,
            .adpcm = a,
            .format = info.format,
            .sink = sink,
            .decoder = decoder,
            .packet_buf = packet_buf,
            .plane_buf = plane_buf,
        };
        for (0..channels) |c| r.planes[c] = plane_buf[c * most ..][0..most];
        return r;
    }

    pub fn deinit(r: *DecodedReader) void {
        r.gpa.free(r.packet_buf);
        r.gpa.free(r.plane_buf);
        r.* = undefined;
    }

    /// The decoded stream: interleaved s16, the count the blocks give
    /// when `count_ahead` asks for one.
    pub fn readHeader(r: *DecodedReader) ReadError!Header {
        const counted: ?u64 = if (r.count_ahead) r.adpcm.samples() else null;
        r.expected = counted;
        var format = r.format;
        format.sample_format = .s16;
        const stream: @FieldType(Header, "stream") = switch (r.adpcm.params.codec) {
            .ima_wav => .adpcm_ima_wav,
            .ms => .adpcm_ms,
        };
        return .{ .stream = stream, .codec = .s16le, .format = format, .frame_count = counted, .bits = 16 };
    }

    /// The first decoded frame's sample count (the ffmpeg program's FLAC
    /// encoder takes it as its block size); null for a stream without
    /// one. `readData` still returns it first.
    pub fn firstFrameSamples(r: *DecodedReader) ReadError!?u32 {
        std.debug.assert(r.delivered == 0);
        if (r.pendingFrames() == 0 and !try r.nextFrame()) return null;
        return r.pendingFrames();
    }

    /// The largest frame the decoder gives: a block, or a shorter packet.
    pub fn maxFrame(r: *const DecodedReader) u32 {
        return @intCast(r.planes[0].len);
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
        const channels: usize = r.adpcm.params.channels;
        const frame_bytes = 2 * channels;
        const frames = try decoded.outputFrames(output.len, frame_bytes, r.pendingFrames(), r.delivered, r.expected);
        for (0..frames) |f| {
            for (0..channels) |c| {
                std.mem.writeInt(i16, output[(f * channels + c) * 2 ..][0..2], r.planes[c][r.pending[0] + f], .little);
            }
        }
        r.pending[0] += @intCast(frames); // at most the u32 pending count
        r.delivered += frames;
        return output[0 .. frames * frame_bytes];
    }

    /// The next frame the decoder gives, from the current packet or the
    /// next; false at the end of the data. A frame the decoder refuses is
    /// reported and the rest of its packet dropped, as decode.c and the
    /// ffmpeg program drop it.
    fn nextFrame(r: *DecodedReader) ReadError!bool {
        if (r.ended) return false;
        const channels = r.adpcm.params.channels;
        while (true) {
            if (r.packet.len == 0) {
                const got = try r.parser.readData(r.packet_buf);
                if (got.len == 0) {
                    r.ended = true;
                    return false;
                }
                r.packet = got;
                r.returned = false;
            }
            const frame = r.decoder.decode(r.packet, r.planes[0..channels]) catch |err| switch (err) {
                error.InvalidData => {
                    // avcodec_send_packet fails while the packet has given
                    // no frame; once it has, avcodec_receive_frame does.
                    if (r.returned)
                        diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{})
                    else
                        diagnostics.report(r.sink, .err, "Error submitting packet to decoder: Invalid data found when processing input", .{});
                    r.errors.decode_errors += 1;
                    r.packet = &.{};
                    continue;
                },
            };
            r.packet = r.packet[frame.consumed..];
            r.returned = true;
            r.errors.frames_decoded += 1;
            r.pending = .{ 0, frame.samples };
            return true;
        }
    }

    /// The rest of the WAV stream (`wav.Parser.finish`), then the
    /// decoding's error rate, and the count `readHeader` reported.
    pub fn finish(r: *DecodedReader) ReadError!void {
        std.debug.assert(r.pendingFrames() == 0);
        try r.parser.finish();
        try r.errors.check();
        if (r.expected) |expected| {
            if (r.delivered != expected) return error.FrameCountMismatch;
        }
    }
};

/// The encoders' options: FFmpeg's `block_size` and `-trellis`.
pub const EncodeOptions = adpcm.EncodeOptions;

/// The checks `Writer.check` and `Writer.begin` share: the WAV header's,
/// and the encoder's options (`InvalidOption`).
pub const HeaderError = wav.HeaderError || EncodeOptions.Error;

pub const WriteError = wav.WriteError || EncodeOptions.Error || error{
    OutOfMemory,
    /// The trellis search lost every path, where FFmpeg's encoder crashes
    /// (notes.md "ADPCM").
    TrellisOverflow,
};

pub const RewriteError = WriteError || error{IoFailure};

/// Writes an IMA WAV or Microsoft ADPCM stream to a WAV file: 16-bit
/// samples in, grouped into frames of the encoder's `frame_size` as the
/// ffmpeg program's filter graph groups them, the last one padded with
/// silence as encode.c pads it, each encoded block written after the
/// header (`wav.Writer`).
pub const Writer = struct {
    gpa: std.mem.Allocator,
    wav: wav.Writer,
    encoder: adpcm.Encoder,
    /// Each channel's samples of the frame being filled (owned), and how
    /// many it holds.
    pending: []i16,
    pending_len: u32 = 0,
    /// One encoded block (owned).
    block: []u8,

    /// The coding `check` and `begin` give the WAV writer: the encoder's
    /// mono or stereo layouts (two unnamed channels, which the ffmpeg
    /// program guesses as stereo, included; notes.md "ADPCM" for others),
    /// s16 samples, and its options.
    fn codingFor(codec: adpcm.Codec, format: audio.Format, options: EncodeOptions) HeaderError!wav.AdpcmCoding {
        if (format.sample_format != .s16) return error.UnsupportedFormat;
        const layout_ok = switch (format.layout) {
            .unspecified => |count| count == 1 or count == 2,
            .native, .custom => format.layout.eql(&audio.ChannelLayout.mono) or format.layout.eql(&audio.ChannelLayout.stereo),
        };
        if (!layout_ok) return error.UnsupportedFormat;
        const bs = try options.check();
        return .{ .codec = codec, .block_size = @intCast(bs), .frame_size = adpcm.encoderFrameSize(codec, format.channelCount(), bs) };
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists; null `frame_count` for a
    /// header rewritten at the end.
    pub fn check(codec: adpcm.Codec, format: audio.Format, frame_count: ?u64, options: EncodeOptions, wav_options: wav.WriteOptions) HeaderError!void {
        const coding = try codingFor(codec, format, options);
        try wav.Writer.checkCoding(.{ .adpcm = coding }, format, frame_count orelse 0, wav_options);
    }

    /// Checks the request, opens the encoder and writes the header for
    /// `frame_count` samples a channel, or, null, for none until
    /// `rewriteHeader` (a seekable output).
    pub fn begin(gpa: std.mem.Allocator, out: *std.Io.Writer, codec: adpcm.Codec, format: audio.Format, frame_count: ?u64, options: EncodeOptions, wav_options: wav.WriteOptions) WriteError!Writer {
        const coding = try codingFor(codec, format, options);
        const channels: usize = format.channelCount();
        var encoder: adpcm.Encoder = try .init(gpa, codec, @intCast(channels), options);
        errdefer encoder.deinit();
        const pending = try gpa.alloc(i16, channels * coding.frame_size);
        errdefer gpa.free(pending);
        const block = try gpa.alloc(u8, coding.block_size);
        errdefer gpa.free(block);
        const header: wav.Writer = if (frame_count) |count|
            try .beginCoding(out, .{ .adpcm = coding }, format, count, wav_options)
        else
            try .beginDeferredCoding(out, .{ .adpcm = coding }, format, wav_options);
        return .{ .gpa = gpa, .wav = header, .encoder = encoder, .pending = pending, .block = block };
    }

    pub fn deinit(w: *Writer) void {
        w.encoder.deinit();
        w.gpa.free(w.pending);
        w.gpa.free(w.block);
        w.* = undefined;
    }

    /// Whole frames of interleaved s16le samples; every `frame_size` of
    /// them make a block.
    pub fn writeData(w: *Writer, data: []const u8) WriteError!void {
        const channels: usize = w.encoder.channels;
        const frame_bytes = 2 * channels;
        if (data.len % frame_bytes != 0) return error.IncompleteFrame;
        const frame_size = w.encoder.frame_size;
        var rest = data;
        while (rest.len != 0) {
            const take = @min(frame_size - w.pending_len, rest.len / frame_bytes);
            for (0..take) |i| {
                for (0..channels) |c| {
                    w.pending[c * frame_size + w.pending_len + i] = std.mem.readInt(i16, rest[(i * channels + c) * 2 ..][0..2], .little);
                }
            }
            w.pending_len += take;
            rest = rest[take * frame_bytes ..];
            if (w.pending_len == frame_size) try w.emit();
        }
    }

    /// The pending frame encoded and written, padded with silence first
    /// when short.
    fn emit(w: *Writer) WriteError!void {
        const frame_size = w.encoder.frame_size;
        var planes: [2][]const i16 = undefined;
        const channels: usize = w.encoder.channels;
        for (0..channels) |c| {
            const plane = w.pending[c * frame_size ..][0..frame_size];
            @memset(plane[w.pending_len..], 0);
            planes[c] = plane;
        }
        try w.encoder.encode(planes[0..channels], w.block);
        try w.wav.writeBlock(w.block, w.pending_len);
        w.pending_len = 0;
    }

    /// The last frame, padded, then the WAV writer's checks and a flush.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.pending_len != 0) try w.emit();
        try w.wav.finish();
    }

    /// After `finish`: the deferred header's sizes (`wav.Writer.rewriteHeader`).
    pub fn rewriteHeader(w: *Writer, seeker: seek.OutputSeeker) RewriteError!void {
        return w.wav.rewriteHeader(seeker);
    }
};

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const hostile = @import("../testing/hostile.zig");
const detect = @import("detect.zig");

/// What FFmpeg makes of each ADPCM fixture (adpcm_wav_vectors.sh).
const vectors = @embedFile("../testing/vectors/adpcm_wav.txt");

/// The port's errors for the fixtures it does not open or decode: where
/// FFmpeg fails too, and the differences notes.md "ADPCM" records (the
/// IMA WAV tag at 8 bits, `block_align` 0, a short `fact`, Wave64, data
/// shorter than its chunk).
const Refusal = struct { name: []const u8, probe: ?anyerror, decode: anyerror };
const refusals = [_]Refusal{
    .{ .name = "adpcm_ima_all_bad", .probe = null, .decode = error.DecodeErrorRate },
    .{ .name = "adpcm_ima_align_short", .probe = null, .decode = error.DecodeErrorRate },
    .{ .name = "adpcm_ima_bits8", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "adpcm_ima_bits6", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "adpcm_ima_3ch", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "adpcm_ms_7ch", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "adpcm_block_align_zero", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "adpcm_fact_short", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "adpcm_w64", .probe = error.UnsupportedFormat, .decode = error.UnsupportedFormat },
    .{ .name = "adpcm_truncated", .probe = error.Truncated, .decode = error.Truncated },
};

fn refusalOf(name: []const u8) ?Refusal {
    for (refusals) |r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// The S and D lines vectors/adpcm_wav.txt holds for fixture `name`.
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

/// Opens fixture bytes as an ADPCM WAV and decodes every sample into `out`
/// (interleaved s16le), without a count or with the one its blocks give.
fn decodeBytes(gpa: std.mem.Allocator, bytes: []const u8, counted: bool, out: *std.ArrayList(u8)) !DecodedReader.Header {
    var reader: std.Io.Reader = .fixed(bytes);
    var parser: wav.Parser = .init(&reader, .{});
    const info = try parser.readHeader();
    if (info.adpcm == null) return error.TestUnexpectedResult;
    var r: DecodedReader = try .init(gpa, parser, info, null);
    defer r.deinit();
    r.count_ahead = counted;
    const header = try r.readHeader();
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = try r.readData(&scratch);
        if (got.len == 0) break;
        try out.appendSlice(gpa, got);
    }
    try r.finish();
    return header;
}

test "every ADPCM fixture gives FFmpeg's stream and samples (vectors/adpcm_wav.txt), or the port's error" {
    const gpa = testing.allocator;
    inline for (fixtures.adpcm.all) |fixture| {
        errdefer std.debug.print("fixture {s}\n", .{fixture.name});
        const bytes = fixtures.adpcm.bytes(fixture.name);
        const refusal = refusalOf(fixture.name);
        try testing.expectEqual(fixture.expected == .reject, refusal != null);
        const lines = try vectorLines(fixture.name);
        // zffprobe's report, as ffprobe's S line has it.
        var probe_reader: std.Io.Reader = .fixed(bytes);
        if (refusal) |r| if (r.probe) |want| {
            try testing.expectError(want, detect.probe(&probe_reader, .{}));
        };
        if (refusal == null or refusal.?.probe == null) {
            const probed = try detect.probe(&probe_reader, .{});
            var text: [128]u8 = undefined;
            const s = try std.fmt.bufPrint(&text, "S {s} {s} {d} {d} {d}", .{
                probed.codec.name(),       probed.format.sample_format.name(), probed.format.channelCount(),
                probed.format.sample_rate, probed.frame_count.?,
            });
            try testing.expectEqualStrings(lines.s, s);
        }
        // The ffmpeg program's samples, as the D line hashes them.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        if (refusal) |r| {
            try testing.expectError(r.decode, decodeBytes(gpa, bytes, false, &out));
        } else {
            const header = try decodeBytes(gpa, bytes, false, &out);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(out.items, &digest, .{});
            var text: [128]u8 = undefined;
            const d = try std.fmt.bufPrint(&text, "D {d} {s}", .{ out.items.len / 2 / header.format.channelCount(), &std.fmt.bytesToHex(digest, .lower) });
            try testing.expectEqualStrings(lines.d, d);
        }
    }
}

test "the count the blocks give is the decoded one, unless a block fails" {
    const gpa = testing.allocator;
    inline for (.{ "adpcm_ms_stereo", "adpcm_ms_6ch", "adpcm_ms_3ch", "adpcm_ffmpeg_ms_short", "adpcm_ima_partial_block", "adpcm_ima_3bit" }) |name| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const header = try decodeBytes(gpa, fixtures.adpcm.bytes(name), true, &out);
        try testing.expectEqual(header.frame_count.?, out.items.len / 2 / header.format.channelCount());
    }
    // Blocks whose headers fail: adpcm_ima_bad_step's step indices, and
    // the frames that start inside a block, after a frame shorter than its
    // block (adpcm_ima_odd_align) or longer (adpcm_ms_tiny_blocks, one
    // sample decoded), whose headers are other bytes.
    inline for (.{ "adpcm_ima_bad_step", "adpcm_ima_odd_align", "adpcm_ms_tiny_blocks" }) |name| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try testing.expectError(error.FrameCountMismatch, decodeBytes(gpa, fixtures.adpcm.bytes(name), true, &out));
    }
}

test "the writer's header is FFmpeg's for FFmpeg's encodes" {
    inline for (fixtures.adpcm.all) |fixture| {
        if (comptime std.mem.startsWith(u8, fixture.name, "adpcm_ffmpeg_")) {
            const bytes = fixtures.adpcm.bytes(fixture.name);
            var reader: std.Io.Reader = .fixed(bytes);
            var parser: wav.Parser = .init(&reader, .{});
            const info = try parser.readHeader();
            const a = info.adpcm.?;
            const header_len = bytes.len - a.data_len.?;
            // FFmpeg's fact count: the samples its encoder took.
            const count = std.mem.readInt(u32, bytes[header_len - 12 ..][0..4], .little);
            var format = info.format;
            format.sample_format = .s16;
            format.layout = audio.ChannelLayout.default(format.channelCount());
            var buffer: [256]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            const options: EncodeOptions = .{ .block_size = @intCast(a.params.block_align) };
            var w: Writer = try .begin(testing.allocator, &out, a.params.codec, format, count, options, .{});
            defer w.deinit();
            try testing.expectEqualSlices(u8, bytes[0..header_len], out.buffered());
            try testing.expectEqual(a.samples().?, w.wav.coding.adpcm.blocks(count) * w.encoder.frame_size);
        }
    }
}

test "the writer groups frames, pads the last, checks the request and rewrites a deferred header" {
    const gpa = testing.allocator;
    const stereo = try audio.Format.initLayout(8000, audio.ChannelLayout.stereo, .s16);
    // 3 channels, a planar or float input, a bad block size or trellis.
    const three = try audio.Format.initLayout(8000, .{ .unspecified = 3 }, .s16);
    try testing.expectError(error.UnsupportedFormat, Writer.check(.ms, three, 0, .{}, .{}));
    const planar = try audio.Format.initLayout(8000, audio.ChannelLayout.stereo, .s16p);
    try testing.expectError(error.UnsupportedFormat, Writer.check(.ms, planar, 0, .{}, .{}));
    try testing.expectError(error.InvalidOption, Writer.check(.ima_wav, stereo, 0, .{ .block_size = 100 }, .{}));
    try testing.expectError(error.InvalidOption, Writer.check(.ima_wav, stereo, 0, .{ .trellis = -1 }, .{}));
    try testing.expectError(error.InvalidOption, Writer.check(.ima_wav, stereo, 0, .{ .trellis = 17 }, .{}));
    // Wave64 is not ported for ADPCM.
    try testing.expectError(error.UnsupportedFormat, Writer.check(.ms, stereo, 0, .{}, .{ .variant = .w64 }));
    try Writer.check(.ms, stereo, null, .{}, .{});

    // 600 frames in blocks of 256 bytes (244 samples): three blocks, the
    // last holding 112, given in uneven pieces.
    var samples: [600 * 2]i16 = undefined;
    for (&samples, 0..) |*v, i| v.* = @intCast(@as(i32, @intCast(i % 397)) * 80 - 16000);
    const bytes = std.mem.sliceAsBytes(&samples);
    var known: [4096]u8 = undefined;
    var known_out: std.Io.Writer = .fixed(&known);
    {
        var w: Writer = try .begin(gpa, &known_out, .ms, stereo, 600, .{ .block_size = 256 }, .{});
        defer w.deinit();
        try testing.expectError(error.IncompleteFrame, w.writeData(bytes[0..3]));
        try w.writeData(bytes[0..400]);
        try w.writeData(bytes[400..]);
        try w.finish();
        try testing.expectEqual(3, w.wav.blocks_written);
    }
    // The same through a deferred header, rewritten.
    var deferred: [4096]u8 = undefined;
    var deferred_out: std.Io.Writer = .fixed(&deferred);
    var w: Writer = try .begin(gpa, &deferred_out, .ms, stereo, null, .{ .block_size = 256 }, .{});
    defer w.deinit();
    try w.writeData(bytes);
    try w.finish();
    try w.rewriteHeader(.fixed(&deferred_out));
    try testing.expectEqualSlices(u8, known_out.buffered(), deferred_out.buffered());
    // Decoded back: three whole blocks, the padding included, and a
    // duration of the 600 frames written (`fact`).
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const header = try decodeBytes(gpa, known_out.buffered(), true, &out);
    try testing.expectEqual(3 * 244, header.frame_count.?);
    try testing.expectEqual(3 * 244 * 4, out.items.len);
    var reader: std.Io.Reader = .fixed(known_out.buffered());
    try testing.expectEqual(600, (try detect.probe(&reader, .{})).frame_count.?);
}

/// Decodes `bytes` and encodes the samples again, both under the sweep's
/// allocator; any error but an allocation failure fails the test.
fn roundTripUnderFailures(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const header = decodeBytes(gpa, bytes, true, &out) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    var encoded: [1 << 16]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&encoded);
    var format = header.format;
    format.layout = audio.ChannelLayout.default(format.channelCount());
    var w = Writer.begin(gpa, &sink, .ima_wav, format, out.items.len / 2 / format.channelCount(), .{ .block_size = 512, .trellis = 3 }, .{}) catch |err|
        return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    defer w.deinit();
    w.writeData(out.items) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    w.finish() catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
}

test "decoding and encoding free everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, fixtures.adpcm.bytes("adpcm_ffmpeg_ms_short"), roundTripUnderFailures);
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.fail, fixtures.adpcm.bytes("adpcm_ima_stereo"), roundTripUnderFailures);
}

/// The fuzz entry's input: a WAV stream, then whether data of unknown
/// length is accepted and whether the reader reports its count, as 0 or 1.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [16384 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const unknown_length = smith.valueRangeAtMost(u8, 0, 1) == 1;
    const counted = smith.valueRangeAtMost(u8, 0, 1) == 1;
    var reader: std.Io.Reader = .fixed(input[0..len]);
    var parser: wav.Parser = .init(&reader, .{ .unknown_length = unknown_length });
    const info = parser.readHeader() catch |err| return if (err == error.OutOfMemory) err else {};
    if (info.adpcm == null) return;
    var r = DecodedReader.init(testing.allocator, parser, info, null) catch |err| return if (err == error.OutOfMemory) err else {};
    defer r.deinit();
    r.count_ahead = counted;
    _ = try r.readHeader();
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = r.readData(&scratch) catch |err| return if (err == error.OutOfMemory) err else {};
        if (got.len == 0) break;
    }
    r.finish() catch {};
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_ima_stereo"), &.{ 0, 1 }),
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_ima_3bit"), &.{ 0, 0 }),
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_ima_odd_align"), &.{ 1, 1 }),
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_ms_6ch"), &.{ 0, 1 }),
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_ms_tiny_blocks"), &.{ 1, 0 }),
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_ms_extensible"), &.{ 0, 0 }),
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_rf64"), &.{ 0, 1 }),
    hostile.fuzzSeed(fixtures.adpcm.bytes("adpcm_ffmpeg_ms_short"), &.{ 1, 1 }),
};

test "fuzz: ADPCM in WAV decoded from arbitrary input" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: ADPCM in WAV decoded from mutated input" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 24, 0x61647063);
}

/// What FFmpeg's libavformat does when each ADPCM fixture is seeked
/// (seek_vectors.c).
const seek_vectors = @embedFile("../testing/vectors/seek_adpcm.txt");

/// One fixture's lines of seek_adpcm.txt, from its `O` line.
fn seekBlock(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, seek_vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, seek_vectors, at, '\n') orelse return null;
        start = line_end + 1;
        if (!std.mem.eql(u8, seek_vectors[at + 2 .. line_end], name)) continue;
        const end = std.mem.findPos(u8, seek_vectors, start, "\nF ") orelse seek_vectors.len;
        return seek_vectors[start..end];
    }
    return null;
}

/// Every seek of `block` replayed on the WAV parser: the position and the
/// timestamp it lands on (ff_pcm_read_seek with the ADPCM block and bit
/// rate); FFmpeg's answers past the end from its read-ahead and packet
/// index are the end here, as for PCM WAV (wav.zig's seek test).
fn expectAdpcmSeeks(bytes: []const u8, block: []const u8, compared: *u32, understood: *u32) !void {
    var lines = std.mem.splitScalar(u8, block, '\n');
    const opened = lines.next() orelse return error.TestUnexpectedResult;
    if (!std.mem.eql(u8, opened, "O ok")) return;
    _ = lines.next(); // the I line
    var pending = lines.next();
    while (pending) |k_line| {
        pending = lines.next();
        if (k_line.len == 0 or k_line[0] != 'K') continue;
        var f = std.mem.tokenizeScalar(u8, k_line, ' ');
        _ = f.next();
        const api = f.next().?[0];
        const stream = try std.fmt.parseInt(i32, f.next().?, 10);
        const ts = try std.fmt.parseInt(i64, f.next().?, 10);
        var min_ts: i64 = 0;
        var max_ts: i64 = 0;
        if (api == 's') {
            min_ts = try std.fmt.parseInt(i64, f.next().?, 10);
            max_ts = try std.fmt.parseInt(i64, f.next().?, 10);
        }
        const bits = try std.fmt.parseInt(u8, f.next().?, 16);
        const flags: seek.Flags = .{ .backward = bits & 1 != 0, .byte = bits & 2 != 0, .any = bits & 4 != 0 };
        const ret = f.next().?;
        errdefer std.debug.print("seek: {s}\n", .{k_line});

        var reader: std.Io.Reader = .fixed(bytes);
        var parser: wav.Parser = .init(&reader, .{});
        parser.enableSeeking(.fixed(&reader));
        _ = try parser.readHeader();
        const result = if (api == 'f') parser.seekFrame(stream, ts, flags) else parser.seekFile(stream, min_ts, ts, max_ts, flags);
        compared.* += 1;
        if (std.mem.eql(u8, ret, "EINVAL")) {
            try testing.expectError(error.InvalidStream, result);
            continue;
        }
        const position = try result;
        if (std.mem.eql(u8, ret, "-1")) {
            try testing.expect(position.at_end);
            understood.* += 1;
            continue;
        }
        try testing.expectEqualStrings("0", ret);
        const p_line = pending orelse return error.TestUnexpectedResult;
        var scratch: [64]u8 = undefined;
        if (std.mem.eql(u8, p_line, "P EOF")) {
            try testing.expectEqual(0, (try parser.readData(&scratch)).len);
            continue;
        }
        var pf = std.mem.tokenizeScalar(u8, p_line, ' ');
        _ = pf.next();
        const pts_text = pf.next().?;
        const pos = try std.fmt.parseInt(u64, pf.next().?, 10);
        if (position.at_end and pos < position.offset) {
            understood.* += 1;
            continue;
        }
        try testing.expectEqual(pos, position.offset);
        // `N`: libavformat sets no pts on a packet of a partial block,
        // whose duration av_get_audio_frame_duration2 makes 0.
        if (flags.byte or std.mem.eql(u8, pts_text, "N")) continue;
        try testing.expectEqual(try std.fmt.parseInt(i64, pts_text, 10), position.timestamp.?);
    }
}

test "the WAV parser seeks ADPCM data as FFmpeg does (vectors/seek_adpcm.txt)" {
    var compared: u32 = 0;
    var understood: u32 = 0;
    inline for (fixtures.adpcm.all) |fixture| {
        const bytes = fixtures.adpcm.bytes(fixture.name);
        // The fixtures whose header the parser refuses (notes.md "ADPCM"),
        // and data shorter than its chunk, which reads `Truncated`.
        var probe_reader: std.Io.Reader = .fixed(bytes);
        var probe_parser: wav.Parser = .init(&probe_reader, .{});
        const opens = if (probe_parser.readHeader()) |_| true else |_| false;
        if (comptime std.mem.eql(u8, fixture.name, "adpcm_truncated")) continue;
        if (opens) {
            const block = seekBlock(fixture.name) orelse return error.TestUnexpectedResult;
            expectAdpcmSeeks(bytes, block, &compared, &understood) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
    // Every seek on the fixtures the parser opens, 304 of them past the
    // data's end where FFmpeg's read-ahead and packet index answer.
    try testing.expectEqual(1944, compared);
    try testing.expectEqual(304, understood);
}
