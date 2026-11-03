// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Synchronous conversion and stream copy between WAV and AU (TODO.md T13a).
//!
//! The operation matrix (TODO.md T13):
//!
//! | Input → output     | `transcode`                  | `copy`                                   |
//! | ------------------ | ---------------------------- | ---------------------------------------- |
//! | WAV → WAV, AU → AU | yes                          | yes                                      |
//! | WAV → AU, AU → WAV | yes, through the PCM kernels | `UnsupportedOperation`: needs byte swaps |
//!
//! Rate and channel-layout changes cannot be requested yet (TODO.md T23/T24);
//! the output always has the input's format.
//!
//! `Conversion.init` reads the input up to its first sample and makes every
//! check that does not need the rest of it: the input header, the request
//! against the matrix, then the output header's limits and sizes (in that
//! order; the first failure wins). It writes nothing, so a rejected operation
//! leaves no output. `run` writes the output header, moves every frame,
//! validates the rest of the input (so an error after the data still fails the
//! operation) and finishes the output, which flushes. A failure found after
//! samples were written is still a failure; output is not atomic, and what to
//! do with a partial output is the caller's decision.
//!
//! The input is read as packets of whole frames (TODO.md T14a), timestamped in
//! frames since the start (`1/sample_rate`). Stream copy writes those packets'
//! bytes unchanged; transcoding sends them through `pcm.Decoder` and
//! `pcm.Encoder` (the core/stage.zig contract) and writes the encoded packets.
//! Neither keeps container metadata: the output has the writer's canonical
//! header, so WAV chunks other than `fmt ` and `data`, and AU annotations, are
//! dropped.
//!
//! Nothing is allocated. Working memory is fixed, whatever the input length:
//! a 4 KiB packet buffer, for transcoding 4 KiB each of decoded samples and
//! encoded bytes, plus the parsers' and writers' own 4 KiB scratch.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const Packet = @import("../core/packet.zig").Packet;
const wav = @import("wav.zig");
const au = @import("au.zig");
const detect = @import("detect.zig");

pub const Container = detect.Container;

/// Parser limits for the input and writer limits for the output, per container.
pub const Limits = detect.Limits;

pub const Mode = enum {
    /// Decode the samples and encode them for the output container.
    transcode,
    /// Copy the encoded samples unchanged; both containers must carry the
    /// same codec.
    copy,
};

pub const Request = struct {
    output: Container,
    mode: Mode,
};

/// Failures before any output exists: the input header, the request and the
/// output header. `LimitExceeded` can come from the input's or the output's
/// limits.
pub const InitError = detect.Error || wav.HeaderError || au.HeaderError || error{
    /// The request is outside the operation matrix: stream copy into a
    /// container that cannot carry the codec, or transcoding samples not
    /// stored as s16 (sample-format conversion waits for TODO.md T23a).
    UnsupportedOperation,
};

/// Failures once output has started: the rest of the input, or the output.
pub const RunError = detect.Error || std.Io.Writer.Error;

pub const Error = InitError || RunError;

pub const Summary = struct {
    input: Container,
    output: Container,
    mode: Mode,
    input_codec: pcm.Codec,
    /// The input codec when copying; when transcoding, the output
    /// container's s16 codec.
    output_codec: pcm.Codec,
    /// The input's and the output's format; neither rate nor layout changes.
    format: audio.Format,
    /// Sample frames in the input and the output. The duration is this many
    /// units of `format.timeBase()`, exactly, in both.
    frame_count: u64,
};

/// Bytes moved per transfer step. It holds at least one frame of every
/// encoding, so an empty read always means the end of the data (the parsers
/// read whole frames and return nothing only when none fits or none is left).
const transfer_len = 4096;

comptime {
    const largest_frame: usize = 2 * 8; // stereo s64 or f64
    std.debug.assert(transfer_len >= largest_frame);
}

/// One conversion from a borrowed reader to a borrowed writer. Create it with
/// `init`, then call `run` once. It holds the reader pointer but nothing
/// points into it, so it may be moved between the two calls.
pub const Conversion = struct {
    input: Input,
    limits: Limits,
    summary: Summary,
    /// Frames read so far: the next packet's timestamp.
    next_pts: i64 = 0,

    const Input = union(Container) {
        wav: wav.Parser,
        au: au.Parser,
    };

    /// Detects the input container, reads its header and checks the request
    /// and the output header. Reads at most up to the first sample and writes
    /// nothing.
    pub fn init(reader: *std.Io.Reader, request: Request, limits: Limits) InitError!Conversion {
        const detected = try detect.detect(reader);
        var input: Input = switch (detected.container) {
            .wav => .{ .wav = .initPrefixed(reader, limits.wav, detected.prefix) },
            .au => .{ .au = .initPrefixed(reader, limits.au, detected.prefix) },
        };
        const summary: Summary = switch (input) {
            inline else => |*parser, container| blk: {
                const info = try parser.readHeader();
                break :blk .{
                    .input = container,
                    .output = request.output,
                    .mode = request.mode,
                    .input_codec = info.codec,
                    .output_codec = switch (request.mode) {
                        .copy => info.codec,
                        .transcode => request.output.s16Codec(),
                    },
                    .format = info.format,
                    .frame_count = info.frame_count,
                };
            },
        };
        const supported = switch (request.mode) {
            .copy => request.output.carries(summary.input_codec),
            .transcode => summary.input_codec.storage() == .s16,
        };
        if (!supported) return error.UnsupportedOperation;
        switch (request.output) {
            .wav => try wav.Writer.check(summary.output_codec, summary.format, summary.frame_count, wavOptions(limits)),
            .au => try au.Writer.check(summary.format, summary.frame_count, limits.au),
        }
        return .{ .input = input, .limits = limits, .summary = summary };
    }

    /// Writes the output header, moves every frame, validates the rest of the
    /// input and finishes the output, which flushes `out`. On failure `out`
    /// may hold a partial stream.
    pub fn run(c: *Conversion, out: *std.Io.Writer) RunError!void {
        const s = c.summary;
        switch (s.output) {
            .wav => {
                var writer = wav.Writer.begin(out, s.output_codec, s.format, s.frame_count, wavOptions(c.limits)) catch |err| return outputFailure(err);
                try c.transfer(wav.Writer, &writer);
            },
            .au => {
                var writer = au.Writer.begin(out, s.format, s.frame_count, c.limits.au) catch |err| return outputFailure(err);
                try c.transfer(au.Writer, &writer);
            },
        }
    }

    fn transfer(c: *Conversion, comptime W: type, writer: *W) RunError!void {
        var packet_bytes: [transfer_len]u8 = undefined;
        switch (c.summary.mode) {
            .copy => while (try c.readPacket(&packet_bytes)) |packet| {
                writer.writeData(packet.data) catch |err| return outputFailure(err);
            },
            .transcode => {
                const s = c.summary;
                // A packet of 1-byte samples (A-law, mu-law) is transfer_len
                // samples, which encode as s16 into twice the bytes.
                var samples: [transfer_len]i16 = undefined;
                var encoded: [2 * transfer_len]u8 = undefined;
                var stages: Transcoder(W) = .{
                    .decoder = .init(s.input_codec, s.format, &samples),
                    .encoder = .init(s.output_codec, s.format, &encoded),
                    .writer = writer,
                };
                while (try c.readPacket(&packet_bytes)) |packet| try stages.push(packet);
                try stages.push(null);
            },
        }
        // The input first: an error after its data fails the operation
        // without flushing the output.
        try c.finishInput();
        writer.finish() catch |err| return outputFailure(err);
    }

    /// The next packet of whole frames, or `null` at the end of the data. Its
    /// bytes are in `storage`, which holds at least one frame, and stay valid
    /// until the next call.
    fn readPacket(c: *Conversion, storage: []u8) detect.Error!?Packet {
        const data = try c.readData(storage);
        if (data.len == 0) return null;
        const format = c.summary.format;
        const sample_bytes: usize = c.summary.input_codec.bytesPerSample();
        // At most `storage.len` bytes, so the frame count fits in i64.
        const frames: i64 = @intCast(data.len / (sample_bytes * format.channelCount()));
        const pts = c.next_pts;
        c.next_pts += frames;
        return .{
            .data = data,
            .time_base = format.timeBase(),
            .pts = pts,
            .dts = pts,
            .duration = frames,
            .flags = .{ .key = true },
        };
    }

    fn readData(c: *Conversion, output: []u8) detect.Error![]u8 {
        return switch (c.input) {
            inline else => |*parser| parser.readData(output),
        };
    }

    fn finishInput(c: *Conversion) detect.Error!void {
        return switch (c.input) {
            inline else => |*parser| parser.finish(),
        };
    }
};

/// The transcoding stages between the packet reader and the writer `W`.
///
/// `push` empties both stages before it returns, so each holds at most one
/// item and `send` never returns `.full`. Their sends cannot fail either:
/// packets hold whole frames of the input codec, at most `transfer_len`
/// bytes, which both storages hold even for 1-byte codecs; their timestamps are
/// already in the format's time base, so rescaling is exact; and input ends
/// only once, with `push(null)`.
fn Transcoder(comptime W: type) type {
    return struct {
        decoder: pcm.Decoder,
        encoder: pcm.Encoder,
        writer: *W,

        const Self = @This();

        /// Sends `packet` through both stages and writes what comes out;
        /// `null` drains them.
        fn push(t: *Self, packet: ?Packet) std.Io.Writer.Error!void {
            if (packet) |p| {
                const sent = t.decoder.send(p) catch unreachable;
                std.debug.assert(sent == .accepted);
            } else {
                t.decoder.finishInput();
            }
            while (true) switch (t.decoder.receive()) {
                .output => |frame| {
                    const sent = t.encoder.send(frame) catch unreachable;
                    std.debug.assert(sent == .accepted);
                    try t.writeEncoded();
                },
                .need_input => return,
                .drained => {
                    t.encoder.finishInput();
                    try t.writeEncoded();
                    std.debug.assert(t.encoder.receive() == .drained);
                    return;
                },
            };
        }

        fn writeEncoded(t: *Self) std.Io.Writer.Error!void {
            while (true) switch (t.encoder.receive()) {
                .output => |p| t.writer.writeData(p.data) catch |err| return outputFailure(err),
                .need_input, .drained => return,
            };
        }
    };
}

/// The WAV writer's options from the conversion's limits: the same rate
/// limit, and RF64 exactly when 32-bit sizes cannot hold the output.
fn wavOptions(limits: Limits) wav.WriteOptions {
    return .{ .max_sample_rate = limits.wav.max_sample_rate };
}

/// The writer's own failure. `init` already ran the header checks `begin`
/// repeats, with the same arguments; the parser delivers whole frames of the
/// same format, exactly the declared count, before `finish`. So only the
/// output's I/O failure remains.
fn outputFailure(err: wav.WriteError) std.Io.Writer.Error {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.UnsupportedFormat,
        error.InvalidFormat,
        error.LimitExceeded,
        error.SizeOverflow,
        error.IncompleteFrame,
        error.TooManyFrames,
        error.TooFewFrames,
        => unreachable,
    };
}

/// Converts one stream: `Conversion.init`, then `run`.
pub fn convert(reader: *std.Io.Reader, out: *std.Io.Writer, request: Request, limits: Limits) Error!Summary {
    var conversion: Conversion = try .init(reader, request, limits);
    try conversion.run(out);
    return conversion.summary;
}

const fixtures = @import("../testing/fixtures.zig");

const all_cells = [_]Request{
    .{ .output = .wav, .mode = .transcode },
    .{ .output = .wav, .mode = .copy },
    .{ .output = .au, .mode = .transcode },
    .{ .output = .au, .mode = .copy },
};

const Decoded = struct {
    format: audio.Format,
    frame_count: u64,
    samples: []const i16,
};

/// Decodes a converted stream with the output container's own parser, not
/// through this file.
fn decodeOutput(container: Container, bytes: []const u8, storage: []i16) !Decoded {
    var reader: std.Io.Reader = .fixed(bytes);
    switch (container) {
        .wav => {
            var parser: wav.Parser = .init(&reader, .{});
            return decodeWith(wav.Parser, &parser, storage);
        },
        .au => {
            var parser: au.Parser = .init(&reader, .{});
            return decodeWith(au.Parser, &parser, storage);
        },
    }
}

fn decodeWith(comptime P: type, parser: *P, storage: []i16) !Decoded {
    const info = try parser.readHeader();
    var len: usize = 0;
    while (true) {
        const decoded = try parser.readSamples(storage[len..]);
        if (decoded.len == 0) break;
        len += decoded.len;
    }
    // Storage that filled up would hide undelivered samples.
    if (len != info.frame_count * info.format.channelCount()) return error.TestUnexpectedResult;
    try parser.finish();
    return .{ .format = info.format, .frame_count = info.frame_count, .samples = storage[0..len] };
}

fn canonicalHeaderLen(container: Container) usize {
    return switch (container) {
        .wav => wav.canonical_header_len,
        .au => au.canonical_header_len,
    };
}

/// The bytes before the samples in an output the writers produce.
fn headerLenOf(container: Container, codec: pcm.Codec, format: audio.Format) usize {
    return switch (container) {
        .wav => wav.headerLen(codec, format, false), // small test outputs: plain RIFF
        .au => au.canonical_header_len,
    };
}

/// A stream's decoded samples, little-endian in their storage format, read by
/// the container's own parser.
fn rawOf(container: Container, bytes: []const u8, out: []u8) ![]const u8 {
    var reader: std.Io.Reader = .fixed(bytes);
    var writer: std.Io.Writer = .fixed(out);
    switch (container) {
        .wav => _ = try wav.decodeToRaw(&reader, &writer, .{}),
        .au => _ = try au.decodeToRaw(&reader, &writer, .{}),
    }
    return writer.buffered();
}

/// Runs every matrix cell on one accepted fixture. Neither container carries
/// the other's codecs, so copy works only into the input's container, and
/// transcoding only from samples stored as s16 (other storage needs T23a).
fn expectEveryCell(input: Container, bytes: []const u8, comptime stream: fixtures.Stream, writer_output: bool) !void {
    var expected_buffer: [1024]u8 = undefined;
    const expected = stream.samples.littleEndian(&expected_buffer);
    for (all_cells) |request| {
        var reader: std.Io.Reader = .fixed(bytes);
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        const result = convert(&reader, &out, request, .{});
        const supported = switch (request.mode) {
            .copy => request.output == input,
            .transcode => stream.samples == .s16,
        };
        if (!supported) {
            try std.testing.expectError(error.UnsupportedOperation, result);
            try std.testing.expectEqual(0, out.buffered().len);
            continue;
        }
        const summary = try result;
        const frame_count = stream.frameCount();
        try std.testing.expectEqual(input, summary.input);
        try std.testing.expectEqual(request.output, summary.output);
        try std.testing.expectEqualStrings(@tagName(stream.codec), summary.input_codec.name());
        try std.testing.expectEqual(stream.sample_rate, summary.format.sample_rate);
        try std.testing.expectEqual(stream.channels, summary.format.channelCount());
        try std.testing.expectEqual(frame_count, summary.frame_count);

        // The output holds the writer's header and exactly the samples, at
        // the same rate and frame count, so the duration is unchanged.
        const written = out.buffered();
        const data_len = frame_count * stream.channels * summary.output_codec.bytesPerSample();
        const header_len = headerLenOf(request.output, summary.output_codec, summary.format);
        try std.testing.expectEqual(header_len + data_len + data_len % 2, written.len);
        var raw_buffer: [1024]u8 = undefined;
        try std.testing.expectEqualSlices(u8, expected, try rawOf(request.output, written, &raw_buffer));
        // A canonical input converts to itself, byte for byte.
        if (writer_output and request.output == input and summary.output_codec == summary.input_codec) {
            try std.testing.expectEqualSlices(u8, bytes, written);
        }
    }
}

test "every accepted fixture gives its samples in every supported cell, and copy across codecs is rejected" {
    inline for (fixtures.all) |fixture| {
        if (fixture.expected == .accept) {
            // The converter writes RF64 only when needed, so an RF64 writer
            // output converts to plain RIFF.
            try expectEveryCell(.wav, fixtures.bytes(fixture.name), fixture.expected.accept, fixture.writer_output and !fixture.writer_rf64);
        }
    }
    inline for (fixtures.au.all) |fixture| {
        if (fixture.expected == .accept) {
            try expectEveryCell(.au, fixtures.au.bytes(fixture.name), fixture.expected.accept, fixture.writer_output);
        }
    }
}

test "the input is read as contiguous, timestamped packets of whole frames" {
    const gpa = std.testing.allocator;
    const stereo = try audio.Format.init(48000, 2, .s16);
    const frame_count = 5000; // Not a multiple of the 1024-frame packets.
    const bytes = try gpa.alloc(u8, wav.canonical_header_len + frame_count * 4);
    defer gpa.free(bytes);
    var out: std.Io.Writer = .fixed(bytes);
    var writer = try wav.Writer.begin(&out, .s16le, stereo, frame_count, .{});
    const zeros: [frame_count * 2]i16 = @splat(0);
    try writer.writeFrames(&zeros);
    try writer.finish();

    var reader: std.Io.Reader = .fixed(bytes);
    var conversion: Conversion = try .init(&reader, .{ .output = .au, .mode = .transcode }, .{});
    var storage: [transfer_len]u8 = undefined;
    var expected_pts: i64 = 0;
    while (try conversion.readPacket(&storage)) |packet| {
        try std.testing.expectEqual(expected_pts, packet.pts);
        try std.testing.expectEqual(expected_pts, packet.dts);
        try std.testing.expectEqual(stereo.timeBase(), packet.time_base);
        try std.testing.expect(packet.flags.key);
        const frames: i64 = @intCast(@divExact(packet.data.len, 4));
        try std.testing.expectEqual(frames, packet.duration.?);
        expected_pts += packet.duration.?;
    }
    try std.testing.expectEqual(frame_count, expected_pts);
}

test "copy keeps the encoded data and timing but not the container's metadata" {
    // unknown_chunks carries chunks besides `fmt ` and `data`;
    // au_annotation_text has a 16-byte annotation.
    const cases = [_]struct { container: Container, bytes: []const u8 }{
        .{ .container = .wav, .bytes = fixtures.bytes("unknown_chunks") },
        .{ .container = .au, .bytes = fixtures.au.bytes("au_annotation_text") },
    };
    for (cases) |case| {
        var copy_reader: std.Io.Reader = .fixed(case.bytes);
        var copy_buffer: [1024]u8 = undefined;
        var copy_out: std.Io.Writer = .fixed(&copy_buffer);
        const copied = try convert(&copy_reader, &copy_out, .{ .output = case.container, .mode = .copy }, .{});

        var storage: [256]i16 = undefined;
        const input = try decodeOutput(case.container, case.bytes, &storage);

        // Same samples, rate and frame count ...
        var copy_storage: [256]i16 = undefined;
        const output = try decodeOutput(case.container, copy_out.buffered(), &copy_storage);
        try std.testing.expectEqual(input.format, output.format);
        try std.testing.expectEqual(input.frame_count, output.frame_count);
        try std.testing.expectEqual(input.frame_count, copied.frame_count);
        try std.testing.expectEqualSlices(i16, input.samples, output.samples);
        // ... under the canonical header: the input's other bytes are gone.
        const data_len = 2 * input.samples.len;
        try std.testing.expectEqual(canonicalHeaderLen(case.container) + data_len, copy_out.buffered().len);
        try std.testing.expect(case.bytes.len > copy_out.buffered().len);
    }
}

/// Converting a rejected stream into its own container, in both modes, fails
/// with the error probing reports. The fixture contracts already pin that
/// error, and for an input without the AU magic it is the WAV parser's.
fn expectProbeError(bytes: []const u8, output: Container) !void {
    var probe_reader: std.Io.Reader = .fixed(bytes);
    const want = if (detect.probe(&probe_reader, .{})) |_| return error.TestExpectedError else |e| e;
    for ([_]Mode{ .transcode, .copy }) |mode| {
        var reader: std.Io.Reader = .fixed(bytes);
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectError(want, convert(&reader, &out, .{ .output = output, .mode = mode }, .{}));
    }
}

test "every rejected fixture fails with the error probing reports" {
    inline for (fixtures.all) |fixture| {
        if (fixture.expected == .reject) {
            expectProbeError(fixtures.bytes(fixture.name), .wav) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
    inline for (fixtures.au.all) |fixture| {
        if (fixture.expected == .reject) {
            expectProbeError(fixtures.au.bytes(fixture.name), .au) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
}

test "an error found after samples were written fails the conversion" {
    // duplicate_data's error follows its data; au_truncated_data ends inside it.
    var late: std.Io.Reader = .fixed(fixtures.bytes("duplicate_data"));
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.InvalidWave, convert(&late, &out, .{ .output = .au, .mode = .transcode }, .{}));
    // The header and both samples were already written.
    try std.testing.expectEqual(au.canonical_header_len + 4, out.buffered().len);

    // The output had started. A transfer read the input cannot fill delivers
    // nothing, so how many samples precede the failure depends on where the
    // 4 KiB transfer boundaries fall; the failure itself does not.
    var truncated: std.Io.Reader = .fixed(fixtures.au.bytes("au_truncated_data"));
    var copy_out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.Truncated, convert(&truncated, &copy_out, .{ .output = .au, .mode = .copy }, .{}));
    try std.testing.expectEqual(au.canonical_header_len, copy_out.buffered().len);
}

test "an output the writer cannot represent is rejected before any output" {
    // A mono WAV header declaring 2 GiB of data, without the data: the AU
    // writer's data-size bound rejects it once the header is read.
    var header = fixtures.bytes("mono_8k")[0..wav.canonical_header_len].*;
    const data_bytes: u32 = 1 << 31;
    std.mem.writeInt(u32, header[4..8], data_bytes + wav.canonical_header_len - 8, .little);
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var huge: std.Io.Reader = .fixed(&header);
    try std.testing.expectError(error.SizeOverflow, convert(&huge, &out, .{ .output = .au, .mode = .transcode }, .{}));
    // The same stream fits in WAV: init succeeds, and only the missing data fails.
    var huge_again: std.Io.Reader = .fixed(&header);
    _ = try Conversion.init(&huge_again, .{ .output = .wav, .mode = .copy }, .{});

    // The output's own rate limit is checked too.
    var mono: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.LimitExceeded, convert(&mono, &out, .{ .output = .au, .mode = .transcode }, .{
        .au = .{ .max_sample_rate = 7999 },
    }));
    try std.testing.expectEqual(0, out.buffered().len);
}

test "input and output failures are reported" {
    var failing: std.Io.Reader = .failing;
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.IoFailure, convert(&failing, &out, .{ .output = .wav, .mode = .transcode }, .{}));

    // The header does not fit in 10 bytes.
    var small: [10]u8 = undefined;
    var short: std.Io.Writer = .fixed(&small);
    var mono: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.WriteFailed, convert(&mono, &short, .{ .output = .wav, .mode = .copy }, .{}));

    // Everything fits in the buffer, so the failure surfaces at the final flush.
    var big: [256]u8 = undefined;
    var failing_flush: std.Io.Writer = .{ .vtable = &.{ .drain = std.Io.Writer.failingDrain }, .buffer = &big };
    var stereo: std.Io.Reader = .fixed(fixtures.bytes("stereo_44k1"));
    try std.testing.expectError(error.WriteFailed, convert(&stereo, &failing_flush, .{ .output = .au, .mode = .transcode }, .{}));
}

test "file adapters with empty, tiny and larger buffers give the memory result" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    const inputs = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "in.wav", .bytes = fixtures.bytes("stereo_44k1") },
        .{ .name = "in.au", .bytes = fixtures.au.bytes("au_annotation_text") },
    };
    for (inputs) |input| {
        try tmp.dir.writeFile(io, .{ .sub_path = input.name, .data = input.bytes });
        for ([_]Request{ .{ .output = .wav, .mode = .transcode }, .{ .output = .au, .mode = .transcode } }) |request| {
            var memory: std.Io.Reader = .fixed(input.bytes);
            var expected_buffer: [1024]u8 = undefined;
            var expected: std.Io.Writer = .fixed(&expected_buffer);
            _ = try convert(&memory, &expected, request, .{});

            for ([_]usize{ 0, 1, 64 }) |capacity| {
                {
                    const in_file = try tmp.dir.openFile(io, input.name, .{});
                    defer in_file.close(io);
                    const out_file = try tmp.dir.createFile(io, "out", .{});
                    defer out_file.close(io);
                    var reader = in_file.readerStreaming(io, read_buffer[0..capacity]);
                    var writer = out_file.writerStreaming(io, write_buffer[0..capacity]);
                    _ = try convert(&reader.interface, &writer.interface, request, .{});
                }
                var content: [1024]u8 = undefined;
                const written = try tmp.dir.readFile(io, "out", &content);
                try std.testing.expectEqualSlices(u8, expected.buffered(), written);
            }
        }
    }
}

fn patternSample(index: u64) i16 {
    const bits: u16 = @truncate(index *% 7919);
    return @bitCast(bits);
}

test "a long stream converts with fixed memory and exact frame counts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stereo = try audio.Format.init(48000, 2, .s16);
    const frame_count = 1 << 20; // 4 MiB of samples
    var buffer: [64 * 1024]u8 = undefined;

    {
        const file = try tmp.dir.createFile(io, "long.wav", .{});
        defer file.close(io);
        var file_writer = file.writerStreaming(io, &buffer);
        var writer = try wav.Writer.begin(&file_writer.interface, .s16le, stereo, frame_count, .{});
        var chunk: [4096]i16 = undefined;
        var next: u64 = 0;
        while (next < frame_count * 2) : (next += chunk.len) {
            for (&chunk, 0..) |*sample, i| sample.* = patternSample(next + i);
            try writer.writeFrames(&chunk);
        }
        try writer.finish();
    }

    var out_buffer: [64 * 1024]u8 = undefined;
    for ([_]struct { request: Request, path: []const u8 }{
        .{ .request = .{ .output = .au, .mode = .transcode }, .path = "long.au" },
        .{ .request = .{ .output = .wav, .mode = .copy }, .path = "copy.wav" },
    }) |case| {
        const in_file = try tmp.dir.openFile(io, "long.wav", .{});
        defer in_file.close(io);
        const out_file = try tmp.dir.createFile(io, case.path, .{});
        defer out_file.close(io);
        var reader = in_file.readerStreaming(io, &buffer);
        var writer = out_file.writerStreaming(io, &out_buffer);
        const summary = try convert(&reader.interface, &writer.interface, case.request, .{});
        try std.testing.expectEqual(frame_count, summary.frame_count);
    }

    // The AU output has every sample, in order, and the same frame count and rate.
    {
        const file = try tmp.dir.openFile(io, "long.au", .{});
        defer file.close(io);
        var reader = file.readerStreaming(io, &buffer);
        var parser: au.Parser = .init(&reader.interface, .{});
        const info = try parser.readHeader();
        try std.testing.expectEqual(frame_count, info.frame_count);
        try std.testing.expectEqual(stereo, info.format);
        var samples: [1000]i16 = undefined;
        var seen: u64 = 0;
        while (true) {
            const decoded = try parser.readSamples(&samples);
            if (decoded.len == 0) break;
            for (decoded, 0..) |sample, i| {
                if (sample != patternSample(seen + i)) return error.TestUnexpectedResult;
            }
            seen += decoded.len;
        }
        try parser.finish();
        try std.testing.expectEqual(frame_count * 2, seen);
    }

    // The input already has the canonical header, so its copy is identical.
    const input_stat = try tmp.dir.statFile(io, "long.wav", .{});
    const copy_stat = try tmp.dir.statFile(io, "copy.wav", .{});
    try std.testing.expectEqual(input_stat.size, copy_stat.size);
    const original = try tmp.dir.openFile(io, "long.wav", .{});
    defer original.close(io);
    const copy = try tmp.dir.openFile(io, "copy.wav", .{});
    defer copy.close(io);
    var original_reader = original.readerStreaming(io, &buffer);
    var copy_reader = copy.readerStreaming(io, &out_buffer);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    var left = input_stat.size;
    while (left > 0) {
        const n: usize = @intCast(@min(left, a.len));
        try original_reader.interface.readSliceAll(a[0..n]);
        try copy_reader.interface.readSliceAll(b[0..n]);
        try std.testing.expectEqualSlices(u8, a[0..n], b[0..n]);
        left -= n;
    }
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    const bytes = input[0..len];
    var probe_reader: std.Io.Reader = .fixed(bytes);
    const probed = detect.probe(&probe_reader, .{});
    for (all_cells) |request| {
        var reader: std.Io.Reader = .fixed(bytes);
        // 1 KiB of input holds at most 1 KiB of data; transcoding 1-byte
        // samples doubles it, under a header of at most 80 bytes.
        var buffer: [4096]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        const result = convert(&reader, &out, request, .{});
        // A stream the probe accepts converts in every supported cell, with
        // the same format and frame count; one it rejects never converts.
        if (probed) |info| {
            const supported = switch (request.mode) {
                .copy => request.output == info.container,
                .transcode => info.format.sample_format == .s16,
            };
            if (!supported) {
                try std.testing.expectError(error.UnsupportedOperation, result);
            } else {
                const summary = try result;
                try std.testing.expectEqual(info.format, summary.format);
                try std.testing.expectEqual(info.frame_count, summary.frame_count);
            }
        } else |_| {
            if (result) |_| return error.TestExpectedError else |_| {}
        }
    }
}

test "fuzz: conversion agrees with probing on arbitrary input" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.bytes("mono_8k"),
        fixtures.bytes("unknown_chunks"),
        fixtures.au.bytes("au_stereo_44k1"),
        fixtures.au.bytes("au_truncated_data"),
        fixtures.bytes("s24_stereo_48k_extensible"),
        fixtures.bytes("alaw_mono_8k"),
    } });
}
