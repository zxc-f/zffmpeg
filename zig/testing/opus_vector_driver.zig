// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a test tool, not part of the port.
//! The RFC 6716 / RFC 8251 test vector check (TODO.md T28) that
//! compare.py runs on the optional corpus: a `.bit` file (each packet a
//! 32-bit big-endian length, the encoder's 32-bit final range and the
//! packet) decoded by `av.opusdec` at 48 kHz into 1 or 2 channels, then a
//! null packet for the samples the decoder still owes, as FFmpeg's
//! decoder is drained.
//!
//!   opus-vector-driver <file.bit> <channels> <reference.dec> [<reference.dec>]
//!
//! Prints the decoding's MD5 (the samples interleaved as float32
//! little-endian, which compare.py compares with FFmpeg's,
//! vectors/opus_rfc.txt), the packets whose final range differs from the
//! encoder's as opus_demo checks it, and `opus_compare`'s verdict on the
//! samples rounded to 16 bits as libopus' float build does; with two
//! references the better, as libopus' `run_vectors.sh` checks a mono
//! decoding against testvectorNN.dec and testvectorNNm.dec. Exits 0 once
//! decoded, 1 on a usage error, 2 on a failure, 3 when the vector holds
//! frames the decoder does not decode yet (hybrid).

const std = @import("std");
const av = @import("av");
const opus_compare = @import("opus_compare.zig");

const usage = "usage: opus-vector-driver <file.bit> <channels> <reference.dec> [<reference.dec>]\n";
const max_input_bytes = 64 << 20;

const Status = enum(u8) { ok = 0, usage = 1, fails = 2, unsupported = 3 };

/// The decoding: 16-bit samples for opus_compare, the float samples'
/// MD5.
const Output = struct {
    pcm: std.ArrayList(i16) = .empty,
    md5: std.crypto.hash.Md5 = .init(.{}),
    samples: u64 = 0,

    /// FLOAT2INT16 (scaled, clamped, rounded to nearest) and the float
    /// bytes hashed, interleaved.
    fn append(o: *Output, gpa: std.mem.Allocator, planes: []const []f32, n: u32) !void {
        for (0..n) |i| {
            for (planes) |plane| {
                const v = std.math.clamp(plane[i] * 32768.0, -32768.0, 32767.0);
                try o.pcm.append(gpa, @intFromFloat(@round(v)));
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(plane[i]), .little);
                o.md5.update(&b);
            }
        }
        o.samples += n;
    }
};

pub fn main(init: std.process.Init) u8 {
    return @backingInt(run(init) catch |err| blk: {
        print(init.io, "opus-vector-driver: {t}\n", .{err});
        break :blk Status.fails;
    });
}

fn run(init: std.process.Init) !Status {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 and args.len != 5) {
        print(io, usage, .{});
        return .usage;
    }
    const channels = std.fmt.parseInt(u8, args[2], 10) catch 0;
    if (channels != 1 and channels != 2) {
        print(io, usage, .{});
        return .usage;
    }
    const cwd = std.Io.Dir.cwd();
    const bits = try cwd.readFileAlloc(io, args[1], gpa, .limited(max_input_bytes));
    defer gpa.free(bits);

    // An OpusHead for mapping family 0 without pre-skip or gain, as
    // opus_demo decodes.
    var head = [_]u8{ 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, channels, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 0 };
    var dec = try av.opusdec.Decoder.init(gpa, &head, true);
    defer dec.deinit();
    const storage = try gpa.alloc(f32, @as(usize, channels) * av.opusdec.max_output);
    defer gpa.free(storage);
    var planes: [2][]f32 = undefined;
    for (0..channels) |c| planes[c] = storage[c * av.opusdec.max_output ..][0..av.opusdec.max_output];

    var decoded: Output = .{};
    defer decoded.pcm.deinit(gpa);
    var at: usize = 0;
    var packets: usize = 0;
    var mismatches: usize = 0;
    while (at + 8 <= bits.len) {
        const len = std.mem.readInt(u32, bits[at..][0..4], .big);
        const enc_range = std.mem.readInt(u32, bits[at + 4 ..][0..4], .big);
        at += 8;
        if (len > bits.len - at) return error.Truncated;
        const packet = bits[at..][0..len];
        at += len;
        packets += 1;
        const n = dec.decodePacket(packet, planes[0..channels]) catch |err| switch (err) {
            error.UnsupportedMode => {
                print(io, "packet {d}: hybrid frames are not decoded yet\n", .{packets});
                return .unsupported;
            },
            error.InvalidData => {
                print(io, "packet {d}: the decoder refuses it\n", .{packets});
                return .fails;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (enc_range != 0 and dec.finalRange() != enc_range) mismatches += 1;
        try decoded.append(gpa, planes[0..channels], n);
    }
    if (at != bits.len) return error.Truncated;
    // FFmpeg's decoder delays SILK by its resampler: the samples it still
    // owes, which libopus' output already holds.
    const tail = dec.decodePacket(null, planes[0..channels]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => 0,
    };
    try decoded.append(gpa, planes[0..channels], tail);

    var best: ?opus_compare.Result = null;
    for (args[3..]) |path| {
        const reference_bytes = try cwd.readFileAlloc(io, path, gpa, .limited(max_input_bytes));
        defer gpa.free(reference_bytes);
        const reference = try gpa.alloc(i16, reference_bytes.len / 2);
        defer gpa.free(reference);
        for (reference, 0..) |*r, i| r.* = std.mem.readInt(i16, reference_bytes[2 * i ..][0..2], .little);
        const result = try opus_compare.compare(gpa, reference, decoded.pcm.items, channels, 48000);
        if (best == null or result.quality > best.?.quality) best = result;
    }
    const result = best.?;
    var digest: [16]u8 = undefined;
    decoded.md5.final(&digest);
    printOut(io, "md5 {x} samples {d} packets {d} range-mismatches {d} opus_compare {s} quality {d:.1}\n", .{
        digest,         decoded.samples, packets, mismatches, if (result.passes()) "PASSES" else "FAILS",
        result.quality,
    });
    return .ok;
}

fn print(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr.interface.print(format, args) catch return;
    stderr.interface.flush() catch return;
}

fn printOut(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    stdout.interface.print(format, args) catch return;
    stdout.interface.flush() catch return;
}
