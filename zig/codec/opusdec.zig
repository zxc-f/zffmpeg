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

pub const sample_rate = 48000;
/// The most samples a packet decodes to (120 ms).
pub const max_frame = opus.max_packet_duration;

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
    /// A SILK or hybrid frame (T28b, T28c).
    UnsupportedMode,
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

/// One of the packet's streams: its CELT decoder and output.
const Stream = struct {
    output_channels: u32,
    celt: *celt.Decoder,
    packet: opus.Packet = undefined,
    /// The range decoder's state after the last frame, libopus'
    /// OPUS_GET_FINAL_RANGE (0 for a frame of at most a byte, which
    /// libopus conceals).
    final_range: u32 = 0,
    out: [2][max_frame]f32 = undefined,
};

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
            for (streams[0..made]) |*s| {
                s.celt.deinit();
                gpa.destroy(s.celt);
            }
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
            s.* = .{ .output_channels = output_channels, .celt = c };
            made += 1;
        }
        return .{ .gpa = gpa, .head = head, .streams = streams, .gain = gain };
    }

    pub fn deinit(d: *Decoder) void {
        for (d.streams) |*s| {
            s.celt.deinit();
            d.gpa.destroy(s.celt);
        }
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
        for (d.streams) |*s| s.celt.flush();
    }

    /// opus_decode_packet: `buf` decoded into `out[0 .. channels]`, each
    /// at least `max_frame` samples; the samples per channel (FFmpeg's
    /// frame). The decoder delays nothing without SILK, so the end needs
    /// no flush.
    pub fn decodePacket(d: *Decoder, buf_in: []const u8, out: [][]f32) DecodeError!u32 {
        std.debug.assert(out.len == d.head.channels);
        var buf = buf_in;
        const nb = d.streams.len;
        d.streams[0].packet = opus.parsePacket(buf, nb > 1) orelse return error.InvalidData;
        const first = d.streams[0].packet;
        const coded_samples = first.frame_count * first.frame_duration;
        var decoded: u32 = std.math.maxInt(u32);
        for (d.streams, 0..) |*s, i| {
            if (i != 0) {
                s.packet = opus.parsePacket(buf, i != nb - 1) orelse return error.InvalidData;
                if (s.packet.frame_count * s.packet.frame_duration != coded_samples) return error.InvalidData;
            }
            const n = try decodeSubpacket(s, buf);
            decoded = @min(decoded, n);
            buf = buf[@min(s.packet.packet_size, buf.len)..];
        }
        // The streams all decode their packets' durations: nothing to
        // keep for the next packet.
        for (d.streams) |*s| std.debug.assert(s.packet.frame_count * s.packet.frame_duration == decoded);

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
};

/// opus_decode_subpacket without the resampler: each frame of the
/// stream's packet in turn; a frame CELT refuses is silence.
fn decodeSubpacket(s: *Stream, buf: []const u8) DecodeError!u32 {
    const pkt = &s.packet;
    var at: u32 = 0;
    for (0..pkt.frame_count) |i| {
        const outs = [2][]f32{ s.out[0][at..], s.out[1][at..] };
        const samples = decodeFrame(s, buf, pkt.frame_offset[i], pkt.frame_size[i], outs) catch |err| switch (err) {
            error.UnsupportedMode => return error.UnsupportedMode,
            error.InvalidData => blk: {
                for (outs[0..s.output_channels]) |o| @memset(o[0..pkt.frame_duration], 0);
                break :blk pkt.frame_duration;
            },
        };
        at += samples;
    }
    return at;
}

/// opus_decode_frame for a CELT frame.
fn decodeFrame(s: *Stream, buf: []const u8, offset: i32, size: i32, outs: [2][]f32) DecodeError!u32 {
    const pkt = &s.packet;
    if (pkt.mode != .celt) return error.UnsupportedMode;
    // ff_opus_rc_dec_init refuses a negative size; the packet's padding
    // past its end reads as zeros.
    if (size < 0 or offset < 0) return error.InvalidData;
    const start: usize = @intCast(offset);
    const end = start + @as(usize, @intCast(size));
    // ff_opus_parse_packet keeps every frame inside the packet.
    if (end > buf.len) return error.InvalidData;
    const data = buf[start..end];
    var rc = opus_rc.RangeDecoder.init(data) catch return error.InvalidData;
    rc.initRaw(data, @intCast(size));
    s.celt.decodeFrame(&rc, outs, @as(u32, @intFromBool(pkt.stereo)) + 1, pkt.frame_duration, 0, tab.celt_band_end[@backingInt(pkt.bandwidth)]) catch
        return error.InvalidData;
    s.final_range = if (size <= 1) 0 else rc.range;
    return pkt.frame_duration;
}
