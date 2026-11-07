// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/ac3_parser.c (ff_ac3_find_syncword,
// ac3_parse_header, eac3_parse_header, ff_ac3_parse_header,
// av_ac3_parse_header, ac3_sync), ac3tab.c and ac3_channel_layout_tab.h at
// the pinned reference revision.
// Copyright (c) 2003 Fabrice Bellard
// Copyright (c) 2003 Michael Niedermayer
// Copyright (c) 2006 Justin Ruggles
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! AC-3 and E-AC-3 frame headers (TODO.md T32a), as FFmpeg's AC-3 parser,
//! demuxer probe and decoder read them: the sync word, the bit stream
//! information and the values derived from it (rate, bit rate, channels,
//! layout, frame size).

const std = @import("std");
const bits = @import("bits.zig");
const aac_ac3_parser = @import("aac_ac3_parser.zig");

/// AC3_HEADER_SIZE: the bytes the parser's sync reads.
pub const header_size = 7;

pub const sample_rate_tab = [4]u32{ 48000, 44100, 32000, 0 };
pub const bitrate_tab = [19]u32{ 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640 };
pub const channels_tab = [8]u8{ 2, 1, 2, 3, 3, 4, 4, 5 };

/// ff_ac3_frame_size_tab: 16-bit words a frame, by frame size code and
/// sample rate code.
pub const frame_size_tab = [38][3]u16{
    .{ 64, 69, 96 },       .{ 64, 70, 96 },       .{ 80, 87, 120 },      .{ 80, 88, 120 },
    .{ 96, 104, 144 },     .{ 96, 105, 144 },     .{ 112, 121, 168 },    .{ 112, 122, 168 },
    .{ 128, 139, 192 },    .{ 128, 140, 192 },    .{ 160, 174, 240 },    .{ 160, 175, 240 },
    .{ 192, 208, 288 },    .{ 192, 209, 288 },    .{ 224, 243, 336 },    .{ 224, 244, 336 },
    .{ 256, 278, 384 },    .{ 256, 279, 384 },    .{ 320, 348, 480 },    .{ 320, 349, 480 },
    .{ 384, 417, 576 },    .{ 384, 418, 576 },    .{ 448, 487, 672 },    .{ 448, 488, 672 },
    .{ 512, 557, 768 },    .{ 512, 558, 768 },    .{ 640, 696, 960 },    .{ 640, 697, 960 },
    .{ 768, 835, 1152 },   .{ 768, 836, 1152 },   .{ 896, 975, 1344 },   .{ 896, 976, 1344 },
    .{ 1024, 1114, 1536 }, .{ 1024, 1115, 1536 }, .{ 1152, 1253, 1728 }, .{ 1152, 1254, 1728 },
    .{ 1280, 1393, 1920 }, .{ 1280, 1394, 1920 },
};

/// FFmpeg's channel masks (AV_CH_*), as far as AC-3 names them.
pub const ch = struct {
    pub const front_left: u64 = 0x1;
    pub const front_right: u64 = 0x2;
    pub const front_center: u64 = 0x4;
    pub const low_frequency: u64 = 0x8;
    pub const back_left: u64 = 0x10;
    pub const back_right: u64 = 0x20;
    pub const front_left_of_center: u64 = 0x40;
    pub const front_right_of_center: u64 = 0x80;
    pub const back_center: u64 = 0x100;
    pub const side_left: u64 = 0x200;
    pub const side_right: u64 = 0x400;
    pub const top_center: u64 = 0x800;
    pub const top_front_left: u64 = 0x1000;
    pub const top_front_center: u64 = 0x2000;
    pub const top_front_right: u64 = 0x4000;
    pub const top_back_left: u64 = 0x8000;
    pub const top_back_right: u64 = 0x20000;
    pub const wide_left: u64 = 1 << 31;
    pub const wide_right: u64 = 1 << 32;
    pub const surround_direct_left: u64 = 1 << 33;
    pub const surround_direct_right: u64 = 1 << 34;
    pub const low_frequency_2: u64 = 1 << 35;
};

/// ff_ac3_channel_layout_tab, by channel mode (AC3_CHMODE_*).
pub const channel_layout_tab = [8]u64{
    ch.front_left | ch.front_right, // stereo (dual mono)
    ch.front_center, // mono
    ch.front_left | ch.front_right, // stereo
    ch.front_left | ch.front_right | ch.front_center, // surround
    ch.front_left | ch.front_right | ch.back_center, // 2.1
    ch.front_left | ch.front_right | ch.front_center | ch.back_center, // 4.0
    ch.front_left | ch.front_right | ch.side_left | ch.side_right, // 2.2
    ch.front_left | ch.front_right | ch.front_center | ch.side_left | ch.side_right, // 5.0
};

/// ff_eac3_custom_channel_map_locations: whether the decoder maps it, and
/// the location's channels.
pub const custom_channel_map_locations = [16][2]u64{
    .{ 1, ch.front_left },
    .{ 1, ch.front_center },
    .{ 1, ch.front_right },
    .{ 1, ch.side_left },
    .{ 1, ch.side_right },
    .{ 0, ch.front_left_of_center | ch.front_right_of_center },
    .{ 0, ch.back_left | ch.back_right },
    .{ 0, ch.back_center },
    .{ 0, ch.top_center },
    .{ 0, ch.surround_direct_left | ch.surround_direct_right },
    .{ 0, ch.wide_left | ch.wide_right },
    .{ 0, ch.top_front_left | ch.top_front_right },
    .{ 0, ch.top_front_center },
    .{ 0, ch.top_back_left | ch.top_back_right },
    .{ 0, ch.low_frequency_2 },
    .{ 1, ch.low_frequency },
};

pub const ChannelMode = struct {
    pub const dual_mono = 0;
    pub const mono = 1;
    pub const stereo = 2;
    pub const f3 = 3;
    pub const f2r1 = 4;
    pub const f3r1 = 5;
    pub const f2r2 = 6;
    pub const f3r2 = 7;
};

pub const FrameType = struct {
    pub const independent = 0;
    pub const dependent = 1;
    pub const ac3_convert = 2;
    pub const reserved = 3;
};

const eac3_blocks = [4]u8{ 1, 2, 3, 6 };
const center_levels = [4]u8{ 4, 5, 6, 5 };
const surround_levels = [4]u8{ 4, 6, 7, 6 };
const eac3_max_channels = 16;
const eac3_sr_code_reduced = 3;

/// AC3HeaderInfo.
pub const HeaderInfo = struct {
    sync_word: u16 = 0,
    crc1: u16 = 0,
    sr_code: u8 = 0,
    bitstream_id: u8 = 0,
    bitstream_mode: u8 = 0,
    channel_mode: u8 = 0,
    lfe_on: u8 = 0,
    frame_type: u8 = 0,
    substreamid: i32 = 0,
    center_mix_level: i32 = 0,
    surround_mix_level: i32 = 0,
    channel_map_present: u8 = 0,
    channel_map: u16 = 0,
    num_blocks: i32 = 0,
    dolby_surround_mode: i32 = 0,
    sr_shift: u8 = 0,
    sample_rate: u16 = 0,
    bit_rate: u32 = 0,
    channels: u8 = 0,
    frame_size: u16 = 0,
    channel_layout: u64 = 0,
    ac3_bit_rate_code: i8 = 0,
    dialog_normalization: [2]i8 = .{ 0, 0 },
    compression_exists: [2]u8 = .{ 0, 0 },
    heavy_dynamic_range: [2]u8 = .{ 0, 0 },
    center_mix_level_ltrt: u8 = 0,
    surround_mix_level_ltrt: u8 = 0,
    dolby_headphone_mode: u8 = 0,
    dolby_surround_ex_mode: u8 = 0,
    lfe_mix_level_exists: u8 = 0,
    lfe_mix_level: u8 = 0,
    preferred_downmix: u8 = 0,
    eac3_extension_type_a: u8 = 0,
    complexity_index_type_a: u8 = 0,
};

/// AC3ParseError.
pub const ParseError = error{ Sync, Bsid, SampleRate, FrameSize, FrameType, Crc, ChannelMap };

/// `av_clip(get_bits(gbc, 3), 3, 7)`.
fn clipped3(r: *bits.BitReader) u8 {
    return @intCast(std.math.clamp(r.bits(3), 3, 7));
}

fn ac3ParseRest(r: *bits.BitReader, hdr: *HeaderInfo) void {
    // The rest of the bsi, twice for dual mono.
    const passes: usize = if (hdr.channel_mode != 0) 1 else 2;
    for (0..passes) |i| {
        // `-get_bits(gbc, 5)` stored as int8_t.
        hdr.dialog_normalization[i] = -@as(i8, @intCast(r.bits(5)));
        hdr.compression_exists[i] = r.bit();
        if (hdr.compression_exists[i] != 0) hdr.heavy_dynamic_range[i] = @intCast(r.bits(8));
        if (r.bit() != 0) r.skip(8); // language code
        if (r.bit() != 0) r.skip(7); // audio production information
    }
    r.skip(2); // copyright and original bit stream bits
    if (hdr.bitstream_id != 6) {
        if (r.bit() != 0) r.skip(14); // timecode1
        if (r.bit() != 0) r.skip(14); // timecode2
    } else {
        if (r.bit() != 0) {
            hdr.preferred_downmix = @intCast(r.bits(2));
            hdr.center_mix_level_ltrt = @intCast(r.bits(3));
            hdr.surround_mix_level_ltrt = clipped3(r);
            hdr.center_mix_level = @intCast(r.bits(3));
            hdr.surround_mix_level = clipped3(r);
        }
        if (r.bit() != 0) {
            hdr.dolby_surround_ex_mode = @intCast(r.bits(2));
            hdr.dolby_headphone_mode = @intCast(r.bits(2));
            r.skip(10); // adconvtyp, xbsi2, encinfo
        }
    }
    // Additional bit stream information.
    if (r.bit() != 0) {
        var i = r.bits(6);
        while (true) {
            r.skip(8);
            if (i == 0) break;
            i -= 1;
        }
    }
}

fn eac3ParseRest(r: *bits.BitReader, hdr: *HeaderInfo) ParseError!void {
    if (hdr.frame_type == FrameType.reserved) return error.FrameType;
    if (hdr.substreamid != 0) return error.FrameType;
    r.skip(5); // bit stream id
    const passes: usize = if (hdr.channel_mode != 0) 1 else 2;
    for (0..passes) |i| {
        hdr.dialog_normalization[i] = -@as(i8, @intCast(r.bits(5)));
        hdr.compression_exists[i] = r.bit();
        if (hdr.compression_exists[i] != 0) hdr.heavy_dynamic_range[i] = @intCast(r.bits(8));
    }
    // Dependent stream channel map.
    if (hdr.frame_type == FrameType.dependent) {
        hdr.channel_map_present = r.bit();
        if (hdr.channel_map_present != 0) {
            var layout: u64 = 0;
            const map = r.bits(16);
            for (0..16) |i| {
                if (map & (@as(u32, 1) << @intCast(eac3_max_channels - i - 1)) != 0) layout |= custom_channel_map_locations[i][1];
            }
            if (@popCount(layout) > eac3_max_channels) return error.ChannelMap;
            hdr.channel_map = @intCast(map);
        }
    }
    // Mixing metadata.
    if (r.bit() != 0) {
        if (hdr.channel_mode > ChannelMode.stereo) {
            hdr.preferred_downmix = @intCast(r.bits(2));
            if (hdr.channel_mode & 1 != 0) {
                hdr.center_mix_level_ltrt = @intCast(r.bits(3));
                hdr.center_mix_level = @intCast(r.bits(3));
            }
            if (hdr.channel_mode & 4 != 0) {
                hdr.surround_mix_level_ltrt = clipped3(r);
                hdr.surround_mix_level = clipped3(r);
            }
        }
        if (hdr.lfe_on != 0) {
            hdr.lfe_mix_level_exists = r.bit();
            if (hdr.lfe_mix_level_exists != 0) hdr.lfe_mix_level = @intCast(r.bits(5));
        }
        if (hdr.frame_type == FrameType.independent) {
            for (0..passes) |_| {
                if (r.bit() != 0) r.skip(6); // program scale factor
            }
            if (r.bit() != 0) r.skip(6); // external program scale factor
            switch (r.bits(2)) {
                1 => r.skip(5),
                2 => r.skip(12),
                3 => r.skipLong((@as(i64, r.bits(5)) + 2) << 3),
                else => {},
            }
            if (hdr.channel_mode < ChannelMode.stereo) {
                for (0..passes) |_| {
                    if (r.bit() != 0) r.skip(14); // pan mean direction index, reserved bits
                }
            }
            if (r.bit() != 0) {
                var i: i32 = 0;
                while (i < hdr.num_blocks) : (i += 1) {
                    if (hdr.num_blocks == 1 or r.bit() != 0) r.skip(5);
                }
            }
        }
    }
    // Informational metadata.
    if (r.bit() != 0) {
        hdr.bitstream_mode = @intCast(r.bits(3));
        r.skip(2);
        if (hdr.channel_mode == ChannelMode.stereo) {
            hdr.dolby_surround_mode = @intCast(r.bits(2));
            hdr.dolby_headphone_mode = @intCast(r.bits(2));
        }
        if (hdr.channel_mode >= ChannelMode.f2r2) hdr.dolby_surround_ex_mode = @intCast(r.bits(2));
        for (0..passes) |_| {
            if (r.bit() != 0) r.skip(8);
        }
        if (hdr.sr_code != eac3_sr_code_reduced) r.skip(1);
    }
    if (hdr.frame_type == FrameType.independent and hdr.num_blocks != 6) r.skip(1);
    if (hdr.frame_type == FrameType.ac3_convert and (hdr.num_blocks == 6 or r.bit() != 0)) r.skip(6);
    // Additional bit stream information.
    if (r.bit() != 0) {
        const addbsil = r.bits(6);
        var i: u32 = 0;
        while (i < addbsil + 1) : (i += 1) {
            if (i == 0) {
                r.skip(7);
                hdr.eac3_extension_type_a = r.bit();
                if (hdr.eac3_extension_type_a != 0) {
                    hdr.complexity_index_type_a = @intCast(r.bits(8));
                    i += 1;
                }
            } else r.skip(8);
        }
    }
}

/// ff_ac3_parse_header.
pub fn parseHeader(r: *bits.BitReader) ParseError!HeaderInfo {
    var hdr: HeaderInfo = .{};
    hdr.sync_word = @intCast(r.bits(16));
    if (hdr.sync_word != 0x0B77) return error.Sync;
    // Read ahead to bsid to tell AC-3 from E-AC-3.
    hdr.bitstream_id = @intCast(r.peek(29) & 0x1F);
    if (hdr.bitstream_id > 16) return error.Bsid;
    hdr.num_blocks = 6;
    hdr.ac3_bit_rate_code = -1;
    hdr.center_mix_level = 5; // -4.5 dB
    hdr.surround_mix_level = 6; // -6.0 dB
    hdr.dolby_surround_mode = 0; // AC3_DSURMOD_NOTINDICATED
    if (hdr.bitstream_id <= 10) {
        hdr.crc1 = @intCast(r.bits(16));
        hdr.sr_code = @intCast(r.bits(2));
        if (hdr.sr_code == 3) return error.SampleRate;
        const frame_size_code = r.bits(6);
        if (frame_size_code > 37) return error.FrameSize;
        hdr.ac3_bit_rate_code = @intCast(frame_size_code >> 1);
        r.skip(5); // bsid, already read
        hdr.bitstream_mode = @intCast(r.bits(3));
        hdr.channel_mode = @intCast(r.bits(3));
        if (hdr.channel_mode == ChannelMode.stereo) {
            hdr.dolby_surround_mode = @intCast(r.bits(2));
        } else {
            if (hdr.channel_mode & 1 != 0 and hdr.channel_mode != ChannelMode.mono) hdr.center_mix_level = center_levels[r.bits(2)];
            if (hdr.channel_mode & 4 != 0) hdr.surround_mix_level = surround_levels[r.bits(2)];
        }
        hdr.lfe_on = r.bit();
        hdr.sr_shift = @max(hdr.bitstream_id, 8) - 8;
        hdr.sample_rate = @intCast(sample_rate_tab[hdr.sr_code] >> @intCast(hdr.sr_shift));
        hdr.bit_rate = (bitrate_tab[@intCast(hdr.ac3_bit_rate_code)] * 1000) >> @intCast(hdr.sr_shift);
        hdr.channels = channels_tab[hdr.channel_mode] + hdr.lfe_on;
        hdr.frame_size = frame_size_tab[frame_size_code][hdr.sr_code] * 2;
        hdr.frame_type = FrameType.ac3_convert;
        hdr.substreamid = 0;
        ac3ParseRest(r, &hdr);
    } else {
        hdr.crc1 = 0;
        hdr.frame_type = @intCast(r.bits(2));
        if (hdr.frame_type == FrameType.reserved) return error.FrameType;
        hdr.substreamid = @intCast(r.bits(3));
        hdr.frame_size = @intCast((r.bits(11) + 1) << 1);
        if (hdr.frame_size < header_size) return error.FrameSize;
        hdr.sr_code = @intCast(r.bits(2));
        if (hdr.sr_code == 3) {
            const sr_code2 = r.bits(2);
            if (sr_code2 == 3) return error.SampleRate;
            hdr.sample_rate = @intCast(sample_rate_tab[sr_code2] / 2);
            hdr.sr_shift = 1;
        } else {
            hdr.num_blocks = eac3_blocks[r.bits(2)];
            hdr.sample_rate = @intCast(sample_rate_tab[hdr.sr_code]);
            hdr.sr_shift = 0;
        }
        hdr.channel_mode = @intCast(r.bits(3));
        hdr.lfe_on = r.bit();
        // `8LL * frame_size * sample_rate / (num_blocks * 256)`: at most
        // 8 * 4096 * 48000 / 256, which fits the uint32_t.
        hdr.bit_rate = @intCast(@as(u64, 8) * hdr.frame_size * hdr.sample_rate / (@as(u64, @intCast(hdr.num_blocks)) * 256));
        hdr.channels = channels_tab[hdr.channel_mode] + hdr.lfe_on;
        try eac3ParseRest(r, &hdr);
    }
    hdr.channel_layout = channel_layout_tab[hdr.channel_mode];
    if (hdr.lfe_on != 0) hdr.channel_layout |= ch.low_frequency;
    return hdr;
}

/// `avpriv_ac3_parse_header`: the header at the start of `buf`.
pub fn parseHeaderBuf(buf: []const u8) ParseError!HeaderInfo {
    var r = bits.BitReader.init(buf) catch return error.Sync;
    return parseHeader(&r);
}

/// `av_ac3_parse_header`: at most the first 32 bytes, zero-padded.
pub fn parseHeaderShort(buf: []const u8) ParseError!HeaderInfo {
    var tmp: [32 + 64]u8 = @splat(0);
    const size = @min(32, buf.len);
    @memcpy(tmp[0..size], buf[0..size]);
    var r = bits.BitReader.initIn(&tmp, size) catch unreachable; // 32 bytes
    return parseHeader(&r);
}

/// ff_ac3_find_syncword: the offset of the first sync word, either byte
/// order, in `buf`; null when there is none.
pub fn findSyncword(buf: []const u8) ?usize {
    var i: usize = 1;
    while (i < buf.len) : (i += 2) {
        if (buf[i] == 0x77 or buf[i] == 0x0B) {
            if ((buf[i] ^ buf[i - 1]) == (0x77 ^ 0x0B)) return i - 1;
            // `buf[i + 1]` past the end reads FFmpeg's zero padding.
            const next: u8 = if (i + 1 < buf.len) buf[i + 1] else 0;
            if ((buf[i] ^ next) == (0x77 ^ 0x0B)) return i;
        }
    }
    return null;
}

/// ac3_sync: the header in the last 7 bytes of `state` (byte-swapped when
/// the sync word is), read as FFmpeg's 54-bit reader over its zero
/// padding.
pub fn sync(state: u64) ?aac_ac3_parser.Sync {
    var tmp: [8 + 64]u8 = @splat(0);
    std.mem.writeInt(u64, tmp[0..8], state, .big);
    if (tmp[1] == 0x77 and tmp[2] == 0x0b) {
        std.mem.swap(u8, &tmp[1], &tmp[2]);
        std.mem.swap(u8, &tmp[3], &tmp[4]);
        std.mem.swap(u8, &tmp[5], &tmp[6]);
    }
    // init_get_bits(&gbc, tmp + 8 - 7, 54): reads past 54 bits see the
    // bytes after it, zeros here.
    var r: bits.BitReader = .{ .bytes = tmp[8 - header_size ..], .size = 54 };
    const hdr = parseHeader(&r) catch return null;
    const new_frame_start = hdr.frame_type != FrameType.dependent;
    return .{
        .frame_size = hdr.frame_size,
        .new_frame_start = new_frame_start,
        .need_next_header = new_frame_start or hdr.frame_type != FrameType.ac3_convert,
    };
}

/// What the AC-3 parser sets in libavformat's codec context.
pub const ParserContext = struct {
    /// `avctx->sample_rate`, 0 until a frame's header and CRC check out.
    sample_rate: u32 = 0,
    /// `avctx->codec_id` became AV_CODEC_ID_EAC3 (a bit stream id above 10).
    eac3: bool = false,
    /// `avctx->ch_layout`: the header's mask (never 0: every channel mode
    /// names a layout), set on every checked frame, as the reference build
    /// has no E-AC-3 decoder.
    channel_layout: u64 = 0,
    channels: u8 = 0,
    /// `avctx->audio_service_type`.
    audio_service_type: u8 = 0,
    /// `avctx->bit_rate`: the running average of the frames' bit rates.
    bit_rate: i64 = 0,
};

/// FFmpeg's AC-3 parser (`ff_aac_ac3_parse` with `ac3_sync`),
/// `PARSER_FLAG_COMPLETE_FRAMES` off, as the reference build compiles it
/// (`CONFIG_EAC3_DECODER` 0).
pub const Parser = struct {
    splitter: aac_ac3_parser.Splitter(header_size, sync) = .{},
    /// The frames whose header and CRC checked out; an int.
    frame_number: i32 = 0,
    /// `s1->duration`: the last checked frame's samples, kept until the
    /// next one (the parser context's field outlives a call).
    duration: u32 = 0,

    pub fn deinit(p: *Parser, gpa: std.mem.Allocator) void {
        p.splitter.deinit(gpa);
        p.* = undefined;
    }

    pub const Result = struct {
        /// The parser's index, as `aac_ac3_parser.Splitter.Step.index`.
        index: i64,
        /// A frame, valid until the next call; null when none is complete.
        frame: ?[]const u8,
    };

    /// One call: `buf` (empty at the end) scanned for frame starts.
    pub fn parse(p: *Parser, gpa: std.mem.Allocator, ctx: *ParserContext, buf: []const u8) std.mem.Allocator.Error!Result {
        const step = try p.splitter.split(gpa, buf);
        const frame = step.frame orelse return .{ .index = step.index, .frame = null };
        if (step.got_frame) p.update(ctx, frame);
        return .{ .index = step.index, .frame = frame };
    }

    /// The got_frame branch: the frame's last header, the frames before it
    /// skipped, its CRC checked, then the codec context.
    fn update(p: *Parser, ctx: *ParserContext, frame: []const u8) void {
        const offset = findSyncword(frame) orelse return;
        var rest = frame[offset..];
        var hdr: HeaderInfo = undefined;
        while (rest.len > 0) {
            hdr = parseHeaderBuf(rest) catch return;
            if (hdr.frame_size > rest.len) return;
            if (rest.len > hdr.frame_size) {
                rest = rest[hdr.frame_size..];
                continue;
            }
            // False positives: the sync word alone is not enough (A/52
            // 6.1.2).
            if (bits.Crc16.hash(rest[2..hdr.frame_size]) != 0) return;
            break;
        }
        // `rest` was not empty: `offset` is inside the frame.
        ctx.sample_rate = hdr.sample_rate;
        if (hdr.bitstream_id > 10) ctx.eac3 = true;
        ctx.channel_layout = hdr.channel_layout;
        ctx.channels = hdr.channels;
        p.duration = @intCast(hdr.num_blocks * 256);
        ctx.audio_service_type = hdr.bitstream_mode;
        // AV_AUDIO_SERVICE_TYPE_KARAOKE.
        if (hdr.bitstream_mode == 0x7 and hdr.channels > 1) ctx.audio_service_type = 8;
        p.frame_number +%= 1;
        if (p.frame_number != 0) ctx.bit_rate += @divTrunc(@as(i64, hdr.bit_rate) - ctx.bit_rate, p.frame_number);
    }
};

const testing = std.testing;

test "the sync search, either byte order" {
    try testing.expectEqual(0, findSyncword(&.{ 0x0b, 0x77, 0, 0 }));
    try testing.expectEqual(1, findSyncword(&.{ 0, 0x0b, 0x77, 0 }));
    try testing.expectEqual(2, findSyncword(&.{ 0, 0, 0x77, 0x0b }));
    try testing.expectEqual(null, findSyncword(&.{ 0, 1, 2, 3 }));
}
