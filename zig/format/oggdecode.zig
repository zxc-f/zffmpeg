// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/decode.c (discard_samples, the skip-samples side data) and
// fftools' input opening (avformat_find_stream_info, then the decoder) at
// the pinned reference revision describe the behavior, restated here.
//! An Ogg stream decoded as the ffmpeg program decodes it (TODO.md T27d):
//! the demuxer through libavformat's generic layer, FFmpeg's Vorbis, Opus
//! (CELT and SILK frames, T28a and T28b) or FLAC decoder, and libavcodec's discarding of the
//! samples a decoder or the demuxer asks to skip, delivered as packed
//! little-endian samples (Vorbis' and Opus' planar floats interleaved as
//! f32le).
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
const opusdec = @import("../codec/opusdec.zig");
const ogg = @import("ogg.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");
const decoded = @import("decoded.zig");

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
    /// FFmpeg's Opus decoder refuses the OpusHead.
    InvalidOpus,
    /// No stream the port decodes, or several: the ffmpeg program's choice
    /// among them is not ported.
    UnsupportedOperation,
};

const Discard = decoded.Discard;

const Layer = demux.Layer(ogg.Demuxer);

pub const DecodedReader = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    sink: ?diagnostics.Sink,
    demuxer: ?*ogg.Demuxer = null,
    layer: ?Layer = null,
    stream: usize = 0,
    decoder: union(enum) {
        none,
        vorbis: vorbis.Decoder,
        opus: opusdec.Decoder,
        /// With the format STREAMINFO opened, which every frame must keep.
        flac: struct { decoder: flacdec.Decoder, opened: flacdec.Opened },
    } = .none,
    channels: u8 = 0,
    /// Vorbis' output planes, blocksize[1] / 2 samples each, or Opus'
    /// (`opusdec.max_frame`).
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
    /// The ffmpeg program's decoder statistics.
    errors: decoded.ErrorRate = .{},

    pub const Header = decoded.Header;

    /// Reads `reader` from its start; `seeker`, when the input can seek,
    /// moves it there and lets the demuxer scan for the durations.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker, sink: ?diagnostics.Sink) DecodedReader {
        return .{ .gpa = gpa, .reader = reader, .seeker = seeker, .sink = sink };
    }

    pub fn deinit(r: *DecodedReader) void {
        switch (r.decoder) {
            .none => {},
            .vorbis => |*d| d.deinit(),
            .opus => |*d| d.deinit(),
            .flac => |*d| d.decoder.deinit(),
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
            try pass.errors.check();
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
            .opus => {
                // Initialized into a local first: assigning the union in
                // place sets its tag before the payload exists, so a
                // failed init would leave `deinit` freeing garbage.
                const opus = opusdec.Decoder.init(r.gpa, info.extradata.items, true) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidData => error.InvalidOpus,
                    error.UnsupportedFormat => error.UnsupportedFormat,
                };
                r.decoder = .{ .opus = opus };
                const dec = &r.decoder.opus;
                const n = dec.channels();
                // The planes and the output follow the decoder's count.
                r.channels = n;
                r.plane_storage = try r.gpa.alloc(f32, @as(usize, opusdec.max_output) * n);
                for (0..n) |c| r.planes[c] = r.plane_storage[c * opusdec.max_output ..][0..opusdec.max_output];
                r.pending = .{ .planes = .{ 0, 0 } };
                // avcodec_open2 starts the skip at avctx->delay, the
                // pre-skip.
                r.discard.skip = dec.head.pre_skip;
                const format = audio.Format.initLayout(opusdec.sample_rate, dec.head.layout, .flt) catch return error.UnsupportedFormat;
                r.bits = 32;
                r.max_frame = opusdec.max_output;
                return .{ .stream = .opus, .codec = .f32le, .format = format, .frame_count = r.expected, .bits = 32 };
            },
            .vorbis => {
                const decoder = vorbis.Decoder.init(r.gpa, info.extradata.items) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidData => error.InvalidVorbis,
                };
                r.decoder = .{ .vorbis = decoder };
                const dec = &r.decoder.vorbis;
                const capacity = dec.blocksize[1] / 2;
                r.channels = dec.channels;
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
                const decoder = flacdec.Decoder.init(r.gpa, si) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidData => error.UnsupportedFormat,
                };
                r.decoder = .{ .flac = .{
                    .decoder = decoder,
                    .opened = .{ .channels = info.channels, .sample_rate = si.sample_rate, .s32 = si.bps > 16 },
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
                decoded.interleave(output, r.planes[0..r.channels], range[0], frames);
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
                .flac => |*state| {
                    const frame = state.decoder.receive() catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidData => {
                            diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{});
                            r.errors.decode_errors += 1;
                            continue;
                        },
                    };
                    if (frame) |f| {
                        r.errors.frames_decoded += 1;
                        // A channel, rate or storage change is refused, as
                        // native FLAC refuses it: delivering the frame would
                        // give its samples the opened rate.
                        if (!state.opened.keeps(f)) return error.UnsupportedFormat;
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
                // The end: the samples Opus' resampler still owes, as the
                // ffmpeg program drains a decoder with a null packet.
                switch (r.decoder) {
                    .opus => |*dec| {
                        const n = dec.decodePacket(null, r.planes[0..r.channels]) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.InvalidData => return false,
                        };
                        if (n == 0) return false;
                        const kept = r.discard.apply(n, null) orelse return false;
                        r.errors.frames_decoded += 1;
                        r.pending = .{ .planes = kept };
                        return true;
                    },
                    else => {},
                }
                return false;
            };
            if (p.stream != r.stream) continue;
            switch (r.decoder) {
                .none => unreachable,
                .flac => |*state| state.decoder.send(p.data, p.pts),
                .vorbis => |*dec| {
                    // The planes allocated at open: a decoder whose channels
                    // or block sizes changed since refuses them (`planesFit`),
                    // where slicing by its own count read unset planes.
                    const samples = dec.decodePacket(p.data, r.planes[0..r.channels]) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidData => {
                            diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{});
                            r.errors.decode_errors += 1;
                            continue;
                        },
                    };
                    const n = samples orelse continue;
                    // avctx->internal->skip_samples, set by the first frame.
                    if (dec.takeSkip()) |skip| r.discard.skip = skip;
                    const kept = r.discard.apply(n, p.skip) orelse continue;
                    r.errors.frames_decoded += 1;
                    r.pending = .{ .planes = kept };
                    return true;
                },
                .opus => |*dec| {
                    const n = dec.decodePacket(p.data, r.planes[0..r.channels]) catch |err| switch (err) {
                        error.InvalidData => {
                            diagnostics.report(r.sink, .err, "Decoding error: Invalid data found when processing input", .{});
                            r.errors.decode_errors += 1;
                            continue;
                        },
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    if (n == 0) continue;
                    const kept = r.discard.apply(n, p.skip) orelse continue;
                    r.errors.frames_decoded += 1;
                    r.pending = .{ .planes = kept };
                    return true;
                },
            }
        }
    }

    /// Checks the decoding's error rate, and that the stream decoded to
    /// the count found ahead.
    pub fn finish(r: *DecodedReader) ReadError!void {
        std.debug.assert(r.pendingFrames() == 0);
        try r.errors.check();
        if (r.expected) |expected| {
            if (r.delivered != expected) return error.FrameCountMismatch;
        }
    }
};

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");

/// Every sample `r` decodes, as `readData` gives them.
fn decodeAll(r: *DecodedReader, out: *std.ArrayList(u8)) !DecodedReader.Header {
    const header = try r.readHeader();
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = try r.readData(&scratch);
        if (got.len == 0) break;
        try out.appendSlice(testing.allocator, got);
    }
    try r.finish();
    return header;
}

/// The samples FFmpeg's decoder keeps for `name`: the sum of the `D`
/// lines of its block in `vectors` (vectors/vorbis.txt, vectors/opus.txt).
fn vectorSamples(vectors: []const u8, name: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var in_block = false;
    var total: u64 = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "F ")) {
            if (in_block) break;
            in_block = std.mem.eql(u8, line[2..], name);
        } else if (in_block and std.mem.startsWith(u8, line, "D ")) {
            var fields = std.mem.splitScalar(u8, line[2..], ' ');
            total += try std.fmt.parseInt(u64, fields.next().?, 10);
        }
    }
    if (!in_block and total == 0) return error.MissingVector;
    return total;
}

test "a non-seekable input decodes to the seekable decoding's samples, FFmpeg's count" {
    const gpa = testing.allocator;
    const cases = [_]struct { name: []const u8, bytes: []const u8, vectors: ?[]const u8 }{
        .{ .name = "ogg_vorbis_ffmpeg_22k_short", .bytes = fixtures.ogg.bytes("ogg_vorbis_ffmpeg_22k_short"), .vectors = @embedFile("../testing/vectors/vorbis.txt") },
        .{ .name = "ogg_opus_ffmpeg_mono", .bytes = fixtures.ogg.bytes("ogg_opus_ffmpeg_mono"), .vectors = @embedFile("../testing/vectors/opus.txt") },
        .{ .name = "ogg_flac_stereo", .bytes = fixtures.ogg.bytes("ogg_flac_stereo"), .vectors = null },
    };
    for (cases) |case| {
        var streamed: std.ArrayList(u8) = .empty;
        defer streamed.deinit(gpa);
        var stream_reader: std.Io.Reader = .fixed(case.bytes);
        var r = DecodedReader.init(gpa, &stream_reader, null, null);
        defer r.deinit();
        const header = try decodeAll(&r, &streamed);
        // Without seeking there is no count ahead.
        try testing.expectEqual(null, header.frame_count);

        var seeked: std.ArrayList(u8) = .empty;
        defer seeked.deinit(gpa);
        var file_reader: std.Io.Reader = .fixed(case.bytes);
        var s = DecodedReader.init(gpa, &file_reader, .fixed(&file_reader), null);
        defer s.deinit();
        const seeked_header = try decodeAll(&s, &seeked);

        try testing.expect(streamed.items.len > 0);
        try testing.expectEqualSlices(u8, seeked.items, streamed.items);
        try testing.expectEqual(seeked_header.frame_count, r.delivered);
        if (case.vectors) |vectors| try testing.expectEqual(try vectorSamples(vectors, case.name), r.delivered);
    }
}

test "a decoder that refuses the headers fails opening without freeing its unset state" {
    const gpa = testing.allocator;
    // The mono Opus fixture whose OpusHead says mapping family 2
    // (ambisonics; one stream, none coupled, channel 0 from stream 0),
    // which the port refuses (notes.md "Mapping families").
    const mono = fixtures.ogg.bytes("ogg_opus_ffmpeg_mono");
    const old_page = 27 + 1 + 19;
    try testing.expectEqual(19, mono[27]);
    const fam2 = try gpa.alloc(u8, mono.len + 3);
    defer gpa.free(fam2);
    @memcpy(fam2[0..27], mono[0..27]);
    fam2[27] = 22;
    @memcpy(fam2[28..][0..19], mono[28..][0..19]);
    fam2[28 + 18] = 2;
    fam2[28 + 19 ..][0..3].* = .{ 1, 0, 0 };
    @memcpy(fam2[old_page + 3 ..], mono[old_page..]);
    @memset(fam2[22..26], 0);
    var crc: ogg.Crc = .init();
    crc.update(fam2[0 .. old_page + 3]);
    std.mem.writeInt(u32, fam2[22..26], crc.final(), .little);

    const cases = [_]struct { bytes: []const u8, err: Error }{
        .{ .bytes = fixtures.ogg.bytes("ogg_vorbis_stereo"), .err = error.InvalidVorbis },
        .{ .bytes = fam2, .err = error.UnsupportedFormat },
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |seekable| {
            var reader: std.Io.Reader = .fixed(case.bytes);
            var r = DecodedReader.init(gpa, &reader, if (seekable) .fixed(&reader) else null, null);
            defer r.deinit();
            try testing.expectError(case.err, r.readHeader());
        }
    }
}

/// A native FLAC file's packets remuxed into Ogg by the port's Ogg muxer,
/// owned by the caller: the Ogg FLAC form of a native FLAC fixture.
fn oggFromFlac(gpa: std.mem.Allocator, flac_bytes: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(flac_bytes);
    var d = try flac_format.Demuxer.init(gpa, &reader);
    defer d.deinit();
    const streaminfo = d.info.extradata orelse return error.TestUnexpectedResult;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var mux = try oggmux.Muxer.init(gpa, &out.writer, &.{.{ .codec = .flac, .sample_rate = d.info.sample_rate, .extradata = &streaminfo }}, .{});
    defer mux.deinit();
    try mux.writeHeader();
    var pts: i64 = 0;
    while (try d.next()) |p| {
        const duration = p.duration orelse 0;
        try mux.writePacket(0, p.data, pts, duration);
        pts += duration;
    }
    try mux.finish();
    return out.toOwnedSlice();
}

test "Ogg FLAC refuses a frame that changes the rate or channels, as native FLAC does" {
    const gpa = testing.allocator;
    // The remux itself keeps every frame: a stream without a change
    // decodes whole.
    const steady = try oggFromFlac(gpa, fixtures.flac.bytes("flac_constant_mono_8k"));
    defer gpa.free(steady);
    var steady_reader: std.Io.Reader = .fixed(steady);
    var whole = DecodedReader.init(gpa, &steady_reader, .fixed(&steady_reader), null);
    defer whole.deinit();
    var samples: std.ArrayList(u8) = .empty;
    defer samples.deinit(gpa);
    _ = try decodeAll(&whole, &samples);
    try testing.expectEqual(256, whole.delivered);

    // 44.1 kHz, then a 48 kHz frame; mono, then a stereo frame. Delivering
    // the second frame would give its samples the opened format.
    inline for (.{ "flac_rate_change", "flac_channel_change" }) |name| {
        const bytes = try oggFromFlac(gpa, fixtures.flac.bytes(name));
        defer gpa.free(bytes);
        for ([_]bool{ false, true }) |seekable| {
            var reader: std.Io.Reader = .fixed(bytes);
            var r = DecodedReader.init(gpa, &reader, if (seekable) .fixed(&reader) else null, null);
            defer r.deinit();
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            try testing.expectError(error.UnsupportedFormat, decodeAll(&r, &out));
            // Seekable, the counting pass refuses it while opening;
            // otherwise only the first frame was delivered.
            const delivered: u64 = if (seekable) 0 else 576;
            try testing.expectEqual(delivered, r.delivered);
        }
    }
}

const flac_format = @import("flac.zig");
const oggmux = @import("oggmux.zig");
const hostile = @import("../testing/hostile.zig");

const SweepInput = struct { bytes: []const u8, seekable: bool };

/// Opens and decodes `input.bytes` through a fresh demuxer and decoder,
/// seekable (the counting pass included) or not; any error but an
/// allocation failure fails the test.
fn decodeUnderFailures(gpa: std.mem.Allocator, input: SweepInput) !void {
    var reader: std.Io.Reader = .fixed(input.bytes);
    var r = DecodedReader.init(gpa, &reader, if (input.seekable) .fixed(&reader) else null, null);
    defer r.deinit();
    _ = r.readHeader() catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = r.readData(&scratch) catch |err| return if (err == error.OutOfMemory) err else error.TestUnexpectedResult;
        if (got.len == 0) break;
    }
    r.finish() catch return error.TestUnexpectedResult;
}

test "an Ogg stream decoded frees everything under every allocation and remap failure" {
    // Each codec once with the counting pass or once without, bounded for
    // Debug: a full Vorbis sweep with the counting pass takes 600 runs of
    // its setup. The decoders' own sweeps (vorbis.zig, opusdec.zig) cover
    // their headers and packets.
    const Case = struct { name: []const u8, seekable: bool, remaps: hostile.Remaps };
    const cases = [_]Case{
        .{ .name = "ogg_flac_stereo", .seekable = false, .remaps = .both },
        .{ .name = "ogg_flac_stereo", .seekable = true, .remaps = .both },
        .{ .name = "ogg_vorbis_ffmpeg_22k_short", .seekable = false, .remaps = .fail },
        .{ .name = "ogg_opus_hybrid", .seekable = true, .remaps = .fail },
        .{ .name = "ogg_opus_mapped", .seekable = false, .remaps = .fail },
    };
    inline for (cases) |case| {
        const input: SweepInput = .{ .bytes = fixtures.ogg.bytes(case.name), .seekable = case.seekable };
        try hostile.checkAllocationFailuresWith(testing.allocator, case.remaps, input, decodeUnderFailures);
    }
}

/// The fuzz entry's input: whether the input seeks (the counting pass and
/// the duration scan), whether the reader takes the samples as they come
/// (`expected` cleared), then the file.
fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    const seekable = smith.value(bool);
    const uncounted = smith.value(bool);
    var input: [16384]u8 = undefined;
    const len = smith.slice(&input);
    var reader: std.Io.Reader = .fixed(input[0..len]);
    var r = DecodedReader.init(testing.allocator, &reader, if (seekable) .fixed(&reader) else null, null);
    defer r.deinit();
    _ = r.readHeader() catch |err| return if (err == error.OutOfMemory) err else {};
    if (uncounted) r.expected = null;
    var scratch: [4096]u8 = undefined;
    while (true) {
        const got = r.readData(&scratch) catch |err| return if (err == error.OutOfMemory) err else {};
        if (got.len == 0) break;
    }
    r.finish() catch {};
}

fn fuzzSeed(gpa: std.mem.Allocator, bytes: []const u8, seekable: bool, uncounted: bool) ![]u8 {
    var s: hostile.Seed = .{};
    errdefer s.deinit(gpa);
    try s.value(gpa, @intFromBool(seekable));
    try s.value(gpa, @intFromBool(uncounted));
    try s.slice(gpa, bytes);
    return s.toOwnedSlice(gpa);
}

test "fuzz: an Ogg stream decoded from arbitrary input" {
    const gpa = testing.allocator;
    const Case = struct { name: []const u8, seekable: bool, uncounted: bool };
    const cases = [_]Case{
        .{ .name = "ogg_vorbis_ffmpeg_22k_short", .seekable = false, .uncounted = false },
        .{ .name = "ogg_vorbis_ffmpeg_8k", .seekable = true, .uncounted = false },
        .{ .name = "ogg_vorbis_granule_zero", .seekable = true, .uncounted = true },
        .{ .name = "ogg_opus_hybrid", .seekable = true, .uncounted = false },
        .{ .name = "ogg_opus_multistream", .seekable = false, .uncounted = false },
        .{ .name = "ogg_opus_ffmpeg_delay10", .seekable = true, .uncounted = true },
        .{ .name = "ogg_chained_opus", .seekable = true, .uncounted = false },
        .{ .name = "ogg_flac_stereo", .seekable = false, .uncounted = false },
        .{ .name = "ogg_page_without_granule", .seekable = true, .uncounted = false },
    };
    var seeds: [cases.len][]u8 = undefined;
    var made: usize = 0;
    defer for (seeds[0..made]) |s| gpa.free(s);
    inline for (cases, 0..) |case, i| {
        seeds[i] = try fuzzSeed(gpa, fixtures.ogg.bytes(case.name), case.seekable, case.uncounted);
        made += 1;
    }
    try testing.fuzz({}, fuzzOne, .{ .corpus = &seeds });
}
