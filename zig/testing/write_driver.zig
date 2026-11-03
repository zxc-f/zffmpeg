// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Test driver for the FFmpeg comparison (TODO.md T19a). It writes one media
//! file from raw samples with the `av` writers, so the reference reads the
//! actual Zig output rather than only fixtures the writer is tested to
//! reproduce.
//!
//!     write-driver <wav|au> <sample_rate> <channels> <input.s16le> <output>
//!
//! The input holds interleaved signed 16-bit little-endian samples, at most
//! `max_input_bytes` of them. Exit status: 0 on success, 1 for usage errors, 2
//! for any other failure, with one diagnostic line on stderr.
//! zig/testing/reference/compare.py runs it. It is a test tool, not a product:
//! `zig build test-tools` installs it, and `zig build test` compiles it.

const std = @import("std");
const av = @import("av");

const usage = "usage: write-driver <wav|au> <sample_rate> <channels> <input.s16le> <output>\n";

const Container = enum { wav, au };

/// Inputs are fixture-sized; the bound keeps a wrong argument from reading a
/// large file into memory.
const max_input_bytes = 1 << 20;

/// The driver's own status contract (see the module docs); it does not share
/// zffprobe's categories.
const Status = enum(u8) {
    ok = 0,
    usage = 1,
    failure = 2,
};

pub fn main(init: std.process.Init) u8 {
    return @backingInt(run(init));
}

fn run(init: std.process.Init) Status {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(io, "write-driver: out of memory\n", .{});
        return .failure;
    };
    if (args.len != 6) return usageError(io);
    const container = std.meta.stringToEnum(Container, args[1]) orelse return usageError(io);
    write(io, init.gpa, container, args[2], args[3], args[4], args[5]) catch |err| {
        printError(io, "write-driver: {t}\n", .{err});
        return .failure;
    };
    return .ok;
}

fn usageError(io: std.Io) Status {
    printError(io, usage, .{});
    return .usage;
}

fn write(
    io: std.Io,
    gpa: std.mem.Allocator,
    container: Container,
    rate_text: []const u8,
    channels_text: []const u8,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    const sample_rate = try std.fmt.parseInt(u32, rate_text, 10);
    const channels = try std.fmt.parseInt(u16, channels_text, 10);
    const format = try av.audio.Format.init(sample_rate, channels, .s16);

    const cwd = std.Io.Dir.cwd();
    const raw = try cwd.readFileAlloc(io, input_path, gpa, .limited(max_input_bytes));
    defer gpa.free(raw);
    const storage = try gpa.alloc(i16, raw.len / 2);
    defer gpa.free(storage);
    const samples = try av.pcm.decodeS16(.little, raw, storage);

    var buffer: [av.file.default_buffer_len]u8 = undefined;
    switch (container) {
        .wav => try av.file.writePath(io, cwd, output_path, &buffer, format, samples, .{}),
        .au => try writeAu(io, cwd, output_path, &buffer, format, samples),
    }
}

fn writeAu(
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    buffer: []u8,
    format: av.audio.Format,
    samples: []const i16,
) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var file_writer = file.writerStreaming(io, buffer);
    var writer = try av.au.Writer.begin(&file_writer.interface, format, samples.len / format.channelCount(), .{});
    try writer.writeFrames(samples);
    try writer.finish();
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr_writer.interface.print(fmt, args) catch return;
    stderr_writer.interface.flush() catch return;
}
