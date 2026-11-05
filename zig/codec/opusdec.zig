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
//! FFmpeg's Opus decoder (TODO.md T28): the OpusHead's channels, gain and
//! channel mapping, then each packet split into its streams (self-delimited
//! but the last) and their frames, each frame decoded by CELT
//! (codec/celt.zig, T28a), SILK (codec/silk.zig, resampled to 48 kHz by
//! libswresample's algorithm, T28b) or both (hybrid, T28c), the streams'
//! different delays evened out by sync buffers, the decoded channels
//! mapped, copied or silenced into the output, and the head's gain
//! applied. Output is planar float at 48 kHz, as FFmpeg's. A frame that
//! fails to decode is silence, as FFmpeg makes it.

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
    /// stream's sample count differs from the first's; or its AVERROR_BUG,
    /// where the delays of the resampler, the hybrid CELT samples and the
    /// sync buffers disagree. Also `decodePacket`'s answer to output
    /// planes that are not one per channel of `max_output` samples, where
    /// FFmpeg allocates the frame itself.
    InvalidData,
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
/// decoders, the resampler from the SILK rate and its delayed samples, the
/// CELT samples a hybrid frame holds back to meet the resampled SILK
/// (`celt_delay`), and the samples held back to meet the other streams
/// (`sync_buffer`). Both FIFOs are always read whole, so each is a buffer
/// and its length.
const Stream = struct {
    output_channels: u32,
    celt: *celt.Decoder,
    silk: silk.Decoder,
    /// The output channel each decoded channel writes into
    /// (`streams[map->stream_idx].out[map->channel_idx]`, the last output
    /// channel that names it), or none: a mono stream's second always.
    plane: [2]?u8 = .{ null, null },
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
    /// The samples the last packet decoded to, `decoded_samples`.
    decoded_samples: u32 = 0,
    silk_buf: [2][960]f32 = undefined,
    celt_buf: [2][960]f32 = undefined,
    redundancy_buf: [2][960]f32 = undefined,
    /// `celt_delay`: at most a frame, the CELT samples past the resampled
    /// SILK ones.
    celt_delay: [2][960]f32 = undefined,
    celt_delay_len: u32 = 0,
    /// `sync_buffer`, by channel.
    sync: [2]std.ArrayList(f32) = .{ .empty, .empty },
    /// The sync samples read into the mapped planes for the packet.
    sync_read: u32 = 0,
    /// `out_dummy`, where an unmapped channel decodes (allocated at the
    /// first need, both channels' planes).
    dummy: ?[]f32 = null,
    /// The packet's output (`cur_out`): each channel's plane past the sync
    /// samples, or the dummy, and the offset decoded so far.
    dest: [2][]f32 = undefined,
    cur_out: u32 = 0,

    fn deinit(s: *Stream, gpa: std.mem.Allocator) void {
        if (s.swr) |*r| r.deinit();
        for (&s.sync) |*l| l.deinit(gpa);
        if (s.dummy) |dm| gpa.free(dm);
        s.celt.deinit();
        gpa.destroy(s.celt);
    }

    fn syncLen(s: *const Stream) u32 {
        return @intCast(s.sync[0].items.len);
    }

    /// swr_close.
    fn closeResampler(s: *Stream) void {
        if (s.swr) |*r| r.deinit();
        s.swr = null;
    }

    /// opus_decode_subpacket's output: the mapped planes past the sync
    /// samples, the dummy for a channel mapped to none.
    fn bindOutput(s: *Stream, gpa: std.mem.Allocator, out: []const []f32) DecodeError!void {
        const need_dummy = s.plane[0] == null or (s.output_channels == 2 and s.plane[1] == null);
        if (need_dummy and s.dummy == null) s.dummy = try gpa.alloc(f32, 2 * max_output);
        for (0..s.output_channels) |c| {
            s.dest[c] = if (s.plane[c]) |p| out[p][s.sync_read..] else s.dummy.?[c * max_output ..][0..max_output];
        }
        // A mono stream's second channel is never written.
        if (s.output_channels == 1) s.dest[1] = s.dest[0];
        s.cur_out = 0;
    }

    fn view(s: *Stream, at: u32) Resampler.View {
        var v: Resampler.View = .{};
        v.planes[0] = s.dest[0][at..].ptr;
        v.planes[1] = s.dest[1][at..].ptr;
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
        _ = s.swr.?.resample(s.view(0), 0, in, silk_resample_delay[@backingInt(s.packet.bandwidth)]) catch return error.OutOfMemory;
    }

    /// opus_flush_resample: the delayed samples drained into the output,
    /// with the CELT samples a hybrid frame held back.
    fn flushResample(s: *Stream, nb_samples: u32) DecodeError!void {
        const r = &s.swr.?;
        r.flush() catch return error.OutOfMemory;
        var none: Resampler.View = .{};
        none.planes[0] = &s.silk_buf[0];
        none.planes[1] = &s.silk_buf[1];
        const got = r.resample(s.view(s.cur_out), @intCast(nb_samples), none, 0) catch return error.OutOfMemory;
        // FFmpeg's AVERROR_BUG otherwise, both.
        if (got != nb_samples) return error.InvalidData;
        if (s.celt_delay_len != 0) {
            if (s.celt_delay_len != nb_samples) return error.InvalidData;
            for (0..s.output_channels) |c| float_dsp.fmacScalar(s.dest[c][s.cur_out..][0..nb_samples], &s.celt_delay[c], 1.0);
            s.celt_delay_len = 0;
        }
        if (s.redundancy_idx != 0) {
            const idx = s.redundancy_idx;
            for (0..s.output_channels) |c| fade(s.dest[c][s.cur_out..], s.dest[c][s.cur_out..], s.redundancy_buf[c][120 + idx ..], tab.celt_window2[idx..], 120 - idx);
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
    /// Output channels no stream writes: a silenced channel takes stream
    /// 0's first channel in FFmpeg (its map's indices are 0), so a channel
    /// mapped there earlier is left as allocated, unwritten memory in
    /// FFmpeg's frame; here it is silence.
    unwritten: std.StaticBitSet(255),

    /// opus_decode_init: the head parsed, a SILK and a CELT decoder per
    /// stream (`apply_phase_inv`, the decoder's option of that name, true
    /// by default).
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
        // opus_decode_packet's `out` pointers: every map but a copy, the
        // silenced ones included, in channel order.
        for (head.maps[0..head.channels], 0..) |m, i| {
            if (m.copy == null) streams[m.stream].plane[m.channel] = @intCast(i);
        }
        var unwritten: std.StaticBitSet(255) = .empty;
        for (head.maps[0..head.channels], 0..) |m, i| {
            const writer = streams[m.stream].plane[m.channel];
            if (m.copy == null and !m.silence and (writer == null or writer.? != i)) unwritten.set(i);
        }
        return .{ .gpa = gpa, .head = head, .streams = streams, .gain = gain, .unwritten = unwritten };
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

    /// opus_decode_flush. Like FFmpeg's, it keeps a pending redundancy
    /// fade.
    pub fn flush(d: *Decoder) void {
        for (d.streams) |*s| {
            s.delayed_samples = 0;
            s.celt_delay_len = 0;
            s.closeResampler();
            for (&s.sync) |*l| l.clearRetainingCapacity();
            s.silk.flush();
            s.celt.flush();
        }
    }

    /// opus_decode_packet: `buf` decoded into `out[0 .. channels]`, each
    /// at least `max_output` samples, or, for a null `buf` (the end), the
    /// samples the resamplers still owe; the samples per channel (FFmpeg's
    /// frame, none when 0). Each stream's samples past the fewest any
    /// stream decoded wait in its sync buffer for the next packet. Other
    /// planes are `InvalidData`, before anything is written or decoded.
    pub fn decodePacket(d: *Decoder, buf_in: ?[]const u8, out: [][]f32) DecodeError!u32 {
        // The caller's planes, checked before any write: safety checks are
        // off in ReleaseFast, and every write below (CELT's included) stays
        // within max_output.
        if (out.len != d.head.channels) return error.InvalidData;
        for (out) |plane| if (plane.len < max_output) return error.InvalidData;
        const nb = d.streams.len;
        var delayed: u32 = 0;
        for (d.streams) |*s| delayed = @max(delayed, s.delayed_samples + s.syncLen());
        var coded_samples: u32 = 0;
        if (buf_in) |b| {
            d.streams[0].packet = opus.parsePacket(b, nb > 1) orelse return error.InvalidData;
            const first = d.streams[0].packet;
            coded_samples = first.frame_count * first.frame_duration;
            d.streams[0].silk_samplerate = silkSamplerate(first.config);
        }
        if (coded_samples + delayed == 0) return 0;
        // FFmpeg allocates the frame at this size; the planes hold
        // max_output, more than the resamplers and sync buffers delay.
        if (coded_samples + delayed > max_output) return error.InvalidData;

        // The sync buffers' samples first. FFmpeg reads a channel mapped to
        // none into a 32-sample array and fails (AVERROR_BUG) past it,
        // a mono stream's second channel included.
        for (d.streams) |*s| {
            const n = s.syncLen();
            if ((s.plane[0] == null or s.plane[1] == null) and n > 32) return error.InvalidData;
            for (0..s.output_channels) |c| {
                if (s.plane[c]) |p| @memcpy(out[p][0..n], s.sync[c].items);
                s.sync[c].clearRetainingCapacity();
            }
            s.sync_read = n;
        }

        var decoded: u32 = std.math.maxInt(u32);
        var buf = buf_in;
        for (d.streams, 0..) |*s, i| {
            if (i != 0) if (buf) |b| {
                s.packet = opus.parsePacket(b, i != nb - 1) orelse return error.InvalidData;
                if (s.packet.frame_count * s.packet.frame_duration != coded_samples) return error.InvalidData;
                s.silk_samplerate = silkSamplerate(s.packet.config);
            };
            const n = try d.decodeSubpacket(s, buf, out);
            s.decoded_samples = n;
            decoded = @min(decoded, n);
            if (buf) |b| buf = b[@min(s.packet.packet_size, b.len)..];
        }

        // The samples past the fewest wait, a channel mapped to none
        // buffering the first output channel's as FFmpeg's does.
        for (d.streams) |*s| {
            const extra = s.decoded_samples - decoded;
            if (extra == 0) continue;
            for (0..s.output_channels) |c| {
                const src = if (s.plane[c]) |p| out[p][s.sync_read + decoded ..] else out[0][decoded..];
                try s.sync[c].appendSlice(d.gpa, src[0..extra]);
            }
        }

        for (out, 0..) |plane, i| {
            const map = d.head.maps[i];
            const dst = plane[0..decoded];
            if (map.copy) |j| {
                @memcpy(dst, out[j][0..decoded]);
            } else if (map.silence or d.unwritten.isSet(i)) {
                @memset(dst, 0);
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
    fn decodeSubpacket(d: *Decoder, s: *Stream, buf: ?[]const u8, out: []const []f32) DecodeError!u32 {
        var output_samples: u32 = 0;
        var flush_needed = false;
        if (s.swr != null) {
            flush_needed = if (buf != null) s.packet.mode == .celt or s.swr_rate != s.silk_samplerate else s.delayed_samples != 0;
        }
        if (buf == null and !flush_needed) return 0;
        try s.bindOutput(d.gpa, out);
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
                error.OutOfMemory => |e| return e,
                error.InvalidData => blk: {
                    for (0..s.output_channels) |c| @memset(s.dest[c][s.cur_out..][0..pkt.frame_duration], 0);
                    break :blk pkt.frame_duration;
                },
            };
            output_samples += samples;
            s.cur_out += samples;
        }
        return output_samples;
    }

    /// opus_decode_frame: SILK at its rate, resampled, the redundancy
    /// frame, then CELT: the whole frame, or a hybrid frame's bands from 17
    /// added to the SILK samples, its samples past them held back
    /// (`celt_delay`) for the next frame or the flush; then the
    /// redundancy frame's fades.
    fn decodeFrame(d: *Decoder, s: *Stream, buf: []const u8, offset: i32, size_in: i32) DecodeError!u32 {
        const pkt = &s.packet;
        var samples: u32 = pkt.frame_duration;
        const delayed_samples = s.delayed_samples;
        // ff_opus_rc_dec_init refuses a negative size; the packet's padding
        // past its end reads as zeros.
        if (size_in < 0 or offset < 0) return error.InvalidData;
        const start: usize = @intCast(offset);
        // ff_opus_parse_packet keeps every frame inside the packet.
        if (start + @as(usize, @intCast(size_in)) > buf.len) return error.InvalidData;
        var size: i32 = size_in;
        // The packet from the frame on: FFmpeg's range decoder reads ahead
        // past the frame's end.
        const memory = buf[start..];
        const data = memory[0..@intCast(size)];
        var rc = opus_rc.RangeDecoder.initIn(memory, data.len) catch return error.InvalidData;

        // The SILK frame.
        if (pkt.mode != .celt) {
            if (s.swr == null) try s.initResample(d.gpa);
            const bw = @min(@backingInt(pkt.bandwidth), 2);
            const n = s.silk.decodeSuperframe(&rc, .{ &s.silk_buf[0], &s.silk_buf[1] }, bw, @as(u32, @intFromBool(pkt.stereo)) + 1, silk_frame_duration_ms[pkt.config]) catch
                return error.InvalidData;
            var in: Resampler.View = .{};
            in.planes[0] = &s.silk_buf[0];
            in.planes[1] = &s.silk_buf[1];
            const got = s.swr.?.resample(s.view(s.cur_out), @intCast(pkt.frame_duration), in, @intCast(n)) catch return error.OutOfMemory;
            samples = @intCast(got);
            s.delayed_samples += pkt.frame_duration - samples;
        } else s.silk.flush();

        // The redundancy information.
        const consumed = rc.tell();
        const bits = @as(u32, @intCast(size)) * 8;
        var redundancy = false;
        var redundancy_pos = false;
        var redundancy_size: i32 = 0;
        var redundant_rng: u32 = 0;
        if (pkt.mode == .hybrid and consumed + 37 <= bits) {
            redundancy = rc.log(12) != 0;
        } else if (pkt.mode == .silk and consumed + 17 <= bits) redundancy = true;
        if (redundancy) {
            redundancy_pos = rc.log(1) != 0;
            redundancy_size = if (pkt.mode == .hybrid)
                @intCast(rc.uint(256) + 2)
            else
                size - @as(i32, @intCast((consumed + 7) / 8));
            size -= redundancy_size;
            if (size < 0) return error.InvalidData;
            if (redundancy_pos) {
                redundant_rng = try d.decodeRedundancy(s, memory[@intCast(size)..], @intCast(redundancy_size));
                s.celt.flush();
            }
        }

        // The CELT frame.
        if (pkt.mode != .silk) {
            var at = s.cur_out;
            var celt_output_samples: i64 = samples;
            const delay_samples = s.celt_delay_len;
            if (delay_samples != 0) {
                // FFmpeg warns of spurious delay samples in a CELT frame and
                // drops them.
                if (pkt.mode == .hybrid) {
                    for (0..s.output_channels) |c| float_dsp.fmacScalar(s.dest[c][at..][0..delay_samples], &s.celt_delay[c], 1.0);
                    at += delay_samples;
                    celt_output_samples -= delay_samples;
                }
                s.celt_delay_len = 0;
            }
            rc.initRaw(data[0..@intCast(size)], @intCast(size));
            const outs: [2][]f32 = if (pkt.mode == .celt)
                .{ s.dest[0][s.cur_out..], s.dest[1][s.cur_out..] }
            else
                .{ &s.celt_buf[0], &s.celt_buf[1] };
            const start_band: u32 = if (pkt.mode == .hybrid) 17 else 0;
            s.celt.decodeFrame(&rc, outs, @as(u32, @intFromBool(pkt.stereo)) + 1, pkt.frame_duration, start_band, tab.celt_band_end[@backingInt(pkt.bandwidth)]) catch
                return error.InvalidData;
            if (pkt.mode == .hybrid) {
                // FFmpeg would read before celt_buf; the resampler never
                // delays SILK past the samples it holds back.
                if (celt_output_samples < 0) return error.InvalidData;
                const n: u32 = @intCast(celt_output_samples);
                const keep = pkt.frame_duration - n;
                for (0..s.output_channels) |c| {
                    float_dsp.fmacScalar(s.dest[c][at..][0..n], &s.celt_buf[c], 1.0);
                    @memcpy(s.celt_delay[c][0..keep], s.celt_buf[c][n..][0..keep]);
                }
                s.celt_delay_len = keep;
            }
        } else s.celt.flush();

        if (s.redundancy_idx != 0) {
            const idx = s.redundancy_idx;
            for (0..s.output_channels) |c| fade(s.dest[c][s.cur_out..], s.dest[c][s.cur_out..], s.redundancy_buf[c][120 + idx ..], tab.celt_window2[idx..], 120 - idx);
            s.redundancy_idx = 0;
        }
        if (redundancy) {
            if (!redundancy_pos) {
                s.celt.flush();
                redundant_rng = try d.decodeRedundancy(s, memory[@intCast(size)..], @intCast(redundancy_size));
                for (0..s.output_channels) |c| {
                    const at = s.cur_out + samples + delayed_samples - 120;
                    fade(s.dest[c][at..], s.dest[c][at..], s.redundancy_buf[c][120..], &tab.celt_window2, 120 - delayed_samples);
                    if (delayed_samples != 0) s.redundancy_idx = 120 - delayed_samples;
                }
            } else {
                for (0..s.output_channels) |c| {
                    const at = s.cur_out + delayed_samples;
                    @memcpy(s.dest[c][at..][0..120], s.redundancy_buf[c][0..120]);
                    fade(s.dest[c][at + 120 ..], s.redundancy_buf[c][120..], s.dest[c][at + 120 ..], &tab.celt_window2, 120);
                }
            }
        }
        // libopus' rangeFinal: the frame's, the redundancy frame's mixed in.
        s.final_range = if (size_in <= 1) 0 else rc.range ^ redundant_rng;
        return samples;
    }

    /// opus_decode_redundancy: a 5 ms CELT frame of the packet's bandwidth,
    /// the first `size` bytes of `memory` (the packet from there on); its
    /// range decoder's final state.
    fn decodeRedundancy(d: *Decoder, s: *Stream, memory: []const u8, size: u32) DecodeError!u32 {
        _ = d;
        const data = memory[0..size];
        var rrc = opus_rc.RangeDecoder.initIn(memory, size) catch return error.InvalidData;
        rrc.initRaw(data, @intCast(data.len));
        const outs = [2][]f32{ &s.redundancy_buf[0], &s.redundancy_buf[1] };
        s.celt.decodeFrame(&rrc, outs, @as(u32, @intFromBool(s.packet.stereo)) + 1, 240, 0, tab.celt_band_end[@backingInt(s.packet.bandwidth)]) catch
            return error.InvalidData;
        return rrc.range;
    }
};

const testing = std.testing;

test "a channel mapped before a silenced one is silence, where FFmpeg leaves it unwritten" {
    // Mapping family 255, one mono stream: channel 0 decodes it, channel 1
    // is silenced, and FFmpeg's silenced map (stream 0, channel 0) takes
    // the stream's output from channel 0.
    const head = [_]u8{ 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 2, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 255, 1, 0, 0, 255 };
    var dec = try Decoder.init(testing.allocator, &head, true);
    defer dec.deinit();
    try testing.expect(dec.unwritten.isSet(0));
    try testing.expect(!dec.unwritten.isSet(1));
    try testing.expectEqual(1, dec.streams[0].plane[0]);

    const storage = try testing.allocator.alloc(f32, 2 * max_output);
    defer testing.allocator.free(storage);
    @memset(storage, 1.0);
    var planes = [2][]f32{ storage[0..max_output], storage[max_output..] };
    // A 20 ms CELT packet (configuration 31, mono) of arbitrary bytes.
    var packet: [40]u8 = undefined;
    packet[0] = 31 << 3;
    for (packet[1..], 1..) |*b, i| b.* = @truncate(i *% 0x9d);
    const n = try dec.decodePacket(&packet, &planes);
    try testing.expectEqual(960, n);
    for (planes) |plane| {
        for (plane[0..n]) |v| try testing.expectEqual(0, v);
    }
}

test "the streams of a multistream packet decode with every mode side by side" {
    // Mapping family 1, three channels: a coupled stream (left, right) and
    // a mono one (centre), Vorbis order L, C, R.
    const head = [_]u8{ 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 3, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 1, 2, 1, 0, 2, 1 };
    var dec = try Decoder.init(testing.allocator, &head, true);
    defer dec.deinit();
    const storage = try testing.allocator.alloc(f32, 3 * max_output);
    defer testing.allocator.free(storage);
    var planes = [3][]f32{ storage[0..max_output], storage[max_output..][0..max_output], storage[2 * max_output ..] };
    // Stream 0 self-delimited: a hybrid 20 ms frame; stream 1 SILK at 8 kHz.
    var packet: [160]u8 = undefined;
    packet[0] = 13 << 3 | 4;
    packet[1] = 80;
    for (packet[2..82], 0..) |*b, i| b.* = @truncate(i *% 0x6b +% 7);
    packet[82] = 1 << 3;
    for (packet[83..], 0..) |*b, i| b.* = @truncate(i *% 0x35 +% 3);
    var total: u32 = 0;
    for (0..4) |_| total += try dec.decodePacket(&packet, &planes);
    total += try dec.decodePacket(null, &planes);
    // Every sample is decoded once, whatever the delays.
    try testing.expect(total <= 4 * 960);
    try testing.expect(total > 3 * 960);
}

test "planes other than one per channel of max_output samples are refused before any write" {
    const head = [_]u8{ 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 2, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 0 };
    var dec = try Decoder.init(testing.allocator, &head, true);
    defer dec.deinit();
    const storage = try testing.allocator.alloc(f32, 3 * max_output);
    defer testing.allocator.free(storage);
    @memset(storage, 7.0);
    // A 20 ms stereo CELT packet (configuration 31) of arbitrary bytes.
    var packet: [60]u8 = undefined;
    packet[0] = 31 << 3 | 4;
    for (packet[1..], 1..) |*b, i| b.* = @truncate(i *% 0x9d);
    var one = [1][]f32{storage[0..max_output]};
    try testing.expectError(error.InvalidData, dec.decodePacket(&packet, &one));
    var three = [3][]f32{ storage[0..max_output], storage[max_output..][0..max_output], storage[2 * max_output ..] };
    try testing.expectError(error.InvalidData, dec.decodePacket(&packet, &three));
    var short = [2][]f32{ storage[0 .. max_output - 1], storage[max_output..][0 .. max_output - 1] };
    try testing.expectError(error.InvalidData, dec.decodePacket(&packet, &short));
    try testing.expectError(error.InvalidData, dec.decodePacket(null, &short));
    for (storage) |v| try testing.expectEqual(7.0, v);
    var planes = [2][]f32{ storage[0..max_output], storage[max_output..][0..max_output] };
    try testing.expectEqual(960, try dec.decodePacket(&packet, &planes));
}

const hostile = @import("../testing/hostile.zig");

/// An Ogg Opus fixture's packets (the OpusHead first, then OpusTags and
/// the audio); free with `deinit`.
const TestStream = struct {
    packets: [24]std.ArrayList(u8) = @splat(.empty),
    count: usize,

    fn init(gpa: std.mem.Allocator, file: []const u8, count: usize) !TestStream {
        var t: TestStream = .{ .count = count };
        errdefer t.deinit(gpa);
        try hostile.oggPackets(gpa, file, t.packets[0..count]);
        return t;
    }

    fn deinit(t: *TestStream, gpa: std.mem.Allocator) void {
        for (&t.packets) |*p| p.deinit(gpa);
    }

    fn head(t: *const TestStream) []const u8 {
        return t.packets[0].items;
    }

    fn audio(t: *const TestStream) []const std.ArrayList(u8) {
        return t.packets[2..t.count];
    }
};

const fixture_hybrid = @embedFile("../testing/fixtures/ogg/ogg_opus_hybrid.ogg");
const fixture_multistream = @embedFile("../testing/fixtures/ogg/ogg_opus_multistream.ogg");
const fixture_silk = @embedFile("../testing/fixtures/ogg/ogg_opus_silk.ogg");
const fixture_mapped = @embedFile("../testing/fixtures/ogg/ogg_opus_mapped.ogg");

fn decodeUnderFailures(gpa: std.mem.Allocator, t: *const TestStream) !void {
    var d = Decoder.init(gpa, t.head(), true) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidData, error.UnsupportedFormat => error.TestUnexpectedResult,
    };
    defer d.deinit();
    const storage = try gpa.alloc(f32, @as(usize, max_output) * d.channels());
    defer gpa.free(storage);
    var planes: [255][]f32 = undefined;
    for (0..d.channels()) |c| planes[c] = storage[c * max_output ..][0..max_output];
    for (t.audio(), 0..) |p, i| {
        _ = d.decodePacket(p.items, planes[0..d.channels()]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidData => {},
        };
        // A flush midway: the resamplers closed and opened again.
        if (i == 3) d.flush();
    }
    _ = try d.decodePacket(null, planes[0..d.channels()]);
}

test "the Opus decoder frees everything under every allocation and remap failure" {
    const gpa = testing.allocator;
    // Bounded for Debug: the three-stream fixture with remaps failing only
    // (which reaches every allocation the other pass makes).
    const cases = [_]struct { file: []const u8, count: usize, remaps: hostile.Remaps }{
        .{ .file = fixture_hybrid, .count = 12, .remaps = .both },
        .{ .file = fixture_silk, .count = 12, .remaps = .both },
        .{ .file = fixture_mapped, .count = 6, .remaps = .both },
        .{ .file = fixture_multistream, .count = 10, .remaps = .fail },
    };
    for (cases) |case| {
        var t = try TestStream.init(gpa, case.file, case.count);
        defer t.deinit(gpa);
        try hostile.checkAllocationFailuresWith(gpa, case.remaps, &t, decodeUnderFailures);
    }
}

/// The fuzz entry's input: the OpusHead, the decoder's `apply_phase_inv`
/// option, then up to 32 steps, each an end flag, an action (0 a packet,
/// 1 the end's null packet, 2 a flush) and a packet.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const gpa = testing.allocator;
    var head: [300]u8 = undefined;
    const head_len = smith.slice(&head);
    const phase_inv = smith.value(bool);
    var d = Decoder.init(gpa, head[0..head_len], phase_inv) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidData, error.UnsupportedFormat => return,
    };
    defer d.deinit();
    const storage = try gpa.alloc(f32, @as(usize, max_output) * d.channels());
    defer gpa.free(storage);
    var planes: [255][]f32 = undefined;
    for (0..d.channels()) |c| planes[c] = storage[c * max_output ..][0..max_output];
    var packet: [4096]u8 = undefined;
    for (0..32) |_| {
        if (smith.eos()) break;
        const action = smith.valueRangeAtMost(u8, 0, 2);
        const n = smith.slice(&packet);
        switch (action) {
            0, 1 => {
                const buf: ?[]const u8 = if (action == 0) packet[0..n] else null;
                const samples = d.decodePacket(buf, planes[0..d.channels()]) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.InvalidData => 0,
                };
                try testing.expect(samples <= max_output);
                for (planes[0..d.channels()]) |plane| for (plane[0..samples]) |v| std.mem.doNotOptimizeAway(v);
            },
            else => d.flush(),
        }
    }
}

/// A `fuzzOne` input: `t`'s head and packets, with `actions[i]` before
/// packet i (a null packet or a flush) where given, and the null packet
/// at the end.
fn fuzzSeed(gpa: std.mem.Allocator, t: *const TestStream, phase_inv: bool, actions: []const u8) ![]u8 {
    var s: hostile.Seed = .{};
    errdefer s.deinit(gpa);
    try s.slice(gpa, t.head());
    try s.value(gpa, @intFromBool(phase_inv));
    for (t.audio(), 0..) |p, i| {
        if (i < actions.len and actions[i] != 0) {
            try s.eos(gpa, false);
            try s.value(gpa, actions[i]);
            try s.slice(gpa, &.{});
        }
        try s.eos(gpa, false);
        try s.value(gpa, 0);
        try s.slice(gpa, p.items);
    }
    try s.eos(gpa, false);
    try s.value(gpa, 1);
    try s.slice(gpa, &.{});
    try s.eos(gpa, true);
    return s.toOwnedSlice(gpa);
}

test "fuzz: the Opus decoder on arbitrary heads and packets" {
    const gpa = testing.allocator;
    var hybrid = try TestStream.init(gpa, fixture_hybrid, 17);
    defer hybrid.deinit(gpa);
    var multistream = try TestStream.init(gpa, fixture_multistream, 10);
    defer multistream.deinit(gpa);
    var silk_stream = try TestStream.init(gpa, fixture_silk, 18);
    defer silk_stream.deinit(gpa);
    var mapped = try TestStream.init(gpa, fixture_mapped, 6);
    defer mapped.deinit(gpa);
    var seeds: [5][]u8 = undefined;
    var made: usize = 0;
    defer for (seeds[0..made]) |s| gpa.free(s);
    seeds[0] = try fuzzSeed(gpa, &hybrid, true, &.{});
    made += 1;
    seeds[1] = try fuzzSeed(gpa, &multistream, true, &.{ 0, 0, 2, 0, 1 });
    made += 1;
    seeds[2] = try fuzzSeed(gpa, &silk_stream, false, &.{ 0, 0, 0, 1, 0, 2 });
    made += 1;
    seeds[3] = try fuzzSeed(gpa, &mapped, true, &.{});
    made += 1;
    seeds[4] = try fuzzSeed(gpa, &hybrid, false, &.{ 0, 2, 1 });
    made += 1;
    try testing.fuzz({}, fuzzOne, .{ .corpus = &seeds });
}
