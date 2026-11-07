// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/g726.c (the Float11 helpers, the tables,
// quant, inverse_quant, g726_decode, g726_reset, g726_encode and the
// g726le decoder's and encoder's frame functions) at the pinned reference
// revision.
// Copyright (c) 2004 Roman Shaposhnik
// Copyright (c) 2008 Maxim Poliakovski
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's G.726 ADPCM codec (TODO.md T31c) in its little-endian
//! ("right-justified") form, `g726le`, the one Sun AU carries: 2 to 5 bits
//! a code, each sample decoded as FFmpeg's decoder gives it and each code
//! as FFmpeg's encoder chooses it. The C's narrowing stores (an int16_t
//! return of a wider value) keep their low 16 bits here, as the reference
//! build's do.

const std = @import("std");
const options_zig = @import("../core/options.zig");

/// Float11: a sign, a 4-bit exponent and a 6-bit mantissa.
const Float11 = struct { sign: u8 = 0, exp: u8 = 0, mant: u8 = 0 };

/// `av_log2_16bit` as the reference build compiles it (HAVE_FAST_CLZ):
/// `31 - clz(v | 1)`, over all 32 bits.
fn log2(v: u32) u32 {
    return 31 - @clz(v | 1);
}

fn i2f(value: i32) Float11 {
    var i = value;
    var f: Float11 = .{ .sign = @intFromBool(i < 0) };
    if (f.sign != 0) i = -%i;
    const u: u32 = @bitCast(i);
    f.exp = @truncate(log2(u) + @intFromBool(i != 0));
    f.mant = if (i != 0) @truncate((u << 6) >> @intCast(f.exp)) else 1 << 5;
    return f;
}

/// `mult`, returned as int16_t.
fn mult(f1: Float11, f2: Float11) i16 {
    const exp: i32 = @as(i32, f1.exp) + f2.exp;
    var res: i32 = ((@as(i32, f1.mant) * f2.mant) + 0x30) >> 4;
    res = if (exp > 19) res << @intCast(exp - 19) else res >> @intCast(19 - exp);
    const signed = if ((f1.sign ^ f2.sign) != 0) -res else res;
    return @truncate(signed);
}

fn sgn(value: i32) i32 {
    return if (value < 0) -1 else 1;
}

const Tables = struct {
    quant: []const i32,
    iquant: []const i16,
    w: []const i16,
    f: []const u8,
};

const int_max = std.math.maxInt(i32);
const i16_min = std.math.minInt(i16);

const tables = [4]Tables{
    .{ .quant = &.{ 260, int_max }, .iquant = &.{ 116, 365, 365, 116 }, .w = &.{ -22, 439, 439, -22 }, .f = &.{ 0, 7, 7, 0 } },
    .{
        .quant = &.{ 7, 217, 330, int_max },
        .iquant = &.{ i16_min, 135, 273, 373, 373, 273, 135, i16_min },
        .w = &.{ -4, 30, 137, 582, 582, 137, 30, -4 },
        .f = &.{ 0, 1, 2, 7, 7, 2, 1, 0 },
    },
    .{
        .quant = &.{ -125, 79, 177, 245, 299, 348, 399, int_max },
        .iquant = &.{ i16_min, 4, 135, 213, 273, 323, 373, 425, 425, 373, 323, 273, 213, 135, 4, i16_min },
        .w = &.{ -12, 18, 41, 64, 112, 198, 355, 1122, 1122, 355, 198, 112, 64, 41, 18, -12 },
        .f = &.{ 0, 0, 0, 1, 1, 1, 3, 7, 7, 3, 1, 1, 1, 0, 0, 0 },
    },
    .{
        .quant = &.{ -122, -16, 67, 138, 197, 249, 297, 338, 377, 412, 444, 474, 501, 527, 552, int_max },
        .iquant = &.{ i16_min, -66, 28, 104, 169, 224, 274, 318, 358, 395, 429, 459, 488, 514, 539, 566, 566, 539, 514, 488, 459, 429, 395, 358, 318, 274, 224, 169, 104, 28, -66, i16_min },
        .w = &.{ 14, 14, 24, 39, 40, 41, 58, 100, 141, 179, 219, 280, 358, 440, 529, 696, 696, 529, 440, 358, 280, 219, 179, 141, 100, 58, 41, 40, 39, 24, 14, 14 },
        .f = &.{ 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 6, 6, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
    },
};

/// The samples a channel each packet of FFmpeg's encoder takes, by code
/// size: frames that end on a byte, about 1024 bytes.
pub fn frameSize(code_size: u32) u32 {
    return ([_]u32{ 4096, 2736, 2048, 1640 })[code_size - 2];
}

/// `G726Context`: one channel's state.
pub const Codec = struct {
    code_size: u32,
    tbls: Tables,
    sr: [2]Float11 = @splat(.{}),
    dq: [6]Float11 = @splat(.{}),
    a: [2]i32 = @splat(0),
    b: [6]i32 = @splat(0),
    pk: [2]i32 = @splat(0),
    ap: i32 = 0,
    yu: i32 = 544,
    yl: i32 = 34816,
    dms: i32 = 0,
    dml: i32 = 0,
    td: i32 = 0,
    se: i32 = 0,
    sez: i32 = 0,
    y: i32 = 544,

    /// g726_reset for `code_size` 2 to 5.
    pub fn init(code_size: u32) Codec {
        std.debug.assert(code_size >= 2 and code_size <= 5);
        var c: Codec = .{ .code_size = code_size, .tbls = tables[code_size - 2] };
        for (&c.sr) |*s| s.mant = 1 << 5;
        c.pk = .{ 1, 1 };
        for (&c.dq) |*d| d.mant = 1 << 5;
        return c;
    }

    fn quant(c: *const Codec, d_in: i32) u8 {
        var d = d_in;
        var sign = false;
        if (d < 0) {
            sign = true;
            d = -%d;
        }
        const u: u32 = @bitCast(d);
        const exp: u5 = @intCast(log2(u));
        const dln: i32 = ((@as(i32, exp) << 7) + (@as(i32, @bitCast((u << 7) >> exp)) & 0x7f)) - (c.y >> 2);
        var i: i32 = 0;
        while (c.tbls.quant[@intCast(i)] < int_max and c.tbls.quant[@intCast(i)] < dln) i += 1;
        if (sign) i = ~i;
        // "I'm not sure this is a good idea".
        if (c.code_size != 2 and i == 0) i = 0xff;
        return @truncate(@as(u32, @bitCast(i)));
    }

    /// inverse_quant, returned as int16_t.
    fn inverseQuant(c: *const Codec, i: u32) i16 {
        const dql: i32 = @as(i32, c.tbls.iquant[i]) + (c.y >> 2);
        const dex: u5 = @intCast((dql >> 7) & 0xf);
        const dqt: i32 = (1 << 7) + (dql & 0x7f);
        return if (dql < 0) 0 else @truncate((dqt << dex) >> 7);
    }

    /// g726_decode: one code's sample, returned as int16_t.
    pub fn decode(c: *Codec, code: u32) i16 {
        const i_sig: u32 = code >> @intCast(c.code_size - 1);
        var dq: i32 = c.inverseQuant(code);
        // Transition detect.
        const ylint = c.yl >> 15;
        const ylfrac = (c.yl >> 10) & 0x1f;
        const thr2: i32 = if (ylint > 9) 0x1f << 10 else (0x20 + ylfrac) << @intCast(ylint);
        const tr = c.td == 1 and dq > ((3 * thr2) >> 2);
        if (i_sig != 0) dq = -dq;
        const re_signal: i16 = @truncate(c.se + dq);
        // Update the second order predictor coefficients A2 and A1.
        const pk0: i32 = if (c.sez + dq != 0) sgn(c.sez + dq) else 0;
        const dq0: i32 = if (dq != 0) sgn(dq) else 0;
        if (tr) {
            c.a = .{ 0, 0 };
            c.b = @splat(0);
        } else {
            // "This is a bit crazy, but it really is +255 not +256".
            const fa1 = std.math.clamp((-c.a[0] * c.pk[0] * pk0) >> 5, -256, 255);
            c.a[1] += 128 * pk0 * c.pk[1] + fa1 - (c.a[1] >> 7);
            c.a[1] = std.math.clamp(c.a[1], -12288, 12288);
            c.a[0] += 64 * 3 * pk0 * c.pk[0] - (c.a[0] >> 8);
            c.a[0] = std.math.clamp(c.a[0], -(15360 - c.a[1]), 15360 - c.a[1]);
            for (&c.b, c.dq) |*b, d| b.* += 128 * dq0 * sgn(-@as(i32, d.sign)) - (b.* >> 8);
        }
        // Update Dq, Sr and Pk.
        c.pk[1] = c.pk[0];
        c.pk[0] = if (pk0 != 0) pk0 else 1;
        c.sr[1] = c.sr[0];
        c.sr[0] = i2f(re_signal);
        var k: usize = 5;
        while (k > 0) : (k -= 1) c.dq[k] = c.dq[k - 1];
        c.dq[0] = i2f(dq);
        c.dq[0].sign = @intCast(i_sig); // "Isn't it crazy ?!?!"
        c.td = @intFromBool(c.a[1] < -11776);
        // Update Ap.
        const f: i32 = c.tbls.f[code];
        c.dms += (f << 4) + ((-c.dms) >> 5);
        c.dml += (f << 4) + ((-c.dml) >> 7);
        if (tr) {
            c.ap = 256;
        } else {
            c.ap += (-c.ap) >> 4;
            if (c.y <= 1535 or c.td != 0 or @abs((c.dms << 2) - c.dml) >= @as(u32, @bitCast(c.dml >> 3))) c.ap += 0x20;
        }
        // Update Yu and Yl.
        c.yu = std.math.clamp(c.y + c.tbls.w[code] + ((-c.y) >> 5), 544, 5120);
        c.yl += c.yu + ((-c.yl) >> 6);
        // The next Y.
        const al: i32 = if (c.ap >= 256) 1 << 6 else c.ap >> 2;
        c.y = (c.yl + (c.yu - (c.yl >> 6)) * al) >> 6;
        // The next SE and SEZ.
        c.se = 0;
        for (c.b, c.dq) |b, d| c.se += mult(i2f(b >> 2), d);
        c.sez = c.se >> 1;
        for (c.a, c.sr) |a, s| c.se += mult(i2f(a >> 2), s);
        c.se >>= 1;
        return @truncate(std.math.clamp(@as(i32, re_signal) * 4, -0xffff, 0xffff));
    }

    /// g726_encode: the code for a 16-bit sample.
    pub fn encode(c: *Codec, sig: i16) u8 {
        const mask: u32 = (@as(u32, 1) << @intCast(c.code_size)) - 1;
        const code: u8 = @intCast(c.quant(@divTrunc(@as(i32, sig), 4) - c.se) & mask);
        _ = c.decode(code);
        return code;
    }
};

/// g726_decode_frame for `g726le`: `packet.len * 8 / code_size` samples
/// into `out` (that many), the codes read LSB first.
pub fn decodePacket(c: *Codec, packet: []const u8, out: []i16) usize {
    const n = packet.len * 8 / c.code_size;
    std.debug.assert(out.len >= n);
    var bit: usize = 0;
    for (out[0..n]) |*s| {
        var code: u32 = 0;
        for (0..c.code_size) |b| {
            const at = bit + b;
            code |= @as(u32, (packet[at / 8] >> @intCast(at % 8)) & 1) << @intCast(b);
        }
        bit += c.code_size;
        s.* = c.decode(code);
    }
    return n;
}

/// g726_encode_frame for `g726le`: `samples` encoded into
/// `(len * code_size + 7) / 8` bytes of `out`, LSB first, the last byte's
/// unused high bits zero.
pub fn encodePacket(c: *Codec, samples: []const i16, out: []u8) []u8 {
    const len = (samples.len * c.code_size + 7) / 8;
    std.debug.assert(out.len >= len);
    @memset(out[0..len], 0);
    var bit: usize = 0;
    for (samples) |s| {
        const code = c.encode(s);
        for (0..c.code_size) |b| {
            const at = bit + b;
            out[at / 8] |= @as(u8, @intCast((code >> @intCast(b)) & 1)) << @intCast(at % 8);
        }
        bit += c.code_size;
    }
    return out[0..len];
}

/// g726_encode_init's code size: the `code_size` option (4 by default),
/// or the bit rate over the sample rate, rounded, when a bit rate is set;
/// clipped to 2 to 5.
pub fn encoderCodeSize(option: i64, bit_rate: i64, sample_rate: u32) u32 {
    var cs = option;
    // `(bit_rate + sample_rate / 2) / sample_rate` in int64_t, which wraps
    // in the reference build for a bit rate near INT64_MAX (notes.md "G.726's
    // code size from a bit rate").
    if (bit_rate != 0) cs = @divTrunc(bit_rate +% (sample_rate / 2), sample_rate);
    return @intCast(std.math.clamp(cs, 2, 5));
}

pub const default_code_size = 4;

/// The encoder's private option, `code_size` (2 to 5, 4 by default); a bit
/// rate, when set, overrides it (`encoderCodeSize`).
pub const EncodeOptions = struct {
    code_size: i32 = default_code_size,

    pub const option_specs = [_]options_zig.Spec{
        .{ .name = "code_size", .field = "code_size", .kind = .int, .help = "Bits per code", .min = 2, .max = 5 },
    };
};

const testing = std.testing;
const signals = @import("../testing/signals.zig");

/// The blocks of vectors/g72x.txt for `codec`: each E or R line with the
/// lines up to the next one.
pub fn vectorBlocks(gpa: std.mem.Allocator, expected: []const u8, codec: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var keep = false;
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == 'E' or line[0] == 'R') {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            _ = f.next();
            if (line[0] == 'E') _ = f.next();
            keep = std.mem.eql(u8, f.next().?, codec);
        }
        if (keep) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// A D line: the samples' count and the MD5 of their little-endian bytes.
pub fn writeDecoded(w: *std.Io.Writer, samples: []const i16) !void {
    var md5: std.crypto.hash.Md5 = .init(.{});
    for (samples) |v| {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .little);
        md5.update(&b);
    }
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    try w.print("D 0 {d} {x}\n", .{ samples.len, &digest });
}

pub fn writePacket(w: *std.Io.Writer, packet: []const u8) !void {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(packet, &digest, .{});
    try w.print("P {d} {x}\n", .{ packet.len, &digest });
}

/// An encoder case's E line, parsed.
pub const VectorCase = struct {
    /// The case's index among all E lines, which seeds its signal.
    index: u32,
    line: []const u8,
    name: []const u8,
    codec: []const u8,
    option: i32,
    signal: []const u8,
    samples: u32,
    frame: u32,
    bit_rate: i64,

    pub fn parse(index: u32, line: []const u8) !VectorCase {
        var f = std.mem.tokenizeScalar(u8, line[2..], ' ');
        return .{
            .index = index,
            .line = line,
            .name = f.next().?,
            .codec = f.next().?,
            .option = try std.fmt.parseInt(i32, f.next().?, 10),
            .signal = f.next().?,
            .samples = try std.fmt.parseInt(u32, f.next().?, 10),
            .frame = try std.fmt.parseInt(u32, f.next().?, 10),
            .bit_rate = try std.fmt.parseInt(i64, f.next().?, 10),
        };
    }

    /// The case's samples from `at`, into `out`.
    pub fn fill(t: VectorCase, rng: *signals.Rng, state: *[8]i32, at: usize, out: []i16) void {
        for (out, 0..) |*s, i| s.* = @intCast(signals.sample(rng, t.signal, 0, at + i, state, 16));
    }

    pub fn generator(t: VectorCase) signals.Rng {
        return .{ .state = 0x9E3779B9 ^ (t.samples *% 7 +% t.index) };
    }
};

/// An R line, parsed: a decoder case on pseudo-random packets.
pub const RandomCase = struct {
    bits: u32,
    seed: u32,
    sizes: [16]usize = undefined,
    count: usize = 0,

    pub fn parse(line: []const u8) !RandomCase {
        var f = std.mem.tokenizeScalar(u8, line[2..], ' ');
        _ = f.next();
        var r: RandomCase = .{
            .bits = try std.fmt.parseInt(u32, f.next().?, 10),
            .seed = try std.fmt.parseInt(u32, f.next().?, 10),
        };
        while (f.next()) |s| : (r.count += 1) r.sizes[r.count] = try std.fmt.parseInt(usize, s, 10);
        return r;
    }

    /// Packet `n`'s bytes, drawn in turn from the generator.
    pub fn packet(r: RandomCase, gen: *signals.Rng, n: usize, out: []u8) []u8 {
        for (out[0..r.sizes[n]]) |*b| b.* = @intCast(gen.next() >> 24);
        return out[0..r.sizes[n]];
    }
};

fn renderVectors(gpa: std.mem.Allocator, w: *std.Io.Writer, expected: []const u8) !void {
    var samples: [4096 * 8]i16 = undefined;
    var bytes: [4096]u8 = undefined;
    var index: u32 = 0;
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "E ")) {
            const t = try VectorCase.parse(index, line);
            index += 1;
            if (!std.mem.eql(u8, t.codec, "g726le")) continue;
            try w.print("{s}\n", .{line});
            const cs = encoderCodeSize(t.option, t.bit_rate, 8000);
            const frame = frameSize(cs);
            try w.print("O ok {d} {d}\n", .{ frame, cs });
            var enc: Codec = .init(cs);
            var dec: Codec = .init(cs);
            var gen = t.generator();
            var state: [8]i32 = @splat(0);
            var at: usize = 0;
            while (at < t.samples) : (at += frame) {
                const n = @min(t.samples - at, frame);
                t.fill(&gen, &state, at, samples[0..n]);
                const packet = encodePacket(&enc, samples[0..n], &bytes);
                try writePacket(w, packet);
                const got = decodePacket(&dec, packet, samples[0..]);
                try writeDecoded(w, samples[0..got]);
            }
        } else if (std.mem.startsWith(u8, line, "R g726le ")) {
            try w.print("{s}\n", .{line});
            const r = try RandomCase.parse(line);
            var dec: Codec = .init(r.bits);
            var gen: signals.Rng = .{ .state = r.seed };
            for (0..r.count) |n| {
                const packet = r.packet(&gen, n, &bytes);
                const got = decodePacket(&dec, packet, samples[0..]);
                try writeDecoded(w, samples[0..got]);
            }
        }
    }
    _ = gpa;
}

test "the g726le encoder and decoder give FFmpeg's packets and samples (vectors/g72x.txt)" {
    const gpa = testing.allocator;
    const all = @embedFile("../testing/vectors/g72x.txt");
    const expected = try vectorBlocks(gpa, all, "g726le");
    defer gpa.free(expected);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try renderVectors(gpa, &out.writer, all);
    try testing.expectEqualStrings(expected, out.written());
}

test "code sizes from the option and the bit rate" {
    try testing.expectEqual(4, encoderCodeSize(default_code_size, 0, 8000));
    try testing.expectEqual(3, encoderCodeSize(4, 24000, 8000));
    try testing.expectEqual(2, encoderCodeSize(4, 1000, 8000));
    try testing.expectEqual(5, encoderCodeSize(4, 900000, 8000));
    try testing.expectEqual(2, encoderCodeSize(4, std.math.maxInt(i64), 8000));
}

const hostile = @import("../testing/hostile.zig");

/// The fuzz entry's input: a packet, then the code size, as a value. The
/// packet decodes to `len * 8 / code_size` samples; encoding them packs
/// `(n * code_size + 7) / 8` bytes, and a second encoder packs the same.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [4096 + hostile.max_growth]u8 = undefined;
    const len = smith.slice(&input);
    const cs = smith.valueRangeAtMost(u32, 2, 5);
    var dec: Codec = .init(cs);
    var samples: [4 * input.len]i16 = undefined;
    const n = decodePacket(&dec, input[0..len], &samples);
    try testing.expectEqual(len * 8 / cs, n);
    var bytes: [2][input.len]u8 = undefined;
    var outs: [2][]u8 = undefined;
    for (&outs, &bytes) |*o, *b| {
        var enc: Codec = .init(cs);
        o.* = encodePacket(&enc, samples[0..n], b);
    }
    try testing.expectEqual((n * cs + 7) / 8, outs[0].len);
    try testing.expectEqualSlices(u8, outs[0], outs[1]);
}

const fuzz_corpus: []const []const u8 = &.{
    hostile.fuzzSeed("\x00\x01\x7f\x80\xff\x3c\xc3\x55\xaa", &.{4}),
    hostile.fuzzSeed("\x12\x34\x56\x78\x9a\xbc\xde\xf0\x0f", &.{2}),
    hostile.fuzzSeed("\xff\xff\xff\xff\x00\x00\x00\x00\x80", &.{5}),
};

test "fuzz: the G.726 decoder on arbitrary packets, the encoder on its samples" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus });
}

test "mutation smoke: the G.726 decoder and encoder on mutated packets" {
    try hostile.mutationSmoke({}, fuzzOne, fuzz_corpus, 64, 0x67373236);
}
