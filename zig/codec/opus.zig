// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/opus/parse.c (ff_opus_parse_packet,
// xiph_lacing_16bit, xiph_lacing_full), frame_duration_tab.c and opus.h at
// the pinned reference revision.
// Copyright (c) 2012 Andrew D'Addesio
// Copyright (c) 2013-2014 Mozilla Corporation
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! Opus packets (RFC 6716 section 3, TODO.md T28a) as FFmpeg's decoder
//! splits them: the TOC byte's configuration, channels and frame-count
//! code, then the frames' offsets and sizes, with FFmpeg's checks
//! (vectors/opus_parse.txt).

const std = @import("std");

pub const max_frame_size = 1275;
pub const max_frames = 48;
/// The longest packet, 120 ms at 48 kHz.
pub const max_packet_duration = 5760;

pub const Mode = enum(u2) { silk, hybrid, celt };

pub const Bandwidth = enum(u3) { narrowband, mediumband, wideband, superwideband, fullband };

/// ff_opus_frame_duration: a configuration's frame length at 48 kHz.
pub const frame_duration = [32]u16{
    480, 960, 1920, 2880,
    480, 960, 1920, 2880,
    480, 960, 1920, 2880,
    480, 960, 480,  960,
    120, 240, 480,  960,
    120, 240, 480,  960,
    120, 240, 480,  960,
    120, 240, 480,  960,
};

/// `OpusPacket`.
pub const Packet = struct {
    packet_size: u32,
    /// The packet less its padding; FFmpeg's ints, negative when the
    /// padding claims more than the packet holds, which FFmpeg accepts here
    /// and its decoder then refuses.
    data_size: i32,
    code: u2,
    stereo: bool,
    vbr: bool,
    config: u5,
    frame_count: u32,
    frame_offset: [max_frames]i32,
    frame_size: [max_frames]i32,
    /// Samples at 48 kHz.
    frame_duration: u32,
    mode: Mode,
    bandwidth: Bandwidth,
};

/// xiph_lacing_16bit: a 1- or 2-byte frame length.
fn lacing16(buf: []const u8, ptr: *usize) ?u32 {
    if (ptr.* >= buf.len) return null;
    var val: u32 = buf[ptr.*];
    ptr.* += 1;
    if (val >= 252) {
        if (ptr.* >= buf.len) return null;
        val += 4 * @as(u32, buf[ptr.*]);
        ptr.* += 1;
    }
    return val;
}

/// xiph_lacing_full: a padding length of 255-steps.
fn lacingFull(buf: []const u8, ptr: *usize) ?u32 {
    var val: u32 = 0;
    while (true) {
        if (ptr.* >= buf.len or val > std.math.maxInt(i32) - 254) return null;
        const next = buf[ptr.*];
        ptr.* += 1;
        val += next;
        if (next < 255) break;
        val -= 1;
    }
    return val;
}

/// ff_opus_parse_packet: null where FFmpeg's fails (AVERROR_INVALIDDATA).
/// A self-delimited packet (multistream) gives its own length.
pub fn parsePacket(buf_in: []const u8, self_delimiting: bool) ?Packet {
    var buf = buf_in;
    var ptr: usize = 0;
    var padding: u32 = 0;
    if (buf.len < 1) return null;
    var pkt: Packet = undefined;
    const toc = buf[0];
    ptr = 1;
    pkt.code = @truncate(toc);
    pkt.stereo = (toc >> 2) & 1 != 0;
    pkt.config = @truncate(toc >> 3);
    if (pkt.code >= 2 and buf.len < 2) return null;
    switch (pkt.code) {
        0 => {
            pkt.frame_count = 1;
            pkt.vbr = false;
            if (self_delimiting) {
                const len = lacing16(buf, &ptr) orelse return null;
                if (len > buf.len - ptr) return null;
                buf = buf[0 .. ptr + len];
            }
            const frame_bytes = buf.len - ptr;
            if (frame_bytes > max_frame_size) return null;
            pkt.frame_offset[0] = @intCast(ptr);
            pkt.frame_size[0] = @intCast(frame_bytes);
        },
        1 => {
            pkt.frame_count = 2;
            pkt.vbr = false;
            if (self_delimiting) {
                const len = lacing16(buf, &ptr) orelse return null;
                if (2 * len > buf.len - ptr) return null;
                buf = buf[0 .. ptr + 2 * len];
            }
            const frame_bytes = buf.len - ptr;
            if (frame_bytes & 1 != 0 or frame_bytes >> 1 > max_frame_size) return null;
            pkt.frame_offset[0] = @intCast(ptr);
            pkt.frame_size[0] = @intCast(frame_bytes >> 1);
            pkt.frame_offset[1] = pkt.frame_offset[0] + pkt.frame_size[0];
            pkt.frame_size[1] = @intCast(frame_bytes >> 1);
        },
        2 => {
            pkt.frame_count = 2;
            pkt.vbr = true;
            const first = lacing16(buf, &ptr) orelse return null;
            if (self_delimiting) {
                const len = lacing16(buf, &ptr) orelse return null;
                if (len + first > buf.len - ptr) return null;
                buf = buf[0 .. ptr + first + len];
            }
            pkt.frame_offset[0] = @intCast(ptr);
            pkt.frame_size[0] = @intCast(first);
            const rest = @as(i64, @intCast(buf.len)) - @as(i64, @intCast(ptr)) - first;
            if (rest < 0 or rest > max_frame_size) return null;
            pkt.frame_offset[1] = pkt.frame_offset[0] + pkt.frame_size[0];
            pkt.frame_size[1] = @intCast(rest);
        },
        3 => {
            const b = buf[ptr];
            ptr += 1;
            pkt.frame_count = b & 0x3f;
            const has_padding = (b >> 6) & 1 != 0;
            pkt.vbr = (b >> 7) & 1 != 0;
            if (pkt.frame_count == 0 or pkt.frame_count > max_frames) return null;
            if (has_padding) padding = lacingFull(buf, &ptr) orelse return null;
            if (pkt.vbr) {
                // Every frame's size but the last is coded.
                var total_bytes: u32 = 0;
                for (0..pkt.frame_count - 1) |i| {
                    const size = lacing16(buf, &ptr) orelse return null;
                    pkt.frame_size[i] = @intCast(size);
                    total_bytes += size;
                }
                if (self_delimiting) {
                    const len = lacing16(buf, &ptr) orelse return null;
                    if (@as(u64, len) + total_bytes + padding > buf.len - ptr) return null;
                    buf = buf[0 .. ptr + total_bytes + len + padding];
                }
                const frame_bytes = @as(i64, @intCast(buf.len)) - @as(i64, @intCast(ptr)) - padding;
                if (total_bytes > frame_bytes) return null;
                pkt.frame_offset[0] = @intCast(ptr);
                for (1..pkt.frame_count) |i| pkt.frame_offset[i] = pkt.frame_offset[i - 1] + pkt.frame_size[i - 1];
                // FFmpeg does not bound the last frame's size here.
                pkt.frame_size[pkt.frame_count - 1] = @intCast(frame_bytes - total_bytes);
            } else {
                // CBR: the bytes divided evenly.
                var frame_bytes: i32 = undefined;
                if (self_delimiting) {
                    const len = lacing16(buf, &ptr) orelse return null;
                    frame_bytes = @intCast(len);
                    if (@as(u64, pkt.frame_count) * len + padding > buf.len - ptr) return null;
                    buf = buf[0 .. ptr + pkt.frame_count * len + padding];
                } else {
                    const all = @as(i64, @intCast(buf.len)) - @as(i64, @intCast(ptr)) - padding;
                    // C's % and / truncate a negative count toward zero:
                    // a padding past the end can leave negative sizes.
                    if (@rem(all, pkt.frame_count) != 0 or @divTrunc(all, pkt.frame_count) > max_frame_size) return null;
                    frame_bytes = @intCast(@divTrunc(all, pkt.frame_count));
                }
                pkt.frame_offset[0] = @intCast(ptr);
                pkt.frame_size[0] = frame_bytes;
                for (1..pkt.frame_count) |i| {
                    pkt.frame_offset[i] = pkt.frame_offset[i - 1] + pkt.frame_size[i - 1];
                    pkt.frame_size[i] = frame_bytes;
                }
            }
        },
    }
    pkt.packet_size = @intCast(buf.len);
    pkt.data_size = @as(i32, @intCast(pkt.packet_size)) - @as(i32, @intCast(padding));
    pkt.frame_duration = frame_duration[pkt.config];
    if (pkt.frame_duration * pkt.frame_count > max_packet_duration) return null;
    if (pkt.config < 12) {
        pkt.mode = .silk;
        pkt.bandwidth = @fromBackingInt(@intCast(pkt.config >> 2));
    } else if (pkt.config < 16) {
        pkt.mode = .hybrid;
        pkt.bandwidth = if (pkt.config >= 14) .fullband else .superwideband;
    } else {
        pkt.mode = .celt;
        var bw: u3 = @intCast((pkt.config - 16) >> 2);
        // No medium band.
        if (bw != 0) bw += 1;
        pkt.bandwidth = @fromBackingInt(@intCast(bw));
    }
    return pkt;
}

const testing = std.testing;
const vectors = @embedFile("../testing/vectors/opus_parse.txt");

/// opus_parse_vectors.c's generator.
const Generator = struct {
    state: u32,

    fn next(g: *Generator) u32 {
        g.state = g.state *% 1103515245 +% 12345;
        return g.state >> 16;
    }

    /// make_packet.
    fn packet(g: *Generator, buf: []u8) usize {
        const size: usize = g.next() % 300;
        for (buf[0 .. size + 8]) |*b| b.* = @truncate(g.next());
        if (size >= 2 and buf[0] & 3 == 3) {
            const count = g.next() % 6 + 1;
            const pad = g.next() % 2;
            const vbr = g.next() % 2;
            buf[1] = @intCast(count | pad << 6 | vbr << 7);
            var at: usize = 2;
            if (buf[1] & 0x40 != 0 and at < size) {
                buf[at] = @intCast(g.next() % 20);
                at += 1;
            }
            if (buf[1] & 0x80 != 0) {
                var i: usize = 0;
                while (i < (buf[1] & 0x3f) - 1 and at < size) : (i += 1) {
                    buf[at] = @intCast(g.next() % 60);
                    at += 1;
                }
            }
        }
        return size;
    }
};

test "packets parse as FFmpeg's ff_opus_parse_packet parses them (vectors/opus_parse.txt)" {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    var buf: [320]u8 = undefined;
    var text: [2048]u8 = undefined;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next();
        const seed = try std.fmt.parseInt(u32, f.next().?, 10);
        var g: Generator = .{ .state = seed };
        const size = g.packet(&buf);
        const sd = g.next() % 2 == 1;
        var w: std.Io.Writer = .fixed(&text);
        if (parsePacket(buf[0..size], sd)) |p| {
            try w.print("K {d} {d} {d} 0 {d} {d} {d} {d} {d} {d} {d} {d} {d} {d} ", .{ seed, size, @intFromBool(sd), p.code, @intFromBool(p.stereo), @intFromBool(p.vbr), p.config, p.frame_count, p.packet_size, p.data_size, p.frame_duration, @backingInt(p.mode), @backingInt(p.bandwidth) });
            for (0..p.frame_count) |i| try w.print("{s}{d}:{d}", .{ if (i == 0) "" else ",", p.frame_offset[i], p.frame_size[i] });
        } else {
            try w.print("K {d} {d} {d} -1 0 0 0 0 0 0 0 0 0 0 -", .{ seed, size, @intFromBool(sd) });
        }
        testing.expectEqualStrings(line, w.buffered()) catch |err| {
            std.debug.print("seed {d}\n", .{seed});
            return err;
        };
        cases += 1;
    }
    try testing.expectEqual(2000, cases);
}
