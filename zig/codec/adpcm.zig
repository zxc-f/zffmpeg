// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/adpcm.c (adpcm_decode_init's checks,
// adpcm_ima_wav_expand_nibble, ff_adpcm_ima_qt_expand_nibble,
// adpcm_ms_expand_nibble, get_nb_samples and adpcm_decode_frame for
// ADPCM_IMA_WAV and ADPCM_MS), adpcmenc.c (adpcm_encode_init,
// adpcm_ima_compress_sample, adpcm_ms_compress_sample,
// adpcm_compress_trellis and adpcm_encode_frame for the same two) and
// adpcm_data.c (the step, index, adaptation and coefficient tables) at the
// pinned reference revision.
// Copyright (c) 2001-2003 The FFmpeg project
// The step, index and MS tables come from the ADPCM reference source and
// from libsndfile, as FFmpeg's file records.
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's IMA WAV and Microsoft ADPCM codecs (TODO.md T31a), the block
//! formats of WAV's tags 0x0011 and 0x0002: each block decoded alone into
//! 16-bit samples, sample for sample as FFmpeg's decoders compute them, and
//! FFmpeg's encoders, packet for packet, with their `block_size` and
//! `trellis` options.

const std = @import("std");
const bits = @import("bits.zig");

/// `ff_adpcm_index_table`.
const index_table = [16]i8{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };
const index_table2 = [4]i8{ -1, 2, -1, 2 };
const index_table3 = [8]i8{ -1, -1, 1, 2, -1, -1, 1, 2 };
const index_table5 = [32]i8{ -1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16, -1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16 };
/// `adpcm_index_tables`, by bits per sample minus 2.
const index_tables = [4][]const i8{ &index_table2, &index_table3, &index_table, &index_table5 };

/// `ff_adpcm_step_table`.
pub const step_table = [89]i32{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,
    19,    21,    23,    25,    28,    31,    34,    37,    41,    45,
    50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
    130,   143,   157,   173,   190,   209,   230,   253,   279,   307,
    337,   371,   408,   449,   494,   544,   598,   658,   724,   796,
    876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
    2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,
    5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

/// `ff_adpcm_AdaptationTable`.
const adaptation_table = [16]i32{ 230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230 };
/// `ff_adpcm_AdaptCoeff1` and `ff_adpcm_AdaptCoeff2`: the MS predictors'
/// coefficients, divided by 4.
pub const adapt_coeff1 = [7]i32{ 64, 128, 0, 48, 60, 115, 98 };
pub const adapt_coeff2 = [7]i32{ 0, -64, 0, 16, 0, -52, -58 };
/// `ff_adpcm_yamaha_difflookup`.
const yamaha_difflookup = [16]i32{ 1, 3, 5, 7, 9, 11, 13, 15, -1, -3, -5, -7, -9, -11, -13, -15 };
/// `ff_adpcm_ima_block_sizes` and `ff_adpcm_ima_block_samples`, by bits
/// per sample minus 2: the bytes and samples of each channel's group.
const ima_block_sizes = [4]u8{ 4, 12, 4, 20 };
const ima_block_samples = [4]u8{ 16, 32, 8, 32 };

pub const Codec = enum { ima_wav, ms };

/// `ADPCMChannelStatus`, the fields these two codecs use.
const ChannelStatus = struct {
    predictor: i32 = 0,
    step_index: i32 = 0,
    prev_sample: i32 = 0,
    sample1: i32 = 0,
    sample2: i32 = 0,
    coeff1: i32 = 0,
    coeff2: i32 = 0,
    idelta: i32 = 0,
};

fn clipInt16(v: i32) i32 {
    return std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16));
}

// ---- Decoding ----

pub const DecodeError = error{
    /// FFmpeg's AVERROR_INVALIDDATA: no sample in the packet, a step index
    /// past 88, a predictor index past 6.
    InvalidData,
};

/// The stream parameters FFmpeg's decoders open with (`adpcm_decode_init`).
pub const Params = struct {
    codec: Codec,
    channels: u32,
    /// `block_align`, 0 when the container gives none.
    block_align: u32,
    /// IMA WAV's bits per sample, 2 to 5.
    bits_per_coded_sample: u32 = 4,

    pub const OpenError = error{
        /// AVERROR(EINVAL): channels outside 1 to 2 (IMA WAV) or 1 to 6
        /// (MS); AVERROR_INVALIDDATA: IMA WAV bits outside 2 to 5.
        InvalidParameters,
    };

    /// adpcm_decode_init's checks.
    pub fn check(p: Params) OpenError!void {
        const max_channels: u32 = switch (p.codec) {
            .ima_wav => 2,
            .ms => 6,
        };
        if (p.channels < 1 or p.channels > max_channels) return error.InvalidParameters;
        if (p.codec == .ima_wav and (p.bits_per_coded_sample < 2 or p.bits_per_coded_sample > 5)) return error.InvalidParameters;
    }

    /// get_nb_samples: the samples a packet of `size` bytes decodes to; 0
    /// for none (`InvalidData`).
    pub fn samplesIn(p: Params, size_in: usize) u32 {
        const ch: i64 = p.channels;
        // FFmpeg's buf_size > INT_MAX / 14 gives no samples.
        if (size_in > std.math.maxInt(i32) / 14) return 0;
        var size: i64 = @intCast(size_in);
        if (p.block_align > 0) size = @min(size, p.block_align);
        const n: i64 = switch (p.codec) {
            .ima_wav => blk: {
                const bsize: i64 = ima_block_sizes[p.bits_per_coded_sample - 2];
                const bsamples: i64 = ima_block_samples[p.bits_per_coded_sample - 2];
                if (size < 4 * ch) return 0;
                break :blk 1 + @divTrunc(size - 4 * ch, bsize * ch) * bsamples;
            },
            .ms => @divTrunc((size - 6 * ch) * 2, ch),
        };
        return if (n <= 0) 0 else @intCast(n);
    }
};

/// One channel's samples, or several channels' interleaved (MS with one or
/// two channels, which FFmpeg decodes to s16).
pub const Frame = struct {
    samples: u32,
    /// The bytes of the packet the decoding used.
    consumed: usize,
};

/// FFmpeg's IMA WAV or MS decoder for a stream: its channel state.
pub const Decoder = struct {
    params: Params,
    status: [6]ChannelStatus = @splat(.{}),

    pub fn init(params: Params) Params.OpenError!Decoder {
        try params.check();
        return .{ .params = params };
    }

    /// adpcm_decode_frame: the first block of `packet` decoded into
    /// `planes` (one per channel, each of at least `samplesIn` samples),
    /// planar whatever FFmpeg's sample format; the samples and the bytes
    /// used. Reads past the packet give zeros, as FFmpeg's padding does.
    pub fn decode(d: *Decoder, packet: []const u8, planes: []const []i16) DecodeError!Frame {
        const p = d.params;
        const nb_samples = p.samplesIn(packet.len);
        if (nb_samples == 0) return error.InvalidData; // "invalid number of samples in packet"
        var gb: ByteReader = .{ .bytes = packet };
        const channels = p.channels;
        switch (p.codec) {
            .ima_wav => {
                for (0..channels) |i| {
                    const cs = &d.status[i];
                    cs.predictor = @as(i16, @bitCast(gb.le16()));
                    planes[i][0] = @intCast(cs.predictor);
                    cs.step_index = gb.byte();
                    gb.skip(1);
                    if (cs.step_index > 88) return error.InvalidData; // "ERROR: step_index[%d] = %i"
                }
                if (p.bits_per_coded_sample != 4) {
                    const samples_per_block = ima_block_samples[p.bits_per_coded_sample - 2];
                    const block_size = ima_block_sizes[p.bits_per_coded_sample - 2];
                    for (0..(nb_samples - 1) / samples_per_block) |n| {
                        for (0..channels) |i| {
                            const cs = &d.status[i];
                            const out = planes[i][1 + n * samples_per_block ..];
                            var temp: [20]u8 = @splat(0);
                            for (temp[0..block_size], 0..) |*t, j| {
                                const at = 4 * channels + block_size * n * channels + (j % 4) + (j / 4) * (channels * 4) + i * 4;
                                t.* = if (at < packet.len) packet[at] else 0;
                            }
                            var g = bits.LsbReader.init(temp[0..block_size]) catch unreachable; // 20 bytes at most
                            for (0..samples_per_block) |m| out[m] = imaWavExpandNibble(cs, &g, p.bits_per_coded_sample);
                        }
                    }
                    gb.skip(@as(i64, p.block_align) - @as(i64, channels) * 4);
                } else {
                    for (0..(nb_samples - 1) / 8) |n| {
                        for (0..channels) |i| {
                            const cs = &d.status[i];
                            const out = planes[i][1 + n * 8 ..];
                            var m: usize = 0;
                            while (m < 8) : (m += 2) {
                                const v = gb.byte();
                                out[m] = imaQtExpandNibble(cs, v & 0x0f);
                                out[m + 1] = imaQtExpandNibble(cs, v >> 4);
                            }
                        }
                    }
                }
            },
            .ms => {
                if (channels > 2) {
                    for (0..channels) |ch| {
                        const cs = &d.status[ch];
                        const out = planes[ch];
                        const block_predictor = gb.byte();
                        if (block_predictor > 6) return error.InvalidData; // "ERROR: block_predictor[%d] = %d"
                        cs.coeff1 = adapt_coeff1[block_predictor];
                        cs.coeff2 = adapt_coeff2[block_predictor];
                        cs.idelta = @as(i16, @bitCast(gb.le16()));
                        cs.sample1 = @as(i16, @bitCast(gb.le16()));
                        cs.sample2 = @as(i16, @bitCast(gb.le16()));
                        out[0] = @intCast(cs.sample2);
                        // Into the padding when the frame has one sample.
                        if (out.len > 1) out[1] = @intCast(cs.sample1);
                        var k: usize = 2;
                        var n = (@as(i64, nb_samples) - 2) >> 1;
                        while (n > 0) : (n -= 1) {
                            const b = gb.byte();
                            out[k] = msExpandNibble(cs, b >> 4);
                            out[k + 1] = msExpandNibble(cs, b & 0x0f);
                            k += 2;
                        }
                    }
                } else {
                    const st: usize = @intFromBool(channels == 2);
                    var bp = gb.byte();
                    if (bp > 6) return error.InvalidData; // "ERROR: block_predictor[0] = %d"
                    d.status[0].coeff1 = adapt_coeff1[bp];
                    d.status[0].coeff2 = adapt_coeff2[bp];
                    if (st != 0) {
                        bp = gb.byte();
                        if (bp > 6) return error.InvalidData; // "ERROR: block_predictor[1] = %d"
                        d.status[1].coeff1 = adapt_coeff1[bp];
                        d.status[1].coeff2 = adapt_coeff2[bp];
                    }
                    d.status[0].idelta = @as(i16, @bitCast(gb.le16()));
                    if (st != 0) d.status[1].idelta = @as(i16, @bitCast(gb.le16()));
                    d.status[0].sample1 = @as(i16, @bitCast(gb.le16()));
                    if (st != 0) d.status[1].sample1 = @as(i16, @bitCast(gb.le16()));
                    d.status[0].sample2 = @as(i16, @bitCast(gb.le16()));
                    if (st != 0) d.status[1].sample2 = @as(i16, @bitCast(gb.le16()));
                    // FFmpeg writes them interleaved; here each channel's
                    // plane takes its own.
                    var k: [2]usize = .{ 0, 0 };
                    put(planes, &k, 0, d.status[0].sample2);
                    if (st != 0) put(planes, &k, 1, d.status[1].sample2);
                    put(planes, &k, 0, d.status[0].sample1);
                    if (st != 0) put(planes, &k, 1, d.status[1].sample1);
                    var n = (@as(i64, nb_samples) - 2) >> @intCast(1 - st);
                    while (n > 0) : (n -= 1) {
                        const b = gb.byte();
                        put(planes, &k, 0, msExpandNibble(&d.status[0], b >> 4));
                        put(planes, &k, st, msExpandNibble(&d.status[st], b & 0x0f));
                    }
                }
            },
        }
        // "Nothing consumed" cannot happen: every path reads a header.
        std.debug.assert(gb.at > 0);
        // "Overread of %d < %d": the packet's size.
        const consumed = @min(gb.at, packet.len);
        return .{ .samples = nb_samples, .consumed = consumed };
    }
};

/// FFmpeg's interleaved MS samples, placed in their channels' planes.
fn put(planes: []const []i16, k: *[2]usize, ch: usize, v: i32) void {
    // A frame of one sample still gets both header samples: FFmpeg writes
    // the second into the frame's padding, which no one reads.
    // Read as 16 bits, or clipped to them.
    if (k[ch] < planes[ch].len) planes[ch][k[ch]] = @intCast(v);
    k[ch] += 1;
}

/// bytestream2's unchecked reads (the `u` ones), past the end giving the
/// padding's zeros, and its checked skip.
const ByteReader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(r: *ByteReader) u8 {
        const v = if (r.at < r.bytes.len) r.bytes[r.at] else 0;
        r.at += 1;
        return v;
    }

    fn le16(r: *ByteReader) u16 {
        const lo: u16 = r.byte();
        return lo | @as(u16, r.byte()) << 8;
    }

    /// bytestream2_skip: clamped to the end; a negative count does nothing
    /// (FFmpeg's unsigned size clamps to the end).
    fn skip(r: *ByteReader, n: i64) void {
        if (r.at >= r.bytes.len) return;
        const left = r.bytes.len - r.at;
        const want: usize = if (n < 0) left else @min(@as(u64, @intCast(n)), left);
        r.at += want;
    }
};

/// ff_adpcm_ima_qt_expand_nibble.
fn imaQtExpandNibble(c: *ChannelStatus, nibble: u8) i16 {
    const step = step_table[@intCast(c.step_index)];
    const step_index = std.math.clamp(c.step_index + index_table[nibble], 0, 88);
    var diff = step >> 3;
    if (nibble & 4 != 0) diff += step;
    if (nibble & 2 != 0) diff += step >> 1;
    if (nibble & 1 != 0) diff += step >> 2;
    var predictor = c.predictor;
    if (nibble & 8 != 0) predictor -= diff else predictor += diff;
    c.predictor = clipInt16(predictor);
    c.step_index = step_index;
    return @intCast(c.predictor);
}

/// adpcm_ima_wav_expand_nibble: a `bps`-bit code from the LSB-first reader.
fn imaWavExpandNibble(c: *ChannelStatus, g: *bits.LsbReader, bps: u32) i16 {
    const shift: u5 = @intCast(bps - 1);
    const nibble = g.bits(@intCast(bps));
    const step = step_table[@intCast(c.step_index)];
    const step_index = std.math.clamp(c.step_index + index_tables[bps - 2][nibble], 0, 88);
    const sign = nibble & (@as(u32, 1) << shift);
    const delta = nibble & ((@as(u32, 1) << shift) - 1);
    var diff = step >> shift;
    for (0..shift) |i| {
        const bit: i32 = @intFromBool(delta & (@as(u32, 1) << @intCast(i)) != 0);
        diff += (step >> @intCast(shift - 1 - i)) * bit;
    }
    var predictor = c.predictor;
    if (sign != 0) predictor -= diff else predictor += diff;
    c.predictor = clipInt16(predictor);
    c.step_index = step_index;
    return @intCast(c.predictor);
}

/// adpcm_ms_expand_nibble.
fn msExpandNibble(c: *ChannelStatus, nibble: u8) i16 {
    var predictor = @divTrunc(c.sample1 * c.coeff1 + c.sample2 * c.coeff2, 64);
    const signed: i32 = if (nibble & 0x08 != 0) @as(i32, nibble) - 0x10 else nibble;
    // The C's int arithmetic: idelta reaches INT_MAX / 768 at most.
    predictor +%= signed *% c.idelta;
    c.sample2 = c.sample1;
    c.sample1 = clipInt16(predictor);
    c.idelta = (adaptation_table[nibble] * c.idelta) >> 8;
    if (c.idelta < 16) c.idelta = 16;
    // "idelta overflow"
    if (c.idelta > std.math.maxInt(i32) / 768) c.idelta = std.math.maxInt(i32) / 768;
    return @intCast(c.sample1);
}

// ---- Encoding ----

pub const EncodeOptions = struct {
    /// `block_size`: 32 to 8192, a power of two.
    block_size: u32 = 1024,
    /// `-trellis`: 0 (off) to 16.
    trellis: u32 = 0,

    pub const Error = error{
        /// "block size must be power of 2", "invalid trellis size", or a
        /// block too small for a sample (FFmpeg's frame size of 1 or less).
        InvalidOption,
    };
};

/// FFmpeg's IMA WAV or MS encoder for a stream of one or two channels.
pub const Encoder = struct {
    codec: Codec,
    channels: u32,
    block_size: u32,
    trellis: u32,
    /// `frame_size`: the samples a channel each packet takes.
    frame_size: u32,
    status: [2]ChannelStatus = @splat(.{}),
    /// The trellis' buffers, allocated when `trellis` is set.
    trellis_state: ?*Trellis = null,
    gpa: std.mem.Allocator,

    /// adpcm_encode_init for 1 or 2 channels.
    pub fn init(gpa: std.mem.Allocator, codec: Codec, channels: u32, options: EncodeOptions) (EncodeOptions.Error || error{OutOfMemory})!Encoder {
        std.debug.assert(channels == 1 or channels == 2);
        const bs = options.block_size;
        if (bs < 32 or bs > 8192 or !std.math.isPowerOfTwo(bs)) return error.InvalidOption;
        if (options.trellis > 16) return error.InvalidOption;
        const frame_size: u32 = switch (codec) {
            .ima_wav => (bs - 4 * channels) * 8 / (4 * channels) + 1,
            .ms => (bs - 7 * channels) * 2 / channels + 2,
        };
        var e: Encoder = .{ .codec = codec, .channels = channels, .block_size = bs, .trellis = options.trellis, .frame_size = frame_size, .gpa = gpa };
        if (options.trellis != 0) e.trellis_state = try Trellis.create(gpa, options.trellis);
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        if (e.trellis_state) |t| t.destroy(e.gpa);
        e.* = undefined;
    }

    /// The MS stream's extradata (32 bytes): the samples per block, 7
    /// coefficient pairs.
    pub fn msExtradata(e: *const Encoder) [32]u8 {
        var out: [32]u8 = undefined;
        std.mem.writeInt(u16, out[0..2], @intCast(e.frame_size), .little);
        std.mem.writeInt(u16, out[2..4], 7, .little);
        for (0..7) |i| {
            std.mem.writeInt(i16, out[4 + 4 * i ..][0..2], @intCast(adapt_coeff1[i] * 4), .little);
            std.mem.writeInt(i16, out[6 + 4 * i ..][0..2], @intCast(adapt_coeff2[i] * 4), .little);
        }
        return out;
    }

    /// adpcm_encode_frame: one block of `block_size` bytes from
    /// `frame_size` samples a channel, `planes` one per channel (FFmpeg's
    /// s16p for IMA WAV; its interleaved s16 for MS, read here from the
    /// planes in the same order).
    pub const EncodeError = error{
        OutOfMemory,
        /// The trellis search lost every path (FFmpeg crashes there).
        TrellisOverflow,
    };

    pub fn encode(e: *Encoder, planes: []const []const i16, out: []u8) EncodeError!void {
        std.debug.assert(out.len == e.block_size);
        const channels = e.channels;
        var dst: usize = 0;
        switch (e.codec) {
            .ima_wav => {
                const blocks = (e.frame_size - 1) / 8;
                for (0..channels) |ch| {
                    const s = &e.status[ch];
                    s.prev_sample = planes[ch][0];
                    std.mem.writeInt(i16, out[dst..][0..2], @intCast(s.prev_sample), .little);
                    out[dst + 2] = @intCast(s.step_index);
                    out[dst + 3] = 0;
                    dst += 4;
                }
                if (e.trellis_state) |t| {
                    const buf = try e.gpa.alloc(u8, channels * blocks * 8);
                    defer e.gpa.free(buf);
                    for (0..channels) |ch| try t.compress(.ima_wav, planes[ch][1..][0 .. blocks * 8], 1, buf[ch * blocks * 8 ..][0 .. blocks * 8], &e.status[ch]);
                    for (0..blocks) |i| {
                        for (0..channels) |ch| {
                            const b = buf[ch * blocks * 8 + i * 8 ..];
                            var j: usize = 0;
                            while (j < 8) : (j += 2) {
                                out[dst] = b[j] | (b[j + 1] << 4);
                                dst += 1;
                            }
                        }
                    }
                } else {
                    for (0..blocks) |i| {
                        for (0..channels) |ch| {
                            const s = &e.status[ch];
                            const smp = planes[ch][1 + i * 8 ..];
                            var j: usize = 0;
                            while (j < 8) : (j += 2) {
                                var v = imaCompressSample(s, smp[j]);
                                v |= imaCompressSample(s, smp[j + 1]) << 4;
                                out[dst] = v;
                                dst += 1;
                            }
                        }
                    }
                }
            },
            .ms => {
                const st: usize = @intFromBool(channels == 2);
                for (0..channels) |i| {
                    out[dst] = 0; // predictor 0
                    dst += 1;
                    e.status[i].coeff1 = adapt_coeff1[0];
                    e.status[i].coeff2 = adapt_coeff2[0];
                }
                for (0..channels) |i| {
                    if (e.status[i].idelta < 16) e.status[i].idelta = 16;
                    std.mem.writeInt(u16, out[dst..][0..2], @truncate(@as(u32, @bitCast(e.status[i].idelta))), .little);
                    dst += 2;
                }
                // FFmpeg's interleaved reads: sample 0 of each channel,
                // then sample 1 of each.
                for (0..channels) |i| e.status[i].sample2 = planes[i][0];
                for (0..channels) |i| {
                    e.status[i].sample1 = planes[i][1];
                    std.mem.writeInt(i16, out[dst..][0..2], @intCast(e.status[i].sample1), .little);
                    dst += 2;
                }
                for (0..channels) |i| {
                    std.mem.writeInt(i16, out[dst..][0..2], @intCast(e.status[i].sample2), .little);
                    dst += 2;
                }
                if (e.trellis_state) |t| {
                    const n = e.block_size - 7 * channels;
                    const buf = try e.gpa.alloc(u8, 2 * n);
                    defer e.gpa.free(buf);
                    if (channels == 1) {
                        try t.compress(.ms, planes[0][2..][0..n], 1, buf[0..n], &e.status[0]);
                        var i: usize = 0;
                        while (i < n) : (i += 2) {
                            out[dst] = (buf[i] << 4) | buf[i + 1];
                            dst += 1;
                        }
                        // FFmpeg's trellis codes n samples, half the
                        // block's nibbles, and leaves the rest of the
                        // packet unwritten (stale heap memory there);
                        // zeros here (notes.md "ADPCM").
                        @memset(out[dst..], 0);
                        dst = e.block_size;
                    } else {
                        // FFmpeg's stride-2 walk over the interleaved
                        // samples: n of each channel, from sample 2.
                        try t.compress(.ms, planes[0][2..][0..n], 1, buf[0..n], &e.status[0]);
                        try t.compress(.ms, planes[1][2..][0..n], 1, buf[n..][0..n], &e.status[1]);
                        for (0..n) |i| {
                            out[dst] = (buf[i] << 4) | buf[n + i];
                            dst += 1;
                        }
                    }
                } else {
                    // The interleaved samples from 2 * channels on, two at
                    // a time: in mono, two of the one channel.
                    var at: usize = 2 * channels;
                    for (7 * channels..e.block_size) |_| {
                        var nibble = msCompressSample(&e.status[0], interleaved(planes, channels, at)) << 4;
                        nibble |= msCompressSample(&e.status[st], interleaved(planes, channels, at + 1));
                        out[dst] = nibble;
                        dst += 1;
                        at += 2;
                    }
                }
            },
        }
        std.debug.assert(dst == e.block_size);
    }
};

/// Sample `at` of the interleaved order of `planes`.
fn interleaved(planes: []const []const i16, channels: u32, at: usize) i16 {
    return planes[at % channels][at / channels];
}

/// adpcm_ima_compress_sample.
fn imaCompressSample(c: *ChannelStatus, sample: i16) u8 {
    const delta = @as(i32, sample) - c.prev_sample;
    const step = step_table[@intCast(c.step_index)];
    const mag: i32 = @intCast(@abs(delta));
    const nibble: u8 = @intCast(@min(7, @divTrunc(mag * 4, step)) + @as(i32, @intFromBool(delta < 0)) * 8);
    c.prev_sample += @divTrunc(step * yamaha_difflookup[nibble], 8);
    c.prev_sample = clipInt16(c.prev_sample);
    c.step_index = std.math.clamp(c.step_index + index_table[nibble], 0, 88);
    return nibble;
}

/// adpcm_ms_compress_sample.
fn msCompressSample(c: *ChannelStatus, sample: i16) u8 {
    var predictor = @divTrunc(c.sample1 * c.coeff1 + c.sample2 * c.coeff2, 64);
    var nibble: i32 = @as(i32, sample) - predictor;
    const bias = if (nibble >= 0) @divTrunc(c.idelta, 2) else -@divTrunc(c.idelta, 2);
    nibble = @divTrunc(nibble + bias, c.idelta);
    // av_clip_intp2(nibble, 3) & 0x0F.
    const code: u8 = @intCast(std.math.clamp(nibble, -8, 7) & 0x0f);
    const signed: i32 = if (code & 0x08 != 0) @as(i32, code) - 0x10 else code;
    predictor += signed * c.idelta;
    c.sample2 = c.sample1;
    c.sample1 = clipInt16(predictor);
    c.idelta = (adaptation_table[code] * c.idelta) >> 8;
    if (c.idelta < 16) c.idelta = 16;
    return code;
}

const freeze_interval = 128;

/// adpcm_compress_trellis' buffers and search, for IMA WAV and MS.
const Trellis = struct {
    frontier: usize,
    trellis: u5,
    paths: []Path,
    node_buf: []Node,
    nodep_buf: []?*Node,
    hash: *[65536]u8,

    const Path = struct { nibble: u8 = 0, prev: u32 = 0 };
    const Node = struct { ssd: u32 = 0, path: u32 = 0, sample1: i32 = 0, sample2: i32 = 0, step: i32 = 0 };

    fn create(gpa: std.mem.Allocator, trellis: u32) error{OutOfMemory}!*Trellis {
        const frontier = @as(usize, 1) << @intCast(trellis);
        const t = try gpa.create(Trellis);
        errdefer gpa.destroy(t);
        const paths = try gpa.alloc(Path, frontier * freeze_interval);
        errdefer gpa.free(paths);
        const node_buf = try gpa.alloc(Node, 2 * frontier);
        errdefer gpa.free(node_buf);
        const nodep_buf = try gpa.alloc(?*Node, 2 * frontier);
        errdefer gpa.free(nodep_buf);
        const hash = try gpa.create([65536]u8);
        t.* = .{ .frontier = frontier, .trellis = @intCast(trellis), .paths = paths, .node_buf = node_buf, .nodep_buf = nodep_buf, .hash = hash };
        return t;
    }

    fn destroy(t: *Trellis, gpa: std.mem.Allocator) void {
        gpa.free(t.paths);
        gpa.free(t.node_buf);
        gpa.free(t.nodep_buf);
        gpa.destroy(t.hash);
        gpa.destroy(t);
    }

    /// adpcm_compress_trellis: `n` nibbles of `samples` (every `stride`th)
    /// into `dst`, the channel state left where the best path ends.
    fn compress(t: *Trellis, codec: Codec, samples: []const i16, stride: usize, dst: []u8, c: *ChannelStatus) error{TrellisOverflow}!void {
        const frontier = t.frontier;
        const n = dst.len;
        const paths = t.paths;
        var nodes = t.nodep_buf[0..frontier];
        var nodes_next = t.nodep_buf[frontier..][0..frontier];
        var pathn: u32 = 0;
        var froze: i64 = -1;
        var generation: u8 = 0;
        @memset(t.hash, 0xff);
        @memset(t.nodep_buf, null);
        const first = &t.node_buf[frontier];
        first.* = .{ .ssd = 0, .path = 0, .step = c.step_index, .sample1 = c.sample1, .sample2 = c.sample2 };
        if (codec == .ima_wav) first.sample1 = c.prev_sample;
        if (codec == .ms) first.step = c.idelta;
        nodes[0] = first;
        for (0..n) |i| {
            var tnext: usize = frontier * (i & 1);
            const sample: i32 = samples[i * stride];
            var heap_pos: usize = 0;
            @memset(nodes_next, null);
            var j: usize = 0;
            while (j < frontier and nodes[j] != null) : (j += 1) {
                const nj = nodes[j].?;
                // Higher j have a higher ssd already.
                const range: i32 = if (j < frontier / 2) 1 else 0;
                const step = nj.step;
                switch (codec) {
                    .ms => {
                        const predictor = @divTrunc(nj.sample1 * c.coeff1 + nj.sample2 * c.coeff2, 64);
                        const div = @divTrunc(sample - predictor, step);
                        const nmin = std.math.clamp(div - range, -8, 6);
                        const nmax = std.math.clamp(div + range, -7, 7);
                        var nidx = nmin;
                        while (nidx <= nmax) : (nidx += 1) {
                            const nibble: u8 = @intCast(nidx & 0xf);
                            const dec_sample = predictor + nidx * step;
                            const new_step = @max(16, (adaptation_table[nibble] * step) >> 8);
                            t.store(nodes, nodes_next, nj, &heap_pos, &tnext, &pathn, sample, dec_sample, nibble, new_step, generation);
                        }
                    },
                    .ima_wav => {
                        const predictor = nj.sample1;
                        const st = step_table[@intCast(step)];
                        const div = @divTrunc((sample - predictor) * 4, st);
                        var nmin = std.math.clamp(div - range, -7, 6);
                        var nmax = std.math.clamp(div + range, -6, 7);
                        if (nmin <= 0) nmin -= 1; // distinguish -0 from +0
                        if (nmax < 0) nmax -= 1;
                        var nidx = nmin;
                        while (nidx <= nmax) : (nidx += 1) {
                            const nibble: u8 = @intCast(if (nidx < 0) 7 - nidx else nidx);
                            const dec_sample = predictor + @divTrunc(st * yamaha_difflookup[nibble], 8);
                            const new_step = std.math.clamp(step + index_table[nibble], 0, 88);
                            t.store(nodes, nodes_next, nj, &heap_pos, &tnext, &pathn, sample, dec_sample, nibble, new_step, generation);
                        }
                    },
                }
            }
            const u = nodes;
            nodes = nodes_next;
            nodes_next = u;
            // Every candidate's error sum wrapped: FFmpeg reads the empty
            // node and crashes (notes.md "ADPCM").
            if (nodes[0] == null) return error.TrellisOverflow;
            generation +%= 1;
            if (generation == 255) {
                @memset(t.hash, 0xff);
                generation = 0;
            }
            // Prevent overflow.
            if (nodes[0].?.ssd > (1 << 28)) {
                var k: usize = 1;
                while (k < frontier and nodes[k] != null) : (k += 1) nodes[k].?.ssd -= nodes[0].?.ssd;
                nodes[0].?.ssd = 0;
            }
            // Merge old paths to save memory.
            if (@as(i64, @intCast(i)) == froze + freeze_interval) {
                var p = &paths[nodes[0].?.path];
                var k: i64 = @intCast(i);
                while (k > froze) : (k -= 1) {
                    dst[@intCast(k)] = p.nibble;
                    p = &paths[p.prev];
                }
                froze = @intCast(i);
                pathn = 0;
                // Other nodes might use paths the frozen one does not.
                @memset(nodes[1..], null);
            }
        }
        var p = &paths[nodes[0].?.path];
        var k: i64 = @as(i64, @intCast(n)) - 1;
        while (k > froze) : (k -= 1) {
            dst[@intCast(k)] = p.nibble;
            p = &paths[p.prev];
        }
        const best = nodes[0].?;
        c.predictor = best.sample1;
        c.sample1 = best.sample1;
        c.sample2 = best.sample2;
        c.step_index = best.step;
        c.idelta = best.step;
    }

    /// STORE_NODE.
    fn store(t: *Trellis, nodes: []?*Node, nodes_next: []?*Node, nj: *Node, heap_pos: *usize, tnext: *usize, pathn: *u32, sample: i32, dec_in: i32, nibble: u8, step_index: i32, generation: u8) void {
        _ = nodes;
        const frontier = t.frontier;
        const dec_sample = clipInt16(dec_in);
        const d = sample - dec_sample;
        const du: u32 = @bitCast(d);
        const ssd = nj.ssd +% du *% du;
        // Wraparound: skipped.
        if (ssd < nj.ssd) return;
        // Collapse two states with the same previous sample.
        const h = &t.hash[@as(u16, @bitCast(@as(i16, @intCast(dec_sample))))];
        if (h.* == generation) return;
        var pos: usize = undefined;
        if (heap_pos.* < frontier) {
            pos = heap_pos.*;
            heap_pos.* += 1;
        } else {
            // Replace a leaf, a different slot each time.
            pos = (frontier >> 1) + (heap_pos.* & ((frontier >> 1) - 1));
            if (ssd > nodes_next[pos].?.ssd) return;
            heap_pos.* += 1;
        }
        h.* = generation;
        var u = nodes_next[pos];
        if (u == null) {
            const node = &t.node_buf[tnext.*];
            tnext.* += 1;
            nodes_next[pos] = node;
            node.path = pathn.*;
            pathn.* += 1;
            u = node;
        }
        const un = u.?;
        un.ssd = ssd;
        un.step = step_index;
        un.sample2 = nj.sample1;
        un.sample1 = dec_sample;
        t.paths[un.path] = .{ .nibble = nibble, .prev = nj.path };
        // Sift up.
        while (pos > 0) {
            const parent = (pos - 1) >> 1;
            if (nodes_next[parent].?.ssd <= ssd) break;
            std.mem.swap(?*Node, &nodes_next[parent], &nodes_next[pos]);
            pos = parent;
        }
    }
};

const testing = std.testing;

test "IMA WAV and MS frame sizes and refusals as FFmpeg's init sets them" {
    var ima = try Encoder.init(testing.allocator, .ima_wav, 2, .{});
    defer ima.deinit();
    try testing.expectEqual(1017, ima.frame_size);
    var ms = try Encoder.init(testing.allocator, .ms, 1, .{ .block_size = 256 });
    defer ms.deinit();
    try testing.expectEqual(500, ms.frame_size);
    try testing.expectError(error.InvalidOption, Encoder.init(testing.allocator, .ms, 1, .{ .block_size = 100 }));
    try testing.expectError(error.InvalidOption, Encoder.init(testing.allocator, .ms, 1, .{ .trellis = 17 }));
    try testing.expectEqual(1017, (Params{ .codec = .ima_wav, .channels = 2, .block_align = 1024 }).samplesIn(1024));
    try testing.expectEqual(500, (Params{ .codec = .ms, .channels = 1, .block_align = 256 }).samplesIn(256));
    try testing.expectEqual(0, (Params{ .codec = .ms, .channels = 2, .block_align = 256 }).samplesIn(11));
    try testing.expectError(error.InvalidParameters, Decoder.init(.{ .codec = .ima_wav, .channels = 3, .block_align = 256 }));
}

test "an encoded block decodes back close to its input" {
    const gpa = testing.allocator;
    inline for (.{ Codec.ima_wav, Codec.ms }) |codec| {
        inline for (.{ 0, 4 }) |trellis| {
            var e = try Encoder.init(gpa, codec, 1, .{ .block_size = 256, .trellis = trellis });
            defer e.deinit();
            const samples = try gpa.alloc(i16, e.frame_size);
            defer gpa.free(samples);
            for (samples, 0..) |*s, i| s.* = @intFromFloat(8000 * @sin(@as(f64, @floatFromInt(i)) * 0.05));
            var block: [256]u8 = undefined;
            try e.encode(&.{samples}, &block);
            var d = try Decoder.init(.{ .codec = codec, .channels = 1, .block_align = 256 });
            const out = try gpa.alloc(i16, e.frame_size);
            defer gpa.free(out);
            const frame = try d.decode(&block, &.{out});
            try testing.expectEqual(e.frame_size, frame.samples);
            try testing.expectEqual(256, frame.consumed);
            var worst: i32 = 0;
            for (samples, out) |a, b| worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, a) - b))));
            // MS mono with trellis codes only half the block (FFmpeg's).
            if (!(codec == .ms and trellis != 0)) try testing.expect(worst < 2000);
        }
    }
}

// ---- The oracle (vectors/adpcm.txt) ----

const Rng = struct {
    state: u32,

    fn next(r: *Rng) u32 {
        var x = r.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        r.state = x;
        return x;
    }
};

/// adpcm_vectors.c's `sample`.
fn testSample(rng: *Rng, signal: []const u8, c: usize, i: usize, state: *[2]i32) i16 {
    const noise: i32 = @as(i32, @intCast(rng.next() & 0xffff)) - 0x8000;
    var v: i32 = undefined;
    if (std.mem.eql(u8, signal, "tone")) {
        const period: i32 = 64 + 24 * @as(i32, @intCast(c));
        const phase: i32 = @intCast(@rem(@as(i64, @intCast(i)), period));
        const tri = if (phase < @divTrunc(period, 2)) phase else period - phase;
        v = @divTrunc((tri * 2 - @divTrunc(period, 2)) * 16384, @divTrunc(period, 2)) + @divTrunc(noise, 8);
    } else if (std.mem.eql(u8, signal, "smooth")) {
        state[c] += @divTrunc(noise - state[c], 8);
        v = state[c] * 2;
    } else if (std.mem.eql(u8, signal, "noise")) {
        v = noise;
    } else if (std.mem.eql(u8, signal, "silence")) {
        v = 0;
    } else {
        v = if ((i + c) & 1 != 0) 32767 else -32768;
        if (rng.next() & 1 != 0) v = -32768;
    }
    return @intCast(std.math.clamp(v, -32768, 32767));
}

/// A D line: the planes' MD5, little-endian, channel after channel.
fn decodeLine(w: *std.Io.Writer, d: *Decoder, packet: []const u8, gpa: std.mem.Allocator) !void {
    const p = d.params;
    const n = p.samplesIn(packet.len);
    const storage = try gpa.alloc(i16, @max(n, 1) * p.channels);
    defer gpa.free(storage);
    var planes: [6][]i16 = undefined;
    for (0..p.channels) |c| planes[c] = storage[c * @max(n, 1) ..][0..@max(n, 1)];
    const frame = d.decode(packet, planes[0..p.channels]) catch {
        try w.writeAll("D INVALIDDATA 0 -\n");
        return;
    };
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (planes[0..p.channels]) |plane| {
        for (plane[0..frame.samples]) |v| {
            var le: [2]u8 = undefined;
            std.mem.writeInt(i16, &le, v, .little);
            md5.update(&le);
        }
    }
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    try w.print("D 0 {d} {x}\n", .{ frame.samples, &digest });
}

fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer) !void {
    const vectors = @embedFile("../testing/vectors/adpcm.txt");
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "E ")) {
            var f = std.mem.splitScalar(u8, line[2..], ' ');
            const name = f.next().?;
            const encoder = f.next().?;
            const signal = f.next().?;
            const channels = try std.fmt.parseInt(u32, f.next().?, 10);
            const block_size = try std.fmt.parseInt(u32, f.next().?, 10);
            const trellis = try std.fmt.parseInt(u32, f.next().?, 10);
            const samples = try std.fmt.parseInt(usize, f.next().?, 10);
            try w.print("E {s} {s} {s} {d} {d} {d} {d}\n", .{ name, encoder, signal, channels, block_size, trellis, samples });
            const codec: Codec = if (std.mem.eql(u8, encoder, "adpcm_ima_wav")) .ima_wav else .ms;
            var e = Encoder.init(gpa, codec, channels, .{ .block_size = block_size, .trellis = trellis }) catch |err| switch (err) {
                error.InvalidOption => {
                    try w.writeAll("O EINVAL\n");
                    continue;
                },
                else => return err,
            };
            defer e.deinit();
            try w.print("O ok\nI {d} {d} ", .{ e.frame_size, e.block_size });
            if (codec == .ms) try w.print("{x}\n", .{&e.msExtradata()}) else try w.writeAll("-\n");
            var d = try Decoder.init(.{ .codec = codec, .channels = channels, .block_align = e.block_size });
            var rng: Rng = .{ .state = 0x9E3779B9 ^ (channels * 1000003 + @as(u32, @intCast(samples)) + block_size) };
            var state: [2]i32 = .{ 0, 0 };
            const plane_store = try gpa.alloc(i16, 2 * e.frame_size);
            defer gpa.free(plane_store);
            const block = try gpa.alloc(u8, e.block_size);
            defer gpa.free(block);
            var start: usize = 0;
            while (start < samples) : (start += e.frame_size) {
                const n = @min(samples - start, e.frame_size);
                @memset(plane_store, 0); // encode.c pads the last frame with silence
                for (0..n) |i| for (0..channels) |c| {
                    plane_store[c * e.frame_size + i] = testSample(&rng, signal, c, start + i, &state);
                };
                const planes = [2][]const i16{ plane_store[0..e.frame_size], plane_store[e.frame_size..][0..e.frame_size] };
                try e.encode(planes[0..channels], block);
                var digest: [16]u8 = undefined;
                // MS mono with trellis: FFmpeg writes only the first bytes.
                if (codec == .ms and channels == 1 and trellis != 0) {
                    const defined = 7 + (block.len - 7) / 2;
                    std.crypto.hash.Md5.hash(block[0..defined], &digest, .{});
                    try w.print("H {d} {d} {x}\n", .{ block.len, defined, &digest });
                    continue;
                }
                std.crypto.hash.Md5.hash(block, &digest, .{});
                try w.print("P {d} {x}\n", .{ block.len, &digest });
                try decodeLine(w, &d, block, gpa);
            }
        } else if (std.mem.startsWith(u8, line, "R ")) {
            var f = std.mem.splitScalar(u8, line[2..], ' ');
            const name = f.next().?;
            const channels = try std.fmt.parseInt(u32, f.next().?, 10);
            const block_align = try std.fmt.parseInt(u32, f.next().?, 10);
            const bits_per_sample = try std.fmt.parseInt(u32, f.next().?, 10);
            const seed = try std.fmt.parseInt(u32, f.next().?, 10);
            const size = try std.fmt.parseInt(usize, f.next().?, 10);
            try w.print("R {s} {d} {d} {d} {d} {d}\n", .{ name, channels, block_align, bits_per_sample, seed, size });
            const codec: Codec = if (std.mem.eql(u8, name, "adpcm_ima_wav")) .ima_wav else .ms;
            const params: Params = .{ .codec = codec, .channels = channels, .block_align = block_align, .bits_per_coded_sample = bits_per_sample };
            var d = Decoder.init(params) catch {
                // FFmpeg's channel check (EINVAL) comes before IMA WAV's bits.
                const max_channels: u32 = if (codec == .ima_wav) 2 else 6;
                try w.writeAll(if (channels > max_channels) "D EINVAL 0 -\n" else "D INVALIDDATA 0 -\n");
                continue;
            };
            const data = try gpa.alloc(u8, size);
            defer gpa.free(data);
            var rng: Rng = .{ .state = seed };
            for (data) |*b| b.* = @truncate(rng.next());
            if (codec == .ima_wav) {
                var c: usize = 0;
                while (c < channels and 4 * c + 2 < size) : (c += 1) {
                    if (seed & 1 != 0) data[4 * c + 2] %= 89;
                }
            } else {
                var c: usize = 0;
                while (c < channels and c < size) : (c += 1) {
                    if (seed & 1 != 0) data[c] %= 7;
                }
            }
            try decodeLine(w, &d, data, gpa);
        }
    }
}

test "the encoders and decoders give FFmpeg's packets and samples (vectors/adpcm.txt)" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try renderVectors(testing.allocator, &out.writer);
    try testing.expectEqualStrings(@embedFile("../testing/vectors/adpcm.txt"), out.written());
}

// ---- Fuzzing ----

const hostile = @import("../testing/hostile.zig");

/// A fuzz input: a packet (the first slice), then the codec (0 or 1), the
/// channels (1 to 7), IMA WAV's bits (1 to 6) and the block alignment (0 to
/// 4096); the packet decoded in every way FFmpeg would accept the
/// parameters, and encoded back when one or two channels.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const gpa = testing.allocator;
    var input: [8192 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const packet = input[0..len];
    const codec: Codec = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .ima_wav else .ms;
    const channels = smith.valueRangeAtMost(u32, 1, 7);
    const bps = smith.valueRangeAtMost(u32, 1, 6);
    const block_align = smith.valueRangeAtMost(u32, 0, 4096);
    const params: Params = .{ .codec = codec, .channels = channels, .block_align = block_align, .bits_per_coded_sample = bps };
    var d = Decoder.init(params) catch return;
    const n = params.samplesIn(packet.len);
    if (n == 0) return testing.expectError(error.InvalidData, d.decode(packet, &.{}));
    const storage = try gpa.alloc(i16, n * channels);
    defer gpa.free(storage);
    var planes: [6][]i16 = undefined;
    for (0..channels) |c| planes[c] = storage[c * n ..][0..n];
    const frame = d.decode(packet, planes[0..channels]) catch return;
    try testing.expect(frame.samples == n and frame.consumed <= packet.len);
    if (channels <= 2 and n >= 2) {
        const options: EncodeOptions = .{ .block_size = 256, .trellis = bps % 3 };
        var e = try Encoder.init(gpa, codec, channels, options);
        defer e.deinit();
        const frame_planes = try gpa.alloc(i16, e.frame_size * channels);
        defer gpa.free(frame_planes);
        @memset(frame_planes, 0);
        for (0..channels) |c| {
            const take = @min(n, e.frame_size);
            @memcpy(frame_planes[c * e.frame_size ..][0..take], planes[c][0..take]);
        }
        var slices: [2][]const i16 = undefined;
        for (0..channels) |c| slices[c] = frame_planes[c * e.frame_size ..][0..e.frame_size];
        var block: [256]u8 = undefined;
        e.encode(slices[0..channels], &block) catch |err| switch (err) {
            error.TrellisOverflow => {},
            else => return err,
        };
    }
}

/// A seed block: a header, then `n` copies of `fill`.
fn seedBlock(comptime head: []const u8, comptime fill: u8, comptime n: usize) []const u8 {
    const tail: [n]u8 = @splat(fill);
    return head ++ &tail;
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed(seedBlock(&.{ 0x10, 0x00, 0x20, 0x00 }, 0x5a, 252), &.{ 0, 1, 4, 256 }),
    hostile.fuzzSeed(seedBlock(&.{ 0x01, 0x02, 0x10, 0x00, 0x30, 0x00 }, 0xa5, 250), &.{ 1, 2, 4, 256 }),
    hostile.fuzzSeed(seedBlock(&.{ 0x00, 0x00, 0x05, 0x00 }, 0x33, 60), &.{ 0, 1, 3, 64 }),
    hostile.fuzzSeed(seedBlock(&.{ 0x03, 0x05, 0x02, 0x10, 0x00, 0x16, 0x00 }, 0x77, 120), &.{ 1, 3, 4, 128 }),
};

test "fuzz: the ADPCM decoders and encoders on arbitrary blocks and parameters" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: the ADPCM decoders and encoders on mutated seeds" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 64, 0x61647063);
}
