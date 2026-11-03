// SPDX-License-Identifier: LGPL-2.1-or-later
// Original example for this project; no zigimg implementation is copied.
//! Standalone Zig 0.17 I/O patterns, informed by the zigimg source review.
//! Run: zig test zig/examples/io_patterns.zig
//! This reads individual fields; it is not a WAV parser or a stable library API.

const std = @import("std");

pub const ReadError = error{ Truncated, IoFailure };

/// Reads exactly one encoded field, without allocating or borrowing buffer views.
/// EOF is truncation here because the caller has requested a required field.
/// Either error may follow consumption of part of the field, so the reader's
/// position is unspecified afterward; treat both errors as terminal for the stream.
pub fn readU32Le(reader: *std.Io.Reader) ReadError!u32 {
    var bytes: [4]u8 = undefined;
    reader.readSliceAll(&bytes) catch |err| switch (err) {
        error.EndOfStream => return error.Truncated,
        error.ReadFailed => return error.IoFailure,
    };
    return std.mem.readInt(u32, &bytes, .little);
}

/// The caller owns the writer and decides when to flush. Failure may write a prefix.
/// Encoding into a local array avoids `Writer.writeInt`'s documented requirement
/// for a writer buffer of at least `@sizeOf(T)` bytes, so any buffer size works.
pub fn writeU32Le(writer: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

/// Recover the file adapter's detailed error, including cancellation, when available.
/// Keep this adapter alive and at a stable address while its interface is borrowed.
pub fn readFileU32Le(reader: *std.Io.File.Reader) (ReadError || std.Io.File.Reader.Error)!u32 {
    return readU32Le(&reader.interface) catch |err| {
        if (err == error.IoFailure) return reader.err orelse error.IoFailure;
        return err;
    };
}

test "memory reader consumes one field and preserves the following byte" {
    var reader = std.Io.Reader.fixed(&.{ 0x78, 0x56, 0x34, 0x12, 0xab });
    try std.testing.expectEqual(0x12345678, try readU32Le(&reader));
    try std.testing.expectEqual(0xab, try reader.takeByte());
}

test "every short field reports truncation" {
    const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    for (0..bytes.len) |length| {
        var reader = std.Io.Reader.fixed(bytes[0..length]);
        try std.testing.expectError(error.Truncated, readU32Le(&reader));
    }
}

test "one-byte source fragments use the same field parser" {
    var buffer: [1]u8 = undefined;
    var source = std.testing.Reader.init(&buffer, &.{
        .{ .buffer = &.{ 0x78, 0x56 } },
        .{ .buffer = &.{ 0x34, 0x12 } },
    });
    source.artificial_limit = .limited(1);
    try std.testing.expectEqual(0x12345678, try readU32Le(&source.interface));
}

test "I/O failure is distinct from truncated data" {
    var reader = std.Io.Reader.failing;
    try std.testing.expectError(error.IoFailure, readU32Le(&reader));
}

test "memory writer produces specified bytes and reports insufficient space" {
    var buffer: [4]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeU32Le(&writer, 0x12345678);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, writer.buffered());

    var small: [1]u8 = undefined;
    var short_writer = std.Io.Writer.fixed(&small);
    try std.testing.expectError(error.WriteFailed, writeU32Le(&short_writer, 0x12345678));
}

test "file adapters work with empty small and larger caller buffers" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    {
        const file = try directory.dir.createFile(io, "fields.bin", .{});
        defer file.close(io);
        var buffer: [3]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        // Borrow the interface only after its enclosing adapter is in place.
        try writeU32Le(&writer.interface, 0x12345678);
        try writeU32Le(&writer.interface, 0x90abcdef);
        writer.interface.flush() catch return writer.err orelse error.WriteFailed;
    }

    for ([_]usize{ 0, 1, 64 }) |capacity| {
        const file = try directory.dir.openFile(io, "fields.bin", .{});
        defer file.close(io);
        var buffer: [64]u8 = undefined;
        var reader = file.readerStreaming(io, buffer[0..capacity]);
        // Reuse the same adapter: reconstructing it could discard read-ahead bytes.
        try std.testing.expectEqual(0x12345678, try readFileU32Le(&reader));
        try std.testing.expectEqual(0x90abcdef, try readFileU32Le(&reader));
        try std.testing.expectError(error.Truncated, readFileU32Le(&reader));
    }
}

test "file read failure returns the adapter's retained error" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();

    // Created files lack read access unless `.read = true`, so reading must fail.
    const file = try directory.dir.createFile(io, "write-only.bin", .{});
    defer file.close(io);
    var buffer: [8]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    if (readFileU32Le(&reader)) |_| {
        return error.TestExpectedError;
    } else |err| {
        // The generic interface reports only ReadFailed; the adapter keeps the cause.
        const retained = reader.err orelse return error.TestExpectedError;
        try std.testing.expectEqual(retained, err);
        try std.testing.expect(err != error.IoFailure);
    }
}
