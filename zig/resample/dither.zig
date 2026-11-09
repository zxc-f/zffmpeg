// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg at commit 5d5a38a7e46be296eab75982c0986054f731e19e:
// the noise-shaping filter coefficients below are copied from
// libswresample/noise_shaping_data.c (Copyright (C) 2013 Michael Niedermayer,
// LGPL-2.1-or-later; the filters credit SoX's dither and Shibata's work).
// The rest is original, following libswresample/dither.c, dither_template.c,
// swresample.c (swr_convert_internal) and rematrix_template.c (sum2).
//! Dithered sample format conversion (TODO.md T23a): libswresample's
//! `dither_method` and `dither_scale`, every method, bit-exact.
//!
//! With dither, libswresample converts through an internal planar format
//! (S16P, S32P, FLTP or DBLP, chosen from the input and output formats),
//! adds noise there, and converts out. The noise of channel `c` is a fixed
//! sequence from a linear congruential generator seeded with
//! `(12345678913579 * c + 3141592) mod 2718281828`: rectangular, triangular
//! (the difference of two uniforms) or triangular high-passed, scaled to one
//! output step, then stored in the internal format (truncated for integers).
//! The plain methods add it (`sum2`, so integers wrap as FFmpeg's do); the
//! noise-shaping methods feed the quantization error back through a filter
//! for the output rate, or fall back to triangular high-pass when no filter
//! is within 5% of it. The noise is read from a buffer of twice the largest
//! call (at least 65536 frames), restarting from its beginning when a call
//! would run past its end, so results depend on the call sizes as FFmpeg's
//! do: each `convert` is one call, or `setCalls` names the sizes of FFmpeg's
//! calls when the chunks differ from them. A conversion whose pair gets no
//! dither scale (to a float, to the same width, ...) is not dithered:
//! `Dither.init` returns null and the plain conversion applies. FFmpeg's
//! `output_sample_bits`, which its command line sets to 24 for a 24-bit
//! encoder, scales the noise for s32 output and dithers s32 to s32. The
//! noise is generated as it is used: nothing allocates.

const std = @import("std");
const libm = @import("../core/libm.zig");
const audio = @import("../core/audio.zig");
const samples = @import("../core/samples.zig");
const audioconvert = @import("audioconvert.zig");
const diagnostics = @import("../core/diagnostics.zig");
const cconv = @import("../core/cconv.zig");

/// libswresample's dither methods (`SwrDitherType`), by its option names.
pub const Method = enum {
    rectangular,
    triangular,
    triangular_hp,
    lipshitz,
    f_weighted,
    modified_e_weighted,
    improved_e_weighted,
    shibata,
    low_shibata,
    high_shibata,

    fn shapes(method: Method) bool {
        return @backingInt(method) >= @backingInt(Method.lipshitz);
    }
};

pub const Options = struct {
    /// Null: no dither, libswresample's default.
    method: ?Method = null,
    /// `dither_scale`, a factor on the noise, from 0 to `max_scale`.
    scale: f32 = 1,
    /// `output_sample_bits`: how many bits of an s32 output sample the
    /// encoder keeps, 0 (all of them) or 2 through 32. FFmpeg's command line
    /// sets 24 for a 24-bit encoder.
    output_sample_bits: u8 = 0,
    /// Where libswresample's warning goes when a noise-shaping method has
    /// no filter at the rate and falls back to triangular high-pass (T17a).
    diagnostics: ?diagnostics.Sink = null,
};

/// `dither_scale`'s largest value, `INT_MAX`, before it is stored as a float.
pub const max_scale: f64 = std.math.maxInt(i32);

/// A `dither_method` value as FFmpeg's option takes it: a method's name, or
/// its `SwrDitherType` number (0 for none). FFmpeg's option evaluator also
/// takes expressions, which this does not.
pub fn methodFromOption(text: []const u8) error{InvalidValue}!?Method {
    if (std.meta.stringToEnum(Method, text)) |method| return method;
    return methodFromNumber(std.fmt.parseInt(u8, text, 10) catch return error.InvalidValue);
}

/// The method of FFmpeg's `SwrDitherType` number `number` (0 for none);
/// numbers of no method are `InvalidValue`.
pub fn methodFromNumber(number: i64) error{InvalidValue}!?Method {
    return switch (number) {
        0 => null,
        1...3 => @fromBackingInt(@intCast(number - 1)),
        65...71 => @fromBackingInt(@intCast(number - 65 + @backingInt(Method.lipshitz))),
        else => error.InvalidValue,
    };
}

/// A `dither_scale` value: a decimal number from 0 to `max_scale`, rounded
/// to a float as FFmpeg stores it.
pub fn scaleFromOption(text: []const u8) error{InvalidValue}!f32 {
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidValue;
    // NaN fails both comparisons.
    if (!(value >= 0 and value <= max_scale)) return error.InvalidValue;
    return @floatCast(value);
}

const Filter = struct {
    rate: i64,
    method: Method,
    gain_cb: i32,
    coefs: []const f64,
};

// noise_shaping_data.c, in its order: the first match wins.
const lip44 = [_]f64{ 2.033, -2.165, 1.959, -1.590, 0.6149 };
const fwe44 = [_]f64{ 2.412, -3.370, 3.937, -4.174, 3.353, -2.205, 1.281, -0.569, 0.0847 };
const mew44 = [_]f64{ 1.662, -1.263, 0.4827, -0.2913, 0.1268, -0.1124, 0.03252, -0.01265, -0.03524 };
const iew44 = [_]f64{ 2.847, -4.685, 6.214, -7.184, 6.639, -5.032, 3.263, -1.632, 0.4191 };
const shi48 = [_]f64{
    2.8720729351043701172,    -5.0413231849670410156,  6.2442994117736816406,
    -5.8483986854553222656,   3.7067542076110839844,   -1.0495119094848632812,
    -1.1830236911773681641,   2.1126792430877685547,   -1.9094531536102294922,
    0.99913084506988525391,   -0.17090806365013122559, -0.32615602016448974609,
    0.39127644896507263184,   -0.26876461505889892578, 0.097676105797290802002,
    -0.023473845794796943665,
};
const shi44 = [_]f64{
    2.6773197650909423828,   -4.8308925628662109375,   6.570110321044921875,
    -7.4572014808654785156,  6.7263274192810058594,    -4.8481650352478027344,
    2.0412089824676513672,   0.7006359100341796875,    -2.9537565708160400391,
    4.0800385475158691406,   -4.1845216751098632812,   3.3311812877655029297,
    -2.1179926395416259766,  0.879302978515625,        -0.031759146600961685181,
    -0.42382788658142089844, 0.47882103919982910156,   -0.35490813851356506348,
    0.17496839165687561035,  -0.060908168554306030273,
};
const shi38 = [_]f64{
    1.6335992813110351562,   -2.2615492343902587891,  2.4077029228210449219,
    -2.6341717243194580078,  2.1440362930297851562,   -1.8153258562088012695,
    1.0816224813461303711,   -0.70302653312683105469, 0.15991993248462677002,
    0.041549518704414367676, -0.29416576027870178223, 0.2518316805362701416,
    -0.27766478061676025391, 0.15785403549671173096,  -0.10165894031524658203,
    0.016833892092108726501,
};
const shi32 = [_]f64{
    0.82118552923202515, -1.0063692331314087,  0.62341964244842529,  -1.0447187423706055,
    0.64532512426376343, -0.87615132331848145, 0.52219754457473755,  -0.67434263229370117,
    0.44954317808151245, -0.52557498216629028, 0.34567299485206604,  -0.39618203043937683,
    0.26791760325431824, -0.28936097025871277, 0.1883765310049057,   -0.19097308814525604,
    0.10431359708309174, -0.10633844882249832, 0.046832218766212463, -0.039653312414884567,
};
const shi22 = [_]f64{
    0.056581053882837296,  -0.56956905126571655,   -0.40727734565734863,   -0.33870288729667664,
    -0.29810553789138794,  -0.19039161503314972,   -0.16510021686553955,   -0.13468159735202789,
    -0.096633769571781158, -0.081049129366874695,  -0.064953058958053589,  -0.054459091275930405,
    -0.043378707021474838, -0.03660014271736145,   -0.026256965473294258,  -0.018786206841468811,
    -0.013387725688517094, -0.0090983230620622635, -0.0026585909072309732, -0.00042083300650119781,
};
const shi16 = [_]f64{
    -0.37251132726669312,  -0.81423574686050415,  -0.55010956525802612,  -0.47405767440795898,
    -0.32624706625938416,  -0.3161766529083252,   -0.2286367267370224,   -0.22916607558727264,
    -0.19565616548061371,  -0.18160104751586914,  -0.15423151850700378,  -0.14104481041431427,
    -0.11844276636838913,  -0.097583092749118805, -0.076493598520755768, -0.068106919527053833,
    -0.041881654411554337, -0.036922425031661987, -0.019364040344953537, -0.014994367957115173,
};
const shi11 = [_]f64{
    -0.9264228343963623,   -0.98695987462997437,  -0.631156325340271,    -0.51966935396194458,
    -0.39738872647285461,  -0.35679301619529724,  -0.29720726609230042,  -0.26310476660728455,
    -0.21719355881214142,  -0.18561814725399017,  -0.15404847264289856,  -0.12687471508979797,
    -0.10339745879173279,  -0.083688631653785706, -0.05875682458281517,  -0.046893671154975891,
    -0.027950936928391457, -0.020740609616041183, -0.009366452693939209, -0.0060260160826146603,
};
const shi08 = [_]f64{
    -1.202863335609436,    -0.94103097915649414,  -0.67878556251525879,  -0.57650017738342285,
    -0.50004476308822632,  -0.44349345564842224,  -0.37833768129348755,  -0.34028723835945129,
    -0.29413089156150818,  -0.24994957447052002,  -0.21715600788593292,  -0.18792112171649933,
    -0.15268312394618988,  -0.12135542929172516,  -0.099610626697540283, -0.075273610651493073,
    -0.048787496984004974, -0.042586319148540497, -0.028991291299462318, -0.011869125068187714,
};
const shl48 = [_]f64{
    2.3925774097442626953,   -3.4350297451019287109,  3.1853709220886230469,
    -1.8117271661758422852,  -0.20124770700931549072, 1.4759907722473144531,
    -1.7210904359817504883,  0.97746700048446655273,  -0.13790138065814971924,
    -0.38185903429985046387, 0.27421241998672485352,  0.066584214568138122559,
    -0.35223302245140075684, 0.37672343850135803223,  -0.23964276909828186035,
    0.068674825131893157959,
};
const shl44 = [_]f64{
    2.0833916664123535156,   -3.0418450832366943359,   3.2047898769378662109,
    -2.7571926116943359375,  1.4978630542755126953,    -0.3427594602108001709,
    -0.71733748912811279297, 1.0737057924270629883,    -1.0225815773010253906,
    0.56649994850158691406,  -0.20968692004680633545,  -0.065378531813621520996,
    0.10322438180446624756,  -0.067442022264003753662, -0.00495197344571352005,
    0,
};
const shh44 = [_]f64{
    3.0259189605712890625,   -6.0268716812133789062,  9.195003509521484375,
    -11.824929237365722656,  12.767142295837402344,   -11.917946815490722656,
    9.1739168167114257812,   -5.3712320327758789062,  1.1393624544143676758,
    2.4484779834747314453,   -4.9719839096069335938,  6.0392003059387207031,
    -5.9359521865844726562,  4.903278350830078125,    -3.5527443885803222656,
    2.1909697055816650391,   -1.1672389507293701172,  0.4903914332389831543,
    -0.16519790887832641602, 0.023217858746647834778,
};

const filters = [_]Filter{
    .{ .rate = 44100, .method = .lipshitz, .gain_cb = 210, .coefs = &lip44 },
    .{ .rate = 46000, .method = .f_weighted, .gain_cb = 276, .coefs = &fwe44 },
    .{ .rate = 46000, .method = .modified_e_weighted, .gain_cb = 160, .coefs = &mew44 },
    .{ .rate = 46000, .method = .improved_e_weighted, .gain_cb = 321, .coefs = &iew44 },
    .{ .rate = 48000, .method = .shibata, .gain_cb = 301, .coefs = &shi48 },
    .{ .rate = 44100, .method = .shibata, .gain_cb = 333, .coefs = &shi44 },
    .{ .rate = 37800, .method = .shibata, .gain_cb = 240, .coefs = &shi38 },
    .{ .rate = 32000, .method = .shibata, .gain_cb = 240, .coefs = &shi32 },
    .{ .rate = 22050, .method = .shibata, .gain_cb = 240, .coefs = &shi22 },
    .{ .rate = 16000, .method = .shibata, .gain_cb = 240, .coefs = &shi16 },
    .{ .rate = 11025, .method = .shibata, .gain_cb = 240, .coefs = &shi11 },
    .{ .rate = 8000, .method = .shibata, .gain_cb = 240, .coefs = &shi08 },
    .{ .rate = 48000, .method = .low_shibata, .gain_cb = 250, .coefs = &shl48 },
    .{ .rate = 44100, .method = .low_shibata, .gain_cb = 250, .coefs = &shl44 },
    .{ .rate = 44100, .method = .high_shibata, .gain_cb = 383, .coefs = &shh44 },
};

/// `MAX_NS_TAPS`.
const max_taps = 20;
/// The most channels a dither handles: libswresample's `SWR_CH_MAX`, the
/// parsers' default limit.
pub const max_channels = 64;

comptime {
    for (filters) |f| {
        if (f.coefs.len > max_taps) @compileError("a filter longer than MAX_NS_TAPS");
        // dither_template.c's loop reads 4 taps at a time: a length of 2 or
        // 3 mod 4 needs a zero past the end, which a length of 3 mod 4 has
        // in ns_coeffs only if it is 15 and shl44's last is 0.
        if (f.coefs.len % 4 == 2) @compileError("a filter length FFmpeg's loop does not handle");
    }
}

/// libswresample's internal format (`swr_init`'s choice). `mixing`: a
/// rematrix mixes channels, rather than only copying or silencing them
/// (`swri_rematrix_build`, T23c); `resampling`: the rates differ (T24).
pub fn internalFormat(in: audio.SampleFormat, out: audio.SampleFormat, mixing: bool) audio.SampleFormat {
    return internalFormatResampling(in, out, mixing, false);
}

pub fn internalFormatResampling(in: audio.SampleFormat, out: audio.SampleFormat, mixing: bool, resampling: bool) audio.SampleFormat {
    const in_bytes = in.bytesPerSample();
    const out_bytes = out.bytesPerSample();
    if (in_bytes <= 2 and out_bytes <= 2 and !resampling) return .s16p;
    if (in_bytes + out_bytes <= 3) return .s16p;
    if (in_bytes <= 2 and !mixing and !resampling) return .s16p;
    if (in.packedForm() == .s32 and out.packedForm() == .s32 and !mixing and !resampling) return .s32p;
    if (in_bytes <= 4) return .fltp;
    return .dblp;
}

/// `swri_dither_init`'s scale from the internal to the output format before
/// `dither_scale` and `output_sample_bits` apply: one output step in
/// internal units; 0 means no dither.
fn ditherScale(internal: audio.SampleFormat, out: audio.SampleFormat, output_sample_bits: u8) f64 {
    const in = internal.packedForm();
    const to = out.packedForm();
    if (in == .flt or in == .dbl) return switch (to) {
        .s32 => 1.0 / 2147483648.0,
        .s16 => 1.0 / 32768.0,
        .u8 => 1.0 / 128.0,
        else => 0,
    };
    if (in == .s32 and to == .s32 and output_sample_bits % 32 != 0) return 1;
    if (in == .s32 and to == .s16) return 65536;
    if (in == .s32 and to == .u8) return 16777216;
    if (in == .s16 and to == .u8) return 256;
    return 0;
}

/// One channel's noise: `swri_get_dither`'s sequence, produced as read.
const Noise = struct {
    seed: u32,
    /// The next three values of `tmp`, the generator's raw output.
    window: [3]f64,
    method: Method,

    fn init(channel: u32, method: Method) Noise {
        const wide: u64 = channel;
        const start: u32 = @intCast((12345678913579 *% wide +% 3141592) % 2718281828);
        var noise: Noise = .{ .seed = start, .window = undefined, .method = method };
        for (&noise.window) |*v| v.* = noise.raw();
        return noise;
    }

    fn step(seed: u32) u32 {
        return seed *% 1664525 +% 1013904223;
    }

    /// The next `tmp` value.
    fn raw(n: *Noise) f64 {
        const max: f64 = std.math.maxInt(u32);
        n.seed = step(n.seed);
        const first: f64 = @floatFromInt(n.seed);
        if (n.method == .rectangular) return first / max - 0.5;
        n.seed = step(n.seed);
        const second: f64 = @floatFromInt(n.seed);
        return first / max - second / max;
    }

    /// The next noise value, before scaling.
    fn next(n: *Noise) f64 {
        const v = if (n.method == .triangular_hp)
            (-n.window[0] + 2 * n.window[1] - n.window[2]) / @sqrt(6.0)
        else
            n.window[0];
        n.window[0] = n.window[1];
        n.window[1] = n.window[2];
        n.window[2] = n.raw();
        return v;
    }
};

/// The dither state of one conversion: what `swr_init` sets up and
/// `swr_convert` carries from call to call.
pub const Dither = struct {
    /// After the fallback for a shaping method without a filter.
    method: Method,
    out_format: audio.SampleFormat,
    internal: audio.SampleFormat,
    channels: u32,
    /// `noise_scale`, a float in FFmpeg: 1 for the shaping methods.
    noise_scale: f32,
    ns_scale: f32,
    ns_scale_1: f32,
    taps: usize = 0,
    /// Zero past `taps`, as FFmpeg's zeroed context is.
    coeffs: [max_taps + 4]f32 = @splat(0),
    errors: [max_channels][2 * max_taps + 4]f32 = @splat(@splat(0)),
    ns_pos: usize = 0,
    /// The noise buffer FFmpeg would have: its frame count and read position.
    noise_count: u64 = 0,
    noise_pos: u64 = 0,
    noise: [max_channels]Noise,
    /// FFmpeg's call size from `setCalls`; 0: each `convert` is a call.
    call_frames: u32 = 0,
    /// Frames of the stream not yet converted, when `setCalls` knows them.
    remaining: ?u64 = null,
    /// Frames left in the current call.
    call_left: u64 = 0,

    /// The dither of a conversion from `in_format` to `out_format` (same
    /// rate and layout), or null when FFmpeg would not dither it.
    pub fn init(in_format: audio.Format, out_format: audio.SampleFormat, options: Options) ?Dither {
        const internal = internalFormat(in_format.sample_format, out_format, false);
        return initInternal(internal, in_format.channelCount(), in_format.sample_rate, out_format, options);
    }

    /// The dither of the `channels` channels libswresample holds in
    /// `internal` before converting them to `out_format`, at `sample_rate`,
    /// or null when FFmpeg would not dither them: after a rematrix (T23c),
    /// the output's channels in the internal format the mix chose.
    pub fn initInternal(internal: audio.SampleFormat, channels: u32, sample_rate: u32, out_format: audio.SampleFormat, options: Options) ?Dither {
        var method = options.method orelse return null;
        std.debug.assert(channels <= max_channels);
        const bits = options.output_sample_bits;
        std.debug.assert(bits == 0 or (bits >= 2 and bits <= 32));
        std.debug.assert(options.scale >= 0 and std.math.isFinite(options.scale));
        // swr_convert_internal converts straight into a planar output in the
        // internal format, undithered, unless it is s32 with bits to drop.
        if (internal == out_format and !(out_format == .s32p and bits % 32 != 0)) return null;
        const user_scale: f64 = options.scale;
        var scale = ditherScale(internal, out_format, bits) * user_scale;
        if (out_format.packedForm() == .s32 and bits != 0) {
            const one: u32 = 1;
            const factor: f64 = @floatFromInt(one << @intCast(32 - bits));
            scale *= factor;
        }
        if (scale == 0) return null;
        var dither: Dither = .{
            .method = method,
            .out_format = out_format,
            .internal = internal,
            .channels = channels,
            .noise_scale = @floatCast(scale),
            .ns_scale = @floatCast(scale),
            .ns_scale_1 = @floatCast(1 / scale),
            .noise = undefined,
        };
        if (method.shapes()) {
            const rate: i64 = sample_rate;
            const filter = for (filters) |f| {
                if (@abs(rate - f.rate) * 20 <= f.rate and f.method == method) break f;
            } else null;
            if (filter) |f| {
                dither.taps = f.coefs.len;
                for (f.coefs, 0..) |c, i| dither.coeffs[i] = @floatCast(c);
                // 1 << (8 * bytes) as x86 shifts it: the count taken mod 32.
                const bytes: u32 = out_format.bytesPerSample();
                const shift: u5 = @truncate(8 * bytes);
                const one: i32 = 1;
                const levels: f64 = @floatFromInt(one << shift);
                const gain: f64 = @floatFromInt(f.gain_cb);
                const factor = 1 - libm.exp(gain * std.math.ln10 * 0.005) * 2 / levels;
                const scale_1: f64 = dither.ns_scale_1;
                dither.ns_scale_1 = @floatCast(scale_1 * factor);
                // Shaping noise is float and unscaled.
                dither.noise_scale = 1;
            } else {
                diagnostics.report(options.diagnostics, .warning, "Requested noise shaping dither not available at this sampling rate, using triangular hp dither", .{});
                method = .triangular_hp;
                dither.method = method;
            }
        }
        // The shaping methods draw triangular noise.
        const noise_method: Method = if (method.shapes()) .triangular else method;
        for (0..channels) |c| dither.noise[c] = .init(@intCast(c), noise_method);
        return dither;
    }

    /// Bytes of scratch `convert` needs for `count` frames.
    pub fn scratchLen(d: Dither, count: u32) usize {
        const frames: usize = count;
        return frames * d.channels * d.internal.bytesPerSample();
    }

    /// Makes the noise that of FFmpeg converting the stream in calls of
    /// `frames` frames (the last one shorter), whatever chunks `convert`
    /// gets: the noise restarts only at a call boundary, so the calls, not
    /// the chunks, decide the result. `total` is the stream's frame count;
    /// unknown, the last call counts as full, which can change the result
    /// only when `frames` does not divide the noise buffer and that call
    /// would just fit at its end. A stream longer than `total` (a FLAC input
    /// whose STREAMINFO is wrong, converted to raw PCM) counts its calls
    /// past it as full. Call before the first `convert`.
    pub fn setCalls(d: *Dither, frames: u32, total: ?u64) void {
        std.debug.assert(frames > 0 and d.noise_count == 0);
        d.call_frames = frames;
        d.remaining = total;
    }

    /// Converts `count` frames: `in` (the input format) to `out` (the output
    /// format) through the internal format and the noise. Without
    /// `setCalls`, this is one `swr_convert` call.
    pub fn convert(d: *Dither, out: samples.Buffer, in: samples.View, count: u32, scratch: []u8) void {
        if (count == 0) return;
        const layout = samples.Layout.init(d.internal, d.channels, count, .{ .line = 1 }) catch unreachable;
        const internal = samples.Buffer.init(layout, scratch) catch unreachable; // scratchLen bytes
        audioconvert.convert(internal, in, 0, 0, count);
        d.applyInternal(internal, count);
        audioconvert.convert(out, internal.view(), 0, 0, count);
    }

    /// The noise step alone: dithers `count` frames already in the internal
    /// format (planar, `channels` of them, from the start of `internal`), as
    /// one `swr_convert` call does unless `setCalls` names the calls.
    pub fn applyInternal(d: *Dither, internal: samples.Buffer, count: u32) void {
        std.debug.assert(internal.layout.format == d.internal and internal.layout.channels == d.channels);
        var done: u32 = 0;
        while (done < count) {
            if (d.call_left == 0) d.beginCall(if (d.call_frames == 0) count else d.nextCall());
            const n: u32 = @intCast(@min(d.call_left, count - done));
            // Every channel shapes from the same filter position.
            var ns_end = d.ns_pos;
            for (0..d.channels) |c| {
                const plane = internal.plane(@intCast(c));
                const size = d.internal.bytesPerSample();
                const part = plane[done * size ..][0 .. n * size];
                switch (d.internal) {
                    inline .s16p, .s32p, .fltp, .dblp => |format| {
                        if (d.method.shapes()) ns_end = d.shape(format, part, c, n) else d.addNoise(format, part, c, n);
                    },
                    else => unreachable, // internalFormat returns these
                }
            }
            d.ns_pos = ns_end;
            d.call_left -= n;
            d.noise_pos += n;
            if (d.remaining) |*r| r.* -|= n;
            done += n;
        }
    }

    /// The size of the next of FFmpeg's calls.
    fn nextCall(d: *Dither) u64 {
        const r = d.remaining orelse return d.call_frames;
        // More frames than `setCalls` was told of: full calls.
        if (r == 0) return d.call_frames;
        return @min(d.call_frames, r);
    }

    /// The start of a `swr_convert` call of `count` frames: the noise buffer
    /// is twice the largest call, at least 65536 frames, and a call that
    /// would run past its end starts over from the beginning.
    fn beginCall(d: *Dither, count: u64) void {
        const wanted: u64 = @max(count, 1 << 16);
        if (d.noise_count < wanted) d.noise_count = 2 * wanted;
        if (d.noise_pos + count > d.noise_count) {
            d.noise_pos = 0;
            for (0..d.channels) |c| d.noise[c] = .init(@intCast(c), d.noise[c].method);
        }
        d.call_left = count;
    }

    fn Sample(comptime format: audio.SampleFormat) type {
        return switch (format) {
            .s16p, .s32p, .fltp, .dblp => format.Element(),
            else => @compileError("not an internal format"),
        };
    }

    fn load(comptime T: type, bytes: []const u8, i: usize) T {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        return @bitCast(std.mem.readInt(Bits, bytes[i * @sizeOf(T) ..][0..@sizeOf(T)], native_endian));
    }

    fn store(comptime T: type, bytes: []u8, i: usize, value: T) void {
        const Bits = @Int(.unsigned, @bitSizeOf(T));
        std.mem.writeInt(Bits, bytes[i * @sizeOf(T) ..][0..@sizeOf(T)], @bitCast(value), native_endian);
    }

    /// The plain methods: the noise, scaled and stored as the internal
    /// format stores it, added as `sum2` adds (integers wrap).
    fn addNoise(d: *Dither, comptime format: audio.SampleFormat, plane: []u8, channel: usize, count: u32) void {
        const T = Sample(format);
        const scale: f64 = d.noise_scale;
        for (0..count) |i| {
            const v = d.noise[channel].next() * scale;
            const value = load(T, plane, i);
            const sum: T = switch (format) {
                .s16p, .s32p => sum: {
                    // swri_get_dither stores the double noise into int16_t or
                    // int32_t: the reference build's cvttsd2si into 32 bits
                    // (toward zero; NaN or out of range gives INT_MIN), then
                    // the low 16 bits for s16p. A dither_scale of 1000 into
                    // u8 makes the s16p noise wrap.
                    const noise: T = @truncate(cconv.cvttsd2si32(v));
                    const wide: i64 = value;
                    const noise_wide: i64 = noise;
                    // (32768 * a + 32768 * b + 16384) >> 15, stored truncated.
                    break :sum @truncate((32768 * wide + 32768 * noise_wide + 16384) >> 15);
                },
                .fltp => fltp: {
                    const noise: f32 = @floatCast(v);
                    break :fltp value + noise;
                },
                .dblp => value + v,
                else => unreachable,
            };
            store(T, plane, i, sum);
        }
    }

    /// `swri_noise_shaping_*` for one channel, in FFmpeg's float and double
    /// arithmetic, from the filter position `ns_pos`; returns the position
    /// after `count` frames.
    fn shape(d: *Dither, comptime format: audio.SampleFormat, plane: []u8, channel: usize, count: u32) usize {
        const T = Sample(format);
        const taps = d.taps;
        const S = d.ns_scale;
        const S_1 = d.ns_scale_1;
        const errors = &d.errors[channel];
        var pos = d.ns_pos;
        for (0..count) |i| {
            const src = load(T, plane, i);
            // src * S_1 in float for the 16- and 32-bit and float formats,
            // in double for double.
            const S_1_wide: f64 = S_1;
            var x: f64 = switch (format) {
                .dblp => src * S_1_wide,
                .fltp => src * S_1,
                else => int: {
                    const as_float: f32 = @floatFromInt(src);
                    break :int as_float * S_1;
                },
            };
            var j: usize = 0;
            while (j + 2 < taps) : (j += 4) {
                const sum: f32 = d.coeffs[j] * errors[pos + j] + d.coeffs[j + 1] * errors[pos + j + 1] +
                    d.coeffs[j + 2] * errors[pos + j + 2] + d.coeffs[j + 3] * errors[pos + j + 3];
                x -= sum;
            }
            if (j < taps) {
                const last: f32 = d.coeffs[j] * errors[pos + j];
                x -= last;
            }
            pos = if (pos != 0) pos - 1 else taps - 1;
            const noise: f32 = @floatCast(d.noise[channel].next());
            var y = cconv.rint(x + noise);
            const err: f32 = @floatCast(y - x);
            errors[pos + taps] = err;
            errors[pos] = err;
            y *= S;
            const value: T = switch (format) {
                .s16p, .s32p => int: {
                    const min: f64 = @floatFromInt(std.math.minInt(T));
                    const max: f64 = @floatFromInt(std.math.maxInt(T));
                    // CLIP: FFMAX(FFMIN(v, max), min), whose comparisons send
                    // NaN to the minimum; then the double stored as T.
                    const below = if (y > max) max else y;
                    const clipped = if (below > min) below else min;
                    break :int @truncate(cconv.cvttsd2si32(clipped));
                },
                .fltp => @floatCast(y),
                .dblp => y,
                else => unreachable,
            };
            store(T, plane, i, value);
        }
        return pos;
    }
};

const native_endian = @import("builtin").cpu.arch.endian();

test "the internal format and scale follow swr_init and swri_dither_init" {
    try std.testing.expectEqual(audio.SampleFormat.fltp, internalFormat(.flt, .s16, false));
    try std.testing.expectEqual(audio.SampleFormat.fltp, internalFormat(.s32, .s16, false));
    try std.testing.expectEqual(audio.SampleFormat.s16p, internalFormat(.s16, .u8, false));
    try std.testing.expectEqual(audio.SampleFormat.dblp, internalFormat(.dbl, .s16, false));
    try std.testing.expectEqual(audio.SampleFormat.s32p, internalFormat(.s32p, .s32, false));
    try std.testing.expectEqual(1.0 / 32768.0, ditherScale(.fltp, .s16, 0));
    try std.testing.expectEqual(256, ditherScale(.s16p, .u8, 0));
    try std.testing.expectEqual(0, ditherScale(.fltp, .dbl, 0));
    try std.testing.expectEqual(0, ditherScale(.s32p, .s32, 0));
    try std.testing.expectEqual(1, ditherScale(.s32p, .s32, 24));
    const stereo = try audio.Format.init(44100, 2, .s16);
    // s16 to s32 has no scale: no dither.
    try std.testing.expectEqual(null, Dither.init(stereo, .s32, .{ .method = .triangular }));
    try std.testing.expectEqual(null, Dither.init(stereo, .u8, .{}));
    // A shaping method with no filter near the rate falls back.
    const odd = try audio.Format.init(96000, 2, .flt);
    try std.testing.expectEqual(Method.triangular_hp, Dither.init(odd, .s16, .{ .method = .shibata }).?.method);
    const cd = try audio.Format.init(44100, 2, .flt);
    try std.testing.expectEqual(20, Dither.init(cd, .s16, .{ .method = .shibata }).?.taps);
}

// zig/testing/vectors/dither.txt comes from the pinned FFmpeg's
// libswresample through zig/testing/reference/dither_vectors.c, which
// documents the input regenerated below and the call sizes. Every line is
// checked, and the count makes a truncated or missing file fail.
const vectors = @embedFile("../testing/vectors/dither.txt");
const vector_count = 137;
const vector_frames = 276005;
const mixed_calls = [_]u32{ 1000, 70000, 5, 65000, 140000 };
/// The chunks a fixed-call vector is converted in, unlike its calls.
const chunk_frames = 1000;

/// dither_vectors.c's interleaved stereo input of `frames` frames, packed
/// and native-endian, as `packed_form` stores it.
fn vectorInput(packed_form: audio.SampleFormat, out: []u8, frames: usize) error{MalformedVector}!void {
    var x: u64 = 1;
    for (0..frames * 2) |i| {
        // A 64-bit LCG: the wrapping arithmetic is the generator's definition.
        x = x *% 6364136223846793005 +% 1442695040888963407;
        const high_bits: u32 = @truncate(x >> 32);
        const high: i32 = @bitCast(high_bits);
        const all: i64 = @bitCast(x);
        switch (packed_form) {
            .flt => {
                const f: f32 = @floatFromInt(high);
                Dither.store(f32, out, i, f * (1.0 / 2147483648.0));
            },
            .dbl => {
                const d: f64 = @floatFromInt(all);
                Dither.store(f64, out, i, d * (1.0 / 9223372036854775808.0));
            },
            .s16 => Dither.store(i16, out, i, @truncate(all >> 48)),
            .s32 => Dither.store(i32, out, i, high),
            .s64 => Dither.store(i64, out, i, all),
            else => return error.MalformedVector,
        }
    }
}

fn vectorField(fields: *std.mem.TokenIterator(u8, .scalar)) error{MalformedVector}![]const u8 {
    return fields.next() orelse error.MalformedVector;
}

/// One vector's conversion: the input's frames from `done` on, `n` of them,
/// laid out as `in_sample` lays them out in `chunk_in`, converted into
/// `chunk_out` and hashed as little-endian samples.
const VectorRun = struct {
    in_sample: audio.SampleFormat,
    out_sample: audio.SampleFormat,
    packed_in: []const u8,
    chunk_in: []u8,
    chunk_out: []u8,
    scratch: []u8,
    dither: ?Dither,
    sha: std.crypto.hash.sha2.Sha256 = .init(.{}),

    fn step(r: *VectorRun, done: usize, n: u32) !void {
        const in_width = r.in_sample.bytesPerSample();
        const in_layout = try samples.Layout.init(r.in_sample, 2, n, .{ .line = 1 });
        const input = try samples.Buffer.init(in_layout, r.chunk_in);
        const from = r.packed_in[done * 2 * in_width ..][0 .. n * 2 * in_width];
        if (r.in_sample.isPlanar()) {
            for (0..2) |c| for (0..n) |i| {
                @memcpy(input.plane(@intCast(c))[i * in_width ..][0..in_width], from[(i * 2 + c) * in_width ..][0..in_width]);
            };
        } else {
            @memcpy(input.bytes, from);
        }
        const out_layout = try samples.Layout.init(r.out_sample, 2, n, .{ .line = 1 });
        const output = try samples.Buffer.init(out_layout, r.chunk_out);
        if (r.dither) |*d| {
            d.convert(output, input.view(), n, r.scratch[0..d.scratchLen(n)]);
        } else {
            audioconvert.convert(output, input.view(), 0, 0, n);
        }
        if (native_endian == .big) {
            const out_width = r.out_sample.bytesPerSample();
            var i: usize = 0;
            while (i < output.bytes.len) : (i += out_width) std.mem.reverse(u8, output.bytes[i..][0..out_width]);
        }
        r.sha.update(output.bytes);
    }
};

test "every method dithers exactly as the pinned libswresample" {
    const gpa = std.testing.allocator;
    var largest: u32 = 0;
    for (mixed_calls) |n| largest = @max(largest, n);
    const packed_in = try gpa.alloc(u8, vector_frames * 2 * 8);
    defer gpa.free(packed_in);
    const chunk_in = try gpa.alloc(u8, largest * 2 * 8);
    defer gpa.free(chunk_in);
    const chunk_out = try gpa.alloc(u8, largest * 2 * 8);
    defer gpa.free(chunk_out);
    const scratch = try gpa.alloc(u8, largest * 2 * 8);
    defer gpa.free(scratch);

    var checked: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const in_sample = std.meta.stringToEnum(audio.SampleFormat, try vectorField(&fields)) orelse return error.MalformedVector;
        const out_sample = std.meta.stringToEnum(audio.SampleFormat, try vectorField(&fields)) orelse return error.MalformedVector;
        const rate = try std.fmt.parseInt(u32, try vectorField(&fields), 10);
        const options: Options = .{
            .method = std.meta.stringToEnum(Method, try vectorField(&fields)) orelse return error.MalformedVector,
            .scale = try std.fmt.parseFloat(f32, try vectorField(&fields)),
            .output_sample_bits = try std.fmt.parseInt(u8, try vectorField(&fields), 10),
        };
        const calls = try vectorField(&fields);
        const want = try vectorField(&fields);
        try vectorInput(in_sample.packedForm(), packed_in, vector_frames);
        const in_format = try audio.Format.init(rate, 2, in_sample);
        const dither = Dither.init(in_format, out_sample, options);

        // Mixed calls are converted call by call. Fixed calls are emulated
        // over other chunks (packed output, so the chunks hash alike), with
        // the frame count and, where the calls divide the noise buffer,
        // without it.
        const fixed: ?u32 = if (std.mem.eql(u8, calls, "mixed")) null else try std.fmt.parseInt(u32, calls, 10);
        var totals: [2]?u64 = .{ vector_frames, null };
        const runs: usize = if (fixed) |f| (if ((2 * @max(f, 1 << 16)) % f == 0) 2 else 1) else 1;
        for (totals[0..runs]) |total| {
            var r: VectorRun = .{
                .in_sample = in_sample,
                .out_sample = out_sample,
                .packed_in = packed_in,
                .chunk_in = chunk_in,
                .chunk_out = chunk_out,
                .scratch = scratch,
                .dither = dither,
            };
            var done: usize = 0;
            if (fixed) |f| {
                if (out_sample.isPlanar() or dither == null) return error.MalformedVector;
                r.dither.?.setCalls(f, total); // not null: checked above
                while (done < vector_frames) {
                    const n: u32 = @min(chunk_frames, vector_frames - done);
                    try r.step(done, n);
                    done += n;
                }
            } else {
                for (mixed_calls) |n| {
                    try r.step(done, n);
                    done += n;
                }
            }
            const hex = std.fmt.bytesToHex(r.sha.finalResult(), .lower);
            std.testing.expectEqualStrings(want, &hex) catch |err| {
                std.debug.print("vector: {s}\n", .{line});
                return err;
            };
        }
        checked += 1;
    }
    try std.testing.expectEqual(vector_count, checked);
}

test "option values parse as FFmpeg's dither options" {
    try std.testing.expectEqual(Method.shibata, try methodFromOption("shibata"));
    try std.testing.expectEqual(Method.triangular_hp, try methodFromOption("3"));
    try std.testing.expectEqual(Method.lipshitz, try methodFromOption("65"));
    try std.testing.expectEqual(Method.high_shibata, try methodFromOption("71"));
    try std.testing.expectEqual(null, try methodFromOption("0"));
    for ([_][]const u8{ "4", "64", "72", "none", "", "-1", "Shibata" }) |bad| {
        try std.testing.expectError(error.InvalidValue, methodFromOption(bad));
    }
    try std.testing.expectEqual(0.5, try scaleFromOption("0.5"));
    try std.testing.expectEqual(0, try scaleFromOption("0"));
    for ([_][]const u8{ "-1", "nan", "inf", "3e9", "x" }) |bad| {
        try std.testing.expectError(error.InvalidValue, scaleFromOption(bad));
    }
}
test "the noise generator follows swri_get_dither's sequence" {
    var n: Noise = .init(0, .rectangular);
    // The first seed after 3141592, over UINT_MAX, minus a half.
    const first: f64 = @floatFromInt(Noise.step(3141592));
    const max: f64 = std.math.maxInt(u32);
    const expected = first / max - 0.5;
    try std.testing.expectEqual(expected, n.next());
}

test "the fallback from a shaping method is reported" {
    var recorder: diagnostics.Recorder = .{};
    // Lipshitz has a filter at 44.1 kHz only.
    const in_format = try audio.Format.init(8000, 1, .flt);
    const d = Dither.init(in_format, .s16, .{ .method = .lipshitz, .diagnostics = recorder.sink(.warning) }).?;
    try std.testing.expectEqual(Method.triangular_hp, d.method);
    try std.testing.expectEqual(1, recorder.count);
    try std.testing.expectEqualStrings("Requested noise shaping dither not available at this sampling rate, using triangular hp dither", recorder.lastMessage());
}
