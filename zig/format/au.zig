// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/au.c and pcm.c at the pinned reference revision describe
// FFmpeg's more permissive behavior; see zig/testing/fixtures/au/README.md.
//! Bounded Sun AU reading and known-length writing for the PCM encodings of
//! FFmpeg's AU table (TODO.md T12, T22a): µ-law (1), s8 (2), s16, s24 and s32
//! big-endian (3 to 5), 32- and 64-bit big-endian float (6, 7) and A-law (27).
//!
//! The parser is sequential and never seeks, so it works on pipes. It reads the
//! 24-byte header exactly into a local array, skips the annotation without
//! keeping it, and never reads past the declared data. Unknown-length data is
//! read to the end of the input only when `Limits.unknown_length` opts in. Its
//! accepted subset, error names and error precedence are the contract in
//! zig/testing/fixtures/au/README.md; every fixture there is tested below.
//!
//! Parser errors and writer I/O errors are terminal: discard the parser or
//! writer afterward. The writer's frame-count errors (`IncompleteFrame`,
//! `TooManyFrames`, `TooFewFrames`) write nothing and leave it usable. Errors
//! found after samples were delivered still fail the stream; output is not
//! atomic. Neither the parser nor the writer allocates.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");
const pcm = @import("../codec/pcm.zig");

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

/// Configurable parser policy: limits, where exceeding one is
/// `error.LimitExceeded`, and the unknown-length opt-in.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// Bytes between the 24-byte header and the data.
    max_annotation_bytes: u32 = 1 << 20,
    /// Read a data size of 0xFFFFFFFF, which FFmpeg's muxer leaves on a pipe,
    /// as data running to the end of the input (T22a), rather than rejecting
    /// it as `UnsupportedStreamingSize`. The data must end on a whole frame,
    /// and `Info.frame_count` is null.
    unknown_length: bool = false,
};

pub const Info = struct {
    codec: pcm.Codec,
    /// The decoded stream: `sample_format` is `codec.storage()`.
    format: audio.Format,
    /// Sample frames in the data; null when its length is unknown.
    frame_count: ?u64,
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

/// The PCM encoding numbers of `codec_au_tags` in au.c.
fn codecFor(encoding: u32) ?pcm.Codec {
    return switch (encoding) {
        1 => .mulaw,
        2 => .s8,
        3 => .s16be,
        4 => .s24be,
        5 => .s32be,
        6 => .f32be,
        7 => .f64be,
        27 => .alaw,
        else => null,
    };
}

/// The encoding number that carries `codec` in AU, or `null` if AU cannot.
fn encodingFor(codec: pcm.Codec) ?u32 {
    return switch (codec) {
        .mulaw => 1,
        .s8 => 2,
        .s16be => 3,
        .s24be => 4,
        .s32be => 5,
        .f32be => 6,
        .f64be => 7,
        .alaw => 27,
        .u8, .s16le, .s24le, .s32le, .s64le, .s64be, .f32le, .f64le => null,
    };
}

/// Whether AU carries `codec`.
pub fn carries(codec: pcm.Codec) bool {
    return encodingFor(codec) != null;
}

/// Bytes decoded per read; a whole number of frames of every encoding.
const scratch_len = 4096;

/// Reads one AU stream from a borrowed reader.
///
/// Call `readHeader` once, then `readData` (or, for encodings stored as s16,
/// `readSamples`) until it returns nothing (or not at all), then `finish`,
/// which skips any unread data. The stream is valid only if `finish`
/// succeeds. Bytes after the declared data are never read.
pub const Parser = struct {
    reader: *std.Io.Reader,
    limits: Limits,
    codec: pcm.Codec = .s16be,
    /// Bytes of one encoded frame; set by `readHeader`.
    frame_bytes: u32 = 0,
    /// Bytes of data not yet delivered; null when the data runs to the end of
    /// the input.
    data_left: ?u32 = 0,
    state: State = .header,

    const State = enum { header, data, done };

    pub fn init(reader: *std.Io.Reader, limits: Limits) Parser {
        return .{ .reader = reader, .limits = limits };
    }

    /// Reads and validates the header, then skips the annotation. Header fields
    /// are checked in file order; the first failing check wins.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        var header: [header_len]u8 = undefined;
        p.reader.readSliceAll(&header) catch |err| return mapRead(err);
        if (!std.mem.eql(u8, header[0..4], ".snd")) return error.InvalidAu;
        const data_offset = std.mem.readInt(u32, header[4..8], .big);
        const data_size = std.mem.readInt(u32, header[8..12], .big);
        const encoding = std.mem.readInt(u32, header[12..16], .big);
        const rate = std.mem.readInt(u32, header[16..20], .big);
        const channels = std.mem.readInt(u32, header[20..24], .big);

        if (data_offset < header_len) return error.InvalidAu;
        const annotation_len = data_offset - header_len;
        if (annotation_len > p.limits.max_annotation_bytes) return error.LimitExceeded;
        const known_size: ?u32 = if (data_size == unknown_size) null else data_size;
        if (known_size) |size| {
            if (size > max_data_bytes) return error.LimitExceeded;
        } else if (!p.limits.unknown_length) {
            return error.UnsupportedStreamingSize;
        }
        const codec = codecFor(encoding) orelse return error.UnsupportedFormat;
        if (rate == 0) return error.InvalidFormat;
        if (rate > p.limits.max_sample_rate) return error.LimitExceeded;
        // A count that does not fit in u16 is far above the two supported channels.
        const channel_count = std.math.cast(u16, channels) orelse return error.UnsupportedFormat;
        const layout = audio.ChannelLayout.fromChannelCount(channel_count) catch |err| switch (err) {
            error.InvalidChannelCount => return error.InvalidFormat,
            error.UnsupportedChannelCount => return error.UnsupportedFormat,
        };
        const format: audio.Format = .{ .sample_rate = rate, .layout = layout, .sample_format = codec.storage() };
        // At most 8 bytes times 2 channels.
        const sample_bytes: u32 = codec.bytesPerSample();
        const frame_bytes = sample_bytes * channel_count;
        if (known_size) |size| {
            if (size % frame_bytes != 0) return error.InvalidFormat;
        }

        p.reader.discardAll(annotation_len) catch |err| return mapRead(err);
        p.codec = codec;
        p.frame_bytes = frame_bytes;
        p.data_left = known_size;
        p.state = .data;
        const frame_count: ?u64 = if (known_size) |size| size / frame_bytes else null;
        return .{ .codec = codec, .format = format, .frame_count = frame_count };
    }

    /// Decodes whole frames of interleaved samples into the start of `output`
    /// and returns the decoded prefix. Returns no samples once the data is
    /// exhausted, or when `output` cannot hold one frame. Only for encodings
    /// stored as s16 (s16be, µ-law, A-law); use `readData` and `pcm.decode`
    /// for the others.
    pub fn readSamples(p: *Parser, output: []i16) Error![]i16 {
        std.debug.assert(p.codec.storage() == .s16);
        const width = p.codec.bytesPerSample();
        var scratch: [scratch_len]u8 = undefined;
        var produced: usize = 0;
        while (true) {
            // At most 2 bytes per sample: an i16 slice already spans that much.
            const room_bytes = @min(scratch_len, (output.len - produced) * width);
            const bytes = try p.readData(scratch[0..room_bytes]);
            if (bytes.len == 0) break;
            // Whole frames of at most room_bytes bytes fit in the output.
            const decoded = pcm.decodeToS16(p.codec, bytes, output[produced..]) catch unreachable;
            produced += decoded.len;
        }
        return output[0..produced];
    }

    /// Reads whole frames of data, still encoded, into the start of `output`
    /// and returns that prefix: the stream-copy counterpart of `readSamples`.
    /// Returns no bytes once the data is exhausted, or when `output` cannot
    /// hold one frame.
    pub fn readData(p: *Parser, output: []u8) Error![]u8 {
        std.debug.assert(p.state == .data);
        const whole = output[0 .. output.len - output.len % p.frame_bytes];
        const data_left = p.data_left orelse {
            // The data runs to the end of the input: a short read ends it.
            const len = p.reader.readSliceShort(whole) catch |err| switch (err) {
                error.ReadFailed => return error.IoFailure,
            };
            if (len % p.frame_bytes != 0) return error.Truncated;
            return whole[0..len];
        };
        const want = @min(data_left, whole.len);
        p.reader.readSliceAll(whole[0..want]) catch |err| return mapRead(err);
        // want is at most data_left, a u32.
        const taken: u32 = @intCast(want);
        p.data_left = data_left - taken;
        return whole[0..want];
    }

    /// Skips any unread data. Input ending inside it is `Truncated`; bytes
    /// after it are never read. Data of unknown length is skipped to the end
    /// of the input, which must end on a whole frame.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        if (p.data_left) |data_left| {
            p.reader.discardAll(data_left) catch |err| return mapRead(err);
        } else {
            const step = 1 << 16;
            // Counted modulo the frame size, so no total overflows.
            var partial: usize = 0;
            while (true) {
                const skipped = p.reader.discardShort(step) catch |err| switch (err) {
                    error.ReadFailed => return error.IoFailure,
                };
                partial = (partial + skipped) % p.frame_bytes;
                if (skipped < step) break;
            }
            if (partial != 0) return error.Truncated;
        }
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

/// Decodes an AU stream and writes its samples to `out` as raw little-endian
/// samples of the stream's storage format (`Info.format.sample_format`), using
/// fixed working storage. The caller flushes `out`.
pub fn decodeToRaw(reader: *std.Io.Reader, out: *std.Io.Writer, limits: Limits) DecodeError!Info {
    var parser: Parser = .init(reader, limits);
    const info = try parser.readHeader();
    var encoded: [scratch_len]u8 = undefined;
    // Storage is at most twice the encoded size (µ-law and A-law to s16).
    var stored: [2 * scratch_len]u8 = undefined;
    const channels = info.format.channelCount();
    while (true) {
        const bytes = try parser.readData(&encoded);
        if (bytes.len == 0) break;
        const frames: u32 = @intCast(bytes.len / parser.frame_bytes);
        const layout = samples_storage.Layout.init(info.format.sample_format, channels, frames, .{ .line = 1 }) catch unreachable;
        const buffer = samples_storage.Buffer.init(layout, &stored) catch unreachable;
        _ = pcm.decode(info.codec, bytes, buffer, 0) catch unreachable;
        pcm.storedToLittle(info.format.sample_format, buffer.bytes);
        try out.writeAll(buffer.bytes);
    }
    try parser.finish();
    return info;
}

/// The header checks `Writer.check` and `Writer.begin` share.
pub const HeaderError = error{
    /// AU does not carry the codec, or the format's storage is not the codec's.
    UnsupportedFormat,
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
/// 32-byte header with the codec's encoding and the exact data size, then the
/// samples. No seeking and no placeholder size.
pub const Writer = struct {
    out: *std.Io.Writer,
    codec: pcm.Codec,
    format: audio.Format,
    frames_expected: u32,
    frames_written: u32 = 0,

    /// Checks every size, then writes the header. Nothing is written when a
    /// check fails. `format.sample_format` must be `codec.storage()`.
    pub fn begin(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, frame_count: u64, limits: Limits) WriteError!Writer {
        const header = try encodeHeader(codec, format, frame_count, limits);
        try out.writeAll(&header);
        // encodeHeader checked the data size against max_data_bytes, so the
        // frame count fits in u32.
        return .{ .out = out, .codec = codec, .format = format, .frames_expected = @intCast(frame_count) };
    }

    /// Runs `begin`'s checks without writing, so a caller can reject an
    /// operation before its output exists.
    pub fn check(codec: pcm.Codec, format: audio.Format, frame_count: u64, limits: Limits) HeaderError!void {
        _ = try encodeHeader(codec, format, frame_count, limits);
    }

    fn encodeHeader(codec: pcm.Codec, format: audio.Format, frame_count: u64, limits: Limits) HeaderError![canonical_header_len]u8 {
        const encoding = encodingFor(codec) orelse return error.UnsupportedFormat;
        if (format.sample_format != codec.storage()) return error.UnsupportedFormat;
        if (format.sample_rate == 0) return error.InvalidFormat;
        if (format.sample_rate > limits.max_sample_rate) return error.LimitExceeded;
        const sample_bytes: u32 = codec.bytesPerSample();
        const frame_bytes = sample_bytes * format.channelCount();
        const data_bytes = std.math.mul(u64, frame_count, frame_bytes) catch return error.SizeOverflow;
        if (data_bytes > max_data_bytes) return error.SizeOverflow;

        // header[24..32] stays zero: the 8-byte annotation.
        var header: [canonical_header_len]u8 = @splat(0);
        @memcpy(header[0..4], ".snd");
        std.mem.writeInt(u32, header[4..8], canonical_header_len, .big);
        std.mem.writeInt(u32, header[8..12], @intCast(data_bytes), .big);
        std.mem.writeInt(u32, header[12..16], encoding, .big);
        std.mem.writeInt(u32, header[16..20], format.sample_rate, .big);
        std.mem.writeInt(u32, header[20..24], format.channelCount(), .big);
        return header;
    }

    /// Writes whole interleaved frames of samples stored as s16, encoded as
    /// the writer's codec (which must be stored as s16). Fails without writing
    /// when the frames are incomplete or exceed the declared count.
    pub fn writeFrames(w: *Writer, samples: []const i16) WriteError!void {
        std.debug.assert(w.codec.storage() == .s16);
        const channels = w.format.channelCount();
        if (samples.len % channels != 0) return error.IncompleteFrame;
        if (samples.len / channels > w.frames_expected - w.frames_written) return error.TooManyFrames;
        var bytes: [scratch_len]u8 = undefined;
        var rest = samples;
        while (rest.len > 0) {
            // scratch_len / 2 samples are whole mono and stereo frames and
            // encode into at most scratch_len bytes.
            const take = @min(rest.len, scratch_len / 2);
            try w.writeData(pcm.encodeFromS16(w.codec, rest[0..take], &bytes) catch unreachable);
            rest = rest[take..];
        }
    }

    /// Writes whole frames already encoded as the writer's codec, unchanged:
    /// the stream-copy counterpart of `writeFrames`. Fails without writing
    /// when the frames are incomplete or exceed the declared count.
    pub fn writeData(w: *Writer, bytes: []const u8) WriteError!void {
        const sample_bytes: usize = w.codec.bytesPerSample();
        const frame_bytes = sample_bytes * w.format.channelCount();
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

/// The implementation's codec for a manifest codec; the names are FFmpeg's.
fn codecOf(comptime codec: fixtures.Codec) pcm.Codec {
    return comptime std.meta.stringToEnum(pcm.Codec, @tagName(codec)["pcm_".len..]).?;
}

const Decoded = struct {
    info: Info,
    raw: []const u8,
};

fn decodeAll(reader: *std.Io.Reader, limits: Limits, storage: []u8) DecodeError!Decoded {
    var out: std.Io.Writer = .fixed(storage);
    const info = try decodeToRaw(reader, &out, limits);
    return .{ .info = info, .raw = out.buffered() };
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

fn expectStream(comptime stream: fixtures.Stream, decoded: Decoded) !void {
    try std.testing.expectEqual(codecOf(stream.codec), decoded.info.codec);
    try std.testing.expectEqual(stream.channels, decoded.info.format.channelCount());
    try std.testing.expectEqual(stream.sample_rate, decoded.info.format.sample_rate);
    try std.testing.expectEqual(codecOf(stream.codec).storage(), decoded.info.format.sample_format);
    // Unknown-length data has no count; the samples below still fix the length.
    if (decoded.info.frame_count) |count| try std.testing.expectEqual(stream.frameCount(), count);
    var expected: [1024]u8 = undefined;
    try std.testing.expectEqualSlices(u8, stream.samples.littleEndian(&expected), decoded.raw);
}

/// Decodes one fixture with the `unknown_length` option off or on and checks
/// the result the manifest gives for that setting.
fn expectFixture(comptime fixture: fixtures.au.Fixture, comptime unknown_length: bool, reader: *std.Io.Reader) !void {
    var storage: [1024]u8 = undefined;
    const result = decodeAll(reader, .{ .unknown_length = unknown_length }, &storage);
    errdefer std.debug.print("fixture {s}, unknown_length {}\n", .{ fixture.name, unknown_length });
    switch (comptime fixture.result(unknown_length)) {
        .accept => |stream| try expectStream(stream, try result),
        .reject => |failure| try std.testing.expectError(expectedError(failure), result),
    }
}

test "every AU fixture gives its contract result from memory" {
    inline for (fixtures.au.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var reader: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
            try expectFixture(fixture, unknown_length, &reader);
        }
    }
}

test "every AU fixture gives the same result from one-byte reads" {
    inline for (fixtures.au.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var buffer: [1]u8 = undefined;
            var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.au.bytes(fixture.name) }});
            source.artificial_limit = .limited(1);
            try expectFixture(fixture, unknown_length, &source.interface);
        }
    }
}

test "probing validates without decoding and agrees with decoding" {
    @setEvalBranchQuota(10_000);
    inline for (fixtures.au.all) |fixture| {
        inline for (.{ false, true }) |unknown_length| {
            var reader: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
            const result = probe(&reader, .{ .unknown_length = unknown_length });
            switch (comptime fixture.result(unknown_length)) {
                .accept => |stream| {
                    const info = try result;
                    try std.testing.expectEqual(codecOf(stream.codec), info.codec);
                    try std.testing.expectEqual(stream.channels, info.format.channelCount());
                    try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
                    if (info.frame_count) |count| try std.testing.expectEqual(stream.frameCount(), count);
                },
                .reject => |failure| try std.testing.expectError(expectedError(failure), result),
            }
        }
    }
}

test "readSamples gives s16 samples for every encoding stored as s16" {
    var checked: usize = 0;
    inline for (fixtures.au.all) |fixture| {
        if (fixture.expected == .accept and fixture.expected.accept.samples == .s16) {
            var reader: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
            var parser: Parser = .init(&reader, .{});
            _ = try parser.readHeader();
            var storage: [256]i16 = undefined;
            var len: usize = 0;
            while (true) {
                const decoded = try parser.readSamples(storage[len..]);
                if (decoded.len == 0) break;
                len += decoded.len;
            }
            try parser.finish();
            try std.testing.expectEqualSlices(i16, fixture.expected.accept.samples.s16, storage[0..len]);
            checked += 1;
        }
    }
    // s16be, µ-law and A-law among them.
    try std.testing.expect(checked > 3);
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
    var storage: [16]u8 = undefined;
    var fast: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, decodeAll(&fast, .{ .max_sample_rate = 191_999 }, &storage));
    var faster: std.Io.Reader = .fixed(fixtures.au.bytes("au_rate_over_limit"));
    const decoded = try decodeAll(&faster, .{ .max_sample_rate = 192_001 }, &storage);
    try std.testing.expectEqual(192_001, decoded.info.format.sample_rate);

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
    var storage: [16]u8 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0xFF, 0xFF, 0xFF, 0x7F }, decoded.raw);
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

const synthetic = @import("../testing/synthetic.zig");

test "unknown-length AU data past 4 GiB is read to the end of the input" {
    // The header of au_unknown_size: data size 0xFFFFFFFF, s16be mono.
    const header = fixtures.au.bytes("au_unknown_size")[0..canonical_header_len];
    const limits: Limits = .{ .unknown_length = true };
    var reader_buffer: [64]u8 = undefined;
    var whole: synthetic.ZeroStream = .init(header, 5 << 30, "", &reader_buffer);
    try std.testing.expectEqual(null, (try probe(&whole.interface, limits)).frame_count);
    var partial: synthetic.ZeroStream = .init(header, (5 << 30) + 1, "", &reader_buffer);
    try std.testing.expectError(error.Truncated, probe(&partial.interface, limits));
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    var reader: std.Io.Reader = .fixed(input[0..len]);
    // At most 1024 encoded bytes, stored in at most twice that.
    var storage: [2048]u8 = undefined;
    // Any contract error is acceptable; the parser must not crash or overrun.
    _ = decodeAll(&reader, .{}, &storage) catch {};
}

test "fuzz: arbitrary input never crashes the AU parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.au.bytes("au_mono_8k"),
        fixtures.au.bytes("au_stereo_44k1"),
        fixtures.au.bytes("au_annotation_text"),
        fixtures.au.bytes("au_truncated_data"),
        fixtures.au.bytes("au_s24_stereo"),
        fixtures.au.bytes("au_mulaw_mono_8k"),
    } });
}

/// Encodes the manifest's samples as `codec`, through T20a storage.
fn encodeExpected(comptime stream: fixtures.Stream, out: []u8) ![]const u8 {
    var stored: [1024]u8 = undefined;
    const raw = stream.samples.littleEndian(&stored);
    const codec = codecOf(stream.codec);
    pcm.storedToLittle(codec.storage(), stored[0..raw.len]); // little-endian to stored, a swap either way
    const frames: u32 = @intCast(stream.frameCount());
    if (frames == 0) return out[0..0];
    const layout = try samples_storage.Layout.init(codec.storage(), stream.channels, frames, .{ .line = 1 });
    const buffer = try samples_storage.Buffer.init(layout, stored[0..raw.len]);
    return pcm.encode(codec, buffer, 0, frames, out);
}

test "the writer reproduces every AU writer-output fixture byte for byte" {
    var count: usize = 0;
    inline for (fixtures.au.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            const codec = codecOf(stream.codec);
            const format = try audio.Format.init(stream.sample_rate, stream.channels, codec.storage());
            var encoded: [1024]u8 = undefined;
            const data = try encodeExpected(stream, &encoded);
            var buffer: [1024]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            var writer = try Writer.begin(&out, codec, format, stream.frameCount(), .{});
            // One frame per call exercises repeated writes.
            const frame_bytes = codec.bytesPerSample() * stream.channels;
            var i: usize = 0;
            while (i < data.len) : (i += frame_bytes) try writer.writeData(data[i..][0..frame_bytes]);
            try writer.finish();
            std.testing.expectEqualSlices(u8, fixtures.au.bytes(fixture.name), out.buffered()) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
            count += 1;
        }
    }
    // s16be and the seven encodings of T22a.
    try std.testing.expect(count >= 11);
}

test "writeFrames encodes s16 samples as the writer's codec" {
    inline for (.{ "au_mono_8k", "au_mulaw_mono_8k", "au_alaw_mono_8k" }) |name| {
        const stream = comptime for (fixtures.au.all) |f| {
            if (std.mem.eql(u8, f.name, name)) break f.expected.accept;
        } else unreachable;
        const codec = codecOf(stream.codec);
        const format = try audio.Format.init(stream.sample_rate, stream.channels, .s16);
        var buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var writer = try Writer.begin(&out, codec, format, stream.frameCount(), .{});
        try writer.writeFrames(stream.samples.s16);
        try writer.finish();
        try std.testing.expectEqualSlices(u8, fixtures.au.bytes(name), out.buffered());
    }
}

test "the writer rejects frame-count mismatches and incomplete frames" {
    const stereo = try audio.Format.init(44100, 2, .s16);
    var buffer: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var writer = try Writer.begin(&out, .s16be, stereo, 2, .{});
    try std.testing.expectError(error.IncompleteFrame, writer.writeFrames(&.{ 1, 2, 3 }));
    try std.testing.expectError(error.TooManyFrames, writer.writeFrames(&.{ 1, 2, 3, 4, 5, 6 }));
    try std.testing.expectError(error.IncompleteFrame, writer.writeData(&.{ 1, 2, 3 }));
    try std.testing.expectEqual(canonical_header_len, out.buffered().len);
    try writer.writeFrames(&.{ 1, 2 });
    try std.testing.expectError(error.TooFewFrames, writer.finish());
    try writer.writeFrames(&.{ 3, 4 });
    try writer.finish();

    var reader: std.Io.Reader = .fixed(out.buffered());
    var storage: [16]u8 = undefined;
    const decoded = try decodeAll(&reader, .{}, &storage);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0, 3, 0, 4, 0 }, decoded.raw);
}

test "the writer checks every size and the codec before writing the header" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16be, mono, std.math.maxInt(u64), .{}));
    // The largest mono stream within the data size bound.
    const max_frames = max_data_bytes / 2;
    try std.testing.expectError(error.SizeOverflow, Writer.begin(&out, .s16be, mono, max_frames + 1, .{}));
    const fast = try audio.Format.init(192_001, 1, .s16);
    try std.testing.expectError(error.LimitExceeded, Writer.begin(&out, .s16be, fast, 0, .{}));
    const zero_rate: audio.Format = .{ .sample_rate = 0, .layout = .mono, .sample_format = .s16 };
    try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, .s16be, zero_rate, 0, .{}));
    const planar = try audio.Format.init(8000, 1, .s16p);
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s16be, planar, 0, .{}));
    // AU does not carry little-endian encodings, and the storage must match.
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s16le, mono, 0, .{}));
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s24be, mono, 0, .{}));
    try std.testing.expectEqual(0, out.buffered().len);
    try std.testing.expect(carries(.s8) and carries(.alaw) and !carries(.u8) and !carries(.s64be));

    _ = try Writer.begin(&out, .s16be, mono, max_frames, .{});
    const header = out.buffered();
    try std.testing.expectEqual(max_frames * 2, std.mem.readInt(u32, header[8..12], .big));
}

test "the writer reports write and flush failures" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var small: [10]u8 = undefined;
    var short: std.Io.Writer = .fixed(&small);
    try std.testing.expectError(error.WriteFailed, Writer.begin(&short, .s16be, mono, 1, .{}));

    // The header fits in the buffer, so the failure surfaces at the flush.
    var buffer: [64]u8 = undefined;
    var failing_flush: std.Io.Writer = .{ .vtable = &.{ .drain = std.Io.Writer.failingDrain }, .buffer = &buffer };
    var writer = try Writer.begin(&failing_flush, .s16be, mono, 1, .{});
    try writer.writeFrames(&.{7});
    try std.testing.expectError(error.WriteFailed, writer.finish());
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}
