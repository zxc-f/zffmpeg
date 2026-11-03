// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/au.c and pcm.c at the pinned reference revision describe
// FFmpeg's more permissive behavior; see zig/testing/fixtures/au/README.md.
//! Bounded Sun AU reading and known-length writing for signed 16-bit
//! big-endian PCM (AU encoding 3).
//!
//! The parser is sequential and never seeks, so it works on pipes. It reads the
//! 24-byte header exactly into a local array, skips the annotation without
//! keeping it, and never reads past the declared data. Its accepted subset,
//! error names and error precedence are the contract in
//! zig/testing/fixtures/au/README.md; every fixture there is tested below.
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

/// Contract errors (see the AU fixture README), plus `IoFailure` for a failing
/// reader.
pub const Error = error{
    InvalidAu,
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
    /// Bytes between the 24-byte header and the data.
    max_annotation_bytes: u32 = 1 << 20,
};

pub const Info = struct {
    format: audio.Format,
    /// Sample frames in the data.
    frame_count: u64,
};

/// Bytes of the fixed header: magic, data offset, data size, encoding, sample
/// rate and channels, each a big-endian `u32`.
pub const header_len = 24;

/// Size of the canonical header the writer emits: the fixed header and 8 zero
/// annotation bytes, as FFmpeg's AU muxer writes without metadata.
pub const canonical_header_len = 32;

/// The largest data size read or written. FFmpeg reads the field as signed and
/// rejects larger values, so this bound keeps files readable by it.
pub const max_data_bytes: u32 = std.math.maxInt(i32);

/// The data size that means "unknown length".
const unknown_size: u32 = std.math.maxInt(u32);

/// AU encoding 3: signed 16-bit big-endian PCM.
const encoding_pcm_s16be: u32 = 3;

/// Bytes decoded per read; a whole number of mono and stereo frames.
const scratch_len = 4096;

/// Reads one AU stream from a borrowed reader.
///
/// Call `readHeader` once, then `readSamples` until it returns no samples (or
/// not at all), then `finish`, which skips any unread data. The stream is valid
/// only if `finish` succeeds. Bytes after the declared data are never read.
pub const Parser = struct {
    reader: *std.Io.Reader,
    limits: Limits,
    /// Bytes content detection already read; they come before the reader's.
    prefix: Prefix = .{},
    format: ?audio.Format = null,
    /// Bytes of data not yet delivered.
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

    /// Reads and validates the header, then skips the annotation. Header fields
    /// are checked in file order; the first failing check wins.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        // The header is longer than any detection prefix, so this read takes it all.
        var header: [header_len]u8 = undefined;
        p.prefix.readAll(p.reader, &header) catch |err| return mapRead(err);
        if (!std.mem.eql(u8, header[0..4], ".snd")) return error.InvalidAu;
        const data_offset = std.mem.readInt(u32, header[4..8], .big);
        const data_size = std.mem.readInt(u32, header[8..12], .big);
        const encoding = std.mem.readInt(u32, header[12..16], .big);
        const rate = std.mem.readInt(u32, header[16..20], .big);
        const channels = std.mem.readInt(u32, header[20..24], .big);

        if (data_offset < header_len) return error.InvalidAu;
        const annotation_len = data_offset - header_len;
        if (annotation_len > p.limits.max_annotation_bytes) return error.LimitExceeded;
        if (data_size == unknown_size) return error.UnsupportedStreamingSize;
        if (data_size > max_data_bytes) return error.LimitExceeded;
        if (encoding != encoding_pcm_s16be) return error.UnsupportedFormat;
        if (rate == 0) return error.InvalidFormat;
        if (rate > p.limits.max_sample_rate) return error.LimitExceeded;
        // A count that does not fit in u16 is far above the two supported channels.
        const channel_count = std.math.cast(u16, channels) orelse return error.UnsupportedFormat;
        const layout = audio.ChannelLayout.fromChannelCount(channel_count) catch |err| switch (err) {
            error.InvalidChannelCount => return error.InvalidFormat,
            error.UnsupportedChannelCount => return error.UnsupportedFormat,
        };
        const format: audio.Format = .{ .sample_rate = rate, .layout = layout, .sample_format = .s16 };
        const frame_bytes = format.bytesPerFrame();
        if (data_size % frame_bytes != 0) return error.InvalidFormat;

        p.reader.discardAll(annotation_len) catch |err| return mapRead(err);
        p.format = format;
        p.data_left = data_size;
        p.state = .data;
        return .{ .format = format, .frame_count = data_size / frame_bytes };
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
            const decoded = pcm.decodeS16(.big, bytes, output[produced..]) catch unreachable;
            produced += decoded.len;
        }
        return output[0..produced];
    }

    /// Reads whole frames of data, still encoded as s16be, into the start of
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

    /// Skips any unread data. Input ending inside it is `Truncated`; bytes
    /// after it are never read.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        p.reader.discardAll(p.data_left) catch |err| return mapRead(err);
        p.data_left = 0;
        p.state = .done;
    }
};

fn mapRead(err: std.Io.Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

/// Validates a complete AU stream without decoding its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    try parser.finish();
    return info;
}

pub const DecodeError = Error || std.Io.Writer.Error;

/// Decodes an AU stream and writes its samples to `out` as raw signed 16-bit
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
    /// A zero sample rate.
    InvalidFormat,
    /// The sample rate is above `Limits.max_sample_rate`.
    LimitExceeded,
    /// The data would exceed `max_data_bytes`.
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

/// Writes one known-length AU stream to a borrowed writer: the canonical
/// 32-byte header with the exact data size, then the samples. No seeking and
/// no placeholder size.
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
        // encodeHeader checked the data size against max_data_bytes, so the
        // frame count fits in u32.
        return .{ .out = out, .format = format, .frames_expected = @intCast(frame_count) };
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(format: audio.Format, frame_count: u64, limits: Limits) HeaderError!void {
        _ = try encodeHeader(format, frame_count, limits);
    }

    fn encodeHeader(format: audio.Format, frame_count: u64, limits: Limits) HeaderError![canonical_header_len]u8 {
        if (format.sample_rate == 0) return error.InvalidFormat;
        if (format.sample_rate > limits.max_sample_rate) return error.LimitExceeded;
        const frame_bytes = format.bytesPerFrame();
        const data_bytes = std.math.mul(u64, frame_count, frame_bytes) catch return error.SizeOverflow;
        if (data_bytes > max_data_bytes) return error.SizeOverflow;

        // header[24..32] stays zero: the 8-byte annotation.
        var header: [canonical_header_len]u8 = @splat(0);
        @memcpy(header[0..4], ".snd");
        std.mem.writeInt(u32, header[4..8], canonical_header_len, .big);
        std.mem.writeInt(u32, header[8..12], @intCast(data_bytes), .big);
        std.mem.writeInt(u32, header[12..16], encoding_pcm_s16be, .big);
        std.mem.writeInt(u32, header[16..20], format.sample_rate, .big);
        std.mem.writeInt(u32, header[20..24], format.channelCount(), .big);
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
            try w.writeData(pcm.encodeS16(.big, rest[0..take], &bytes) catch unreachable);
            rest = rest[take..];
        }
    }

    /// Writes whole frames already encoded as s16be, unchanged: the
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
fn expectedError(failure: fixtures.au.Failure) Error {
    return switch (failure) {
        .InvalidAu => error.InvalidAu,
        .InvalidFormat => error.InvalidFormat,
        .Truncated => error.Truncated,
        .UnsupportedFormat => error.UnsupportedFormat,
        .UnsupportedStreamingSize => error.UnsupportedStreamingSize,
        .LimitExceeded => error.LimitExceeded,
    };
}

fn expectFixture(comptime fixture: fixtures.au.Fixture, reader: *std.Io.Reader) !void {
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

test "every AU fixture gives its contract result from memory" {
    inline for (fixtures.au.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
        try expectFixture(fixture, &reader);
    }
}

test "every AU fixture gives the same result from one-byte reads" {
    inline for (fixtures.au.all) |fixture| {
        var buffer: [1]u8 = undefined;
        var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.au.bytes(fixture.name) }});
        source.artificial_limit = .limited(1);
        try expectFixture(fixture, &source.interface);
    }
}

test "probing validates without decoding and agrees with decoding" {
    inline for (fixtures.au.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
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
    inline for (fixtures.au.all) |fixture| {
        if (fixture.expected == .accept) {
            const stream = fixture.expected.accept;
            var reader: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
            var raw: [512]u8 = undefined;
            var out: std.Io.Writer = .fixed(&raw);
            _ = try decodeToRaw(&reader, &out, .{});
            var expected: [512]u8 = undefined;
            try std.testing.expectEqualSlices(u8, try pcm.encodeS16(.little, stream.samples, &expected), out.buffered());
        }
    }
}

test "truncated data fails after the earlier frames were delivered" {
    var reader: std.Io.Reader = .fixed(fixtures.au.bytes("au_truncated_data"));
    var parser: Parser = .init(&reader, .{});
    const info = try parser.readHeader();
    try std.testing.expectEqual(8, info.frame_count);
    var storage: [2]i16 = undefined;
    try std.testing.expectEqualSlices(i16, &.{ 0, 1 }, try parser.readSamples(&storage));
    try std.testing.expectEqualSlices(i16, &.{ -1, 32767 }, try parser.readSamples(&storage));
    try std.testing.expectError(error.Truncated, parser.readSamples(&storage));
}

test "limits are configurable" {
    var storage: [8]i16 = undefined;
    var fast: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, decodeAll(&fast, .{ .max_sample_rate = 191_999 }, &storage));
    var faster: std.Io.Reader = .fixed(fixtures.au.bytes("au_rate_over_limit"));
    const decoded = try decodeAll(&faster, .{ .max_sample_rate = 192_001 }, &storage);
    try std.testing.expectEqual(192_001, decoded.format.sample_rate);

    // au_annotation_text has a 16-byte annotation.
    var short_limit: std.Io.Reader = .fixed(fixtures.au.bytes("au_annotation_text"));
    try std.testing.expectError(error.LimitExceeded, decodeAll(&short_limit, .{ .max_annotation_bytes = 15 }, &storage));
    var exact_limit: std.Io.Reader = .fixed(fixtures.au.bytes("au_annotation_text"));
    _ = try decodeAll(&exact_limit, .{ .max_annotation_bytes = 16 }, &storage);
}

test "an annotation of exactly the default limit is skipped" {
    const gpa = std.testing.allocator;
    const annotation_len = (Limits{}).max_annotation_bytes;
    const header = fixtures.au.bytes("au_header_24");
    const bytes = try gpa.alloc(u8, header.len + annotation_len);
    defer gpa.free(bytes);
    // au_header_24 is a 24-byte header and 4 samples; put the annotation between.
    @memcpy(bytes[0..header_len], header[0..header_len]);
    std.mem.writeInt(u32, bytes[4..8], header_len + annotation_len, .big);
    @memset(bytes[header_len..][0..annotation_len], 'a');
    @memcpy(bytes[header_len + annotation_len ..], header[header_len..]);

    var reader: std.Io.Reader = .fixed(bytes);
    var storage: [8]i16 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(i16, &.{ 0, 1, -1, 32767 }, decoded.samples);
}

test "the largest data size is accepted from the header and its absence is truncation" {
    // A mono header declaring the largest whole-frame size within the bound.
    var bytes = fixtures.au.bytes("au_header_24")[0..header_len].*;
    const largest = max_data_bytes - max_data_bytes % 2;
    std.mem.writeInt(u32, bytes[8..12], largest, .big);
    var reader: std.Io.Reader = .fixed(&bytes);
    var parser: Parser = .init(&reader, .{});
    const info = try parser.readHeader();
    try std.testing.expectEqual(largest / 2, info.frame_count);
    try std.testing.expectError(error.Truncated, parser.finish());
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

test "fuzz: arbitrary input never crashes the AU parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.au.bytes("au_mono_8k"),
        fixtures.au.bytes("au_stereo_44k1"),
        fixtures.au.bytes("au_annotation_text"),
        fixtures.au.bytes("au_truncated_data"),
    } });
}

test "the writer reproduces every AU writer-output fixture byte for byte" {
    inline for (fixtures.au.all) |fixture| {
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
            try std.testing.expectEqualSlices(u8, fixtures.au.bytes(fixture.name), out.buffered());
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
    // The largest mono stream within the data size bound.
    const max_frames = max_data_bytes / 2;
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, mono, max_frames + 1, .{}));
    const fast = try audio.Format.init(192_001, 1, .s16);
    try std.testing.expectError(error.LimitExceeded, Writer.begin(&out, fast, 0, .{}));
    const zero_rate: audio.Format = .{ .sample_rate = 0, .layout = .mono, .sample_format = .s16 };
    try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, zero_rate, 0, .{}));
    try std.testing.expectEqual(0, out.buffered().len);

    _ = try Writer.begin(&out, mono, max_frames, .{});
    const header = out.buffered();
    try std.testing.expectEqual(max_frames * 2, std.mem.readInt(u32, header[8..12], .big));
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

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}
