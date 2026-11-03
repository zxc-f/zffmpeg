// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! zffprobe: validates one WAV stream and reports it as `key=value` lines.
//!
//!     zffprobe <file.wav | ->
//!
//! `-` reads standard input, which may be a pipe. The report goes to stdout
//! only after the whole stream validates; diagnostics go to stderr. The output
//! schema and exit codes are documented in port.md ("Initial probe output"):
//! 0 success or help, 1 usage, 2 invalid or truncated media, 3 unsupported
//! media, 4 I/O failure, 5 resource or allocation limit, 6 cancellation.
//! Parsing lives in the `av` library; this file only handles arguments,
//! files and output.

const std = @import("std");
const av = @import("av");

const usage = "usage: zffprobe <file.wav | ->\n";
const help = usage ++
    \\
    \\Validates a WAV stream (standard input with -) and prints its stream
    \\parameters as key=value lines. Exit codes: 0 success, 1 usage,
    \\2 invalid or truncated media, 3 unsupported media, 4 I/O failure,
    \\5 resource limit, 6 cancellation.
    \\
;

const exit_ok = 0;
const exit_usage = 1;
const exit_invalid = 2;
const exit_unsupported = 3;
const exit_io = 4;
const exit_limit = 5;
const exit_canceled = 6;

/// Every resource is released before `main` returns its status.
pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(init.io, "zffprobe: out of memory\n", .{});
        return exit_limit;
    };
    return run(init.io, args);
}

fn run(io: std.Io, args: []const [:0]const u8) u8 {
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        return writeStdout(io, help);
    }
    if (args.len != 2) {
        printError(io, usage, .{});
        return exit_usage;
    }
    const path = args[1];
    var buffer: [av.file.default_buffer_len]u8 = undefined;
    const result = if (std.mem.eql(u8, path, "-"))
        av.file.probeFile(io, std.Io.File.stdin(), &buffer, .{})
    else
        av.file.probePath(io, std.Io.Dir.cwd(), path, &buffer, .{});
    const info = result catch |err| {
        printError(io, "zffprobe: {s}: {t}\n", .{ path, err });
        return exitCode(err);
    };

    var report_buffer: [512]u8 = undefined;
    var report: std.Io.Writer = .fixed(&report_buffer);
    writeReport(&report, info) catch unreachable; // nine short lines fit in 512 bytes
    return writeStdout(io, report.buffered());
}

fn writeReport(out: *std.Io.Writer, info: av.wav.Info) std.Io.Writer.Error!void {
    const format = info.format;
    try out.print(
        \\format=wav
        \\codec=pcm_s16le
        \\sample_fmt={s}
        \\channels={d}
        \\channel_layout={s}
        \\sample_rate={d}
        \\nb_samples={d}
        \\duration_num={d}
        \\duration_den={d}
        \\
    , .{
        format.sample_format.name(),
        format.channelCount(),
        format.layout.name(),
        format.sample_rate,
        info.frame_count,
        info.frame_count,
        format.sample_rate,
    });
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidRiff, error.InvalidWave, error.InvalidFormat, error.Truncated => exit_invalid,
        error.UnsupportedFormat, error.UnsupportedStreamingSize => exit_unsupported,
        error.LimitExceeded,
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => exit_limit,
        error.Canceled => exit_canceled,
        else => exit_io,
    };
}

/// Writes `bytes` to stdout and flushes; returns the exit status.
fn writeStdout(io: std.Io, bytes: []const u8) u8 {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch |err| {
        printError(io, "zffprobe: cannot write output: {t}\n", .{err});
        return exitCode(err);
    };
    return exit_ok;
}

fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr_writer.interface.print(fmt, args) catch return;
    stderr_writer.interface.flush() catch return;
}
