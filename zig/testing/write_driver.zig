// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Test driver for the FFmpeg comparison (TODO.md T19a). It writes one media
//! file from raw samples with the `av` writers, so the reference reads the
//! actual Zig output rather than only fixtures the writer is tested to
//! reproduce.
//!
//!     write-driver wav <sample_rate> <channels> <input.s16le> <output>
//!
//! The input holds interleaved signed 16-bit little-endian samples, at most
//! `max_input_bytes` of them. Exit status: 0 on success, 1 for usage errors, 2
//! for any other failure, with one diagnostic line on stderr.
//! zig/testing/reference/compare.py runs it. It is a test tool, not a product:
//! `zig build test-tools` installs it, and `zig build test` compiles it.

const std = @import("std");
const av = @import("av");

const usage = "usage: write-driver wav <sample_rate> <channels> <input.s16le> <output>\n";

/// Inputs are fixture-sized; the bound keeps a wrong argument from reading a
/// large file into memory.
const max_input_bytes = 1 << 20;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(io, "write-driver: out of memory\n", .{});
        return 2;
    };
    if (args.len != 6 or !std.mem.eql(u8, args[1], "wav")) {
        printError(io, usage, .{});
        return 1;
    }
    writeWav(io, init.gpa, args[2], args[3], args[4], args[5]) catch |err| {
        printError(io, "write-driver: {t}\n", .{err});
        return 2;
    };
    return 0;
}

fn writeWav(
    io: std.Io,
    gpa: std.mem.Allocator,
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
    try av.file.writePath(io, cwd, output_path, &buffer, format, samples, .{});
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr_writer.interface.print(fmt, args) catch return;
    stderr_writer.interface.flush() catch return;
}
