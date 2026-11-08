// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Test driver for the frame and stream hash comparison (TODO.md T19b). It
//! prints what FFmpeg's hash muxers would print for the port's packets, so
//! compare.py can set the text beside the ffmpeg program's:
//!
//!     hash-driver <framecrc|framemd5|streamhash> <copy|decode> <input>
//!
//! For FLAC input, `copy` hashes the demuxer's packets with STREAMINFO as
//! extradata (`ffmpeg -i <input> -c copy -f <muxer>`) and `decode` the
//! decoder's frames as pcm_s16le packets, one per frame (`ffmpeg -i <input>
//! -c:a pcm_s16le -f <muxer>`); decoding errors are reported on stderr and
//! skipped, as the ffmpeg program skips them. For a PCM container
//! (WAV, Wave64, AU, AIFF, CAF), only `streamhash` applies, since FFmpeg's
//! PCM packet sizes are not modeled: `copy` hashes the encoded samples
//! (av.convert's copy into the codec's raw format) and `decode` the samples
//! converted to s16 (av.convert into s16le); copying s64, which has no raw
//! format, is `NoRawFormat`. The text is what FFmpeg writes
//! with `-fflags +bitexact`. Exit status: 0 on success, 1 for usage errors,
//! 2 for any other failure, with one diagnostic line on stderr.
//!
//! compare.py runs it. It is a test tool, not a product: `zig build
//! test-tools` installs it, and `zig build test` compiles it.

const std = @import("std");
const av = @import("av");

const usage = "usage: hash-driver <framecrc|framemd5|streamhash> <copy|decode> <input>\n";
/// Inputs are fixture-sized.
const max_input_bytes = 64 << 20;

const Status = enum(u8) {
    ok = 0,
    usage = 1,
    failure = 2,
};

const Mode = enum { copy, decode };

pub fn main(init: std.process.Init) u8 {
    return @backingInt(run(init));
}

fn run(init: std.process.Init) Status {
    const io = init.io;
    const gpa = init.gpa;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(io, "hash-driver: out of memory\n", .{});
        return .failure;
    };
    if (args.len != 4) return usageError(io);
    const kind = av.framehash.Kind.fromName(args[1]) orelse return usageError(io);
    const mode = std.meta.stringToEnum(Mode, args[2]) orelse return usageError(io);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, args[3], gpa, .limited(max_input_bytes)) catch |err| {
        printError(io, "hash-driver: {s}: {t}\n", .{ args[3], err });
        return .failure;
    };
    defer gpa.free(bytes);

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    const head = av.detect.probeHead(bytes, std.fs.path.basename(args[3]));
    const result = if (head == .flac)
        hashFlac(io, gpa, kind, mode, bytes, out)
    else if (head == .ogg)
        if (mode == .copy) hashOgg(gpa, kind, bytes, out) else error.OggNotDecoded
    else if (head == .mp3)
        if (mode == .copy) hashMp3(gpa, kind, bytes, out) else error.Mp3NotDecoded
    else if (head == .aac)
        if (mode == .copy) hashAac(gpa, kind, bytes, out) else error.AacNotDecoded
    else if (head == .mov)
        if (mode == .copy) hashMov(gpa, kind, bytes, out) else error.MovNotDecoded
    else if (kind != .streamhash)
        error.PcmNeedsStreamhash
    else
        hashPcm(gpa, mode, bytes, std.fs.path.basename(args[3]), out);
    result catch |err| {
        printError(io, "hash-driver: {s}: {t}\n", .{ args[3], err });
        return .failure;
    };
    out.flush() catch {
        printError(io, "hash-driver: cannot write the output\n", .{});
        return .failure;
    };
    return .ok;
}

/// MPEG audio (T29a), `ffmpeg -i <input> -c copy -f <muxer>`: the frames
/// the demuxer's parser splits, with the codec, rate and layout of the
/// parser's context after the read-ahead, and the gapless side data.
fn hashMp3(gpa: std.mem.Allocator, kind: av.framehash.Kind, bytes: []const u8, out: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = try av.mp3.Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
    defer d.deinit();
    var layer = av.demux.Layer(av.mp3.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    const params = try layer.codecParams(0);
    const tb = av.mp3.time_base;
    var w: av.framehash.Writer = .init(kind, out, .{
        .time_base = .{ .num = @intCast(tb.num), .den = @intCast(tb.den) },
        .codec = if (params.mpa_codec) |c| @tagName(c) else "mp3",
        .sample_rate = params.sample_rate,
        .layout = .default(params.channels),
        .extradata = null,
    });
    try w.writeHeader();
    while (layer.next() catch null) |p| {
        var skip: [10]u8 = @splat(0);
        var side: [1]av.framehash.SideData = undefined;
        var n: usize = 0;
        if (p.skip) |s| {
            std.mem.writeInt(u32, skip[0..4], s[0], .little);
            std.mem.writeInt(u32, skip[4..8], s[1], .little);
            side[n] = .{ .name = "Skip Samples", .data = &skip };
            n += 1;
        }
        try w.writePacketSide(.{
            .data = p.data,
            .time_base = .{ .num = @intCast(tb.num), .den = @intCast(tb.den) },
            .pts = p.pts,
            .dts = p.dts,
            .duration = p.duration,
            .flags = .{ .key = p.flags & 1 != 0 },
        }, side[0..n]);
    }
    try w.finish();
}

/// ADTS (T30a, T30b), `ffmpeg -i <input> -c copy -f <muxer>`: the frames
/// the AAC parser splits, with the rate and layout the decoder gave the
/// stream in the read-ahead.
fn hashAac(gpa: std.mem.Allocator, kind: av.framehash.Kind, bytes: []const u8, out: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = try av.aac.Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
    defer d.deinit();
    var layer = av.demux.Layer(av.aac.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    const params = try layer.codecParams(0);
    // No packet decoded in the read-ahead: the muxer's "sample rate not
    // set", zffprobe's refusal.
    if (params.sample_rate == 0 or params.channels == 0) return error.UnsupportedFormat;
    const tb = av.aac.time_base;
    var w: av.framehash.Writer = .init(kind, out, .{
        .time_base = .{ .num = @intCast(tb.num), .den = @intCast(tb.den) },
        .codec = "aac",
        .sample_rate = params.sample_rate,
        .layout = if (params.mask != 0) .{ .native = params.mask } else .{ .unspecified = std.math.cast(u8, params.channels) orelse return error.UnsupportedFormat },
        .extradata = null,
    });
    try w.writeHeader();
    while (layer.next() catch null) |p| {
        try w.writePacketSide(.{
            .data = p.data,
            .time_base = .{ .num = @intCast(tb.num), .den = @intCast(tb.den) },
            .pts = p.pts,
            .dts = p.dts,
            .duration = p.duration,
            .flags = .{ .key = p.flags & 1 != 0 },
        }, &.{});
    }
    try w.finish();
}

/// MP4 and QuickTime (T33a1, T33a3), `ffmpeg -i <input> -c copy -f
/// <muxer>`: the streams the program maps by default, video first
/// (map_auto_video: the largest picture, a track that had packets in the
/// read-ahead first, the default disposition, the first of equals; any
/// codec), then audio (map_auto_audio: the most channels, then the same
/// bonuses), never subtitles or data (framecrc has no codec for them); the
/// audio stream's layout the default for its count when it has none, each
/// stream's extradata. Their packets as the program copies them
/// (of_streamcopy, mux_fixup_ts): those before each stream's first
/// keyframe dropped, every timestamp shifted by the input's start time, an
/// audio packet's pts set to its dts, a dts after the pts or before the
/// stream's last replaced, a video packet without a duration given one
/// (guess_pkt_duration), with their flags and side data; and libavformat's
/// interleaving by dts (ff_interleave_packet_per_dts).
fn hashMov(gpa: std.mem.Allocator, kind: av.framehash.Kind, bytes: []const u8, out: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = try av.mov.Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
    defer d.deinit();
    var layer = av.demux.Layer(av.mov.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    var best_video: ?usize = null;
    var best_video_score: i64 = 0;
    var best_audio: ?usize = null;
    var best_audio_score: i64 = 0;
    for (0..d.streamCount()) |i| {
        const info = try av.mov.streamInfo(d, &layer, i);
        const had_packets: i64 = if (i < layer.states.items.len and layer.states.items[i].codec_info_nb_frames > 0) 100000000 else 0;
        const default: i64 = if (info.disposition & 1 != 0) 5000000 else 0;
        switch (info.media) {
            .video => {
                const score = @as(i64, info.video.width) * info.video.height + had_packets + default;
                if (score > best_video_score) {
                    best_video_score = score;
                    best_video = i;
                }
            },
            .audio => {
                const score = @as(i64, info.layout.channelCount()) + had_packets + default;
                if (score > best_audio_score) {
                    best_audio_score = score;
                    best_audio = i;
                }
            },
            .data, .subtitle => {},
        }
    }
    var inputs: [2]usize = undefined;
    var count: usize = 0;
    if (best_video) |i| {
        inputs[count] = i;
        count += 1;
    }
    if (best_audio) |i| {
        inputs[count] = i;
        count += 1;
    }
    if (count == 0) return error.UnsupportedFormat;
    var streams: [2]av.framehash.Stream = undefined;
    var copies: [2]CopyStream = undefined;
    for (inputs[0..count], 0..) |index, o| {
        const info = try av.mov.streamInfo(d, &layer, index);
        const tb: av.time.TimeBase = .{ .num = @intCast(info.time_base.num), .den = @intCast(info.time_base.den) };
        const video = info.media == .video;
        streams[o] = .{
            .time_base = tb,
            .codec = info.codec,
            .extradata = if (info.extradata.len != 0) info.extradata else null,
        };
        if (video) {
            // The stream's aspect ratio, else the codec's (0/1 without a
            // decoder).
            const sar: av.rational.Rational = if (info.video.sar.num != 0) info.video.sar else .{ .num = 0, .den = 1 };
            streams[o].video = .{ .width = info.video.width, .height = info.video.height, .sar_num = sar.num, .sar_den = sar.den };
        } else {
            streams[o].sample_rate = std.math.cast(u32, info.sample_rate) orelse return error.UnsupportedFormat;
            streams[o].layout = switch (info.layout) {
                .unspecified => |n| .default(n),
                else => info.layout,
            };
        }
        copies[o] = .{
            .input = index,
            .video = video,
            .time_base = info.time_base,
            .offset = if (layer.start_time == std.math.minInt(i64)) 0 else av.rational.rescaleQ(layer.start_time, .{ .num = 1, .den = 1000000 }, info.time_base),
            .avg_frame_rate = info.video.avg_frame_rate,
            .vp9 = std.mem.eql(u8, info.codec, "vp9") or std.mem.eql(u8, info.codec, "vp8"),
        };
    }
    var w = try av.framehash.Writer.initMany(kind, out, streams[0..count]);
    try w.writeHeader();
    var mux: Interleaver = .{ .gpa = gpa, .streams = copies[0..count], .writer = &w };
    defer mux.deinit();
    while (try layer.next()) |p| {
        const o = for (copies[0..count], 0..) |c, k| {
            if (c.input == p.stream) break k;
        } else continue;
        const c = &copies[o];
        if (!c.started and p.flags & av.demux.key_flag == 0) continue;
        c.started = true;
        // The program estimates a missing dts (not modelled).
        var dts = (p.dts orelse return error.MissingTimestamp) - c.offset;
        var pts: ?i64 = if (!c.video) dts else if (p.pts) |t| t - c.offset else null;
        // mux_fixup_ts: a dts after the pts, then one before the last
        // (framecrc allows equal ones).
        if (pts) |t| if (dts > t) {
            const clipped = std.math.clamp(c.last_mux_dts, t - 1, dts - 1) + 1;
            pts = clipped;
            dts = clipped;
        };
        if (c.last_mux_dts != std.math.minInt(i64) and dts < c.last_mux_dts) {
            if (pts) |t| if (t >= dts) {
                pts = @max(t, c.last_mux_dts);
            };
            dts = c.last_mux_dts;
        }
        c.last_mux_dts = dts;
        var duration = p.duration;
        if (c.video and duration == 0) {
            const avg = c.avg_frame_rate;
            if (avg.num > 0 and avg.den > 0) {
                duration = av.rational.rescaleQ(1, .{ .num = avg.den, .den = avg.num }, c.time_base);
            } else if (@as(i64, c.time_base.num) * 1000 > c.time_base.den) duration = 1;
        }
        try mux.add(o, p, dts, pts orelse dts, duration);
    }
    try mux.flushAll();
    try w.finish();
}

/// An output stream of the program's copy.
const CopyStream = struct {
    input: usize,
    video: bool,
    time_base: av.rational.Rational,
    /// The input's start time in the stream's time base.
    offset: i64,
    avg_frame_rate: av.rational.Rational,
    /// VP8 and VP9 streams without a buffered packet do not hold back
    /// libavformat's 10-second rule.
    vp9: bool,
    started: bool = false,
    last_mux_dts: i64 = std.math.minInt(i64),
};

/// A packet libavformat's interleaver holds, its bytes owned.
const Buffered = struct {
    stream: usize,
    data: []u8,
    pts: i64,
    dts: i64,
    duration: i64,
    flags: u32,
    side: [3]av.framehash.SideData = undefined,
    side_count: usize = 0,
    owned_side: [3][]u8 = undefined,

    fn deinit(b: *Buffered, gpa: std.mem.Allocator) void {
        gpa.free(b.data);
        for (b.owned_side[0..b.side_count]) |x| gpa.free(x);
    }

    fn addSide(b: *Buffered, name: []const u8, data: []const u8, gpa: std.mem.Allocator) !void {
        return addSideImpl(b, name, data, gpa);
    }
};

/// ff_interleave_packet_per_dts: a list ordered by dts (ties by output
/// index), each packet inserted after its stream's last; the head is
/// written while every stream has a packet buffered, or when the newest
/// is more than 10 seconds after it; the rest at the end.
const Interleaver = struct {
    gpa: std.mem.Allocator,
    streams: []const CopyStream,
    writer: *av.framehash.Writer,
    list: std.ArrayList(Buffered) = .empty,
    head: usize = 0,
    /// Each stream's last buffered packet (`last_in_packet_buffer`).
    last: [2]?usize = .{ null, null },

    fn deinit(m: *Interleaver) void {
        for (m.list.items[m.head..]) |*b| b.deinit(m.gpa);
        m.list.deinit(m.gpa);
    }

    /// interleave_compare_dts: `next` comes after `pkt`.
    fn after(m: *const Interleaver, next: *const Buffered, pkt: *const Buffered) bool {
        const comp = av.rational.compareTs(next.dts, m.streams[next.stream].time_base, pkt.dts, m.streams[pkt.stream].time_base);
        if (comp == 0) return pkt.stream < next.stream;
        return comp > 0;
    }

    fn add(m: *Interleaver, o: usize, p: av.demux.Packet, dts: i64, pts: i64, duration: i64) !void {
        var b: Buffered = .{ .stream = o, .data = try m.gpa.dupe(u8, p.data), .pts = pts, .dts = dts, .duration = duration, .flags = p.flags };
        errdefer b.deinit(m.gpa);
        // The packet's side data in its order: the demuxer's palette, its
        // new extradata, then libavformat's skip samples.
        if (p.palette) |x| try b.addSide("Palette", x, m.gpa);
        if (p.new_extradata) |x| try b.addSide("New Extradata", x, m.gpa);
        if (p.skip) |sk| {
            var skip: [10]u8 = @splat(0);
            std.mem.writeInt(u32, skip[0..4], sk[0], .little);
            std.mem.writeInt(u32, skip[4..8], sk[1], .little);
            try b.addSide("Skip Samples", &skip, m.gpa);
        }
        // ff_interleave_add_packet.
        var at = if (m.last[o]) |l| l + 1 else m.head;
        if (at < m.list.items.len and m.after(&m.list.items[m.list.items.len - 1], &b)) {
            while (!m.after(&m.list.items[at], &b)) at += 1;
        } else at = m.list.items.len;
        try m.list.insert(m.gpa, at, b);
        for (&m.last) |*l| if (l.*) |x| if (x >= at) {
            l.* = x + 1;
        };
        m.last[o] = at;
        try m.drain(false);
    }

    fn flushAll(m: *Interleaver) !void {
        try m.drain(true);
    }

    fn drain(m: *Interleaver, eof: bool) !void {
        while (m.head < m.list.items.len) {
            var stream_count: usize = 0;
            var noninterleaved: usize = 0;
            for (m.streams, 0..) |c, i| {
                if (m.last[i] != null) stream_count += 1 else if (!c.vp9) noninterleaved += 1;
            }
            var flush = eof or stream_count == m.streams.len;
            if (!flush and m.streams.len == stream_count + noninterleaved) {
                const top = &m.list.items[m.head];
                const us: av.rational.Rational = .{ .num = 1, .den = 1000000 };
                const top_dts = av.rational.rescaleQ(top.dts, m.streams[top.stream].time_base, us);
                var delta: i64 = std.math.minInt(i64);
                for (m.last[0..m.streams.len], 0..) |l, i| {
                    const x = l orelse continue;
                    delta = @max(delta, av.rational.rescaleQ(m.list.items[x].dts, m.streams[i].time_base, us) -% top_dts);
                }
                if (delta > 10000000) flush = true;
            }
            if (stream_count == 0 or !flush) return;
            var b = m.list.items[m.head];
            if (m.last[b.stream] == m.head) m.last[b.stream] = null;
            m.head += 1;
            defer b.deinit(m.gpa);
            try m.writer.writePacketSide(.{
                .data = b.data,
                .time_base = .{ .num = @intCast(m.streams[b.stream].time_base.num), .den = @intCast(m.streams[b.stream].time_base.den) },
                .pts = b.pts,
                .dts = b.dts,
                .duration = b.duration,
                .stream_index = @intCast(b.stream),
                .flags = .{
                    .key = b.flags & av.demux.key_flag != 0,
                    .corrupt = b.flags & av.demux.corrupt_flag != 0,
                    .discard = b.flags & av.demux.discard_flag != 0,
                    .disposable = b.flags & 0x10 != 0,
                },
            }, b.side[0..b.side_count]);
            // The written entries are dropped once they are half the list.
            if (m.head * 2 >= m.list.items.len) {
                const keep = m.list.items.len - m.head;
                std.mem.copyForwards(Buffered, m.list.items[0..keep], m.list.items[m.head..]);
                m.list.shrinkRetainingCapacity(keep);
                for (&m.last) |*l| if (l.*) |x| {
                    l.* = x - m.head;
                };
                m.head = 0;
            }
        }
    }
};

fn addSideImpl(b: *Buffered, name: []const u8, data: []const u8, gpa: std.mem.Allocator) !void {
    const copy = try gpa.dupe(u8, data);
    b.owned_side[b.side_count] = copy;
    b.side[b.side_count] = .{ .name = name, .data = copy };
    b.side_count += 1;
}

/// Ogg (T27a), `ffmpeg -i <input> -c copy -f <muxer>`: the input read
/// as the ffmpeg program opens a file, the one audio stream it maps, its
/// layout the default for its channel count, as the program gives a copied
/// stream without one, and each packet's side data.
fn hashOgg(gpa: std.mem.Allocator, kind: av.framehash.Kind, bytes: []const u8, out: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = try av.ogg.Demuxer.initSeekable(gpa, &reader, .fixed(&reader));
    defer d.deinit();
    var layer = av.demux.Layer(av.ogg.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    var chosen: ?usize = null;
    for (0..d.streamCount()) |i| {
        if (d.stream(i).codec == null) continue;
        // More than one audio stream needs the program's stream choice,
        // which the driver does not model.
        if (chosen != null) return error.SeveralAudioStreams;
        chosen = i;
    }
    const index = chosen orelse return error.NoAudioStream;
    const info = d.stream(index);
    const tb = info.time_base;
    var w: av.framehash.Writer = .init(kind, out, .{
        .time_base = .{ .num = @intCast(tb.num), .den = @intCast(tb.den) },
        .codec = @tagName(info.codec.?),
        .sample_rate = info.sample_rate,
        .layout = .default(info.channels),
        .extradata = if (info.extradata.items.len > 0) info.extradata.items else null,
    });
    try w.writeHeader();
    // The program ends the input at a demuxing error ("Error during
    // demuxing") and keeps what it read.
    while (layer.next() catch null) |p| {
        if (p.stream != index) continue;
        var skip: [10]u8 = @splat(0);
        var side: [3]av.framehash.SideData = undefined;
        var n: usize = 0;
        if (p.skip) |s| {
            std.mem.writeInt(u32, skip[0..4], s[0], .little);
            std.mem.writeInt(u32, skip[4..8], s[1], .little);
            side[n] = .{ .name = "Skip Samples", .data = &skip };
            n += 1;
        }
        if (p.new_metadata) |m| {
            side[n] = .{ .name = "Strings Metadata", .data = m };
            n += 1;
        }
        if (p.new_extradata) |e| {
            side[n] = .{ .name = "New Extradata", .data = e };
            n += 1;
        }
        try w.writePacketSide(.{
            .data = p.data,
            .time_base = .{ .num = @intCast(tb.num), .den = @intCast(tb.den) },
            .pts = p.pts,
            .dts = p.dts,
            .duration = p.duration,
            .flags = .{ .key = p.flags & 1 != 0 },
        }, side[0..n]);
    }
    try w.finish();
}

fn hashFlac(io: std.Io, gpa: std.mem.Allocator, kind: av.framehash.Kind, mode: Mode, bytes: []const u8, out: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var demuxer = try av.flac.Demuxer.init(gpa, &reader);
    defer demuxer.deinit();
    const info = demuxer.info;
    var stream: av.framehash.Stream = .{
        .time_base = info.time_base,
        .codec = "flac",
        .sample_rate = info.sample_rate,
        .layout = info.layout,
        .extradata = if (info.extradata != null) &info.extradata.? else null,
    };
    // Decoded packets take the encoder's 1/rate time base, as the ffmpeg
    // program's output stream does.
    const decoded_tb = try av.time.TimeBase.ofSampleRate(info.sample_rate);
    if (mode == .decode) {
        stream.codec = if (info.bps > 16) "pcm_s32le" else "pcm_s16le";
        stream.extradata = null;
        stream.time_base = decoded_tb;
    }
    var w: av.framehash.Writer = .init(kind, out, stream);
    try w.writeHeader();
    var decoder = try av.flac.decoder.Decoder.init(gpa, info.stream_info);
    defer decoder.deinit();
    var pcm: std.ArrayList(u8) = .empty;
    defer pcm.deinit(gpa);
    while (try demuxer.next()) |p| {
        if (mode == .copy) {
            try w.writePacket(p);
            continue;
        }
        decoder.send(p.data, p.pts);
        while (true) {
            const frame = decoder.receive() catch |err| {
                printError(io, "hash-driver: decoding error: {t}\n", .{err});
                continue;
            } orelse break;
            pcm.clearRetainingCapacity();
            switch (frame.samples) {
                inline else => |samples| for (samples) |s| {
                    var le: [@sizeOf(@TypeOf(s))]u8 = undefined;
                    std.mem.writeInt(@TypeOf(s), &le, s, .little);
                    try pcm.appendSlice(gpa, &le);
                },
            }
            const pts = try av.time.rescaleTimestamp(frame.pts, info.time_base, decoded_tb, .nearest);
            try w.writePacket(.{
                .data = pcm.items,
                .time_base = decoded_tb,
                .pts = pts,
                .dts = pts,
                .duration = frame.nb_samples,
                .flags = .{ .key = true },
            });
        }
    }
    try w.finish();
}

fn hashPcm(gpa: std.mem.Allocator, mode: Mode, bytes: []const u8, file_name: []const u8, out: *std.Io.Writer) !void {
    // The name gives the demuxers' extension hints, as the ffmpeg program's
    // input has them.
    const source: av.detect.Source = .{ .file_name = file_name, .length = bytes.len };
    var probe_reader: std.Io.Reader = .fixed(bytes);
    const probed = try av.detect.probeWith(&probe_reader, .{}, .{ .source = source });
    // The codec's raw format, FFmpeg's name for it without `pcm_`.
    const raw_name = if (mode == .copy) probed.codec.name()["pcm_".len..] else "s16le";
    const output = av.formats.findMuxer(raw_name) orelse return error.NoRawFormat;
    var converted: std.Io.Writer.Allocating = .init(gpa);
    defer converted.deinit();
    var reader: std.Io.Reader = .fixed(bytes);
    const summary = try av.convert.convert(&reader, &converted.writer, .{
        .output = output,
        .mode = if (mode == .copy) .copy else .transcode,
        .input = source,
        .gpa = gpa,
    }, .{});
    const format = summary.outputFormat();
    var w: av.framehash.Writer = .init(.streamhash, out, .{
        .time_base = format.timeBase(),
        .codec = summary.output_codec.name(),
        .sample_rate = format.sample_rate,
        .layout = format.layout,
    });
    try w.writeHeader();
    try w.writePacket(.{ .data = converted.written(), .time_base = format.timeBase() });
    try w.finish();
}

fn usageError(io: std.Io) Status {
    printError(io, usage, .{});
    return .usage;
}

fn printError(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr.interface.print(format, args) catch return;
    stderr.interface.flush() catch return;
}
