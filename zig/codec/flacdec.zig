// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/flacdec.c (flac_decode_frame, decode_frame, decode_subframe,
// decode_residuals, decode_subframe_fixed and _wide and _33bps,
// decode_subframe_lpc and _33bps, lpc_analyze_remodulate,
// decorrelate_33bps, flac_set_bps, allocate_buffers), flacdsp.c
// (flac_lpc_16_c, flac_lpc_32_c, flac_lpc_33_c, flac_wasted_32_c,
// flac_wasted_33_c), flacdsp_template.c (the decorrelations) and decode.c
// (decode_simple_internal's packet remainders) at the pinned reference
// revision describe the behavior, restated here.
//! The FLAC decoder (TODO.md T26a, T26b), as FFmpeg's decoder decodes a
//! stream to packed samples with its default options: s16 for 4 to 16 bits
//! per sample, s32 for 17 to 32, each sample shifted to the top of its
//! storage. The side channel of 32-bit stereo has 33 bits, which the
//! decoder keeps in 64 bits, as FFmpeg does.
//!
//! A packet is decoded as libavcodec feeds an audio decoder: the decoder
//! reads one frame and reports the bytes it used, and what remains of the
//! packet is decoded again, without a timestamp, until it is used up or
//! fails. So a packet with junk after a frame gives the frame and then an
//! error, as FFmpeg's does. A failure drops the rest of the packet; the
//! next packet decodes normally. The CRC-16 is not checked, FFmpeg's
//! default. A frame with another channel count or rate than the stream's
//! changes them, as FFmpeg's decoder follows such a change; its sample size
//! may not change.
//!
//! Arithmetic follows FFmpeg's C: prediction wraps at 32 bits where the C
//! code uses unsigned or 32-bit sums, uses 64-bit sums where it does, and
//! the output keeps the low bits of each shifted sample.

const std = @import("std");
const bits = @import("bits.zig");
const flac = @import("flac.zig");

pub const DecodeError = error{
    /// FFmpeg's decoder refuses the frame (`AVERROR_INVALIDDATA`).
    InvalidData,
    OutOfMemory,
};

/// A decoded frame's samples, interleaved; borrowed until the next call.
pub const Samples = union(enum) {
    s16: []const i16,
    s32: []const i32,
};

/// A decoded frame, borrowed until the next call on the decoder.
pub const Frame = struct {
    samples: Samples,
    nb_samples: u32,
    channels: u8,
    sample_rate: u32,
    /// The packet's timestamp; null for a packet's remainder.
    pts: ?i64,
};

/// The format a reader opened a stream with, which its decoded frames must
/// keep. The decoder follows a channel or rate change, as FFmpeg's does;
/// the port's decoded readers refuse one (notes.md "FLAC conversion"), so
/// that native and Ogg FLAC apply one policy.
pub const Opened = struct {
    channels: u8,
    sample_rate: u32,
    /// s32 storage (17 to 32 bits per sample); s16 otherwise.
    s32: bool,

    /// Whether `f` has the opened channel count, rate and storage.
    pub fn keeps(o: Opened, f: Frame) bool {
        return f.channels == o.channels and f.sample_rate == o.sample_rate and o.s32 == (f.samples == .s32);
    }
};

/// Why a frame failed, FFmpeg's log message for it.
pub const Problem = enum {
    frame_header,
    bps_missing,
    bps_switch,
    blocksize,
    rate_missing,
    streaminfo,
    subframe_padding,
    wasted_bits,
    coding_type,
    residual_method,
    rice_order,
    predictor_order,
    invalid_residual,
    coeff_precision,
    qlevel,
    overread,
    metadata,
};

/// What the decoder knows of the stream: FFmpeg's FLACStreaminfo.
const Stream = struct {
    /// 0 until a header or frame gives it.
    bps: u8 = 0,
    channels: u8 = 0,
    sample_rate: u32 = 0,
    max_blocksize: u32 = 0,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    stream: Stream = .{},
    got_streaminfo: bool = false,
    /// One buffer per channel of `max_blocksize` samples rounded up to 32
    /// (`channelBufferLength`).
    decoded: [][]i32 = &.{},
    /// The 33-bit side channel of 32-bit stereo, as long as a channel buffer.
    decoded_33: []i64 = &.{},
    output16: []i16 = &.{},
    output32: []i32 = &.{},
    /// FFmpeg's `sample_shift`: to the top of the s16 or s32 storage.
    sample_shift: u5 = 0,
    /// What remains of the packet being decoded, borrowed from the caller.
    pending: []const u8 = &.{},
    pending_pts: ?i64 = null,
    /// The last failure's reason, for diagnostics.
    problem: ?Problem = null,
    blocksize: u32 = 0,
    ch_mode: flac.ChannelMode = .independent,

    /// flac_decode_init: with STREAMINFO as extradata, or without (a
    /// headerless stream), when the first frame gives the parameters.
    pub fn init(gpa: std.mem.Allocator, info: ?flac.StreamInfo) error{ OutOfMemory, InvalidData }!Decoder {
        var d: Decoder = .{ .gpa = gpa };
        if (info) |si| {
            errdefer d.deinit();
            try d.setStreamInfo(si);
        }
        return d;
    }

    pub fn deinit(d: *Decoder) void {
        for (d.decoded) |c| d.gpa.free(c);
        d.gpa.free(d.decoded);
        d.gpa.free(d.decoded_33);
        d.gpa.free(d.output16);
        d.gpa.free(d.output32);
        d.* = undefined;
    }

    /// ff_flac_parse_streaminfo, then allocate_buffers and flac_set_bps.
    fn setStreamInfo(d: *Decoder, si: flac.StreamInfo) error{ OutOfMemory, InvalidData }!void {
        if (si.max_blocksize < flac.min_blocksize or si.bps < 4) return error.InvalidData;
        d.stream = .{ .bps = si.bps, .channels = si.channels, .sample_rate = si.sample_rate, .max_blocksize = si.max_blocksize };
        try d.allocateBuffers(si.channels);
        d.setBps();
        d.got_streaminfo = true;
    }

    fn setBps(d: *Decoder) void {
        d.sample_shift = @intCast(if (d.stream.bps > 16) 32 - @as(u8, d.stream.bps) else 16 - @as(u8, d.stream.bps));
    }

    /// The samples of one channel buffer: `max_blocksize` rounded up to 32,
    /// as `av_samples_get_buffer_size` with alignment 0 sizes FFmpeg's.
    /// Every predictor order (at most 32) fits, so the warm-up samples are
    /// read, in FFmpeg's order, before `decodeResiduals` refuses an order
    /// above the block size.
    fn channelBufferLength(max_blocksize: u32) usize {
        return std.mem.alignForward(usize, @max(max_blocksize, 1), 32);
    }

    /// allocate_buffers: a buffer per channel (`channelBufferLength`), the
    /// 64-bit one for 32-bit stereo, and the output, for `channel_count`.
    /// On failure the previous buffers stay, so the caller commits a new
    /// channel count only after this succeeds.
    fn allocateBuffers(d: *Decoder, channel_count: u8) error{OutOfMemory}!void {
        const gpa = d.gpa;
        const n: usize = d.stream.max_blocksize;
        const len = channelBufferLength(d.stream.max_blocksize);
        const channels: usize = channel_count;
        const decoded = try gpa.alloc([]i32, channels);
        var made: usize = 0;
        errdefer {
            for (decoded[0..made]) |c| gpa.free(c);
            gpa.free(decoded);
        }
        for (decoded) |*c| {
            c.* = try gpa.alloc(i32, len);
            made += 1;
        }
        const wide = if (d.stream.bps == 32 and channels == 2) try gpa.alloc(i64, len) else try gpa.alloc(i64, 0);
        errdefer gpa.free(wide);
        const out16 = try gpa.alloc(i16, n * channels);
        errdefer gpa.free(out16);
        const out32 = try gpa.alloc(i32, n * channels);
        for (d.decoded) |c| gpa.free(c);
        gpa.free(d.decoded);
        gpa.free(d.decoded_33);
        gpa.free(d.output16);
        gpa.free(d.output32);
        d.decoded = decoded;
        d.decoded_33 = wide;
        d.output16 = out16;
        d.output32 = out32;
    }

    /// avcodec_send_packet: `data` is borrowed until `receive` returns null
    /// or an error. The previous packet must be used up.
    pub fn send(d: *Decoder, data: []const u8, pts: ?i64) void {
        std.debug.assert(d.pending.len == 0);
        d.pending = data;
        d.pending_pts = pts;
    }

    /// avcodec_receive_frame: the next frame of the packet, null when it is
    /// used up, or the error that ended it.
    pub fn receive(d: *Decoder) DecodeError!?Frame {
        while (d.pending.len > 0) {
            const pts = d.pending_pts;
            const result = d.decodePacket(d.pending) catch |err| {
                d.pending = &.{};
                return err;
            };
            if (result.consumed >= d.pending.len) {
                d.pending = &.{};
            } else {
                d.pending = d.pending[result.consumed..];
                d.pending_pts = null;
            }
            if (result.frame) {
                const count = @as(usize, d.blocksize) * d.stream.channels;
                return .{
                    .samples = if (d.stream.bps > 16) .{ .s32 = d.output32[0..count] } else .{ .s16 = d.output16[0..count] },
                    .nb_samples = d.blocksize,
                    .channels = d.stream.channels,
                    .sample_rate = d.stream.sample_rate,
                    .pts = pts,
                };
            }
        }
        return null;
    }

    fn fail(d: *Decoder, problem: Problem) DecodeError {
        d.problem = problem;
        return error.InvalidData;
    }

    const Decoded = struct { consumed: usize, frame: bool };

    /// flac_decode_frame.
    fn decodePacket(d: *Decoder, buf: []const u8) DecodeError!Decoded {
        if (buf.len > 5 and std.mem.eql(u8, buf[0..5], "\x7fFLAC")) return .{ .consumed = buf.len, .frame = false };
        if (buf.len > 0 and buf[0] & 0x7f == 4) return .{ .consumed = buf.len, .frame = false }; // VORBIS_COMMENT
        // Smaller than the smallest decodable frame.
        if (buf.len < flac.min_frame_size) return .{ .consumed = buf.len, .frame = false };
        if (std.mem.readInt(u32, buf[0..4], .big) == std.mem.readInt(u32, "fLaC", .big)) {
            // An inline header: its STREAMINFO if none came before, then
            // skipped by its size.
            if (!d.got_streaminfo) try d.inlineStreamInfo(buf);
            return .{ .consumed = try d.metadataSize(buf), .frame = false };
        }
        var r = bits.BitReader.init(buf) catch return d.fail(.overread);
        try d.decodeFrame(&r);
        const bytes_read = r.count() / 8;
        d.decorrelate();
        if (bytes_read > buf.len) return d.fail(.overread);
        return .{ .consumed = bytes_read, .frame = true };
    }

    /// parse_streaminfo: an inline header's first block.
    fn inlineStreamInfo(d: *Decoder, buf: []const u8) DecodeError!void {
        // FFmpeg waits for more data with fewer bytes, which a packet never
        // brings; the size check below then refuses it.
        if (buf.len < flac.streaminfo_size + 8) return;
        if (buf[4] & 0x7f != 0 or std.mem.readInt(u24, buf[5..8], .big) != flac.streaminfo_size) return d.fail(.streaminfo);
        d.setStreamInfo(flac.StreamInfo.parse(buf[8..][0..flac.streaminfo_size])) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidData => d.fail(.streaminfo),
        };
    }

    /// get_metadata_size: the bytes of `fLaC` and its blocks.
    fn metadataSize(d: *Decoder, buf: []const u8) DecodeError!usize {
        var at: usize = 4;
        while (true) {
            if (buf.len - at < 4) return d.fail(.metadata);
            const last = buf[at] & 0x80 != 0;
            const size = std.mem.readInt(u24, buf[at + 1 ..][0..3], .big);
            at += 4;
            if (buf.len - at < size) return d.fail(.metadata);
            at += size;
            if (last) return at;
        }
    }

    /// decode_frame.
    fn decodeFrame(d: *Decoder, r: *bits.BitReader) DecodeError!void {
        var fi = switch (flac.decodeFrameHeader(r)) {
            .ok => |fi| fi,
            .invalid => return d.fail(.frame_header),
        };
        if (d.stream.channels != 0 and fi.channels != d.stream.channels and d.got_streaminfo) {
            try d.allocateBuffers(fi.channels);
        }
        d.stream.channels = fi.channels;
        d.ch_mode = fi.ch_mode;
        if (d.stream.bps == 0 and fi.bps == 0) return d.fail(.bps_missing);
        if (fi.bps == 0) {
            fi.bps = d.stream.bps;
        } else if (d.stream.bps != 0 and fi.bps != d.stream.bps) {
            return d.fail(.bps_switch);
        }
        if (d.stream.bps == 0) {
            d.stream.bps = fi.bps;
            d.setBps();
        }
        if (d.stream.max_blocksize == 0) d.stream.max_blocksize = flac.max_blocksize;
        if (fi.blocksize > d.stream.max_blocksize) return d.fail(.blocksize);
        d.blocksize = fi.blocksize;
        if (d.stream.sample_rate == 0 and fi.sample_rate == 0) return d.fail(.rate_missing);
        if (fi.sample_rate == 0) fi.sample_rate = d.stream.sample_rate;
        d.stream.sample_rate = fi.sample_rate;
        if (!d.got_streaminfo) {
            try d.allocateBuffers(d.stream.channels);
            d.got_streaminfo = true;
        }
        for (0..d.stream.channels) |ch| try d.decodeSubframe(r, ch);
        r.alignByte();
        r.skip(16); // the CRC-16, unchecked
    }

    /// decode_subframe.
    fn decodeSubframe(d: *Decoder, r: *bits.BitReader, channel: usize) DecodeError!void {
        // The whole channel buffer: warm-up samples may run past the block
        // before the predictor order is checked, as FFmpeg's do.
        const decoded = d.decoded[channel];
        const n = d.blocksize;
        var bps: u7 = @intCast(d.stream.bps);
        if (channel == 0) {
            if (d.ch_mode == .right_side) bps += 1;
        } else {
            if (d.ch_mode == .left_side or d.ch_mode == .mid_side) bps += 1;
        }
        if (r.bit() != 0) return d.fail(.subframe_padding);
        const subframe_type = r.bits(6);
        var wasted: u7 = 0;
        if (r.bit() != 0) {
            const left = r.left();
            if (left <= 0 or
                (left < bps and r.peek(@intCast(left)) == 0) or
                r.peek(@intCast(bps - 1)) == 0) return d.fail(.wasted_bits);
            wasted = @intCast(1 + r.unary(1, r.left()));
            bps -= wasted;
        }
        // Empty unless the stream is 32-bit stereo, the only one with a
        // 33-bit side channel: side modes are stereo, and allocateBuffers
        // runs for every new channel count with the stream's fixed bps.
        const wide = d.decoded_33;
        std.debug.assert(wasted + bps < 33 or wide.len >= n);
        switch (subframe_type) {
            0 => if (bps < 33) @memset(decoded[0..n], r.signed(@intCast(bps))) else @memset(wide[0..n], r.signed64(33)),
            1 => if (bps < 33) {
                for (decoded[0..n]) |*s| s.* = r.signed(@intCast(bps));
            } else {
                for (wide[0..n]) |*s| s.* = r.signed64(33);
            },
            8...12 => {
                const order: u32 = subframe_type & ~@as(u32, 0x8);
                if (bps < 33) try d.decodeFixed(r, decoded, order, @intCast(bps)) else try d.decodeFixed33(r, wide, decoded, order);
            },
            32...63 => {
                const order: u32 = (subframe_type & ~@as(u32, 0x20)) + 1;
                if (bps < 33) try d.decodeLpc(r, decoded, order, @intCast(bps)) else try d.decodeLpc33(r, wide, decoded, order);
            },
            else => return d.fail(.coding_type),
        }
        if (wasted > 0) {
            if (wasted + bps == 33) {
                // flac_wasted_33_c: into the 64-bit buffer.
                for (wide[0..n], decoded[0..n]) |*w, s| w.* = @bitCast(@as(u64, @bitCast(@as(i64, s))) << @intCast(wasted));
            } else if (wasted < 32) {
                for (decoded[0..n]) |*s| s.* = @bitCast(@as(u32, @bitCast(s.*)) << @intCast(wasted));
            }
        }
    }

    /// decode_residuals: the residual after `pred_order` warm-up samples,
    /// into `decoded[pred_order..blocksize]` once the order is checked.
    fn decodeResiduals(d: *Decoder, r: *bits.BitReader, decoded: []i32, pred_order: u32) DecodeError!void {
        const method_type = r.bits(2);
        const rice_order: u5 = @intCast(r.bits(4));
        const samples = d.blocksize >> rice_order;
        const rice_bits: u6 = @intCast(4 + method_type);
        const rice_esc = (@as(u32, 1) << @intCast(rice_bits)) - 1;
        if (method_type > 1) return d.fail(.residual_method);
        if (samples << rice_order != d.blocksize) return d.fail(.rice_order);
        if (pred_order > samples) return d.fail(.predictor_order);
        var i: u32 = pred_order;
        var at: usize = pred_order;
        for (0..@as(u32, 1) << rice_order) |_| {
            const tmp = r.bits(rice_bits);
            if (tmp == rice_esc) {
                const raw: u6 = @intCast(r.bits(5));
                while (i < samples) : (i += 1) {
                    decoded[at] = r.signed(raw);
                    at += 1;
                }
            } else {
                const k: u5 = @intCast(tmp);
                const max: i32 = std.math.maxInt(i32);
                const real_limit: i32 = if (k > 1) (max >> (k - 1)) + 2 else max;
                while (i < samples) : (i += 1) {
                    const v = r.riceFlac(k, real_limit, 1);
                    if (v == std.math.minInt(i32)) return d.fail(.invalid_residual);
                    decoded[at] = v;
                    at += 1;
                }
            }
            i = 0;
        }
    }

    /// decode_subframe_fixed (and _wide, which gives the same 32-bit
    /// results): unsigned, wrapping recurrences, as FFmpeg's. `decoded` is
    /// the whole channel buffer.
    fn decodeFixed(d: *Decoder, r: *bits.BitReader, decoded: []i32, order: u32, bps: u6) DecodeError!void {
        for (decoded[0..order]) |*s| s.* = r.signed(bps);
        try d.decodeResiduals(r, decoded, order);
        const u = struct {
            fn of(v: i32) u32 {
                return @bitCast(v);
            }
        }.of;
        var a: u32 = 0;
        var b: u32 = 0;
        var c: u32 = 0;
        var e: u32 = 0;
        if (order > 0) a = u(decoded[order - 1]);
        if (order > 1) b = a -% u(decoded[order - 2]);
        if (order > 2) c = b -% u(decoded[order - 2]) +% u(decoded[order - 3]);
        if (order > 3) e = c -% u(decoded[order - 2]) +% 2 *% u(decoded[order - 3]) -% u(decoded[order - 4]);
        for (decoded[order..d.blocksize]) |*s| {
            switch (order) {
                0 => {},
                1 => a +%= u(s.*),
                2 => {
                    b +%= u(s.*);
                    a +%= b;
                },
                3 => {
                    c +%= u(s.*);
                    b +%= c;
                    a +%= b;
                },
                4 => {
                    e +%= u(s.*);
                    c +%= e;
                    b +%= c;
                    a +%= b;
                },
                else => unreachable,
            }
            if (order > 0) s.* = @bitCast(a);
        }
    }

    /// decode_subframe_fixed_33bps: 33-bit warm-up samples, 64-bit
    /// wrapping prediction from the 32-bit residual. `wide` and `residual`
    /// are whole buffers.
    fn decodeFixed33(d: *Decoder, r: *bits.BitReader, wide: []i64, residual: []i32, order: u32) DecodeError!void {
        for (wide[0..order]) |*s| s.* = r.signed64(33);
        try d.decodeResiduals(r, residual, order);
        const u = struct {
            fn of(v: i64) u64 {
                return @bitCast(v);
            }
        }.of;
        for (order..d.blocksize) |i| {
            const res = u(residual[i]);
            const v: u64 = switch (order) {
                0 => res,
                1 => res +% u(wide[i - 1]),
                2 => res +% 2 *% u(wide[i - 1]) -% u(wide[i - 2]),
                3 => res +% 3 *% u(wide[i - 1]) -% 3 *% u(wide[i - 2]) +% u(wide[i - 3]),
                4 => res +% 4 *% u(wide[i - 1]) -% 6 *% u(wide[i - 2]) +% 4 *% u(wide[i - 3]) -% u(wide[i - 4]),
                else => unreachable,
            };
            wide[i] = @bitCast(v);
        }
    }

    /// The precision, shift and coefficients of an LPC subframe.
    fn lpcParameters(d: *Decoder, r: *bits.BitReader, order: u32, coeffs: *[32]i32) DecodeError!struct { prec: u6, qlevel: u5 } {
        const coeff_prec: u6 = @intCast(r.bits(4) + 1);
        if (coeff_prec == 16) return d.fail(.coeff_precision);
        const qlevel_signed = r.signed(5);
        if (qlevel_signed < 0) return d.fail(.qlevel);
        for (0..order) |i| coeffs[order - i - 1] = r.signed(coeff_prec);
        return .{ .prec = coeff_prec, .qlevel = @intCast(qlevel_signed) };
    }

    /// decode_subframe_lpc, without FFmpeg's `use_buggy_lpc` emulation.
    /// `decoded` is the whole channel buffer.
    fn decodeLpc(d: *Decoder, r: *bits.BitReader, decoded: []i32, order: u32, bps: u6) DecodeError!void {
        for (decoded[0..order]) |*s| s.* = r.signed(bps);
        var coeffs: [32]i32 = undefined;
        const p = try d.lpcParameters(r, order, &coeffs);
        try d.decodeResiduals(r, decoded, order);
        const block = decoded[0..d.blocksize];
        const log2_order: u32 = std.math.log2_int(u32, order);
        if (bps <= 16 and bps + p.prec + log2_order <= 32) {
            lpc16(block, coeffs[0..order], p.qlevel);
        } else {
            lpc32(block, coeffs[0..order], p.qlevel);
            if (d.stream.bps <= 16) lpcAnalyzeRemodulate(block, coeffs[0..order], p.qlevel, bps);
        }
    }

    /// decode_subframe_lpc_33bps with flac_lpc_33_c. `wide` and `residual`
    /// are whole buffers.
    fn decodeLpc33(d: *Decoder, r: *bits.BitReader, wide: []i64, residual: []i32, order: u32) DecodeError!void {
        for (wide[0..order]) |*s| s.* = r.signed64(33);
        var coeffs: [32]i32 = undefined;
        const p = try d.lpcParameters(r, order, &coeffs);
        try d.decodeResiduals(r, residual, order);
        for (order..d.blocksize) |i| {
            var sum: i64 = 0;
            for (coeffs[0..order], wide[i - order .. i]) |c, s| sum +%= @as(i64, c) *% s;
            wide[i] = @bitCast(@as(u64, @bitCast(@as(i64, residual[i]))) +% @as(u64, @bitCast(sum >> p.qlevel)));
        }
    }

    /// decorrelate_33bps for 32-bit stereo, then the decorrelations into the
    /// shifted s16 or s32 output.
    fn decorrelate(d: *Decoder) void {
        const n = d.blocksize;
        const channels = d.stream.channels;
        var mode = d.ch_mode;
        if (d.stream.bps == 32 and mode != .independent) {
            const left = d.decoded[0];
            const right = d.decoded[1];
            for (0..n) |i| {
                const w: u64 = @bitCast(d.decoded_33[i]);
                switch (mode) {
                    .left_side => right[i] = @truncate(@as(i64, @bitCast(@as(u64, @bitCast(@as(i64, left[i]))) -% w))),
                    .right_side => left[i] = @truncate(@as(i64, @bitCast(@as(u64, @bitCast(@as(i64, right[i]))) +% w))),
                    .mid_side => {
                        var a: u64 = @bitCast(@as(i64, left[i]));
                        a -%= @bitCast(d.decoded_33[i] >> 1);
                        left[i] = @truncate(@as(i64, @bitCast(a +% w)));
                        right[i] = @truncate(@as(i64, @bitCast(a)));
                    },
                    .independent => unreachable,
                }
            }
            mode = .independent;
        }
        const shift = d.sample_shift;
        if (d.stream.bps > 16) {
            decorrelateInto(i32, d.output32[0 .. @as(usize, n) * channels], d.decoded, channels, n, mode, shift);
        } else {
            decorrelateInto(i16, d.output16[0 .. @as(usize, n) * channels], d.decoded, channels, n, mode, shift);
        }
    }
};

/// flacdsp_template.c's packed decorrelations: `(unsigned)sample << shift`,
/// truncated to the output's width.
fn decorrelateInto(comptime T: type, out: []T, decoded: []const []i32, channels: usize, n: u32, mode: flac.ChannelMode, shift: u5) void {
    const U = @Int(.unsigned, @bitSizeOf(T));
    const store = struct {
        fn of(v: u32, s: u5) T {
            return @bitCast(@as(U, @truncate(v << s)));
        }
    }.of;
    switch (mode) {
        .independent => for (0..n) |i| {
            for (0..channels) |ch| out[i * channels + ch] = store(@bitCast(decoded[ch][i]), shift);
        },
        .left_side => for (0..n) |i| {
            const a: u32 = @bitCast(decoded[0][i]);
            const b: u32 = @bitCast(decoded[1][i]);
            out[2 * i] = store(a, shift);
            out[2 * i + 1] = store(a -% b, shift);
        },
        .right_side => for (0..n) |i| {
            const a: u32 = @bitCast(decoded[0][i]);
            const b: u32 = @bitCast(decoded[1][i]);
            out[2 * i] = store(a +% b, shift);
            out[2 * i + 1] = store(b, shift);
        },
        .mid_side => for (0..n) |i| {
            var a: u32 = @bitCast(decoded[0][i]);
            const b: i32 = decoded[1][i];
            a -%= @bitCast(b >> 1);
            out[2 * i] = store(a +% @as(u32, @bitCast(b)), shift);
            out[2 * i + 1] = store(a, shift);
        },
    }
}

/// flac_lpc_16_c: 32-bit wrapping sums. FFmpeg computes two samples at a
/// time; wrapping addition makes the order irrelevant.
fn lpc16(decoded: []i32, coeffs: []const i32, qlevel: u5) void {
    const order = coeffs.len;
    for (order..decoded.len) |i| {
        var sum: u32 = 0;
        for (coeffs, decoded[i - order .. i]) |c, s| sum +%= @as(u32, @bitCast(c)) *% @as(u32, @bitCast(s));
        const shifted: i32 = @as(i32, @bitCast(sum)) >> qlevel;
        decoded[i] = decoded[i] +% shifted;
    }
}

/// flac_lpc_32_c: 64-bit sums, the result wrapped to 32 bits.
fn lpc32(decoded: []i32, coeffs: []const i32, qlevel: u5) void {
    const order = coeffs.len;
    for (order..decoded.len) |i| {
        var sum: i64 = 0;
        for (coeffs, decoded[i - order .. i]) |c, s| sum +%= @as(i64, c) * s;
        const wide: i64 = @as(i64, decoded[i]) +% (sum >> qlevel);
        decoded[i] = @truncate(wide);
    }
}

/// lpc_analyze_remodulate: when the 64-bit prediction left a sample outside
/// `bps` bits, FFmpeg undoes it and predicts again with 32-bit wrapping, as
/// the encoder that made the stream did.
fn lpcAnalyzeRemodulate(decoded: []i32, coeffs: []const i32, qlevel: u5, bps: u6) void {
    const order = coeffs.len;
    const ebps: u32 = @as(u32, 1) << @intCast(bps - 1);
    var sigma: u32 = 0;
    for (decoded[order..]) |s| sigma |= @as(u32, @bitCast(s)) +% ebps;
    if (sigma < 2 *% ebps) return;
    var i = decoded.len;
    while (i > order) {
        i -= 1;
        var p: i64 = 0;
        for (coeffs, decoded[i - order .. i]) |c, s| p +%= @as(i64, c) * s;
        decoded[i] = @bitCast(@as(u32, @bitCast(decoded[i])) -% @as(u32, @truncate(@as(u64, @bitCast(p >> qlevel)))));
    }
    for (order..decoded.len) |at| {
        var p: u32 = 0;
        for (coeffs, decoded[at - order .. at]) |c, s| p +%= @as(u32, @bitCast(c)) *% @as(u32, @bitCast(s));
        const shifted: i32 = @as(i32, @bitCast(p)) >> qlevel;
        decoded[at] = decoded[at] +% shifted;
    }
}

const testing = std.testing;

/// MSB-first bits for hand-made test frames.
const TestBits = struct {
    bytes: [256]u8 = @splat(0),
    count: usize = 0,

    fn put(t: *TestBits, n: u6, value: u64) void {
        var i = n;
        while (i > 0) {
            i -= 1;
            const b: u8 = @intCast((value >> i) & 1);
            t.bytes[t.count / 8] |= b << @intCast(7 - t.count % 8);
            t.count += 1;
        }
    }

    fn signed(t: *TestBits, n: u6, value: i64) void {
        const mask = (@as(u64, 1) << n) - 1;
        t.put(n, @as(u64, @bitCast(value)) & mask);
    }

    /// A mono 16-bit frame header of `blocksize` (8-bit size code) at 44.1
    /// kHz, frame 0, with its CRC-8.
    fn header(t: *TestBits, blocksize: u32, channel_code: u4, bps_code: u3, var_size: bool) void {
        t.put(15, 0x7ffc);
        t.put(1, @intFromBool(var_size));
        t.put(4, 6);
        t.put(4, 9);
        t.put(4, channel_code);
        t.put(3, bps_code);
        t.put(1, 0);
        t.put(8, 0);
        t.put(8, blocksize - 1);
        t.put(8, bits.Crc8.hash(t.bytes[0 .. t.count / 8]));
    }

    /// Pads to a byte, adds the CRC-16, and returns the frame.
    fn finish(t: *TestBits) []const u8 {
        t.put(@intCast((8 - t.count % 8) % 8), 0);
        t.put(16, bits.Crc16.hash(t.bytes[0 .. t.count / 8]));
        return t.bytes[0 .. t.count / 8];
    }
};

const test_info: flac.StreamInfo = .{
    .min_blocksize = 16,
    .max_blocksize = 192,
    .min_framesize = 0,
    .max_framesize = 0,
    .sample_rate = 44100,
    .channels = 1,
    .bps = 16,
    .samples = 0,
    .md5 = @splat(0),
};

fn decodeOne(info: flac.StreamInfo, frame: []const u8) !Decoder.Decoded {
    var d = try Decoder.init(testing.allocator, info);
    defer d.deinit();
    return d.decodePacket(frame);
}

fn expectProblem(problem: Problem, frame: []const u8) !void {
    try expectProblemIn(test_info, problem, frame);
}

fn expectProblemIn(info: flac.StreamInfo, problem: Problem, frame: []const u8) !void {
    var d = try Decoder.init(testing.allocator, info);
    defer d.deinit();
    try testing.expectError(error.InvalidData, d.decodePacket(frame));
    try testing.expectEqual(problem, d.problem.?);
}

test "a constant frame decodes, and a verbatim one with wasted bits" {
    var t: TestBits = .{};
    t.header(16, 0, 4, false);
    t.put(1, 0);
    t.put(6, 0);
    t.put(1, 0);
    t.signed(16, -1234);
    const frame = t.finish();
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    d.send(frame, 7);
    const got = (try d.receive()).?;
    try testing.expectEqual(16, got.nb_samples);
    try testing.expectEqual(7, got.pts);
    for (got.samples.s16) |s| try testing.expectEqual(-1234, s);
    try testing.expectEqual(null, try d.receive());

    var w: TestBits = .{};
    w.header(16, 0, 4, false);
    w.put(1, 0);
    w.put(6, 1);
    w.put(1, 1);
    w.put(3, 0b001); // three wasted bits: unary 2, then the 1
    for (0..16) |i| {
        const value: i64 = @intCast(i);
        w.signed(13, value - 8);
    }
    const verbatim = w.finish();
    d.send(verbatim, null);
    const v = (try d.receive()).?;
    for (v.samples.s16, 0..) |s, i| {
        const index: i16 = @intCast(i);
        try testing.expectEqual((index - 8) * 8, s);
    }
}

test "two frames in one packet: the second has no timestamp" {
    var t: TestBits = .{};
    t.header(16, 0, 4, false);
    t.put(1, 0);
    t.put(6, 0);
    t.put(1, 0);
    t.signed(16, 5);
    const one = t.finish();
    var both: [64]u8 = undefined;
    @memcpy(both[0..one.len], one);
    @memcpy(both[one.len..][0..one.len], one);
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    d.send(both[0 .. 2 * one.len], 100);
    try testing.expectEqual(100, (try d.receive()).?.pts);
    try testing.expectEqual(null, (try d.receive()).?.pts);
    try testing.expectEqual(null, try d.receive());
}

test "packets the decoder skips" {
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    for ([_][]const u8{ "\x7fFLAC\x01\x00", "\x84abcdefghijkl", "\xff\xf8\x00", "fLaC\x80\x00\x00\x02ab" }) |p| {
        d.send(p, 0);
        try testing.expectEqual(null, try d.receive());
    }
    // An inline header whose blocks run past the packet is refused.
    d.send("fLaC\x80\x00\x00\x09abcdef", 0);
    try testing.expectError(error.InvalidData, d.receive());
    try testing.expectEqual(Problem.metadata, d.problem.?);
}

test "every refusal of a frame" {
    {
        var t: TestBits = .{};
        t.put(16, 0xfff8);
        t.put(48, 0);
        try expectProblem(.frame_header, t.finish());
    }
    {
        // A 12-bit header in a 16-bit stream (padded past the 10 bytes the
        // decoder needs to try a frame).
        var t: TestBits = .{};
        t.header(16, 0, 2, false);
        t.put(16, 0);
        try expectProblem(.bps_switch, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(200, 0, 4, false);
        t.put(16, 0);
        try expectProblem(.blocksize, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 1);
        try expectProblem(.subframe_padding, t.finish());
    }
    {
        // The wasted-bits flag with no 1 bit in reach.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 0);
        t.put(1, 1);
        t.put(24, 0);
        try expectProblem(.wasted_bits, t.finish());
    }
    for ([_]u6{ 2, 7, 13, 31 }) |reserved| {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, reserved);
        t.put(1, 0);
        try expectProblem(.coding_type, t.finish());
    }
    {
        // Fixed order 1: a warm-up sample, then residual method 2.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 9);
        t.put(1, 0);
        t.signed(16, 0);
        t.put(2, 2);
        try expectProblem(.residual_method, t.finish());
    }
    {
        // 24 samples do not split into 16 partitions.
        var t: TestBits = .{};
        t.header(24, 0, 4, false);
        t.put(1, 0);
        t.put(6, 8);
        t.put(1, 0);
        t.put(2, 0);
        t.put(4, 4);
        try expectProblem(.rice_order, t.finish());
    }
    {
        // Order 4 with partitions of 2 samples.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 12);
        t.put(1, 0);
        for (0..4) |_| t.signed(16, 0);
        t.put(2, 0);
        t.put(4, 3);
        try expectProblem(.predictor_order, t.finish());
    }
    {
        // A Rice quotient that runs past the frame.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 8);
        t.put(1, 0);
        t.put(2, 0);
        t.put(4, 0);
        t.put(4, 0);
        t.put(40, 0);
        try expectProblem(.invalid_residual, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 32);
        t.put(1, 0);
        t.signed(16, 0);
        t.put(4, 15);
        try expectProblem(.coeff_precision, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 32);
        t.put(1, 0);
        t.signed(16, 0);
        t.put(4, 11);
        t.signed(5, -1);
        try expectProblem(.qlevel, t.finish());
    }
    {
        // Verbatim samples cut short: the reader runs past the packet.
        var t: TestBits = .{};
        t.header(16, 0, 4, false);
        t.put(1, 0);
        t.put(6, 1);
        t.put(1, 0);
        for (0..4) |_| t.signed(16, 1);
        const whole = t.finish();
        try expectProblem(.overread, whole[0 .. whole.len - 2]);
    }
}

/// An LPC subframe of order 32 at a 1-sample block: the warm-up samples,
/// one-bit coefficients, then a residual header whose partition holds a
/// single sample.
fn putLpc32(t: *TestBits, bps: u6) void {
    t.put(1, 0);
    t.put(6, 63);
    t.put(1, 0);
    for (0..32) |_| t.signed(bps, -1);
    t.put(4, 0); // precision 1
    t.put(5, 0); // shift 0
    t.put(32, 0); // the coefficients
    t.put(2, 0);
    t.put(4, 0);
}

/// A fixed subframe of order 4 at a 2-sample block.
fn putFixed4(t: *TestBits, bps: u6) void {
    t.put(1, 0);
    t.put(6, 12);
    t.put(1, 0);
    for (0..4) |_| t.signed(bps, 3);
    t.put(2, 0);
    t.put(4, 0);
}

test "a predictor order above the block size is refused after its warm-up samples" {
    // The smallest buffers STREAMINFO allows: 16 samples, rounded up to 32
    // as FFmpeg's are, so even order 32 reads its warm-up samples in bounds
    // before decode_residuals refuses the order.
    var info = test_info;
    info.max_blocksize = flac.min_blocksize;
    {
        var t: TestBits = .{};
        t.header(1, 0, 4, false);
        putLpc32(&t, 16);
        try expectProblemIn(info, .predictor_order, t.finish());
    }
    {
        var t: TestBits = .{};
        t.header(2, 0, 4, false);
        putFixed4(&t, 16);
        try expectProblemIn(info, .predictor_order, t.finish());
    }
    // The 33-bit side channel of 32-bit left/side stereo, whose warm-up
    // samples go to the 64-bit buffer.
    info.bps = 32;
    info.channels = 2;
    for ([_]u32{ 1, 2 }, [_]*const fn (*TestBits, u6) void{ putLpc32, putFixed4 }) |blocksize, putSide| {
        var t: TestBits = .{};
        t.header(blocksize, 8, 7, false);
        t.put(1, 0);
        t.put(6, 0);
        t.put(1, 0);
        t.signed(32, 5); // the left channel, constant
        putSide(&t, 33);
        try expectProblemIn(info, .predictor_order, t.finish());
    }
}

test "a frame that changes the channels or blocking decodes, as FFmpeg's does" {
    var d = try Decoder.init(testing.allocator, test_info);
    defer d.deinit();
    {
        // Stereo in a mono stream: two constant subframes.
        var t: TestBits = .{};
        t.header(16, 1, 4, false);
        for (0..2) |_| {
            t.put(1, 0);
            t.put(6, 0);
            t.put(1, 0);
            t.signed(16, 7);
        }
        d.send(t.finish(), 0);
        const frame = (try d.receive()).?;
        try testing.expectEqual(2, frame.channels);
        try testing.expectEqual(32, frame.samples.s16.len);
    }
    {
        // A variable-blocking frame.
        var t: TestBits = .{};
        t.header(16, 0, 4, true);
        t.put(1, 0);
        t.put(6, 0);
        t.put(1, 0);
        t.signed(16, 7);
        d.send(t.finish(), 0);
        try testing.expectEqual(16, (try d.receive()).?.nb_samples);
    }
}

test "STREAMINFO the decoder refuses, and output above 16 bits" {
    var info = test_info;
    info.bps = 3;
    try testing.expectError(error.InvalidData, Decoder.init(testing.allocator, info));
    info.bps = 24;
    var d = try Decoder.init(testing.allocator, info);
    defer d.deinit();
    // A 24-bit constant frame (code 6): s32, shifted by 8.
    var t: TestBits = .{};
    t.header(16, 0, 6, false);
    t.put(1, 0);
    t.put(6, 0);
    t.put(1, 0);
    t.signed(24, -3);
    d.send(t.finish(), 0);
    const frame = (try d.receive()).?;
    for (frame.samples.s32) |s| try testing.expectEqual(-3 * 256, s);
}

test "allocation failures leave nothing behind" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var info = test_info;
            info.channels = 3;
            var d = try Decoder.init(gpa, info);
            d.deinit();
        }
    }.run, .{});
}

test "a channel change whose buffers fail to allocate keeps the old count" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var d = try Decoder.init(failing.allocator(), test_info);
    defer d.deinit();
    // Stereo in the mono stream: two constant subframes.
    var t: TestBits = .{};
    t.header(16, 1, 4, false);
    for (0..2) |_| {
        t.put(1, 0);
        t.put(6, 0);
        t.put(1, 0);
        t.signed(16, 7);
    }
    const stereo = t.finish();
    failing.fail_index = failing.alloc_index;
    d.send(stereo, 0);
    try testing.expectError(error.OutOfMemory, d.receive());
    try testing.expectEqual(1, d.stream.channels);
    // The same change again finds the count unchanged, so it allocates
    // the stereo buffers before decoding into them.
    failing.fail_index = std.math.maxInt(usize);
    d.send(stereo, 0);
    try testing.expectEqual(2, (try d.receive()).?.channels);
}

test "LPC prediction: the 32-bit path wraps, the 64-bit path remodulates" {
    // lpc16 with coefficients 2 and -1 and no shift is a second-order
    // fixed predictor.
    var decoded = [_]i32{ 10, 20, 0, 0, 0 };
    lpc16(&decoded, &.{ -1, 2 }, 0);
    try testing.expectEqualSlices(i32, &.{ 10, 20, 30, 40, 50 }, &decoded);
    // Within `bps` bits the remodulation leaves the 64-bit result alone.
    var wide = [_]i32{ 100, -100, 7, 7 };
    lpc32(&wide, &.{ 1, 1 }, 1);
    const before = wide;
    lpcAnalyzeRemodulate(&wide, &.{ 1, 1 }, 1, 17);
    try testing.expectEqualSlices(i32, &before, &wide);
    // Outside them, the samples are predicted again with 32-bit wrapping,
    // which differs once the sums overflow.
    var big = [_]i32{ 0x7fff_0000, 0x7fff_0000, 0, 0 };
    var big32 = big;
    lpc32(&big, &.{ 1, 1 }, 0);
    lpc16(&big32, &.{ 1, 1 }, 0);
    lpcAnalyzeRemodulate(&big, &.{ 1, 1 }, 0, 17);
    try testing.expectEqualSlices(i32, &big32, &big);
}
