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
    const result = if (av.detect.probeHead(bytes, std.fs.path.basename(args[3])) == .flac)
        hashFlac(io, gpa, kind, mode, bytes, out)
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
