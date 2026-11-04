// SPDX-License-Identifier: LGPL-2.1-or-later
// Translated from FFmpeg at the pinned reference revision:
// libavcodec/flacenc.c (Copyright (c) 2006 Justin Ruggles) and
// flacdsp_lpc_template.c (Copyright (c) 2012 Mans Rullgard), with the
// PUT_UTF8 macro of libavutil/common.h; LGPL 2.1 or later, as LICENSE holds.
//! FFmpeg's FLAC encoder (TODO.md T26c), packet for packet: stereo
//! decorrelation chosen by estimate or forced, wasted bits, constant,
//! verbatim, fixed and LPC subframes with FFmpeg's order searches, Rice and
//! Rice2 partitions, the verbatim fallback, STREAMINFO and the input's MD5.
//!
//! The encoder borrows nothing: `encode` copies the interleaved input and
//! returns a packet borrowed until the next call. Its buffers are sized for
//! the block size chosen at `init`. Integer arithmetic that C leaves to
//! wrap (it reads one stale sample past a block in the two-at-a-time
//! loops) wraps here; floating-point analysis is lpc.zig's.

const std = @import("std");
const bits = @import("bits.zig");
const flac = @import("flac.zig");
const lpc = @import("lpc.zig");
const options_zig = @import("../core/options.zig");

const max_fixed_order = 4;
const max_partition_order = 8;
const max_partitions = 1 << max_partition_order;
const max_lpc_precision = 15;
const min_lpc_shift = 0;
const max_lpc_shift = 15;

/// The subframe type codes.
const SubframeType = enum(u8) { constant = 0, verbatim = 1, fixed = 8, lpc = 32 };

/// `enum CodingMode`: the Rice parameter width.
const CodingMode = enum(u3) { rice = 4, rice2 = 5 };

pub const SampleFormat = enum { s16, s32 };

/// The stream: what FFmpeg's `AVCodecContext` gives the encoder.
pub const Params = struct {
    sample_format: SampleFormat,
    /// `bits_per_raw_sample`: for s32, up to 24 encodes as 24 bits per
    /// sample, more as 32 only with `Options.strict_experimental`.
    bits_per_raw_sample: u8 = 0,
    channels: u8,
    sample_rate: u32,
    /// The block size (16 to 65535); 0 lets the encoder choose from the
    /// compression level and the rate.
    frame_size: u32 = 0,
};

/// The encoder's options, FFmpeg's names and defaults; null is FFmpeg's -1,
/// the compression level's choice.
pub const Options = struct {
    compression_level: ?i32 = null,
    lpc_type: ?lpc.Type = null,
    lpc_passes: u32 = 2,
    lpc_coeff_precision: u5 = 15,
    min_prediction_order: ?u6 = null,
    max_prediction_order: ?u6 = null,
    prediction_order_method: ?lpc.OrderMethod = null,
    min_partition_order: ?u4 = null,
    max_partition_order: ?u4 = null,
    /// null: estimated per frame.
    ch_mode: ?flac.ChannelMode = null,
    exact_rice_parameters: bool = false,
    multi_dim_quant: bool = false,
    /// `-strict experimental`: 32-bit samples stay 32 bits.
    strict_experimental: bool = false,
};

/// The options as FFmpeg's command line sets them (T17a's `options.set`):
/// FFmpeg's names, ranges, named constants and -1 defaults, the generic
/// `compression_level` and `strict` among them. `toOptions` gives the
/// encoder's.
pub const AvOptions = struct {
    compression_level: i32 = -1,
    lpc_coeff_precision: i32 = 15,
    lpc_type: i32 = -1,
    lpc_passes: i32 = 2,
    min_partition_order: i32 = -1,
    max_partition_order: i32 = -1,
    prediction_order_method: i32 = -1,
    ch_mode: i32 = -1,
    exact_rice_parameters: bool = false,
    multi_dim_quant: bool = false,
    min_prediction_order: i32 = -1,
    max_prediction_order: i32 = -1,
    strict: i32 = 0,

    const int_min: f64 = std.math.minInt(i32);
    const int_max: f64 = std.math.maxInt(i32);

    pub const option_specs = [_]options_zig.Spec{
        .{ .name = "compression_level", .field = "compression_level", .kind = .int, .help = "", .min = int_min, .max = int_max },
        .{ .name = "lpc_coeff_precision", .field = "lpc_coeff_precision", .kind = .int, .help = "LPC coefficient precision", .min = 0, .max = max_lpc_precision },
        .{ .name = "lpc_type", .field = "lpc_type", .kind = .int, .help = "LPC algorithm", .min = -1, .max = 3, .constants = &.{
            .{ .name = "none", .value = 0 }, .{ .name = "fixed", .value = 1 }, .{ .name = "levinson", .value = 2 }, .{ .name = "cholesky", .value = 3 },
        } },
        .{ .name = "lpc_passes", .field = "lpc_passes", .kind = .int, .help = "Number of passes to use for Cholesky factorization during LPC analysis", .min = 1, .max = int_max },
        .{ .name = "min_partition_order", .field = "min_partition_order", .kind = .int, .help = "", .min = -1, .max = max_partition_order },
        .{ .name = "max_partition_order", .field = "max_partition_order", .kind = .int, .help = "", .min = -1, .max = max_partition_order },
        .{ .name = "prediction_order_method", .field = "prediction_order_method", .kind = .int, .help = "Search method for selecting prediction order", .min = -1, .max = 5, .constants = &.{
            .{ .name = "estimation", .value = 0 }, .{ .name = "2level", .value = 1 }, .{ .name = "4level", .value = 2 }, .{ .name = "8level", .value = 3 }, .{ .name = "search", .value = 4 }, .{ .name = "log", .value = 5 },
        } },
        .{ .name = "ch_mode", .field = "ch_mode", .kind = .int, .help = "Stereo decorrelation mode", .min = -1, .max = 3, .constants = &.{
            .{ .name = "auto", .value = -1 }, .{ .name = "indep", .value = 0 }, .{ .name = "left_side", .value = 1 }, .{ .name = "right_side", .value = 2 }, .{ .name = "mid_side", .value = 3 },
        } },
        .{ .name = "exact_rice_parameters", .field = "exact_rice_parameters", .kind = .bool, .help = "Calculate rice parameters exactly", .min = 0, .max = 1 },
        .{ .name = "multi_dim_quant", .field = "multi_dim_quant", .kind = .bool, .help = "Multi-dimensional quantization", .min = 0, .max = 1 },
        .{ .name = "min_prediction_order", .field = "min_prediction_order", .kind = .int, .help = "", .min = -1, .max = lpc.max_order },
        .{ .name = "max_prediction_order", .field = "max_prediction_order", .kind = .int, .help = "", .min = -1, .max = lpc.max_order },
        .{ .name = "strict", .field = "strict", .kind = .int, .help = "how strictly to follow the standards", .min = int_min, .max = int_max, .constants = &.{
            .{ .name = "very", .value = 2 }, .{ .name = "strict", .value = 1 }, .{ .name = "normal", .value = 0 }, .{ .name = "unofficial", .value = -1 }, .{ .name = "experimental", .value = -2 },
        } },
    };

    comptime {
        options_zig.check(AvOptions);
    }

    /// The encoder's options; the ranges above keep every value in its
    /// field.
    pub fn toOptions(o: AvOptions) Options {
        return .{
            .compression_level = if (o.compression_level < 0) null else o.compression_level,
            .lpc_type = if (o.lpc_type < 0) null else @fromBackingInt(@intCast(o.lpc_type)),
            .lpc_passes = @intCast(o.lpc_passes),
            .lpc_coeff_precision = @intCast(o.lpc_coeff_precision),
            .min_prediction_order = if (o.min_prediction_order < 0) null else @intCast(o.min_prediction_order),
            .max_prediction_order = if (o.max_prediction_order < 0) null else @intCast(o.max_prediction_order),
            .prediction_order_method = if (o.prediction_order_method < 0) null else @fromBackingInt(@intCast(o.prediction_order_method)),
            .min_partition_order = if (o.min_partition_order < 0) null else @intCast(o.min_partition_order),
            .max_partition_order = if (o.max_partition_order < 0) null else @intCast(o.max_partition_order),
            .ch_mode = if (o.ch_mode < 0) null else @fromBackingInt(@intCast(o.ch_mode)),
            .exact_rice_parameters = o.exact_rice_parameters,
            .multi_dim_quant = o.multi_dim_quant,
            // FFmpeg's FF_COMPLIANCE_EXPERIMENTAL is -2.
            .strict_experimental = o.strict <= -2,
        };
    }
};

pub const InitError = error{
    /// FFmpeg's `avcodec_open2` refuses the stream: channels, rate or block
    /// size (`AVERROR(EINVAL)`).
    UnsupportedFormat,
    /// FFmpeg refuses the options: the level, the orders, an option out
    /// of its range.
    InvalidOption,
    OutOfMemory,
};

pub const EncodeError = error{
    /// More samples than the block size, or a short block before the last.
    InvalidFrame,
    OutOfMemory,
};

const RiceContext = struct {
    coding_mode: CodingMode = .rice,
    porder: u4 = 0,
    params: [max_partitions]u5 = @splat(0),
};

const Subframe = struct {
    type: SubframeType = .constant,
    type_code: u8 = 0,
    obits: u8 = 0,
    wasted: u8 = 0,
    order: u8 = 0,
    coefs: [lpc.max_order]i32 = @splat(0),
    shift: i32 = 0,
    rc: RiceContext = .{},
    /// The block, then one more sample the two-at-a-time loops read.
    samples: []i32,
    /// The residual, then the one more the two-at-a-time loops write.
    residual: []i32,
};

/// The encoder's compression options once `init` resolved them.
const Resolved = struct {
    lpc_type: lpc.Type,
    lpc_passes: u32,
    lpc_coeff_precision: u5,
    min_prediction_order: u6,
    max_prediction_order: u6,
    prediction_order_method: lpc.OrderMethod,
    min_partition_order: u4,
    max_partition_order: u4,
    ch_mode: ?flac.ChannelMode,
    exact_rice_parameters: bool,
    multi_dim_quant: bool,
};

/// A packet borrowed from the encoder until its next call.
pub const Packet = struct {
    data: []const u8,
    pts: i64,
    duration: u32,
};

/// The flush's result: the final STREAMINFO (FFmpeg's new-extradata side
/// data) and the timestamp after the last sample.
pub const Final = struct {
    streaminfo: [flac.streaminfo_size]u8,
    pts: i64,
};

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    params: Params,
    options: Resolved,
    /// FFmpeg's `bits_per_raw_sample` after `init`: 16, 24 or 32.
    bits_per_raw_sample: u8,
    bps_code: u3,
    channels: u8,
    sample_rate: u32,
    sr_code: [2]u32,
    /// The block size.
    frame_size: u32,
    min_framesize: u32,
    max_framesize: u32,
    max_encoded_framesize: u32 = 0,
    frame_count: u32 = 0,
    sample_count: u64 = 0,
    md5: std.crypto.hash.Md5,
    md5sum: [16]u8 = @splat(0),
    streaminfo: [flac.streaminfo_size]u8 = @splat(0),
    lpc_ctx: lpc.Context,
    subframes: [flac.max_channels]Subframe,
    samples_33bps: []i64,
    /// `rc_udata` and `rc_sums`, shared by the subframes: each search
    /// writes what it reads.
    rc_udata: []u32,
    rc_sums: *[32][max_partitions]u64,
    md5_buffer: []u8,
    packet: std.ArrayList(u8) = .empty,
    // FlacFrame.
    blocksize: u32 = 0,
    bs_code: [2]u32 = .{ 0, 0 },
    ch_mode: flac.ChannelMode = .independent,
    verbatim_only: bool = false,
    flushed: bool = false,
    next_pts: i64 = 0,

    /// `flac_encode_init`: checks the stream and the options as FFmpeg
    /// does, in its order, and writes the first STREAMINFO.
    pub fn init(gpa: std.mem.Allocator, params: Params, options: Options) InitError!*Encoder {
        const set = try setup(params, options);
        const e = try gpa.create(Encoder);
        errdefer gpa.destroy(e);
        e.* = .{
            .gpa = gpa,
            .params = params,
            .options = set.resolved,
            .bits_per_raw_sample = set.bits_per_raw_sample,
            .bps_code = set.bps_code,
            .channels = params.channels,
            .sample_rate = params.sample_rate,
            .sr_code = set.sr_code,
            .frame_size = set.frame_size,
            .min_framesize = 0,
            .max_framesize = maxFrameSize(set.frame_size, params.channels, set.bits_per_raw_sample),
            .md5 = .init(.{}),
            .lpc_ctx = undefined,
            .subframes = undefined,
            .samples_33bps = &.{},
            .rc_udata = &.{},
            .rc_sums = undefined,
            .md5_buffer = &.{},
        };
        try e.allocate();
        e.writeStreaminfo();
        e.min_framesize = e.max_framesize;
        return e;
    }

    /// The checks `init` makes, without allocating: what FFmpeg's
    /// `avcodec_open2` would refuse.
    pub fn validate(params: Params, options: Options) error{ UnsupportedFormat, InvalidOption }!void {
        _ = try setup(params, options);
    }

    const Setup = struct {
        bits_per_raw_sample: u8,
        bps_code: u3,
        sr_code: [2]u32,
        resolved: Resolved,
        frame_size: u32,
    };

    fn setup(params: Params, options: Options) error{ UnsupportedFormat, InvalidOption }!Setup {
        // Out-of-range options fail where FFmpeg sets them, before the
        // encoder's checks. A precision of 0, which FFmpeg's range allows
        // and its arithmetic does not, is refused too.
        if (options.lpc_passes < 1 or options.lpc_coeff_precision < 1 or options.lpc_coeff_precision > max_lpc_precision) return error.InvalidOption;
        if (options.min_prediction_order) |o| if (o > lpc.max_order) return error.InvalidOption;
        if (options.max_prediction_order) |o| if (o > lpc.max_order) return error.InvalidOption;
        if (options.min_partition_order) |o| if (o > max_partition_order) return error.InvalidOption;
        if (options.max_partition_order) |o| if (o > max_partition_order) return error.InvalidOption;

        var bits_per_raw_sample: u8 = undefined;
        var bps_code: u3 = undefined;
        switch (params.sample_format) {
            .s16 => {
                bits_per_raw_sample = 16;
                bps_code = 4;
            },
            .s32 => if (params.bits_per_raw_sample <= 24 or !options.strict_experimental) {
                bits_per_raw_sample = 24;
                bps_code = 6;
            } else {
                bits_per_raw_sample = 32;
                bps_code = 7;
            },
        }
        const channels = params.channels;
        if (channels < 1 or channels > flac.max_channels) return error.UnsupportedFormat;

        const freq = params.sample_rate;
        if (freq < 1) return error.UnsupportedFormat;
        var sr_code: [2]u32 = undefined;
        if (std.mem.findScalar(u32, flac.sample_rate_table[1..12], freq)) |index| {
            sr_code = .{ @intCast(index + 1), 0 };
        } else if (freq % 1000 == 0 and freq < 255000) {
            sr_code = .{ 12, freq / 1000 };
        } else if (freq % 10 == 0 and freq < 655350) {
            sr_code = .{ 14, freq / 10 };
        } else if (freq < 65535) {
            sr_code = .{ 13, freq };
        } else if (freq < 1048576) {
            sr_code = .{ 0, 0 };
        } else {
            return error.UnsupportedFormat;
        }

        const level_option = options.compression_level orelse -1;
        const level: usize = if (level_option < 0) 5 else std.math.cast(usize, level_option) orelse return error.InvalidOption;
        if (level > 12) return error.InvalidOption;

        const block_time_ms = [13]u32{ 27, 27, 27, 105, 105, 105, 105, 105, 105, 105, 105, 105, 105 };
        const lpc_types = [13]lpc.Type{ .fixed, .fixed, .fixed, .levinson, .levinson, .levinson, .levinson, .levinson, .levinson, .levinson, .levinson, .levinson, .levinson };
        const min_orders = [13]u6{ 2, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
        const max_orders = [13]u6{ 3, 4, 4, 6, 8, 8, 8, 8, 12, 12, 12, 32, 32 };
        const methods = [13]lpc.OrderMethod{ .estimation, .estimation, .estimation, .estimation, .estimation, .estimation, .four_level, .log, .four_level, .log, .search, .log, .search };
        const min_partitions = [13]u4{ 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        const max_partitions_table = [13]u4{ 2, 2, 3, 3, 3, 8, 8, 8, 8, 8, 8, 8, 8 };

        var resolved: Resolved = .{
            .lpc_type = options.lpc_type orelse lpc_types[level],
            .lpc_passes = options.lpc_passes,
            .lpc_coeff_precision = options.lpc_coeff_precision,
            .min_prediction_order = options.min_prediction_order orelse min_orders[level],
            .max_prediction_order = options.max_prediction_order orelse max_orders[level],
            .prediction_order_method = options.prediction_order_method orelse methods[level],
            .min_partition_order = undefined,
            .max_partition_order = undefined,
            .ch_mode = options.ch_mode,
            .exact_rice_parameters = options.exact_rice_parameters,
            .multi_dim_quant = options.multi_dim_quant,
        };
        // FFmpeg compares the options as given, -1 included.
        const min_p: i8 = if (options.min_partition_order) |o| o else -1;
        const max_p: i8 = if (options.max_partition_order) |o| o else -1;
        if (min_p > max_p) return error.InvalidOption;
        resolved.min_partition_order = options.min_partition_order orelse min_partitions[level];
        resolved.max_partition_order = options.max_partition_order orelse max_partitions_table[level];

        switch (resolved.lpc_type) {
            .none => {
                resolved.min_prediction_order = 0;
                resolved.max_prediction_order = 0;
            },
            .fixed => {
                resolved.min_prediction_order = @min(resolved.min_prediction_order, max_fixed_order);
                resolved.max_prediction_order = @min(resolved.max_prediction_order, max_fixed_order);
            },
            .levinson, .cholesky => resolved.min_prediction_order = @max(resolved.min_prediction_order, lpc.min_order),
        }
        if (resolved.max_prediction_order < resolved.min_prediction_order) return error.InvalidOption;

        var frame_size = params.frame_size;
        if (frame_size > 0) {
            if (frame_size < flac.min_blocksize or frame_size > flac.max_blocksize) return error.UnsupportedFormat;
        } else {
            frame_size = selectBlocksize(freq, block_time_ms[level]);
        }

        return .{ .bits_per_raw_sample = bits_per_raw_sample, .bps_code = bps_code, .sr_code = sr_code, .resolved = resolved, .frame_size = frame_size };
    }

    fn allocate(e: *Encoder) std.mem.Allocator.Error!void {
        const gpa = e.gpa;
        const n = e.frame_size;
        var done: usize = 0;
        errdefer for (e.subframes[0..done]) |*sub| {
            gpa.free(sub.samples);
            gpa.free(sub.residual);
        };
        for (e.subframes[0..e.channels]) |*sub| {
            const samples = try gpa.alloc(i32, n + 1);
            errdefer gpa.free(samples);
            const residual = try gpa.alloc(i32, n + 1);
            @memset(samples, 0);
            @memset(residual, 0);
            sub.* = .{ .samples = samples, .residual = residual };
            done += 1;
        }
        e.samples_33bps = try gpa.alloc(i64, n + 1);
        errdefer gpa.free(e.samples_33bps);
        @memset(e.samples_33bps, 0);
        e.rc_udata = try gpa.alloc(u32, n);
        errdefer gpa.free(e.rc_udata);
        e.rc_sums = try gpa.create([32][max_partitions]u64);
        errdefer gpa.destroy(e.rc_sums);
        const sample_bytes: usize = (@as(usize, e.bits_per_raw_sample) + 7) / 8;
        e.md5_buffer = try gpa.alloc(u8, n * e.channels * sample_bytes);
        errdefer gpa.free(e.md5_buffer);
        e.lpc_ctx = try .init(gpa, n);
    }

    pub fn deinit(e: *Encoder) void {
        const gpa = e.gpa;
        for (e.subframes[0..e.channels]) |*sub| {
            gpa.free(sub.samples);
            gpa.free(sub.residual);
        }
        gpa.free(e.samples_33bps);
        gpa.free(e.rc_udata);
        gpa.destroy(e.rc_sums);
        gpa.free(e.md5_buffer);
        e.lpc_ctx.deinit(gpa);
        e.packet.deinit(gpa);
        gpa.destroy(e);
    }

    /// The first STREAMINFO (FFmpeg's extradata after `init`): no sample
    /// count, frame sizes or MD5 yet.
    pub fn initialStreaminfo(e: *const Encoder) [flac.streaminfo_size]u8 {
        return e.streaminfo;
    }

    /// `write_streaminfo`.
    fn writeStreaminfo(e: *Encoder) void {
        var header: [flac.streaminfo_size]u8 = @splat(0);
        var pb: bits.BitWriter = .init(&header);
        pb.bits(16, e.frame_size);
        pb.bits(16, e.frame_size);
        pb.bits(24, e.min_framesize);
        pb.bits(24, e.max_framesize);
        pb.bits(20, e.sample_rate);
        pb.bits(3, e.channels - 1);
        pb.bits(5, e.bits_per_raw_sample - 1);
        pb.bits(24, (e.sample_count & 0xFFFFFF000) >> 12);
        pb.bits(12, e.sample_count & 0x000000FFF);
        pb.flush();
        std.debug.assert(!pb.overflow);
        @memcpy(header[18..34], &e.md5sum);
        e.streaminfo = header;
    }

    /// `flac_encode_frame` with a frame of `nb_samples` interleaved
    /// samples (`input` holds at least `nb_samples * channels`), at most
    /// the block size; only the last may be shorter.
    pub fn encode(e: *Encoder, input: Input, nb_samples: u32, pts: i64) EncodeError!Packet {
        std.debug.assert(!e.flushed);
        if (nb_samples == 0 or nb_samples > e.frame_size) return error.InvalidFrame;
        if (@as(SampleFormat, input) != e.params.sample_format) return error.InvalidFrame;
        switch (input) {
            inline else => |s| if (s.len < @as(usize, nb_samples) * e.channels) return error.InvalidFrame,
        }
        // A smaller final frame lowers the verbatim bound (the previous
        // frame's block size: none before the first frame).
        if (nb_samples < e.blocksize) e.max_framesize = maxFrameSize(nb_samples, e.channels, e.bits_per_raw_sample);

        e.initFrame(nb_samples);
        e.copySamples(input);
        e.channelDecorrelation();
        e.removeWastedBits();

        var frame_bytes = e.encodeFrame();
        if (frame_bytes > e.max_framesize) {
            e.verbatim_only = true;
            frame_bytes = e.encodeFrame();
        }
        try e.packet.resize(e.gpa, frame_bytes);
        const out_bytes = e.writeFrame(e.packet.items);
        std.debug.assert(out_bytes == frame_bytes);

        e.frame_count +%= 1;
        e.sample_count += nb_samples;
        e.updateMd5(input, nb_samples);
        e.max_encoded_framesize = @max(e.max_encoded_framesize, out_bytes);
        e.min_framesize = @min(e.min_framesize, out_bytes);
        e.next_pts = pts + nb_samples;
        return .{ .data = e.packet.items[0..out_bytes], .pts = pts, .duration = nb_samples };
    }

    /// The flush (`flac_encode_frame` without a frame): the final
    /// STREAMINFO, once.
    pub fn flush(e: *Encoder) Final {
        std.debug.assert(!e.flushed);
        e.max_framesize = e.max_encoded_framesize;
        e.md5.final(&e.md5sum);
        e.writeStreaminfo();
        e.flushed = true;
        return .{ .streaminfo = e.streaminfo, .pts = e.next_pts };
    }

    /// `init_frame`.
    fn initFrame(e: *Encoder, nb_samples: u32) void {
        if (std.mem.findScalar(u32, &flac.blocksize_table, nb_samples)) |i| {
            e.blocksize = nb_samples;
            e.bs_code = .{ @intCast(i), 0 };
        } else {
            e.blocksize = nb_samples;
            e.bs_code = .{ if (nb_samples <= 256) 6 else 7, nb_samples - 1 };
        }
        for (e.subframes[0..e.channels]) |*sub| {
            sub.wasted = 0;
            sub.obits = e.bits_per_raw_sample;
            sub.rc.coding_mode = if (sub.obits > 16) .rice2 else .rice;
        }
        e.verbatim_only = false;
    }

    /// `copy_samples`: s32 input shifted down to its sample size.
    fn copySamples(e: *Encoder, input: Input) void {
        const n = e.blocksize;
        const ch = e.channels;
        switch (input) {
            .s16 => |s| for (0..n) |i| {
                for (e.subframes[0..ch], 0..) |*sub, c| sub.samples[i] = s[i * ch + c];
            },
            .s32 => |s| {
                const shift: u5 = @intCast(32 - e.bits_per_raw_sample);
                for (0..n) |i| {
                    for (e.subframes[0..ch], 0..) |*sub, c| sub.samples[i] = s[i * ch + c] >> shift;
                }
            },
        }
    }

    /// `channel_decorrelation`.
    fn channelDecorrelation(e: *Encoder) void {
        const n = e.blocksize;
        if (e.channels != 2) {
            e.ch_mode = .independent;
            return;
        }
        const left = e.subframes[0].samples;
        const right = e.subframes[1].samples;
        const side = e.samples_33bps;
        e.ch_mode = e.options.ch_mode orelse blk: {
            const max_rice_param: u32 = (@as(u32, 1) << @backingInt(e.subframes[0].rc.coding_mode)) - 2;
            break :blk estimateStereoMode(left[0..n], right[0..n], max_rice_param, e.bits_per_raw_sample);
        };
        if (e.ch_mode == .independent) return;
        if (e.bits_per_raw_sample == 32) {
            switch (e.ch_mode) {
                .mid_side => {
                    for (0..n) |i| {
                        const tmp: i64 = left[i];
                        left[i] = @intCast((tmp + right[i]) >> 1);
                        side[i] = tmp - right[i];
                    }
                    e.subframes[1].obits += 1;
                },
                .left_side => {
                    for (0..n) |i| side[i] = @as(i64, left[i]) - right[i];
                    e.subframes[1].obits += 1;
                },
                .right_side => {
                    for (0..n) |i| side[i] = @as(i64, left[i]) - right[i];
                    e.subframes[0].obits += 1;
                },
                .independent => unreachable,
            }
        } else {
            switch (e.ch_mode) {
                .mid_side => {
                    for (0..n) |i| {
                        const tmp = left[i];
                        left[i] = (tmp +% right[i]) >> 1;
                        right[i] = tmp -% right[i];
                    }
                    e.subframes[1].obits += 1;
                },
                .left_side => {
                    for (0..n) |i| right[i] = left[i] -% right[i];
                    e.subframes[1].obits += 1;
                },
                .right_side => {
                    for (0..n) |i| left[i] -%= right[i];
                    e.subframes[0].obits += 1;
                },
                .independent => unreachable,
            }
        }
    }

    /// `remove_wasted_bits`. FFmpeg returns, not continues, at the first
    /// channel without wasted bits, so the channels after it keep theirs.
    fn removeWastedBits(e: *Encoder) void {
        const n = e.blocksize;
        for (e.subframes[0..e.channels]) |*sub| {
            var wasted: u8 = undefined;
            if (sub.obits > 32) {
                var v: i64 = 0;
                for (e.samples_33bps[0..n]) |s| {
                    v |= s;
                    if (v & 1 != 0) break;
                }
                if (v == 0 or v & 1 != 0) return;
                const shift: u6 = @intCast(@ctz(v));
                for (0..n) |i| sub.samples[i] = @truncate(e.samples_33bps[i] >> shift);
                wasted = shift;
            } else {
                var v: i32 = 0;
                for (sub.samples[0..n]) |s| {
                    v |= s;
                    if (v & 1 != 0) break;
                }
                if (v == 0 or v & 1 != 0) return;
                const shift: u5 = @intCast(@ctz(v));
                for (sub.samples[0..n]) |*s| s.* >>= shift;
                wasted = shift;
            }
            sub.wasted = wasted;
            sub.obits -= wasted;
            if (sub.obits <= 17) sub.rc.coding_mode = .rice;
        }
    }

    /// `count_frame_header`.
    fn countFrameHeader(e: *const Encoder) u64 {
        var count: u64 = 32;
        count += 8 * utf8Length(e.frame_count);
        if (e.bs_code[0] == 6) count += 8 else if (e.bs_code[0] == 7) count += 16;
        const sr = e.sr_code[0];
        count += (@as(u64, @intFromBool(sr == 12)) + @as(u64, @intFromBool(sr > 12)) * 2) * 8;
        count += 8;
        return count;
    }

    /// `encode_frame`: the frame's size in bytes.
    fn encodeFrame(e: *Encoder) u32 {
        var count = e.countFrameHeader();
        for (0..e.channels) |ch| count += e.encodeResidualCh(ch);
        count += (8 - (count & 7)) & 7;
        count += 16;
        count >>= 3;
        // FFmpeg's AVERROR_BUG above INT_MAX cannot happen: a frame of
        // 65535 samples of 8 channels of 33 bits is about 2 MiB.
        return @intCast(count);
    }

    /// `subframe_count_exact`.
    fn subframeCountExact(e: *const Encoder, sub: *const Subframe, pred_order: u32) u64 {
        var count: u64 = 8;
        count += sub.wasted;
        switch (sub.type) {
            .constant => count += sub.obits,
            .verbatim => count += @as(u64, e.blocksize) * sub.obits,
            .fixed, .lpc => {
                count += @as(u64, pred_order) * sub.obits;
                if (sub.type == .lpc) count += 4 + 5 + @as(u64, pred_order) * e.options.lpc_coeff_precision;
                count += 2;
                const porder = sub.rc.porder;
                const psize = e.blocksize >> porder;
                count += 4;
                var i: u32 = pred_order;
                var part_end: u32 = psize;
                for (0..@as(u32, 1) << porder) |p| {
                    const k = sub.rc.params[p];
                    count += @backingInt(sub.rc.coding_mode);
                    if (part_end > i) count += riceCountExact(sub.residual[i..part_end], k);
                    i = part_end;
                    part_end = @min(e.blocksize, part_end + psize);
                }
            },
        }
        return count;
    }

    /// `find_subframe_rice_params`.
    fn findSubframeRiceParams(e: *Encoder, sub: *Subframe, pred_order: u32) u64 {
        const pmin = getMaxPOrder(e.options.min_partition_order, e.blocksize, pred_order);
        const pmax = getMaxPOrder(e.options.max_partition_order, e.blocksize, pred_order);
        var count: u64 = 8 + @as(u64, pred_order) * sub.obits + 2 + @backingInt(sub.rc.coding_mode);
        if (sub.type == .lpc) count += 4 + 5 + @as(u64, pred_order) * e.options.lpc_coeff_precision;
        count += calcRiceParams(&sub.rc, e.rc_udata, e.rc_sums, pmin, pmax, sub.residual, e.blocksize, pred_order, e.options.exact_rice_parameters);
        return count;
    }

    /// `lpc_encode_choose_datapath`: true when a residual does not fit.
    fn lpcEncodeChooseDatapath(e: *Encoder, bps: u32, res: []i32, smp: []const i32, len: u32, order: u32, coefs: []const i32, shift: i32) bool {
        var max_residual_value: u64 = 0;
        const max_sample_value: i64 = @as(i64, 1) << @intCast(bps - 1);
        for (coefs[0..order]) |c| max_residual_value +%= @abs(max_sample_value * c);
        max_residual_value >>= @intCast(shift);
        max_residual_value +%= @intCast(max_sample_value);
        if (bps > 32) {
            return lpcEncodeWithResidualLimit(i64, res, e.samples_33bps, len, order, coefs, shift);
        } else if (max_residual_value > std.math.maxInt(i32)) {
            return lpcEncodeWithResidualLimit(i32, res, smp, len, order, coefs, shift);
        } else if (bps + e.options.lpc_coeff_precision + log2(order) <= 32) {
            lpcEncode16(res, smp, len, order, coefs, shift);
        } else {
            lpcEncode32(res, smp, len, order, coefs, shift);
        }
        return false;
    }

    /// `DEFAULT_TO_VERBATIM`.
    fn defaultToVerbatim(e: *Encoder, sub: *Subframe) u64 {
        sub.type = .verbatim;
        sub.type_code = @backingInt(SubframeType.verbatim);
        if (sub.obits <= 32) @memcpy(sub.residual[0..e.blocksize], sub.samples[0..e.blocksize]);
        return e.subframeCountExact(sub, 0);
    }

    /// `encode_residual_ch`: picks the subframe and returns its size in
    /// bits.
    fn encodeResidualCh(e: *Encoder, ch: usize) u64 {
        const sub = &e.subframes[ch];
        const res = sub.residual;
        const smp = sub.samples;
        const smp_33bps = e.samples_33bps;
        const n = e.blocksize;

        // CONSTANT
        if (sub.obits > 32) {
            if (std.mem.allEqual(i64, smp_33bps[1..n], smp_33bps[0])) {
                sub.type = .constant;
                sub.type_code = @backingInt(SubframeType.constant);
                return e.subframeCountExact(sub, 0);
            }
        } else if (std.mem.allEqual(i32, smp[1..n], smp[0])) {
            sub.type = .constant;
            sub.type_code = @backingInt(SubframeType.constant);
            res[0] = smp[0];
            return e.subframeCountExact(sub, 0);
        }

        // VERBATIM
        if (e.verbatim_only or n < 5) return e.defaultToVerbatim(sub);

        const min_order: u32 = e.options.min_prediction_order;
        var max_order: u32 = e.options.max_prediction_order;
        const omethod = e.options.prediction_order_method;

        // FIXED
        sub.type = .fixed;
        if (e.options.lpc_type == .none or e.options.lpc_type == .fixed or n <= max_order) {
            var fixed_bits: [max_fixed_order + 1]u64 = undefined;
            if (max_order > max_fixed_order) max_order = max_fixed_order;
            var opt_order: u32 = 0;
            fixed_bits[0] = std.math.maxInt(u32);
            var i: u32 = min_order;
            while (i <= max_order) : (i += 1) {
                if (sub.obits == 33) {
                    if (encodeResidualFixedWithLimit(i64, res, smp_33bps, n, i)) continue;
                } else if (sub.obits + i >= 32) {
                    if (encodeResidualFixedWithLimit(i32, res, smp, n, i)) continue;
                } else {
                    encodeResidualFixed(res, smp, n, i);
                }
                fixed_bits[i] = e.findSubframeRiceParams(sub, i);
                if (fixed_bits[i] < fixed_bits[opt_order]) opt_order = i;
            }
            if (opt_order == 0 and fixed_bits[0] == std.math.maxInt(u32)) return e.defaultToVerbatim(sub);
            sub.order = @intCast(opt_order);
            sub.type_code = @backingInt(sub.type) | sub.order;
            if (sub.order != max_order) {
                // FFmpeg tests `obits + i` with `i` left by the loop above.
                if (sub.obits == 33) {
                    _ = encodeResidualFixedWithLimit(i64, res, smp_33bps, n, sub.order);
                } else if (sub.obits + i >= 32) {
                    _ = encodeResidualFixedWithLimit(i32, res, smp, n, sub.order);
                } else {
                    encodeResidualFixed(res, smp, n, sub.order);
                }
                _ = e.findSubframeRiceParams(sub, sub.order);
            }
            return e.subframeCountExact(sub, sub.order);
        }

        // LPC
        sub.type = .lpc;
        if (sub.obits == 33) {
            // FFmpeg drops the low bit for the analysis, which takes 32-bit
            // samples.
            for (0..n) |i| smp[i] = @truncate(smp_33bps[i] >> 1);
        }
        var coefs: lpc.Coefs = undefined;
        var shift: [lpc.max_order]i32 = undefined;
        var opt_order: i32 = @intCast(e.lpc_ctx.calcCoefs(smp[0..n], min_order, max_order, e.options.lpc_coeff_precision, &coefs, &shift, e.options.lpc_type, e.options.lpc_passes, omethod, min_lpc_shift, max_lpc_shift, 0));
        const obits: u32 = sub.obits;
        const min_o: i32 = @intCast(min_order);
        const max_o: i32 = @intCast(max_order);

        switch (omethod) {
            .two_level, .four_level, .eight_level => {
                const levels: i32 = @as(i32, 1) << @backingInt(omethod);
                var level_bits: [1 << @backingInt(lpc.OrderMethod.eight_level)]u64 = undefined;
                var order: i32 = -1;
                var opt_index: i32 = levels - 1;
                opt_order = max_o - 1;
                level_bits[@intCast(opt_index)] = std.math.maxInt(u32);
                var i: i32 = levels - 1;
                while (i >= 0) : (i -= 1) {
                    const last_order = order;
                    order = min_o + @divTrunc((max_o - min_o + 1) * (i + 1), levels) - 1;
                    order = std.math.clamp(order, min_o - 1, max_o - 1);
                    if (order == last_order) continue;
                    const o: usize = @intCast(order);
                    if (e.lpcEncodeChooseDatapath(obits, res, smp, n, @intCast(o + 1), &coefs[o], shift[o])) continue;
                    level_bits[@intCast(i)] = e.findSubframeRiceParams(sub, @intCast(o + 1));
                    if (level_bits[@intCast(i)] < level_bits[@intCast(opt_index)]) {
                        opt_index = i;
                        opt_order = order;
                    }
                }
                opt_order += 1;
            },
            .search => {
                var order_bits: [lpc.max_order]u64 = undefined;
                opt_order = 0;
                order_bits[0] = std.math.maxInt(u32);
                var i: i32 = min_o - 1;
                while (i < max_o) : (i += 1) {
                    const o: usize = @intCast(i);
                    if (e.lpcEncodeChooseDatapath(obits, res, smp, n, @intCast(o + 1), &coefs[o], shift[o])) continue;
                    order_bits[o] = e.findSubframeRiceParams(sub, @intCast(o + 1));
                    if (order_bits[o] < order_bits[@intCast(opt_order)]) opt_order = i;
                }
                opt_order += 1;
            },
            .log => {
                var order_bits: [lpc.max_order]u64 = @splat(std.math.maxInt(u64));
                opt_order = min_o - 1 + @divTrunc(max_o - min_o, 3);
                var step: i32 = 16;
                while (step != 0) : (step >>= 1) {
                    const last = opt_order;
                    var i: i32 = last - step;
                    while (i <= last + step) : (i += step) {
                        if (i < min_o - 1 or i >= max_o or order_bits[@intCast(i)] < std.math.maxInt(u32)) continue;
                        const o: usize = @intCast(i);
                        if (e.lpcEncodeChooseDatapath(obits, res, smp, n, @intCast(o + 1), &coefs[o], shift[o])) continue;
                        order_bits[o] = e.findSubframeRiceParams(sub, @intCast(o + 1));
                        if (order_bits[o] < order_bits[@intCast(opt_order)]) opt_order = i;
                    }
                }
                opt_order += 1;
            },
            .estimation => {},
        }

        const chosen: usize = @intCast(opt_order);
        if (e.options.multi_dim_quant) {
            // FFmpeg's int, which wraps for orders above 19.
            var allsteps: i32 = 1;
            const qmax: i32 = (@as(i32, 1) << (e.options.lpc_coeff_precision - 1)) - 1;
            for (0..chosen) |_| allsteps *%= 3;
            var best_score: u64 = std.math.maxInt(i64);
            while (true) {
                var improved = false;
                var step: i32 = 0;
                while (step < allsteps) : (step += 1) {
                    var tmp = step;
                    var lpc_try: [lpc.max_order]i32 = undefined;
                    var diffsum: u32 = 0;
                    for (0..chosen) |i| {
                        const diff: i32 = @rem(tmp + 1, 3) - 1;
                        lpc_try[i] = std.math.clamp(coefs[chosen - 1][i] + diff, -qmax, qmax);
                        tmp = @divTrunc(tmp, 3);
                        diffsum += @intFromBool(diff != 0);
                    }
                    if (diffsum > 8) continue;
                    if (e.lpcEncodeChooseDatapath(obits, res, smp, n, @intCast(chosen), &lpc_try, shift[chosen - 1])) continue;
                    const score = e.findSubframeRiceParams(sub, @intCast(chosen));
                    if (score < best_score) {
                        best_score = score;
                        coefs[chosen - 1] = lpc_try;
                        improved = true;
                    }
                }
                if (!improved) break;
            }
        }

        sub.order = @intCast(chosen);
        sub.type_code = @backingInt(sub.type) | (sub.order - 1);
        sub.shift = shift[chosen - 1];
        @memcpy(sub.coefs[0..chosen], coefs[chosen - 1][0..chosen]);
        if (e.lpcEncodeChooseDatapath(obits, res, smp, n, sub.order, &sub.coefs, sub.shift)) return e.defaultToVerbatim(sub);
        _ = e.findSubframeRiceParams(sub, sub.order);
        return e.subframeCountExact(sub, sub.order);
    }

    /// `write_frame`: header, subframes and footer into `out`, exactly
    /// `encode_frame`'s size; returns the bytes written.
    fn writeFrame(e: *Encoder, out: []u8) u32 {
        var pb: bits.BitWriter = .init(out);
        e.writeFrameHeader(&pb);
        e.writeSubframes(&pb);
        // write_frame_footer.
        pb.flush();
        const crc = bits.Crc16.hash(pb.written());
        pb.bits(16, crc);
        pb.flush();
        std.debug.assert(!pb.overflow);
        return @intCast(pb.written().len);
    }

    fn writeFrameHeader(e: *Encoder, pb: *bits.BitWriter) void {
        pb.bits(16, 0xFFF8);
        pb.bits(4, e.bs_code[0]);
        pb.bits(4, e.sr_code[0]);
        if (e.ch_mode == .independent) {
            pb.bits(4, e.channels - 1);
        } else {
            pb.bits(4, @as(u32, @backingInt(e.ch_mode)) + flac.max_channels - 1);
        }
        pb.bits(3, e.bps_code);
        pb.bits(1, 0);
        writeUtf8(pb, e.frame_count);
        if (e.bs_code[0] == 6) pb.bits(8, e.bs_code[1]) else if (e.bs_code[0] == 7) pb.bits(16, e.bs_code[1]);
        if (e.sr_code[0] == 12) pb.bits(8, e.sr_code[1]) else if (e.sr_code[0] > 12) pb.bits(16, e.sr_code[1]);
        pb.flush();
        pb.bits(8, bits.Crc8.hash(pb.written()));
    }

    fn writeSubframes(e: *Encoder, pb: *bits.BitWriter) void {
        const n = e.blocksize;
        for (e.subframes[0..e.channels]) |*sub| {
            const res = sub.residual;
            pb.bits(1, 0);
            pb.bits(6, sub.type_code);
            pb.bits(1, @intFromBool(sub.wasted != 0));
            if (sub.wasted != 0) pb.bits(@intCast(sub.wasted), 1);
            switch (sub.type) {
                .constant => if (sub.obits == 33) {
                    pb.signed(33, e.samples_33bps[0]);
                } else {
                    pb.signed(@intCast(sub.obits), res[0]);
                },
                .verbatim => if (sub.obits == 33) {
                    for (e.samples_33bps[0..n]) |s| pb.signed(33, s);
                } else {
                    for (res[0..n]) |s| pb.signed(@intCast(sub.obits), s);
                },
                .fixed, .lpc => {
                    const order = sub.order;
                    if (sub.obits == 33) {
                        for (e.samples_33bps[0..order]) |s| pb.signed(33, s);
                    } else {
                        for (res[0..order]) |s| pb.signed(@intCast(sub.obits), s);
                    }
                    if (sub.type == .lpc) {
                        const cbits = e.options.lpc_coeff_precision;
                        pb.bits(4, cbits - 1);
                        pb.signed(5, sub.shift);
                        for (sub.coefs[0..order]) |c| pb.signed(cbits, c);
                    }
                    pb.bits(2, @backingInt(sub.rc.coding_mode) - 4);
                    const porder = sub.rc.porder;
                    const psize = n >> porder;
                    pb.bits(4, porder);
                    var i: u32 = order;
                    var part_end: u32 = psize;
                    for (0..@as(u32, 1) << porder) |p| {
                        const k = sub.rc.params[p];
                        pb.bits(@backingInt(sub.rc.coding_mode), k);
                        while (i < part_end) : (i += 1) pb.riceFlac(res[i], k);
                        part_end = @min(n, part_end + psize);
                    }
                },
            }
        }
    }

    /// `update_md5_sum`: the samples as FLAC's MD5 takes them, signed
    /// little-endian in the fewest bytes holding the sample size.
    fn updateMd5(e: *Encoder, input: Input, nb_samples: u32) void {
        const count = @as(usize, nb_samples) * e.channels;
        switch (input) {
            .s16 => |s| {
                const out = e.md5_buffer[0 .. count * 2];
                for (s[0..count], 0..) |v, i| std.mem.writeInt(i16, out[2 * i ..][0..2], v, .little);
                e.md5.update(out);
            },
            .s32 => |s| if (e.bits_per_raw_sample <= 24) {
                const out = e.md5_buffer[0 .. count * 3];
                for (s[0..count], 0..) |v, i| std.mem.writeInt(i24, out[3 * i ..][0..3], @truncate(v >> 8), .little);
                e.md5.update(out);
            } else {
                const out = e.md5_buffer[0 .. count * 4];
                for (s[0..count], 0..) |v, i| std.mem.writeInt(i32, out[4 * i ..][0..4], v, .little);
                e.md5.update(out);
            },
        }
    }
};

/// Interleaved input samples, in the stream's sample format.
pub const Input = union(SampleFormat) {
    s16: []const i16,
    s32: []const i32,
};

/// `flac_get_max_frame_size`: the size of a verbatim frame, the bound a
/// frame falls back to verbatim above.
fn maxFrameSize(blocksize: u32, ch: u32, bps: u32) u32 {
    var count: u32 = 16;
    count += ch * ((7 + bps + 7) / 8);
    if (ch == 2) {
        count += ((2 * bps + 1) * blocksize + 7) / 8;
    } else {
        count += (ch * bps * blocksize + 7) / 8;
    }
    count += 2;
    return count;
}

/// `select_blocksize`: the largest table size at most `block_time_ms` of
/// samples, at least 192.
fn selectBlocksize(samplerate: u32, block_time_ms: u32) u32 {
    var blocksize = flac.blocksize_table[1];
    // FFmpeg's int product; rates are below 2^20.
    const target = samplerate * block_time_ms / 1000;
    for (flac.blocksize_table) |size| {
        if (target >= size and size > blocksize) blocksize = size;
    }
    return blocksize;
}

/// `av_log2`: floor of the base-2 logarithm, 0 for 0.
fn log2(v: u32) u32 {
    return if (v == 0) 0 else 31 - @clz(v);
}

/// The bytes `PUT_UTF8` writes for `value`.
fn utf8Length(value: u32) u32 {
    if (value < 0x80) return 1;
    return (log2(value) + 4) / 5;
}

/// `write_utf8`: FFmpeg's `PUT_UTF8`, up to 7 bytes for 32 bits.
fn writeUtf8(pb: *bits.BitWriter, value: u32) void {
    if (value < 0x80) {
        pb.bits(8, value);
        return;
    }
    const bytes = (log2(value) + 4) / 5;
    var shift: u32 = (bytes - 1) * 6;
    const lead: u32 = (256 - (@as(u32, 256) >> @intCast(bytes))) | (value >> @intCast(shift));
    pb.bits(8, lead & 0xff);
    while (shift >= 6) {
        shift -= 6;
        pb.bits(8, 0x80 | ((value >> @intCast(shift)) & 0x3f));
    }
}

/// The folded (zigzag) residual FLAC's Rice code takes.
fn fold(r: i32) u32 {
    return @bitCast((r << 1) ^ (r >> 31));
}

/// `rice_count_exact`.
fn riceCountExact(res: []const i32, k: u5) u64 {
    var count: u64 = 0;
    for (res) |r| count += (fold(r) >> k) + 1 + @as(u64, k);
    return count;
}

/// The `rice_encode_count` macro: unsigned 64-bit arithmetic, which wraps
/// when `sum` is below `n / 2`, as FFmpeg's does.
fn riceEncodeCount(sum: u64, n: u32, k: u32) u64 {
    const lead: u64 = @as(u64, n) * (k + 1);
    return lead +% ((sum -% (n >> 1)) >> @intCast(k));
}

/// `find_optimal_param`.
fn findOptimalParam(sum: u64, n: u32, max_param: u32) u32 {
    if (sum <= n >> 1) return 0;
    const sum2 = sum - (n >> 1);
    // av_clipl_int32 takes an int64: the quotient reinterpreted, then
    // clipped; av_log2 takes it as unsigned.
    const q: i64 = @bitCast(sum2 / n);
    const clipped: i32 = @intCast(std.math.clamp(q, std.math.minInt(i32), std.math.maxInt(i32)));
    const k = log2(@bitCast(clipped));
    return @min(k, max_param);
}

/// `find_optimal_param_exact`.
fn findOptimalParamExact(sums: *const [32][max_partitions]u64, i: usize, max_param: u32) u32 {
    var bestk: u32 = 0;
    var bestbits: i64 = std.math.maxInt(i64);
    for (0..max_param + 1) |k| {
        const b: i64 = @bitCast(sums[k][i]);
        if (b < bestbits) {
            bestbits = b;
            bestk = @intCast(k);
        }
    }
    return bestk;
}

/// `calc_optimal_rice_params`.
fn calcOptimalRiceParams(rc: *RiceContext, porder: u4, sums: *const [32][max_partitions]u64, n: u32, pred_order: u32, max_param: u32, exact: bool) u64 {
    const part: u32 = @as(u32, 1) << porder;
    var all_bits: u64 = 4 * @as(u64, part);
    // getMaxPOrder keeps the first partition at least `pred_order` long.
    var cnt: u32 = (n >> porder) - pred_order;
    for (0..part) |i| {
        var k: u32 = undefined;
        if (exact) {
            k = findOptimalParamExact(sums, i, max_param);
            all_bits +%= sums[k][i];
        } else {
            k = findOptimalParam(sums[0][i], cnt, max_param);
            all_bits +%= riceEncodeCount(sums[0][i], cnt, k);
        }
        rc.params[i] = @intCast(k);
        cnt = n >> porder;
    }
    rc.porder = porder;
    return all_bits;
}

/// `calc_sum_top`.
fn calcSumTop(pmax: u4, kmax: u32, data: []const u32, n: u32, pred_order: u32, sums: *[32][max_partitions]u64) void {
    const parts: u32 = @as(u32, 1) << pmax;
    for (0..kmax + 1) |k| {
        var res: u32 = pred_order;
        var res_end: u32 = n >> pmax;
        for (0..parts) |i| {
            if (kmax != 0) {
                var sum: u64 = (1 + @as(u64, k)) * (res_end - res);
                while (res < res_end) : (res += 1) sum +%= data[res] >> @intCast(k);
                sums[k][i] = sum;
            } else {
                var sum: u64 = 0;
                while (res < res_end) : (res += 1) sum +%= data[res];
                sums[k][i] = sum;
            }
            res_end += n >> pmax;
        }
    }
}

/// `calc_sum_next`.
fn calcSumNext(level: u4, sums: *[32][max_partitions]u64, kmax: u32) void {
    const parts: u32 = @as(u32, 1) << level;
    for (0..parts) |i| {
        for (0..kmax + 1) |k| sums[k][i] = sums[k][2 * i] +% sums[k][2 * i + 1];
    }
}

/// `calc_rice_params`.
fn calcRiceParams(rc: *RiceContext, udata: []u32, sums: *[32][max_partitions]u64, pmin: u4, pmax: u4, data: []const i32, n: u32, pred_order: u32, exact: bool) u64 {
    std.debug.assert(pmin <= pmax and pmax <= max_partition_order);
    var bits_at: [max_partition_order + 1]u64 = undefined;
    var tmp_rc: RiceContext = .{ .coding_mode = rc.coding_mode };
    const kmax: u32 = (@as(u32, 1) << @backingInt(rc.coding_mode)) - 2;
    for (pred_order..n) |i| udata[i] = fold(data[i]);
    calcSumTop(pmax, if (exact) kmax else 0, udata, n, pred_order, sums);
    var opt_porder = pmin;
    bits_at[pmin] = std.math.maxInt(u32);
    var i = pmax;
    while (true) {
        bits_at[i] = calcOptimalRiceParams(&tmp_rc, i, sums, n, pred_order, kmax, exact);
        if (bits_at[i] < bits_at[opt_porder] or pmax == pmin) {
            opt_porder = i;
            rc.* = tmp_rc;
        }
        if (i == pmin) break;
        i -= 1;
        calcSumNext(i, sums, if (exact) kmax else 0);
    }
    return bits_at[opt_porder];
}

/// `get_max_p_order`.
fn getMaxPOrder(max_porder: u4, n: u32, order: u32) u4 {
    var porder: u32 = @min(max_porder, log2(n ^ (n - 1)));
    if (order > 0) porder = @min(porder, log2(n / order));
    return @intCast(porder);
}

/// `encode_residual_fixed`, C's int arithmetic wrapping: the two-at-a-time
/// loops read `smp[n]` and write `res[n]`, both outside the block.
fn encodeResidualFixed(res: []i32, smp: []const i32, n: u32, order: u32) void {
    for (0..order) |i| res[i] = smp[i];
    switch (order) {
        0 => for (order..n) |i| {
            res[i] = smp[i];
        },
        1 => for (order..n) |i| {
            res[i] = smp[i] -% smp[i - 1];
        },
        2 => {
            var a = smp[order - 1] -% smp[order - 2];
            var i: usize = order;
            while (i < n) : (i += 2) {
                const b = smp[i] -% smp[i - 1];
                res[i] = b -% a;
                a = smp[i + 1] -% smp[i];
                res[i + 1] = a -% b;
            }
        },
        3 => {
            var a = smp[order - 1] -% smp[order - 2];
            var c = smp[order - 1] -% 2 *% smp[order - 2] +% smp[order - 3];
            var i: usize = order;
            while (i < n) : (i += 2) {
                const b = smp[i] -% smp[i - 1];
                const d = b -% a;
                res[i] = d -% c;
                a = smp[i + 1] -% smp[i];
                c = a -% b;
                res[i + 1] = c -% d;
            }
        },
        else => {
            var a = smp[order - 1] -% smp[order - 2];
            var c = smp[order - 1] -% 2 *% smp[order - 2] +% smp[order - 3];
            var ee = smp[order - 1] -% 3 *% smp[order - 2] +% 3 *% smp[order - 3] -% smp[order - 4];
            var i: usize = order;
            while (i < n) : (i += 2) {
                const b = smp[i] -% smp[i - 1];
                const d = b -% a;
                const f = d -% c;
                res[i] = f -% ee;
                a = smp[i + 1] -% smp[i];
                c = a -% b;
                ee = c -% d;
                res[i + 1] = ee -% f;
            }
        },
    }
}

/// `encode_residual_fixed_with_residual_limit` (and its `_33bps` twin for
/// `T` = i64): true when a residual falls outside (INT32_MIN, INT32_MAX].
/// Order 0 keeps only the low 32 bits of a 33-bit sample, as FFmpeg's does.
fn encodeResidualFixedWithLimit(comptime T: type, res: []i32, smp: []const T, n: u32, order: u32) bool {
    const lo = std.math.minInt(i32);
    const hi = std.math.maxInt(i32);
    for (0..order) |i| res[i] = @truncate(smp[i]);
    for (order..n) |i| {
        const r: i64 = switch (order) {
            0 => {
                if (smp[i] == lo) return true;
                res[i] = @truncate(smp[i]);
                continue;
            },
            1 => @as(i64, smp[i]) - smp[i - 1],
            2 => @as(i64, smp[i]) - 2 * @as(i64, smp[i - 1]) + smp[i - 2],
            3 => @as(i64, smp[i]) - 3 * @as(i64, smp[i - 1]) + 3 * @as(i64, smp[i - 2]) - smp[i - 3],
            else => @as(i64, smp[i]) - 4 * @as(i64, smp[i - 1]) + 6 * @as(i64, smp[i - 2]) - 4 * @as(i64, smp[i - 3]) + smp[i - 4],
        };
        if (r <= lo or r > hi) return true;
        res[i] = @intCast(r);
    }
    return false;
}

/// `lpc_encode_with_residual_limit` (and `_33bps`): true when a residual
/// falls outside (INT32_MIN, INT32_MAX].
fn lpcEncodeWithResidualLimit(comptime T: type, res: []i32, smp: []const T, len: u32, order: u32, coefs: []const i32, shift: i32) bool {
    for (0..order) |i| res[i] = @truncate(smp[i]);
    for (order..len) |i| {
        var p: i64 = 0;
        for (0..order) |j| p +%= @as(i64, coefs[j]) *% smp[i - 1 - j];
        p >>= @intCast(shift);
        const tmp = @as(i64, smp[i]) -% p;
        if (tmp <= std.math.minInt(i32) or tmp > std.math.maxInt(i32)) return true;
        res[i] = @intCast(tmp);
    }
    return false;
}

/// `flac_lpc_encode_c_16`: 32-bit sums, wrapping as C's int does.
fn lpcEncode16(res: []i32, smp: []const i32, len: u32, order: u32, coefs: []const i32, shift: i32) void {
    for (0..order) |i| res[i] = smp[i];
    for (order..len) |i| {
        var p: i32 = 0;
        for (0..order) |j| p +%= coefs[j] *% smp[i - 1 - j];
        res[i] = smp[i] -% (p >> @intCast(shift));
    }
}

/// `flac_lpc_encode_c_32`: 64-bit sums clipped to 32 bits.
fn lpcEncode32(res: []i32, smp: []const i32, len: u32, order: u32, coefs: []const i32, shift: i32) void {
    for (0..order) |i| res[i] = smp[i];
    for (order..len) |i| {
        var p: i64 = 0;
        for (0..order) |j| p +%= @as(i64, coefs[j]) * smp[i - 1 - j];
        const clipped: i32 = @intCast(std.math.clamp(p >> @intCast(shift), std.math.minInt(i32), std.math.maxInt(i32)));
        res[i] = smp[i] -% clipped;
    }
}

/// `estimate_stereo_mode`.
fn estimateStereoMode(left: []const i32, right: []const i32, max_rice_param: u32, bps: u32) flac.ChannelMode {
    const n: u32 = @intCast(left.len);
    var sum: [4]u64 = @splat(0);
    if (bps < 30) {
        for (2..@max(n, 2)) |i| {
            const lt = left[i] -% 2 *% left[i - 1] +% left[i - 2];
            const rt = right[i] -% 2 *% right[i - 1] +% right[i - 2];
            sum[2] +%= absWide(i32, (lt +% rt) >> 1);
            sum[3] +%= absWide(i32, lt -% rt);
            sum[0] +%= absWide(i32, lt);
            sum[1] +%= absWide(i32, rt);
        }
    } else {
        for (2..@max(n, 2)) |i| {
            const lt = @as(i64, left[i]) - 2 * @as(i64, left[i - 1]) + left[i - 2];
            const rt = @as(i64, right[i]) - 2 * @as(i64, right[i - 1]) + right[i - 2];
            sum[2] +%= absWide(i64, (lt + rt) >> 1);
            sum[3] +%= absWide(i64, lt - rt);
            sum[0] +%= absWide(i64, lt);
            sum[1] +%= absWide(i64, rt);
        }
    }
    for (&sum) |*s| {
        const k = findOptimalParam(2 *% s.*, n, max_rice_param);
        s.* = riceEncodeCount(2 *% s.*, n, k);
    }
    const score = [4]u64{ sum[0] +% sum[1], sum[0] +% sum[3], sum[1] +% sum[3], sum[2] +% sum[3] };
    var best: usize = 0;
    for (1..4) |i| {
        if (score[i] < score[best]) best = i;
    }
    return @fromBackingInt(@intCast(best));
}

/// FFABS of a C int or int64 added to a uint64: the absolute value, which
/// for the minimum stays negative and converts with sign extension.
fn absWide(comptime T: type, v: T) u64 {
    const a: T = if (v < 0) 0 -% v else v;
    return @bitCast(@as(i64, a));
}

const testing = std.testing;

const vectors = @embedFile("../testing/vectors/flacenc.txt");

/// flacenc_vectors.c's xorshift32 signal generator.
const Signal = struct {
    rng_state: u32,
    state: [8]i64 = @splat(0),
    kind: []const u8,
    bits: u6,

    fn rng(g: *Signal) u32 {
        var x = g.rng_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        g.rng_state = x;
        return x;
    }

    fn sample(g: *Signal, c: usize, i: u32) !i64 {
        const top: i64 = @as(i64, 1) << (g.bits - 1);
        const channel: i64 = @intCast(c);
        const noise: i64 = @as(i64, g.rng() & 0xffff) - 0x8000;
        var v: i64 = undefined;
        if (std.mem.eql(u8, g.kind, "tone")) {
            const period: i64 = 64 + 24 * channel;
            const phase = @mod(@as(i64, i), period);
            const tri = if (phase < @divTrunc(period, 2)) phase else period - phase;
            const half = @divTrunc(period, 2);
            v = @divTrunc((tri * 2 - half) * @divTrunc(top, 2), half) + @divTrunc(noise * top, 8 * 32768);
        } else if (std.mem.eql(u8, g.kind, "noise")) {
            const high: u64 = g.rng();
            const low: u64 = g.rng();
            const wide: i64 = @bitCast(high << 32 | low);
            v = wide >> @intCast(64 - @as(u7, g.bits));
        } else if (std.mem.eql(u8, g.kind, "smooth") or std.mem.eql(u8, g.kind, "wasted")) {
            const x = @divTrunc(noise * top, 32768);
            g.state[c] += @divTrunc(x - g.state[c], 8);
            v = g.state[c] * 2;
            if (std.mem.eql(u8, g.kind, "wasted")) v = @divTrunc(v, 8) * 8;
        } else if (std.mem.eql(u8, g.kind, "stereo")) {
            const x = @divTrunc(noise * top, 32768);
            if (c == 0) {
                g.state[0] += @divTrunc(x - g.state[0], 8);
                v = g.state[0] * 2;
            } else {
                v = g.state[0] * 2 + @divTrunc(noise, 64) * (top >> 15);
            }
        } else if (std.mem.eql(u8, g.kind, "steps")) {
            v = (@as(i64, @mod(@divTrunc(i, 300), 5)) - 2) * @divTrunc(top, 3) + channel;
        } else if (std.mem.eql(u8, g.kind, "ramp")) {
            const slope: i64 = if (c != 0) -987654321 else 1234567890123;
            v = (@as(i64, i) * slope) >> @intCast(64 - @as(u7, g.bits));
        } else if (std.mem.eql(u8, g.kind, "extremes")) {
            v = if ((i + c) & 1 != 0) top - 1 else -top;
            if (g.rng() & 1 != 0) v = -top;
        } else return error.UnknownSignal;
        return std.math.clamp(v, -top, top - 1);
    }
};

fn parseOptions(text: []const u8) !Options {
    var o: Options = .{};
    if (std.mem.eql(u8, text, "-")) return o;
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse return error.BadVector;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "compression_level")) {
            o.compression_level = try std.fmt.parseInt(i32, value, 10);
        } else if (std.mem.eql(u8, key, "lpc_type")) {
            o.lpc_type = std.meta.stringToEnum(lpc.Type, value) orelse return error.BadVector;
        } else if (std.mem.eql(u8, key, "lpc_passes")) {
            o.lpc_passes = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "lpc_coeff_precision")) {
            o.lpc_coeff_precision = try std.fmt.parseInt(u5, value, 10);
        } else if (std.mem.eql(u8, key, "min_prediction_order")) {
            o.min_prediction_order = try std.fmt.parseInt(u6, value, 10);
        } else if (std.mem.eql(u8, key, "max_prediction_order")) {
            o.max_prediction_order = try std.fmt.parseInt(u6, value, 10);
        } else if (std.mem.eql(u8, key, "prediction_order_method")) {
            const names = [_]struct { []const u8, lpc.OrderMethod }{ .{ "estimation", .estimation }, .{ "2level", .two_level }, .{ "4level", .four_level }, .{ "8level", .eight_level }, .{ "search", .search }, .{ "log", .log } };
            o.prediction_order_method = for (names) |name| {
                if (std.mem.eql(u8, name[0], value)) break name[1];
            } else return error.BadVector;
        } else if (std.mem.eql(u8, key, "min_partition_order")) {
            o.min_partition_order = try std.fmt.parseInt(u4, value, 10);
        } else if (std.mem.eql(u8, key, "max_partition_order")) {
            o.max_partition_order = try std.fmt.parseInt(u4, value, 10);
        } else if (std.mem.eql(u8, key, "ch_mode")) {
            o.ch_mode = if (std.mem.eql(u8, value, "indep")) .independent else std.meta.stringToEnum(flac.ChannelMode, value) orelse return error.BadVector;
        } else if (std.mem.eql(u8, key, "exact_rice_parameters")) {
            o.exact_rice_parameters = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "multi_dim_quant")) {
            o.multi_dim_quant = std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "strict")) {
            o.strict_experimental = std.mem.eql(u8, value, "experimental");
        } else return error.BadVector;
    }
    return o;
}

fn hexOf(comptime n: usize, bytes: *const [n]u8) [2 * n]u8 {
    return std.fmt.bytesToHex(bytes.*, .lower);
}

/// Encodes one vector case and checks its lines; returns the lines read.
fn checkCase(gpa: std.mem.Allocator, header: []const u8, lines: *std.mem.SplitIterator(u8, .scalar)) !void {
    var f = std.mem.tokenizeScalar(u8, header, ' ');
    _ = f.next(); // C
    const name = f.next().?;
    errdefer std.debug.print("flacenc case {s}\n", .{name});
    const kind = f.next().?;
    const channels = try std.fmt.parseInt(u8, f.next().?, 10);
    const rate = try std.fmt.parseInt(u32, f.next().?, 10);
    const format: SampleFormat = if (std.mem.eql(u8, f.next().?, "s32")) .s32 else .s16;
    const raw_bits = try std.fmt.parseInt(u8, f.next().?, 10);
    const total = try std.fmt.parseInt(u32, f.next().?, 10);
    const frame_size = try std.fmt.parseInt(u32, f.next().?, 10);
    const options = try parseOptions(f.next().?);

    const open_line = lines.next().?;
    const encoder = Encoder.init(gpa, .{ .sample_format = format, .bits_per_raw_sample = raw_bits, .channels = channels, .sample_rate = rate, .frame_size = frame_size }, options) catch |err| {
        try testing.expectEqualStrings("O EINVAL", open_line);
        try testing.expect(err == error.UnsupportedFormat or err == error.InvalidOption);
        return;
    };
    defer encoder.deinit();
    try testing.expectEqualStrings("O ok", open_line);
    const info = lines.next().?;
    var expected_info: [128]u8 = undefined;
    const initial = encoder.initialStreaminfo();
    try testing.expectEqualStrings(info, try std.fmt.bufPrint(&expected_info, "I {d} {d} {s}", .{ encoder.bits_per_raw_sample, encoder.frame_size, &hexOf(34, &initial) }));

    const bits_gen: u6 = if (raw_bits != 0) @intCast(raw_bits) else if (format == .s32) 32 else 16;
    var gen: Signal = .{ .rng_state = 0x9e3779b9 ^ (@as(u32, channels) * 7919 + total), .kind = kind, .bits = bits_gen };
    const block = encoder.frame_size;
    const buffer16 = try gpa.alloc(i16, @as(usize, block) * channels);
    defer gpa.free(buffer16);
    const buffer32 = try gpa.alloc(i32, @as(usize, block) * channels);
    defer gpa.free(buffer32);
    var start: u32 = 0;
    while (start < total) : (start += block) {
        const n = @min(block, total - start);
        for (0..n) |i| {
            const index: u32 = @intCast(i);
            for (0..channels) |c| {
                const v = try gen.sample(c, start + index);
                const at = i * channels + c;
                switch (format) {
                    .s16 => buffer16[at] = @truncate(v),
                    .s32 => {
                        const raw: u32 = @truncate(@as(u64, @bitCast(v)));
                        buffer32[at] = @bitCast(raw << @intCast(32 - @as(u7, bits_gen)));
                    },
                }
            }
        }
        const input: Input = switch (format) {
            .s16 => .{ .s16 = buffer16 },
            .s32 => .{ .s32 = buffer32 },
        };
        const packet = try encoder.encode(input, n, start);
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(packet.data, &digest, .{});
        var line: [128]u8 = undefined;
        try testing.expectEqualStrings(lines.next().?, try std.fmt.bufPrint(&line, "P {d} {d} {d} {s}", .{ packet.pts, packet.duration, packet.data.len, &hexOf(16, &digest) }));
    }
    const final = encoder.flush();
    var line: [128]u8 = undefined;
    try testing.expectEqualStrings(lines.next().?, try std.fmt.bufPrint(&line, "F {d} {s}", .{ final.pts, &hexOf(34, &final.streaminfo) }));
}

test "every case encodes as FFmpeg's encoder does (vectors/flacenc.txt)" {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(std.mem.startsWith(u8, line, "C "));
        try checkCase(testing.allocator, line, &lines);
        cases += 1;
    }
    try testing.expectEqual(84, cases);
}

test "FFmpeg's option text sets the encoder's options" {
    var o: AvOptions = .{};
    try options_zig.set(AvOptions, &o, "lpc_type", "cholesky");
    try options_zig.set(AvOptions, &o, "ch_mode", "mid_side");
    try options_zig.set(AvOptions, &o, "prediction_order_method", "8level");
    try options_zig.set(AvOptions, &o, "strict", "experimental");
    try options_zig.set(AvOptions, &o, "compression_level", "8");
    try options_zig.set(AvOptions, &o, "exact_rice_parameters", "1");
    try testing.expectError(error.OutOfRange, options_zig.set(AvOptions, &o, "max_prediction_order", "33"));
    try testing.expectError(error.UnknownOption, options_zig.set(AvOptions, &o, "frame_size", "4096"));
    const resolved = o.toOptions();
    try testing.expectEqual(lpc.Type.cholesky, resolved.lpc_type.?);
    try testing.expectEqual(flac.ChannelMode.mid_side, resolved.ch_mode.?);
    try testing.expectEqual(lpc.OrderMethod.eight_level, resolved.prediction_order_method.?);
    try testing.expectEqual(8, resolved.compression_level.?);
    try testing.expect(resolved.strict_experimental and resolved.exact_rice_parameters);
    try testing.expectEqual(null, resolved.max_prediction_order);
    try testing.expectEqual(null, (AvOptions{}).toOptions().ch_mode);
}

test "frames the encoder refuses, and every allocation failure" {
    const e = try Encoder.init(testing.allocator, .{ .sample_format = .s16, .channels = 2, .sample_rate = 44100, .frame_size = 16 }, .{});
    defer e.deinit();
    const samples: [40]i16 = @splat(3);
    try testing.expectError(error.InvalidFrame, e.encode(.{ .s16 = &samples }, 17, 0));
    try testing.expectError(error.InvalidFrame, e.encode(.{ .s16 = &samples }, 0, 0));
    try testing.expectError(error.InvalidFrame, e.encode(.{ .s16 = samples[0..10] }, 16, 0));
    const wide: [32]i32 = @splat(0);
    try testing.expectError(error.InvalidFrame, e.encode(.{ .s32 = &wide }, 16, 0));
    // A constant block: two constant subframes.
    const packet = try e.encode(.{ .s16 = &samples }, 16, 0);
    try testing.expectEqual(16, packet.duration);
    try testing.expectError(error.InvalidOption, Encoder.init(testing.allocator, .{ .sample_format = .s16, .channels = 1, .sample_rate = 8000 }, .{ .lpc_coeff_precision = 0 }));

    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const enc = try Encoder.init(gpa, .{ .sample_format = .s32, .bits_per_raw_sample = 24, .channels = 3, .sample_rate = 48000, .frame_size = 64 }, .{ .compression_level = 8 });
            defer enc.deinit();
            var input: [64 * 3]i32 = undefined;
            for (&input, 0..) |*s, i| s.* = @intCast((i * 7919 % 1000) << 8);
            _ = try enc.encode(.{ .s32 = &input }, 64, 0);
            _ = enc.flush();
        }
    }.run, .{});
}
