// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/decode.c (discard_samples, the skip-samples side data) and
// fftools' input opening (avformat_find_stream_info, then the decoder) at
// the pinned reference revision describe the behavior, restated here.
//! An Ogg stream decoded as the ffmpeg program decodes it (TODO.md T27d):
//! the demuxer through libavformat's generic layer, FFmpeg's Vorbis or
//! FLAC decoder, and libavcodec's discarding of the samples a decoder or
//! the demuxer asks to skip, delivered as packed little-endian samples
//! (Vorbis' planar floats interleaved as f32le).
//!
//! On a seekable input the stream is decoded once ahead to count its
//! samples, the count FFmpeg's muxers write when they rewrite a header at
//! the end (the stream's duration, from its granules, can differ: a
//! Vorbis stream decodes to whole blocks). Without seeking there is no
//! count. Reading checks the count, as FLAC's STREAMINFO count is checked
//! in format/flac.zig (`FrameCountMismatch`), unless the caller takes the
//! samples as they come (`expected` set to null).

const std = @import("std");
const audio = @import("../core/audio.zig");
const metadata = @import("../core/metadata.zig");
const diagnostics = @import("../core/diagnostics.zig");
const pcm = @import("../codec/pcm.zig");
const codecs = @import("../codec/registry.zig");
const flac = @import("../codec/flac.zig");
const flacdec = @import("../codec/flacdec.zig");
const vorbis = @import("../codec/vorbis.zig");
const ogg = @import("ogg.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");

/// What reading the samples can fail with.
pub const ReadError = ogg.Error || error{
    /// The stream decodes to another sample count than counted ahead.
    FrameCountMismatch,
    /// More than two thirds of the decodes failed: the ffmpeg program's
    /// `-max_error_rate` (2/3), which fails the decoding.
    DecodeErrorRate,
};

/// What opening can fail with, and reading.
pub const Error = ReadError || error{
    /// FFmpeg's Vorbis decoder refuses the stream's headers.
    InvalidVorbis,
    /// No stream the port decodes (Opus has no decoder yet), or several:
    /// the ffmpeg program's choice among them is not ported.
    UnsupportedOperation,
};

/// libavcodec's decode.c around a decoder (discard_samples): the samples
/// still to skip, from the decoder (its first frame) or a packet's
/// skip-samples side data, and the end padding a packet asks to drop.
pub const Discard = struct {
    skip: i64 = 0,

    /// The kept part of a decoded frame of `n` samples, as [start, end);
    /// null when the whole frame is dropped.
    pub fn apply(x: *Discard, n: u32, side: ?[2]u32) ?[2]u32 {
        var padding: u32 = 0;
        if (side) |s| {
            const skip: i32 = @bitCast(s[0]);
            if (skip != 0) x.skip = skip;
            x.skip = @max(0, x.skip);
            padding = s[1];
        }
        var start: u32 = 0;
        var count = n;
        if (x.skip > 0) {
            if (count <= x.skip) {
                x.skip -= count;
                return null;
            }
            start = @intCast(x.skip);
            count -= start;
            x.skip = 0;
        }
        if (padding > 0 and padding <= n) {
            const drop = @min(padding, count);
            if (drop == count) return null;
            count -= drop;
        }
        return .{ start, start + count };
    }
};

const Layer = demux.Layer(ogg.Demuxer);

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    sink: ?diagnostics.Sink,
    demuxer: ?*ogg.Demuxer = null,
    layer: ?Layer = null,
    stream: usize = 0,
    decoder: union(enum) { none, vorbis: vorbis.Decoder, flac: flacdec.Decoder } = .none,
    channels: u8 = 0,
    /// Vorbis' output planes, blocksize[1] / 2 samples each.
    plane_storage: []f32 = &.{},
    planes: [255][]f32 = undefined,
    /// The current frame's samples not yet delivered: a range of the
    /// planes (Vorbis) or interleaved samples borrowed from the decoder.
    pending: union(enum) { planes: [2]u32, s16: []const i16, s32: []const i32 } = .{ .s16 = &.{} },
    discard: Discard = .{},
    delivered: u64 = 0,
    expected: ?u64 = null,
    ended: bool = false,
    /// The decoded samples' bits, from `readHeader`.
    bits: u8 = 0,
    /// The decoder's largest frame (the ffmpeg program's packets).
    max_frame: u32 = 0,
    /// This reader is the counting pass of another.
    counting: bool = false,
    /// The ffmpeg program's decoder statistics: frames returned and
    /// packets the decoder refused.
    frames_decoded: u64 = 0,
    decode_errors: u64 = 0,

    pub const Header = struct {
        /// The stream's codec.
        stream: codecs.Codec,
        /// The encoding of the bytes `readData` gives.
        codec: pcm.Codec,
        format: audio.Format,
        /// The stream's duration, when known.
        frame_count: ?u64,
        /// The decoded samples' bits (`bits_per_raw_sample` for an encoder).
        bits: u8,
    };

    /// Reads `reader` from its start; `seeker`, when the input can seek,
    /// moves it there and lets the demuxer scan for the durations.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker, sink: ?diagnostics.Sink) DecodedReader {
        return .{ .gpa = gpa, .reader = reader, .seeker = seeker, .sink = sink };
    }

    pub fn deinit(r: *DecodedReader) void {
        switch (r.decoder) {
            .none => {},
            .vorbis => |*d| d.deinit(),
            .flac => |*d| d.deinit(),
        }
        r.gpa.free(r.plane_storage);
        if (r.layer) |*l| l.deinit();
        if (r.demuxer) |d| d.deinit();
        r.* = undefined;
    }

    /// The demuxer, avformat_find_stream_info and the decoder opened, as
    /// the ffmpeg program opens an input.
    pub fn readHeader(r: *DecodedReader) Error!Header {
        std.debug.assert(r.demuxer == null);
        // The counting pass, from the start, before this one.
        var counted: ?u64 = null;
        if (r.seeker != null and !r.counting) {
            var pass = init(r.gpa, r.reader, r.seeker, null);
            pass.counting = true;
            defer pass.deinit();
            _ = try pass.readHeader();
            var scratch: [4096]u8 = undefined;
            while ((try pass.readData(&scratch)).len != 0) {}
            // A decoding the program fails, failed before any output.
            try pass.checkErrorRate();
            counted = pass.delivered;
        }
        if (r.seeker) |sk| {
            sk.seekTo(0) catch return error.IoFailure;
            r.demuxer = try ogg.Demuxer.initSeekable(r.gpa, r.reader, sk);
        } else r.demuxer = try ogg.Demuxer.init(r.gpa, r.reader);
        const d = r.demuxer.?;
        r.layer = .init(r.gpa, d);
        try r.layer.?.findStreamInfo();
        var chosen: ?usize = null;
        for (0..d.streamCount()) |i| {
            if (d.stream(i).codec == null) continue;
            if (chosen != null) return error.UnsupportedOperation;
            chosen = i;
        }
        r.stream = chosen orelse return error.UnsupportedOperation;
        const info = d.stream(r.stream);
        r.channels = info.channels;
        r.expected = counted;
        switch (info.codec.?) {
            .opus => return error.UnsupportedOperation,
            .vorbis => {
                r.decoder = .{ .vorbis = vorbis.Decoder.init(r.gpa, info.extradata.items) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidData => error.InvalidVorbis,
                } };
                const dec = &r.decoder.vorbis;
                const capacity = dec.blocksize[1] / 2;
                r.plane_storage = try r.gpa.alloc(f32, @as(usize, capacity) * dec.channels);
                for (0..dec.channels) |c| r.planes[c] = r.plane_storage[c * capacity ..][0..capacity];
                r.pending = .{ .planes = .{ 0, 0 } };
                const format = audio.Format.initLayout(dec.sample_rate, vorbis.channelLayout(dec.channels), .flt) catch return error.UnsupportedFormat;
                r.bits = 32;
                r.max_frame = capacity;
                return .{ .stream = .vorbis, .codec = .f32le, .format = format, .frame_count = r.expected, .bits = 32 };
            },
            .flac => {
                const e = info.extradata.items;
                if (e.len < flac.streaminfo_size) return error.UnsupportedFormat;
                const si = flac.StreamInfo.parse(e[0..flac.streaminfo_size]);
                r.decoder = .{ .flac = flacdec.Decoder.init(r.gpa, si) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidData => error.UnsupportedFormat,
                } };
                if (si.channels > flac.max_channels or si.sample_rate == 0) return error.UnsupportedFormat;
                const storage: audio.SampleFormat = if (si.bps > 16) .s32 else .s16;
                const format = audio.Format.initLayout(si.sample_rate, flac.channelLayout(si.channels), storage) catch return error.UnsupportedFormat;
                r.bits = si.bps;
                r.max_frame = si.max_blocksize;
                return .{ .stream = .flac, .codec = if (si.bps > 16) .s32le else .s16le, .format = format, .frame_count = r.expected, .bits = si.bps };
            },
        }
    }

    /// The decoded stream's tags (its Vorbis comments, under FFmpeg's
    /// names), from `readHeader`.
    pub fn streamTags(r: *const DecodedReader) *const metadata.Dictionary {
        return &r.demuxer.?.stream(r.stream).tags;
    }

    fn pendingFrames(r: *const DecodedReader) usize {
        return switch (r.pending) {
            .planes => |range| range[1] - range[0],
            .s16 => |s| s.len / r.channels,
            .s32 => |s| s.len / r.channels,
        };
    }

    /// The first decoded frame's sample count, after discarding (the
    /// ffmpeg program's FLAC encoder takes it as its block size); null for
    /// a stream without one. `readData` still returns it first.
    pub fn firstFrameSamples(r: *DecodedReader) ReadError!?u32 {
        std.debug.assert(r.delivered == 0);
        if (r.pendingFrames() == 0 and !try r.nextFrame()) return null;
        return @intCast(r.pendingFrames());
    }

    /// Whole frames of samples into `output`, at least one while any
    /// remain (a frame fits in 4 bytes a channel); empty at the end.
    pub fn readData(r: *DecodedReader, output: []u8) ReadError![]u8 {
        while (r.pendingFrames() == 0) {
            if (!try r.nextFrame()) return output[0..0];
        }
        const width: usize = switch (r.pending) {
            .s16 => 2,
            .planes, .s32 => 4,
        };
        const frame_bytes = width * r.channels;
        const frames = @min(output.len / frame_bytes, r.pendingFrames());
        std.debug.assert(frames > 0);
        if (r.expected) |expected| {
            if (r.delivered + frames > expected) return error.FrameCountMismatch;
        }
        switch (r.pending) {
            .planes => |*range| {
                for (0..frames) |f| {
                    for (0..r.channels) |c| {
                        const v = r.planes[c][range[0] + f];
                        std.mem.writeInt(u32, output[(f * r.channels + c) * 4 ..][0..4], @bitCast(v), .little);
                    }
                }
                range[0] += @intCast(frames);
            },
            .s16 => |*s| {
                const count = frames * r.channels;
                for (s.*[0..count], 0..) |sample, i| std.mem.writeInt(i16, output[2 * i ..][0..2], sample, .little);
                s.* = s.*[count..];
            },
            .s32 => |*s| {
                const count = frames * r.channels;
                for (s.*[0..count], 0..) |sample, i| std.mem.writeInt(i32, output[4 * i ..][0..4], sample, .little);
                s.* = s.*[count..];
            },
        }
        r.delivered += frames;
        return output[0 .. frames * frame_bytes];
    }

    /// The next frame libavcodec returns into `pending`; false at the end.
    /// A packet the decoder refuses is reported and skipped, as the ffmpeg
    /// program skips it.
    fn nextFrame(r: *DecodedReader) ReadError!bool {
        if (r.ended) return false;
        const layer = &r.layer.?;
        while (true) {
            switch (r.decoder) {
                .flac => |*dec| {
                    const frame = dec.receive() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidData => {
                            diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{});
                            r.decode_errors += 1;
                            continue;
                        },
                    };
                    if (frame) |f| {
                        r.frames_decoded += 1;
                        if (f.channels != r.channels) return error.UnsupportedFormat;
                        r.pending = switch (f.samples) {
                            .s16 => |s| .{ .s16 = s },
                            .s32 => |s| .{ .s32 = s },
                        };
                        return true;
                    }
                },
                else => {},
            }
            const p = try layer.next() orelse {
                r.ended = true;
                return false;
            };
            if (p.stream != r.stream) continue;
            switch (r.decoder) {
                .none => unreachable,
                .flac => |*dec| dec.send(p.data, p.pts),
                .vorbis => |*dec| {
                    const samples = dec.decodePacket(p.data, r.planes[0..dec.channels]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidData => {
                            diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{});
                            r.decode_errors += 1;
                            continue;
                        },
                    };
                    const n = samples orelse continue;
                    if (!dec.first_frame_consumed and dec.skip_samples != 0) {
                        // avctx->internal->skip_samples, set by the first frame.
                        r.discard.skip = dec.skip_samples;
                        dec.first_frame_consumed = true;
                    }
                    const kept = r.discard.apply(n, p.skip) orelse continue;
                    r.frames_decoded += 1;
                    r.pending = .{ .planes = kept };
                    return true;
                },
            }
        }
    }

    /// The ffmpeg program's check at the end of decoding: the share of
    /// failed decodes, in single precision, above `-max_error_rate`.
    fn checkErrorRate(r: *const DecodedReader) ReadError!void {
        if (r.frames_decoded == 0 and r.decode_errors == 0) return;
        const errors: f32 = @floatFromInt(r.decode_errors);
        const all: f32 = @floatFromInt(r.frames_decoded + r.decode_errors);
        if (errors / all > @as(f32, 2.0 / 3.0)) return error.DecodeErrorRate;
    }

    /// Checks the decoding's error rate, and that the stream decoded to
    /// the count found ahead.
    pub fn finish(r: *DecodedReader) ReadError!void {
        std.debug.assert(r.pendingFrames() == 0);
        try r.checkErrorRate();
        if (r.expected) |expected| {
            if (r.delivered != expected) return error.FrameCountMismatch;
        }
    }
};
