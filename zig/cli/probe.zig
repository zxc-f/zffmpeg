// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! zffprobe: validates one WAV, Wave64, AU, AIFF, CAF or raw PCM stream and reports
//! it as `key=value` lines.
//!
//!     zffprobe [-f <format>] [-sample_rate <rate>] [-ch_layout <layout>] <file | ->
//!
//! The container is detected from content as FFmpeg's probing would
//! (`av.detect`, T16), with the file name's extension as FFmpeg's fallback
//! for raw PCM (T22c); `-f` forces it, as `ffprobe -f` does. Raw PCM has no
//! header: `-sample_rate` and `-ch_layout` give its stream, FFmpeg's raw
//! demuxer options, 44100 Hz mono by default; for any other format they are a
//! usage error.
//! `-` reads standard input, which may be a pipe. The report goes to stdout
//! only after the whole stream validates; diagnostics go to stderr. The output
//! schema and exit codes are documented in port.md ("Initial probe output"):
//! 0 success or help, 1 usage, 2 invalid or truncated media, 3 unsupported
//! media, 4 I/O failure, 5 resource or allocation limit, 6 cancellation.
//! Parsing lives in the `av` library; this file only handles arguments,
//! files and output.

const std = @import("std");
const av = @import("av");
const status = @import("status.zig");
const ExitStatus = status.ExitStatus;
const printError = status.printError;

const usage = "usage: zffprobe [-f <format>] [-sample_rate <rate>] [-ch_layout <layout>] <file | ->\n";
const help = usage ++
    \\
    \\Validates a WAV, Wave64, AU, AIFF, CAF or raw PCM stream (standard input with -)
    \\and prints its stream parameters as key=value lines. The format is detected
    \\from content, or for raw PCM from the name (.sb, .ub, .al, .ul, .sw), or
    \\forced with -f (wav, w64, au, aiff, caf, or a raw format such as s16le).
    \\-sample_rate and -ch_layout describe raw PCM, 44100 Hz mono by default.
    \\Exit codes: 0 success, 1 usage, 2 invalid or truncated media,
    \\3 unsupported media, 4 I/O failure, 5 resource limit, 6 cancellation.
    \\
;

/// Every resource is released before `main` returns its status.
pub fn main(init: std.process.Init) u8 {
    return @backingInt(run(init));
}

fn run(init: std.process.Init) ExitStatus {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(io, "zffprobe: out of memory\n", .{});
        return .limit;
    };
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        return status.writeStdout(io, "zffprobe", help);
    }
    // Options with their values, then the input. An option given again
    // replaces its value, as FFmpeg's last one wins; one without a value
    // is FFmpeg's missing argument, a usage error.
    var format_name: ?[]const u8 = null;
    var rate_text: ?[]const u8 = null;
    var layout_text: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const slot = if (std.mem.eql(u8, args[i], "-f"))
            &format_name
        else if (std.mem.eql(u8, args[i], "-sample_rate"))
            &rate_text
        else if (std.mem.eql(u8, args[i], "-ch_layout"))
            &layout_text
        else
            break;
        if (i + 1 == args.len) {
            printError(io, "zffprobe: missing value for {s}\n" ++ usage, .{args[i]});
            return .usage;
        }
        slot.* = args[i + 1];
    }
    if (i + 1 != args.len) {
        printError(io, usage, .{});
        return .usage;
    }
    const format: ?av.detect.Container = if (format_name) |name|
        av.formats.findDemuxer(name) orelse {
            printError(io, "zffprobe: {s}: unsupported input format\n", .{name});
            return .unsupported;
        }
    else
        null;
    const rate: ?status.RawRate = if (rate_text) |text| .{ .option = text } else null;
    const raw_params = switch (status.rawParams(io, "zffprobe", rate, layout_text, null)) {
        .ok => |params| params,
        .failed => |exit| return exit,
    };
    const path = args[args.len - 1];
    const gpa = init.gpa;
    var tags: av.metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    const options: av.detect.Options = .{
        .source = .{ .format = format, .raw = raw_params },
        .tags = .{ .gpa = gpa, .dictionary = &tags },
    };
    var buffer: [av.file.default_buffer_len]u8 = undefined;
    const result = if (std.mem.eql(u8, path, "-"))
        av.file.probeFile(io, std.Io.File.stdin(), &buffer, .{}, options)
    else
        av.file.probePath(io, std.Io.Dir.cwd(), path, &buffer, .{}, options);
    const info = result catch |err| {
        if (err == error.UnusedOption) {
            printError(io, "zffprobe: {s}: -sample_rate and -ch_layout apply only to raw PCM input\n", .{path});
        } else {
            printError(io, "zffprobe: {s}: {t}\n", .{ path, err });
        }
        return status.of(err);
    };

    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    // The allocating writer fails only when it cannot grow.
    writeReport(&report.writer, info, &tags) catch {
        printError(io, "zffprobe: out of memory\n", .{});
        return .limit;
    };
    return status.writeStdout(io, "zffprobe", report.writer.buffered());
}

/// The nine stream lines, then one `tag:<key>=<value>` line per tag in order
/// (T21c). Keys and values are written as stored, except that a backslash,
/// line feed and carriage return become `\\`, `\n` and `\r`, so each tag stays
/// on one line.
fn writeReport(out: *std.Io.Writer, info: av.detect.Probed, tags: *const av.metadata.Dictionary) std.Io.Writer.Error!void {
    try writeStream(out, info);
    for (tags.items()) |tag| {
        try out.writeAll("tag:");
        try writeEscaped(out, tag.key);
        try out.writeByte('=');
        try writeEscaped(out, tag.value);
        try out.writeByte('\n');
    }
}

fn writeEscaped(out: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    for (bytes) |byte| switch (byte) {
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(byte),
    };
}

fn writeStream(out: *std.Io.Writer, info: av.detect.Probed) std.Io.Writer.Error!void {
    const format = info.format;
    try out.print(
        \\format={s}
        \\codec={s}
        \\sample_fmt={s}
        \\channels={d}
        \\channel_layout=
    , .{
        info.container.name(),
        info.codec.name(),
        // As ffprobe without a decoder for the codec (MPEG audio, T29a).
        if (info.decoded) format.sample_format.name() else "unknown",
        format.channelCount(),
    });
    // As ffprobe: `unknown` for an unspecified layout, else FFmpeg's description.
    switch (format.layout) {
        .unspecified => try out.writeAll("unknown"),
        .native, .custom => try format.layout.describe(out),
    }
    try out.print("\nsample_rate={d}\n", .{format.sample_rate});
    if (info.time_base_duration) |d| {
        // The duration in the stream's own time base, ffprobe's duration_ts.
        try out.print("nb_samples={d}\nduration_num={d}\nduration_den={d}\n", .{ info.frame_count.?, d.ts, d.den });
    } else if (info.frame_count) |frames| {
        try out.print("nb_samples={d}\nduration_num={d}\nduration_den={d}\n", .{ frames, frames, format.sample_rate });
    } else {
        // Unknown-length data, which zffprobe does not enable yet: no count
        // or duration, as ffprobe's N/A.
        try out.writeAll("nb_samples=N/A\nduration_num=N/A\nduration_den=N/A\n");
    }
}
