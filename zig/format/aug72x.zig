// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/au.c (au_read_header, au_g726le_tag, au_write_header,
// au_write_trailer), pcm.c (ff_pcm_read_packet), libavcodec/g722enc.c's
// and g726.c's registrations (mono, s16, a small last frame) and
// fftools' frame grouping for a fixed frame size at the pinned reference
// revision describe the behavior, restated here.
//! G.722 and G.726 in Sun AU (TODO.md T31c), as the ffmpeg program reads
//! and writes them: `DecodedReader` decodes the data with FFmpeg's
//! decoders (`codec/g722.zig`, `codec/g726.zig`), packet by packet as the
//! AU demuxer reads them, delivered as mono s16le; `Writer` encodes mono
//! 16-bit samples with FFmpeg's encoders into an AU file, in frames of the
//! encoder's `frame_size`, the last one short. The ffmpeg program presets
//! an encoder's frame size to its first frame's sample count, which
//! G.722's keeps (corrected to an even count, at most 32768) and G.726's
//! replaces with its own.

const std = @import("std");
const audio = @import("../core/audio.zig");
const g722 = @import("../codec/g722.zig");
const g726 = @import("../codec/g726.zig");
const au = @import("au.zig");
const seek = @import("seek.zig");
const decoded = @import("decoded.zig");

pub const ReadError = au.Error || error{OutOfMemory};

const Decoder = union(au.G72x.Codec) {
    g722: g722.Decoder,
    g726le: g726.Codec,

    fn init(g: au.G72x) Decoder {
        return switch (g.codec) {
            .g722 => .{ .g722 = .init(g722.default_bits_per_codeword) },
            .g726le => .{ .g726le = .init(g.bits) },
        };
    }

    /// One packet's samples into `out`.
    fn decode(d: *Decoder, packet: []const u8, out: []i16) []i16 {
        return switch (d.*) {
            .g722 => |*x| x.decodePacket(packet, out),
            .g726le => |*x| out[0..g726.decodePacket(x, packet, out)],
        };
    }
};

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    /// The AU parser, past its header; its `readData` gives the packets.
    parser: au.Parser,
    g72x: au.G72x,
    format: audio.Format,
    decoder: Decoder,
    /// One packet of the demuxer's (owned).
    packet_buf: []u8,
    /// The current packet's samples (owned storage), and those delivered.
    samples: []i16,
    pending: [2]u32 = .{ 0, 0 },
    delivered: u64 = 0,
    ended: bool = false,

    pub const Header = decoded.Header;

    /// Takes over `parser`, whose `readHeader` gave `info` (a G.722 or
    /// G.726 stream), and opens FFmpeg's decoder.
    pub fn init(gpa: std.mem.Allocator, parser: au.Parser, info: au.Info) error{OutOfMemory}!DecodedReader {
        const g = info.g72x.?; // the caller dispatches on it
        const packet_buf = try gpa.alloc(u8, g.packet_len);
        errdefer gpa.free(packet_buf);
        const samples = try gpa.alloc(i16, @intCast(g.samplesIn(g.packet_len)));
        return .{
            .gpa = gpa,
            .parser = parser,
            .g72x = g,
            .format = info.format,
            .decoder = .init(g),
            .packet_buf = packet_buf,
            .samples = samples,
        };
    }

    pub fn deinit(r: *DecodedReader) void {
        r.gpa.free(r.packet_buf);
        r.gpa.free(r.samples);
        r.* = undefined;
    }

    /// The decoded stream: mono s16, with the count the data's size gives
    /// (the decoders take every byte, so it is exact).
    pub fn readHeader(r: *DecodedReader) ReadError!Header {
        const stream: @FieldType(Header, "stream") = switch (r.g72x.codec) {
            .g722 => .adpcm_g722,
            .g726le => .adpcm_g726le,
        };
        return .{ .stream = stream, .codec = .s16le, .format = r.format, .frame_count = r.g72x.samples(), .bits = 16 };
    }

    /// The first packet's sample count (the ffmpeg program's FLAC encoder
    /// takes it as its block size); null for no data. `readData` still
    /// returns it first.
    pub fn firstFrameSamples(r: *DecodedReader) ReadError!?u32 {
        std.debug.assert(r.delivered == 0);
        if (r.pendingFrames() == 0 and !try r.nextFrame()) return null;
        return r.pendingFrames();
    }

    /// The largest frame the decoder gives: a whole packet's.
    pub fn maxFrame(r: *const DecodedReader) u32 {
        return @intCast(r.samples.len);
    }

    fn pendingFrames(r: *const DecodedReader) u32 {
        return r.pending[1] - r.pending[0];
    }

    /// Whole samples into `output`, at least one while any remain; empty
    /// at the end. An output too small for one is `OutputTooSmall`.
    pub fn readData(r: *DecodedReader, output: []u8) ReadError![]u8 {
        while (r.pendingFrames() == 0) {
            if (!try r.nextFrame()) return output[0..0];
        }
        const n = @min(output.len / 2, r.pendingFrames());
        if (n == 0) return error.OutputTooSmall;
        for (0..n) |i| std.mem.writeInt(i16, output[2 * i ..][0..2], r.samples[r.pending[0] + i], .little);
        r.pending[0] += n;
        r.delivered += n;
        return output[0 .. 2 * n];
    }

    /// The next packet decoded; false at the end of the data. A packet of
    /// fewer bits than a G.726 code decodes to nothing and is skipped.
    fn nextFrame(r: *DecodedReader) ReadError!bool {
        while (!r.ended) {
            const got = try r.parser.readData(r.packet_buf);
            if (got.len == 0) {
                r.ended = true;
                break;
            }
            const out = r.decoder.decode(got, r.samples);
            r.pending = .{ 0, @intCast(out.len) };
            if (out.len != 0) return true;
        }
        return false;
    }

    /// The rest of the AU stream (`au.Parser.finish`).
    pub fn finish(r: *DecodedReader) ReadError!void {
        std.debug.assert(r.pendingFrames() == 0);
        try r.parser.finish();
    }
};

/// The encoders' options: FFmpeg's `-trellis` (G.722), and G.726's
/// `code_size` and the bit rate (`-b:a`), which overrides it when set.
pub const EncodeOptions = struct {
    trellis: i32 = 0,
    code_size: i32 = g726.default_code_size,
    bit_rate: i64 = 0,
};

pub const HeaderError = au.HeaderError;

pub const WriteError = std.Io.Writer.Error || HeaderError || error{
    OutOfMemory,
    /// The samples are not whole s16 samples.
    IncompleteFrame,
    /// More samples than declared to `begin`.
    TooManyFrames,
    /// `finish` came before every declared sample.
    TooFewFrames,
};

pub const RewriteError = WriteError || error{IoFailure};

/// What `check` and `begin` decide from the request.
const Coding = struct {
    codec: au.G72x.Codec,
    /// G.726's code size; 4 for G.722.
    bits: u32,
    /// G.726's; for G.722, 0 until the first frame gives it.
    frame_size: u32,
    trellis: u32,

    /// The encoders' checks: s16 mono (G.722's only layout, which the
    /// ffmpeg program's filters downmix to, and G.726's "Only mono is
    /// supported"; notes.md "G.722 and G.726"), and G.726 at 8 kHz, as
    /// g726_encode_init requires above the unofficial compliance level.
    fn of(codec: au.G72x.Codec, format: audio.Format, options: EncodeOptions) HeaderError!Coding {
        if (format.sample_format != .s16) return error.UnsupportedFormat;
        const mono = switch (format.layout) {
            .unspecified => |count| count == 1,
            .native, .custom => format.layout.eql(&audio.ChannelLayout.mono),
        };
        if (!mono) return error.UnsupportedFormat;
        return switch (codec) {
            .g722 => .{ .codec = .g722, .bits = 4, .frame_size = 0, .trellis = g722.effectiveTrellis(options.trellis) },
            .g726le => {
                if (format.sample_rate != 8000) return error.UnsupportedFormat;
                const bits = g726.encoderCodeSize(options.code_size, options.bit_rate, format.sample_rate);
                return .{ .codec = .g726le, .bits = bits, .frame_size = g726.frameSize(bits), .trellis = 0 };
            },
        };
    }

    /// The bytes `samples` encode to: whole frames of whole bytes (G.722's
    /// frame size is even), and a short last frame rounded up to a byte
    /// (G.722's odd last sample doubled into one).
    fn bytesFor(c: Coding, samples: u64) u64 {
        return switch (c.codec) {
            .g722 => (samples + 1) / 2,
            .g726le => (samples * c.bits + 7) / 8,
        };
    }

    fn encoding(c: Coding) u32 {
        return au.G72x.tagFor(c.codec, c.bits);
    }
};

const Encoder = union(au.G72x.Codec) {
    g722: g722.Encoder,
    g726le: g726.Codec,

    fn encode(e: *Encoder, samples: []const i16, out: []u8) []u8 {
        return switch (e.*) {
            .g722 => |*x| x.encodeFrame(samples, out),
            .g726le => |*x| g726.encodePacket(x, samples, out),
        };
    }
};

/// Writes a G.722 or G.726 stream to an AU file: mono 16-bit samples in,
/// grouped into frames of the encoder's `frame_size` as the ffmpeg
/// program's filter graph groups them, the last one short, each packet
/// written after the canonical header.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    coding: Coding,
    format: audio.Format,
    limits: au.Limits,
    encoder: Encoder,
    /// The frame being filled (owned; empty until the frame size is
    /// known), and how many samples it holds.
    pending: []i16 = &.{},
    pending_len: u32 = 0,
    /// One encoded packet (owned, as `pending`).
    packet: []u8 = &.{},
    /// The bytes the header declared; null when it is rewritten at the end.
    bytes_expected: ?u64,
    bytes_written: u64 = 0,

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists; null `frame_count` for a header
    /// rewritten at the end.
    pub fn check(codec: au.G72x.Codec, format: audio.Format, frame_count: ?u64, options: EncodeOptions, limits: au.Limits) HeaderError!void {
        const coding = try Coding.of(codec, format, options);
        _ = try au.codedHeader(coding.encoding(), format, coding.bytesFor(frame_count orelse 0), limits);
    }

    /// Checks the request, opens the encoder and writes the header for
    /// `frame_count` samples, or, null, for none until `rewriteHeader` (a
    /// seekable output). `first_frame` is the first frame's sample count,
    /// null when `setFirstFrame` gives it later (a resampler's first
    /// output).
    pub fn begin(gpa: std.mem.Allocator, out: *std.Io.Writer, codec: au.G72x.Codec, format: audio.Format, frame_count: ?u64, first_frame: ?u32, options: EncodeOptions, limits: au.Limits) WriteError!Writer {
        const coding = try Coding.of(codec, format, options);
        const expected: ?u64 = if (frame_count) |n| coding.bytesFor(n) else null;
        const header = try au.codedHeader(coding.encoding(), format, expected orelse 0, limits);
        const encoder: Encoder = switch (coding.codec) {
            .g722 => .{ .g722 = try .init(gpa, coding.trellis) },
            .g726le => .{ .g726le = .init(coding.bits) },
        };
        var w: Writer = .{
            .gpa = gpa,
            .out = out,
            .coding = coding,
            .format = format,
            .limits = limits,
            .encoder = encoder,
            .bytes_expected = expected,
        };
        errdefer w.deinit();
        if (coding.frame_size != 0) {
            try w.open(coding.frame_size);
        } else if (first_frame) |n| try w.open(g722.effectiveFrameSize(n));
        try out.writeAll(&header);
        return w;
    }

    /// The first frame's size, when the caller learns it after `begin`;
    /// before any sample is written. G.726 keeps its own.
    pub fn setFirstFrame(w: *Writer, samples: u32) error{OutOfMemory}!void {
        std.debug.assert(w.pending_len == 0);
        if (w.pending.len == 0) try w.open(g722.effectiveFrameSize(samples));
    }

    /// The frame size known: the frame and packet buffers.
    fn open(w: *Writer, frame_size: u32) error{OutOfMemory}!void {
        std.debug.assert(w.pending.len == 0 and frame_size != 0);
        const pending = try w.gpa.alloc(i16, frame_size);
        errdefer w.gpa.free(pending);
        const packet = try w.gpa.alloc(u8, @intCast(w.coding.bytesFor(frame_size)));
        w.pending = pending;
        w.packet = packet;
    }

    pub fn deinit(w: *Writer) void {
        if (w.encoder == .g722) w.encoder.g722.deinit(w.gpa);
        w.gpa.free(w.pending);
        w.gpa.free(w.packet);
        w.* = undefined;
    }

    /// Whole s16le samples; every `frame_size` of them make a packet.
    pub fn writeData(w: *Writer, data: []const u8) WriteError!void {
        if (data.len % 2 != 0) return error.IncompleteFrame;
        // Without a first frame's size (a caller that gave none): its
        // samples are the first frame.
        if (w.pending.len == 0 and data.len != 0) try w.open(g722.effectiveFrameSize(@min(data.len / 2, g722.max_frame_size)));
        var rest = data;
        while (rest.len != 0) {
            const take = @min(w.pending.len - w.pending_len, rest.len / 2);
            for (0..take) |i| w.pending[w.pending_len + i] = std.mem.readInt(i16, rest[2 * i ..][0..2], .little);
            w.pending_len += @intCast(take);
            rest = rest[2 * take ..];
            if (w.pending_len == w.pending.len) try w.emit();
        }
    }

    /// The pending frame encoded and written.
    fn emit(w: *Writer) WriteError!void {
        const packet = w.encoder.encode(w.pending[0..w.pending_len], w.packet);
        const written = w.bytes_written + packet.len;
        if (w.bytes_expected) |expected| {
            if (written > expected) return error.TooManyFrames;
        } else if (written > au.max_data_bytes) return error.SizeOverflow;
        try w.out.writeAll(packet);
        w.bytes_written = written;
        w.pending_len = 0;
    }

    /// The last frame, short, then the declared size's check and a flush.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.pending_len != 0) try w.emit();
        if (w.bytes_expected) |expected| {
            if (w.bytes_written != expected) return error.TooFewFrames;
        }
        try w.out.flush();
    }

    /// After `finish`, for a header begun without a count: the header for
    /// the bytes written, as au_write_trailer rewrites it.
    pub fn rewriteHeader(w: *Writer, seeker: seek.OutputSeeker) RewriteError!void {
        if (w.bytes_expected != null) return;
        const header = try au.codedHeader(w.coding.encoding(), w.format, w.bytes_written, w.limits);
        const end = seeker.position();
        try seeker.seekTo(0);
        try w.out.writeAll(&header);
        try seeker.seekTo(end);
        try w.out.flush();
    }
};

const testing = std.testing;

/// Decodes AU bytes holding G.722 or G.726 into `out` (mono s16le).
fn decodeBytes(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !DecodedReader.Header {
    var reader: std.Io.Reader = .fixed(bytes);
    var parser: au.Parser = .init(&reader, .{});
    const info = try parser.readHeader();
    if (info.g72x == null) return error.TestUnexpectedResult;
    var r: DecodedReader = try .init(gpa, parser, info);
    defer r.deinit();
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

/// Encodes `samples` (mono s16) at `rate` into AU bytes.
fn encodeSamples(gpa: std.mem.Allocator, codec: au.G72x.Codec, rate: u32, samples: []const i16, options: EncodeOptions, out: *std.Io.Writer) !void {
    const format: audio.Format = .{ .sample_rate = rate, .layout = audio.ChannelLayout.mono, .sample_format = .s16 };
    var w: Writer = try .begin(gpa, out, codec, format, samples.len, 320, options, .{});
    defer w.deinit();
    // In uneven pieces, as a conversion delivers them.
    var at: usize = 0;
    var piece: usize = 1;
    var bytes: [2 * 4096]u8 = undefined;
    while (at < samples.len) : (piece = @min(piece * 3 + 1, 4096)) {
        const n = @min(piece, samples.len - at);
        for (samples[at..][0..n], 0..) |s, i| std.mem.writeInt(i16, bytes[2 * i ..][0..2], s, .little);
        try w.writeData(bytes[0 .. 2 * n]);
        at += n;
    }
    try w.finish();
}

test "a G.722 and G.726 AU written and read back: the header's encoding, size and samples" {
    const gpa = testing.allocator;
    var samples: [3001]i16 = undefined;
    for (&samples, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i * 7919 % 20001)) - 10000);
    const cases = [_]struct { codec: au.G72x.Codec, rate: u32, options: EncodeOptions, encoding: u32 }{
        .{ .codec = .g722, .rate = 16000, .options = .{}, .encoding = 24 },
        .{ .codec = .g722, .rate = 16000, .options = .{ .trellis = 3 }, .encoding = 24 },
        .{ .codec = .g726le, .rate = 8000, .options = .{ .code_size = 2 }, .encoding = 0x37323632 },
        .{ .codec = .g726le, .rate = 8000, .options = .{ .code_size = 3 }, .encoding = 25 },
        .{ .codec = .g726le, .rate = 8000, .options = .{}, .encoding = 23 },
        .{ .codec = .g726le, .rate = 8000, .options = .{ .bit_rate = 40000 }, .encoding = 26 },
    };
    for (cases) |c| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try encodeSamples(gpa, c.codec, c.rate, &samples, c.options, &out.writer);
        const bytes = out.written();
        try testing.expectEqual(c.encoding, std.mem.readInt(u32, bytes[12..16], .big));
        try testing.expectEqual(bytes.len - au.canonical_header_len, std.mem.readInt(u32, bytes[8..12], .big));
        var decoded_bytes: std.ArrayList(u8) = .empty;
        defer decoded_bytes.deinit(gpa);
        const header = try decodeBytes(gpa, bytes, &decoded_bytes);
        try testing.expectEqual(header.frame_count.?, decoded_bytes.items.len / 2);
        // G.722 rounds an odd count up a sample; G.726 rounds up to whole
        // codes in the last byte.
        try testing.expect(header.frame_count.? >= samples.len and header.frame_count.? < samples.len + 4);
    }
}

test "the encoders' refusals: more than one channel, G.726 away from 8 kHz, not s16" {
    const stereo: audio.Format = .{ .sample_rate = 16000, .layout = .{ .unspecified = 2 }, .sample_format = .s16 };
    try testing.expectError(error.UnsupportedFormat, Writer.check(.g722, stereo, 10, .{}, .{}));
    const mono16k: audio.Format = .{ .sample_rate = 16000, .layout = .{ .unspecified = 1 }, .sample_format = .s16 };
    try Writer.check(.g722, mono16k, 10, .{}, .{});
    try testing.expectError(error.UnsupportedFormat, Writer.check(.g726le, mono16k, 10, .{}, .{}));
    const float: audio.Format = .{ .sample_rate = 8000, .layout = .{ .unspecified = 1 }, .sample_format = .flt };
    try testing.expectError(error.UnsupportedFormat, Writer.check(.g726le, float, 10, .{}, .{}));
}

const fixtures = @import("../testing/fixtures.zig");
const detect = @import("detect.zig");
/// What FFmpeg makes of each G.722 and G.726 fixture (g72x_au_vectors.sh).
const vectors = @embedFile("../testing/vectors/g72x_au.txt");

/// The port's errors for the fixtures it refuses, where FFmpeg reads them
/// (notes.md "G.722 and G.726"): the AU contract's unknown length, data
/// shorter than its size, and the parser's limits.
const refusals = [_]struct { name: []const u8, err: anyerror }{
    .{ .name = "g72x_unknown_size", .err = error.UnsupportedStreamingSize },
    .{ .name = "g72x_truncated", .err = error.Truncated },
    .{ .name = "g72x_rate_over_limit", .err = error.LimitExceeded },
    .{ .name = "g72x_channels65", .err = error.LimitExceeded },
};

fn refusalOf(name: []const u8) ?anyerror {
    for (refusals) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.err;
    }
    return null;
}

/// The S and D lines vectors/g72x_au.txt holds for fixture `name`.
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

test "every G.722 and G.726 fixture gives FFmpeg's stream and samples (vectors/g72x_au.txt), or the port's error" {
    const gpa = testing.allocator;
    inline for (fixtures.g72x.all) |fixture| {
        errdefer std.debug.print("fixture {s}\n", .{fixture.name});
        const bytes = fixtures.g72x.bytes(fixture.name);
        const refusal = refusalOf(fixture.name);
        try testing.expectEqual(fixture.expected == .reject, refusal != null);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        if (refusal) |err| {
            var probe_reader: std.Io.Reader = .fixed(bytes);
            try testing.expectError(err, detect.probeWith(&probe_reader, .{}, .{ .source = .{ .format = .au } }));
            try testing.expectError(err, decodeBytes(gpa, bytes, &out));
        } else {
            const lines = try vectorLines(fixture.name);
            // zffprobe's report, as ffprobe's S line has it.
            var probe_reader: std.Io.Reader = .fixed(bytes);
            const probed = try detect.probeWith(&probe_reader, .{}, .{ .source = .{ .format = .au } });
            var text: [160]u8 = undefined;
            var layout: [32]u8 = undefined;
            var lw: std.Io.Writer = .fixed(&layout);
            try probed.format.layout.describe(&lw);
            const s = try std.fmt.bufPrint(&text, "S {s} {s} {d} {s} {d} {d}", .{
                probed.codec.name(),
                probed.format.sample_format.name(),
                probed.format.channelCount(),
                lw.buffered(),
                probed.format.sample_rate,
                probed.frame_count.?,
            });
            try testing.expectEqualStrings(lines.s, s);
            // The ffmpeg program's samples, as the D line hashes them.
            const header = try decodeBytes(gpa, bytes, &out);
            try testing.expectEqual(header.frame_count.?, out.items.len / 2);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(out.items, &digest, .{});
            const d = try std.fmt.bufPrint(&text, "D {d} {s}", .{ out.items.len / 2, &std.fmt.bytesToHex(digest, .lower) });
            try testing.expectEqualStrings(lines.d, d);
        }
    }
}

const hostile = @import("../testing/hostile.zig");

fn decodeUnderFailures(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = decodeBytes(gpa, bytes, &out) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
}

fn encodeUnderFailures(gpa: std.mem.Allocator, options: EncodeOptions) !void {
    var samples: [700]i16 = undefined;
    for (&samples, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i * 389 % 9001)) - 4500);
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try encodeSamples(gpa, .g722, 16000, &samples, options, &out);
}

test "G.722 and G.726 in AU decoded and encoded free everything under every allocation and remap failure" {
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, fixtures.g72x.bytes("g72x_ffmpeg_g722_8k"), decodeUnderFailures);
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.fail, fixtures.g72x.bytes("g72x_g726_5_partial"), decodeUnderFailures);
    try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, EncodeOptions{ .trellis = 2 }, encodeUnderFailures);
}

/// The fuzz entry's input: an AU stream, then whether data of unknown
/// length is accepted, as 0 or 1. A G.722 or G.726 stream decodes to the
/// count its header gives, every packet whole.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [8192 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const unknown_length = smith.valueRangeAtMost(u8, 0, 1) == 1;
    const gpa = testing.allocator;
    var reader: std.Io.Reader = .fixed(input[0..len]);
    var parser: au.Parser = .init(&reader, .{ .unknown_length = unknown_length });
    const info = parser.readHeader() catch return;
    const g = info.g72x orelse return;
    var r = try DecodedReader.init(gpa, parser, info);
    defer r.deinit();
    const header = try r.readHeader();
    var scratch: [1024]u8 = undefined;
    var samples: u64 = 0;
    while (true) {
        const got = r.readData(&scratch) catch return;
        if (got.len == 0) break;
        samples += got.len / 2;
    }
    r.finish() catch return;
    if (header.frame_count) |count| try testing.expectEqual(count, samples);
    if (g.data_bytes) |bytes| try testing.expectEqual(g.samplesIn(bytes), samples);
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(fixtures.g72x.bytes("g72x_g726_5_partial"), &.{0}),
    hostile.fuzzSeed(fixtures.g72x.bytes("g72x_7262_8ch"), &.{0}),
    hostile.fuzzSeed(fixtures.g72x.bytes("g72x_unknown_size"), &.{1}),
    hostile.fuzzSeed(fixtures.g72x.bytes("g72x_g722_3ch_header"), &.{1}),
    hostile.fuzzSeed(fixtures.g72x.bytes("g72x_ffmpeg_one_sample"), &.{0}),
};

test "fuzz: G.722 and G.726 in AU, decoded" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: G.722 and G.726 in AU, decoded" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 64, 0x61753732);
}

test "malformed G.722 and G.726 headers: the AU contract's errors before any sample" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // A header cut inside its channel count.
    try testing.expectError(error.Truncated, decodeBytes(gpa, fixtures.g72x.bytes("g72x_g726_5_partial")[0..22], &out));
    // A zero rate, and an annotation that runs past the input.
    const bad = try gpa.dupe(u8, fixtures.g72x.bytes("g72x_g726_2_one_byte"));
    defer gpa.free(bad);
    std.mem.writeInt(u32, bad[16..20], 0, .big);
    try testing.expectError(error.InvalidFormat, decodeBytes(gpa, bad, &out));
    std.mem.writeInt(u32, bad[16..20], 8000, .big);
    std.mem.writeInt(u32, bad[4..8], 4096, .big);
    try testing.expectError(error.Truncated, decodeBytes(gpa, bad, &out));
    // The PCM paths refuse G.722 and G.726 data.
    var reader: std.Io.Reader = .fixed(fixtures.g72x.bytes("g72x_annotation"));
    var parser: au.Parser = .init(&reader, .{});
    _ = try parser.readHeader();
    var samples: [16]i16 = undefined;
    try testing.expectError(error.UnsupportedFormat, parser.readSamples(&samples));
    var raw_reader: std.Io.Reader = .fixed(fixtures.g72x.bytes("g72x_annotation"));
    var sink: [64]u8 = undefined;
    var raw_out: std.Io.Writer = .fixed(&sink);
    try testing.expectError(error.UnsupportedFormat, au.decodeToRaw(&raw_reader, &raw_out, .{}));
}
