// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// The conversions are those of FFmpeg's C at the pinned reference revision
// (libswresample/audioconvert.c `CONV_FUNC`, dither.c `swri_get_dither`,
// rematrix.c `swri_rematrix_init`), as the reference build (Clang, Linux
// x86-64, -O3 -fno-math-errno, --disable-x86asm) compiles them; the
// instructions were read from its libswresample.a (notes.md "Undefined C
// cases").
//! C's float-to-integer conversions as the reference build computes them,
//! for every input, NaN, infinity and out-of-range values included.
//!
//! FFmpeg has no NaN or overflow case in these conversions. C leaves the
//! result unspecified, so FFmpeg's output is whatever instruction its
//! compiler emitted: on the reference build, `cvtss2si`/`cvtsd2si` for
//! `lrintf`/`lrint` (inlined under -fno-math-errno) and `cvttsd2si` for a
//! plain assignment. Each gives the x86 "integer indefinite" (the most negative
//! value of its width) for NaN, ±inf and overflow. ARM and Windows builds of
//! FFmpeg give other results (notes.md "Follow the reference build"). The
//! port computes the reference build's result on every CPU.
//!
//! Zig's own float-to-integer conversion (`@trunc` into an integer type) must
//! not stand in for these. Out of range or NaN it is illegal behavior: a panic
//! in Debug and ReleaseSafe, and in ReleaseFast an arbitrary value that can
//! change with the LLVM version and the target. Every function here checks
//! NaN and the range first, so `@trunc` only sees values that fit.
//!
//! Rounding to nearest, ties to even, uses the 2^(mantissa bits) addition,
//! not `@round`. `@round` rounds ties away from zero, and without SSE4.1 it is
//! a compiler-rt call per value. The addition is exact in the default
//! rounding mode with strict float semantics, so every function that relies
//! on it sets `.strict` explicitly. `.optimized` would let LLVM fold
//! `(a + m) - m` back to `a`.
//!
//! Narrowing a returned `i64` to C's `int` (`int v = lrintf(x)`, or
//! `av_clip_int16(lrintf(x))`, whose parameter is an `int`) keeps the low 32
//! bits, as Clang does with the implementation-defined conversion. Callers
//! write `@truncate` with that comment, or use `lrintfInt`.

const std = @import("std");

/// Round to nearest, ties to even, in `F`'s default rounding mode: x86's
/// `cvtss2si`/`cvtsd2si` rounding and C's `rint`. NaN and infinities come
/// back unchanged.
fn roundEven(comptime F: type, x: F) F {
    @setFloatMode(.strict);
    // At or above 2^(mantissa bits), every float of F is already an integer.
    const magic: F = comptime std.math.pow(F, 2, std.math.floatMantissaBits(F));
    const a = @abs(x);
    if (!(a < magic)) return x; // NaN, infinity or already an integer
    // a + magic lies in [2^m, 2^(m+1)), where the spacing is 1, so the sum
    // rounds a to an integer, ties to even; subtracting magic is exact.
    return std.math.copysign((a + magic) - magic, x);
}

/// C's `rint` (and `nearbyint`) in the default rounding mode: the nearest
/// integer as a double, ties to even.
pub fn rint(x: f64) f64 {
    return roundEven(f64, x);
}

/// An already-rounded float to `i64` as x86-64's 64-bit `cvt*2si` gives it:
/// NaN, ±inf and values outside [-2^63, 2^63) give `minInt(i64)`.
fn toI64(comptime F: type, r: F) i64 {
    @setFloatMode(.strict);
    if (!(r >= -0x1p63 and r < 0x1p63)) return std.math.minInt(i64); // NaN fails both
    return @trunc(r); // in range: checked above
}

/// C's `lrintf` (and `llrintf`) on the reference build: `cvtss2si` into a
/// 64-bit register. Ties go to even; NaN, ±inf and |x| >= 2^63 give
/// `minInt(i64)`.
pub fn lrintf(x: f32) i64 {
    return toI64(f32, roundEven(f32, x));
}

/// C's `lrint` (and `llrint`) on the reference build: `cvtsd2si` into a
/// 64-bit register, with the same results as `lrintf`.
pub fn lrint(x: f64) i64 {
    return toI64(f64, roundEven(f64, x));
}

/// C's `int v = lrintf(double_value)` on the reference build
/// (`swri_rematrix_init`'s `native_matrix` and `matrix32`): the double is
/// rounded to float (`cvtsd2ss`; out of range it becomes an infinity), then
/// `lrintf`, then the low 32 bits.
pub fn lrintfInt(x: f64) i32 {
    const f: f32 = @floatCast(x);
    // C converts the long to int; Clang keeps the low 32 bits.
    return @truncate(lrintf(f));
}

/// C's `int32_t v = double_value` (and `int16_t v = double_value`, which
/// the reference build computes as this, then stores the low 16 bits) as
/// `cvttsd2si` into a 32-bit register: toward zero; NaN, ±inf and values
/// whose integer part is outside `i32` give `minInt(i32)`.
/// `swri_get_dither`'s s16p and s32p noise.
pub fn cvttsd2si32(x: f64) i32 {
    @setFloatMode(.strict);
    // trunc(x) fits i32 exactly when -2^31 - 1 < x < 2^31.
    if (!(x > -0x1p31 - 1 and x < 0x1p31)) return std.math.minInt(i32); // NaN fails both
    return @trunc(x); // in range: checked above
}

// Tests ---------------------------------------------------------------------

const testing = std.testing;
const nan32 = std.math.nan(f32);
const inf32 = std.math.inf(f32);
const nan64 = std.math.nan(f64);
const inf64 = std.math.inf(f64);

test "lrintf rounds ties to even" {
    const cases = [_]struct { f32, i64 }{
        .{ 0.5, 0 },             .{ 1.5, 2 },               .{ 2.5, 2 },             .{ 3.5, 4 },
        .{ -0.5, 0 },            .{ -1.5, -2 },             .{ -2.5, -2 },           .{ 0.49999997, 0 },
        .{ 0.50000006, 1 },      .{ -0.0, 0 },              .{ 1e-45, 0 },           .{ 8388607.5, 8388608 },
        .{ 8388606.5, 8388606 }, .{ -8388607.5, -8388608 }, .{ 8388608.0, 8388608 }, .{ 16777217.0, 16777216 },
    };
    for (cases) |c| try testing.expectEqual(c[1], lrintf(c[0]));
}

test "lrint rounds ties to even" {
    const cases = [_]struct { f64, i64 }{
        .{ 0.5, 0 },                                 .{ 1.5, 2 },
        .{ 2.5, 2 },                                 .{ -2.5, -2 },
        .{ 4503599627370495.5, 4503599627370496 },   .{ 4503599627370494.5, 4503599627370494 },
        .{ -4503599627370495.5, -4503599627370496 }, .{ 4503599627370496.0, 4503599627370496 },
        .{ 0x1p63 - 1024, 0x7fff_ffff_ffff_fc00 },   .{ -0x1p63, std.math.minInt(i64) },
    };
    for (cases) |c| try testing.expectEqual(c[1], lrint(c[0]));
}

test "NaN, infinity and overflow give the most negative value" {
    const min = std.math.minInt(i64);
    for ([_]f32{ nan32, -nan32, inf32, -inf32, 0x1p63, -0x1p64, 3e38, -3e38 }) |x| try testing.expectEqual(min, lrintf(x));
    for ([_]f64{ nan64, -nan64, inf64, -inf64, 0x1p63, -0x1p63 - 2048, 1e300, -1e300 }) |x| try testing.expectEqual(min, lrint(x));
    // Just inside the range.
    try testing.expectEqual(0x7fff_ff80_0000_0000, lrintf(0x1p63 - 0x1p39));
    try testing.expectEqual(min, lrintf(-0x1p63));
}

test "cvttsd2si32 truncates toward zero and gives minInt(i32) out of range" {
    const min = std.math.minInt(i32);
    const cases = [_]struct { f64, i32 }{
        .{ 0.9, 0 },             .{ -0.9, 0 },           .{ 2.5, 2 },
        .{ -2.5, -2 },           .{ 40000.7, 40000 },    .{ 2147483647.9, 2147483647 },
        .{ -2147483648.9, min }, .{ 2147483648.0, min }, .{ -2147483649.0, min },
        .{ nan64, min },         .{ inf64, min },        .{ -inf64, min },
        .{ 1e300, min },
    };
    for (cases) |c| try testing.expectEqual(c[1], cvttsd2si32(c[0]));
    // The s16p dither noise keeps the low 16 bits (swri_get_dither, reference build).
    try testing.expectEqual(-25536, @as(i16, @truncate(cvttsd2si32(40000.7))));
    try testing.expectEqual(0, @as(i16, @truncate(cvttsd2si32(nan64))));
}

test "lrintfInt goes through float and keeps the low 32 bits" {
    // A pan gain of 1e5 times 32768 (swri_rematrix_init): 3276800000.
    try testing.expectEqual(-1018167296, lrintfInt(1e5 * 32768));
    try testing.expectEqual(0, lrintfInt(nan64));
    try testing.expectEqual(0, lrintfInt(1e300)); // inf as float, then INT64_MIN
    try testing.expectEqual(0, lrintfInt(0x1p32));
    // The double is rounded to float first: 0.5000000001 is 0.5 as a float.
    try testing.expectEqual(0, lrintfInt(0.5000000001));
    try testing.expectEqual(16777216, lrintfInt(16777217.0));
}

/// FFmpeg's `av_clip_int16_c`, for the measured-output test below.
fn clipInt16(a: i32) i16 {
    return @intCast(std.math.clamp(a, std.math.minInt(i16), std.math.maxInt(i16)));
}

test "float to s16 gives the pinned ffmpeg's measured output" {
    // av_clip_int16(lrintf(x * (1<<15))): the pinned ffmpeg converting a
    // float WAV with -c:a pcm_s16le (notes.md "Undefined C cases").
    const cases = [_]struct { f32, i16 }{
        .{ 0.5, 16384 },      .{ nan32, 0 },         .{ inf32, 0 },     .{ -inf32, 0 },
        .{ 65536.0, -32768 }, .{ 100000.0, -32768 }, .{ 131072.0, 0 },  .{ -65537.0, 32767 },
        .{ 16777216.0, 0 },   .{ 1e10, -32768 },     .{ 1e19, 0 },      .{ -1e19, 0 },
        .{ 3e38, 0 },         .{ -3e38, 0 },         .{ 1.0, 32767 },   .{ 0.0, 0 },
        .{ -1.0, -32768 },    .{ 0.99999, 32767 },   .{ -0.5, -16384 },
    };
    for (cases) |c| {
        // C converts lrintf's long to av_clip_int16's int; Clang keeps the low 32 bits.
        const low: i32 = @truncate(lrintf(c[0] * 32768));
        try testing.expectEqual(c[1], clipInt16(low));
    }
}

/// An independent model of `lrintf`/`lrint` for the property test: floor,
/// then the fraction decides, ties to the even neighbor.
fn referenceLrint(comptime F: type, x: F) i64 {
    if (std.math.isNan(x) or std.math.isInf(x)) return std.math.minInt(i64);
    const floor = @floor(x);
    const diff = x - floor;
    const up = diff > 0.5 or (diff == 0.5 and @mod(floor, 2) != 0);
    const r = if (up) floor + 1 else floor;
    if (!(r >= -0x1p63 and r < 0x1p63)) return std.math.minInt(i64);
    return @trunc(r);
}

test "rint rounds ties to even and keeps NaN and infinities" {
    try testing.expectEqual(2.0, rint(2.5));
    try testing.expectEqual(-4.0, rint(-3.5));
    try testing.expectEqual(1e300, rint(1e300));
    try testing.expect(std.math.isNan(rint(nan64)));
    try testing.expectEqual(-inf64, rint(-inf64));
    try testing.expect(std.math.signbit(rint(-0.25)));
}

test "lrintf and lrint agree with an independent model on random bit patterns" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_c0de);
    const random = prng.random();
    for (0..200_000) |_| {
        const x32: f32 = @bitCast(random.int(u32));
        try testing.expectEqual(referenceLrint(f32, x32), lrintf(x32));
        const x64: f64 = @bitCast(random.int(u64));
        try testing.expectEqual(referenceLrint(f64, x64), lrint(x64));
        // Small magnitudes, where the rounding happens.
        const s32 = (random.float(f32) - 0.5) * 0x1p25;
        try testing.expectEqual(referenceLrint(f32, s32), lrintf(s32));
        const s64 = (random.float(f64) - 0.5) * 0x1p54;
        try testing.expectEqual(referenceLrint(f64, s64), lrint(s64));
    }
}
