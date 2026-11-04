// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg at commit 5d5a38a7e46be296eab75982c0986054f731e19e:
// the Bessel I0 coefficients below are copied from libavutil/mathematics.c
// (av_bessel_i0: minimax rational approximations of Blair and Edwards, Chalk
// River Report AECL-4928, 1974, taken by FFmpeg from Boost; Boost Software
// License 1.0, whose notice FFmpeg's file keeps). The rest is original,
// following libswresample/resample.c, resample_template.c, resample_dsp.c and
// swresample.c (resample, swr_get_delay) and libavutil/rational.c
// (av_reduce) by Michael Niedermayer and the FFmpeg developers.
//! Sample rate conversion (TODO.md T24): libswresample's polyphase resampler
//! with its defaults (a Kaiser-windowed sinc of 32 taps per phase, 1024
//! phases, or the exact ratio's when it has fewer, linear interpolation
//! between phases, a 0.97 cutoff), in its internal sample formats and
//! kernels, with its input buffering: the first samples reflected before the
//! stream, the last ones after it when it is flushed.
//!
//! The filter is built with `sin` and, past an argument of 15, `exp`; Zig's
//! differ from the C library's in the last bit for a few percent of
//! arguments, so float and double results differ from FFmpeg's within a
//! declared tolerance (port.md "Resampling"; the project owner's choice).
//! Everything else follows FFmpeg's arithmetic.

const std = @import("std");
const libm = @import("../core/libm.zig");
const audio = @import("../core/audio.zig");
const typed_options = @import("../core/options.zig");

pub const FilterType = enum { cubic, blackman_nuttall, kaiser };

/// libswresample's resampler options, with its defaults.
pub const Options = struct {
    filter_size: u32 = 32,
    /// The phase count is `1 << phase_shift`, at most 2^24.
    phase_shift: u5 = 10,
    linear_interp: bool = true,
    /// Use the ratio's exact phase count when it is smaller.
    exact_rational: bool = true,
    /// 0 is libswresample's 0.97.
    cutoff: f64 = 0,
    filter_type: FilterType = .kaiser,
    kaiser_beta: f64 = 9,

    /// libswresample's AVOptions for these fields (options.c), for
    /// `core/options.zig`'s `set`.
    pub const option_specs = [_]typed_options.Spec{
        .{ .name = "filter_size", .field = "filter_size", .kind = .int, .help = "set swr resampling filter size", .min = 0, .max = std.math.maxInt(i32) },
        .{ .name = "phase_shift", .field = "phase_shift", .kind = .int, .help = "set swr resampling phase shift", .min = 0, .max = 24 },
        .{ .name = "linear_interp", .field = "linear_interp", .kind = .bool, .help = "enable linear interpolation", .min = 0, .max = 1 },
        .{ .name = "exact_rational", .field = "exact_rational", .kind = .bool, .help = "enable exact rational", .min = 0, .max = 1 },
        .{ .name = "cutoff", .field = "cutoff", .kind = .double, .help = "set cutoff frequency ratio", .min = 0, .max = 1 },
        .{ .name = "resample_cutoff", .field = "cutoff", .kind = .double, .help = "set cutoff frequency ratio", .min = 0, .max = 1 },
        .{ .name = "filter_type", .field = "filter_type", .kind = .int, .help = "select swr filter type", .min = 0, .max = 2, .constants = &.{
            .{ .name = "cubic", .value = 0 },
            .{ .name = "blackman_nuttall", .value = 1 },
            .{ .name = "kaiser", .value = 2 },
        } },
        .{ .name = "kaiser_beta", .field = "kaiser_beta", .kind = .double, .help = "set swr Kaiser window beta", .min = 2, .max = 16 },
    };

    comptime {
        typed_options.check(Options);
    }
};

pub const Error = error{
    /// The rates or the options give a filter libswresample refuses.
    UnsupportedFormat,
    OutOfMemory,
};

/// The most channels a resampler handles: libswresample's `SWR_CH_MAX`.
pub const max_channels = 64;

/// `av_reduce`: `num / den` in lowest terms, or its best approximation with
/// both parts at most `max`. The second result is false when it is not exact.
pub fn reduce(num_in: i64, den_in: i64, max: i64) struct { num: i64, den: i64, exact: bool } {
    var a0_num: i64 = 0;
    var a0_den: i64 = 1;
    var a1_num: i64 = 1;
    var a1_den: i64 = 0;
    const sign = (num_in < 0) != (den_in < 0);
    var num: i64 = @intCast(@abs(num_in));
    var den: i64 = @intCast(@abs(den_in));
    const gcd = std.math.gcd(@as(u64, @intCast(num)), @as(u64, @intCast(den)));
    if (gcd != 0) {
        num = @divTrunc(num, @as(i64, @intCast(gcd)));
        den = @divTrunc(den, @as(i64, @intCast(gcd)));
    }
    if (num <= max and den <= max) {
        a1_num = num;
        a1_den = den;
        den = 0;
    }
    while (den != 0) {
        const x: i64 = @divTrunc(num, den);
        const next_den = num - den * x;
        const a2n = x * a1_num + a0_num;
        const a2d = x * a1_den + a0_den;
        if (a2n > max or a2d > max) {
            var y = x;
            if (a1_num != 0) y = @divTrunc(max - a0_num, a1_num);
            if (a1_den != 0) y = @min(y, @divTrunc(max - a0_den, a1_den));
            if (den * (2 * y * a1_den + a0_den) > num * a1_den) {
                a1_num = y * a1_num + a0_num;
                a1_den = y * a1_den + a0_den;
            }
            break;
        }
        a0_num = a1_num;
        a0_den = a1_den;
        a1_num = a2n;
        a1_den = a2d;
        num = den;
        den = next_den;
    }
    return .{ .num = if (sign) -a1_num else a1_num, .den = a1_den, .exact = den == 0 };
}

const bessel_p1 = [_]f64{
    -2.2335582639474375249e+15, -5.5050369673018427753e+14, -3.2940087627407749166e+13,
    -8.4925101247114157499e+11, -1.1912746104985237192e+10, -1.0313066708737980747e+08,
    -5.9545626019847898221e+05, -2.4125195876041896775e+03, -7.0935347449210549190e+00,
    -1.5453977791786851041e-02, -2.5172644670688975051e-05, -3.0517226450451067446e-08,
    -2.6843448573468483278e-11, -1.5982226675653184646e-14, -5.2487866627945699800e-18,
};
const bessel_q1 = [_]f64{
    -2.2335582639474375245e+15, 7.8858692566751002988e+12,  -1.2207067397808979846e+10,
    1.0377081058062166144e+07,  -4.8527560179962773045e+03, 1.0,
};
const bessel_p2 = [_]f64{
    -2.2210262233306573296e-04, 1.3067392038106924055e-02,  -4.4700805721174453923e-01,
    5.5674518371240761397e+00,  -2.3517945679239481621e+01, 3.1611322818701131207e+01,
    -9.6090021968656180000e+00,
};
const bessel_q2 = [_]f64{
    -5.5194330231005480228e-04, 3.2547697594819615062e-02,  -1.1151759188741312645e+00,
    1.3982595353892851542e+01,  -6.0228002066743340583e+01, 8.5539563258012929600e+01,
    -3.1446690275135491500e+01, 1.0,
};

/// FFmpeg's `eval_poly`: Horner's rule from the highest coefficient.
fn evalPoly(coeff: []const f64, x: f64) f64 {
    var sum = coeff[coeff.len - 1];
    var i = coeff.len - 1;
    while (i > 0) {
        i -= 1;
        sum *= x;
        sum += coeff[i];
    }
    return sum;
}

/// `av_bessel_i0`: the modified Bessel function of the first kind, order 0.
fn besselI0(x_in: f64) f64 {
    if (x_in == 0) return 1;
    const x = @abs(x_in);
    if (x <= 15) {
        const y = x * x;
        return evalPoly(&bessel_p1, y) / evalPoly(&bessel_q1, y);
    }
    const y = 1 / x - 1.0 / 15.0;
    const r = evalPoly(&bessel_p2, y) / evalPoly(&bessel_q2, y);
    return libm.exp(x) / @sqrt(x) * r;
}

/// `lrintf` of a double: to `float`, then to the nearest integer, ties to even.
fn lrintf(x: f64) i64 {
    const f: f32 = @floatCast(x);
    return @trunc(roundEven(f64, f));
}

/// `llrint`: the nearest integer, ties to even.
fn llrint(x: f64) i64 {
    return @trunc(roundEven(f64, x));
}

fn roundEven(comptime F: type, x: anytype) F {
    const v: F = x;
    const floor = @floor(v);
    const diff = v - floor;
    const up = diff > 0.5 or (diff == 0.5 and @mod(floor, 2) != 0);
    return if (up) floor + 1 else floor;
}

/// The resampler of one internal format: libswresample's `ResampleContext`
/// and the input buffer `swr_convert` keeps for it. `format` is s16p, s32p,
/// fltp or dblp.
pub fn Engine(comptime format: audio.SampleFormat) type {
    return EngineIn(format, false);
}

/// The resampler's positions and buffer counts without its samples: what
/// `resample` returns and `delay` reports, for any input, at a fraction of
/// the cost and with no allocation. Its views carry no data.
pub const Counter = EngineIn(.dblp, true);

fn EngineIn(comptime format: audio.SampleFormat, comptime counting: bool) type {
    return struct {
        const Self = @This();

        /// The sample and filter element type (`DELEM`, `FELEM`).
        pub const Sample = switch (format) {
            .s16p => i16,
            .s32p => i32,
            .fltp => f32,
            .dblp => f64,
            else => @compileError("not an internal format"),
        };
        const filter_shift: u5 = switch (format) {
            .s16p => 15,
            .s32p => 30,
            else => 0,
        };

        gpa: std.mem.Allocator,
        channels: u32,
        in_rate: u32,
        out_rate: u32,
        filter: []Sample,
        filter_length: i32,
        filter_alloc: i32,
        phase_count: i32,
        linear: bool,
        src_incr: i32,
        dst_incr: i32,
        dst_incr_div: i32,
        dst_incr_mod: i32,
        index: i32,
        frac: i32,
        /// `in_buffer`: planar history, `capacity` samples per channel.
        history: [max_channels][]Sample = @splat(&.{}),
        capacity: usize = 0,
        buffer_index: i32 = 0,
        buffer_count: i32 = 0,
        /// `resample_in_constraint`, 0 in a new context.
        in_constraint: bool = false,
        flushed: bool = false,

        /// `resample_init` for these rates: builds the filter bank.
        pub fn init(gpa: std.mem.Allocator, channels: u32, in_rate: u32, out_rate: u32, options: Options) Error!Self {
            std.debug.assert(channels >= 1 and channels <= max_channels);
            const cutoff = if (options.cutoff != 0) options.cutoff else 0.97;
            const out_f: f64 = @floatFromInt(out_rate);
            const in_f: f64 = @floatFromInt(in_rate);
            const factor = @min(out_f * cutoff / in_f, 1.0);
            const one: i32 = 1;
            var phase_count: i32 = one << options.phase_shift;
            const size_f: f64 = @floatFromInt(options.filter_size);
            const length_f = @ceil(size_f / factor);
            // filter_size / factor past INT32_MAX / 256 is refused.
            if (size_f / factor > std.math.maxInt(i32) / 256) return error.UnsupportedFormat;
            var filter_length: i32 = @max(@as(i32, @trunc(length_f)), 1);
            if (filter_length > 1) filter_length = std.mem.alignForward(i32, filter_length, 2);
            if (options.exact_rational) {
                const exact = reduce(out_rate, in_rate, std.math.maxInt(i32));
                if (exact.num <= phase_count) phase_count = @intCast(exact.num);
            }
            const filter_alloc = std.mem.alignForward(i32, filter_length, 8);
            var filter: []Sample = &.{};
            if (!counting) {
                const elements: usize = @as(usize, @intCast(filter_alloc)) * (@as(usize, @intCast(phase_count)) + 1);
                filter = try gpa.alloc(Sample, elements);
                @memset(filter, 0);
                const tab = gpa.alloc(f64, @intCast(filter_length)) catch |err| {
                    gpa.free(filter);
                    return err;
                };
                defer gpa.free(tab);
                buildFilter(filter, tab, factor, filter_length, filter_alloc, phase_count, options.filter_type, options.kaiser_beta);
                const alloc: usize = @intCast(filter_alloc);
                const last_row = alloc * @as(usize, @intCast(phase_count));
                // memcpy(bank + alloc * phase_count + 1, bank, alloc - 1), then
                // the row's first element: the last of row 0.
                @memmove(filter[last_row + 1 ..][0 .. alloc - 1], filter[0 .. alloc - 1]);
                filter[last_row] = filter[alloc - 1];
            }
            errdefer if (!counting) gpa.free(filter);

            // resample_init refuses a ratio av_reduce cannot keep exact.
            const incr = reduce(out_rate, @as(i64, in_rate) * phase_count, std.math.maxInt(i32) / 2);
            if (!incr.exact) return error.UnsupportedFormat;
            var src_incr: i32 = @intCast(incr.num);
            var dst_incr: i32 = @intCast(incr.den);
            while (dst_incr < (1 << 20) and src_incr < (1 << 20)) {
                dst_incr *= 2;
                src_incr *= 2;
            }
            return .{
                .gpa = gpa,
                .channels = channels,
                .in_rate = in_rate,
                .out_rate = out_rate,
                .filter = filter,
                .filter_length = filter_length,
                .filter_alloc = filter_alloc,
                .phase_count = phase_count,
                .linear = options.linear_interp,
                .src_incr = src_incr,
                .dst_incr = dst_incr,
                .dst_incr_div = @divTrunc(dst_incr, src_incr),
                .dst_incr_mod = @rem(dst_incr, src_incr),
                .index = -phase_count * @divTrunc(filter_length - 1, 2),
                .frac = 0,
            };
        }

        pub fn deinit(e: *Self) void {
            if (!counting) {
                e.gpa.free(e.filter);
                for (e.history[0..e.channels]) |h| e.gpa.free(h);
            }
            e.* = undefined;
        }

        /// `build_filter`.
        fn buildFilter(filter: []Sample, tab: []f64, factor_in: f64, tap_count: i32, alloc_i: i32, phase_count: i32, filter_type: FilterType, kaiser_beta: f64) void {
            std.debug.assert(tap_count == 1 or @rem(tap_count, 2) == 0);
            const ph_nb: i32 = if (@rem(phase_count, 2) != 0) phase_count else @divTrunc(phase_count, 2) + 1;
            const center = @divTrunc(tap_count - 1, 2);
            // Upsampling only interpolates.
            const factor = @min(factor_in, 1.0);
            const alloc: usize = @intCast(alloc_i);
            const taps: usize = @intCast(tap_count);
            const phases_f: f64 = @floatFromInt(phase_count);
            var norm: f64 = 0;
            const scale: f64 = @floatFromInt(@as(i64, 1) << filter_shift);
            var ph: i32 = 0;
            while (ph < ph_nb) : (ph += 1) {
                const ph_f: f64 = @floatFromInt(ph);
                var s: f64 = if (factor == 1.0)
                    libm.sin(std.math.pi * ph_f / phases_f) * @as(f64, if (center & 1 != 0) 1 else -1)
                else
                    0;
                for (0..taps) |i| {
                    const offset: f64 = @floatFromInt(@as(i32, @intCast(i)) - center);
                    var x = std.math.pi * (offset - ph_f / phases_f) * factor;
                    var y: f64 = if (x == 0) 1.0 else if (factor == 1.0) s / x else libm.sin(x) / x;
                    switch (filter_type) {
                        .cubic => {
                            const d: f64 = -0.5;
                            x = @abs((offset - ph_f / phases_f) * factor);
                            y = if (x < 1.0)
                                1 - 3 * x * x + 2 * x * x * x + d * (-x * x + x * x * x)
                            else
                                d * (-4 + 8 * x - 5 * x * x + x * x * x);
                        },
                        .blackman_nuttall => {
                            const taps_f: f64 = @floatFromInt(tap_count);
                            const w = 2.0 * x / (factor * taps_f);
                            const t = -libm.cos(w);
                            y *= 0.3635819 - 0.4891775 * t + 0.1365995 * (2 * t * t - 1) - 0.0106411 * (4 * t * t * t - 3 * t);
                        },
                        .kaiser => {
                            const taps_f: f64 = @floatFromInt(tap_count);
                            const w = 2.0 * x / (factor * taps_f * std.math.pi);
                            y *= besselI0(kaiser_beta * @sqrt(@max(1 - w * w, 0)));
                        },
                    }
                    tab[i] = y;
                    s = -s;
                    if (ph == 0) norm += y;
                }
                // Normalized so that a constant stays the same.
                const row: usize = @intCast(ph);
                for (0..taps) |i| filter[row * alloc + i] = coefficient(tab[i] * scale / norm);
                if (@rem(phase_count, 2) != 0) continue;
                const mirror: usize = @intCast(phase_count - ph);
                for (0..taps) |i| filter[mirror * alloc + taps - 1 - i] = filter[row * alloc + i];
            }
        }

        fn coefficient(v: f64) Sample {
            return switch (format) {
                .s16p => @intCast(std.math.clamp(lrintf(v), std.math.minInt(i16), std.math.maxInt(i16))),
                .s32p => @intCast(std.math.clamp(llrint(v), std.math.minInt(i32), std.math.maxInt(i32))),
                .fltp => @floatCast(v),
                .dblp => v,
                else => unreachable,
            };
        }

        /// A view of planar samples: one pointer per channel, moved by
        /// `buf_set`.
        pub const View = struct {
            planes: [max_channels][*]Sample = undefined,

            pub fn shifted(v: View, channels: u32, n: i64) View {
                if (counting) return v;
                var out = v;
                for (out.planes[0..channels]) |*p| {
                    const step: usize = @intCast(@abs(n));
                    if (n >= 0) p.* += step else p.* -= step;
                }
                return out;
            }
        };

        /// `resample_common`: one output sample per position, the filter of
        /// its phase over the input; returns the input samples passed.
        fn resampleCommon(e: *Self, dst: [*]Sample, src: [*]const Sample, n: i32, update: bool) i32 {
            var index = e.index;
            var frac = e.frac;
            var sample_index: i32 = 0;
            while (index >= e.phase_count) {
                sample_index += 1;
                index -= e.phase_count;
            }
            const length: usize = @intCast(e.filter_length);
            var dst_index: usize = 0;
            while (dst_index < n) : (dst_index += 1) {
                if (!counting) e.commonSample(dst, src, dst_index, index, sample_index, length);
                frac += e.dst_incr_mod;
                index += e.dst_incr_div;
                if (frac >= e.src_incr) {
                    frac -= e.src_incr;
                    index += 1;
                }
                while (index >= e.phase_count) {
                    sample_index += 1;
                    index -= e.phase_count;
                }
            }
            if (update) {
                e.frac = frac;
                e.index = index;
            }
            return sample_index;
        }

        fn commonSample(e: *Self, dst: [*]Sample, src: [*]const Sample, dst_index: usize, index: i32, sample_index: i32, length: usize) void {
            {
                const filter = e.filter[@as(usize, @intCast(e.filter_alloc * index))..];
                const base: usize = @intCast(sample_index);
                switch (format) {
                    .s16p, .s32p => {
                        const Acc = if (format == .s16p) i32 else i64;
                        var val: Acc = if (format == .s16p) 1 << 14 else 1 << 29;
                        var val2: Acc = 0;
                        var i: usize = 0;
                        while (i + 1 < length) : (i += 2) {
                            val +%= @as(Acc, src[base + i]) *% @as(Acc, filter[i]);
                            val2 +%= @as(Acc, src[base + i + 1]) *% @as(Acc, filter[i + 1]);
                        }
                        if (i < length) val +%= @as(Acc, src[base + i]) *% @as(Acc, filter[i]);
                        const sum: i64 = @as(i64, val) +% @as(i64, val2);
                        dst[dst_index] = clipShift(sum);
                    },
                    .fltp, .dblp => {
                        var val: Sample = 0;
                        var val2: Sample = 0;
                        var i: usize = 0;
                        while (i + 1 < length) : (i += 2) {
                            val += src[base + i] * filter[i];
                            val2 += src[base + i + 1] * filter[i + 1];
                        }
                        if (i < length) val += src[base + i] * filter[i];
                        dst[dst_index] = val + val2;
                    },
                    else => unreachable,
                }
            }
        }

        /// `resample_linear`: as `resampleCommon`, interpolating between the
        /// position's phase and the next by the fraction.
        fn resampleLinear(e: *Self, dst: [*]Sample, src: [*]const Sample, n: i32, update: bool) i32 {
            var index = e.index;
            var frac = e.frac;
            var sample_index: i32 = 0;
            const inv_src_incr: f64 = 1.0 / @as(f64, @floatFromInt(e.src_incr));
            while (index >= e.phase_count) {
                sample_index += 1;
                index -= e.phase_count;
            }
            const length: usize = @intCast(e.filter_length);
            const alloc: usize = @intCast(e.filter_alloc);
            var dst_index: usize = 0;
            while (dst_index < n) : (dst_index += 1) {
                if (!counting) e.linearSample(dst, src, dst_index, index, frac, sample_index, length, alloc, inv_src_incr);
                frac += e.dst_incr_mod;
                index += e.dst_incr_div;
                if (frac >= e.src_incr) {
                    frac -= e.src_incr;
                    index += 1;
                }
                while (index >= e.phase_count) {
                    sample_index += 1;
                    index -= e.phase_count;
                }
            }
            if (update) {
                e.frac = frac;
                e.index = index;
            }
            return sample_index;
        }

        fn linearSample(e: *Self, dst: [*]Sample, src: [*]const Sample, dst_index: usize, index: i32, frac: i32, sample_index: i32, length: usize, alloc: usize, inv_src_incr: f64) void {
            {
                const filter = e.filter[@as(usize, @intCast(e.filter_alloc * index))..];
                const base: usize = @intCast(sample_index);
                switch (format) {
                    .s16p => {
                        // FELEM2U is uint32, FELEML int64.
                        var val: u32 = 1 << 14;
                        var v2: u32 = 1 << 14;
                        for (0..length) |i| {
                            val +%= @bitCast(@as(i32, src[base + i]) *% @as(i32, filter[i]));
                            v2 +%= @bitCast(@as(i32, src[base + i]) *% @as(i32, filter[i + alloc]));
                        }
                        const diff: i32 = @bitCast(v2 -% val);
                        const step = @divTrunc(@as(i64, diff) * frac, e.src_incr);
                        val = @truncate(@as(u64, @bitCast(@as(i64, val) +% step)));
                        const signed: i32 = @bitCast(val);
                        dst[dst_index] = clipShift(signed);
                    },
                    .s32p => {
                        // FELEM2U is uint64; FELEM2 int64.
                        var val: u64 = 1 << 29;
                        var v2: u64 = 1 << 29;
                        for (0..length) |i| {
                            val +%= @bitCast(@as(i64, src[base + i]) *% @as(i64, filter[i]));
                            v2 +%= @bitCast(@as(i64, src[base + i]) *% @as(i64, filter[i + alloc]));
                        }
                        const diff: i64 = @bitCast(v2 -% val);
                        const step = @divTrunc(diff, e.src_incr) *% frac;
                        val +%= @bitCast(step);
                        const signed: i64 = @bitCast(val);
                        dst[dst_index] = clipShift(signed);
                    },
                    .fltp, .dblp => {
                        var val: Sample = 0;
                        var v2: Sample = 0;
                        for (0..length) |i| {
                            val += src[base + i] * filter[i];
                            v2 += src[base + i] * filter[i + alloc];
                        }
                        // (v2 - val) in the sample type, the rest in double.
                        const d: f64 = v2 - val;
                        const frac_f: f64 = @floatFromInt(frac);
                        const wide: f64 = val;
                        val = @floatCast(wide + d * inv_src_incr * frac_f);
                        dst[dst_index] = val;
                    },
                    else => unreachable,
                }
            }
        }

        /// `OUT`: integers shift down by the filter's scale and clip.
        fn clipShift(v: anytype) Sample {
            const shifted = v >> filter_shift;
            return @intCast(std.math.clamp(shifted, std.math.minInt(Sample), std.math.maxInt(Sample)));
        }

        /// `multiple_resample`: as many output samples as `src_size` inputs
        /// allow, at most `dst_size`; `consumed` gets the inputs passed.
        fn multipleResample(e: *Self, dst: View, dst_size_in: i32, src: View, src_size_in: i32, consumed: *i32) i32 {
            const half_max: i64 = std.math.maxInt(i64) / 2;
            const max_src: i64 = @divTrunc(@divTrunc(half_max, e.phase_count), e.src_incr);
            const src_size: i64 = @min(src_size_in, max_src);
            consumed.* = 0;
            if (e.filter_length == 1 and e.phase_count == 1) {
                const one: i64 = 1 << 32;
                const index2: i64 = @divTrunc(one * e.frac, e.src_incr) + one * e.index + 1;
                const incr: i64 = @divTrunc(one * e.dst_incr, e.src_incr) + 1;
                const new_size: i64 = @divTrunc(src_size * e.src_incr - e.frac + e.dst_incr - 1, e.dst_incr);
                const dst_size: i32 = @intCast(@max(@min(dst_size_in, new_size), 0));
                if (dst_size > 0) {
                    if (!counting) for (0..e.channels) |ch| {
                        var position = index2;
                        for (0..@intCast(dst_size)) |i| {
                            dst.planes[ch][i] = src.planes[ch][@intCast(position >> 32)];
                            position += incr;
                        }
                    };
                    e.index += dst_size * e.dst_incr_div;
                    e.index += @intCast(@divTrunc(e.frac + @as(i64, dst_size) * e.dst_incr_mod, e.src_incr));
                    consumed.* = e.index;
                    e.frac = @intCast(@rem(e.frac + @as(i64, dst_size) * e.dst_incr_mod, e.src_incr));
                    e.index = 0;
                }
                return dst_size;
            }
            const end_index: i64 = (1 + src_size - e.filter_length) * e.phase_count;
            const delta_frac: i64 = (end_index - e.index) * e.src_incr - e.frac;
            const delta_n: i64 = @divTrunc(delta_frac + e.dst_incr - 1, e.dst_incr);
            const dst_size: i32 = @intCast(@max(@min(dst_size_in, delta_n), 0));
            if (dst_size > 0) {
                // The two kernels agree when there is nothing to interpolate.
                const linear = e.linear and (e.frac != 0 or e.dst_incr_mod != 0);
                for (0..e.channels) |ch| {
                    const last = ch + 1 == e.channels;
                    consumed.* = if (linear)
                        e.resampleLinear(dst.planes[ch], src.planes[ch], dst_size, last)
                    else
                        e.resampleCommon(dst.planes[ch], src.planes[ch], dst_size, last);
                }
            }
            return dst_size;
        }

        fn historyView(e: *Self, offset: i32) View {
            var v: View = .{};
            if (counting) return v;
            for (0..e.channels) |ch| v.planes[ch] = e.history[ch].ptr + @as(usize, @intCast(offset));
            return v;
        }

        /// `swri_realloc_audio` for the history: at least `count` samples,
        /// twice that when it grows, keeping what it holds.
        fn reserve(e: *Self, count: usize) Error!void {
            if (e.capacity >= count) return;
            const new_capacity = count * 2;
            if (counting) {
                e.capacity = new_capacity;
                return;
            }
            for (e.history[0..e.channels]) |*h| {
                const grown = try e.gpa.alloc(Sample, new_capacity);
                @memset(grown, zero);
                @memcpy(grown[0..e.capacity], h.*[0..e.capacity]);
                e.gpa.free(h.*);
                h.* = grown;
            }
            e.capacity = new_capacity;
        }

        const zero: Sample = 0;

        fn copyInto(e: *Self, at: i32, from: View, count: i32) void {
            if (counting) return;
            for (0..e.channels) |ch| {
                const dst = e.history[ch][@intCast(at)..][0..@intCast(count)];
                @memcpy(dst, from.planes[ch][0..@intCast(count)]);
            }
        }

        /// `invert_initial_buffer`: until `index` is reached, the first
        /// `filter_length + 1` inputs are gathered and reflected before the
        /// stream. Returns the inputs it took, or null while it waits.
        fn invertInitialBuffer(e: *Self, src: View, in_count: i32) Error!?i32 {
            if (e.index >= 0) return 0;
            try e.reserve(@intCast(e.filter_length * 2 + 1));
            const num = @min(in_count + e.buffer_count, e.filter_length + 1);
            var n = e.buffer_count;
            while (n < num) : (n += 1) {
                if (!counting) for (0..e.channels) |ch| {
                    e.history[ch][@intCast(e.filter_length + n)] = src.planes[ch][@intCast(n - e.buffer_count)];
                };
            }
            if (num < e.filter_length + 1) {
                e.buffer_count = num;
                e.buffer_index = e.filter_length;
                return null;
            }
            var m: i32 = 1;
            while (m <= e.filter_length) : (m += 1) {
                if (!counting) for (0..e.channels) |ch| {
                    e.history[ch][@intCast(e.filter_length - m)] = e.history[ch][@intCast(e.filter_length + m)];
                };
            }
            const taken = num - e.buffer_count;
            e.buffer_index = e.filter_length;
            while (e.index < 0) {
                e.buffer_index -= 1;
                e.index += e.phase_count;
            }
            e.buffer_count = @max(e.buffer_count + e.filter_length, 1 + e.filter_length * 2) - e.buffer_index;
            return @max(taken, 0);
        }

        /// `resample` in swresample.c: resamples `in_count` inputs, with the
        /// history, into at most `out_count` outputs, keeping what is left.
        pub fn resample(e: *Self, out_in: View, out_count_in: i32, in_in: View, in_count_in: i32) Error!i32 {
            var out = out_in;
            var out_count = out_count_in;
            var in = in_in;
            var in_count = in_count_in;
            var ret_sum: i32 = 0;
            // swresample.c's padless: 7 on x86, the reference platform.
            var padless: i32 = 7;
            var border: i32 = 0;
            const taken = try e.invertInitialBuffer(in, in_count) orelse return 0;
            if (taken > 0) {
                border = taken;
                in = in.shifted(e.channels, taken);
                in_count -= taken;
                e.in_constraint = false;
            }
            while (true) {
                var consumed: i32 = 0;
                if (!e.in_constraint and e.buffer_count != 0) {
                    const ret = e.multipleResample(out, out_count, e.historyView(e.buffer_index), e.buffer_count, &consumed);
                    out_count -= ret;
                    ret_sum += ret;
                    out = out.shifted(e.channels, ret);
                    e.buffer_count -= consumed;
                    e.buffer_index += consumed;
                    if (in_count == 0) break;
                    if (e.buffer_count <= border) {
                        in = in.shifted(e.channels, -e.buffer_count);
                        in_count += e.buffer_count;
                        e.buffer_count = 0;
                        e.buffer_index = 0;
                        border = 0;
                    }
                }
                if ((e.flushed or in_count > padless) and e.buffer_count == 0) {
                    e.buffer_index = 0;
                    const ret = e.multipleResample(out, out_count, in, @max(in_count - padless, 0), &consumed);
                    out_count -= ret;
                    ret_sum += ret;
                    out = out.shifted(e.channels, ret);
                    in_count -= consumed;
                    in = in.shifted(e.channels, consumed);
                }
                const size = e.buffer_index + e.buffer_count + in_count;
                if (size > e.capacity and e.buffer_count + in_count <= e.buffer_index) {
                    // Move the history to the start.
                    if (!counting) for (0..e.channels) |ch| {
                        const h = e.history[ch];
                        std.mem.copyForwards(Sample, h[0..@intCast(e.buffer_count)], h[@intCast(e.buffer_index)..][0..@intCast(e.buffer_count)]);
                    };
                    e.buffer_index = 0;
                } else {
                    try e.reserve(@intCast(size));
                }
                if (in_count != 0) {
                    var count = in_count;
                    if (e.buffer_count != 0 and e.buffer_count + 2 < count and out_count != 0) count = e.buffer_count + 2;
                    e.copyInto(e.buffer_index + e.buffer_count, in, count);
                    e.buffer_count += count;
                    in_count -= count;
                    border += count;
                    in = in.shifted(e.channels, count);
                    e.in_constraint = false;
                    if (e.buffer_count != count or in_count != 0) continue;
                    if (padless != 0) {
                        padless = 0;
                        continue;
                    }
                }
                break;
            }
            e.in_constraint = out_count != 0;
            return ret_sum;
        }

        /// `resample_flush`: the last samples reflected after the stream.
        pub fn flush(e: *Self) Error!void {
            if (e.flushed) return;
            const reflection = @divTrunc(@min(e.buffer_count, e.filter_length) + 1, 2);
            try e.reserve(@intCast(e.buffer_index + e.buffer_count + reflection));
            if (!counting) for (0..e.channels) |ch| {
                const h = e.history[ch];
                var j: i32 = 0;
                while (j < reflection) : (j += 1) {
                    h[@intCast(e.buffer_index + e.buffer_count + j)] = h[@intCast(e.buffer_index + e.buffer_count - j - 1)];
                }
            };
            e.buffer_count += reflection;
            e.in_constraint = false;
            e.flushed = true;
        }

        /// `swr_get_delay` with a resampler: the buffered input as output
        /// samples of `base` per second, rounded to the nearest.
        pub fn delay(e: *const Self, base: i64) i64 {
            var num: i64 = e.buffer_count - @divTrunc(e.filter_length - 1, 2);
            num *= e.phase_count;
            num -= e.index;
            num *= e.src_incr;
            num -= e.frac;
            const den: i64 = @as(i64, e.in_rate) * e.src_incr * e.phase_count;
            return rescaleNear(num, base, den);
        }
    };
}

/// The frames libswresample gives for `in_frames` input frames, after its
/// flush: what a known-length writer needs before the first sample. The
/// count does not depend on how the input is cut into calls.
pub fn outputFrames(in_frames: u64, in_rate: u32, out_rate: u32, options: Options) Error!u64 {
    // A counter allocates nothing; the allocator is never used.
    var counter = try Counter.init(std.mem.Allocator.failing, 1, in_rate, out_rate, options);
    defer counter.deinit();
    const view: Counter.View = .{};
    const most: i32 = std.math.maxInt(i32);
    var total: u64 = 0;
    var left = in_frames;
    while (left > 0) {
        const n: i32 = @intCast(@min(left, 1 << 24));
        total += @intCast(try counter.resample(view, most, view, n));
        left -= @intCast(n);
    }
    try counter.flush();
    while (true) {
        const got = try counter.resample(view, most, view, 0);
        if (got <= 0) break;
        total += @intCast(got);
    }
    return total;
}

/// `av_rescale`: `a * b / c`, rounded to the nearest, halves away from zero.
/// `av_rescale`: `a * b / c` rounded to the nearest, halves away from
/// zero, for `b` and `c` above zero and a result that fits.
pub fn rescaleNear(a: i64, b: i64, c: i64) i64 {
    const product: i128 = @as(i128, a) * b;
    const half: i128 = @divTrunc(c, 2);
    const rounded = if (product < 0) -@divTrunc(-product + half, c) else @divTrunc(product + half, c);
    return @intCast(rounded);
}

const vectors = @embedFile("../testing/vectors/resample.txt");
const vector_count = 96;
const audioconvert = @import("audioconvert.zig");
const samples = @import("../core/samples.zig");
const dither = @import("dither.zig");
const native_endian = @import("builtin").cpu.arch.endian();

fn field(fields: *std.mem.TokenIterator(u8, .scalar)) error{MalformedVector}![]const u8 {
    return fields.next() orelse error.MalformedVector;
}

/// The generator's input: resample_vectors.c's smoothed pseudo-random
/// signal in [-1, 1), one memory per channel (graph_vectors.c's too).
pub const Signal = struct {
    state: u64 = 1,
    memory: [64]f64 = @splat(0),

    pub fn next(g: *Signal, channel: usize) f64 {
        g.state = g.state *% 6364136223846793005 +% 1442695040888963407;
        const top: i32 = @bitCast(@as(u32, @truncate(g.state >> 32)));
        const top_f: f64 = @floatFromInt(top);
        const white = top_f / 2147483648.0 * 0.25;
        g.memory[channel] = g.memory[channel] * 0.9 + white * 0.1;
        return g.memory[channel] * 4;
    }
};

fn storeSample(bytes: []u8, format: audio.SampleFormat, v: f64) void {
    switch (format) {
        .u8 => bytes[0] = @intCast(@as(i64, @trunc(roundEven(f64, v * 127 + 128)))),
        .s16 => std.mem.writeInt(i16, bytes[0..2], @intCast(@as(i64, @trunc(roundEven(f64, v * 32767)))), native_endian),
        .s32 => std.mem.writeInt(i32, bytes[0..4], @intCast(@as(i64, @trunc(roundEven(f64, v * 2147483647.0)))), native_endian),
        .flt => {
            const f: f32 = @floatCast(v);
            std.mem.writeInt(u32, bytes[0..4], @bitCast(f), native_endian);
        },
        .dbl => std.mem.writeInt(u64, bytes[0..8], @bitCast(v), native_endian),
        else => unreachable,
    }
}

const Run = struct { out: []u8, frames: usize, delay: i64 };

/// `swr_convert` of the whole input into at most `capacity` frames, then
/// drained 4096 frames at a time, through the internal format.
fn runResample(gpa: std.mem.Allocator, comptime internal: audio.SampleFormat, in: samples.View, frames: u32, in_rate: u32, out_rate: u32, out_format: audio.SampleFormat, capacity: u32) !Run {
    const E = Engine(internal);
    const channels = in.layout.channels;
    var engine = try E.init(gpa, channels, in_rate, out_rate, .{});
    defer engine.deinit();
    const in_internal_layout = try samples.Layout.init(internal, channels, @max(frames, 1), .{ .line = 1 });
    const in_internal_bytes = try gpa.alloc(u8, in_internal_layout.size);
    defer gpa.free(in_internal_bytes);
    const in_internal = try samples.Buffer.init(in_internal_layout, in_internal_bytes);
    if (frames > 0) audioconvert.convert(in_internal, in, 0, 0, frames);
    const mid_layout = try samples.Layout.init(internal, channels, capacity, .{ .line = 1 });
    const mid_bytes = try gpa.alignedAlloc(u8, .@"8", mid_layout.size);
    defer gpa.free(mid_bytes);
    const mid = try samples.Buffer.init(mid_layout, mid_bytes);
    var out_view: E.View = .{};
    var in_view: E.View = .{};
    for (0..channels) |ch| {
        out_view.planes[ch] = @ptrCast(@alignCast(mid.plane(@intCast(ch)).ptr));
        in_view.planes[ch] = @ptrCast(@alignCast(in_internal.plane(@intCast(ch)).ptr));
    }
    var total: i32 = try engine.resample(out_view, @intCast(capacity), in_view, @intCast(frames));
    const delay = engine.delay(out_rate);
    while (total < capacity) {
        try engine.flush();
        const got = try engine.resample(out_view.shifted(channels, total), @intCast(@min(4096, capacity - @as(u32, @intCast(total)))), in_view, 0);
        if (got <= 0) break;
        total += got;
    }
    const count: u32 = @intCast(total);
    const out_layout = try samples.Layout.init(out_format, channels, @max(count, 1), .{ .line = 1 });
    const out_bytes = try gpa.alloc(u8, out_layout.size);
    const out = try samples.Buffer.init(out_layout, out_bytes);
    if (count > 0) audioconvert.convert(out, mid.view(), 0, 0, count);
    return .{ .out = out_bytes, .frames = count, .delay = delay };
}

fn checkVector(line: []const u8, gpa: std.mem.Allocator) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, try field(&fields), "R")) return error.MalformedVector;
    const in_rate = try std.fmt.parseInt(u32, try field(&fields), 10);
    const out_rate = try std.fmt.parseInt(u32, try field(&fields), 10);
    const in_format = audio.SampleFormat.fromName(try field(&fields)) orelse return error.MalformedVector;
    const out_format = audio.SampleFormat.fromName(try field(&fields)) orelse return error.MalformedVector;
    const channels = try std.fmt.parseInt(u32, try field(&fields), 10);
    const frames = try std.fmt.parseInt(u32, try field(&fields), 10);
    const want_delay = try std.fmt.parseInt(i64, try field(&fields), 10);
    const want_frames = try std.fmt.parseInt(usize, try field(&fields), 10);
    const hex = try field(&fields);

    const in_layout = try samples.Layout.init(in_format, channels, @max(frames, 1), .{ .line = 1 });
    const in_bytes = try gpa.alloc(u8, in_layout.size);
    defer gpa.free(in_bytes);
    var signal: Signal = .{};
    const width = in_format.bytesPerSample();
    for (0..frames) |f| {
        for (0..channels) |c| storeSample(in_bytes[(f * channels + c) * width ..], in_format, signal.next(c));
    }
    const in_view = try samples.View.init(in_layout, in_bytes);
    const capacity: u32 = @intCast(frames * @as(u64, out_rate) / in_rate + 8192);
    const internal = dither.internalFormatResampling(in_format, out_format, false, true);
    const run = switch (internal) {
        inline .s16p, .s32p, .fltp, .dblp => |f| try runResample(gpa, f, in_view, frames, in_rate, out_rate, out_format, capacity),
        else => unreachable,
    };
    defer gpa.free(run.out);
    try std.testing.expectEqual(want_delay, run.delay);
    try std.testing.expectEqual(want_frames, run.frames);
    try std.testing.expectEqual(want_frames, try outputFrames(frames, in_rate, out_rate, .{}));
    if (want_frames == 0) return;
    var expected_buffer = try gpa.alloc(u8, hex.len / 2);
    defer gpa.free(expected_buffer);
    const expected = try std.fmt.hexToBytes(expected_buffer[0..], hex);
    // FFmpeg's bytes are little-endian; ours are native.
    @import("../codec/pcm.zig").storedToLittle(out_format, run.out[0..expected.len]);
    try std.testing.expectEqualSlices(u8, expected, run.out[0..expected.len]);
}

test "resampling equals libswresample's byte for byte" {
    const gpa = std.testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        checkVector(line, gpa) catch |err| {
            std.debug.print("resample vector {d}: {s}\n", .{ count + 1, line[0..@min(line.len, 80)] });
            return err;
        };
    }
    try std.testing.expectEqual(vector_count, count);
}

test "any input chunking gives the same output" {
    const gpa = std.testing.allocator;
    const E = Engine(.fltp);
    var input: [700]f32 = undefined;
    var signal: Signal = .{};
    for (&input) |*v| v.* = @floatCast(signal.next(0));
    var reference: [2000]f32 = undefined;
    var reference_len: usize = 0;
    for ([_]usize{ input.len, 1, 7, 64, 333 }, 0..) |chunk, run| {
        var engine = try E.init(gpa, 1, 44100, 48000, .{});
        defer engine.deinit();
        var out: [2000]f32 = undefined;
        var total: usize = 0;
        var at: usize = 0;
        while (at < input.len) : (at += chunk) {
            const n = @min(chunk, input.len - at);
            var in_view: E.View = .{};
            in_view.planes[0] = input[at..].ptr;
            var out_view: E.View = .{};
            out_view.planes[0] = out[total..].ptr;
            total += @intCast(try engine.resample(out_view, @intCast(out.len - total), in_view, @intCast(n)));
        }
        while (true) {
            try engine.flush();
            var out_view: E.View = .{};
            out_view.planes[0] = out[total..].ptr;
            var in_view: E.View = .{};
            in_view.planes[0] = &input;
            const got = try engine.resample(out_view, @intCast(out.len - total), in_view, 0);
            if (got <= 0) break;
            total += @intCast(got);
        }
        if (run == 0) {
            @memcpy(reference[0..total], out[0..total]);
            reference_len = total;
        } else {
            try std.testing.expectEqual(reference_len, total);
            try std.testing.expectEqualSlices(f32, reference[0..total], out[0..total]);
        }
    }
}

const option_vectors = @embedFile("../testing/vectors/options.txt");
const option_vector_count = 136;

/// The option's stored value as `av_opt_get` reads it.
fn storedValue(o: *const Options, name: []const u8) ?f64 {
    inline for (Options.option_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) {
            const v = @field(o, spec.field);
            return switch (@typeInfo(@TypeOf(v))) {
                .bool => if (v) 1 else 0,
                .int => @floatFromInt(v),
                .@"enum" => @floatFromInt(@backingInt(v)),
                .float => v,
                else => unreachable,
            };
        }
    }
    return null;
}

test "options are set as av_opt_set sets them, on every vector" {
    var lines = std.mem.tokenizeScalar(u8, option_vectors, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next().?;
        const name = fields.next().?;
        const text_hex = fields.next().?;
        const want = fields.next().?;
        var buffer: [64]u8 = undefined;
        const text = if (std.mem.eql(u8, text_hex, "-")) "" else try std.fmt.hexToBytes(&buffer, text_hex);
        errdefer std.debug.print("option vector {d}: {s} {s} '{s}'\n", .{ count + 1, kind, name, text });
        var o: Options = .{};
        const result = typed_options.set(Options, &o, name, text);
        // Refused by FFmpeg; X marks an expression, evaluated since T25b.
        if (std.mem.eql(u8, want, "E")) {
            if (result) |_| return error.TestUnexpectedResult else |_| {}
            continue;
        }
        try result;
        const got = storedValue(&o, name).?;
        const expected: f64 = if (std.mem.indexOfScalar(u8, want, 'p') != null)
            try std.fmt.parseFloat(f64, want)
        else
            @floatFromInt(try std.fmt.parseInt(i64, want, 10));
        try std.testing.expectEqual(expected, got);
    }
    try std.testing.expectEqual(option_vector_count, count);
}

test "an unknown option is refused" {
    var o: Options = .{};
    try std.testing.expectError(error.UnknownOption, typed_options.set(Options, &o, "filter_lenght", "32"));
}
