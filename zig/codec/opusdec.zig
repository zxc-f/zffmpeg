// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/opus/dec.c (opus_decode_packet,
// opus_decode_subpacket, opus_decode_frame, opus_decode_init) and parse.c
// (ff_opus_parse_extradata) at the pinned reference revision.
// Copyright (c) 2012 Andrew D'Addesio
// Copyright (c) 2013-2014 Mozilla Corporation
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's Opus decoder (TODO.md T28a): the OpusHead's channels, gain and
//! channel mapping, then each packet split into its streams (self-delimited
//! but the last) and their frames, each frame decoded by CELT
//! (codec/celt.zig), the decoded channels mapped, copied or silenced into
//! the output, and the head's gain applied. Output is planar float at
//! 48 kHz, as FFmpeg's.
//!
//! SILK and hybrid frames (T28b, T28c) are `error.UnsupportedMode`: FFmpeg
//! decodes them, so the port stops rather than differ. A frame CELT
//! refuses is silence, as FFmpeg makes it.

const std = @import("std");
const opus = @import("opus.zig");
const celt = @import("celt.zig");
const tab = @import("celt_tab.zig");
const opus_rc = @import("opus_rc.zig");
const float_dsp = @import("float_dsp.zig");
const vorbis_data = @import("vorbis_data.zig");
const channel_layout = @import("../core/channel_layout.zig");
const libm = @import("../core/libm.zig");
const silk = @import("silk.zig");
const resample = @import("../resample/resample.zig");

const Resampler = resample.Engine(.fltp);

pub const sample_rate = 48000;
/// The most samples a packet decodes to (120 ms).
pub const max_frame = opus.max_packet_duration;
/// The most samples a packet's frame holds: its duration and the
/// resampler's delayed samples (opus_decode_packet's
/// `coded_samples + delayed_samples`), with room to spare.
pub const max_output = max_frame + 1024;

pub const HeadError = error{
    /// FFmpeg's AVERROR_INVALIDDATA: a short head, no channels, counts or
    /// maps out of range.
    InvalidData,
    /// FFmpeg's AVERROR_PATCHWELCOME (a version past 15, an unknown
    /// mapping family), or a layout the port does not represent (mapping
    /// family 2, ambisonics).
    UnsupportedFormat,
};

pub const DecodeError = error{
    /// FFmpeg's AVERROR_INVALIDDATA for the packet: it does not parse, or a
    /// stream's sample count differs from the first's.
    InvalidData,
    /// A hybrid frame, or a SILK frame in a multistream packet, whose
    /// streams' delays differ (T28c).
    UnsupportedMode,
    OutOfMemory,
};

/// `ChannelMap`: where an output channel's samples come from.
pub const ChannelMap = struct {
    stream: u8 = 0,
    channel: u1 = 0,
    /// The earlier output channel this one copies, when a decoded channel
    /// feeds several.
    copy: ?u8 = null,
    silence: bool = false,
};

/// The OpusHead as ff_opus_parse_extradata reads it.
pub const Head = struct {
    channels: u8,
    /// The pre-skip, FFmpeg's `avctx->delay`.
    pre_skip: u16,
    gain_i: i16,
    family: u8,
    streams: u8,
    stereo_streams: u8,
    maps: [255]ChannelMap,
    layout: channel_layout.Layout,

    pub fn parse(extradata: []const u8) HeadError!Head {
        if (extradata.len < 19) return error.InvalidData;
        const version = extradata[8];
        if (version > 15) return error.UnsupportedFormat;
        const channels = extradata[9];
        if (channels == 0) return error.InvalidData;
        var head: Head = .{
            .channels = channels,
            .pre_skip = std.mem.readInt(u16, extradata[10..12], .little),
            .gain_i = std.mem.readInt(i16, extradata[16..18], .little),
            .family = extradata[18],
            .streams = 1,
            .stereo_streams = 0,
            .maps = @splat(.{}),
            .layout = undefined,
        };
        const default_map = [2]u8{ 0, 1 };
        var map: []const u8 = undefined;
        var vorbis_order = false;
        switch (head.family) {
            0 => {
                if (channels > 2) return error.InvalidData;
                head.layout = if (channels == 1) .{ .native = mono } else .{ .native = stereo };
                head.stereo_streams = channels - 1;
                map = &default_map;
            },
            1, 2, 255 => {
                if (extradata.len < 21 + @as(usize, channels)) return error.InvalidData;
                head.streams = extradata[19];
                head.stereo_streams = extradata[20];
                if (head.streams == 0 or head.stereo_streams > head.streams or
                    @as(u32, head.streams) + head.stereo_streams > 255) return error.InvalidData;
                switch (head.family) {
                    1 => {
                        if (channels > 8) return error.InvalidData;
                        head.layout = @import("vorbis.zig").channelLayout(channels);
                        vorbis_order = true;
                    },
                    // Ambisonic orders are not represented here.
                    2 => return error.UnsupportedFormat,
                    else => head.layout = .{ .unspecified = channels },
                }
                map = extradata[21..][0..channels];
            },
            else => return error.UnsupportedFormat,
        }
        for (0..channels) |i| {
            const reorder = if (vorbis_order) vorbis_data.channel_layout_offsets[channels - 1][i] else i;
            const idx = map[reorder];
            if (idx == 255) {
                head.maps[i] = .{ .silence = true };
                continue;
            }
            if (idx >= @as(u32, head.streams) + head.stereo_streams) return error.InvalidData;
            var m: ChannelMap = .{};
            for (0..i) |j| {
                const other = if (vorbis_order) vorbis_data.channel_layout_offsets[channels - 1][j] else j;
                if (map[other] == idx) {
                    m.copy = @intCast(j);
                    break;
                }
            }
            if (idx < 2 * @as(u32, head.stereo_streams)) {
                m.stream = idx / 2;
                m.channel = @intCast(idx & 1);
            } else {
                m.stream = idx - head.stereo_streams;
                m.channel = 0;
            }
            head.maps[i] = m;
        }
        return head;
    }
};

const mono = 0x4; // AV_CH_FRONT_CENTER
const stereo = 0x3; // AV_CH_FRONT_LEFT | AV_CH_FRONT_RIGHT

/// dec.c's silk_frame_duration_ms: a SILK configuration's frame length.
const silk_frame_duration_ms = [16]u32{ 10, 20, 40, 60, 10, 20, 40, 60, 10, 20, 40, 60, 10, 20, 10, 20 };

/// dec.c's silk_resample_delay: the silence fed to a new resampler, by
/// bandwidth.
const silk_resample_delay = [5]i32{ 4, 8, 11, 11, 11 };

/// get_silk_samplerate.
fn silkSamplerate(config: u5) u32 {
    return if (config < 4) 8000 else if (config < 8) 12000 else 16000;
}

/// One of the packet's streams (`OpusStreamContext`): its SILK and CELT
/// decoders, the resampler from the SILK rate and its delayed samples,
/// and the stream's output for the packet.
const Stream = struct {
    output_channels: u32,
    celt: *celt.Decoder,
    silk: silk.Decoder,
    /// libswresample, initialized at `swr_rate` while present.
    swr: ?Resampler = null,
    swr_rate: u32 = 0,
    silk_samplerate: u32 = 0,
    /// Samples the resampler still owes.
    delayed_samples: u32 = 0,
    /// The redundancy frame's fade still to apply at the next output.
    redundancy_idx: u32 = 0,
    packet: opus.Packet = undefined,
    /// The range decoder's state after the last frame, libopus'
    /// OPUS_GET_FINAL_RANGE (0 for a frame of at most a byte, which
    /// libopus conceals).
    final_range: u32 = 0,
    silk_buf: [2][960]f32 = undefined,
    redundancy_buf: [2][960]f32 = undefined,
    /// The packet's output, `cur_out` an offset into it.
    out: [2][max_output]f32 = undefined,
    cur_out: u32 = 0,

    fn deinit(s: *Stream, gpa: std.mem.Allocator) void {
        if (s.swr) |*r| r.deinit();
        s.celt.deinit();
        gpa.destroy(s.celt);
    }

    /// swr_close.
    fn closeResampler(s: *Stream) void {
        if (s.swr) |*r| r.deinit();
        s.swr = null;
    }

    fn view(s: *Stream, buffer: *[2][max_output]f32, at: u32) Resampler.View {
        _ = s;
        var v: Resampler.View = .{};
        v.planes[0] = buffer[0][at..].ptr;
        v.planes[1] = buffer[1][at..].ptr;
        return v;
    }

    /// opus_init_resample: the resampler at the SILK rate, with the
    /// initial silence for the packet's bandwidth.
    fn initResample(s: *Stream, gpa: std.mem.Allocator) DecodeError!void {
        s.swr = Resampler.init(gpa, s.output_channels, s.silk_samplerate, sample_rate, .{ .filter_size = 16 }) catch return error.OutOfMemory;
        s.swr_rate = s.silk_samplerate;
        var zeros: [16]f32 = @splat(0);
        var in: Resampler.View = .{};
        in.planes[0] = &zeros;
        in.planes[1] = &zeros;
        _ = s.swr.?.resample(s.view(&s.out, 0), 0, in, silk_resample_delay[@backingInt(s.packet.bandwidth)]) catch return error.OutOfMemory;
    }

    /// opus_flush_resample: the delayed samples drained into the output.
    fn flushResample(s: *Stream, nb_samples: u32) DecodeError!void {
        const r = &s.swr.?;
        r.flush() catch return error.OutOfMemory;
        var none: Resampler.View = .{};
        none.planes[0] = &s.silk_buf[0];
        none.planes[1] = &s.silk_buf[1];
        const got = r.resample(s.view(&s.out, s.cur_out), @intCast(nb_samples), none, 0) catch return error.OutOfMemory;
        // FFmpeg's AVERROR_BUG otherwise.
        if (got != nb_samples) return error.InvalidData;
        if (s.redundancy_idx != 0) {
            const idx = s.redundancy_idx;
            for (0..s.output_channels) |c| fade(s.out[c][s.cur_out..], s.out[c][s.cur_out..], s.redundancy_buf[c][120 + idx ..], tab.celt_window2[idx..], 120 - idx);
            s.redundancy_idx = 0;
        }
        s.cur_out += nb_samples;
    }
};

/// opus_fade: `in1` faded into `in2` under `window`, in double precision
/// where the C is.
fn fade(out: []f32, in1: []const f32, in2: []const f32, window: []const f32, len: u32) void {
    for (0..len) |i| {
        out[i] = @floatCast(@as(f64, in2[i] * window[i]) + @as(f64, in1[i]) * (1.0 - @as(f64, window[i])));
    }
}

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    head: Head,
    streams: []Stream,
    /// The head's gain as a factor, `c->gain`.
    gain: f32,

    /// opus_decode_init: the head parsed, a CELT decoder per stream
    /// (`apply_phase_inv`, the decoder's option of that name, true by
    /// default).
    pub fn init(gpa: std.mem.Allocator, extradata: []const u8, apply_phase_inv: bool) (HeadError || std.mem.Allocator.Error)!Decoder {
        const head = try Head.parse(extradata);
        // ff_exp10(gain_i / (20.0 * 256)): exp2(M_LOG2_10 * x).
        const gain: f32 = @floatCast(libm.exp2(3.32192809488736234787 * (@as(f64, @floatFromInt(head.gain_i)) / (20.0 * 256))));
        const streams = try gpa.alloc(Stream, head.streams);
        var made: usize = 0;
        errdefer {
            for (streams[0..made]) |*s| s.deinit(gpa);
            gpa.free(streams);
        }
        for (streams, 0..) |*s, i| {
            const output_channels: u32 = if (i < head.stereo_streams) 2 else 1;
            const c = try gpa.create(celt.Decoder);
            errdefer gpa.destroy(c);
            c.* = celt.Decoder.init(gpa, output_channels, apply_phase_inv) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Lengths and channel counts here are always valid.
                else => unreachable,
            };
            s.* = .{ .output_channels = output_channels, .celt = c, .silk = silk.Decoder.init(output_channels) catch unreachable };
            made += 1;
        }
        return .{ .gpa = gpa, .head = head, .streams = streams, .gain = gain };
    }

    pub fn deinit(d: *Decoder) void {
        for (d.streams) |*s| s.deinit(d.gpa);
        d.gpa.free(d.streams);
        d.* = undefined;
    }

    pub fn channels(d: *const Decoder) u8 {
        return d.head.channels;
    }

    /// The first stream's final range after the last packet
    /// (OPUS_GET_FINAL_RANGE, for RFC 6716's conformance check).
    pub fn finalRange(d: *const Decoder) u32 {
        return d.streams[0].final_range;
    }

    /// opus_decode_flush.
    pub fn flush(d: *Decoder) void {
        for (d.streams) |*s| {
            s.delayed_samples = 0;
            s.closeResampler();
            s.silk.flush();
            s.celt.flush();
        }
    }

    /// opus_decode_packet: `buf` decoded into `out[0 .. channels]`, each
    /// at least `max_output` samples, or, for a null `buf` (the end), the
    /// samples the resampler still owes; the samples per channel (FFmpeg's
    /// frame, none when 0).
    pub fn decodePacket(d: *Decoder, buf_in: ?[]const u8, out: [][]f32) DecodeError!u32 {
        std.debug.assert(out.len == d.head.channels);
        const nb = d.streams.len;
        var delayed: u32 = 0;
        for (d.streams) |*s| delayed = @max(delayed, s.delayed_samples);
        var coded_samples: u32 = 0;
        if (buf_in) |b| {
            d.streams[0].packet = opus.parsePacket(b, nb > 1) orelse return error.InvalidData;
            const first = d.streams[0].packet;
            coded_samples = first.frame_count * first.frame_duration;
            d.streams[0].silk_samplerate = silkSamplerate(first.config);
        }
        if (coded_samples + delayed == 0) return 0;

        var decoded: u32 = std.math.maxInt(u32);
        var buf = buf_in;
        for (d.streams, 0..) |*s, i| {
            if (i != 0) if (buf) |b| {
                s.packet = opus.parsePacket(b, i != nb - 1) orelse return error.InvalidData;
                if (s.packet.frame_count * s.packet.frame_duration != coded_samples) return error.InvalidData;
                s.silk_samplerate = silkSamplerate(s.packet.config);
            };
            // Streams whose delays could differ keep FFmpeg's sync
            // buffers, which T28c ports.
            if (nb > 1 and buf != null and s.packet.mode != .celt) return error.UnsupportedMode;
            const n = try d.decodeSubpacket(s, buf);
            decoded = @min(decoded, n);
            if (buf) |b| buf = b[@min(s.packet.packet_size, b.len)..];
        }

        for (out, 0..) |plane, i| {
            const map = d.head.maps[i];
            const dst = plane[0..decoded];
            if (map.copy) |j| {
                @memcpy(dst, out[j][0..decoded]);
            } else if (map.silence) {
                @memset(dst, 0);
            } else {
                @memcpy(dst, d.streams[map.stream].out[map.channel][0..decoded]);
            }
            // A copied channel takes the gain again, as FFmpeg's loop
            // copies after the source's gain.
            if (d.head.gain_i != 0 and decoded > 0) float_dsp.fmulScalar(dst, dst, d.gain);
        }
        return decoded;
    }

    /// opus_decode_subpacket: the resampler flushed when the mode or the
    /// SILK rate changes (or at the end), then each frame of the stream's
    /// packet; a frame that fails to decode is silence.
    fn decodeSubpacket(d: *Decoder, s: *Stream, buf: ?[]const u8) DecodeError!u32 {
        s.cur_out = 0;
        var output_samples: u32 = 0;
        var flush_needed = false;
        if (s.swr != null) {
            flush_needed = if (buf != null) s.packet.mode == .celt or s.swr_rate != s.silk_samplerate else s.delayed_samples != 0;
        }
        if (buf == null and !flush_needed) return 0;
        if (flush_needed) {
            try s.flushResample(s.delayed_samples);
            s.closeResampler();
            output_samples += s.delayed_samples;
            s.delayed_samples = 0;
            if (buf == null) return output_samples;
        }
        const pkt = &s.packet;
        for (0..pkt.frame_count) |i| {
            const samples = d.decodeFrame(s, buf.?, pkt.frame_offset[i], pkt.frame_size[i]) catch |err| switch (err) {
                error.UnsupportedMode, error.OutOfMemory => |e| return e,
                error.InvalidData => blk: {
                    for (0..s.output_channels) |c| @memset(s.out[c][s.cur_out..][0..pkt.frame_duration], 0);
                    break :blk pkt.frame_duration;
                },
            };
            output_samples += samples;
            s.cur_out += samples;
        }
        return output_samples;
    }

    /// opus_decode_frame: SILK at its rate, resampled, then the CELT
    /// redundancy frame and its fade, or a CELT frame.
    fn decodeFrame(d: *Decoder, s: *Stream, buf: []const u8, offset: i32, size_in: i32) DecodeError!u32 {
        const pkt = &s.packet;
        if (pkt.mode == .hybrid) return error.UnsupportedMode;
        var samples: u32 = pkt.frame_duration;
        const delayed_samples = s.delayed_samples;
        // ff_opus_rc_dec_init refuses a negative size; the packet's padding
        // past its end reads as zeros.
        if (size_in < 0 or offset < 0) return error.InvalidData;
        const start: usize = @intCast(offset);
        // ff_opus_parse_packet keeps every frame inside the packet.
        if (start + @as(usize, @intCast(size_in)) > buf.len) return error.InvalidData;
        var size: i32 = size_in;
        const data = buf[start..][0..@intCast(size)];
        var rc = opus_rc.RangeDecoder.init(data) catch return error.InvalidData;

        // The SILK frame.
        if (pkt.mode == .silk) {
            if (s.swr == null) try s.initResample(d.gpa);
            const bw = @min(@backingInt(pkt.bandwidth), 2);
            const n = s.silk.decodeSuperframe(&rc, .{ &s.silk_buf[0], &s.silk_buf[1] }, bw, @as(u32, @intFromBool(pkt.stereo)) + 1, silk_frame_duration_ms[pkt.config]) catch
                return error.InvalidData;
            var in: Resampler.View = .{};
            in.planes[0] = &s.silk_buf[0];
            in.planes[1] = &s.silk_buf[1];
            const got = s.swr.?.resample(s.view(&s.out, s.cur_out), @intCast(pkt.frame_duration), in, @intCast(n)) catch return error.OutOfMemory;
            samples = @intCast(got);
            s.delayed_samples += pkt.frame_duration - samples;
        } else s.silk.flush();

        // The redundancy information.
        const consumed = rc.tell();
        var redundancy = false;
        var redundancy_pos = false;
        var redundancy_size: i32 = 0;
        var redundant_rng: u32 = 0;
        if (pkt.mode == .silk and consumed + 17 <= @as(u32, @intCast(size)) * 8) redundancy = true;
        if (redundancy) {
            redundancy_pos = rc.log(1) != 0;
            redundancy_size = size - @as(i32, @intCast((consumed + 7) / 8));
            size -= redundancy_size;
            if (size < 0) return error.InvalidData;
            if (redundancy_pos) {
                redundant_rng = try d.decodeRedundancy(s, data[@intCast(size)..][0..@intCast(redundancy_size)]);
                s.celt.flush();
            }
        }

        // The CELT frame.
        if (pkt.mode == .celt) {
            rc.initRaw(data[0..@intCast(size)], @intCast(size));
            const outs = [2][]f32{ s.out[0][s.cur_out..], s.out[1][s.cur_out..] };
            s.celt.decodeFrame(&rc, outs, @as(u32, @intFromBool(pkt.stereo)) + 1, pkt.frame_duration, 0, tab.celt_band_end[@backingInt(pkt.bandwidth)]) catch
                return error.InvalidData;
        } else s.celt.flush();

        if (s.redundancy_idx != 0) {
            const idx = s.redundancy_idx;
            for (0..s.output_channels) |c| fade(s.out[c][s.cur_out..], s.out[c][s.cur_out..], s.redundancy_buf[c][120 + idx ..], tab.celt_window2[idx..], 120 - idx);
            s.redundancy_idx = 0;
        }
        if (redundancy) {
            if (!redundancy_pos) {
                s.celt.flush();
                redundant_rng = try d.decodeRedundancy(s, data[@intCast(size)..][0..@intCast(redundancy_size)]);
                for (0..s.output_channels) |c| {
                    const at = s.cur_out + samples + delayed_samples - 120;
                    fade(s.out[c][at..], s.out[c][at..], s.redundancy_buf[c][120..], &tab.celt_window2, 120 - delayed_samples);
                    if (delayed_samples != 0) s.redundancy_idx = 120 - delayed_samples;
                }
            } else {
                for (0..s.output_channels) |c| {
                    const at = s.cur_out + delayed_samples;
                    @memcpy(s.out[c][at..][0..120], s.redundancy_buf[c][0..120]);
                    fade(s.out[c][at + 120 ..], s.redundancy_buf[c][120..], s.out[c][at + 120 ..], &tab.celt_window2, 120);
                }
            }
        }
        // libopus' rangeFinal: the frame's, the redundancy frame's mixed in.
        s.final_range = if (size_in <= 1) 0 else rc.range ^ redundant_rng;
        return samples;
    }

    /// opus_decode_redundancy: a 5 ms CELT frame of the packet's bandwidth;
    /// its range decoder's final state.
    fn decodeRedundancy(d: *Decoder, s: *Stream, data: []const u8) DecodeError!u32 {
        _ = d;
        var rrc = opus_rc.RangeDecoder.init(data) catch return error.InvalidData;
        rrc.initRaw(data, @intCast(data.len));
        const outs = [2][]f32{ &s.redundancy_buf[0], &s.redundancy_buf[1] };
        s.celt.decodeFrame(&rrc, outs, @as(u32, @intFromBool(s.packet.stereo)) + 1, 240, 0, tab.celt_band_end[@backingInt(s.packet.bandwidth)]) catch
            return error.InvalidData;
        return rrc.range;
    }
};
