// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/wavdec.c, wavenc.c and riffenc.c at the pinned reference revision
// describe FFmpeg's more permissive behavior; see zig/testing/fixtures/README.md.
//! Bounded RIFF/WAVE reading and known-length writing for signed 16-bit PCM.
//!
//! The parser is sequential and never seeks, so it works on pipes. It reads
//! every field exactly into local arrays, keeps only the `fmt ` fields, and
//! validates the whole declared RIFF extent, including the chunks after `data`.
//! Its accepted subset, error names and error precedence are the contract in
//! zig/testing/fixtures/README.md; every fixture there is tested below.
//!
//! Parser errors and writer I/O errors are terminal: discard the parser or
//! writer afterward. The writer's frame-count errors (`IncompleteFrame`,
//! `TooManyFrames`, `TooFewFrames`) write nothing and leave it usable. Errors
//! found after samples were delivered still fail the stream; output is not
//! atomic. Neither the parser nor the writer allocates.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const Prefix = @import("prefix.zig").Prefix;

/// Contract errors (see the fixture README), plus `IoFailure` for a failing
/// reader. File adapters in zig/io/file.zig replace `IoFailure` with the cause.
pub const Error = error{
    InvalidRiff,
    InvalidWave,
    InvalidFormat,
    Truncated,
    UnsupportedFormat,
    UnsupportedStreamingSize,
    LimitExceeded,
    IoFailure,
};

/// Configurable policy limits; exceeding one is `error.LimitExceeded`.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// Counts every chunk header inside the RIFF extent, `fmt ` and `data` included.
    max_chunks: u32 = 4096,
};

pub const Info = struct {
    format: audio.Format,
    /// Sample frames in the `data` chunk.
    frame_count: u64,
};

/// Size of the canonical header the writer emits: RIFF header, 16-byte `fmt `
/// chunk and `data` chunk header.
pub const canonical_header_len = 44;

/// Bytes decoded per read; a whole number of mono and stereo frames.
const scratch_len = 4096;

const ChunkHeader = struct {
    id: [4]u8,
    size: u32,
};

/// Reads one WAV stream from a borrowed reader.
///
/// Call `readHeader` once, then `readSamples` until it returns no samples (or
/// not at all), then `finish`, which skips any unread data and validates the
/// rest of the RIFF extent. The stream is valid only if `finish` succeeds.
pub const Parser = struct {
    reader: *std.Io.Reader,
    limits: Limits,
    /// Bytes content detection already read; they come before the reader's.
    prefix: Prefix = .{},
    /// Bytes of the declared RIFF extent not yet consumed.
    extent_left: u32 = 0,
    chunks: u32 = 0,
    format: ?audio.Format = null,
    /// Bytes of `data` not yet delivered.
    data_left: u32 = 0,
    state: State = .header,

    const State = enum { header, data, done };

    pub fn init(reader: *std.Io.Reader, limits: Limits) Parser {
        return .{ .reader = reader, .limits = limits };
    }

    /// Like `init`, for a stream whose first bytes content detection already
    /// read (format/detect.zig). The parser reads them first.
    pub fn initPrefixed(reader: *std.Io.Reader, limits: Limits, prefix: Prefix) Parser {
        return .{ .reader = reader, .limits = limits, .prefix = prefix };
    }

    /// Reads the RIFF header and every chunk up to the start of `data`.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        const tag = try p.readArray(4);
        if (!std.mem.eql(u8, &tag, "RIFF")) {
            for ([_]*const [4]u8{ "RIFX", "RF64", "BW64", "riff" }) |unsupported| {
                if (std.mem.eql(u8, &tag, unsupported)) return error.UnsupportedFormat;
            }
            return error.InvalidRiff;
        }
        const size_bytes = try p.readArray(4);
        const riff_size = std.mem.readInt(u32, &size_bytes, .little);
        if (riff_size == 0 or riff_size == std.math.maxInt(u32)) return error.UnsupportedStreamingSize;
        if (riff_size < 4) return error.InvalidRiff;
        const form = try p.readArray(4);
        if (!std.mem.eql(u8, &form, "WAVE")) return error.InvalidWave;
        p.extent_left = riff_size - 4;

        while (true) {
            // The extent ended before `data`: `fmt ` or `data` is missing.
            const header = try p.nextChunk() orelse return error.InvalidWave;
            if (std.mem.eql(u8, &header.id, "fmt ")) {
                try p.readFormat(header.size);
            } else if (std.mem.eql(u8, &header.id, "data")) {
                return p.beginData(header.size);
            } else {
                try p.skipChunk(header.size);
            }
        }
    }

    /// Decodes whole frames of interleaved samples into the start of `output`
    /// and returns the decoded prefix. Returns no samples once the data is
    /// exhausted, or when `output` cannot hold one frame.
    pub fn readSamples(p: *Parser, output: []i16) Error![]i16 {
        var scratch: [scratch_len]u8 = undefined;
        var produced: usize = 0;
        while (true) {
            // An i16 slice already spans 2 * len bytes, so this cannot overflow.
            const room_bytes = @min(scratch_len, (output.len - produced) * 2);
            const bytes = try p.readData(scratch[0..room_bytes]);
            if (bytes.len == 0) break;
            // Whole frames of at most room_bytes bytes fit in the output.
            const decoded = pcm.decodeS16(.little, bytes, output[produced..]) catch unreachable;
            produced += decoded.len;
        }
        return output[0..produced];
    }

    /// Reads whole frames of `data`, still encoded as s16le, into the start of
    /// `output` and returns that prefix: the stream-copy counterpart of
    /// `readSamples`. Returns no bytes once the data is exhausted, or when
    /// `output` cannot hold one frame.
    pub fn readData(p: *Parser, output: []u8) Error![]u8 {
        std.debug.assert(p.state == .data);
        const frame_bytes = p.format.?.bytesPerFrame();
        const data_left: usize = p.data_left;
        const want = @min(data_left, output.len - output.len % frame_bytes);
        p.reader.readSliceAll(output[0..want]) catch |err| return mapRead(err);
        p.data_left -= @intCast(want);
        return output[0..want];
    }

    /// Skips any unread data, then validates the chunks after `data` up to the
    /// end of the RIFF extent. Bytes after the extent are never read.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        p.reader.discardAll(p.data_left) catch |err| return mapRead(err);
        p.data_left = 0;
        while (try p.nextChunk()) |header| {
            if (std.mem.eql(u8, &header.id, "fmt ") or std.mem.eql(u8, &header.id, "data")) {
                return error.InvalidWave;
            }
            try p.skipChunk(header.size);
        }
        p.state = .done;
    }

    fn nextChunk(p: *Parser) Error!?ChunkHeader {
        if (p.extent_left == 0) return null;
        if (p.extent_left < 8) return error.InvalidRiff;
        const bytes = try p.readArray(8);
        p.extent_left -= 8;
        if (p.chunks >= p.limits.max_chunks) return error.LimitExceeded;
        p.chunks += 1;
        return .{ .id = bytes[0..4].*, .size = std.mem.readInt(u32, bytes[4..8], .little) };
    }

    fn readFormat(p: *Parser, size: u32) Error!void {
        if (p.format != null) return error.InvalidWave;
        if (size < 16) return error.InvalidFormat;
        try p.checkExtent(size);
        const fields = try p.readArray(16);
        const tag = std.mem.readInt(u16, fields[0..2], .little);
        const channels = std.mem.readInt(u16, fields[2..4], .little);
        const rate = std.mem.readInt(u32, fields[4..8], .little);
        // fields[8..12] is byte_rate: informational, never validated or used.
        const block_align = std.mem.readInt(u16, fields[12..14], .little);
        const bits = std.mem.readInt(u16, fields[14..16], .little);

        if (tag != 1) return error.UnsupportedFormat;
        if (bits != 16) return error.UnsupportedFormat;
        const layout = audio.ChannelLayout.fromChannelCount(channels) catch |err| switch (err) {
            error.InvalidChannelCount => return error.InvalidFormat,
            error.UnsupportedChannelCount => return error.UnsupportedFormat,
        };
        if (rate == 0) return error.InvalidFormat;
        if (rate > p.limits.max_sample_rate) return error.LimitExceeded;
        const format: audio.Format = .{ .sample_rate = rate, .layout = layout, .sample_format = .s16 };
        if (block_align != format.bytesPerFrame()) return error.InvalidFormat;
        switch (size) {
            16 => {},
            18 => {
                const extension = try p.readArray(2);
                if (std.mem.readInt(u16, &extension, .little) != 0) return error.UnsupportedFormat;
            },
            else => return error.UnsupportedFormat,
        }
        // Accepted sizes are even, so no pad byte follows.
        p.extent_left -= size;
        p.format = format;
    }

    fn beginData(p: *Parser, size: u32) Error!Info {
        // Data is read straight from the reader; the prefix was consumed first.
        std.debug.assert(p.prefix.pending().len == 0);
        const format = p.format orelse return error.InvalidWave;
        if (size == std.math.maxInt(u32)) return error.UnsupportedStreamingSize;
        const frame_bytes = format.bytesPerFrame();
        if (size % frame_bytes != 0) return error.InvalidFormat;
        try p.checkExtent(size);
        // Whole frames of 2 or 4 bytes: the size is even, so no pad byte.
        p.extent_left -= size;
        p.data_left = size;
        p.state = .data;
        return .{ .format = format, .frame_count = size / frame_bytes };
    }

    fn skipChunk(p: *Parser, size: u32) Error!void {
        try p.checkExtent(size);
        p.reader.discardAll(size) catch |err| return mapRead(err);
        p.extent_left -= size;
        // A pad byte that would lie outside the extent is not read.
        if (size % 2 == 1 and p.extent_left > 0) {
            p.reader.discardAll(1) catch |err| return mapRead(err);
            p.extent_left -= 1;
        }
    }

    fn checkExtent(p: *Parser, size: u32) Error!void {
        if (size > p.extent_left) return error.InvalidRiff;
    }

    /// Every header and chunk field goes through here, so the first read takes
    /// any detection prefix; later reads find it empty.
    fn readArray(p: *Parser, comptime n: usize) Error![n]u8 {
        var bytes: [n]u8 = undefined;
        p.prefix.readAll(p.reader, &bytes) catch |err| return mapRead(err);
        return bytes;
    }
};

fn mapRead(err: std.Io.Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

/// Validates a complete WAV stream without decoding its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    try parser.finish();
    return info;
}

pub const DecodeError = Error || std.Io.Writer.Error;

/// Decodes a WAV stream and writes its samples to `out` as raw signed 16-bit
/// little-endian PCM, using fixed working storage. The caller flushes `out`.
pub fn decodeToRaw(reader: *std.Io.Reader, out: *std.Io.Writer, limits: Limits) DecodeError!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    var samples: [scratch_len / 2]i16 = undefined;
    var bytes: [scratch_len]u8 = undefined;
    while (true) {
        const decoded = try parser.readSamples(&samples);
        if (decoded.len == 0) break;
        // At most scratch_len / 2 samples encode into scratch_len bytes.
        try out.writeAll(pcm.encodeS16(.little, decoded, &bytes) catch unreachable);
    }
    try parser.finish();
    return info;
}

/// The header checks `Writer.check` and `Writer.begin` share.
pub const HeaderError = error{
    /// The sample format is not `s16` (the only one written so far, T21a).
    UnsupportedFormat,
    /// A zero sample rate.
    InvalidFormat,
    /// The sample rate is above `Limits.max_sample_rate`.
    LimitExceeded,
    /// The `data` or RIFF size would not fit in 32 bits.
    SizeOverflow,
};

pub const WriteError = std.Io.Writer.Error || HeaderError || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
    /// More frames than declared to `begin`.
    TooManyFrames,
    /// `finish` was called before all declared frames were written.
    TooFewFrames,
};

/// Writes one known-length WAV stream to a borrowed writer: a canonical header
/// with exact sizes (a 16-byte tag-1 `fmt ` at every supported rate), then the
/// samples. No seeking and no placeholder sizes.
pub const Writer = struct {
    out: *std.Io.Writer,
    format: audio.Format,
    frames_expected: u32,
    frames_written: u32 = 0,

    /// Checks every size, then writes the header. Nothing is written when a
    /// check fails.
    pub fn begin(out: *std.Io.Writer, format: audio.Format, frame_count: u64, limits: Limits) WriteError!Writer {
        const header = try encodeHeader(format, frame_count, limits);
        try out.writeAll(&header);
        // encodeHeader checked that the data size, and so the frame count, fits in u32.
        return .{ .out = out, .format = format, .frames_expected = @intCast(frame_count) };
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(format: audio.Format, frame_count: u64, limits: Limits) HeaderError!void {
        _ = try encodeHeader(format, frame_count, limits);
    }

    fn encodeHeader(format: audio.Format, frame_count: u64, limits: Limits) HeaderError![canonical_header_len]u8 {
        if (format.sample_format != .s16) return error.UnsupportedFormat;
        if (format.sample_rate == 0) return error.InvalidFormat;
        if (format.sample_rate > limits.max_sample_rate) return error.LimitExceeded;
        const frame_bytes = format.bytesPerFrame();
        const data_bytes = std.math.mul(u64, frame_count, frame_bytes) catch return error.SizeOverflow;
        const riff_size = std.math.add(u64, data_bytes, canonical_header_len - 8) catch return error.SizeOverflow;
        if (riff_size > std.math.maxInt(u32)) return error.SizeOverflow;
        const byte_rate = std.math.mul(u32, format.sample_rate, frame_bytes) catch return error.SizeOverflow;

        var header: [canonical_header_len]u8 = undefined;
        @memcpy(header[0..4], "RIFF");
        std.mem.writeInt(u32, header[4..8], @intCast(riff_size), .little);
        @memcpy(header[8..12], "WAVE");
        @memcpy(header[12..16], "fmt ");
        std.mem.writeInt(u32, header[16..20], 16, .little);
        std.mem.writeInt(u16, header[20..22], 1, .little);
        std.mem.writeInt(u16, header[22..24], format.channelCount(), .little);
        std.mem.writeInt(u32, header[24..28], format.sample_rate, .little);
        std.mem.writeInt(u32, header[28..32], byte_rate, .little);
        std.mem.writeInt(u16, header[32..34], @intCast(frame_bytes), .little);
        std.mem.writeInt(u16, header[34..36], 16, .little);
        @memcpy(header[36..40], "data");
        std.mem.writeInt(u32, header[40..44], @intCast(data_bytes), .little);
        return header;
    }

    /// Writes whole interleaved frames. Fails without writing when the frames
    /// are incomplete or exceed the declared count.
    pub fn writeFrames(w: *Writer, samples: []const i16) WriteError!void {
        const channels = w.format.channelCount();
        if (samples.len % channels != 0) return error.IncompleteFrame;
        if (samples.len / channels > w.frames_expected - w.frames_written) return error.TooManyFrames;
        var bytes: [scratch_len]u8 = undefined;
        var rest = samples;
        while (rest.len > 0) {
            // scratch_len / 2 samples are whole mono and stereo frames and
            // encode into at most scratch_len bytes.
            const take = @min(rest.len, scratch_len / 2);
            try w.writeData(pcm.encodeS16(.little, rest[0..take], &bytes) catch unreachable);
            rest = rest[take..];
        }
    }

    /// Writes whole frames already encoded as s16le, unchanged: the
    /// stream-copy counterpart of `writeFrames`. Fails without writing when
    /// the frames are incomplete or exceed the declared count.
    pub fn writeData(w: *Writer, bytes: []const u8) WriteError!void {
        const frame_bytes = w.format.bytesPerFrame();
        if (bytes.len % frame_bytes != 0) return error.IncompleteFrame;
        const frames = bytes.len / frame_bytes;
        if (frames > w.frames_expected - w.frames_written) return error.TooManyFrames;
        try w.out.writeAll(bytes);
        w.frames_written += @intCast(frames);
    }

    /// Verifies that every declared frame was written, then flushes `out`.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.frames_written != w.frames_expected) return error.TooFewFrames;
        try w.out.flush();
    }
};

const fixtures = @import("../testing/fixtures.zig");

const Decoded = struct {
    format: audio.Format,
    samples: []const i16,
};

fn decodeAll(reader: *std.Io.Reader, limits: Limits, storage: []i16) Error!Decoded {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    var len: usize = 0;
    while (true) {
        const decoded = try parser.readSamples(storage[len..]);
        if (decoded.len == 0) break;
        len += decoded.len;
    }
    try parser.finish();
    return .{ .format = info.format, .samples = storage[0..len] };
}

/// The parser error each fixture failure names. The manifest's `Failure` stays
/// independent of the parser; this exhaustive switch is the only link.
fn expectedError(failure: fixtures.Failure) Error {
    return switch (failure) {
        .InvalidRiff => error.InvalidRiff,
        .InvalidWave => error.InvalidWave,
        .InvalidFormat => error.InvalidFormat,
        .Truncated => error.Truncated,
        .UnsupportedFormat => error.UnsupportedFormat,
        .UnsupportedStreamingSize => error.UnsupportedStreamingSize,
        .LimitExceeded => error.LimitExceeded,
    };
}

fn expectFixture(comptime fixture: fixtures.Fixture, reader: *std.Io.Reader) !void {
    var storage: [256]i16 = undefined;
    const result = decodeAll(reader, .{}, &storage);
    switch (fixture.expected) {
        .accept => |stream| {
            const decoded = result catch |err| {
                std.debug.print("fixture {s}: expected acceptance, got error.{t}\n", .{ fixture.name, err });
                return err;
            };
            try std.testing.expectEqual(stream.channels, decoded.format.channelCount());
            try std.testing.expectEqual(stream.sample_rate, decoded.format.sample_rate);
            try std.testing.expectEqualSlices(i16, stream.samples, decoded.samples);
        },
        .reject => |failure| std.testing.expectError(expectedError(failure), result) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        },
    }
}

test "every fixture gives its contract result from memory" {
    inline for (fixtures.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
        try expectFixture(fixture, &reader);
    }
}

test "every fixture gives the same result from one-byte reads" {
    inline for (fixtures.all) |fixture| {
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.bytes(fixture.name) }});
        source.artificial_limit = .limited(1);
        try expectFixture(fixture, &source.interface);
    }
}

test "probing validates without decoding and agrees with decoding" {
    inline for (fixtures.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
        const result = probe(&reader, .{});
        switch (fixture.expected) {
            .accept => |stream| {
                const info = try result;
                try std.testing.expectEqual(stream.channels, info.format.channelCount());
                try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
                try std.testing.expectEqual(stream.samples.len / stream.channels, info.frame_count);
            },
            .reject => |failure| try std.testing.expectError(expectedError(failure), result),
        }
    }
}

test "raw decoding writes the expected little-endian samples" {
    inline for (fixtures.all) |fixture| {
        if (fixture.expected == .accept) {
            const stream = fixture.expected.accept;
            var reader: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
            var raw: [512]u8 = undefined;
            var out: std.Io.Writer = .fixed(&raw);
            _ = try decodeToRaw(&reader, &out, .{});
            var expected: [512]u8 = undefined;
            try std.testing.expectEqualSlices(u8, try pcm.encodeS16(.little, stream.samples, &expected), out.buffered());
        }
    }
}

test "an error after data is reported after the earlier frames were delivered" {
    var reader: std.Io.Reader = .fixed(fixtures.bytes("duplicate_data"));
    var parser: Parser = .init(&reader, .{});
    const info = try parser.readHeader();
    try std.testing.expectEqual(2, info.frame_count);
    var storage: [8]i16 = undefined;
    try std.testing.expectEqualSlices(i16, &.{ 0, 1 }, try parser.readSamples(&storage));
    try std.testing.expectEqual(0, (try parser.readSamples(&storage)).len);
    try std.testing.expectError(error.InvalidWave, parser.finish());
}

test "limits are configurable" {
    var storage: [8]i16 = undefined;
    var at_limit: std.Io.Reader = .fixed(fixtures.bytes("chunks_at_limit"));
    try std.testing.expectError(error.LimitExceeded, decodeAll(&at_limit, .{ .max_chunks = 4095 }, &storage));
    var fast: std.Io.Reader = .fixed(fixtures.bytes("mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, decodeAll(&fast, .{ .max_sample_rate = 191_999 }, &storage));
    var faster: std.Io.Reader = .fixed(fixtures.bytes("fmt_rate_over_limit"));
    const decoded = try decodeAll(&faster, .{ .max_sample_rate = 192_001 }, &storage);
    try std.testing.expectEqual(192_001, decoded.format.sample_rate);
}

test "the synthesized 2 MiB skip vector is accepted" {
    const gpa = std.testing.allocator;
    const list_len = 2 * 1024 * 1024;
    const total = canonical_header_len + 8 + list_len + 8;
    const bytes = try gpa.alloc(u8, total);
    defer gpa.free(bytes);
    @memset(bytes, 0);
    const mono_8k = fixtures.bytes("mono_8k");
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], total - 8, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..36], mono_8k[12..36]); // the `fmt ` chunk of mono_8k
    @memcpy(bytes[36..40], "LIST");
    std.mem.writeInt(u32, bytes[40..44], list_len, .little);
    const data_at = 44 + list_len;
    @memcpy(bytes[data_at..][0..4], "data");
    std.mem.writeInt(u32, bytes[data_at + 4 ..][0..4], 8, .little);
    @memcpy(bytes[data_at + 8 ..][0..8], mono_8k[44..52]);

    // Same bytes as generate.py's large_skip_vector (fixture README).
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("e3edce59e7710b921c2082f76f1b97a299b1a869a8ecf594dcf7099fb7e0414b", &hex);

    var reader: std.Io.Reader = .fixed(bytes);
    var storage: [8]i16 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(i16, &.{ 0, 1, -1, 32767 }, decoded.samples);
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    var reader: std.Io.Reader = .fixed(input[0..len]);
    var storage: [512]i16 = undefined;
    // Any contract error is acceptable; the parser must not crash or overrun.
    _ = decodeAll(&reader, .{}, &storage) catch {};
}

test "fuzz: arbitrary input never crashes the parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.bytes("mono_8k"),
        fixtures.bytes("stereo_44k1"),
        fixtures.bytes("unknown_chunks"),
        fixtures.bytes("odd_final_chunk_pad_missing"),
    } });
}

test "the writer reproduces every writer-output fixture byte for byte" {
    inline for (fixtures.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            const format = try audio.Format.init(stream.sample_rate, stream.channels, .s16);
            var buffer: [256]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            var writer = try Writer.begin(&out, format, stream.samples.len / stream.channels, .{});
            // One frame per call exercises repeated writes.
            var i: usize = 0;
            while (i < stream.samples.len) : (i += stream.channels) {
                try writer.writeFrames(stream.samples[i..][0..stream.channels]);
            }
            try writer.finish();
            try std.testing.expectEqualSlices(u8, fixtures.bytes(fixture.name), out.buffered());
        }
    }
}

test "the writer rejects frame-count mismatches and incomplete frames" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var writer = try Writer.begin(&out, stereo, 2, .{});
    try std.testing.expectError(error.IncompleteFrame, writer.writeFrames(&.{ 1, 2, 3 }));
    try std.testing.expectError(error.TooManyFrames, writer.writeFrames(&.{ 1, 2, 3, 4, 5, 6 }));
    try std.testing.expectEqual(canonical_header_len, out.buffered().len);
    try writer.writeFrames(&.{ 1, 2 });
    try std.testing.expectError(error.TooFewFrames, writer.finish());
    try writer.writeFrames(&.{ 3, 4 });
    try writer.finish();

    var reader: std.Io.Reader = .fixed(out.buffered());
    var storage: [8]i16 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(i16, &.{ 1, 2, 3, 4 }, decoded.samples);
}

test "the writer checks every size before writing the header" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, mono, std.math.maxInt(u64), .{}));
    // The largest mono stream whose RIFF size still fits in 32 bits.
    const max_frames = (std.math.maxInt(u32) - 36) / 2;
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, mono, max_frames + 1, .{}));
    const fast = try audio.Format.init(192_001, 1, .s16);
    try std.testing.expectError(error.LimitExceeded, Writer.begin(&out, fast, 0, .{}));
    const zero_rate: audio.Format = .{ .sample_rate = 0, .layout = .mono, .sample_format = .s16 };
    try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, zero_rate, 0, .{}));
    const floats = try audio.Format.init(8000, 1, .flt);
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, floats, 0, .{}));
    try std.testing.expectEqual(0, out.buffered().len);

    _ = try Writer.begin(&out, mono, max_frames, .{});
    const header = out.buffered();
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, std.mem.readInt(u32, header[4..8], .little));
    try std.testing.expectEqual(max_frames * 2, std.mem.readInt(u32, header[40..44], .little));
}

test "the writer reports write and flush failures" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var small: [10]u8 = undefined;
    var short: std.Io.Writer = .fixed(&small);
    try std.testing.expectError(error.WriteFailed, Writer.begin(&short, mono, 1, .{}));

    // The header fits in the buffer, so the failure surfaces at the flush.
    var buffer: [64]u8 = undefined;
    var failing_flush: std.Io.Writer = .{ .vtable = &.{ .drain = std.Io.Writer.failingDrain }, .buffer = &buffer };
    var writer = try Writer.begin(&failing_flush, mono, 1, .{});
    try writer.writeFrames(&.{7});
    try std.testing.expectError(error.WriteFailed, writer.finish());
}
