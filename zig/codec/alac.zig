// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/alac.c (decode_scalar, rice_decompress,
// lpc_prediction, decode_element, alac_decode_frame, alac_set_info and
// alac_decode_init), alacdsp.c (decorrelate_stereo, append_extra_bits),
// alacenc.c (the whole encoder) and alac_data.c (the channel tables) at the
// pinned reference revision.
// Copyright (c) 2005 David Hammerton (the ALAC decoder)
// Copyright (c) 2008 Jaikrishnan Menon (the ALAC encoder)
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's ALAC (Apple Lossless) decoder and encoder (TODO.md T31b): the
//! 36-byte magic cookie, the frame's SCE, CPE and LFE elements with their
//! adaptive Rice codes, zero runs, adaptive LPC, stereo decorrelation and
//! extra low bits, sample for sample as FFmpeg's decoder gives them; and
//! FFmpeg's encoder, packet for packet, with its compression levels and
//! prediction orders. The C's signed overflows wrap here, as the reference
//! build's do (notes.md "Undefined C behavior").

const std = @import("std");
const bits = @import("bits.zig");
const lpc = @import("lpc.zig");
const options_zig = @import("../core/options.zig");
const audio = @import("../core/audio.zig");

pub const max_channels = 8;

/// `AlacRawDataBlockType`: the frame's element types.
pub const Element = enum(u3) { sce = 0, cpe = 1, cce = 2, lfe = 3, dse = 4, pce = 5, fil = 6, end = 7 };

/// `ff_alac_channel_layout_offsets`: each element channel's output plane.
pub const channel_layout_offsets = [max_channels][max_channels]u8{
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 0, 0, 0, 0, 0 },
    .{ 2, 0, 1, 3, 0, 0, 0, 0 },
    .{ 2, 0, 1, 3, 4, 0, 0, 0 },
    .{ 2, 0, 1, 4, 5, 3, 0, 0 },
    .{ 2, 0, 1, 4, 5, 6, 3, 0 },
    .{ 2, 6, 7, 0, 1, 4, 5, 3 },
};

/// `ff_alac_channel_elements`: the encoder's elements for each count.
pub const channel_elements = [max_channels][]const Element{
    &.{.sce},
    &.{.cpe},
    &.{ .sce, .cpe },
    &.{ .sce, .cpe, .sce },
    &.{ .sce, .cpe, .cpe },
    &.{ .sce, .cpe, .cpe, .sce },
    &.{ .sce, .cpe, .cpe, .sce, .sce },
    &.{ .sce, .cpe, .cpe, .cpe, .sce },
};

/// `ff_alac_ch_layouts`, as native channel masks: mono, stereo, 3.0, 4.0,
/// 5.0(side), 5.1(side), 6.1(back) and 7.1(wide-side) by FFmpeg's names
/// (AV_CHANNEL_LAYOUT_5POINT0_BACK and so on).
pub const channel_masks = [max_channels]u64{
    0x4, // FC
    0x3, // FL FR
    0x7, // FL FR FC
    0x107, // FL FR FC BC
    0x37, // FL FR FC BL BR
    0x3f, // FL FR FC LFE BL BR
    0x13f, // FL FR FC LFE BL BR BC
    0xff, // FL FR FC LFE BL BR FLC FRC
};

/// Bytes of the magic cookie (`ALAC_EXTRADATA_SIZE`).
pub const cookie_len = 36;

/// The stream's parameters from its magic cookie (`alac_set_info`).
pub const Config = struct {
    max_samples_per_frame: u32,
    sample_size: u8,
    rice_history_mult: u8,
    rice_initial_history: u8,
    rice_limit: u8,
    channels: u8,
    sample_rate: u32,

    /// Decoder parameters after the cookie's channel fallback. Container
    /// timestamps keep their own time base, even when this rate differs.
    pub fn format(c: Config) audio.Format {
        return .{
            .sample_rate = c.sample_rate,
            .layout = .{ .native = channel_masks[c.channels - 1] },
            .sample_format = if (c.sample_size > 16) .s32p else .s16p,
        };
    }

    pub const Error = error{
        /// "extradata is too small", "max samples per frame invalid", no
        /// channels in the cookie or the container.
        InvalidData,
        /// AVERROR_PATCHWELCOME: a sample size other than 16, 20, 24 or 32,
        /// more than 8 channels, or a rate outside a positive C int.
        Unsupported,
    };

    /// alac_decode_init's reading of `cookie`; `container_channels` is the
    /// container's count, for a cookie that gives none.
    pub fn parse(cookie: []const u8, container_channels: u32) Error!Config {
        if (cookie.len < cookie_len) return error.InvalidData;
        const max = std.mem.readInt(u32, cookie[12..16], .big);
        if (max == 0 or max > 4096 * 4096) return error.InvalidData;
        var c: Config = .{
            .max_samples_per_frame = max,
            .sample_size = cookie[17],
            .rice_history_mult = cookie[18],
            .rice_initial_history = cookie[19],
            .rice_limit = cookie[20],
            .channels = cookie[21],
            .sample_rate = std.mem.readInt(u32, cookie[32..36], .big),
        };
        switch (c.sample_size) {
            16, 20, 24, 32 => {},
            else => return error.Unsupported,
        }
        if (c.channels < 1) {
            // "Invalid channel count": the container's, when it has one.
            if (container_channels < 1) return error.InvalidData;
            c.channels = std.math.cast(u8, container_channels) orelse return error.Unsupported;
        }
        if (c.channels > max_channels) return error.Unsupported;
        // avctx's sample rate is a signed int; avcodec_open2 refuses a
        // cookie that would store a negative value there.
        if (c.sample_rate > std.math.maxInt(i32)) return error.Unsupported;
        return c;
    }
};

pub const DecodeError = error{
    /// AVERROR_INVALIDDATA: a malformed frame.
    InvalidData,
    /// AVERROR_PATCHWELCOME: an element type or sample width FFmpeg's
    /// decoder does not decode.
    Unsupported,
    /// AVERROR(ENOSYS): a compressed element under a rice limit of 0.
    RiceLimitZero,
    OutOfMemory,
};

/// A decoded frame: each channel's samples, as FFmpeg's planes hold them
/// (s16p values for 16 bits, s32p for 20, 24 and 32: the samples shifted
/// to the top). Borrowed from the decoder until its next frame.
pub const Frame = struct {
    planes: []const []const i32,
    samples: u32,
};

/// FFmpeg's ALAC decoder for one stream.
pub const Decoder = struct {
    gpa: std.mem.Allocator,
    config: Config,
    /// The `extra_bits_bug` option: the extra bits before the stereo
    /// decorrelation.
    extra_bit_bug: bool = false,
    /// The decoder's work buffers and the frame's planes, grown to the
    /// largest frame decoded (FFmpeg allocates `max_samples_per_frame`).
    predict_error: [2][]i32 = .{ &.{}, &.{} },
    output: [2][]i32 = .{ &.{}, &.{} },
    extra_bits_buffer: [2][]i32 = .{ &.{}, &.{} },
    plane_storage: [max_channels][]i32 = @splat(&.{}),
    capacity: usize = 0,
    planes: [max_channels][]const i32 = undefined,

    pub fn init(gpa: std.mem.Allocator, config: Config) Decoder {
        return .{ .gpa = gpa, .config = config };
    }

    pub fn deinit(d: *Decoder) void {
        for (0..2) |c| {
            d.gpa.free(d.predict_error[c]);
            d.gpa.free(d.output[c]);
            d.gpa.free(d.extra_bits_buffer[c]);
        }
        for (&d.plane_storage) |p| d.gpa.free(p);
        d.* = undefined;
    }

    /// Room for frames of `n` samples.
    fn reserve(d: *Decoder, n: usize) error{OutOfMemory}!void {
        if (n <= d.capacity) return;
        for (0..2) |c| {
            for ([_]*[]i32{ &d.predict_error[c], &d.output[c], &d.extra_bits_buffer[c] }) |buf| {
                const grown = try d.gpa.alloc(i32, n);
                d.gpa.free(buf.*);
                buf.* = grown;
            }
        }
        for (0..d.config.channels) |c| {
            const grown = try d.gpa.alloc(i32, n);
            d.gpa.free(d.plane_storage[c]);
            d.plane_storage[c] = grown;
        }
        d.capacity = n;
    }

    /// alac_decode_frame: the frame `packet` holds, or null when its
    /// elements do not give every channel ("Failed to decode all
    /// channels"). The decoder always takes the whole packet.
    pub fn decode(d: *Decoder, packet: []const u8) DecodeError!?Frame {
        var gb = bits.BitReader.init(packet) catch return error.InvalidData;
        var nb_samples: u32 = 0;
        var ch: u32 = 0;
        const channels_total = d.config.channels;
        var got_end = false;
        while (gb.left() >= 3) {
            const element: Element = @fromBackingInt(@intCast(gb.bits(3)));
            if (element == .end) {
                got_end = true;
                break;
            }
            if (@backingInt(element) > @backingInt(Element.cpe) and element != .lfe) return error.Unsupported; // "Syntax element %d"
            const channels: u32 = if (element == .cpe) 2 else 1;
            if (ch + channels > channels_total) return error.InvalidData; // "invalid element channel count"
            const offset = channel_layout_offsets[channels_total - 1][ch];
            if (offset + channels > channels_total) return error.InvalidData;
            d.decodeElement(&gb, &nb_samples, offset, channels) catch |err| {
                // An element that fails exactly at the end of the packet
                // is ignored, as FFmpeg's decoder ignores it.
                if (err == error.OutOfMemory or gb.left() != 0) return err;
            };
            ch += channels;
        }
        if (!got_end) return error.InvalidData; // "no end tag found. incomplete packet."
        if (ch != channels_total or nb_samples == 0) return null;
        for (0..channels_total) |c| d.planes[c] = d.plane_storage[c][0..nb_samples];
        return .{ .planes = d.planes[0..channels_total], .samples = nb_samples };
    }

    fn decodeElement(d: *Decoder, gb: *bits.BitReader, nb_samples: *u32, ch_index: u32, channels: u32) DecodeError!void {
        const cfg = d.config;
        gb.skip(4); // element instance tag
        gb.skip(12); // unused header bits
        const has_size = gb.bit() == 1;
        var extra_bits: u32 = gb.bits(2) << 3;
        const bps_signed = @as(i32, cfg.sample_size) - @as(i32, @intCast(extra_bits)) + @as(i32, @intCast(channels)) - 1;
        if (bps_signed > 32) return error.Unsupported; // "bps %d"
        if (bps_signed < 1) return error.InvalidData;
        const bps: u6 = @intCast(bps_signed);
        const is_compressed = gb.bit() == 0;
        const output_samples: u32 = if (has_size) gb.bits(32) else cfg.max_samples_per_frame;
        if (output_samples == 0 or output_samples > cfg.max_samples_per_frame) return error.InvalidData; // "invalid samples per frame"
        if (nb_samples.* == 0) {
            // The frame's buffer: FFmpeg's is uninitialized, zeros here
            // (notes.md "ALAC").
            try d.reserve(output_samples);
            for (0..cfg.channels) |c| @memset(d.plane_storage[c][0..output_samples], 0);
        } else if (output_samples != nb_samples.*) return error.InvalidData; // "sample count mismatch"
        nb_samples.* = output_samples;
        const n: usize = output_samples;
        // Above 16 bits FFmpeg decodes into the frame's planes directly.
        const direct = cfg.sample_size > 16;
        var out: [2][]i32 = undefined;
        for (0..channels) |c| out[c] = if (direct) d.plane_storage[ch_index + c] else d.output[c];

        var decorr_shift: u32 = 0;
        var decorr_left_weight: u32 = 0;
        if (is_compressed) {
            var lpc_coefs: [2][32]i16 = undefined;
            var lpc_order: [2]u32 = undefined;
            var prediction_type: [2]u32 = undefined;
            var lpc_quant: [2]u32 = undefined;
            var rice_history_mult: [2]u32 = undefined;
            if (cfg.rice_limit == 0) return error.RiceLimitZero; // "Compression with rice limit 0"
            decorr_shift = gb.bits(8);
            decorr_left_weight = gb.bits(8);
            if (channels == 2 and decorr_left_weight != 0 and decorr_shift > 31) return error.InvalidData;
            for (0..channels) |c| {
                prediction_type[c] = gb.bits(4);
                lpc_quant[c] = gb.bits(4);
                rice_history_mult[c] = gb.bits(3);
                lpc_order[c] = gb.bits(5);
                if (lpc_order[c] >= cfg.max_samples_per_frame or lpc_quant[c] == 0) return error.InvalidData;
                var i = lpc_order[c];
                while (i > 0) {
                    i -= 1;
                    lpc_coefs[c][i] = @truncate(gb.signed(16));
                }
            }
            if (extra_bits != 0) {
                const need = @as(i64, @intCast(n)) * channels * extra_bits;
                if (gb.left() < need) return error.InvalidData;
                for (0..n) |i| {
                    for (0..channels) |c| d.extra_bits_buffer[c][i] = @bitCast(gb.bits(@intCast(extra_bits)));
                }
            }
            for (0..channels) |c| {
                try riceDecompress(gb, cfg, d.predict_error[c][0..n], bps, rice_history_mult[c] * cfg.rice_history_mult / 4);
                if (prediction_type[c] == 15) {
                    // Two passes: first the special-case order 31, in place.
                    lpcPrediction(d.predict_error[c][0..n], d.predict_error[c][0..n], bps, &.{}, 31, 0);
                }
                // Another type: "unknown prediction type", decoded anyway.
                lpcPrediction(d.predict_error[c][0..n], out[c][0..n], bps, lpc_coefs[c][0..lpc_order[c]], lpc_order[c], lpc_quant[c]);
            }
        } else {
            const sample_size: u6 = @intCast(cfg.sample_size);
            const need = @as(i64, @intCast(n)) * channels * sample_size;
            if (gb.left() < need) return error.InvalidData;
            for (0..n) |i| {
                for (0..channels) |c| out[c][i] = gb.signed(sample_size);
            }
            extra_bits = 0;
            decorr_shift = 0;
            decorr_left_weight = 0;
        }

        if (channels == 2) {
            if (extra_bits != 0 and d.extra_bit_bug) appendExtraBits(out[0..2], d.extra_bits_buffer[0..2], extra_bits, n);
            if (decorr_left_weight != 0) decorrelateStereo(out[0][0..n], out[1][0..n], decorr_shift, decorr_left_weight);
            if (extra_bits != 0 and !d.extra_bit_bug) appendExtraBits(out[0..2], d.extra_bits_buffer[0..2], extra_bits, n);
        } else if (extra_bits != 0) {
            appendExtraBits(out[0..1], d.extra_bits_buffer[0..1], extra_bits, n);
        }

        switch (cfg.sample_size) {
            16 => for (0..channels) |c| {
                const plane = d.plane_storage[ch_index + c];
                // Stored as int16_t.
                for (0..n) |i| plane[i] = @as(i16, @truncate(out[c][i]));
            },
            20 => for (0..channels) |c| {
                for (out[c][0..n]) |*v| v.* = @bitCast(@as(u32, @bitCast(v.*)) << 12);
            },
            24 => for (0..channels) |c| {
                for (out[c][0..n]) |*v| v.* = @bitCast(@as(u32, @bitCast(v.*)) << 8);
            },
            else => {},
        }
    }
};

/// `av_log2`: the index of the highest set bit, 0 for 0.
fn log2(v: u32) u32 {
    return if (v == 0) 0 else 31 - @clz(v);
}

/// decode_scalar: a unary count of up to 9 ones; past 8, `bps` bits
/// verbatim; else `k` more bits fold in.
fn decodeScalar(gb: *bits.BitReader, k: u32, bps: u6) u32 {
    var x: u32 = @intCast(gb.unary(0, 9));
    if (x > 8) {
        x = gb.bits(bps);
    } else if (k != 1) {
        const kk: u6 = @intCast(k);
        const extrabits = gb.peek(kk);
        // "multiply x by 2^k - 1, as part of their strange algorithm".
        x = (x << @intCast(k)) -% x;
        if (extrabits > 1) {
            x +%= extrabits - 1;
            gb.skip(k);
        } else gb.skip(k - 1);
    }
    return x;
}

/// rice_decompress: `out.len` residuals, with the runs of zeros.
fn riceDecompress(gb: *bits.BitReader, cfg: Config, out: []i32, bps: u6, rice_history_mult: u32) DecodeError!void {
    const nb_samples = out.len;
    var history: u32 = cfg.rice_initial_history;
    var sign_modifier: u32 = 0;
    var i: usize = 0;
    while (i < nb_samples) : (i += 1) {
        if (gb.left() <= 0) return error.InvalidData;
        var k = log2((history >> 9) + 3);
        k = @min(k, cfg.rice_limit);
        var x = decodeScalar(gb, k, bps);
        x +%= sign_modifier;
        sign_modifier = 0;
        out[i] = @bitCast((x >> 1) ^ (0 -% (x & 1)));
        if (x > 0xffff) {
            history = 0xffff;
        } else {
            history = history +% x *% rice_history_mult -% ((history *% rice_history_mult) >> 9);
        }
        // "special case: there may be compressed blocks of 0".
        if (history < 128 and i + 1 < nb_samples) {
            k = 7 - log2(history) + ((history + 16) >> 6);
            k = @min(k, cfg.rice_limit);
            var block_size: i64 = @as(i32, @bitCast(decodeScalar(gb, k, 16)));
            if (block_size > 0) {
                if (block_size >= nb_samples - i) {
                    // "invalid zero block size"
                    block_size = @intCast(nb_samples - i - 1);
                }
                const run: usize = @intCast(block_size);
                @memset(out[i + 1 ..][0..run], 0);
                i += run;
            }
            if (block_size <= 0xffff) sign_modifier = 1;
            history = 0;
        }
    }
}

/// `sign_extend`: the low `bps` bits as a signed value.
fn signExtend(v: u32, bps: u6) i32 {
    const shift: u5 = @intCast(32 - @as(u7, bps));
    return @as(i32, @bitCast(v << shift)) >> shift;
}

fn signOnly(v: i32) i32 {
    return @as(i32, @intFromBool(v > 0)) - @intFromBool(v < 0);
}

/// lpc_prediction: the samples from the residuals, adapting the
/// coefficients sample by sample. `error_buffer` and `buffer_out` may be
/// the same (order 31). FFmpeg's unsigned arithmetic wraps.
fn lpcPrediction(error_buffer: []const i32, buffer_out: []i32, bps: u6, coefs_in: []const i16, lpc_order: u32, lpc_quant: u32) void {
    const nb_samples = buffer_out.len;
    var coefs: [32]i16 = undefined;
    @memcpy(coefs[0..coefs_in.len], coefs_in);
    // First sample always copies.
    buffer_out[0] = error_buffer[0];
    if (nb_samples <= 1) return;
    if (lpc_order == 0) {
        @memcpy(buffer_out[1..nb_samples], error_buffer[1..nb_samples]);
        return;
    }
    if (lpc_order == 31) {
        for (1..nb_samples) |i| buffer_out[i] = signExtend(@as(u32, @bitCast(buffer_out[i - 1])) +% @as(u32, @bitCast(error_buffer[i])), bps);
        return;
    }
    // Warm-up samples.
    var i: usize = 1;
    while (i <= lpc_order and i < nb_samples) : (i += 1) {
        buffer_out[i] = signExtend(@as(u32, @bitCast(buffer_out[i - 1])) +% @as(u32, @bitCast(error_buffer[i])), bps);
    }
    var pred: usize = 0;
    while (i < nb_samples) : (i += 1) {
        var error_val: u32 = @bitCast(error_buffer[i]);
        const d: i32 = buffer_out[pred];
        pred += 1;
        const p = buffer_out[pred..];
        var val: u32 = 0;
        for (0..lpc_order) |j| {
            const diff = @as(u32, @bitCast(p[j])) -% @as(u32, @bitCast(d));
            val +%= diff *% @as(u32, @bitCast(@as(i32, coefs[j])));
        }
        // `(val + (1LL << (lpc_quant - 1))) >> lpc_quant`, back to an int.
        const rounded: i64 = (@as(i64, @as(i32, @bitCast(val))) + (@as(i64, 1) << @intCast(lpc_quant - 1))) >> @intCast(lpc_quant);
        var v: u32 = @bitCast(@as(i32, @truncate(rounded)));
        v +%= @as(u32, @bitCast(d)) +% error_val;
        buffer_out[i] = signExtend(v, bps);
        // Adapt the coefficients.
        const error_sign = signOnly(@bitCast(error_val));
        if (error_sign != 0) {
            var j: usize = 0;
            while (j < lpc_order and @as(i32, @bitCast(error_val *% @as(u32, @bitCast(error_sign)))) > 0) : (j += 1) {
                var dv: i32 = @bitCast(@as(u32, @bitCast(d)) -% @as(u32, @bitCast(p[j])));
                const sign = signOnly(dv) * error_sign;
                coefs[j] = @truncate(@as(i32, coefs[j]) - sign);
                dv = @bitCast(@as(u32, @bitCast(dv)) *% @as(u32, @bitCast(sign)));
                error_val -%= @as(u32, @bitCast(dv >> @intCast(lpc_quant))) *% @as(u32, @intCast(j + 1));
            }
        }
    }
}

/// decorrelate_stereo.
fn decorrelateStereo(left: []i32, right: []i32, shift: u32, weight: u32) void {
    for (left, right) |*l, *r| {
        var a: u32 = @bitCast(l.*);
        var b: u32 = @bitCast(r.*);
        const prod: i32 = @bitCast(b *% weight);
        a -%= @bitCast(prod >> @intCast(shift));
        b +%= a;
        l.* = @bitCast(b);
        r.* = @bitCast(a);
    }
}

/// append_extra_bits.
fn appendExtraBits(buffer: []const []i32, extra: []const []i32, extra_bits: u32, n: usize) void {
    for (buffer, extra) |b, e| {
        for (0..n) |i| b[i] = @bitCast((@as(u32, @bitCast(b[i])) << @intCast(extra_bits)) | @as(u32, @bitCast(e[i])));
    }
}

// ---- Encoding ----

/// `DEFAULT_FRAME_SIZE`: the samples a channel of every frame but the last.
pub const frame_size = 4096;
const max_lpc_order = 30;
const max_lpc_precision = 9;
const escape_code = 0x1FF;

/// The encoder's options, as FFmpeg's ints: the codec context's
/// `compression_level` (-1 for the default, 2) and the private
/// `min_prediction_order` and `max_prediction_order` (1 to 30).
pub const EncodeOptions = struct {
    compression_level: i32 = -1,
    min_prediction_order: i32 = 4,
    max_prediction_order: i32 = 6,

    pub const Error = error{
        /// "invalid prediction orders", or an order outside 1 to 30 (the
        /// options' range).
        InvalidOption,
    };

    pub const option_specs = [_]options_zig.Spec{
        .{ .name = "min_prediction_order", .field = "min_prediction_order", .kind = .int, .help = "", .min = lpc.min_order, .max = max_lpc_order },
        .{ .name = "max_prediction_order", .field = "max_prediction_order", .kind = .int, .help = "", .min = lpc.min_order, .max = max_lpc_order },
    };
};

/// FFmpeg's ALAC encoder for one stream of 1 to 8 channels at 16 bits
/// (s16p input) or 24 (s32p input, the top 24 bits).
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    channels: u32,
    /// 16 or 24: `bits_per_raw_sample`.
    bits_per_sample: u32,
    sample_rate: u32,
    compression_level: u32,
    min_order: u32,
    max_order: u32,
    max_coded_frame_size: u32,
    lpc_ctx: lpc.Context,

    // Per-frame state (`AlacEncodeContext`).
    frame_len: u32 = frame_size,
    verbatim: bool = false,
    extra_bits: u32 = 0,
    write_sample_size: u6 = 0,
    interlacing_shift: u32 = 0,
    interlacing_leftweight: u32 = 0,
    /// Zeroed, as FFmpeg's context: a short frame's warm-up reads past it.
    sample_buf: [2][frame_size]i32 = @splat(@splat(0)),
    predictor_buf: [2][frame_size]i32 = @splat(@splat(0)),
    lpc_state: [2]LpcParams = undefined,

    const history_mult = 40;
    const initial_history = 10;
    const k_modifier = 14;
    const rice_modifier = 4;

    const LpcParams = struct {
        order: u32,
        coeff: [max_lpc_order + 1]i32,
        quant: u32,
    };

    /// alac_encode_init: `bits_per_sample` 16 (s16p) or 24 (s32p).
    pub fn create(gpa: std.mem.Allocator, channels: u32, bits_per_sample: u32, sample_rate: u32, options: EncodeOptions) (EncodeOptions.Error || error{OutOfMemory})!*Encoder {
        std.debug.assert(channels >= 1 and channels <= max_channels);
        std.debug.assert(bits_per_sample == 16 or bits_per_sample == 24);
        const in_range = struct {
            fn f(v: i32) bool {
                return v >= lpc.min_order and v <= max_lpc_order;
            }
        }.f;
        if (!in_range(options.min_prediction_order) or !in_range(options.max_prediction_order)) return error.InvalidOption;
        if (options.max_prediction_order < options.min_prediction_order) return error.InvalidOption; // "invalid prediction orders"
        const level: u32 = if (options.compression_level == -1) 2 else @intCast(std.math.clamp(options.compression_level, 0, 2));
        const e = try gpa.create(Encoder);
        errdefer gpa.destroy(e);
        const ctx: lpc.Context = try .init(gpa, frame_size);
        e.* = .{
            .gpa = gpa,
            .channels = channels,
            .bits_per_sample = bits_per_sample,
            .sample_rate = sample_rate,
            .compression_level = level,
            .min_order = @intCast(options.min_prediction_order),
            .max_order = @intCast(options.max_prediction_order),
            .max_coded_frame_size = maxFrameSize(frame_size, channels, bits_per_sample),
            .lpc_ctx = ctx,
        };
        return e;
    }

    pub fn destroy(e: *Encoder) void {
        e.lpc_ctx.deinit(e.gpa);
        e.gpa.destroy(e);
    }

    /// The magic cookie the encoder writes (`extradata`).
    pub fn cookie(e: *const Encoder) [cookie_len]u8 {
        var out: [cookie_len]u8 = @splat(0);
        std.mem.writeInt(u32, out[0..4], cookie_len, .big);
        out[4..8].* = "alac".*;
        std.mem.writeInt(u32, out[12..16], frame_size, .big);
        out[17] = @intCast(e.bits_per_sample);
        out[21] = @intCast(e.channels);
        std.mem.writeInt(u32, out[24..28], e.max_coded_frame_size, .big);
        // The average bit rate, in FFmpeg's int arithmetic.
        std.mem.writeInt(u32, out[28..32], e.sample_rate *% e.channels *% e.bits_per_sample, .big);
        std.mem.writeInt(u32, out[32..36], e.sample_rate, .big);
        if (e.compression_level > 0) {
            out[18] = history_mult;
            out[19] = initial_history;
            out[20] = k_modifier;
        }
        return out;
    }

    /// The largest packet `encode` writes for frames of `n` samples.
    pub fn maxPacket(e: *const Encoder, n: u32) usize {
        return 4 * @as(usize, maxFrameSize(n, e.channels, e.bits_per_sample));
    }

    /// alac_encode_frame: one frame of `n` samples a channel (at most
    /// `frame_size`; fewer only for the last), `planes` in FFmpeg's input
    /// format (s16 values for 16 bits, s32 for 24), into `out` (at least
    /// `maxPacket(n)` bytes); returns the packet.
    pub fn encode(e: *Encoder, planes: []const []const i32, n: u32, out: []u8) []u8 {
        std.debug.assert(n >= 1 and n <= frame_size and planes.len == e.channels);
        e.frame_len = n;
        const max_frame = if (n < frame_size) maxFrameSize(n, e.channels, e.bits_per_sample) else e.max_coded_frame_size;
        std.debug.assert(out.len >= 4 * @as(usize, max_frame));
        if (e.compression_level != 0) {
            e.verbatim = false;
            e.extra_bits = e.bits_per_sample - 16;
        } else {
            e.verbatim = true;
            e.extra_bits = 0;
        }
        var len = e.writeFrame(planes, out);
        if (len > max_frame) {
            // "frame too large. use verbatim mode".
            e.verbatim = true;
            e.extra_bits = 0;
            len = e.writeFrame(planes, out);
        }
        return out[0..len];
    }

    fn writeFrame(e: *Encoder, planes: []const []const i32, out: []u8) usize {
        var pb: bits.BitWriter = .init(out);
        const elements = channel_elements[e.channels - 1];
        const map = channel_layout_offsets[e.channels - 1];
        var ch: usize = 0;
        var element: usize = 0;
        var sce: u32 = 0;
        var cpe: u32 = 0;
        while (ch < e.channels) {
            if (elements[element] == .cpe) {
                e.writeElement(&pb, .cpe, cpe, &.{ planes[map[ch]], planes[map[ch + 1]] });
                cpe += 1;
                ch += 2;
            } else {
                e.writeElement(&pb, .sce, sce, &.{planes[map[ch]]});
                sce += 1;
                ch += 1;
            }
            element += 1;
        }
        pb.bits(3, @backingInt(Element.end));
        pb.flush();
        std.debug.assert(!pb.overflow);
        return pb.written().len;
    }

    fn writeElementHeader(e: *Encoder, pb: *bits.BitWriter, element: Element, instance: u32) void {
        const encode_fs = e.frame_len < frame_size;
        pb.bits(3, @backingInt(element));
        pb.bits(4, instance);
        pb.bits(12, 0);
        pb.bits(1, @intFromBool(encode_fs));
        pb.bits(2, e.extra_bits >> 3);
        pb.bits(1, @intFromBool(e.verbatim));
        if (encode_fs) pb.bits(32, e.frame_len);
    }

    fn writeElement(e: *Encoder, pb: *bits.BitWriter, element: Element, instance: u32, samples: []const []const i32) void {
        const channels = samples.len;
        const n = e.frame_len;
        // FFmpeg's input shift: s32p holds 24 bits at the top.
        const shift: u5 = if (e.bits_per_sample == 24) 8 else 0;
        if (e.verbatim) {
            e.writeElementHeader(pb, element, instance);
            // Channel-interleaved.
            for (0..n) |i| {
                for (0..channels) |j| pb.signed(@intCast(e.bits_per_sample), samples[j][i] >> shift);
            }
            return;
        }
        e.write_sample_size = @intCast(e.bits_per_sample - e.extra_bits + channels - 1);
        // init_sample_buffers.
        for (0..channels) |c| {
            for (0..n) |i| e.sample_buf[c][i] = samples[c][i] >> shift;
        }
        e.writeElementHeader(pb, element, instance);
        if (e.extra_bits != 0) {
            const mask = (@as(u32, 1) << @intCast(e.extra_bits)) - 1;
            for (0..channels) |c| {
                for (0..n) |i| {
                    e.predictor_buf[c][i] = @bitCast(@as(u32, @bitCast(e.sample_buf[c][i])) & mask);
                    e.sample_buf[c][i] >>= @intCast(e.extra_bits);
                }
            }
        }
        if (channels == 2) {
            e.stereoDecorrelation();
        } else {
            e.interlacing_shift = 0;
            e.interlacing_leftweight = 0;
        }
        pb.bits(8, e.interlacing_shift);
        pb.bits(8, e.interlacing_leftweight);
        const prediction_type = 0;
        for (0..channels) |c| {
            e.calcPredictorParams(c);
            pb.bits(4, prediction_type);
            pb.bits(4, e.lpc_state[c].quant);
            pb.bits(3, rice_modifier);
            pb.bits(5, e.lpc_state[c].order);
            for (0..e.lpc_state[c].order) |j| pb.signed(16, e.lpc_state[c].coeff[j]);
        }
        if (e.extra_bits != 0) {
            for (0..n) |i| {
                for (0..channels) |c| pb.bits(@intCast(e.extra_bits), @as(u32, @bitCast(e.predictor_buf[c][i])));
            }
        }
        for (0..channels) |c| {
            e.linearPredictor(c);
            e.entropyCoder(pb, c);
        }
    }

    fn calcPredictorParams(e: *Encoder, c: usize) void {
        const state = &e.lpc_state[c];
        if (e.compression_level == 1) {
            state.order = 6;
            state.quant = 6;
            state.coeff[0..6].* = .{ 160, -190, 170, -130, 80, -25 };
            return;
        }
        var coefs: lpc.Coefs = undefined;
        var shift: [lpc.max_order]i32 = undefined;
        const opt_order = e.lpc_ctx.calcCoefs(e.sample_buf[c][0..e.frame_len], e.min_order, e.max_order, max_lpc_precision, &coefs, &shift, .levinson, 0, .estimation, 0, 9, 1);
        state.order = @intCast(opt_order);
        state.quant = @intCast(shift[opt_order - 1]);
        @memcpy(state.coeff[0..opt_order], coefs[opt_order - 1][0..opt_order]);
    }

    /// estimate_stereo_mode, then the chosen decorrelation.
    fn stereoDecorrelation(e: *Encoder) void {
        const n = e.frame_len;
        const left = e.sample_buf[0][0..n];
        const right = e.sample_buf[1][0..n];
        var sum: [4]u64 = @splat(0);
        var i: usize = 2;
        while (i < n) : (i += 1) {
            const lt = left[i] -% 2 *% left[i - 1] +% left[i - 2];
            const rt = right[i] -% 2 *% right[i - 1] +% right[i - 2];
            sum[2] +%= @abs((lt +% rt) >> 1);
            sum[3] +%= @abs(lt -% rt);
            sum[0] +%= @abs(lt);
            sum[1] +%= @abs(rt);
        }
        const score = [4]u64{ sum[0] +% sum[1], sum[0] +% sum[3], sum[1] +% sum[3], sum[2] +% sum[3] };
        var best: usize = 0;
        for (1..4) |m| {
            if (score[m] < score[best]) best = m;
        }
        switch (best) {
            0 => {
                e.interlacing_leftweight = 0;
                e.interlacing_shift = 0;
            },
            1 => {
                for (left, right) |l, *r| r.* = l -% r.*;
                e.interlacing_leftweight = 1;
                e.interlacing_shift = 0;
            },
            2 => {
                for (left, right) |*l, *r| {
                    const tmp = r.*;
                    r.* = l.* -% r.*;
                    l.* = tmp +% (r.* >> 31);
                }
                e.interlacing_leftweight = 1;
                e.interlacing_shift = 31;
            },
            else => {
                for (left, right) |*l, *r| {
                    const tmp = l.*;
                    l.* = (tmp +% r.*) >> 1;
                    r.* = tmp -% r.*;
                }
                e.interlacing_leftweight = 1;
                e.interlacing_shift = 1;
            },
        }
    }

    /// alac_linear_predictor: the residuals of channel `c`, adapting a
    /// copy of its coefficients.
    fn linearPredictor(e: *Encoder, c: usize) void {
        var state = e.lpc_state[c];
        const residual = e.predictor_buf[c][0..];
        const samples_all = e.sample_buf[c][0..];
        const n = e.frame_len;
        const wss = e.write_sample_size;
        if (state.order == 31) {
            residual[0] = samples_all[0];
            for (1..n) |i| residual[i] = samples_all[i] -% samples_all[i - 1];
            return;
        }
        if (state.order == 0) return;
        const order = state.order;
        // Warm-up samples; past a short frame they read the buffer's stale
        // samples, which nothing encodes.
        residual[0] = samples_all[0];
        var i: usize = 1;
        while (i <= order) : (i += 1) {
            if (i >= frame_size) break;
            residual[i] = signExtend(@bitCast(samples_all[i] -% samples_all[i - 1]), wss);
        }
        var base: usize = 0;
        i = order + 1;
        while (i < n) : (i += 1) {
            const samples = samples_all[base..];
            // `1 << (lpc_quant - 1)`: a shift of 0 (coefficients past 255,
            // at high orders) shifts by -1, which x86 takes mod 32: 1 << 31
            // (notes.md "Undefined C behavior").
            var sum: i32 = @bitCast(@as(u32, 1) << @as(u5, @truncate(state.quant -% 1)));
            for (0..order) |j| sum +%= (samples[order - j] -% samples[0]) *% state.coeff[j];
            sum >>= @intCast(state.quant);
            sum +%= samples[0];
            residual[i] = signExtend(@bitCast(samples[order + 1] -% sum), wss);
            var res_val = residual[i];
            if (res_val != 0) {
                var index: i32 = @as(i32, @intCast(order)) - 1;
                const neg = res_val < 0;
                while (index >= 0 and (if (neg) res_val < 0 else res_val > 0)) {
                    const idx: usize = @intCast(index);
                    var val = samples[0] -% samples[order - idx];
                    var sign: i32 = if (val != 0) (if (val > 0) 1 else -1) else 0;
                    if (neg) sign *= -1;
                    state.coeff[idx] -%= sign;
                    val *%= sign;
                    res_val -%= (val >> @intCast(state.quant)) *% @as(i32, @intCast(order - idx));
                    index -= 1;
                }
            }
            base += 1;
        }
    }

    /// alac_entropy_coder for channel `c`.
    fn entropyCoder(e: *Encoder, pb: *bits.BitWriter, c: usize) void {
        var history: u32 = initial_history;
        var sign_modifier: i32 = 0;
        const samples = e.predictor_buf[c][0..e.frame_len];
        var i: usize = 0;
        while (i < samples.len) {
            var k = log2((history >> 9) + 3);
            var x: i32 = -2 *% samples[i] -% 1;
            x ^= x >> 31;
            i += 1;
            e.encodeScalar(pb, x - sign_modifier, k, e.write_sample_size);
            history = history +% @as(u32, @bitCast(x *% history_mult)) -% ((history *% history_mult) >> 9);
            sign_modifier = 0;
            if (x > 0xFFFF) history = 0xFFFF;
            if (history < 128 and i < samples.len) {
                var block_size: u32 = 0;
                k = 7 - log2(history) + ((history + 16) >> 6);
                while (i < samples.len and samples[i] == 0) {
                    i += 1;
                    block_size += 1;
                }
                e.encodeScalar(pb, @intCast(block_size), k, 16);
                sign_modifier = @intFromBool(block_size <= 0xFFFF);
                history = 0;
            }
        }
    }

    /// encode_scalar.
    fn encodeScalar(e: *Encoder, pb: *bits.BitWriter, x: i32, k_in: u32, write_sample_size: u6) void {
        _ = e;
        const k: u5 = @min(k_in, k_modifier);
        const divisor: i32 = (@as(i32, 1) << k) - 1;
        const q = @divTrunc(x, divisor);
        const r = @rem(x, divisor);
        if (q > 8) {
            // The escape code, then the value.
            pb.bits(9, escape_code);
            pb.bits(write_sample_size, @as(u32, @bitCast(x)) & lowMask(write_sample_size));
        } else {
            std.debug.assert(q >= 0);
            if (q != 0) pb.bits(@intCast(q), (@as(u32, 1) << @intCast(q)) - 1);
            pb.bits(1, 0);
            if (k != 1) {
                if (r > 0) pb.bits(k, @intCast(r + 1)) else pb.bits(k - 1, 0);
            }
        }
    }
};

fn lowMask(n: u6) u64 {
    return if (n >= 32) 0xffff_ffff else (@as(u64, 1) << n) - 1;
}

/// get_max_frame_size: a frame's bytes when every sample is verbatim.
fn maxFrameSize(n: u32, channels: u32, bps: u32) u32 {
    const header_bits: u32 = 23 + 32 * @as(u32, @intFromBool(n < frame_size));
    return (header_bits + bps * channels * n + 3 + 7) / 8;
}

const testing = std.testing;

const signals = @import("../testing/signals.zig");
const Rng = signals.Rng;

fn decodeLine(w: *std.Io.Writer, d: *Decoder, packet: []const u8) !void {
    const frame = d.decode(packet) catch |err| {
        try w.print("D {s} 0 -\n", .{resultName(err)});
        return;
    } orelse {
        try w.writeAll("D EAGAIN 0 -\n");
        return;
    };
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (frame.planes) |plane| {
        for (plane) |v| {
            if (d.config.sample_size == 16) {
                var b: [2]u8 = undefined;
                std.mem.writeInt(i16, &b, @intCast(v), .little);
                md5.update(&b);
            } else {
                var b: [4]u8 = undefined;
                std.mem.writeInt(i32, &b, v, .little);
                md5.update(&b);
            }
        }
    }
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    try w.print("D 0 {d} {x}\n", .{ frame.samples, &digest });
}

fn resultName(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidData => "INVALIDDATA",
        error.Unsupported => "PATCHWELCOME",
        error.RiceLimitZero => "ENOSYS",
        else => @errorName(err),
    };
}

const TestCase = struct { name: []const u8, signal: []const u8, channels: u32, bps: u32, level: i32, min: i32, max: i32, samples: u32 };

/// Renders vectors/alac.txt from the port: the encoder's packets and the
/// decoder's samples for alac_vectors.c's cases.
fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer, expected: []const u8) !void {
    var cases: std.ArrayList(TestCase) = .empty;
    defer cases.deinit(gpa);
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "E ")) continue;
        var f = std.mem.tokenizeScalar(u8, line[2..], ' ');
        try cases.append(gpa, .{
            .name = f.next().?,
            .signal = f.next().?,
            .channels = try std.fmt.parseInt(u32, f.next().?, 10),
            .bps = try std.fmt.parseInt(u32, f.next().?, 10),
            .level = try std.fmt.parseInt(i32, f.next().?, 10),
            .min = try std.fmt.parseInt(i32, f.next().?, 10),
            .max = try std.fmt.parseInt(i32, f.next().?, 10),
            .samples = try std.fmt.parseInt(u32, f.next().?, 10),
        });
    }
    const Stored = struct { cookie: [cookie_len]u8 = undefined, packets: [8][]u8 = undefined, count: usize = 0 };
    const stored = try gpa.alloc(Stored, cases.items.len);
    defer {
        for (stored) |s| for (s.packets[0..s.count]) |p| gpa.free(p);
        gpa.free(stored);
    }
    @memset(stored, .{});
    for (cases.items, 0..) |t, k| {
        try w.print("E {s} {s} {d} {d} {d} {d} {d} {d}\n", .{ t.name, t.signal, t.channels, t.bps, t.level, t.min, t.max, t.samples });
        const e = Encoder.create(gpa, t.channels, t.bps, 44100, .{ .compression_level = t.level, .min_prediction_order = t.min, .max_prediction_order = t.max }) catch |err| switch (err) {
            error.InvalidOption => {
                try w.writeAll("O EINVAL\n");
                continue;
            },
            else => |other| return other,
        };
        defer e.destroy();
        const cookie = e.cookie();
        try w.print("O ok\nI {x}\n", .{&cookie});
        stored[k].cookie = cookie;
        var d: Decoder = .init(gpa, try Config.parse(&cookie, t.channels));
        defer d.deinit();
        var rng: Rng = .{ .state = 0x9E3779B9 ^ (t.channels *% 1000003 +% t.samples +% t.bps * 7 +% @as(u32, @intCast(k))) };
        var state: [8]i32 = @splat(0);
        var plane_storage: [8][frame_size]i32 = undefined;
        var planes: [8][]const i32 = undefined;
        const out = try gpa.alloc(u8, e.maxPacket(frame_size));
        defer gpa.free(out);
        var at: u32 = 0;
        while (at < t.samples) {
            const n = @min(t.samples - at, frame_size);
            for (0..n) |i| {
                for (0..t.channels) |c| {
                    const v = signals.sample(&rng, t.signal, c, at + i, &state, t.bps);
                    plane_storage[c][i] = if (t.bps == 16) v else @bitCast(@as(u32, @bitCast(v)) << 8);
                }
            }
            for (0..t.channels) |c| planes[c] = plane_storage[c][0..n];
            const packet = e.encode(planes[0..t.channels], n, out);
            var digest: [16]u8 = undefined;
            std.crypto.hash.Md5.hash(packet, &digest, .{});
            try w.print("P {d} {x}\n", .{ packet.len, &digest });
            try decodeLine(w, &d, packet);
            if (stored[k].count < 8) {
                stored[k].packets[stored[k].count] = try gpa.dupe(u8, packet);
                stored[k].count += 1;
            }
            at += n;
        }
    }
    // The decoder cases: the M lines, replayed.
    lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "M ")) continue;
        var f = std.mem.tokenizeScalar(u8, line[2..], ' ');
        const name = f.next().?;
        const size = try std.fmt.parseInt(u8, f.next().?, 10);
        const bug = try std.fmt.parseInt(u8, f.next().?, 10) == 1;
        const index = try std.fmt.parseInt(usize, f.next().?, 10);
        const seed = try std.fmt.parseInt(u32, f.next().?, 10);
        const flips = try std.fmt.parseInt(u32, f.next().?, 10);
        const cut = try std.fmt.parseInt(i64, f.next().?, 10);
        try w.print("{s}\n", .{line});
        const k = for (cases.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, name)) break i;
        } else return error.TestUnexpectedResult;
        var cookie = stored[k].cookie;
        if (size != 0) cookie[17] = size;
        const data = try gpa.dupe(u8, stored[k].packets[index]);
        defer gpa.free(data);
        var rng: Rng = .{ .state = seed };
        for (0..flips) |_| {
            const bit = rng.next() % @as(u32, @intCast(data.len * 8));
            data[bit / 8] ^= @as(u8, 0x80) >> @intCast(bit % 8);
        }
        const len: usize = if (cut >= 0 and cut < data.len) @intCast(cut) else data.len;
        const config = Config.parse(&cookie, cases.items[k].channels) catch |err| {
            try w.print("D {s} 0 -\n", .{resultName(err)});
            continue;
        };
        var d: Decoder = .init(gpa, config);
        defer d.deinit();
        d.extra_bit_bug = bug;
        try decodeLine(w, &d, data[0..len]);
    }
}

test "the encoder and decoder give FFmpeg's packets and samples (vectors/alac.txt)" {
    const gpa = testing.allocator;
    const expected = @embedFile("../testing/vectors/alac.txt");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderVectors(gpa, &out.writer, expected);
    try testing.expectEqualStrings(expected, out.written());
}

const hostile = @import("../testing/hostile.zig");

fn hexBytes(comptime hex: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: [hex.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
        const final = out;
        return &final;
    }
}

/// The fuzz entry's input: a 36-byte magic cookie (its frame size cut to
/// 8192 samples, so that a mutated cookie stays small), then a packet;
/// then the extra bits option and the container's channels, as values.
/// A frame that decodes at 16 or 24 bits is encoded again and must decode
/// back to the same samples: ALAC is lossless.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const gpa = testing.allocator;
    var input: [8192 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const bug = smith.valueRangeAtMost(u8, 0, 1) == 1;
    const container_channels = smith.valueRangeAtMost(u32, 0, 9);
    if (len < cookie_len) return;
    var cookie = input[0..cookie_len].*;
    const max = std.mem.readInt(u32, cookie[12..16], .big);
    std.mem.writeInt(u32, cookie[12..16], @min(max, 8192), .big);
    const packet = input[cookie_len..len];
    const config = Config.parse(&cookie, container_channels) catch return;
    var d: Decoder = .init(gpa, config);
    defer d.deinit();
    d.extra_bit_bug = bug;
    const frame = (d.decode(packet) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    }) orelse return;
    try testing.expectEqual(config.channels, frame.planes.len);
    const bps: u32 = switch (config.sample_size) {
        16 => 16,
        24 => 24,
        else => return,
    };
    if (frame.samples > frame_size) return;
    const e = try Encoder.create(gpa, config.channels, bps, 44100, .{});
    defer e.destroy();
    const out = try gpa.alloc(u8, e.maxPacket(frame.samples));
    defer gpa.free(out);
    const encoded = e.encode(frame.planes, frame.samples, out);
    var again: Decoder = .init(gpa, try Config.parse(&e.cookie(), config.channels));
    defer again.deinit();
    const back = (try again.decode(encoded)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(frame.samples, back.samples);
    for (frame.planes, back.planes) |a, b| try testing.expectEqualSlices(i32, a, b);
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(seed_packets[0], &.{ 0, 2 }),
    hostile.fuzzSeed(seed_packets[1], &.{ 1, 2 }),
    hostile.fuzzSeed(seed_packets[2], &.{ 0, 2 }),
};

const seed_packets = [_][]const u8{
    // st16: a cookie and FFmpeg's packet (ffmpeg -c:a alac -f caf).
    hexBytes(
        "00000024616c616300000000000010000010280a0e02000000004004001588800000ac44200010000000c800000f0c01" ++
            "f1ff53ffe3ff5200b1ffd80d0c0123ff5a0003ffbe0065ffde0ff81b5ffe06d0fc0bfabff46ed09264020e4123912418" ++
            "017d54f13b270ee926e9e14c411fb88ad1e591b9eb7a3d95e5eb1d66809041f0570789837d5e54b99ba528579aebb186" ++
            "4c9511727ca590a2344c9e65b1038cacc4e2891a95c21c3037488c69fae50121911cdedfe1f728cc8df61f7887ffc002" ++
            "dff06af7fc1a3df783ef17c26cdb83803a7085c871fa8a1b28c23c04950a31da92b69b8069e9754041217858c0a88e97" ++
            "52e23029142acbd520379640e78c6f20a3a1709676cd39c8f1ed8ebab17099e0b7198e5a4f8763f61e692b40e042141c" ++
            "cf16e4d3760cb633c1908a31544c830ba7f06ac8467a9933cf72ae097be0",
    ),
    // mo24: a cookie and FFmpeg's packet (ffmpeg -c:a alac -f caf).
    hexBytes(
        "00000024616c616300000000000010000018280a0e01000000003004001026600000ac440000140000007800000d0c01" ++
            "61fe70012bff3e005dffec01488bc716aae24bac14dbaa93fec83a1aa69f4a7a8a637fe22d7f90a58378566671a39c60" ++
            "4a0aa1497ce34eaaf43675adc685883dd130f97287b8260ff8332ffc1983fe0c9df8fff0fef98be04820080a84000002" ++
            "4050e054a8008069309080e102449ae300c58a160c3114075a90c5450d41119711faf226c882325c",
    ),
    // c3: a cookie and FFmpeg's packet (ffmpeg -c:a alac -f caf).
    hexBytes(
        "00000024616c616300000000000010000010280a0e0300000000600400204cc00000ac440000100000006400000d0c01" ++
            "67fe7200ffff740045fff1ff002cff87797fc3933f147e9f785f4803887f2ae74aa738d561d5b410d7f8433118e42d9b" ++
            "873229d6105533b96f6d602dfb7d93d936f84e18d718d7061197bc3b2d719aba0cbdc8000400000019000083430056ff" ++
            "a3003c7fdf800e7ffd0342805c7f93804c7fda800a03fe0533ff814bbfdafe16f7ef86e5cc35856b507c49348c248bf7" ++
            "1bd222188b0a5e54d8da08864e8d1c25385daa26fd1a6884aedc77418364cbf738d162f8ca63084b1ff000affc09c7ff" ++
            "025dffb5775e84c69cbd6ed5c05339c686a27c72b4d464d188a8464c0287052b5f9170d6b68f154030f2b74f5f1c5236" ++
            "87c2a23080a4b9cc6307f89ff32e",
    ),
};

test "fuzz: the ALAC decoder on arbitrary cookies and packets, its frames encoded back" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: the ALAC decoder and encoder on mutated packets" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 64, 0x616c6163);
}

/// Decodes the seeds and encodes a frame of each, under the sweep's
/// allocator.
fn codecUnderFailures(gpa: std.mem.Allocator, seed: []const u8) !void {
    const config = Config.parse(seed[0..cookie_len], 0) catch return error.TestUnexpectedResult;
    var d: Decoder = .init(gpa, config);
    defer d.deinit();
    const frame = (try d.decode(seed[cookie_len..])) orelse return error.TestUnexpectedResult;
    const bps: u32 = if (config.sample_size == 16) 16 else 24;
    const e = try Encoder.create(gpa, config.channels, bps, 44100, .{});
    defer e.destroy();
    const out = try gpa.alloc(u8, e.maxPacket(frame.samples));
    defer gpa.free(out);
    _ = e.encode(frame.planes, frame.samples, out);
}

test "the decoder and encoder free everything under every allocation and remap failure" {
    for (seed_packets) |seed| try hostile.checkAllocationFailuresWith(testing.allocator, hostile.Remaps.both, seed, codecUnderFailures);
}

test "the seeds decode to the samples ffmpeg encoded" {
    // FFmpeg's encoder is lossless: each seed decodes to as many samples
    // as its input held (100 stereo, 60 mono at 24 bits, 50 in 3.0).
    const want = [_]u32{ 100, 60, 50 };
    for (seed_packets, want) |seed, n| {
        var d: Decoder = .init(testing.allocator, try Config.parse(seed[0..cookie_len], 0));
        defer d.deinit();
        const frame = (try d.decode(seed[cookie_len..])).?;
        try testing.expectEqual(n, frame.samples);
    }
}
