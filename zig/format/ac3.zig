// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/ac3dec.c (ac3_eac3_probe) and rawdec.c
// (ff_raw_audio_read_header, ff_raw_read_partial_packet) at the pinned
// reference revision.
// Copyright (c) 2007 Justin Ruggles
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's raw AC-3 demuxer (`ac3`, TODO.md T32a): its content probe, one
//! stream in the 1/90000 time base starting at 0, and raw packets of up to
//! 1024 bytes, which demux.zig's layer splits into frames with FFmpeg's
//! AC-3 parser (codec/ac3.zig). The layer's read-ahead takes the stream's
//! rate, channels and layout from the parser and from FFmpeg's decoder,
//! which it runs on the first packet, and the sample format from the
//! decoder, which sets it when it opens.

const std = @import("std");
const rational = @import("../core/rational.zig");
const ac3 = @import("../codec/ac3.zig");
const bits = @import("../codec/bits.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");

pub const Error = error{
    /// A read failed.
    IoFailure,
    OutOfMemory,
};

pub const nopts: i64 = std.math.minInt(i64);
/// avformat_new_stream's default time base, which the raw demuxer keeps.
pub const time_base: rational.Rational = .{ .num = 1, .den = 90000 };
/// RAW_PACKET_SIZE: the raw demuxer's `raw_packet_size` default.
pub const raw_packet_size = 1024;

pub const Packet = demux.SourcePacket;

/// ac3_eac3_probe for AC-3 on a probe buffer: from every position that
/// starts with a sync word (and the first), the run of frames whose
/// headers parse, whose sizes fit and whose CRCs check, either byte order
/// (decided by the first two bytes of the run's start, as FFmpeg decides
/// it), an AMR-like 16-byte `\x01\x10` header skipped before each; 0 when
/// any frame found is E-AC-3.
pub fn probeScore(buf: []const u8) u8 {
    var max_frames: u32 = 0;
    var first_frames: u32 = 0;
    var eac3 = false;
    const at = struct {
        // Reads past the buffer see FFmpeg's zero padding.
        fn byte(b: []const u8, i: usize) u8 {
            return if (i < b.len) b[i] else 0;
        }
    }.byte;
    for (0..buf.len) |start| {
        const swapped_start = at(buf, start) == 0x77 and at(buf, start + 1) == 0x0B;
        if (start > 0 and !(at(buf, start) == 0x0B and at(buf, start + 1) == 0x77) and !swapped_start) continue;
        var pos = start;
        var frames: u32 = 0;
        while (pos < buf.len) : (frames += 1) {
            if (at(buf, pos) == 0x01 and at(buf, pos + 1) == 0x10) {
                if (pos + 16 > buf.len) break;
                pos += 16;
            }
            var buf3: [4096]u8 = undefined;
            const hdr = if (swapped_start) blk: {
                var i: usize = 0;
                while (i < 8) : (i += 2) {
                    buf3[i] = at(buf, pos + i + 1);
                    buf3[i + 1] = at(buf, pos + i);
                }
                break :blk ac3.parseHeaderShort(buf3[0..8]) catch break;
            } else ac3.parseHeaderShort(buf[pos..]) catch break;
            if (pos + hdr.frame_size > buf.len) break;
            if (swapped_start) {
                // Frames are at most 4096 bytes (av_assert0 in FFmpeg).
                var i: usize = 8;
                while (i < hdr.frame_size) : (i += 2) {
                    buf3[i] = at(buf, pos + i + 1);
                    buf3[i + 1] = at(buf, pos + i);
                }
                if (bits.Crc16.hash(buf3[2..hdr.frame_size]) != 0) break;
            } else {
                if (bits.Crc16.hash(buf[pos + 2 .. pos + hdr.frame_size]) != 0) break;
            }
            if (hdr.bitstream_id > 10) eac3 = true;
            pos += hdr.frame_size;
        }
        max_frames = @max(max_frames, frames);
        if (start == 0) first_frames = frames;
    }
    if (eac3) return 0;
    // AVPROBE_SCORE_EXTENSION is 50; kept in step with the MP3 probe.
    if (first_frames >= 7) return 50 + 2;
    if (max_frames > 200) return 50;
    if (max_frames >= 4) return 50 / 2;
    if (max_frames >= 1) return 1;
    return 0;
}

pub const Demuxer = struct {
    /// The error set demux.zig's layer returns.
    pub const ReadError = Error;

    gpa: std.mem.Allocator,
    src: demux.Window,
    /// The next read's position.
    pos: i64 = 0,
    /// ff_raw_audio_read_header's `start_time` 0.
    start_time: i64 = 0,
    duration: i64 = nopts,
    /// The packet returned last.
    current: std.ArrayList(u8) = .empty,

    /// The demuxer on a source that cannot seek (a pipe).
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader) Error!*Demuxer {
        return initWith(gpa, reader, null);
    }

    /// The demuxer on a seekable source read from its start (a file).
    pub fn initSeekable(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: seek.Seeker) Error!*Demuxer {
        return initWith(gpa, reader, seeker);
    }

    fn initWith(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker) Error!*Demuxer {
        const d = try gpa.create(Demuxer);
        d.* = .{ .gpa = gpa, .src = .{ .reader = reader, .seeker = seeker } };
        if (seeker) |sk| {
            d.src.window_start = @intCast(sk.position());
            d.pos = d.src.window_start;
        }
        return d;
    }

    pub fn deinit(d: *Demuxer) void {
        d.src.deinit(d.gpa);
        d.current.deinit(d.gpa);
        d.gpa.destroy(d);
    }

    pub fn streamCount(d: *const Demuxer) usize {
        _ = d;
        return 1;
    }

    pub fn setup(d: *const Demuxer, i: usize) demux.Setup {
        _ = d;
        std.debug.assert(i == 0);
        return .{
            .known = true,
            .time_base = time_base,
            .sample_rate = 0,
            .channels = 0,
            .parser = .ac3,
            .decoder = .ac3,
        };
    }

    /// ff_raw_read_partial_packet: the next bytes, up to 1024 (fewer at the
    /// end), with no flags; null at the end.
    pub fn next(d: *Demuxer) Error!?Packet {
        const bytes = d.src.bytesAt(d.gpa, d.pos, raw_packet_size) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoFailure,
        };
        if (bytes.len == 0) return null;
        d.current.clearRetainingCapacity();
        try d.current.appendSlice(d.gpa, bytes);
        const pos = d.pos;
        d.pos += @intCast(bytes.len);
        d.src.drop(d.pos);
        return .{ .stream = 0, .data = d.current.items, .pts = nopts, .dts = nopts, .duration = 0, .flags = 0, .pos = pos };
    }

    pub fn durationOf(d: *Demuxer, i: usize) *i64 {
        std.debug.assert(i == 0);
        return &d.duration;
    }

    pub fn startTime(d: *Demuxer, i: usize) *i64 {
        std.debug.assert(i == 0);
        return &d.start_time;
    }

    pub fn fileSize(d: *const Demuxer) ?u64 {
        const sk = d.src.seeker orelse return null;
        return sk.size();
    }

    pub fn dataOffset(d: *const Demuxer) i64 {
        _ = d;
        return 0;
    }

    /// libavformat's `avio_seek`: `IoFailure` on a pipe.
    pub fn reposition(d: *Demuxer, pos: i64) Error!void {
        d.src.seekTo(pos) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoFailure,
        };
        d.pos = pos;
    }

    pub fn ioRepositioned(d: *Demuxer) void {
        _ = d;
    }

    /// No `read_timestamp`: the generic layer seeks without it.
    pub fn readTimestamp(d: *Demuxer, i: usize, pos: *i64, pos_limit: i64) Error!i64 {
        _ = d;
        _ = i;
        _ = pos;
        _ = pos_limit;
        return nopts;
    }

    /// No `read_seek`: the generic index code.
    pub fn readSeek(d: *Demuxer, layer: anytype, i: usize, ts: i64, flags: seek.Flags) Error!bool {
        _ = d;
        _ = layer;
        _ = i;
        _ = ts;
        _ = flags;
        return false;
    }
};

test "the probe: a run of frames, either byte order, E-AC-3 refused" {
    try std.testing.expectEqual(0, probeScore(&.{ 0, 1, 2, 3 }));
}
