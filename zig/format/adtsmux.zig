// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/adtsenc.c (adts_decode_extradata,
// adts_init, adts_write_frame_header, adts_write_packet) at the pinned
// reference revision.
// Copyright (c) 2006 Baptiste Coudurier <baptiste.coudurier@smartjog.com>
//                    Mans Rullgard <mans@mansr.com>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's ADTS muxer (`adts`, TODO.md T30a): raw AAC packets with the
//! stream's AudioSpecificConfig become ADTS frames, a 7-byte header before
//! each (and the configuration's PCE, once, before the first), as MP4's AAC
//! is written to an `.aac` file; without a configuration the packets are
//! written as they are (already ADTS). The `write_id3v2` and `write_apetag`
//! options are not ported (notes.md "ADTS muxer").

const std = @import("std");
const bits = @import("../codec/bits.zig");
const mpeg4audio = @import("../codec/mpeg4audio.zig");

pub const Options = struct {
    /// `write_mpeg2`: the header's ID bit says MPEG-2.
    write_mpeg2: bool = false,
};

/// FFmpeg's AVERROR_INVALIDDATA: a configuration ADTS cannot carry (an
/// object type past LTP, an escaped sampling rate, a channel configuration
/// past 7, a 960-sample frame, a scalable or extended configuration) or
/// one FFmpeg cannot parse, or a frame past `max_frame_bytes`.
pub const Error = error{InvalidData};

pub const WriteError = std.Io.Writer.Error || Error;

/// `ADTS_MAX_FRAME_BYTES`: one more than the 13-bit length field holds, so
/// lengths from 8192 spill into the field before it, as FFmpeg's
/// `put_bits` writes them unmasked.
pub const max_frame_bytes = (1 << 14) - 1;

const header_size = 7;

pub const Muxer = struct {
    out: *std.Io.Writer,
    mpeg_id: u1,
    /// A configuration was decoded: each packet gets a header.
    write_adts: bool = false,
    objecttype: u32 = 0,
    sample_rate_index: u32 = 0,
    channel_conf: u32 = 0,
    pce_data: [mpeg4audio.max_pce_size]u8 = @splat(0),
    /// The PCE's bytes not yet written (before the first frame only).
    pce_size: usize = 0,
    /// The stream has extradata (from `init` or a packet's side data).
    has_extradata: bool,

    /// adts_init: the stream's extradata, when it has any, decoded.
    pub fn init(out: *std.Io.Writer, extradata: []const u8, options: Options) Error!Muxer {
        var m: Muxer = .{ .out = out, .mpeg_id = @intFromBool(options.write_mpeg2), .has_extradata = extradata.len > 0 };
        if (extradata.len > 0) try m.decodeExtradata(extradata);
        return m;
    }

    /// adts_decode_extradata.
    fn decodeExtradata(m: *Muxer, buf: []const u8) Error!void {
        const parsed = mpeg4audio.parse(buf, true) catch return error.InvalidData;
        var r = bits.BitReader.init(buf) catch return error.InvalidData;
        r.skipLong(@intCast(parsed.specific_config_bit));
        const c = parsed.config;
        // `m4ac.object_type - 1` compared as unsigned: an object type of 0
        // wraps past 3 too.
        const objecttype: u32 = @bitCast(c.object_type - 1);
        m.objecttype = objecttype;
        m.sample_rate_index = @bitCast(c.sampling_index);
        m.channel_conf = @bitCast(c.chan_config);
        if (objecttype > 3) return error.InvalidData; // "MPEG-4 AOT %d is not allowed in ADTS"
        if (m.sample_rate_index == 15) return error.InvalidData; // "Escape sample rate index illegal in ADTS"
        if (m.channel_conf > 7) return error.InvalidData; // "channelConfiguration > 7 is not supported in ADTS"
        if (r.bit() != 0) return error.InvalidData; // "960/120 MDCT window is not allowed in ADTS"
        if (r.bit() != 0) return error.InvalidData; // "Scalable configurations are not allowed in ADTS"
        if (r.bit() != 0) return error.InvalidData; // "Extension flag is not allowed in ADTS"
        if (m.channel_conf == 0) {
            var w: bits.BitWriter = .init(&m.pce_data);
            w.bits(3, 5); // ID_PCE
            m.pce_size = (mpeg4audio.copyPce(&w, &r) + 3) / 8;
            w.flush();
        }
        m.write_adts = true;
    }

    /// adts_write_frame_header: the 7 bytes before a packet of `size`
    /// bytes; the 13-bit length takes `full`'s bits unmasked.
    fn frameHeader(m: *const Muxer, full: u32) [header_size]u8 {
        var acc: u64 = 0;
        const fields = [_]struct { u6, u64 }{
            .{ 12, 0xfff }, // syncword
            .{ 1, m.mpeg_id }, // ID
            .{ 2, 0 }, // layer
            .{ 1, 1 }, // protection_absent
            .{ 2, m.objecttype }, // profile_objecttype
            .{ 4, m.sample_rate_index },
            .{ 1, 0 }, // private_bit
            .{ 3, m.channel_conf }, // channel_configuration
            .{ 1, 0 }, // original_copy
            .{ 1, 0 }, // home
            .{ 1, 0 }, // copyright_identification_bit
            .{ 1, 0 }, // copyright_identification_start
            .{ 13, full }, // aac_frame_length
            .{ 11, 0x7ff }, // adts_buffer_fullness
            .{ 2, 0 }, // number_of_raw_data_blocks_in_frame
        };
        // put_bits ORs each value into the bits written so far, unmasked.
        for (fields) |f| acc = (acc << f[0]) | f[1];
        var out: [header_size]u8 = undefined;
        std.mem.writeInt(u56, &out, @truncate(acc), .big);
        return out;
    }

    /// adts_write_packet: an empty packet is skipped; a packet's new
    /// extradata (`AV_PKT_DATA_NEW_EXTRADATA`) is decoded while the stream
    /// has none; then the header, the PCE before the first frame, and the
    /// packet. Nothing is written for a refused packet.
    pub fn writePacket(m: *Muxer, data: []const u8, new_extradata: ?[]const u8) WriteError!void {
        if (data.len == 0) return;
        if (!m.has_extradata) {
            if (new_extradata) |side| if (side.len > 0) {
                try m.decodeExtradata(side);
                m.has_extradata = true;
            };
        }
        if (m.write_adts) {
            const full = std.math.add(u64, header_size + m.pce_size, data.len) catch return error.InvalidData;
            if (full > max_frame_bytes) return error.InvalidData; // "frame size too large"
            try m.out.writeAll(&m.frameHeader(@intCast(full)));
            if (m.pce_size > 0) {
                try m.out.writeAll(m.pce_data[0..m.pce_size]);
                m.pce_size = 0;
            }
        }
        try m.out.writeAll(data);
    }

    pub fn finish(m: *Muxer) std.Io.Writer.Error!void {
        try m.out.flush();
    }
};

const testing = std.testing;

test "every case muxes as FFmpeg's adts muxer muxes it (vectors/adtsmux.txt)" {
    const gpa = testing.allocator;
    const vectors = @embedFile("../testing/vectors/adtsmux.txt");
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    var line = lines.next();
    while (line) |c_line| {
        if (c_line.len == 0) break;
        var f = std.mem.tokenizeScalar(u8, c_line, ' ');
        try testing.expectEqualStrings("C", f.next().?);
        const name = f.next().?;
        var extra_buf: [64]u8 = undefined;
        const extra_hex = f.next().?;
        const extradata = if (std.mem.eql(u8, extra_hex, "-")) extra_buf[0..0] else try std.fmt.hexToBytes(&extra_buf, extra_hex);
        const mpeg2 = std.mem.eql(u8, f.next().?, "1");
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        errdefer std.debug.print("adtsmux case {s}\n", .{name});
        const header_line = lines.next().?;
        const opened = Muxer.init(&out.writer, extradata, .{ .write_mpeg2 = mpeg2 });
        line = lines.next();
        if (opened) |muxer| {
            var m = muxer;
            try testing.expectEqualStrings("H 0", header_line);
            while (line) |w_line| : (line = lines.next()) {
                if (!std.mem.startsWith(u8, w_line, "W ")) break;
                var w = std.mem.tokenizeScalar(u8, w_line, ' ');
                _ = w.next();
                const size = try std.fmt.parseInt(usize, w.next().?, 10);
                const side_hex = w.next().?;
                var side_buf: [64]u8 = undefined;
                const side = if (std.mem.eql(u8, side_hex, "-")) null else try std.fmt.hexToBytes(&side_buf, side_hex);
                const data = try gpa.alloc(u8, size);
                defer gpa.free(data);
                for (data, 0..) |*b, k| b.* = @truncate(k * 7 + size);
                const result = w.next().?;
                if (std.mem.eql(u8, result, "INVALIDDATA")) {
                    try testing.expectError(error.InvalidData, m.writePacket(data, side));
                } else {
                    try testing.expectEqualStrings("0", result);
                    try m.writePacket(data, side);
                }
            }
            try testing.expectEqualStrings("T 0", line.?);
            try m.finish();
            line = lines.next();
        } else |err| {
            try testing.expectEqual(error.InvalidData, err);
            try testing.expectEqualStrings("H INVALIDDATA", header_line);
        }
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(out.written(), &digest, .{});
        var o = std.mem.tokenizeScalar(u8, line.?, ' ');
        try testing.expectEqualStrings("O", o.next().?);
        try testing.expectEqual(try std.fmt.parseInt(usize, o.next().?, 10), out.written().len);
        try testing.expectEqualStrings(o.next().?, &std.fmt.bytesToHex(digest, .lower));
        line = lines.next();
        cases += 1;
    }
    try testing.expectEqual(23, cases);
}

const hostile = @import("../testing/hostile.zig");

/// Arbitrary extradata (as the stream's, or a first packet's side data,
/// the first value) and packet sizes (the rest): the configuration parsed
/// both ways, then the muxer on it; no input may panic, and a refused
/// packet writes nothing.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var config: [64]u8 = undefined;
    const len = smith.slice(&config);
    const extradata = config[0..len];
    for ([_]bool{ false, true }) |sync| {
        if (mpeg4audio.parse(extradata, sync)) |parsed| {
            try testing.expect(parsed.specific_config_bit <= len * 8 + 8);
        } else |_| {}
    }
    var out_buffer: [4 * max_frame_bytes]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buffer);
    const as_side = smith.value(bool);
    var m = Muxer.init(&out, if (as_side) &.{} else extradata, .{ .write_mpeg2 = smith.value(bool) }) catch return;
    var data: [max_frame_bytes + 2]u8 = @splat(0x21);
    for (0..3) |i| {
        const size = smith.valueRangeAtMost(u16, 0, data.len);
        const before = out.buffered().len;
        m.writePacket(data[0..size], if (as_side and i == 0) extradata else null) catch |err| switch (err) {
            error.InvalidData => {
                try testing.expectEqual(before, out.buffered().len);
                continue;
            },
            error.WriteFailed => return,
        };
    }
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(&.{ 0x12, 0x10 }, &.{ 0, 0, 200, 8185, 16377 }),
    hostile.fuzzSeed(&.{ 0x12, 0x00, 0x15, 0x04, 0x00, 0x00, 0x20, 0x03, 0x41, 0x42, 0x43 }, &.{ 1, 1, 100, 0, 16370 }),
    hostile.fuzzSeed(&.{ 0x12, 0x10, 0x56, 0xe5, 0x98 }, &.{ 0, 0, 90 }),
    hostile.fuzzSeed(&.{ 0xf8, 0x88, 0x40, 0x41, 0x4c, 0x53, 0x00, 0x00, 0x00, 0xbb, 0x80, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x05 }, &.{ 0, 0, 50 }),
    hostile.fuzzSeed(&.{ 0xf9, 0x46, 0x5f, 0x00, 0xac, 0x44, 0x60 }, &.{ 1, 0, 50 }),
};

test "fuzz: AudioSpecificConfig parsing and the ADTS muxer on arbitrary extradata and packet sizes" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: AudioSpecificConfig parsing and the ADTS muxer" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 256, 0x61647473);
}
