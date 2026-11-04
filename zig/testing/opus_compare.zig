// SPDX-License-Identifier: BSD-3-Clause
// Derived from libopus 1.5.2's src/opus_compare.c, RFC 6716's conformance
// check. Copyright (c) 2011-2012 Xiph.Org Foundation, Mozilla Corporation.
// Written by Jean-Marc Valin and Timothy B. Terriberry.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
// - Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// - Redistributions in binary form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS ``AS
// IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//! `opus_compare` (TODO.md T28): RFC 6716's quality check of a decoder's
//! 16-bit output against a test vector's reference, a masked per-band
//! spectral error that passes at a quality of 0 or more. A test harness
//! tool, not part of the port; it computes as the C does, in single
//! precision where the C does, with Zig's own cos, sin and log (the metric
//! has no bit-exact result to match).

const std = @import("std");

const nbands = 21;
const nfreqs = 240;
const test_win_size = 480;
const test_win_step = 120;
const opus_pi: f32 = 3.14159265;

/// Bark-derived CELT bands, in 100 Hz bins.
const bands = [nbands + 1]usize{ 0, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 68, 80, 96, 120, 156, 200 };

pub const Result = struct {
    /// The internal weighted error.
    err: f64,
    /// The quality metric in percent; negative fails.
    quality: f32,

    pub fn passes(r: Result) bool {
        return r.quality >= 0;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    /// The sample counts differ.
    LengthMismatch,
    /// Fewer samples than one analysis window.
    TooShort,
};

fn cosf(x: f32) f32 {
    return @floatCast(@cos(@as(f64, x)));
}

fn sinf(x: f32) f32 {
    return @floatCast(@sin(@as(f64, x)));
}

/// band_energy: windowed DFT power per bin (plus a floor) and its mean per
/// band.
fn bandEnergy(gpa: std.mem.Allocator, out: ?[]f32, ps: []f32, nb: usize, in: []const f32, nchannels: usize, nframes: usize, window_sz: usize, step: usize, downsample: f32) Error!void {
    const scratch = try gpa.alloc(f32, (3 + nchannels) * window_sz);
    defer gpa.free(scratch);
    const window = scratch[0..window_sz];
    const c = scratch[window_sz..][0..window_sz];
    const s = scratch[2 * window_sz ..][0..window_sz];
    const x = scratch[3 * window_sz ..];
    const ps_sz = window_sz / 2;
    const wf: f32 = @floatFromInt(window_sz);
    for (window, 0..) |*w, j| w.* = 0.5 - 0.5 * cosf((2 * opus_pi / (wf - 1)) * @as(f32, @floatFromInt(j)));
    for (c, 0..) |*v, j| v.* = cosf((2 * opus_pi / wf) * @as(f32, @floatFromInt(j)));
    for (s, 0..) |*v, j| v.* = sinf((2 * opus_pi / wf) * @as(f32, @floatFromInt(j)));
    for (0..nframes) |xi| {
        for (0..nchannels) |ci| {
            for (0..window_sz) |k| x[ci * window_sz + k] = window[k] * in[(xi * step + k) * nchannels + ci];
        }
        var xj: usize = 0;
        for (0..nb) |bi| {
            var p = [2]f32{ 0, 0 };
            while (xj < bands[bi + 1]) : (xj += 1) {
                for (0..nchannels) |ci| {
                    var re: f32 = 0;
                    var im: f32 = 0;
                    var ti: usize = 0;
                    for (0..window_sz) |k| {
                        re += c[ti] * x[ci * window_sz + k];
                        im -= s[ti] * x[ci * window_sz + k];
                        ti += xj;
                        if (ti >= window_sz) ti -= window_sz;
                    }
                    re *= downsample;
                    im *= downsample;
                    const at = (xi * ps_sz + xj) * nchannels + ci;
                    ps[at] = re * re + im * im + 100000;
                    p[ci] += ps[at];
                }
            }
            if (out) |o| {
                const width: f32 = @floatFromInt(bands[bi + 1] - bands[bi]);
                o[(xi * nbands + bi) * nchannels] = p[0] / width;
                if (nchannels == 2) o[(xi * nbands + bi) * nchannels + 1] = p[1] / width;
            }
        }
    }
}

/// opus_compare: `reference` is the test vector's stereo 16-bit output
/// (averaged to mono when `nchannels` is 1), `decoded` the decoder's at
/// `rate` (48000, 24000, 16000, 12000 or 8000) with `nchannels` channels.
pub fn compare(gpa: std.mem.Allocator, reference: []const i16, decoded: []const i16, nchannels: usize, rate: u32) Error!Result {
    std.debug.assert(nchannels == 1 or nchannels == 2);
    const downsample: usize = 48000 / rate;
    const ybands: usize = switch (rate) {
        8000 => 13,
        12000 => 15,
        16000 => 17,
        24000 => 19,
        else => nbands,
    };
    const yfreqs = nfreqs / downsample;
    const xlength = reference.len / 2;
    const x = try gpa.alloc(f32, xlength * nchannels);
    defer gpa.free(x);
    if (nchannels == 1) {
        for (x, 0..) |*v, i| v.* = @floatCast(0.5 * (@as(f64, @floatFromInt(reference[2 * i])) + @as(f64, @floatFromInt(reference[2 * i + 1]))));
    } else {
        for (x, reference[0 .. 2 * xlength]) |*v, r| v.* = @floatFromInt(r);
    }
    const ylength = decoded.len / nchannels;
    const y = try gpa.alloc(f32, ylength * nchannels);
    defer gpa.free(y);
    for (y, decoded[0 .. ylength * nchannels]) |*v, d| v.* = @floatFromInt(d);
    if (xlength != ylength * downsample) return error.LengthMismatch;
    if (xlength < test_win_size) return error.TooShort;

    const nframes = (xlength - test_win_size + test_win_step) / test_win_step;
    const xb = try gpa.alloc(f32, nframes * nbands * nchannels);
    defer gpa.free(xb);
    const big_x = try gpa.alloc(f32, nframes * nfreqs * nchannels);
    defer gpa.free(big_x);
    const big_y = try gpa.alloc(f32, nframes * yfreqs * nchannels);
    defer gpa.free(big_y);
    // The per-band spectral energy of the original signal and the error.
    try bandEnergy(gpa, xb, big_x, nbands, x, nchannels, nframes, test_win_size, test_win_step, 1);
    try bandEnergy(gpa, null, big_y, ybands, y, nchannels, nframes, test_win_size / downsample, test_win_step / downsample, @floatFromInt(downsample));

    for (0..nframes) |xi| {
        // Frequency masking, low to high: 10 dB/Bark.
        for (1..nbands) |bi| {
            for (0..nchannels) |ci| xb[(xi * nbands + bi) * nchannels + ci] += 0.1 * xb[(xi * nbands + bi - 1) * nchannels + ci];
        }
        // High to low: 15 dB/Bark.
        var bi: usize = nbands - 1;
        while (bi > 0) {
            bi -= 1;
            for (0..nchannels) |ci| xb[(xi * nbands + bi) * nchannels + ci] += 0.03 * xb[(xi * nbands + bi + 1) * nchannels + ci];
        }
        if (xi > 0) {
            // Temporal masking: -3 dB/2.5 ms.
            for (0..nbands) |b| {
                for (0..nchannels) |ci| xb[(xi * nbands + b) * nchannels + ci] += 0.5 * xb[((xi - 1) * nbands + b) * nchannels + ci];
            }
        }
        // Some cross-talk.
        if (nchannels == 2) {
            for (0..nbands) |b| {
                const l = xb[(xi * nbands + b) * nchannels + 0];
                const r = xb[(xi * nbands + b) * nchannels + 1];
                xb[(xi * nbands + b) * nchannels + 0] += 0.01 * r;
                xb[(xi * nbands + b) * nchannels + 1] += 0.01 * l;
            }
        }
        // The masking.
        for (0..ybands) |b| {
            for (bands[b]..bands[b + 1]) |xj| {
                for (0..nchannels) |ci| {
                    const m = 0.1 * xb[(xi * nbands + b) * nchannels + ci];
                    big_x[(xi * nfreqs + xj) * nchannels + ci] += m;
                    big_y[(xi * yfreqs + xj) * nchannels + ci] += m;
                }
            }
        }
    }

    // Consecutive frames averaged, for a slightly less sensitive check.
    for (0..ybands) |b| {
        for (bands[b]..bands[b + 1]) |xj| {
            for (0..nchannels) |ci| {
                var xtmp = big_x[xj * nchannels + ci];
                var ytmp = big_y[xj * nchannels + ci];
                for (1..nframes) |xi| {
                    const xtmp2 = big_x[(xi * nfreqs + xj) * nchannels + ci];
                    const ytmp2 = big_y[(xi * yfreqs + xj) * nchannels + ci];
                    big_x[(xi * nfreqs + xj) * nchannels + ci] += xtmp;
                    big_y[(xi * yfreqs + xj) * nchannels + ci] += ytmp;
                    xtmp = xtmp2;
                    ytmp = ytmp2;
                }
            }
        }
    }

    // At lower rates the last 300 Hz are left out (none at 12 kHz, whose
    // last band already leaves out 400 Hz).
    const max_compare: usize = if (rate == 48000) bands[nbands] else if (rate == 12000) bands[ybands] else bands[ybands] - 3;
    var err: f64 = 0;
    for (0..nframes) |xi| {
        var ef: f64 = 0;
        for (0..ybands) |b| {
            var eb: f64 = 0;
            var xj = bands[b];
            while (xj < bands[b + 1] and xj < max_compare) : (xj += 1) {
                for (0..nchannels) |ci| {
                    const re: f32 = big_y[(xi * yfreqs + xj) * nchannels + ci] / big_x[(xi * nfreqs + xj) * nchannels + ci];
                    var im: f32 = @floatCast(@as(f64, re) - @log(@as(f64, re)) - 1);
                    // Less sensitive around the SILK/CELT cross-over.
                    if (xj >= 79 and xj <= 81) im *= 0.1;
                    if (xj == 80) im *= 0.1;
                    eb += im;
                }
            }
            eb /= @floatFromInt((bands[b + 1] - bands[b]) * nchannels);
            ef += eb * eb;
        }
        // A fixed normalization: slightly lower quality is accepted at
        // lower rates.
        ef /= nbands;
        ef *= ef;
        err += ef * ef;
    }
    err = std.math.pow(f64, err / @as(f64, @floatFromInt(nframes)), 1.0 / 16.0);
    const quality: f32 = @floatCast(100 * (1 - 0.5 * @log(1 + err) / @log(1.13)));
    return .{ .err = err, .quality = quality };
}

const testing = std.testing;

/// A deterministic stereo test signal: a chirp and noise.
fn signal(gpa: std.mem.Allocator, frames: usize) ![]i16 {
    const out = try gpa.alloc(i16, 2 * frames);
    var state: u32 = 1;
    for (0..frames) |i| {
        const t: f64 = @floatFromInt(i);
        state = state *% 1103515245 +% 12345;
        const noise: f64 = @floatFromInt(@as(i32, @intCast(state >> 16)) - 32768);
        const v = 8000 * @sin(t * (0.01 + t * 1e-6)) + noise / 16;
        out[2 * i] = @intFromFloat(v);
        out[2 * i + 1] = @intFromFloat(-v / 2);
    }
    return out;
}

test "a signal compared with itself passes at full quality, a degraded one fails" {
    const gpa = testing.allocator;
    const reference = try signal(gpa, 4800);
    defer gpa.free(reference);
    const same = try compare(gpa, reference, reference, 2, 48000);
    try testing.expect(same.passes());
    try testing.expectApproxEqAbs(@as(f32, 100), same.quality, 0.01);
    const mono = try gpa.alloc(i16, reference.len / 2);
    defer gpa.free(mono);
    for (mono, 0..) |*m, i| m.* = @intCast(@divTrunc(@as(i32, reference[2 * i]) + reference[2 * i + 1], 2));
    try testing.expect((try compare(gpa, reference, mono, 1, 48000)).passes());
    // Every other sample's sign flipped: a different spectrum.
    const bad = try gpa.dupe(i16, reference);
    defer gpa.free(bad);
    for (bad, 0..) |*v, i| {
        if (i % 4 < 2) v.* = -%v.*;
    }
    try testing.expect(!(try compare(gpa, reference, bad, 2, 48000)).passes());
    try testing.expectError(error.LengthMismatch, compare(gpa, reference, reference[0..10], 2, 48000));
}
