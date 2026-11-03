// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! File and stream adapters for the WAV and AU paths.
//!
//! Borrowed-handle functions (`probeFile`, `decodeFile`, `writeFile`) take an
//! open `std.Io.File` and never close it. Path helpers (`probePath`,
//! `writePath`) open, use and close their own handle, also on failure.
//!
//! Readers use `readerStreaming`, so pipes and other non-seekable files work;
//! the parser never seeks. Each call builds one adapter over the caller's
//! `buffer` and keeps it for the whole stream, so read-ahead is never lost.
//! Memory use is that buffer plus the parser's fixed 4 KiB of working storage:
//! nothing is allocated, whatever the file size. Any buffer size works;
//! `default_buffer_len` is the recommended size. To stream a long recording
//! out, build a `wav.Writer` over `file.writerStreaming(...).interface`.
//!
//! When the generic reader or writer reports a failure, the adapter's detailed
//! error (its `.err`, which includes `error.Canceled`) replaces `IoFailure` or
//! `WriteFailed`.
//!
//! `probeFile` and `probePath` detect the container (format/detect.zig); the
//! decode and write helpers are WAV-only. To write AU, build an `au.Writer` over
//! `file.writerStreaming(...).interface`.

const std = @import("std");
const audio = @import("../core/audio.zig");
const wav = @import("../format/wav.zig");
const detect = @import("../format/detect.zig");

/// Recommended scratch buffer size for the file adapters.
pub const default_buffer_len = 64 * 1024;

pub const ReadError = detect.Error || std.Io.File.Reader.Error;
pub const DecodeError = wav.DecodeError || std.Io.File.Reader.Error;
pub const WriteError = wav.WriteError || std.Io.File.Writer.Error;

/// Detects the container (WAV or AU) of the stream in a borrowed file and
/// validates the stream without decoding samples.
pub fn probeFile(io: std.Io, file: std.Io.File, buffer: []u8, limits: detect.Limits) ReadError!detect.Probed {
    var reader = file.readerStreaming(io, buffer);
    return detect.probe(&reader.interface, limits) catch |err| return withReadCause(err, &reader);
}

/// Opens `sub_path` in `dir`, detects and validates its stream and closes it.
pub fn probePath(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffer: []u8,
    limits: detect.Limits,
) (ReadError || std.Io.File.OpenError)!detect.Probed {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    return probeFile(io, file, buffer, limits);
}

/// Decodes the WAV stream in a borrowed file and writes its samples to `out`
/// as raw little-endian samples of its storage format (`wav.decodeToRaw`).
/// The caller flushes `out`.
pub fn decodeFile(
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    out: *std.Io.Writer,
    limits: wav.Limits,
) DecodeError!wav.Info {
    var reader = file.readerStreaming(io, buffer);
    return wav.decodeToRaw(&reader.interface, out, limits) catch |err| return withReadCause(err, &reader);
}

/// Writes interleaved s16 `samples` as one `pcm_s16le` WAV stream to a
/// borrowed file and flushes before returning. For other encodings, build a
/// `wav.Writer` over `file.writerStreaming(...).interface`.
pub fn writeFile(
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    format: audio.Format,
    samples: []const i16,
    options: wav.WriteOptions,
) WriteError!void {
    var file_writer = file.writerStreaming(io, buffer);
    writeStream(&file_writer.interface, format, samples, options) catch |err| {
        return withWriteCause(err, &file_writer);
    };
}

/// Creates or truncates `sub_path` in `dir`, writes the WAV stream and closes it.
pub fn writePath(
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    buffer: []u8,
    format: audio.Format,
    samples: []const i16,
    options: wav.WriteOptions,
) (WriteError || std.Io.File.OpenError)!void {
    const file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);
    return writeFile(io, file, buffer, format, samples, options);
}

fn writeStream(out: *std.Io.Writer, format: audio.Format, samples: []const i16, options: wav.WriteOptions) wav.WriteError!void {
    const channels = format.channelCount();
    if (samples.len % channels != 0) return error.IncompleteFrame;
    var writer = try wav.Writer.begin(out, .s16le, format, samples.len / channels, options);
    try writer.writeFrames(samples);
    try writer.finish();
}

fn withReadCause(err: anytype, reader: *const std.Io.File.Reader) (@TypeOf(err) || std.Io.File.Reader.Error) {
    if (err == error.IoFailure) {
        if (reader.err) |cause| return cause;
    }
    return err;
}

fn withWriteCause(err: anytype, file_writer: *const std.Io.File.Writer) (@TypeOf(err) || std.Io.File.Writer.Error) {
    if (err == error.WriteFailed) {
        if (file_writer.err) |cause| return cause;
    }
    return err;
}

const builtin = @import("builtin");
const fixtures = @import("../testing/fixtures.zig");
const au = @import("../format/au.zig");

fn writeFixture(io: std.Io, dir: std.Io.Dir, comptime name: []const u8) !void {
    try writeBytes(io, dir, name ++ ".wav", fixtures.bytes(name));
}

fn writeBytes(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

test "files agree with memory for every fixture and buffer size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [default_buffer_len]u8 = undefined;

    inline for (fixtures.all) |fixture| {
        try writeFixture(io, tmp.dir, fixture.name);
        var memory: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
        const expected = wav.probe(&memory, .{});

        for ([_]usize{ 0, 1, 64, default_buffer_len }) |capacity| {
            const result = probePath(io, tmp.dir, fixture.name ++ ".wav", buffer[0..capacity], .{});
            if (expected) |info| {
                const got = try result;
                try std.testing.expectEqual(info.frame_count, got.frame_count);
                try std.testing.expectEqual(info.format.sample_rate, got.format.sample_rate);
                try std.testing.expectEqual(info.format.layout, got.format.layout);
            } else |want| {
                try std.testing.expectError(want, result);
            }
        }
    }
}

test "AU files agree with memory for every fixture and buffer size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [default_buffer_len]u8 = undefined;

    inline for (fixtures.au.all) |fixture| {
        const path = fixture.name ++ ".au";
        try writeBytes(io, tmp.dir, path, fixtures.au.bytes(fixture.name));
        var memory: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
        const expected = detect.probe(&memory, .{});

        for ([_]usize{ 0, 1, 64, default_buffer_len }) |capacity| {
            const result = probePath(io, tmp.dir, path, buffer[0..capacity], .{});
            if (expected) |info| {
                const got = try result;
                try std.testing.expectEqual(info.container, got.container);
                try std.testing.expectEqual(info.frame_count, got.frame_count);
                try std.testing.expectEqual(info.format, got.format);
            } else |want| {
                try std.testing.expectError(want, result);
            }
        }
    }
}

test "decoding a file matches decoding the same bytes in memory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [64]u8 = undefined;

    inline for (fixtures.all) |fixture| {
        if (fixture.expected == .accept) {
            try writeFixture(io, tmp.dir, fixture.name);
            var memory: std.Io.Reader = .fixed(fixtures.bytes(fixture.name));
            var expected_raw: [512]u8 = undefined;
            var expected_out: std.Io.Writer = .fixed(&expected_raw);
            _ = try wav.decodeToRaw(&memory, &expected_out, .{});

            const file = try tmp.dir.openFile(io, fixture.name ++ ".wav", .{});
            defer file.close(io);
            var raw: [512]u8 = undefined;
            var out: std.Io.Writer = .fixed(&raw);
            _ = try decodeFile(io, file, &buffer, &out, .{});
            try std.testing.expectEqualSlices(u8, expected_out.buffered(), out.buffered());
        }
    }
}

fn patternSample(index: u64) i16 {
    const bits: u16 = @truncate(index *% 7919);
    return @bitCast(bits);
}

test "a 4 MiB stream is written and read back with fixed memory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stereo = try audio.Format.init(48000, 2, .s16);
    const frame_count = 1 << 20;

    {
        const file = try tmp.dir.createFile(io, "large.wav", .{});
        defer file.close(io);
        var buffer: [default_buffer_len]u8 = undefined;
        var file_writer = file.writerStreaming(io, &buffer);
        var writer = try wav.Writer.begin(&file_writer.interface, .s16le, stereo, frame_count, .{});
        var chunk: [4096]i16 = undefined;
        var next: u64 = 0;
        while (next < frame_count * 2) {
            for (&chunk, 0..) |*sample, i| sample.* = patternSample(next + i);
            try writer.writeFrames(&chunk);
            next += chunk.len;
        }
        try writer.finish();
    }

    const file = try tmp.dir.openFile(io, "large.wav", .{});
    defer file.close(io);
    var buffer: [default_buffer_len]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    var parser: wav.Parser = .init(&reader.interface, .{});
    const info = try parser.readHeader();
    try std.testing.expectEqual(frame_count, info.frame_count);
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

test "a failing read reports the file's own error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Created files are write-only unless `.read = true`, so reading fails.
    const file = try tmp.dir.createFile(io, "write-only.wav", .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    const err = if (probeFile(io, file, &buffer, .{})) |_| return error.TestExpectedError else |e| e;
    try std.testing.expect(err != error.IoFailure);
    if (builtin.os.tag == .linux) try std.testing.expectEqual(error.NotOpenForReading, err);
}

test "path helpers report missing files and release handles on failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [64]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, probePath(io, tmp.dir, "missing.wav", &buffer, .{}));
    try writeFixture(io, tmp.dir, "not_riff");
    try std.testing.expectError(error.InvalidRiff, probePath(io, tmp.dir, "not_riff.wav", &buffer, .{}));
    // The handle was closed, so the file can be removed.
    try tmp.dir.deleteFile(io, "not_riff.wav");
}

test "writer adapters produce the writer-output fixtures" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [1]u8 = undefined;

    // The helpers write pcm_s16le from s16 samples, plain or extensible.
    inline for (fixtures.all) |fixture| {
        if (fixture.writer_output and !fixture.writer_rf64 and fixture.expected.accept.codec == .pcm_s16le) {
            const stream = fixture.expected.accept;
            const format = try audio.Format.init(stream.sample_rate, stream.channels, .s16);
            try writePath(io, tmp.dir, fixture.name ++ ".wav", &buffer, format, stream.samples.s16, .{});
            var content: [256]u8 = undefined;
            const written = try tmp.dir.readFile(io, fixture.name ++ ".wav", &content);
            try std.testing.expectEqualSlices(u8, fixtures.bytes(fixture.name), written);
        }
    }
}

// The adapters above are WAV-only; these run the AU parser and writer over
// real files with the same reader and writer buffer sizes.
test "AU files decode like memory with every reader buffer size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [default_buffer_len]u8 = undefined;

    inline for (fixtures.au.all) |fixture| {
        const path = fixture.name ++ ".au";
        try writeBytes(io, tmp.dir, path, fixtures.au.bytes(fixture.name));
        var memory: std.Io.Reader = .fixed(fixtures.au.bytes(fixture.name));
        var expected_raw: [512]u8 = undefined;
        var expected_out: std.Io.Writer = .fixed(&expected_raw);
        const expected = au.decodeToRaw(&memory, &expected_out, .{});

        for ([_]usize{ 0, 1, 64, default_buffer_len }) |capacity| {
            const file = try tmp.dir.openFile(io, path, .{});
            defer file.close(io);
            var reader = file.readerStreaming(io, buffer[0..capacity]);
            var raw: [512]u8 = undefined;
            var out: std.Io.Writer = .fixed(&raw);
            const result = au.decodeToRaw(&reader.interface, &out, .{});
            if (expected) |info| {
                const got = try result;
                try std.testing.expectEqual(info.frame_count, got.frame_count);
                try std.testing.expectEqual(info.format.sample_rate, got.format.sample_rate);
                try std.testing.expectEqual(info.format.layout, got.format.layout);
            } else |want| {
                try std.testing.expectError(want, result);
            }
            // Samples delivered before a failure are the same too.
            try std.testing.expectEqualSlices(u8, expected_out.buffered(), out.buffered());
        }
    }
}

test "the AU writer reproduces its fixtures through every writer buffer size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [64]u8 = undefined;

    inline for (fixtures.au.all) |fixture| {
        if (fixture.writer_output) {
            const stream = fixture.expected.accept;
            const format = try audio.Format.init(stream.sample_rate, stream.channels, .s16);
            const path = fixture.name ++ ".au";
            for ([_]usize{ 0, 1, 64 }) |capacity| {
                {
                    const file = try tmp.dir.createFile(io, path, .{});
                    defer file.close(io);
                    var file_writer = file.writerStreaming(io, buffer[0..capacity]);
                    var writer = try au.Writer.begin(&file_writer.interface, format, stream.frameCount(), .{});
                    try writer.writeFrames(stream.samples.s16);
                    try writer.finish();
                }
                var content: [256]u8 = undefined;
                const written = try tmp.dir.readFile(io, path, &content);
                try std.testing.expectEqualSlices(u8, fixtures.au.bytes(fixture.name), written);
            }
        }
    }
}

test "a failing write reports the file's own error" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir, "mono_8k");
    // Opened read-only, so writing fails.
    const file = try tmp.dir.openFile(io, "mono_8k.wav", .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    const mono = try audio.Format.init(8000, 1, .s16);
    const err = if (writeFile(io, file, &buffer, mono, &.{ 1, 2 }, .{})) |_| return error.TestExpectedError else |e| e;
    try std.testing.expect(err != error.WriteFailed);
    if (builtin.os.tag == .linux) try std.testing.expectEqual(error.NotOpenForWriting, err);
}
