// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Test driver for the FFmpeg comparison (TODO.md T19a, T21a). It writes one
//! media file from decoded samples with the `av` encoders and writers, so the
//! reference reads the actual Zig output rather than only fixtures the writer
//! is tested to reproduce.
//!
//!     write-driver <wav|au> <codec> <sample_rate> <channels> <input.raw> <output> [rf64]
//!
//! `codec` is an FFmpeg PCM codec name such as `pcm_s24le`. The input holds
//! interleaved samples in that codec's storage format (`s32` for 24-bit),
//! little-endian, at most `max_input_bytes` of them. A trailing `rf64` makes
//! the WAV writer emit RF64 even for a small stream (`rf64 = .always`, T21b). Exit status: 0 on success, 1 for usage errors, 2
//! for any other failure, with one diagnostic line on stderr.
//! zig/testing/reference/compare.py runs it. It is a test tool, not a product:
//! `zig build test-tools` installs it, and `zig build test` compiles it.

const std = @import("std");
const av = @import("av");

const usage = "usage: write-driver <wav|au> <codec> <sample_rate> <channels> <input.raw> <output> [rf64]\n";

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
    if (args.len != 7 and args.len != 8) return usageError(io);
    const container = std.meta.stringToEnum(Container, args[1]) orelse return usageError(io);
    const codec = codecFromName(args[2]) orelse return usageError(io);
    const rf64: av.wav.Rf64 = if (args.len == 8) blk: {
        if (!std.mem.eql(u8, args[7], "rf64")) return usageError(io);
        break :blk .always;
    } else .auto;
    write(io, init.gpa, container, codec, rf64, args[3], args[4], args[5], args[6]) catch |err| {
        printError(io, "write-driver: {t}\n", .{err});
        return .failure;
    };
    return .ok;
}

fn usageError(io: std.Io) Status {
    printError(io, usage, .{});
    return .usage;
}

fn codecFromName(name: []const u8) ?av.pcm.Codec {
    if (!std.mem.startsWith(u8, name, "pcm_")) return null;
    return std.meta.stringToEnum(av.pcm.Codec, name["pcm_".len..]);
}

fn write(
    io: std.Io,
    gpa: std.mem.Allocator,
    container: Container,
    codec: av.pcm.Codec,
    rf64: av.wav.Rf64,
    rate_text: []const u8,
    channels_text: []const u8,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    const sample_rate = try std.fmt.parseInt(u32, rate_text, 10);
    const channels = try std.fmt.parseInt(u16, channels_text, 10);
    const format = try av.audio.Format.init(sample_rate, channels, codec.storage());

    const cwd = std.Io.Dir.cwd();
    const raw = try cwd.readFileAlloc(io, input_path, gpa, .limited(max_input_bytes));
    defer gpa.free(raw);
    const stored_bytes: usize = codec.storage().bytesPerSample();
    const frame_bytes = stored_bytes * channels;
    if (raw.len % frame_bytes != 0) return error.IncompleteFrame;
    // At most max_input_bytes bytes, so the count fits in u32.
    const frames: u32 = @intCast(raw.len / frame_bytes);
    // The input is little-endian; stored samples are in the target's order.
    av.pcm.storedToLittle(codec.storage(), raw);
    const frame_count: usize = frames;
    const encoded = try gpa.alloc(u8, frame_count * channels * codec.bytesPerSample());
    defer gpa.free(encoded);
    if (frames > 0) {
        const layout = try av.samples.Layout.init(codec.storage(), channels, frames, .{ .line = 1 });
        _ = try av.pcm.encode(codec, try av.samples.Buffer.init(layout, raw), 0, frames, encoded);
    }

    const file = try cwd.createFile(io, output_path, .{});
    defer file.close(io);
    var buffer: [av.file.default_buffer_len]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buffer);
    switch (container) {
        .wav => {
            var writer = try av.wav.Writer.begin(&file_writer.interface, codec, format, frames, .{ .rf64 = rf64 });
            try writer.writeData(encoded);
            try writer.finish();
        },
        .au => {
            // AU carries only pcm_s16be until TODO.md T22a.
            if (codec != .s16be) return error.UnsupportedFormat;
            var writer = try av.au.Writer.begin(&file_writer.interface, format, frames, .{});
            try writer.writeData(encoded);
            try writer.finish();
        },
    }
}
fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr_writer.interface.print(fmt, args) catch return;
    stderr_writer.interface.flush() catch return;
}
