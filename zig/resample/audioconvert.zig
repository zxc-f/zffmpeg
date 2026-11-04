// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libswresample/audioconvert.c and swresample.c (the `full_convert` path) at
// the pinned reference revision give the conversions reproduced here.
//! Sample format conversion (TODO.md T23a): every T20a sample format to every
//! other, packed or planar, as libswresample converts when only the format
//! changes (no resampling, rematrixing or dither). Dithered conversion is
//! resample/dither.zig, which the `Converter` stage runs when given one.
//!
//! The conversions are FFmpeg's `CONV_FUNC` table:
//!
//! - integer to integer shifts: up by the width difference, or down
//!   arithmetically (toward minus infinity), u8 offset by 128;
//! - integer to float multiplies the integer, converted to the float type
//!   with round-to-nearest-even, by 2^-(bits - 1), which is exact;
//! - float to integer multiplies by 2^(bits - 1) in the float's own
//!   precision, rounds half to even (`lrint` in the default mode) and clips
//!   to the integer's range (u8 after adding 128);
//! - float to float converts with round-to-nearest-even.
//!
//! So every result is bit-exact with FFmpeg's on the inputs C defines. Where C
//! leaves FFmpeg's `lrint`/`llrint` undefined (NaN, or a product beyond the
//! 64-bit range, such as 1.0 to s64), this file gives what x86-64, the
//! reference platform, gives: the most negative 64-bit value, then clipped.
//! (Windows' 32-bit `long` also overflows `lrint` for finite products from
//! 2^31 to 2^63 in the u8 and s16 paths; this file computes those in 64 bits.)
//! zig/testing/vectors/sampleconv.txt, printed by the pinned libswresample,
//! checks every pair and layout. The kernels are scalar loops specialized at
//! compile time per format pair; nothing allocates.

const std = @import("std");
const builtin = @import("builtin");
const audio = @import("../core/audio.zig");
const samples = @import("../core/samples.zig");
const stage = @import("../core/stage.zig");
const Frame = @import("../core/frame.zig").Frame;
const Dither = @import("dither.zig").Dither;
const rematrix = @import("rematrix.zig");

/// Stored samples are in the target's byte order (T20a).
const native_endian = builtin.cpu.arch.endian();

/// The six sample types, whatever the plane layout.
const Kind = enum {
    u8,
    s16,
    s32,
    s64,
    flt,
    dbl,

    fn of(format: audio.SampleFormat) Kind {
        return switch (format.packedForm()) {
            .u8 => .u8,
            .s16 => .s16,
            .s32 => .s32,
            .s64 => .s64,
            .flt => .flt,
            .dbl => .dbl,
            else => unreachable, // packedForm returns a packed format
        };
    }

    fn Type(comptime kind: Kind) type {
        return switch (kind) {
            .u8 => u8,
            .s16 => i16,
            .s32 => i32,
            .s64 => i64,
            .flt => f32,
            .dbl => f64,
        };
    }

    fn isFloat(comptime kind: Kind) bool {
        return kind == .flt or kind == .dbl;
    }

    /// Value bits of an integer kind.
    fn bits(comptime kind: Kind) comptime_int {
        return @bitSizeOf(kind.Type());
    }
};

fn load(comptime kind: Kind, bytes: *const [@sizeOf(kind.Type())]u8) kind.Type() {
    const T = kind.Type();
    if (comptime kind.isFloat()) {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        return @bitCast(std.mem.readInt(Bits, bytes, native_endian));
    }
    return std.mem.readInt(T, bytes, native_endian);
}

fn store(comptime kind: Kind, bytes: *[@sizeOf(kind.Type())]u8, value: kind.Type()) void {
    const T = kind.Type();
    if (comptime kind.isFloat()) {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        std.mem.writeInt(Bits, bytes, @bitCast(value), native_endian);
    } else {
        std.mem.writeInt(T, bytes, value, native_endian);
    }
}

/// An integer sample at the top of 64 bits: u8 is offset to signed first.
fn widen(comptime kind: Kind, value: kind.Type()) i64 {
    const shift: u6 = 64 - kind.bits();
    return toSigned(kind, value) << shift;
}

/// An integer sample as signed: u8 offset by 128.
fn toSigned(comptime kind: Kind, value: kind.Type()) i64 {
    const wide: i64 = value;
    return if (kind == .u8) wide - 0x80 else wide;
}

/// The inverse shift, arithmetic, so it rounds toward minus infinity.
fn narrow(comptime kind: Kind, wide: i64) kind.Type() {
    const shift: u6 = 64 - kind.bits();
    const shifted = wide >> shift;
    if (kind == .u8) return @intCast(shifted + 0x80);
    return @intCast(shifted);
}
/// Round half to even, as `lrint` does in the default rounding mode.
fn roundEven(x: anytype) @TypeOf(x) {
    const nearest = @round(x); // half away from zero
    if (@abs(x - @trunc(x)) != 0.5) return nearest;
    return 2 * @round(x / 2);
}

/// `llrint` of an already rounded float as x86-64 computes it, the
/// reference platform: NaN and values outside the 64-bit range give the most
/// negative value (the "integer indefinite"), which C leaves undefined.
fn toI64(x: anytype) i64 {
    const F = @TypeOf(x);
    const limit: F = 9223372036854775808.0; // 2^63, exact
    if (std.math.isNan(x) or x >= limit or x < -limit) return std.math.minInt(i64);
    return @intFromFloat(x);
}

/// FFmpeg's `av_clip` to `[min, max]`.
fn clip(comptime T: type, value: i64, min: T, max: T) T {
    return @intCast(std.math.clamp(value, min, max));
}
fn convertSample(comptime out: Kind, comptime in: Kind, value: in.Type()) out.Type() {
    const Out = out.Type();
    if (comptime !in.isFloat() and !out.isFloat()) return narrow(out, widen(in, value));
    if (comptime !in.isFloat()) {
        // The integer as the float type, then the exact power-of-two scale.
        const as_float: Out = @floatFromInt(toSigned(in, value));
        const one: Out = 1;
        const exponent: i32 = in.bits() - 1;
        return as_float * std.math.ldexp(one, -exponent);
    }
    if (comptime out.isFloat()) return @floatCast(value);
    const F = in.Type();
    const one: F = 1;
    const rounded = roundEven(value * std.math.ldexp(one, out.bits() - 1));
    const whole = toI64(rounded);
    // u8 adds 128 before clipping, in 64 bits: the most negative value stays negative.
    if (comptime out == .u8) return clip(u8, whole +| 0x80, 0, 0xFF);
    if (comptime out == .s64) return whole;
    return clip(Out, whole, std.math.minInt(Out), std.math.maxInt(Out));
}
/// Converts `count` samples per channel from `src` at `src_offset` into `dst`
/// at `dst_offset`. Any formats, packed or planar; the channel counts must
/// match, and the ranges must not overlap.
pub fn convert(dst: samples.Buffer, src: samples.View, dst_offset: u32, src_offset: u32, count: u32) void {
    std.debug.assert(dst.layout.channels == src.layout.channels);
    const dst_start: u64 = dst_offset;
    const src_start: u64 = src_offset;
    std.debug.assert(dst_start + count <= dst.layout.samples);
    std.debug.assert(src_start + count <= src.layout.samples);
    switch (Kind.of(dst.layout.format)) {
        inline else => |out| switch (Kind.of(src.layout.format)) {
            inline else => |in| convertKinds(out, in, dst, src, dst_offset, src_offset, count),
        },
    }
}

fn convertKinds(comptime out: Kind, comptime in: Kind, dst: samples.Buffer, src: samples.View, dst_offset: u32, src_offset: u32, count: u32) void {
    const in_size = @sizeOf(in.Type());
    const out_size = @sizeOf(out.Type());
    const channels = dst.layout.channels;
    // Bytes between one sample of a channel and the next.
    const in_step: usize = if (src.layout.format.isPlanar()) in_size else in_size * channels;
    const out_step: usize = if (dst.layout.format.isPlanar()) out_size else out_size * channels;
    var ch: u32 = 0;
    while (ch < channels) : (ch += 1) {
        // A channel's first sample: its plane, or its slot in the one plane.
        const from = if (src.layout.format.isPlanar()) src.plane(ch) else src.plane(0)[ch * in_size ..];
        const to = if (dst.layout.format.isPlanar()) dst.plane(ch) else dst.plane(0)[ch * out_size ..];
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const in_at = (src_offset + i) * in_step;
            const out_at = (dst_offset + i) * out_step;
            const value = load(in, from[in_at..][0..in_size]);
            store(out, to[out_at..][0..out_size], convertSample(out, in, value));
        }
    }
}

/// Converts frames to another sample format, rate and layout unchanged, as a
/// send/receive stage (core/stage.zig), dithered or not.
///
/// Holds at most one frame. A received frame borrows the caller's `storage`
/// and stays valid until the next `send` or `reset`; its timestamp is the
/// input's. A frame is read during `send` and not retained; a failed `send`
/// consumes nothing and leaves the state unchanged. The dither's noise runs
/// on across frames, and `reset` does not restart it.
pub const Converter = struct {
    in_format: audio.Format,
    out_format: audio.Format,
    storage: []u8,
    /// libswresample's dither (resample/dither.zig), with its scratch.
    dither: ?Dither = null,
    /// A channel layout change (resample/rematrix.zig, T23c), borrowed:
    /// the remix, then the dither if any, share the scratch.
    remix: ?*const rematrix.Remix = null,
    scratch: []u8 = &.{},
    pending: ?Frame = null,
    state: stage.State = .accepting,

    pub const Error = stage.SendError || error{
        /// The frame's format is not the converter's input format.
        FormatMismatch,
        /// `storage` cannot hold the converted samples, or the scratch the
        /// dither's internal format.
        OutputTooSmall,
    };

    /// `in_format` and `out_format` must differ only in the sample format.
    /// `storage` bounds the frame size: its samples, converted, must fit in
    /// `storage.len` bytes.
    pub fn init(in_format: audio.Format, out_format: audio.Format, storage: []u8) Converter {
        std.debug.assert(in_format.sample_rate == out_format.sample_rate and in_format.layout.eql(&out_format.layout));
        return .{ .in_format = in_format, .out_format = out_format, .storage = storage };
    }

    /// A converter that dithers with `dither`, made for these formats by
    /// `Dither.init`; `scratch` must hold `dither.scratchLen` bytes for the
    /// largest frame, which also bounds the frame size.
    pub fn initDithered(in_format: audio.Format, out_format: audio.Format, storage: []u8, dither: Dither, scratch: []u8) Converter {
        std.debug.assert(dither.channels == in_format.channelCount() and dither.out_format == out_format.sample_format);
        var c: Converter = .init(in_format, out_format, storage);
        c.dither = dither;
        c.scratch = scratch;
        return c;
    }

    /// A converter that changes the channel layout with `remix`, set up for
    /// these formats by `Remix.init`, and dithers with `dither`, made by
    /// `Dither.initInternal` for the output's channels in `remix.internal`.
    /// `scratch` must hold `remix.scratchLen` bytes for the largest frame.
    /// `remix` must outlive the converter.
    pub fn initRemixed(in_format: audio.Format, out_format: audio.Format, storage: []u8, remix: *const rematrix.Remix, dither: ?Dither, scratch: []u8) Converter {
        std.debug.assert(in_format.sample_rate == out_format.sample_rate);
        std.debug.assert(remix.in_channels == in_format.channelCount() and remix.out_channels == out_format.channelCount());
        return .{ .in_format = in_format, .out_format = out_format, .storage = storage, .remix = remix, .dither = dither, .scratch = scratch };
    }

    pub fn send(c: *Converter, frame: Frame) Error!stage.Send {
        if (c.state != .accepting) return error.InputAfterEnd;
        if (c.pending != null) return .full;
        if (!frame.format.eql(c.in_format)) return error.FormatMismatch;
        const frames = frame.frameCount();
        const out_len = frames * c.out_format.bytesPerFrame();
        if (out_len > c.storage.len) return error.OutputTooSmall;
        if (frames > 0) {
            // Fewer than storage.len bytes, so the count fits in u32 for any
            // storage a caller can hold.
            const count = std.math.cast(u32, frames) orelse return error.OutputTooSmall;
            const layout = samples.Layout.init(c.out_format.sample_format, c.out_format.channelCount(), count, .{ .line = 1 }) catch return error.OutputTooSmall;
            const output = samples.Buffer.init(layout, c.storage) catch unreachable; // checked above
            if (c.remix) |remix| {
                const scratch_len = remix.scratchLen(count);
                if (scratch_len > c.scratch.len) return error.OutputTooSmall;
                rematrix.convert(remix, output, frame.view(), count, c.scratch[0..scratch_len], if (c.dither) |*d| d else null);
            } else if (c.dither) |*d| {
                const scratch_len = d.scratchLen(count);
                if (scratch_len > c.scratch.len) return error.OutputTooSmall;
                d.convert(output, frame.view(), count, c.scratch[0..scratch_len]);
            } else {
                convert(output, frame.view(), 0, 0, count);
            }
        }
        c.pending = .{ .format = c.out_format, .data = c.storage[0..out_len], .pts = frame.pts };
        return .accepted;
    }

    pub fn finishInput(c: *Converter) void {
        if (c.state == .accepting) c.state = .draining;
    }

    pub fn receive(c: *Converter) stage.Receive(Frame) {
        if (c.pending) |frame| {
            c.pending = null;
            return .{ .output = frame };
        }
        switch (c.state) {
            .accepting => return .need_input,
            .draining, .drained => {
                c.state = .drained;
                return .drained;
            },
        }
    }

    pub fn reset(c: *Converter) void {
        c.pending = null;
        c.state = .accepting;
    }
};

comptime {
    stage.check(Converter, Frame, Frame);
}

test "the converter stage converts whole frames and keeps the timestamp" {
    const in_format = try audio.Format.init(8000, 2, .s16);
    const out_format = try audio.Format.init(8000, 2, .fltp);
    var storage: [16]u8 = undefined;
    var converter: Converter = .init(in_format, out_format, &storage);
    const frame = try Frame.fromS16(in_format, &.{ 16384, -32768, 0, 8192 }, 7);
    try std.testing.expectEqual(stage.Send.accepted, try converter.send(frame));
    try std.testing.expectEqual(stage.Send.full, try converter.send(frame));
    const out = converter.receive().output;
    try std.testing.expectEqual(7, out.pts);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]f32{ 0.5, 0, -1, 0.25 }), out.data);
    const mono = try audio.Format.init(8000, 1, .s16);
    try std.testing.expectError(error.FormatMismatch, converter.send(try Frame.fromS16(mono, &.{1}, null)));
    var small: [8]u8 = undefined;
    var tight: Converter = .init(in_format, out_format, &small);
    try std.testing.expectError(error.OutputTooSmall, tight.send(frame));
    converter.finishInput();
    try std.testing.expect(converter.receive() == .drained);
}

fn expectConverted(comptime out: Kind, comptime in: Kind, value: in.Type(), want: out.Type()) !void {
    try std.testing.expectEqual(want, convertSample(out, in, value));
}

test "integer conversions shift as FFmpeg's, u8 offset by 128" {
    try expectConverted(.s16, .u8, 0, -32768);
    try expectConverted(.s16, .u8, 0xFF, 0x7F00);
    try expectConverted(.s64, .u8, 0, std.math.minInt(i64));
    try expectConverted(.u8, .s16, -1, 0x7F); // (-1 >> 8) + 0x80
    try expectConverted(.u8, .s16, 0x7FFF, 0xFF);
    try expectConverted(.s16, .s32, -65537, -2); // toward minus infinity
    try expectConverted(.s32, .s16, -2, -131072);
    try expectConverted(.s16, .s64, std.math.minInt(i64), std.math.minInt(i16));
    try expectConverted(.s32, .s64, 0x1_8000_0000, 1);
}

test "integer to float scales the rounded integer by a power of two" {
    try expectConverted(.flt, .u8, 0, -1.0);
    try expectConverted(.flt, .u8, 0xC0, 0.5);
    try expectConverted(.dbl, .s16, -32768, -1.0);
    // 2^31 - 1 rounds to 2^31 as a float: the product is exactly 1.0.
    try expectConverted(.flt, .s32, std.math.maxInt(i32), 1.0);
    try expectConverted(.dbl, .s32, std.math.maxInt(i32), 1.0 - 1.0 / 2147483648.0);
    try expectConverted(.flt, .s64, std.math.minInt(i64), -1.0);
}

test "float to integer rounds half to even and clips" {
    try expectConverted(.s16, .flt, 0.5 / 32768.0, 0); // 0.5 rounds to 0
    try expectConverted(.s16, .flt, 1.5 / 32768.0, 2);
    try expectConverted(.s16, .flt, -2.5 / 32768.0, -2);
    try expectConverted(.s16, .flt, 1.0, 32767);
    try expectConverted(.s16, .dbl, -1.5, -32768);
    try expectConverted(.u8, .flt, 1.0, 0xFF);
    try expectConverted(.u8, .flt, -1.0, 0);
    try expectConverted(.u8, .dbl, 0.5 / 128.0, 0x80);
    try expectConverted(.s32, .flt, 1.0, std.math.maxInt(i32));
    try expectConverted(.s32, .dbl, -1.0, std.math.minInt(i32));
    try expectConverted(.s64, .dbl, -1.0, std.math.minInt(i64));
    try expectConverted(.s64, .dbl, 0.5, 1 << 62);
    // Where C is undefined, x86-64's most negative 64-bit value, clipped.
    try expectConverted(.s64, .flt, 1.0, std.math.minInt(i64));
    try expectConverted(.s16, .flt, std.math.inf(f32), -32768);
    try expectConverted(.s16, .dbl, std.math.nan(f64), -32768);
    try expectConverted(.u8, .flt, std.math.nan(f32), 0);
    try expectConverted(.s32, .dbl, -std.math.inf(f64), std.math.minInt(i32));
    try expectConverted(.s16, .flt, 65536.0, 32767); // in range for 64 bits
}

test "float to float rounds to nearest even" {
    const ulp24 = 1.0 / 16777216.0; // 2^-24: half a float ulp at 1.0
    try expectConverted(.flt, .dbl, 1.0 + ulp24, 1.0); // a tie, to even
    try expectConverted(.flt, .dbl, 1.0 + 3 * ulp24, 1.0 + 4 * ulp24); // a tie, to even
    const tenth: f32 = 0.1;
    try expectConverted(.dbl, .flt, tenth, tenth);
}

test "packed and planar buffers convert by channel, at any offset" {
    const in_layout = try samples.Layout.init(.s16, 2, 3, .{ .line = 1 });
    var in_bytes: [12]u8 = undefined;
    const input = try samples.Buffer.init(in_layout, &in_bytes);
    // Interleaved left, right: (0, -32768), (16384, 32767), (-1, 1).
    for ([_]i16{ 0, -32768, 16384, 32767, -1, 1 }, 0..) |v, i| std.mem.writeInt(i16, in_bytes[2 * i ..][0..2], v, native_endian);
    const out_layout = try samples.Layout.init(.fltp, 2, 4, .{ .line = 1 });
    var out_bytes: [32]u8 = @splat(0);
    const output = try samples.Buffer.init(out_layout, &out_bytes);
    convert(output, input.view(), 1, 0, 3);
    const left = [_]f32{ 0, 0, 0.5, -1.0 / 32768.0 };
    const right = [_]f32{ 0, -1, 32767.0 / 32768.0, 1.0 / 32768.0 };
    for (left, right, 0..) |l, r, i| {
        try std.testing.expectEqual(l, load(.flt, output.plane(0)[4 * i ..][0..4]));
        try std.testing.expectEqual(r, load(.flt, output.plane(1)[4 * i ..][0..4]));
    }
}

// zig/testing/vectors/sampleconv.txt comes from the pinned FFmpeg's
// libswresample through zig/testing/reference/sampleconv_vectors.c, which
// documents the patterns regenerated below. Every line is checked, and the
// count makes a truncated or missing file fail.
const vectors = @embedFile("../testing/vectors/sampleconv.txt");
const vector_count = 232;

const lcg_multiplier: u64 = 6364136223846793005;
const lcg_increment: u64 = 1442695040888963407;

/// Writes the named pattern's interleaved samples, packed and native-endian,
/// into `out` and returns how many samples it holds.
fn pattern(name: []const u8, kind: Kind, out: []u8) !usize {
    var x: u64 = 1;
    if (std.mem.eql(u8, name, "all") and kind == .u8) {
        for (0..256) |k| out[k] = @intCast(k);
        return 256;
    }
    if (std.mem.eql(u8, name, "all") and kind == .s16) {
        for (0..65536) |k| {
            const k_signed: i32 = @intCast(k);
            const value: i16 = @intCast(k_signed - 32768);
            store(.s16, out[2 * k ..][0..2], value);
        }
        return 65536;
    }
    const frames = 4096;
    if (std.mem.eql(u8, name, "lcg")) {
        const width: usize = switch (kind) {
            .s32 => 4,
            .s64 => 8,
            else => return error.MalformedVector,
        };
        // Little-endian bytes in C; stored samples are native-endian.
        for (0..frames * 2 * width) |i| {
            x = x *% lcg_multiplier +% lcg_increment;
            out[i] = @intCast(x >> 56);
        }
        if (native_endian == .big) {
            var i: usize = 0;
            while (i < frames * 2 * width) : (i += width) std.mem.reverse(u8, out[i..][0..width]);
        }
        return frames * 2;
    }
    const random = std.mem.eql(u8, name, "rand");
    const unit = std.mem.eql(u8, name, "unit");
    if (!random and !unit and !std.mem.eql(u8, name, "wide")) return error.MalformedVector;
    const count: usize = if (random) frames * 2 else 65536;
    for (0..count) |k| {
        var f: f32 = undefined;
        var d: f64 = undefined;
        if (random) {
            x = x *% lcg_multiplier +% lcg_increment;
            const high_bits: u32 = @truncate(x >> 32);
            const high: i32 = @bitCast(high_bits);
            const all: i64 = @bitCast(x);
            const f_value: f32 = @floatFromInt(high);
            const d_value: f64 = @floatFromInt(all);
            f = f_value * (1.0 / 2147483648.0);
            d = d_value * (1.0 / 9223372036854775808.0);
        } else {
            const k_signed: i32 = @intCast(k);
            const centered = k_signed - 32768;
            const numerator = if (unit) centered else centered * 3;
            const f_num: f32 = @floatFromInt(numerator);
            const d_num: f64 = @floatFromInt(numerator);
            f = if (unit) f_num / 32768.0 else f_num / 65536.0;
            d = if (unit) d_num / 32768.0 else d_num / 65536.0;
        }
        switch (kind) {
            .flt => store(.flt, out[4 * k ..][0..4], f),
            .dbl => store(.dbl, out[8 * k ..][0..8], d),
            else => return error.MalformedVector,
        }
    }
    return count;
}

test "every conversion equals the pinned libswresample's" {
    const gpa = std.testing.allocator;
    const packed_in = try gpa.alloc(u8, 65536 * 8);
    defer gpa.free(packed_in);
    const in_bytes = try gpa.alloc(u8, 65536 * 8);
    defer gpa.free(in_bytes);
    const out_bytes = try gpa.alloc(u8, 65536 * 8);
    defer gpa.free(out_bytes);
    var checked: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const in_name = fields.next() orelse return error.MalformedVector;
        const out_name = fields.next() orelse return error.MalformedVector;
        const pattern_name = fields.next() orelse return error.MalformedVector;
        const frames = try std.fmt.parseInt(u32, fields.next() orelse return error.MalformedVector, 10);
        const digest_hex = fields.next() orelse return error.MalformedVector;
        const in_format = std.meta.stringToEnum(audio.SampleFormat, in_name) orelse return error.MalformedVector;
        const out_format = std.meta.stringToEnum(audio.SampleFormat, out_name) orelse return error.MalformedVector;
        const n = try pattern(pattern_name, Kind.of(in_format), packed_in);
        if (n != frames * 2) return error.MalformedVector;

        // The interleaved pattern as the input format lays it out.
        const in_layout = try samples.Layout.init(in_format, 2, frames, .{ .line = 1 });
        const input = try samples.Buffer.init(in_layout, in_bytes);
        const width = in_format.bytesPerSample();
        if (in_format.isPlanar()) {
            for (0..2) |c| for (0..frames) |i| {
                @memcpy(input.plane(@intCast(c))[i * width ..][0..width], packed_in[(i * 2 + c) * width ..][0..width]);
            };
        } else {
            @memcpy(input.bytes, packed_in[0 .. n * width]);
        }
        const out_layout = try samples.Layout.init(out_format, 2, frames, .{ .line = 1 });
        const output = try samples.Buffer.init(out_layout, out_bytes);
        convert(output, input.view(), 0, 0, frames);

        // The digest is of little-endian samples.
        const out_width = out_format.bytesPerSample();
        if (native_endian == .big) {
            var i: usize = 0;
            while (i < output.bytes.len) : (i += out_width) std.mem.reverse(u8, output.bytes[i..][0..out_width]);
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(output.bytes, &digest, .{});
        const actual = std.fmt.bytesToHex(digest, .lower);
        std.testing.expectEqualStrings(digest_hex, &actual) catch |err| {
            std.debug.print("vector: {s}\n", .{line});
            return err;
        };
        checked += 1;
    }
    try std.testing.expectEqual(vector_count, checked);
}
