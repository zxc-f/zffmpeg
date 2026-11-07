// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/g722.c, g722.h, g722dsp.c, g722dec.c and
// g722enc.c at the pinned reference revision.
// Copyright (c) CMU 1993 Computer Science, Speech Group
//                        Chengxiang Lu and Alex Hauptmann
// Copyright (c) 2005 Steve Underwood <steveu at coppice.org>
// Copyright (c) 2009 Kenan Gillet
// Copyright (c) 2010 Martin Storsjo
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's G.722 ADPCM codec (TODO.md T31c): the decoder at 6, 7 or 8
//! bits a codeword and the encoder, plain or with FFmpeg's trellis search,
//! each byte as FFmpeg's gives it. Two samples make one byte: the QMF
//! splits them into a low band (6 bits) and a high band (2 bits).
//!
//! FFmpeg's trellis writes the frame's last segment one byte late: byte
//! `k` of it carries step `k - 1`'s codes, byte 0 of a frame shorter than
//! 128 bytes the value its path table last held at index 0, and the step
//! the segment ends on lands one byte past the packet, where FFmpeg's
//! padding drops it (an odd last sample then overwrites it). The port
//! writes the same bytes (notes.md "G.722 and G.726").

const std = @import("std");

const sign_lookup = [2]i32{ -1, 1 };

const inv_log2_table = [32]i32{
    2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383,
    2435, 2489, 2543, 2599, 2656, 2714, 2774, 2834,
    2896, 2960, 3025, 3091, 3158, 3228, 3298, 3371,
    3444, 3520, 3597, 3676, 3756, 3838, 3922, 4008,
};
const high_log_factor_step = [2]i32{ 798, -214 };
const high_inv_quant = [4]i32{ -926, -202, 926, 202 };
/// `low_log_factor_step[index] == wl[rl42[index]]`.
const low_log_factor_step = [16]i32{
    -60,  3042, 1198, 538, 334, 172, 58,  -30,
    3042, 1198, 538,  334, 172, 58,  -30, -60,
};
const low_inv_quant4 = [16]i32{
    0,    -2557, -1612, -1121, -786, -530, -323, -150,
    2557, 1612,  1121,  786,   530,  323,  150,  0,
};
const low_inv_quant5 = [32]i32{
    -35,  -35,  -2919, -2195, -1765, -1458, -1219, -1023,
    -858, -714, -587,  -473,  -370,  -276,  -190,  -110,
    2919, 2195, 1765,  1458,  1219,  1023,  858,   714,
    587,  473,  370,   276,   190,   110,   35,    -35,
};
const low_inv_quant6 = [64]i32{
    -17,   -17,   -17,   -17,   -3101, -2738, -2376, -2088,
    -1873, -1689, -1535, -1399, -1279, -1170, -1072, -982,
    -899,  -822,  -750,  -682,  -618,  -558,  -501,  -447,
    -396,  -347,  -300,  -254,  -211,  -170,  -130,  -91,
    3101,  2738,  2376,  2088,  1873,  1689,  1535,  1399,
    1279,  1170,  1072,  982,   899,   822,   750,   682,
    618,   558,   501,   447,   396,   347,   300,   254,
    211,   170,   130,   91,    54,    17,    -54,   -17,
};
/// By `8 - bits_per_codeword`.
const low_inv_quants = [3][]const i32{ &low_inv_quant6, &low_inv_quant5, &low_inv_quant4 };

const low_quant = [29]i32{
    35,   72,   110,  150,  190,  233,  276,  323,
    370,  422,  473,  530,  587,  650,  714,  786,
    858,  940,  1023, 1121, 1219, 1339, 1458, 1612,
    1765, 1980, 2195, 2557, 2919,
};

fn clip(v: i32, lo: i32, hi: i32) i32 {
    return std.math.clamp(v, lo, hi);
}

fn clipInt16(v: i32) i32 {
    return clip(v, std.math.minInt(i16), std.math.maxInt(i16));
}

/// `av_clip_intp2(v, 14)`.
fn clipIntp2_14(v: i32) i32 {
    return clip(v, -(1 << 14), (1 << 14) - 1);
}

/// `struct G722Band`, with C's member widths: every store below is in
/// range of its member, so the narrowing casts cannot fire.
pub const Band = struct {
    s_predictor: i16 = 0,
    s_zero: i32 = 0,
    part_reconst_mem: [2]bool = .{ false, false },
    prev_qtzd_reconst: i16 = 0,
    pole_mem: [2]i16 = .{ 0, 0 },
    diff_mem: [6]i32 = @splat(0),
    zero_mem: [6]i16 = @splat(0),
    log_factor: i16 = 0,
    scale_factor: i16 = 0,

    fn sZero(band: *Band, cur_diff: i32) void {
        const d: i32 = @intFromBool(cur_diff != 0);
        var s: i32 = 0;
        var k: usize = 6;
        while (k > 0) {
            k -= 1;
            const tmp: i32 = if (k == 0) cur_diff * 2 else band.diff_mem[k - 1];
            const step: i32 = if ((band.diff_mem[k] ^ cur_diff) < 0) -128 else 128;
            // ((z * 255) >> 8) + d * ±128 stays within int16: (z * 255) >> 8
            // lies in [-32640, 32639].
            band.zero_mem[k] = @intCast(((@as(i32, band.zero_mem[k]) * 255) >> 8) + d * step);
            band.diff_mem[k] = tmp;
            s += (tmp * band.zero_mem[k]) >> 15;
        }
        band.s_zero = s;
    }

    /// do_adaptive_prediction.
    fn adaptivePrediction(band: *Band, cur_diff: i32) void {
        const cur_part_reconst = band.s_zero + cur_diff < 0;
        const sg0 = sign_lookup[@intFromBool(cur_part_reconst != band.part_reconst_mem[0])];
        const sg1 = sign_lookup[@intFromBool(cur_part_reconst == band.part_reconst_mem[1])];
        band.part_reconst_mem[1] = band.part_reconst_mem[0];
        band.part_reconst_mem[0] = cur_part_reconst;

        const pole0: i32 = band.pole_mem[0];
        const pole1: i32 = band.pole_mem[1];
        const new_pole1 = clip(((sg0 * clip(pole0, -8191, 8191)) >> 5) + sg1 * 128 + ((pole1 * 127) >> 7), -12288, 12288);
        band.pole_mem[1] = @intCast(new_pole1);
        const limit = 15360 - new_pole1;
        band.pole_mem[0] = @intCast(clip(-192 * sg0 + ((pole0 * 255) >> 8), -limit, limit));

        band.sZero(cur_diff);

        const cur_qtzd_reconst = clipInt16((@as(i32, band.s_predictor) + cur_diff) * 2);
        band.s_predictor = @intCast(clipInt16(band.s_zero +
            ((@as(i32, band.pole_mem[0]) * cur_qtzd_reconst) >> 15) +
            ((@as(i32, band.pole_mem[1]) * band.prev_qtzd_reconst) >> 15)));
        band.prev_qtzd_reconst = @intCast(cur_qtzd_reconst);
    }

    fn linearScaleFactor(log_factor: i32) i16 {
        const wd1 = inv_log2_table[@intCast((log_factor >> 6) & 31)];
        const shift = log_factor >> 11;
        return @intCast(if (shift < 0) wd1 >> @intCast(-shift) else wd1 << @intCast(shift));
    }

    /// ff_g722_update_low_predictor, `ilow` a 4-bit index.
    fn updateLow(band: *Band, ilow: usize) void {
        band.adaptivePrediction((@as(i32, band.scale_factor) * low_inv_quant4[ilow]) >> 10);
        const lf = clip(((@as(i32, band.log_factor) * 127) >> 7) + low_log_factor_step[ilow], 0, 18432);
        band.log_factor = @intCast(lf);
        band.scale_factor = linearScaleFactor(lf - (8 << 11));
    }

    /// ff_g722_update_high_predictor.
    fn updateHigh(band: *Band, dhigh: i32, ihigh: usize) void {
        band.adaptivePrediction(dhigh);
        const lf = clip(((@as(i32, band.log_factor) * 127) >> 7) + high_log_factor_step[ihigh & 1], 0, 22528);
        band.log_factor = @intCast(lf);
        band.scale_factor = linearScaleFactor(lf - (10 << 11));
    }

    fn highDelta(band: *const Band, ihigh: usize) i32 {
        return (@as(i32, band.scale_factor) * high_inv_quant[ihigh]) >> 10;
    }
};

const prev_samples_buf_size = 1024;

/// The QMF's sample memory, `prev_samples` and `prev_samples_pos`.
const Qmf = struct {
    prev: [prev_samples_buf_size]i16 = @splat(0),
    pos: usize = 22,

    /// Stores two samples and applies g722_apply_qmf to the last 24.
    fn push(q: *Qmf, a: i16, b: i16) [2]i32 {
        q.prev[q.pos] = a;
        q.prev[q.pos + 1] = b;
        q.pos += 2;
        const s = q.prev[q.pos - 24 ..][0..24];
        // ITU-T G.722 Table 11, interleaved as g722dsp.c applies it.
        const c1 = [12]i32{ 3, -11, 12, 32, -210, 951, 3876, -805, 362, -156, 53, -11 };
        const c0 = [12]i32{ -11, 53, -156, 362, -805, 3876, 951, -210, 32, 12, -11, 3 };
        var x0: i32 = 0;
        var x1: i32 = 0;
        for (0..12) |i| {
            x1 += @as(i32, s[2 * i]) * c1[i];
            x0 += @as(i32, s[2 * i + 1]) * c0[i];
        }
        if (q.pos >= prev_samples_buf_size) {
            @memmove(q.prev[0..22], q.prev[q.pos - 22 ..][0..22]);
            q.pos = 22;
        }
        return .{ x0, x1 };
    }
};

/// The decoder's `bits_per_codeword` option: 6 to 8, 8 by default.
pub const default_bits_per_codeword = 8;

pub const Decoder = struct {
    bits_per_codeword: u32,
    band: [2]Band = .{ .{ .scale_factor = 8 }, .{ .scale_factor = 2 } },
    qmf: Qmf = .{},

    pub fn init(bits_per_codeword: u32) Decoder {
        std.debug.assert(bits_per_codeword >= 6 and bits_per_codeword <= 8);
        return .{ .bits_per_codeword = bits_per_codeword };
    }

    /// g722_decode_frame: `2 * packet.len` mono samples into `out`.
    pub fn decodePacket(d: *Decoder, packet: []const u8, out: []i16) []i16 {
        std.debug.assert(out.len >= 2 * packet.len);
        const skip: u3 = @intCast(8 - d.bits_per_codeword);
        const table = low_inv_quants[skip];
        const low_mask: u8 = (@as(u8, 1) << @intCast(6 - @as(u32, skip))) - 1;
        for (packet, 0..) |byte, j| {
            const ihigh: usize = byte >> 6;
            const ilow: usize = (byte >> skip) & low_mask;
            const rlow = clipIntp2_14(((@as(i32, d.band[0].scale_factor) * table[ilow]) >> 10) + d.band[0].s_predictor);
            d.band[0].updateLow(ilow >> @intCast(2 - @as(u32, skip)));
            const dhigh = d.band[1].highDelta(ihigh);
            const rhigh = clipIntp2_14(dhigh + d.band[1].s_predictor);
            d.band[1].updateHigh(dhigh, ihigh);
            // rlow ± rhigh lies in [-32768, 32766].
            const x = d.qmf.push(@intCast(rlow + rhigh), @intCast(rlow - rhigh));
            out[2 * j] = @intCast(clipInt16(x[0] >> 11));
            out[2 * j + 1] = @intCast(clipInt16(x[1] >> 11));
        }
        return out[0 .. 2 * packet.len];
    }
};

const freeze_interval = 128;
/// MAX_FRAME_SIZE: the largest frame the encoder takes.
pub const max_frame_size = 32768;
/// The samples a packet holds when no frame size is asked for: 20 ms at
/// 16 kHz.
pub const default_frame_size = 320;
/// The encoder's `initial_padding`.
pub const initial_padding = 22;
pub const max_trellis = 16;

/// g722_encode_init's frame size check: odd sizes lose one sample (1
/// becomes 2), sizes above the maximum become it; 0 asks for the default.
/// FFmpeg warns when it changes the request.
pub fn effectiveFrameSize(requested: u32) u32 {
    if (requested == 0) return default_frame_size;
    if (requested & 1 == 0 and requested <= max_frame_size) return requested;
    if (requested == 1) return 2;
    if (requested > max_frame_size) return max_frame_size;
    return requested - 1;
}

/// g722_encode_init's trellis check: clipped to 0 to 16, with a warning.
pub fn effectiveTrellis(requested: i32) u32 {
    return @intCast(clip(requested, 0, max_trellis));
}

const Node = struct { state: Band = .{}, ssd: u32 = 0, path: u32 = 0 };
const Path = struct { value: u32 = 0, prev: u32 = 0 };

/// One band's trellis memory, `node_buf`, `nodep_buf` and `paths`, kept
/// for the encoder's life as FFmpeg's are.
const TrellisBand = struct {
    node_buf: []Node,
    /// Indices into `node_buf`; null where FFmpeg's pointer is.
    nodep: []?u32,
    paths: []Path,
};

pub const Encoder = struct {
    band: [2]Band = .{ .{ .scale_factor = 8 }, .{ .scale_factor = 2 } },
    qmf: Qmf = .{},
    trellis: u32 = 0,
    tb: [2]TrellisBand = undefined,

    /// `trellis` is effectiveTrellis's result; above 0 it allocates
    /// FFmpeg's buffers, 2^trellis * 128 path entries a band.
    pub fn init(gpa: std.mem.Allocator, trellis: u32) error{OutOfMemory}!Encoder {
        std.debug.assert(trellis <= max_trellis);
        var e: Encoder = .{ .trellis = trellis };
        if (trellis == 0) return e;
        const frontier = @as(usize, 1) << @intCast(trellis);
        var done: usize = 0;
        errdefer for (e.tb[0..done]) |t| {
            gpa.free(t.paths);
            gpa.free(t.node_buf);
            gpa.free(t.nodep);
        };
        for (&e.tb) |*t| {
            const paths = try gpa.alloc(Path, frontier * freeze_interval);
            errdefer gpa.free(paths);
            const node_buf = try gpa.alloc(Node, 2 * frontier);
            errdefer gpa.free(node_buf);
            const nodep = try gpa.alloc(?u32, 2 * frontier);
            @memset(paths, .{});
            @memset(node_buf, .{});
            @memset(nodep, null);
            t.* = .{ .node_buf = node_buf, .nodep = nodep, .paths = paths };
            done += 1;
        }
        return e;
    }

    pub fn deinit(e: *Encoder, gpa: std.mem.Allocator) void {
        if (e.trellis != 0) for (e.tb) |t| {
            gpa.free(t.paths);
            gpa.free(t.node_buf);
            gpa.free(t.nodep);
        };
        e.* = undefined;
    }

    fn filterSamples(e: *Encoder, a: i16, b: i16) [2]i32 {
        const x = e.qmf.push(a, b);
        return .{ (x[0] + x[1]) >> 14, (x[0] - x[1]) >> 14 };
    }

    fn encodeByte(e: *Encoder, a: i16, b: i16) u8 {
        const x = e.filterSamples(a, b);
        const ihigh = encodeHigh(&e.band[1], x[1]);
        const ilow = encodeLow(&e.band[0], x[0]);
        e.band[1].updateHigh(e.band[1].highDelta(ihigh), ihigh);
        e.band[0].updateLow(ilow >> 2);
        return @intCast(ihigh << 6 | ilow);
    }

    /// g722_encode_frame: `samples` (at most max_frame_size) into
    /// `(samples.len + 1) / 2` bytes of `out`.
    pub fn encodeFrame(e: *Encoder, samples: []const i16, out: []u8) []u8 {
        std.debug.assert(samples.len <= max_frame_size);
        const out_size = (samples.len + 1) / 2;
        std.debug.assert(out.len >= out_size);
        const dst = out[0..out_size];
        const n = samples.len & ~@as(usize, 1);
        if (e.trellis != 0) {
            e.encodeTrellis(dst, samples[0..n]);
        } else {
            var i: usize = 0;
            while (i < n) : (i += 2) dst[i / 2] = e.encodeByte(samples[i], samples[i + 1]);
        }
        // The last frame's odd sample, doubled.
        if (n < samples.len) dst[n / 2] = e.encodeByte(samples[n], samples[n]);
        return dst;
    }

    fn encodeTrellis(e: *Encoder, dst: []u8, samples: []const i16) void {
        const frontier = @as(usize, 1) << @intCast(e.trellis);
        // nodes[b] and nodes_next[b] are the two halves of tb[b].nodep.
        var nodes: [2][]?u32 = undefined;
        var nodes_next: [2][]?u32 = undefined;
        var pathn = [2]u32{ 0, 0 };
        var froze: isize = -1;
        for (0..2) |b| {
            const t = &e.tb[b];
            nodes[b] = t.nodep[0..frontier];
            nodes_next[b] = t.nodep[frontier..];
            @memset(t.nodep, null);
            nodes[b][0] = @intCast(frontier);
            t.node_buf[frontier] = .{ .state = e.band[b], .ssd = 0, .path = 0 };
        }

        const steps = samples.len / 2;
        var i: usize = 0;
        while (i < steps) : (i += 1) {
            var next = [2]u32{ @intCast(frontier * (i & 1)), @intCast(frontier * (i & 1)) };
            var heap_pos = [2]usize{ 0, 0 };
            for (0..2) |b| @memset(nodes_next[b], null);

            const x = e.filterSamples(samples[2 * i], samples[2 * i + 1]);

            var j: usize = 0;
            while (j < frontier) : (j += 1) {
                const cur_idx = nodes[0][j] orelse break;
                // Only k >> 2 changes the adaptive state: k steps by 4
                // around encode_low's choice, for the better half only.
                const range: i32 = if (j < frontier / 2) 4 else 0;
                const cur = e.tb[0].node_buf[cur_idx];
                const ilow: i32 = @intCast(encodeLow(&cur.state, x[0]));
                var k = ilow - range;
                while (k <= ilow + range and k <= 63) : (k += 4) {
                    if (k < 0) continue;
                    const ku: usize = @intCast(k);
                    const decoded = clipIntp2_14(((@as(i32, cur.state.scale_factor) * low_inv_quant6[ku]) >> 10) + cur.state.s_predictor);
                    const node = e.storeNode(0, frontier, &cur, x[0] - decoded, &heap_pos[0], &next[0], &pathn[0], nodes_next[0]) orelse continue;
                    node.state.updateLow(ku >> 2);
                    e.tb[0].paths[node.path] = .{ .value = @intCast(ku), .prev = cur.path };
                }
            }

            j = 0;
            while (j < frontier) : (j += 1) {
                const cur_idx = nodes[1][j] orelse break;
                const cur = e.tb[1].node_buf[cur_idx];
                // All four high codes are tried.
                for (0..4) |ihigh| {
                    const dhigh = cur.state.highDelta(ihigh);
                    const decoded = clipIntp2_14(dhigh + cur.state.s_predictor);
                    const node = e.storeNode(1, frontier, &cur, x[1] - decoded, &heap_pos[1], &next[1], &pathn[1], nodes_next[1]) orelse continue;
                    node.state.updateHigh(dhigh, ihigh);
                    e.tb[1].paths[node.path] = .{ .value = @intCast(ihigh), .prev = cur.path };
                }
            }

            for (0..2) |b| {
                std.mem.swap([]?u32, &nodes[b], &nodes_next[b]);
                const nb = e.tb[b].node_buf;
                const root = nodes[b][0].?;
                if (nb[root].ssd > (1 << 16)) {
                    var k: usize = 1;
                    while (k < frontier) : (k += 1) {
                        const idx = nodes[b][k] orelse break;
                        nb[idx].ssd -%= nb[root].ssd;
                    }
                    nb[root].ssd = 0;
                }
            }

            if (@as(isize, @intCast(i)) == froze + freeze_interval) {
                e.backtrack(dst, &nodes, i, froze);
                froze = @intCast(i);
                pathn = .{ 0, 0 };
                @memset(nodes[0][1..], null);
                @memset(nodes[1][1..], null);
            }
        }

        e.backtrack(dst, &nodes, i, froze);
        e.band[0] = e.tb[0].node_buf[nodes[0][0].?].state;
        e.band[1] = e.tb[1].node_buf[nodes[1][0].?].state;
    }

    /// Writes `dst[j]` for j from `last` down past `froze` from the best
    /// paths. After the loop `last` is the step count, one past the last
    /// step, so the final segment lands one byte late and its first byte
    /// is the path's root entry; the byte past the packet is FFmpeg's
    /// padding, not written.
    fn backtrack(e: *Encoder, dst: []u8, nodes: *const [2][]?u32, last: usize, froze: isize) void {
        var p0 = e.tb[0].paths[e.tb[0].node_buf[nodes[0][0].?].path];
        var p1 = e.tb[1].paths[e.tb[1].node_buf[nodes[1][0].?].path];
        var j: isize = @intCast(last);
        while (j > froze) : (j -= 1) {
            const ju: usize = @intCast(j);
            if (ju < dst.len) dst[ju] = @truncate(p1.value << 6 | p0.value);
            p0 = e.tb[0].paths[p0.prev];
            p1 = e.tb[1].paths[p1.prev];
        }
    }

    /// STORE_NODE up to its UPDATE: the node a candidate with error
    /// `dec_diff` takes, its state copied from `cur`, or null when the
    /// candidate is dropped. Sifts it up the heap; the caller then updates
    /// its state and path, as the macro does before its sift, which reads
    /// only `ssd`.
    fn storeNode(e: *Encoder, b: usize, frontier: usize, cur: *const Node, dec_diff: i32, heap_pos: *usize, next: *u32, pathn: *u32, heap: []?u32) ?*Node {
        // |dec_diff| < 2^16: x is at most 25929 in magnitude (the QMF's
        // coefficient sum times 2^15, over 2^14) and decoded 2^14.
        const ssd = cur.ssd +% @as(u32, @intCast(dec_diff * dec_diff));
        // Wraparound check.
        if (ssd < cur.ssd) return null;
        const nb = e.tb[b].node_buf;
        var pos: usize = undefined;
        var idx: u32 = undefined;
        if (heap_pos.* < frontier) {
            pos = heap_pos.*;
            heap_pos.* += 1;
            std.debug.assert(pathn.* < freeze_interval * frontier);
            idx = next.*;
            next.* += 1;
            heap[pos] = idx;
            nb[idx].path = pathn.*;
            pathn.* += 1;
        } else {
            // Replace a leaf, not always the same one.
            pos = (frontier >> 1) + (heap_pos.* & ((frontier >> 1) - 1));
            if (ssd >= nb[heap[pos].?].ssd) return null;
            heap_pos.* += 1;
            idx = heap[pos].?;
        }
        nb[idx].ssd = ssd;
        nb[idx].state = cur.state;
        while (pos > 0) {
            const parent = (pos - 1) >> 1;
            if (nb[heap[parent].?].ssd <= ssd) break;
            std.mem.swap(?u32, &heap[parent], &heap[pos]);
            pos = parent;
        }
        return &nb[idx];
    }
};

fn encodeHigh(state: *const Band, xhigh: i32) usize {
    const diff = clipInt16(xhigh - state.s_predictor);
    const pred = (141 * @as(i32, state.scale_factor)) >> 8;
    // diff >= 0 ? (diff < pred) + 2 : diff >= -pred
    return @as(usize, @intFromBool((diff ^ (diff >> 31)) < pred)) + 2 * @as(usize, @intFromBool(diff >= 0));
}

fn encodeLow(state: *const Band, xlow: i32) usize {
    const diff = clipInt16(xlow - state.s_predictor);
    // diff >= 0 ? diff : -(diff + 1)
    const limit = ((diff ^ (diff >> 31)) + 1) << 10;
    const sf: i32 = state.scale_factor;
    var i: usize = 0;
    if (limit > low_quant[8] * sf) i = 9;
    while (i < 29 and limit > low_quant[i] * sf) i += 1;
    const base: usize = if (diff < 0) (if (i < 2) 63 else 33) else 61;
    return base - i;
}

test "the QMF's memory wraps as FFmpeg's does" {
    var q: Qmf = .{};
    for (0..1000) |n| _ = q.push(@intCast(n % 300), -@as(i16, @intCast(n % 200)));
    try std.testing.expect(q.pos >= 22 and q.pos < prev_samples_buf_size);
}

test "frame size and trellis checks" {
    try std.testing.expectEqual(320, effectiveFrameSize(0));
    try std.testing.expectEqual(2, effectiveFrameSize(1));
    try std.testing.expectEqual(318, effectiveFrameSize(319));
    try std.testing.expectEqual(max_frame_size, effectiveFrameSize(40001));
    try std.testing.expectEqual(0, effectiveTrellis(-3));
    try std.testing.expectEqual(16, effectiveTrellis(99));
}

const g726 = @import("g726.zig");
const signals = @import("../testing/signals.zig");

fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer, expected: []const u8) !void {
    const samples = try gpa.alloc(i16, max_frame_size + 2 * 4096);
    defer gpa.free(samples);
    const bytes = try gpa.alloc(u8, max_frame_size / 2 + 4096);
    defer gpa.free(bytes);
    var index: u32 = 0;
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "E ")) {
            const t = try g726.VectorCase.parse(index, line);
            index += 1;
            if (!std.mem.eql(u8, t.codec, "g722")) continue;
            try w.print("{s}\n", .{line});
            const frame = effectiveFrameSize(t.frame);
            try w.print("O ok {d} 0\n", .{frame});
            var enc: Encoder = try .init(gpa, effectiveTrellis(t.option));
            defer enc.deinit(gpa);
            var dec: Decoder = .init(default_bits_per_codeword);
            var gen = t.generator();
            var state: [8]i32 = @splat(0);
            var at: usize = 0;
            while (at < t.samples) : (at += frame) {
                const n = @min(t.samples - at, frame);
                t.fill(&gen, &state, at, samples[0..n]);
                const packet = enc.encodeFrame(samples[0..n], bytes);
                try g726.writePacket(w, packet);
                try g726.writeDecoded(w, dec.decodePacket(packet, samples));
            }
        } else if (std.mem.startsWith(u8, line, "R g722 ")) {
            try w.print("{s}\n", .{line});
            const r = try g726.RandomCase.parse(line);
            var dec: Decoder = .init(r.bits);
            var gen: signals.Rng = .{ .state = r.seed };
            for (0..r.count) |n| {
                const packet = r.packet(&gen, n, bytes);
                try g726.writeDecoded(w, dec.decodePacket(packet, samples));
            }
        }
    }
}

test "the g722 encoder and decoder give FFmpeg's packets and samples (vectors/g72x.txt)" {
    const gpa = std.testing.allocator;
    const all = @embedFile("../testing/vectors/g72x.txt");
    const expected = try g726.vectorBlocks(gpa, all, "g722");
    defer gpa.free(expected);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderVectors(gpa, &out.writer, all);
    try std.testing.expectEqualStrings(expected, out.written());
}

const hostile = @import("../testing/hostile.zig");

/// The fuzz entry's input: a packet, then the bits per codeword and the
/// trellis, as values. The packet decodes to two samples a byte, which
/// the encoder takes back as one frame: a byte a pair of samples, and the
/// same bytes from a second encoder.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const gpa = std.testing.allocator;
    var input: [4096 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const bits = smith.valueRangeAtMost(u32, 6, 8);
    const trellis = smith.valueRangeAtMost(u32, 0, 4);
    var dec: Decoder = .init(bits);
    var samples: [2 * input.len]i16 = undefined;
    const got = dec.decodePacket(input[0..len], &samples);
    try std.testing.expectEqual(2 * len, got.len);
    const frame = got[0..@min(got.len, max_frame_size) -| @intFromBool(len % 3 == 1)];
    var bytes: [2][input.len]u8 = undefined;
    var outs: [2][]u8 = undefined;
    for (&outs, &bytes) |*o, *b| {
        var enc: Encoder = try .init(gpa, trellis);
        defer enc.deinit(gpa);
        o.* = enc.encodeFrame(frame, b);
    }
    try std.testing.expectEqual((frame.len + 1) / 2, outs[0].len);
    try std.testing.expectEqualSlices(u8, outs[0], outs[1]);
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed("\x00\x01\x7f\x80\xff\x3c\xc3\x55\xaa", &.{ 8, 0 }),
    hostile.fuzzSeed("\x12\x34\x56\x78\x9a\xbc\xde\xf0\x0f", &.{ 6, 2 }),
    hostile.fuzzSeed("\xff\xff\xff\xff\x00\x00\x00\x00\x80", &.{ 7, 4 }),
};

test "fuzz: the G.722 decoder on arbitrary packets, the encoder on its samples" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: the G.722 decoder and encoder on mutated packets" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 64, 0x67373232);
}

fn trellisUnderFailures(gpa: std.mem.Allocator, trellis: u32) !void {
    var enc: Encoder = try .init(gpa, trellis);
    defer enc.deinit(gpa);
    var samples: [64]i16 = undefined;
    for (&samples, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i * 997 % 4001)) - 2000);
    var out: [32]u8 = undefined;
    _ = enc.encodeFrame(&samples, &out);
}

test "the trellis encoder frees everything under every allocation failure" {
    try hostile.checkAllocationFailuresWith(std.testing.allocator, hostile.Remaps.both, @as(u32, 3), trellisUnderFailures);
}
