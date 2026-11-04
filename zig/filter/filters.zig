// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavfilter/af_anull.c, af_aformat.c, af_volume.c, af_aresample.c and
// audio.c, libavutil/opt.c (opt_set_array, set_string_fmt,
// set_string_channel_layout), eval.c (white space, numbers),
// float_dsp.c (vector_fmul_scalar_c, vector_dmul_scalar_c) and
// libswresample/options.c and swresample.c (swr_next_pts, the path
// without resampling) at the pinned reference revision describe the
// behavior, restated here.
//! The audio filters of the T25a graph: anull, aformat, volume with a
//! constant gain, and aresample. Each is created by name with options set
//! from text as `avfilter_init_dict` sets them (`create`), declares the
//! format lists it accepts to the negotiation (graph.zig), and runs on
//! frames once its links are configured.
//!
//! An option value FFmpeg would read as an expression (`1/2`, `PI`) is
//! `Expression` until its evaluator is ported (T25b); libswresample
//! options the port does not implement are `UnsupportedOption`.

const std = @import("std");
const audio = @import("../core/audio.zig");
const channel_layout = @import("../core/channel_layout.zig");
const number = @import("../core/number.zig");
const options = @import("../core/options.zig");
const samples = @import("../core/samples.zig");
const time = @import("../core/time.zig");
const diagnostics = @import("../core/diagnostics.zig");
const audioconvert = @import("../resample/audioconvert.zig");
const dither = @import("../resample/dither.zig");
const rematrix = @import("../resample/rematrix.zig");
const resample = @import("../resample/resample.zig");
const swr = @import("../resample/swr.zig");
const Layout = channel_layout.Layout;
const SampleFormat = audio.SampleFormat;

/// An option as text, as `avfilter_init_dict` takes it.
pub const Option = struct { name: []const u8, value: []const u8 };

pub const CreateError = options.SetError || error{
    /// No filter of that name.
    UnknownFilter,
    /// A libswresample option the port does not implement.
    UnsupportedOption,
    /// A value FFmpeg reads as an expression (TODO.md T25b).
    Expression,
    OutOfMemory,
};

pub const Kind = enum { anull, aformat, volume, aresample };

pub const Descriptor = struct {
    name: []const u8,
    kind: Kind,
    description: []const u8,
};

/// The filters, by FFmpeg's names and descriptions.
pub const descriptors = [_]Descriptor{
    .{ .name = "anull", .kind = .anull, .description = "Pass the source unchanged to the output." },
    .{ .name = "aformat", .kind = .aformat, .description = "Convert the input audio to one of the specified formats." },
    .{ .name = "volume", .kind = .volume, .description = "Change input volume." },
    .{ .name = "aresample", .kind = .aresample, .description = "Resample audio data." },
};

comptime {
    for (descriptors, 0..) |d, i| {
        if (!std.mem.eql(u8, d.name, @tagName(d.kind))) @compileError("descriptor name differs from its kind: " ++ d.name);
        for (descriptors[i + 1 ..]) |other| {
            if (std.mem.eql(u8, d.name, other.name)) @compileError("duplicate filter name: " ++ d.name);
        }
    }
}

pub fn find(name: []const u8) ?Descriptor {
    for (descriptors) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

/// A created filter: its options, before the graph is configured.
pub const Filter = union(Kind) {
    anull,
    aformat: AFormat,
    volume: Volume,
    aresample: AResample,

    /// The filter `name` with `opts` set in order; nothing is kept when it
    /// fails.
    pub fn create(gpa: std.mem.Allocator, name: []const u8, opts: []const Option) CreateError!Filter {
        const d = find(name) orelse return error.UnknownFilter;
        var f: Filter = switch (d.kind) {
            .anull => .anull,
            .aformat => .{ .aformat = .{} },
            .volume => .{ .volume = .{} },
            .aresample => .{ .aresample = .{} },
        };
        errdefer f.deinit(gpa);
        for (opts) |o| try f.set(gpa, o.name, o.value);
        return f;
    }

    pub fn set(f: *Filter, gpa: std.mem.Allocator, name: []const u8, value: []const u8) CreateError!void {
        switch (f.*) {
            .anull => return error.UnknownOption,
            .aformat => |*a| try a.set(gpa, name, value),
            .volume => |*v| try v.set(name, value),
            .aresample => |*a| try a.set(name, value),
        }
    }

    pub fn deinit(f: *Filter, gpa: std.mem.Allocator) void {
        switch (f.*) {
            .aformat => |*a| a.deinit(gpa),
            else => {},
        }
        f.* = undefined;
    }
};

// Option values -------------------------------------------------------------

/// `opt_set_array`: `text` split at `separator`, a backslash taking the
/// next character as it is; an empty text is no elements. Calls
/// `element(p, text)` for each, in a buffer valid during the call.
fn splitArray(text: []const u8, separator: u8, p: *AFormat.Parse, comptime element: fn (*AFormat.Parse, []const u8) CreateError!void) CreateError!void {
    var buffer: [256]u8 = undefined;
    var pos: usize = 0;
    while (pos < text.len) {
        var len: usize = 0;
        while (pos < text.len) : (pos += 1) {
            var c = text[pos];
            if (c == '\\' and pos + 1 < text.len) {
                pos += 1;
                c = text[pos];
            } else if (c == separator) {
                pos += 1;
                break;
            }
            if (len == buffer.len) return error.InvalidValue;
            buffer[len] = c;
            len += 1;
        }
        try element(p, buffer[0..len]);
    }
}

/// `set_string_fmt` for sample formats, within -1 and the last format:
/// `none` (null), a format's name, or `strtol`'s number of the whole text
/// (an empty text is 0, u8, as there).
pub fn sampleFormatValue(text: []const u8) options.SetError!?SampleFormat {
    if (std.mem.eql(u8, text, "none")) return null;
    if (SampleFormat.fromName(text)) |f| return f;
    const n = channel_layout.strtol(text, 0);
    if (n.end != text.len) return error.InvalidValue;
    // C keeps the long's low 32 bits in the int.
    const id: i32 = @truncate(n.value);
    return SampleFormat.fromFfmpegId(id) orelse error.InvalidValue;
}

/// `set_string_channel_layout`: `av_channel_layout_from_string`.
fn layoutValue(text: []const u8) options.SetError!Layout {
    return Layout.parse(text) catch error.InvalidValue;
}

/// A positive int, as an int array element of `[1, INT_MAX]` is set.
const PositiveInt = struct {
    value: i32 = 1,

    pub const option_specs = [_]options.Spec{
        .{ .name = "value", .field = "value", .kind = .int, .help = "a positive integer", .min = 1, .max = std.math.maxInt(i32) },
    };

    comptime {
        options.check(PositiveInt);
    }

    fn parse(text: []const u8) options.SetError!i32 {
        // An array option's `default` reads its array definition's address
        // as a number, which no rate is.
        if (std.mem.eql(u8, std.mem.trim(u8, text, &std.ascii.whitespace), "default")) return error.OutOfRange;
        var p: PositiveInt = .{};
        try options.set(PositiveInt, &p, "value", text);
        return p.value;
    }
};

/// A constant as `av_expr_parse` reads one: the text without its white
/// space, all of it `av_strtod`'s number. Anything else is an expression.
fn constantValue(text: []const u8) CreateError!f64 {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        if (len == buffer.len) return error.Expression;
        buffer[len] = c;
        len += 1;
    }
    const stripped = buffer[0..len];
    if (stripped.len == 0) return error.InvalidValue;
    const n = number.avStrtod(stripped);
    if (n.end != stripped.len) return error.Expression;
    return n.value;
}

// aformat -------------------------------------------------------------------

pub const AFormat = struct {
    /// FFmpeg's sample format numbers; -1 (`none`) ends the list there.
    formats: std.ArrayList(i32) = .empty,
    rates: std.ArrayList(i32) = .empty,
    layouts: std.ArrayList(Layout) = .empty,

    fn deinit(a: *AFormat, gpa: std.mem.Allocator) void {
        a.formats.deinit(gpa);
        a.rates.deinit(gpa);
        a.layouts.deinit(gpa);
    }

    const Parse = struct {
        gpa: std.mem.Allocator,
        formats: std.ArrayList(i32) = .empty,
        rates: std.ArrayList(i32) = .empty,
        layouts: std.ArrayList(Layout) = .empty,

        fn format(p: *Parse, text: []const u8) CreateError!void {
            const f = try sampleFormatValue(text);
            try p.formats.append(p.gpa, if (f) |v| v.ffmpegId() else -1);
        }

        fn rate(p: *Parse, text: []const u8) CreateError!void {
            try p.rates.append(p.gpa, try PositiveInt.parse(text));
        }

        fn layout(p: *Parse, text: []const u8) CreateError!void {
            try p.layouts.append(p.gpa, try layoutValue(text));
        }
    };

    /// Sets a '|'-separated list, replacing the option's previous one.
    fn set(a: *AFormat, gpa: std.mem.Allocator, name: []const u8, text: []const u8) CreateError!void {
        var p: Parse = .{ .gpa = gpa };
        errdefer {
            p.formats.deinit(gpa);
            p.rates.deinit(gpa);
            p.layouts.deinit(gpa);
        }
        if (std.mem.eql(u8, name, "sample_fmts") or std.mem.eql(u8, name, "f")) {
            try splitArray(text, '|', &p, Parse.format);
            a.formats.deinit(gpa);
            a.formats = p.formats;
        } else if (std.mem.eql(u8, name, "sample_rates") or std.mem.eql(u8, name, "r")) {
            try splitArray(text, '|', &p, Parse.rate);
            a.rates.deinit(gpa);
            a.rates = p.rates;
        } else if (std.mem.eql(u8, name, "channel_layouts") or std.mem.eql(u8, name, "cl")) {
            try splitArray(text, '|', &p, Parse.layout);
            a.layouts.deinit(gpa);
            a.layouts = p.layouts;
        } else return error.UnknownOption;
    }

    /// The formats as `ff_make_sample_format_list` reads them: up to the
    /// first `none`.
    pub fn formatList(a: *const AFormat) []const i32 {
        const end = std.mem.findScalar(i32, a.formats.items, -1) orelse a.formats.items.len;
        return a.formats.items[0..end];
    }
};

// volume --------------------------------------------------------------------

pub const Precision = enum(u8) { fixed, float, double };
pub const EvalMode = enum(u8) { once, frame };
pub const ReplayGain = enum(u8) { drop, ignore, track, album };

pub const Volume = struct {
    /// The constant gain; NaN is refused when the graph is configured, as
    /// FFmpeg evaluates it there.
    volume: f64 = 1.0,
    rest: Rest = .{},

    /// The options other than `volume`, a string option FFmpeg evaluates.
    pub const Rest = struct {
        precision: Precision = .float,
        eval: EvalMode = .once,
        /// Frames carry no replay gain here, so the replay-gain options
        /// change nothing.
        replaygain: ReplayGain = .drop,
        replaygain_preamp: f64 = 0,
        replaygain_noclip: bool = true,

        pub const option_specs = [_]options.Spec{
            .{ .name = "precision", .field = "precision", .kind = .int, .help = "select mathematical precision", .min = 0, .max = 2, .constants = &.{
                .{ .name = "fixed", .value = 0 },
                .{ .name = "float", .value = 1 },
                .{ .name = "double", .value = 2 },
            } },
            .{ .name = "eval", .field = "eval", .kind = .int, .help = "specify when to evaluate expressions", .min = 0, .max = 1, .constants = &.{
                .{ .name = "once", .value = 0 },
                .{ .name = "frame", .value = 1 },
            } },
            .{ .name = "replaygain", .field = "replaygain", .kind = .int, .help = "Apply replaygain side data when present", .min = 0, .max = 3, .constants = &.{
                .{ .name = "drop", .value = 0 },
                .{ .name = "ignore", .value = 1 },
                .{ .name = "track", .value = 2 },
                .{ .name = "album", .value = 3 },
            } },
            .{ .name = "replaygain_preamp", .field = "replaygain_preamp", .kind = .double, .help = "Apply replaygain pre-amplification", .min = -15, .max = 15 },
            .{ .name = "replaygain_noclip", .field = "replaygain_noclip", .kind = .bool, .help = "Apply replaygain clipping prevention", .min = 0, .max = 1 },
        };

        comptime {
            options.check(Rest);
        }
    };

    fn set(v: *Volume, name: []const u8, text: []const u8) CreateError!void {
        if (std.mem.eql(u8, name, "volume")) {
            v.volume = try constantValue(text);
            return;
        }
        try options.set(Rest, &v.rest, name, text);
    }
};

/// The volume filter on configured links (`config_output`, `set_volume`).
pub const VolumeRun = struct {
    precision: Precision,
    format: SampleFormat,
    volume: f64,
    /// The fixed-point gain, 256 for unity.
    volume_i: i32 = 0,

    pub const Error = error{
        /// "Invalid value NaN for volume", evaluated once.
        InvalidVolume,
        /// A fixed-point gain past an int: FFmpeg's conversion is undefined.
        VolumeOutOfRange,
    };

    pub fn init(v: Volume, format: SampleFormat, sink: ?diagnostics.Sink) Error!VolumeRun {
        var r: VolumeRun = .{ .precision = v.rest.precision, .format = format, .volume = v.volume };
        if (std.math.isNan(r.volume)) {
            if (v.rest.eval == .once) {
                diagnostics.report(sink, .err, "Invalid value NaN for volume", .{});
                return error.InvalidVolume;
            }
            diagnostics.report(sink, .warning, "Invalid value NaN for volume, setting to 0", .{});
            r.volume = 0;
        }
        if (r.precision == .fixed) {
            const scaled = r.volume * 256 + 0.5;
            if (!(scaled > -2147483649.0 and scaled < 2147483648.0)) return error.VolumeOutOfRange;
            r.volume_i = @intFromFloat(@trunc(scaled));
            const vi: f64 = @floatFromInt(r.volume_i);
            r.volume = vi / 256.0;
        }
        return r;
    }

    /// Scales `data`, the frame's samples in `format`, in place.
    pub fn apply(r: *const VolumeRun, data: []align(8) u8) void {
        if (r.volume == 1.0 or r.volume_i == 256) return;
        if (r.precision == .fixed and r.volume_i <= 0) {
            // A new frame, left silent.
            @memset(data, r.format.silenceByte());
            return;
        }
        const v: i64 = r.volume_i;
        switch (r.format.packedForm()) {
            .u8 => for (data) |*s| {
                const x: i64 = s.*;
                s.* = @intCast(std.math.clamp((((x - 128) * v + 128) >> 8) + 128, 0, 255));
            },
            .s16 => for (std.mem.bytesAsSlice(i16, data)) |*s| {
                s.* = @intCast(std.math.clamp((@as(i64, s.*) * v + 128) >> 8, std.math.minInt(i16), std.math.maxInt(i16)));
            },
            .s32 => for (std.mem.bytesAsSlice(i32, data)) |*s| {
                s.* = @intCast(std.math.clamp((@as(i64, s.*) * v + 128) >> 8, std.math.minInt(i32), std.math.maxInt(i32)));
            },
            .flt => {
                // vector_fmul_scalar takes the gain as a float.
                const mul: f32 = @floatCast(r.volume);
                for (std.mem.bytesAsSlice(f32, data)) |*s| s.* *= mul;
            },
            .dbl => for (std.mem.bytesAsSlice(f64, data)) |*s| {
                s.* *= r.volume;
            },
            // The negotiation gives volume no other format.
            else => unreachable,
        }
    }

    /// The formats a precision accepts (`query_formats`), in FFmpeg's order.
    pub fn formats(precision: Precision) []const SampleFormat {
        return switch (precision) {
            .fixed => &.{ .u8, .u8p, .s16, .s16p, .s32, .s32p },
            .float => &.{ .flt, .fltp },
            .double => &.{ .dbl, .dblp },
        };
    }
};

// aresample -----------------------------------------------------------------

pub const AResample = struct {
    /// aresample's own `sample_rate`; 0 keeps libswresample's `osr`.
    sample_rate: i32 = 0,
    swr_scalars: SwrScalars = .{},
    /// `osf`; null when unset.
    out_sample_format: ?SampleFormat = null,
    /// `ochl`; null when unset.
    out_layout: ?Layout = null,
    resampler: resample.Options = .{},

    const Own = struct {
        sample_rate: i32 = 0,

        pub const option_specs = [_]options.Spec{
            .{ .name = "sample_rate", .field = "sample_rate", .kind = .int, .help = "", .min = 0, .max = std.math.maxInt(i32) },
        };

        comptime {
            options.check(Own);
        }
    };

    /// libswresample's scalar options the port implements, besides the
    /// resampler's.
    pub const SwrScalars = struct {
        out_sample_rate: i32 = 0,
        /// `SwrDitherType`'s number; numbers of no method fail when the
        /// graph is configured, as `swr_init` fails.
        dither_method: i32 = 0,
        dither_scale: f32 = 1,

        pub const option_specs = [_]options.Spec{
            .{ .name = "osr", .field = "out_sample_rate", .kind = .int, .help = "set output sample rate", .min = 0, .max = std.math.maxInt(i32) },
            .{ .name = "out_sample_rate", .field = "out_sample_rate", .kind = .int, .help = "set output sample rate", .min = 0, .max = std.math.maxInt(i32) },
            .{ .name = "dither_method", .field = "dither_method", .kind = .int, .help = "set dither method", .min = 0, .max = 71, .constants = &.{
                .{ .name = "rectangular", .value = 1 },
                .{ .name = "triangular", .value = 2 },
                .{ .name = "triangular_hp", .value = 3 },
                .{ .name = "lipshitz", .value = 65 },
                .{ .name = "shibata", .value = 69 },
                .{ .name = "low_shibata", .value = 70 },
                .{ .name = "high_shibata", .value = 71 },
                .{ .name = "f_weighted", .value = 66 },
                .{ .name = "modified_e_weighted", .value = 67 },
                .{ .name = "improved_e_weighted", .value = 68 },
            } },
            .{ .name = "dither_scale", .field = "dither_scale", .kind = .float, .help = "set dither scale", .min = 0, .max = std.math.maxInt(i32) },
        };

        comptime {
            options.check(SwrScalars);
        }
    };

    /// libswresample's options the port does not implement.
    const unsupported = [_][]const u8{
        "isr",                "in_sample_rate",     "isf",           "in_sample_fmt", "tsf",             "internal_sample_fmt",
        "ichl",               "in_chlayout",        "uchl",          "used_chlayout", "clev",            "center_mix_level",
        "slev",               "surround_mix_level", "lfe_mix_level", "rmvol",         "rematrix_volume", "rematrix_maxval",
        "flags",              "swr_flags",          "resampler",     "precision",     "cheby",           "min_comp",
        "min_hard_comp",      "comp_duration",      "max_soft_comp", "async",         "first_pts",       "matrix_encoding",
        "output_sample_bits",
    };

    /// aresample's option first, then libswresample's
    /// (`AV_OPT_SEARCH_CHILDREN`).
    fn set(a: *AResample, name: []const u8, text: []const u8) CreateError!void {
        if (std.mem.eql(u8, name, "sample_rate")) {
            var own: Own = .{ .sample_rate = a.sample_rate };
            try options.set(Own, &own, name, text);
            a.sample_rate = own.sample_rate;
            return;
        }
        if (std.mem.eql(u8, name, "osf") or std.mem.eql(u8, name, "out_sample_fmt")) {
            a.out_sample_format = try sampleFormatValue(text);
            return;
        }
        if (std.mem.eql(u8, name, "ochl") or std.mem.eql(u8, name, "out_chlayout")) {
            a.out_layout = try layoutValue(text);
            return;
        }
        if (options.set(SwrScalars, &a.swr_scalars, name, text)) |_| return else |err| {
            if (err != error.UnknownOption) return err;
        }
        if (options.set(resample.Options, &a.resampler, name, text)) |_| return else |err| {
            if (err != error.UnknownOption) return err;
        }
        for (unsupported) |u| {
            if (std.mem.eql(u8, u, name)) return error.UnsupportedOption;
        }
        return error.UnknownOption;
    }

    /// The output rate the options ask for, or 0 (`osr` after
    /// `sample_rate`, as `query_formats` sets it).
    pub fn outRate(a: *const AResample) i32 {
        return if (a.sample_rate > 0) a.sample_rate else a.swr_scalars.out_sample_rate;
    }
};

/// A frame the graph owns: whole frames of `format`, one plane after
/// another when planar, with no padding.
pub const Owned = struct {
    format: audio.Format,
    data: []align(8) u8,
    pts: ?i64,

    pub fn alloc(gpa: std.mem.Allocator, format: audio.Format, frames: u32, pts: ?i64) error{OutOfMemory}!Owned {
        const len = std.math.mul(usize, frames, format.bytesPerFrame()) catch return error.OutOfMemory;
        return .{ .format = format, .data = try gpa.alignedAlloc(u8, .@"8", len), .pts = pts };
    }

    pub fn free(o: *Owned, gpa: std.mem.Allocator) void {
        gpa.free(o.data);
        o.* = undefined;
    }

    pub fn frameCount(o: *const Owned) u32 {
        return @intCast(o.data.len / o.format.bytesPerFrame());
    }

    pub fn buffer(o: *const Owned) samples.Buffer {
        const layout = samples.Layout.init(o.format.sample_format, o.format.channelCount(), o.frameCount(), .{ .line = 1 }) catch unreachable;
        return samples.Buffer.init(layout, o.data) catch unreachable;
    }
};

/// The aresample filter on configured links: libswresample as `aresample`
/// calls it, with its timestamps.
pub const ResampleRun = struct {
    gpa: std.mem.Allocator,
    in_format: audio.Format,
    out_format: audio.Format,
    in_time_base: time.TimeBase,
    mode: Mode,
    /// swr's `outpts`: the next output's time in 1 / (in rate * out rate).
    outpts: i64 = 0,
    first_pts_seen: bool = false,

    const Mode = union(enum) {
        /// The same rate: libswresample converts without resampling.
        convert: Convert,
        resample: swr.Swr,
    };

    const Convert = struct {
        /// Owned; null when the layouts are the same.
        remix: ?*rematrix.Remix,
        dithering: ?dither.Dither,
        scratch: std.ArrayList(u8) = .empty,
    };

    pub const Error = rematrix.Error || resample.Error || error{
        /// A `dither_method` number of no method (`swr_init` fails).
        InvalidDither,
    };

    pub fn init(gpa: std.mem.Allocator, a: AResample, in_format: audio.Format, out_format: audio.Format, in_time_base: time.TimeBase, sink: ?diagnostics.Sink) Error!ResampleRun {
        const method = dither.methodFromNumber(a.swr_scalars.dither_method) catch return error.InvalidDither;
        const dither_options: dither.Options = .{ .method = method, .scale = a.swr_scalars.dither_scale, .diagnostics = sink };
        var r: ResampleRun = .{ .gpa = gpa, .in_format = in_format, .out_format = out_format, .in_time_base = in_time_base, .mode = undefined };
        if (in_format.sample_rate != out_format.sample_rate) {
            r.mode = .{ .resample = try swr.Swr.init(gpa, in_format, out_format, 1024, .{ .resampler = a.resampler, .dither = dither_options }) };
            return r;
        }
        const remix = try gpa.create(rematrix.Remix);
        errdefer gpa.destroy(remix);
        const mixes = try remix.init(in_format, out_format.layout, out_format.sample_format, .{});
        r.mode = .{ .convert = .{
            .remix = if (mixes) remix else null,
            .dithering = if (mixes)
                dither.Dither.initInternal(remix.internal, remix.out_channels, in_format.sample_rate, out_format.sample_format, dither_options)
            else
                dither.Dither.init(in_format, out_format.sample_format, dither_options),
        } };
        if (!mixes) gpa.destroy(remix);
        return r;
    }

    pub fn deinit(r: *ResampleRun) void {
        switch (r.mode) {
            .resample => |*s| s.deinit(),
            .convert => |*c| {
                if (c.remix) |m| r.gpa.destroy(m);
                c.scratch.deinit(r.gpa);
            },
        }
        r.* = undefined;
    }

    /// Whether a call filled its room: `flush(false)` comes before more
    /// input (`more_data`).
    pub fn more(r: *const ResampleRun) bool {
        return switch (r.mode) {
            .resample => |*s| s.more,
            .convert => false,
        };
    }

    pub fn clearMore(r: *ResampleRun) void {
        switch (r.mode) {
            .resample => |*s| s.more = false,
            .convert => {},
        }
    }

    fn rates(r: *const ResampleRun) i64 {
        return @as(i64, r.in_format.sample_rate) * r.out_format.sample_rate;
    }

    /// `swr_get_delay(s, in rate * out rate)`.
    fn delay(r: *const ResampleRun) i64 {
        return switch (r.mode) {
            .resample => |*s| s.delayIn(r.rates()),
            // Nothing is ever buffered: the room exceeds the input.
            .convert => 0,
        };
    }

    /// `ROUNDED_DIV(outpts, in rate)`.
    fn outputPts(r: *const ResampleRun, outpts: i64) i64 {
        const b: i64 = r.in_format.sample_rate;
        const half = b >> 1;
        return @divTrunc(if (outpts >= 0) outpts + half else outpts - half, b);
    }

    /// `filter_frame`: the output of one input frame, or null when the
    /// call gave nothing.
    pub fn filterFrame(r: *ResampleRun, in: *const Owned) Error!?Owned {
        var pts: ?i64 = null;
        if (in.pts) |p| {
            // av_rescale(pts, tb.num * out rate * in rate, tb.den), then
            // swr_next_pts without compensation.
            const inpts = rescale(p, @as(i128, r.in_time_base.num) * r.rates(), r.in_time_base.den);
            if (!r.first_pts_seen) {
                r.first_pts_seen = true;
                r.outpts = inpts;
            }
            r.outpts = inpts - r.delay();
            pts = r.outputPts(r.outpts);
        }
        const count = in.frameCount();
        const view = in.buffer().view();
        switch (r.mode) {
            .resample => |*s| {
                const out = try s.filterFrame(view, count) orelse return null;
                return try r.take(out, pts);
            },
            .convert => |*c| {
                var out = try Owned.alloc(r.gpa, r.out_format, count, pts);
                errdefer out.free(r.gpa);
                const buffer = out.buffer();
                if (c.remix) |m| {
                    const scratch = try r.scratchOf(c, m.scratchLen(count));
                    rematrix.convert(m, buffer, view, count, scratch, if (c.dithering) |*d| d else null);
                } else if (c.dithering) |*d| {
                    const scratch = try r.scratchOf(c, d.scratchLen(count));
                    d.convert(buffer, view, count, scratch);
                } else {
                    audioconvert.convert(buffer, view, 0, 0, count);
                }
                r.outpts += @as(i64, count) * r.in_format.sample_rate;
                return out;
            },
        }
    }

    /// `flush_frame`: buffered output, the resampler flushed first when
    /// `final`; null when there is none.
    pub fn flush(r: *ResampleRun, final: bool) Error!?Owned {
        const pts = r.outputPts(r.outpts);
        switch (r.mode) {
            .resample => |*s| {
                const out = try s.flushFrame(final) orelse return null;
                return try r.take(out, pts);
            },
            .convert => return null,
        }
    }

    /// Copies a call's output into a frame and advances `outpts`.
    fn take(r: *ResampleRun, out: samples.View, pts: ?i64) Error!Owned {
        const frames = out.layout.samples;
        var o = try Owned.alloc(r.gpa, r.out_format, frames, pts);
        audioconvert.convert(o.buffer(), out, 0, 0, frames);
        r.outpts += @as(i64, frames) * r.in_format.sample_rate;
        return o;
    }

    fn scratchOf(r: *ResampleRun, c: *Convert, len: usize) error{OutOfMemory}![]u8 {
        try c.scratch.resize(r.gpa, @max(len, c.scratch.items.len));
        return c.scratch.items[0..len];
    }

    /// `av_rescale` with a wide multiplier.
    fn rescale(a: i64, b: i128, c: i64) i64 {
        const product: i128 = @as(i128, a) * b;
        const half: i128 = @divTrunc(c, 2);
        const rounded = if (product < 0) -@divTrunc(-product + half, c) else @divTrunc(product + half, c);
        return std.math.cast(i64, rounded) orelse if (rounded < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    }
};

const testing = std.testing;

test "the filters are found by FFmpeg's names" {
    try testing.expectEqual(Kind.volume, find("volume").?.kind);
    try testing.expectEqual(null, find("Volume"));
    try testing.expectError(error.UnknownFilter, Filter.create(testing.allocator, "atempo", &.{}));
}

test "sample formats are set as set_string_fmt sets them" {
    try testing.expectEqual(SampleFormat.s16p, (try sampleFormatValue("s16p")).?);
    try testing.expectEqual(null, try sampleFormatValue("none"));
    try testing.expectEqual(SampleFormat.flt, (try sampleFormatValue("3")).?);
    try testing.expectEqual(SampleFormat.s32, (try sampleFormatValue("0x2")).?);
    try testing.expectEqual(SampleFormat.u8, (try sampleFormatValue("")).?);
    try testing.expectError(error.InvalidValue, sampleFormatValue("12"));
    try testing.expectError(error.InvalidValue, sampleFormatValue("-1"));
    try testing.expectError(error.InvalidValue, sampleFormatValue("s17"));
    try testing.expectError(error.InvalidValue, sampleFormatValue(" "));
}

test "aformat takes '|' lists, a backslash escaping" {
    const gpa = testing.allocator;
    var f = try Filter.create(gpa, "aformat", &.{
        .{ .name = "f", .value = "s16|flt" },
        .{ .name = "sample_rates", .value = "8000|44.1k" },
        .{ .name = "cl", .value = "stereo|3C" },
    });
    defer f.deinit(gpa);
    try testing.expectEqualSlices(i32, &.{ 1, 3 }, f.aformat.formatList());
    try testing.expectEqualSlices(i32, &.{ 8000, 44100 }, f.aformat.rates.items);
    try testing.expectEqual(2, f.aformat.layouts.items.len);
    try f.set(gpa, "f", "s32|none|u8");
    try testing.expectEqualSlices(i32, &.{2}, f.aformat.formatList());
    try testing.expectError(error.InvalidValue, f.set(gpa, "cl", "stereo|nonsense"));
    try testing.expectError(error.OutOfRange, f.set(gpa, "r", "0"));
    try testing.expectError(error.OutOfRange, f.set(gpa, "r", "default"));
    try testing.expectError(error.UnknownOption, f.set(gpa, "layouts", "mono"));
}

test "volume takes a constant and refuses an expression" {
    const gpa = testing.allocator;
    var f = try Filter.create(gpa, "volume", &.{ .{ .name = "volume", .value = " -6dB " }, .{ .name = "precision", .value = "fixed" } });
    defer f.deinit(gpa);
    try testing.expectApproxEqRel(0.501187, f.volume.volume, 1e-5);
    try testing.expectEqual(Precision.fixed, f.volume.rest.precision);
    try testing.expectError(error.Expression, f.set(gpa, "volume", "1/2"));
    try testing.expectError(error.InvalidValue, f.set(gpa, "volume", " "));
    try testing.expectError(error.InvalidValue, f.set(gpa, "precision", "half"));
    try testing.expectError(error.UnknownOption, f.set(gpa, "gain", "2"));
}

test "aresample's options and libswresample's" {
    const gpa = testing.allocator;
    var f = try Filter.create(gpa, "aresample", &.{
        .{ .name = "osr", .value = "22.05k" },
        .{ .name = "osf", .value = "s16p" },
        .{ .name = "ochl", .value = "mono" },
        .{ .name = "dither_method", .value = "triangular" },
        .{ .name = "filter_size", .value = "16" },
    });
    defer f.deinit(gpa);
    try testing.expectEqual(22050, f.aresample.outRate());
    try f.set(gpa, "sample_rate", "48000");
    try testing.expectEqual(48000, f.aresample.outRate());
    try testing.expectEqual(SampleFormat.s16p, f.aresample.out_sample_format.?);
    try testing.expectEqual(2, f.aresample.swr_scalars.dither_method);
    try testing.expectEqual(16, f.aresample.resampler.filter_size);
    try testing.expectError(error.UnsupportedOption, f.set(gpa, "async", "1"));
    try testing.expectError(error.UnknownOption, f.set(gpa, "speed", "2"));
    try testing.expectError(error.UnknownOption, f.set(gpa, "triangular", "1"));
}

test "fixed-point volume rounds the gain and scales as FFmpeg does" {
    const v: Volume = .{ .volume = 0.5, .rest = .{ .precision = .fixed } };
    const r = try VolumeRun.init(v, .s16, null);
    try testing.expectEqual(128, r.volume_i);
    var data: [8]u8 align(8) = undefined;
    const values = [_]i16{ 1000, -1000, 3, -3 };
    @memcpy(&data, std.mem.sliceAsBytes(&values));
    r.apply(&data);
    try testing.expectEqualSlices(i16, &.{ 500, -500, 2, -1 }, std.mem.bytesAsSlice(i16, &data));
    const nan: Volume = .{ .volume = std.math.nan(f64) };
    try testing.expectError(error.InvalidVolume, VolumeRun.init(nan, .flt, null));
    const nan_frame: Volume = .{ .volume = std.math.nan(f64), .rest = .{ .eval = .frame } };
    try testing.expectEqual(0, (try VolumeRun.init(nan_frame, .flt, null)).volume);
    const huge: Volume = .{ .volume = 1e10, .rest = .{ .precision = .fixed } };
    try testing.expectError(error.VolumeOutOfRange, VolumeRun.init(huge, .s16, null));
}
