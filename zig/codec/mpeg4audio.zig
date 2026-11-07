// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/mpeg4audio.c (parse_config_ALS,
// ff_mpeg4audio_channels, get_object_type, get_sample_rate,
// ff_mpeg4audio_get_config_gb, avpriv_mpeg4audio_get_config2),
// mpeg4audio.h, mpeg4audio_sample_rates.h and mpeg4audio_copy_pce.h at the
// pinned reference revision.
// Copyright (c) 2008 Baptiste Coudurier <baptiste.coudurier@free.fr>
// Copyright (c) 2008 Alex Converse <alex.converse@gmail.com>
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! MPEG-4 audio configuration (TODO.md T30a): the AudioSpecificConfig
//! (ISO/IEC 14496-3) as FFmpeg reads it from extradata, for the ADTS muxer
//! and later MP4 (T33a) and the AAC decoder (T30b), and FFmpeg's copy of a
//! program config element (PCE). The fields keep FFmpeg's `int` values,
//! -1 included (SBR and PS signalled implicitly), so they compare with the
//! oracle (vectors/mpeg4audio.txt) as they are.

const std = @import("std");
const bits = @import("bits.zig");

/// `ff_mpeg4audio_sample_rates`: by sampling frequency index; 0 for the
/// reserved indexes 13 and 14 and the escape, 15.
pub const sample_rates = [16]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0, 0 };

/// `ff_mpeg4audio_channels`: the channels of each channel configuration
/// below 15 (0 for a PCE and the reserved ones).
pub const channel_counts = [15]u8{ 0, 1, 2, 3, 4, 5, 6, 8, 0, 0, 0, 7, 8, 24, 8 };

/// `enum AudioObjectType`, the values this file branches on.
pub const aot = struct {
    pub const null_type = 0;
    pub const aac_main = 1;
    pub const aac_lc = 2;
    pub const aac_ssr = 3;
    pub const aac_ltp = 4;
    pub const sbr = 5;
    pub const er_aac_lc = 17;
    pub const er_bsac = 22;
    pub const er_aac_ld = 23;
    pub const ps = 29;
    pub const escape = 31;
    pub const als = 36;
    pub const er_aac_eld = 39;
    pub const usac = 42;
};

/// `MPEG4AudioConfig`, FFmpeg's ints. A field the configuration does not
/// reach keeps its initial 0 (`ext_chan_config` outside BSAC, the frame
/// length of other object types).
pub const Config = struct {
    object_type: i32 = 0,
    sampling_index: i32 = 0,
    sample_rate: i32 = 0,
    chan_config: i32 = 0,
    /// -1 implicit, 0 absent, 1 present.
    sbr: i32 = 0,
    ext_object_type: i32 = 0,
    ext_sampling_index: i32 = 0,
    ext_sample_rate: i32 = 0,
    ext_chan_config: i32 = 0,
    channels: i32 = 0,
    /// -1 implicit, 0 absent, 1 present.
    ps: i32 = 0,
    frame_length_short: i32 = 0,
    frame_length: i32 = 0,
};

/// FFmpeg's AVERROR_INVALIDDATA: an invalid channel configuration, or an
/// ALS configuration that is short, unmarked or without a rate.
pub const Error = error{InvalidData};

/// The configuration and where it ends.
pub const Parsed = struct {
    config: Config,
    /// `avpriv_mpeg4audio_get_config2`'s result: the bits from the start
    /// to the end of the AudioSpecificConfig's common part, where the
    /// object type's specific config starts.
    specific_config_bit: usize,
};

/// `avpriv_mpeg4audio_get_config2` on extradata: the bytes past `bytes`,
/// which FFmpeg's padding holds, read as zeros. With `sync_extension`, the
/// bits after the configuration are searched for an SBR or PS sync
/// extension when none was signalled.
pub fn parse(bytes: []const u8, sync_extension: bool) Error!Parsed {
    if (bytes.len == 0) return error.InvalidData;
    var r = bits.BitReader.init(bytes) catch return error.InvalidData;
    return parseBits(&r, sync_extension);
}

/// `ff_mpeg4audio_get_config_gb`: the configuration from the reader's
/// position, the reader left after what it read.
pub fn parseBits(r: *bits.BitReader, sync_extension: bool) Error!Parsed {
    var c: Config = .{};
    const start = r.count();
    c.object_type = objectType(r);
    c.sample_rate = sampleRate(r, &c.sampling_index);
    c.chan_config = @intCast(r.bits(4));
    if (c.chan_config >= channel_counts.len) return error.InvalidData;
    c.channels = channel_counts[@intCast(c.chan_config)];
    c.sbr = -1;
    c.ps = -1;
    // An explicit SBR or PS, unless AOT 29 is shaped as W6132 Annex YYYY's
    // draft MP3onMP4.
    if (c.object_type == aot.sbr or (c.object_type == aot.ps and !(r.peek(3) & 0x03 != 0 and r.peek(9) & 0x3f == 0))) {
        if (c.object_type == aot.ps) c.ps = 1;
        c.ext_object_type = aot.sbr;
        c.sbr = 1;
        c.ext_sample_rate = sampleRate(r, &c.ext_sampling_index);
        c.object_type = objectType(r);
        if (c.object_type == aot.er_bsac) c.ext_chan_config = @intCast(r.bits(4));
    } else {
        c.ext_object_type = aot.null_type;
        c.ext_sample_rate = 0;
    }
    var specific = r.count();
    if (c.object_type == aot.als) {
        r.skip(5);
        // `show_bits(gb, 24) != MKBETAG('\0','A','L','S')`.
        if (r.peek(24) != 0x00414c53) r.skip(24);
        specific = r.count();
        try parseAls(r, &c);
    }
    switch (c.object_type) {
        aot.aac_main, aot.aac_lc, aot.aac_ssr, aot.aac_ltp, aot.er_aac_lc => {
            c.frame_length_short = r.bit();
            c.frame_length = if (c.frame_length_short != 0) 960 else 1024;
        },
        aot.er_aac_ld, aot.er_aac_eld => {
            c.frame_length_short = r.bit();
            c.frame_length = if (c.frame_length_short != 0) 480 else 512;
        },
        aot.usac => {
            // usacSamplingFrequencyIndex, and its escaped frequency.
            if (r.bits(5) == 0x1f) r.skip(24);
            const core_sbr_frame_len_idx = r.bits(3);
            c.frame_length_short = @intFromBool(core_sbr_frame_len_idx == 0 or core_sbr_frame_len_idx == 2);
            // FFmpeg's ratio for index 4 is 1, so its branch for 4 is
            // never taken.
            const sbr_ratio: u32 = switch (core_sbr_frame_len_idx) {
                2 => 2,
                3 => 3,
                4 => 1,
                else => 0,
            };
            const mult: i32, const dec: i32 = switch (sbr_ratio) {
                2 => .{ 8, 3 },
                3 => .{ 2, 1 },
                4 => .{ 4, 1 },
                else => .{ 1, 1 },
            };
            const frame_length: i32 = if (c.frame_length_short != 0) 768 else 1024;
            c.frame_length = @divTrunc(frame_length * mult, dec);
        },
        else => {},
    }
    if (c.ext_object_type != aot.sbr and sync_extension) {
        while (r.left() > 15) {
            if (r.peek(11) == 0x2b7) {
                r.skip(11);
                c.ext_object_type = objectType(r);
                if (c.ext_object_type == aot.sbr) {
                    c.sbr = r.bit();
                    if (c.sbr == 1) {
                        c.ext_sample_rate = sampleRate(r, &c.ext_sampling_index);
                        if (c.ext_sample_rate == c.sample_rate) c.sbr = -1;
                    }
                }
                if (r.left() > 11 and r.bits(11) == 0x548) c.ps = r.bit();
                break;
            }
            r.skip(1);
        }
    }
    // PS requires SBR, and implicit PS is limited to HE-AACv2 (LC, one
    // channel).
    if (c.sbr == 0) c.ps = 0;
    if ((c.ps == -1 and c.object_type != aot.aac_lc) or c.channels & ~@as(i32, 1) != 0) c.ps = 0;
    return .{ .config = c, .specific_config_bit = specific - start };
}

/// `get_object_type`: 5 bits, or 32 plus 6 more after the escape.
fn objectType(r: *bits.BitReader) i32 {
    const t: i32 = @intCast(r.bits(5));
    if (t != aot.escape) return t;
    const escaped: i32 = @intCast(r.bits(6));
    return 32 + escaped;
}

/// `get_sample_rate`: the index, and the table's rate or the escaped 24-bit
/// one.
fn sampleRate(r: *bits.BitReader, index: *i32) i32 {
    index.* = @intCast(r.bits(4));
    if (index.* == 0x0f) return @intCast(r.bits(24));
    return @intCast(sample_rates[@intCast(index.*)]);
}

/// `parse_config_ALS`: the ALS configuration's rate and channel count,
/// which override the AudioSpecificConfig's (old conformance files have
/// them wrong).
fn parseAls(r: *bits.BitReader, c: *Config) Error!void {
    if (r.left() < 112) return error.InvalidData;
    if (r.bits(32) != 0x414c5300) return error.InvalidData;
    c.sample_rate = @bitCast(r.bits(32));
    if (c.sample_rate <= 0) return error.InvalidData;
    r.skip(32);
    c.chan_config = 0;
    const channels: i32 = @intCast(r.bits(16));
    c.channels = channels + 1;
}

/// `ff_copy_pce_data`: the program config element at the reader's
/// position copied to the writer (the reader byte-aligned before the
/// comment, the writer too), as the ADTS muxer copies it after its ID_PCE
/// marker; returns the bits written.
pub fn copyPce(w: *bits.BitWriter, r: *bits.BitReader) usize {
    const offset = w.count();
    _ = copyBits(w, r, 10); // tag, object type, frequency
    var five_bit_ch = copyBits(w, r, 4); // front
    five_bit_ch += copyBits(w, r, 4); // side
    five_bit_ch += copyBits(w, r, 4); // back
    var four_bit_ch = copyBits(w, r, 2); // LFE
    four_bit_ch += copyBits(w, r, 3); // data
    five_bit_ch += copyBits(w, r, 4); // coupling
    if (copyBits(w, r, 1) != 0) _ = copyBits(w, r, 4); // mono mixdown
    if (copyBits(w, r, 1) != 0) _ = copyBits(w, r, 4); // stereo mixdown
    if (copyBits(w, r, 1) != 0) _ = copyBits(w, r, 3); // matrix mixdown
    var n = five_bit_ch * 5 + four_bit_ch * 4;
    while (n > 16) : (n -= 16) _ = copyBits(w, r, 16);
    if (n != 0) _ = copyBits(w, r, @intCast(n));
    // align_put_bits, align_get_bits.
    if (w.count() % 8 != 0) w.bits(@intCast(8 - w.count() % 8), 0);
    r.alignByte();
    var comment_size = copyBits(w, r, 8);
    while (comment_size > 0) : (comment_size -= 1) _ = copyBits(w, r, 8);
    return w.count() - offset;
}

/// `ff_pce_copy_bits`.
fn copyBits(w: *bits.BitWriter, r: *bits.BitReader, n: u6) u32 {
    const v = r.bits(n);
    w.bits(n, v);
    return v;
}

/// `MAX_PCE_SIZE`: a PCE with its 3-bit ID_PCE marker and comment.
pub const max_pce_size = 320;

const testing = std.testing;

test "every configuration parses as FFmpeg's avpriv_mpeg4audio_get_config2 parses it (vectors/mpeg4audio.txt)" {
    const vectors = @embedFile("../testing/vectors/mpeg4audio.txt");
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    var line = lines.next();
    while (line) |a_line| : (cases += 1) {
        if (a_line.len == 0) break;
        var f = std.mem.tokenizeScalar(u8, a_line, ' ');
        try testing.expectEqualStrings("A", f.next().?);
        const hex = f.next().?;
        var buf: [64]u8 = undefined;
        const bytes = if (std.mem.eql(u8, hex, "-")) buf[0..0] else try std.fmt.hexToBytes(&buf, hex);
        const sync = std.mem.eql(u8, f.next().?, "1");
        const result = f.next().?;
        line = lines.next();
        const got = parse(bytes, sync);
        if (std.mem.eql(u8, result, "INVALIDDATA")) {
            testing.expectError(error.InvalidData, got) catch |err| {
                std.debug.print("config {s} {}\n", .{ hex, sync });
                return err;
            };
            continue;
        }
        const parsed = got catch |err| {
            std.debug.print("config {s} {}\n", .{ hex, sync });
            return err;
        };
        try testing.expectEqual(try std.fmt.parseInt(usize, result, 10), parsed.specific_config_bit);
        var want = std.mem.tokenizeScalar(u8, line.?, ' ');
        try testing.expectEqualStrings("M", want.next().?);
        const c = parsed.config;
        const fields = [_]i32{ c.object_type, c.sampling_index, c.sample_rate, c.chan_config, c.sbr, c.ext_object_type, c.ext_sampling_index, c.ext_sample_rate, c.ext_chan_config, c.channels, c.ps, c.frame_length_short, c.frame_length };
        for (fields, 0..) |v, i| testing.expectEqual(try std.fmt.parseInt(i32, want.next().?, 10), v) catch |err| {
            std.debug.print("config {s} {}: field {d}\n", .{ hex, sync, i });
            return err;
        };
        line = lines.next();
    }
    try testing.expect(cases > 600);
}

test "a PCE is copied bit for bit, its comment byte-aligned" {
    // Element tag 1, profile 1, index 4; one front element, no side, back,
    // LFE, data or coupling; no mixdowns; a 2-byte comment.
    var src: [16]u8 = @splat(0);
    var sw: bits.BitWriter = .init(&src);
    sw.bits(10, 0x054);
    sw.bits(4, 1);
    sw.bits(4, 0);
    sw.bits(4, 0);
    sw.bits(2, 0);
    sw.bits(3, 0);
    sw.bits(4, 0);
    sw.bits(3, 0);
    sw.bits(5, 0x11); // the front element: is_cpe and tag
    sw.flush();
    sw.bits(8, 2);
    sw.bits(16, 0xabcd);
    sw.flush();
    var dst: [16]u8 = @splat(0);
    var w: bits.BitWriter = .init(&dst);
    w.bits(3, 5);
    var r = try bits.BitReader.init(sw.written());
    const n = copyPce(&w, &r);
    w.flush();
    // 39 bits of elements, 6 to align, then the comment's size and bytes.
    try testing.expectEqual(39 + 6 + 8 + 16, n);
    try testing.expectEqual(0xab, dst[w.written().len - 2]);
}
