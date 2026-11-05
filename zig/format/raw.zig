// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/pcmdec.c, pcmenc.c, pcm.c and rawenc.c at the pinned reference
// revision describe FFmpeg's behavior; see zig/testing/fixtures/raw/README.md.
//! Raw PCM (TODO.md T22c): header-less interleaved samples in one PCM
//! encoding, read with the stream parameters the caller gives (FFmpeg's raw
//! demuxers, `-f s16le -sample_rate 44100 -ch_layout mono`) and written
//! unchanged (its raw muxers).
//!
//! Nothing in the bytes names the encoding, rate or layout, so a raw format
//! is never chosen from content: only `-f`, or FFmpeg's file-name extension
//! fallback, selects one (format/detect.zig). The parameters default to
//! FFmpeg's 44100 Hz mono.
//!
//! The data runs to the end of the input, or to a length the caller knows,
//! such as a regular file's size; either way it must be whole frames, or the
//! input is `Truncated`. With a known length the frame count is known before
//! the first sample, which the known-length writers need; otherwise it is
//! counted while reading. Neither the parser nor the writer allocates.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");
const pcm = @import("../codec/pcm.zig");
const skip = @import("../io/skip.zig");

/// Contract errors (see the raw fixture README), plus `IoFailure` for a
/// failing reader.
pub const Error = error{
    InvalidFormat,
    Truncated,
    LimitExceeded,
    IoFailure,
};

/// The stream parameters FFmpeg's raw demuxers take as options.
pub const Params = struct {
    /// `-sample_rate`.
    sample_rate: u32 = 44100,
    /// `-ch_layout`.
    layout: audio.ChannelLayout = .mono,
};

/// Configurable policy limits; exceeding one is `error.LimitExceeded`.
pub const Limits = struct {
    max_sample_rate: u32 = 192_000,
    /// libswresample's `SWR_CH_MAX`: more channels than FFmpeg converts.
    max_channels: u16 = max_channels,
};

/// The default channel limit of the parser.
pub const max_channels = 64;

pub const Info = struct {
    codec: pcm.Codec,
    /// The decoded stream: `sample_format` is `codec.storage()`.
    format: audio.Format,
    /// Sample frames, when the length is known before reading; else null.
    frame_count: ?u64,
};

/// Whether a raw format exists for `codec`: FFmpeg has none for s64.
pub fn carries(codec: pcm.Codec) bool {
    return switch (codec) {
        .s64le, .s64be => false,
        else => true,
    };
}

/// Bytes moved per read; a whole number of frames of every encoding.
const scratch_len = 4096;

/// Reads one raw stream from a borrowed reader.
///
/// Call `readHeader` once, which reads nothing, then `readData` (or, for
/// encodings stored as s16, `readSamples`) until it returns nothing (or not at
/// all), then `finish`, which skips any unread data. The stream is valid only
/// if `finish` succeeds; `frames_read` then counts its frames.
pub const Parser = struct {
    reader: *std.Io.Reader,
    codec: pcm.Codec,
    params: Params,
    limits: Limits,
    /// Bytes of one encoded frame; set by `readHeader`.
    frame_bytes: u32 = 0,
    /// Bytes not yet delivered; null when the data runs to the end of the input.
    data_left: ?u64,
    /// Frames delivered or skipped so far.
    frames_read: u64 = 0,
    state: State = .header,

    const State = enum { header, data, done };

    /// `length` is the input's size in bytes, when known.
    pub fn init(reader: *std.Io.Reader, codec: pcm.Codec, params: Params, length: ?u64, limits: Limits) Parser {
        std.debug.assert(carries(codec));
        return .{ .reader = reader, .codec = codec, .params = params, .limits = limits, .data_left = length };
    }

    /// Checks the parameters, then a known length; reads nothing.
    pub fn readHeader(p: *Parser) Error!Info {
        std.debug.assert(p.state == .header);
        const rate = p.params.sample_rate;
        if (rate == 0) return error.InvalidFormat;
        if (rate > p.limits.max_sample_rate) return error.LimitExceeded;
        // Checked before `Format.channelCount`, which needs a count in u16.
        const channels = p.params.layout.channelCount();
        if (channels == 0) return error.InvalidFormat;
        if (channels > p.limits.max_channels) return error.LimitExceeded;
        const format: audio.Format = .{ .sample_rate = rate, .layout = p.params.layout, .sample_format = p.codec.storage() };
        // At most 8 bytes times 65535 channels: no overflow.
        const sample_bytes: u32 = p.codec.bytesPerSample();
        p.frame_bytes = sample_bytes * format.channelCount();
        var frame_count: ?u64 = null;
        if (p.data_left) |length| {
            // The input would end inside its last frame.
            if (length % p.frame_bytes != 0) return error.Truncated;
            frame_count = length / p.frame_bytes;
        }
        p.state = .data;
        return .{ .codec = p.codec, .format = format, .frame_count = frame_count };
    }

    /// Decodes whole frames of interleaved samples into the start of `output`
    /// and returns the decoded prefix. Returns no samples once the data is
    /// exhausted, or when `output` cannot hold one frame. Only for encodings
    /// stored as s16; use `readData` and `pcm.decode` for the others.
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

    /// Reads whole frames, still encoded, into the start of `output` and
    /// returns that prefix. Returns no bytes once the data is exhausted, or
    /// when `output` cannot hold one frame.
    pub fn readData(p: *Parser, output: []u8) Error![]u8 {
        std.debug.assert(p.state == .data);
        const whole = output[0 .. output.len - output.len % p.frame_bytes];
        const len = if (p.data_left) |data_left| len: {
            const want = @min(std.math.cast(usize, data_left) orelse std.math.maxInt(usize), whole.len);
            p.reader.readSliceAll(whole[0..want]) catch |err| return mapRead(err);
            p.data_left = data_left - want;
            break :len want;
        } else len: {
            // The data runs to the end of the input: a short read ends it.
            const len = p.reader.readSliceShort(whole) catch |err| switch (err) {
                error.ReadFailed => return error.IoFailure,
            };
            if (len % p.frame_bytes != 0) return error.Truncated;
            break :len len;
        };
        p.frames_read += len / p.frame_bytes;
        return whole[0..len];
    }

    /// Skips any unread data, counting its frames. With a known length, input
    /// ending early is `Truncated` and bytes after it are never read;
    /// otherwise the input must end on a whole frame.
    pub fn finish(p: *Parser) Error!void {
        std.debug.assert(p.state == .data);
        if (p.data_left) |data_left| {
            skip.discardAll(p.reader, data_left) catch |err| return mapRead(err);
            p.frames_read += data_left / p.frame_bytes;
        } else {
            const step = 1 << 16;
            var partial: u64 = 0;
            while (true) {
                const skipped = p.reader.discardShort(step) catch |err| switch (err) {
                    error.ReadFailed => return error.IoFailure,
                };
                // Whole frames are counted as they pass; at most one partial
                // frame is carried, so nothing overflows.
                partial += skipped;
                p.frames_read += partial / p.frame_bytes;
                partial %= p.frame_bytes;
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

/// Validates a complete raw stream without decoding its samples. The frame
/// count is always known: counted when the length was not given.
pub fn probe(reader: *std.Io.Reader, codec: pcm.Codec, params: Params, length: ?u64, limits: Limits) Error!Info {
    var parser: Parser = .init(reader, codec, params, length, limits);
    var info = try parser.readHeader();
    try parser.finish();
    info.frame_count = parser.frames_read;
    return info;
}

pub const DecodeError = Error || std.Io.Writer.Error;

/// Decodes a raw stream and writes its samples to `out` as raw little-endian
/// samples of its storage format, using fixed working storage. The caller
/// flushes `out`. The frame count is counted when the length was not given.
/// A frame wider than that storage (4 KiB, possible only with a channel limit
/// above the default) is `LimitExceeded`.
pub fn decodeToRaw(reader: *std.Io.Reader, out: *std.Io.Writer, codec: pcm.Codec, params: Params, length: ?u64, limits: Limits) DecodeError!Info {
    var parser: Parser = .init(reader, codec, params, length, limits);
    var info = try parser.readHeader();
    // readData delivers nothing when a frame does not fit, which would end
    // the loop below early; only a channel limit above the default allows it.
    if (parser.frame_bytes > scratch_len) return error.LimitExceeded;
    var encoded: [scratch_len]u8 = undefined;
    // Storage is at most twice the encoded size (A-law and µ-law to s16).
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
    info.frame_count = parser.frames_read;
    return info;
}

/// The checks `Writer.check` and `Writer.begin` share.
pub const HeaderError = error{
    /// No raw format carries the codec, or the format's storage is not the codec's.
    UnsupportedFormat,
    /// A zero sample rate, or no channels.
    InvalidFormat,
    /// The sample rate is above `WriteOptions.max_sample_rate`.
    LimitExceeded,
};

pub const WriteError = std.Io.Writer.Error || HeaderError || error{
    /// The samples do not fill whole frames.
    IncompleteFrame,
    /// More frames than declared to `begin`.
    TooManyFrames,
    /// `finish` was called before all declared frames were written.
    TooFewFrames,
};

pub const WriteOptions = struct {
    max_sample_rate: u32 = 192_000,
};

/// Writes one raw stream to a borrowed writer: the encoded frames and
/// nothing else, as FFmpeg's raw muxers do. A frame count given to `begin`
/// is checked by `finish`; without one, any whole frames are accepted.
pub const Writer = struct {
    out: *std.Io.Writer,
    codec: pcm.Codec,
    format: audio.Format,
    frames_expected: ?u64,
    frames_written: u64 = 0,

    /// Checks the codec and the format; writes nothing.
    pub fn begin(out: *std.Io.Writer, codec: pcm.Codec, format: audio.Format, frame_count: ?u64, options: WriteOptions) HeaderError!Writer {
        try check(codec, format, options);
        return .{ .out = out, .codec = codec, .format = format, .frames_expected = frame_count };
    }

    pub fn check(codec: pcm.Codec, format: audio.Format, options: WriteOptions) HeaderError!void {
        if (!carries(codec) or format.sample_format != codec.storage()) return error.UnsupportedFormat;
        // avcodec_open2 refuses an encoder without channels; frame sizes divide by the count.
        if (format.sample_rate == 0 or format.channelCount() == 0) return error.InvalidFormat;
        if (format.sample_rate > options.max_sample_rate) return error.LimitExceeded;
    }

    /// Writes whole frames of samples stored as s16, encoded as the writer's
    /// codec (which must be stored as s16).
    pub fn writeFrames(w: *Writer, samples: []const i16) WriteError!void {
        std.debug.assert(w.codec.storage() == .s16);
        const channels = w.format.channelCount();
        if (samples.len % channels != 0) return error.IncompleteFrame;
        try w.reserve(samples.len / channels);
        var bytes: [scratch_len]u8 = undefined;
        var rest = samples;
        while (rest.len > 0) {
            // The frames were checked above, so a chunk need not end on a
            // frame. scratch_len / 2 samples encode into at most scratch_len
            // bytes.
            const take = @min(rest.len, scratch_len / 2);
            try w.out.writeAll(pcm.encodeFromS16(w.codec, rest[0..take], &bytes) catch unreachable);
            rest = rest[take..];
        }
        w.frames_written += samples.len / channels;
    }

    /// Writes whole frames already encoded as the writer's codec, unchanged.
    pub fn writeData(w: *Writer, bytes: []const u8) WriteError!void {
        const sample_bytes: usize = w.codec.bytesPerSample();
        const frame_bytes = sample_bytes * w.format.channelCount();
        if (bytes.len % frame_bytes != 0) return error.IncompleteFrame;
        const frames = bytes.len / frame_bytes;
        try w.reserve(frames);
        try w.out.writeAll(bytes);
        w.frames_written += frames;
    }

    fn reserve(w: *Writer, frames: u64) WriteError!void {
        const expected = w.frames_expected orelse return;
        if (frames > expected - w.frames_written) return error.TooManyFrames;
    }

    /// Verifies a declared frame count, then flushes `out`.
    pub fn finish(w: *Writer) WriteError!void {
        if (w.frames_expected) |expected| {
            if (w.frames_written != expected) return error.TooFewFrames;
        }
        try w.out.flush();
    }
};

const fixtures = @import("../testing/fixtures.zig");

/// The implementation's codec for a manifest codec; the names are FFmpeg's.
fn codecOf(comptime codec: fixtures.Codec) pcm.Codec {
    return comptime std.meta.stringToEnum(pcm.Codec, @tagName(codec)["pcm_".len..]).?;
}

/// A raw format's codec, named as it.
fn formatCodec(comptime format: fixtures.raw.Format) pcm.Codec {
    return @field(pcm.Codec, @tagName(format));
}

fn paramsOf(comptime given: ?fixtures.raw.Params) Params {
    const p = given orelse return .{};
    // The manifest's texts parse; checked at compile time.
    return .{ .sample_rate = p.sample_rate, .layout = comptime audio.ChannelLayout.parse(p.layout) catch unreachable };
}

/// The parser error each fixture failure names. The manifest's `Failure` stays
/// independent of the parser; this exhaustive switch is the only link.
fn expectedError(failure: fixtures.raw.Failure) Error {
    return switch (failure) {
        .InvalidFormat => error.InvalidFormat,
        .Truncated => error.Truncated,
        .LimitExceeded => error.LimitExceeded,
    };
}

fn expectInfo(comptime stream: fixtures.Stream, info: Info) !void {
    try std.testing.expectEqual(codecOf(stream.codec), info.codec);
    try std.testing.expectEqual(stream.channels, info.format.channelCount());
    try stream.expectLayout(info.format.layout);
    try std.testing.expectEqual(stream.sample_rate, info.format.sample_rate);
    try std.testing.expectEqual(codecOf(stream.codec).storage(), info.format.sample_format);
    try std.testing.expectEqual(stream.frameCount(), info.frame_count);
}

/// Decodes one fixture, with its length known or not, and checks the result.
fn expectFixture(comptime fixture: fixtures.raw.Fixture, reader: *std.Io.Reader, comptime known_length: bool) !void {
    var storage: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&storage);
    const bytes = fixtures.raw.bytes(fixture.name);
    const length: ?u64 = if (known_length) bytes.len else null;
    const result = decodeToRaw(reader, &out, formatCodec(fixture.format), paramsOf(fixture.params), length, .{});
    errdefer std.debug.print("fixture {s}, known length {}\n", .{ fixture.name, known_length });
    switch (fixture.expected) {
        .accept => |stream| {
            try expectInfo(stream, try result);
            var expected: [1024]u8 = undefined;
            try std.testing.expectEqualSlices(u8, stream.samples.littleEndian(&expected), out.buffered());
        },
        .reject => |failure| try std.testing.expectError(expectedError(failure), result),
    }
}

test "every raw fixture gives its contract result from memory, its length known or not" {
    inline for (fixtures.raw.all) |fixture| {
        inline for (.{ false, true }) |known_length| {
            var reader: std.Io.Reader = .fixed(fixtures.raw.bytes(fixture.name));
            try expectFixture(fixture, &reader, known_length);
        }
    }
}

test "every raw fixture gives the same result from one-byte reads" {
    inline for (fixtures.raw.all) |fixture| {
        inline for (.{ false, true }) |known_length| {
            var buffer: [1]u8 = undefined;
            var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = fixtures.raw.bytes(fixture.name) }});
            source.artificial_limit = .limited(1);
            try expectFixture(fixture, &source.interface, known_length);
        }
    }
}

test "probing counts the frames and agrees with decoding" {
    @setEvalBranchQuota(10_000);
    inline for (fixtures.raw.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.raw.bytes(fixture.name));
        const result = probe(&reader, formatCodec(fixture.format), paramsOf(fixture.params), null, .{});
        switch (fixture.expected) {
            .accept => |stream| try expectInfo(stream, try result),
            .reject => |failure| try std.testing.expectError(expectedError(failure), result),
        }
    }
}

test "the frame count is known from the header only with a known length" {
    const bytes = fixtures.raw.bytes("raw_s16le_mono_8k");
    var unknown: std.Io.Reader = .fixed(bytes);
    var parser: Parser = .init(&unknown, .s16le, .{ .sample_rate = 8000 }, null, .{});
    try std.testing.expectEqual(null, (try parser.readHeader()).frame_count);
    var known: std.Io.Reader = .fixed(bytes);
    var known_parser: Parser = .init(&known, .s16le, .{ .sample_rate = 8000 }, bytes.len, .{});
    try std.testing.expectEqual(8, (try known_parser.readHeader()).frame_count);
    // A known length the input does not fill is truncation.
    var short: std.Io.Reader = .fixed(bytes);
    try std.testing.expectError(error.Truncated, probe(&short, .s16le, .{}, bytes.len + 2, .{}));
    // Bytes after a known length are never read.
    var long: std.Io.Reader = .fixed(bytes);
    try std.testing.expectEqual(4, (try probe(&long, .s16le, .{}, 8, .{})).frame_count);
}

test "readSamples gives s16 samples for every encoding stored as s16" {
    var checked: usize = 0;
    inline for (fixtures.raw.all) |fixture| {
        if (fixture.expected == .accept and fixture.expected.accept.samples == .s16) {
            var reader: std.Io.Reader = .fixed(fixtures.raw.bytes(fixture.name));
            var parser: Parser = .init(&reader, formatCodec(fixture.format), paramsOf(fixture.params), null, .{});
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
    // s16le, s16be, A-law and µ-law among them.
    try std.testing.expect(checked > 4);
}

test "the rate limit is configurable" {
    var fast: std.Io.Reader = .fixed(fixtures.raw.bytes("raw_rate_over_limit"));
    const info = try probe(&fast, .s16le, .{ .sample_rate = 192_001 }, null, .{ .max_sample_rate = 192_001 });
    try std.testing.expectEqual(192_001, info.format.sample_rate);
}

test "a long raw stream is counted exactly without a length" {
    const synthetic = @import("../testing/synthetic.zig");
    var reader_buffer: [64]u8 = undefined;
    // Stereo s16: 4-byte frames; 5 GiB of them, then one partial frame.
    var whole: synthetic.ZeroStream = .init("", 5 << 30, "", &reader_buffer);
    try std.testing.expectEqual((5 << 30) / 4, (try probe(&whole.interface, .s16le, .{ .layout = .stereo }, null, .{})).frame_count);
    var partial: synthetic.ZeroStream = .init("", (5 << 30) + 2, "", &reader_buffer);
    try std.testing.expectError(error.Truncated, probe(&partial.interface, .s16le, .{ .layout = .stereo }, null, .{}));
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    var storage: [2048]u8 = undefined;
    // Every codec and both lengths: any contract error is acceptable; the
    // parser must not crash or overrun, and a known length agrees.
    inline for (@typeInfo(pcm.Codec).@"enum".field_names) |name| {
        const codec = @field(pcm.Codec, name);
        if (comptime carries(codec)) {
            var a: std.Io.Reader = .fixed(input[0..len]);
            var out_a: std.Io.Writer = .fixed(&storage);
            const unknown = decodeToRaw(&a, &out_a, codec, .{ .layout = .stereo }, null, .{});
            var b: std.Io.Reader = .fixed(input[0..len]);
            const known = probe(&b, codec, .{ .layout = .stereo }, len, .{});
            if (unknown) |info| {
                try std.testing.expectEqual(info.frame_count, (try known).frame_count);
            } else |err| try std.testing.expectError(err, known);
        }
    }
}

test "fuzz: arbitrary input never crashes the raw parser" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.raw.bytes("raw_s16le_mono_8k"),
        fixtures.raw.bytes("raw_s24le_stereo_48k"),
        fixtures.raw.bytes("raw_partial_frame"),
    } });
}

test "the writer reproduces every raw writer-output fixture, its frame count given or not" {
    var count: usize = 0;
    inline for (fixtures.raw.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            const codec = codecOf(stream.codec);
            const format = try audio.Format.initLayout(stream.sample_rate, stream.channelLayout(), codec.storage());
            const bytes = fixtures.raw.bytes(fixture.name);
            inline for (.{ null, stream.frameCount() }) |frame_count| {
                var buffer: [1024]u8 = undefined;
                var out: std.Io.Writer = .fixed(&buffer);
                var writer = try Writer.begin(&out, codec, format, frame_count, .{});
                const frame_bytes = codec.bytesPerSample() * stream.channels;
                var i: usize = 0;
                while (i < bytes.len) : (i += frame_bytes) try writer.writeData(bytes[i..][0..frame_bytes]);
                try writer.finish();
                try std.testing.expectEqualSlices(u8, bytes, out.buffered());
            }
            count += 1;
        }
    }
    // One per raw format, and the empty stream.
    try std.testing.expect(count >= 15);
}

test "writeFrames encodes s16 samples as the writer's codec" {
    inline for (.{ "raw_s16le_mono_8k", "raw_s16be_stereo_44k1", "raw_alaw_mono_8k", "raw_mulaw_mono_8k" }) |name| {
        const stream = comptime for (fixtures.raw.all) |f| {
            if (std.mem.eql(u8, f.name, name)) break f.expected.accept;
        } else unreachable;
        const codec = codecOf(stream.codec);
        const format = try audio.Format.initLayout(stream.sample_rate, stream.channelLayout(), .s16);
        var buffer: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        var writer = try Writer.begin(&out, codec, format, null, .{});
        try writer.writeFrames(stream.samples.s16);
        try writer.finish();
        try std.testing.expectEqualSlices(u8, fixtures.raw.bytes(name), out.buffered());
    }
}

test "the writer checks the codec, the format and a declared frame count" {
    const mono = try audio.Format.init(8000, 1, .s16);
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s64le, try audio.Format.init(8000, 1, .s64), null, .{}));
    try std.testing.expectError(error.UnsupportedFormat, Writer.begin(&out, .s24le, mono, null, .{}));
    try std.testing.expectError(error.LimitExceeded, Writer.begin(&out, .s16le, try audio.Format.init(192_001, 1, .s16), null, .{}));
    const zero_rate: audio.Format = .{ .sample_rate = 0, .layout = .mono, .sample_format = .s16 };
    try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, .s16le, zero_rate, null, .{}));
    // No channels: every frame size would divide by zero.
    for ([_]audio.ChannelLayout{ .{ .unspecified = 0 }, .{ .native = 0 } }) |none| {
        const no_channels: audio.Format = .{ .sample_rate = 8000, .layout = none, .sample_format = .s16 };
        try std.testing.expectError(error.InvalidFormat, Writer.begin(&out, .s16le, no_channels, null, .{}));
    }

    var writer = try Writer.begin(&out, .s16le, mono, 2, .{});
    try std.testing.expectError(error.IncompleteFrame, writer.writeData(&.{1}));
    try std.testing.expectError(error.TooManyFrames, writer.writeFrames(&.{ 1, 2, 3 }));
    try writer.writeFrames(&.{1});
    try std.testing.expectError(error.TooFewFrames, writer.finish());
    try writer.writeFrames(&.{2});
    try writer.finish();
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, out.buffered());
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .s16le, .{}, null, .{}));
    var known: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&known, .s16le, .{}, 4, .{}));
}
