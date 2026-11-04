// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a test tool, not part of the port.
//! The RFC 6716 / RFC 8251 test vector check (TODO.md T28a) that
//! compare.py runs on the optional corpus: a `.bit` file (each packet a
//! 32-bit big-endian length, the encoder's 32-bit final range and the
//! packet) decoded by `av.opusdec` at 48 kHz into 1 or 2 channels, each
//! packet's final range checked against the encoder's as opus_demo checks
//! it, the samples rounded to 16 bits as libopus' float build does, then
//! compared with the vector's reference output by `opus_compare`.
//!
//!   opus-vector-driver <file.bit> <channels> <reference.dec> [<reference.dec>]
//!
//! With two references the vector passes on either, as libopus'
//! `run_vectors.sh` checks a mono decoding against testvectorNN.dec and
//! testvectorNNm.dec. Prints `PASSES` or `FAILS` with the best quality,
//! and exits 0 when the vector passes, 1 on a usage error, 2 when it fails, 3 when the vector
//! holds frames the decoder does not decode yet (SILK or hybrid).

const std = @import("std");
const av = @import("av");
const opus_compare = @import("opus_compare.zig");

const usage = "usage: opus-vector-driver <file.bit> <channels> <reference.dec> [<reference.dec>]\n";
const max_input_bytes = 64 << 20;

const Status = enum(u8) { ok = 0, usage = 1, fails = 2, unsupported = 3 };

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
    const storage = try gpa.alloc(f32, @as(usize, channels) * av.opusdec.max_frame);
    defer gpa.free(storage);
    var planes: [2][]f32 = undefined;
    for (0..channels) |c| planes[c] = storage[c * av.opusdec.max_frame ..][0..av.opusdec.max_frame];

    var decoded: std.ArrayList(i16) = .empty;
    defer decoded.deinit(gpa);
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
                print(io, "packet {d}: SILK or hybrid frames are not decoded yet\n", .{packets});
                return .unsupported;
            },
            error.InvalidData => {
                print(io, "packet {d}: the decoder refuses it\n", .{packets});
                return .fails;
            },
        };
        if (enc_range != 0 and dec.finalRange() != enc_range) mismatches += 1;
        // FLOAT2INT16: scaled, clamped and rounded to nearest.
        for (0..n) |i| {
            for (0..channels) |c| {
                const v = std.math.clamp(planes[c][i] * 32768.0, -32768.0, 32767.0);
                try decoded.append(gpa, @intFromFloat(@round(v)));
            }
        }
    }
    if (at != bits.len) return error.Truncated;

    var best: ?opus_compare.Result = null;
    for (args[3..]) |path| {
        const reference_bytes = try cwd.readFileAlloc(io, path, gpa, .limited(max_input_bytes));
        defer gpa.free(reference_bytes);
        const reference = try gpa.alloc(i16, reference_bytes.len / 2);
        defer gpa.free(reference);
        for (reference, 0..) |*r, i| r.* = std.mem.readInt(i16, reference_bytes[2 * i ..][0..2], .little);
        const result = try opus_compare.compare(gpa, reference, decoded.items, channels, 48000);
        if (best == null or result.quality > best.?.quality) best = result;
    }
    const result = best.?;
    const passes = result.passes() and mismatches == 0;
    printOut(io, "{s} quality {d:.1} error {d:.6} packets {d} range mismatches {d}\n", .{ if (passes) "PASSES" else "FAILS", result.quality, result.err, packets, mismatches });
    return if (passes) .ok else .fails;
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
