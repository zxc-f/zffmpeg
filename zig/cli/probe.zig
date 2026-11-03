// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! zffprobe: validates one WAV, Wave64 or AU stream and reports it as
//! `key=value` lines.
//!
//!     zffprobe <file.wav | file.w64 | file.au | ->
//!
//! The container is detected from content, not the file name (`av.detect`).
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

const usage = "usage: zffprobe <file.wav | file.w64 | file.au | ->\n";
const help = usage ++
    \\
    \\Validates a WAV, Wave64 or AU stream (standard input with -) and prints its
    \\stream parameters as key=value lines. Exit codes: 0 success, 1 usage,
    \\2 invalid or truncated media, 3 unsupported media, 4 I/O failure,
    \\5 resource limit, 6 cancellation.
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
    if (args.len != 2) {
        printError(io, usage, .{});
        return .usage;
    }
    const path = args[1];
    var buffer: [av.file.default_buffer_len]u8 = undefined;
    const result = if (std.mem.eql(u8, path, "-"))
        av.file.probeFile(io, std.Io.File.stdin(), &buffer, .{})
    else
        av.file.probePath(io, std.Io.Dir.cwd(), path, &buffer, .{});
    const info = result catch |err| {
        printError(io, "zffprobe: {s}: {t}\n", .{ path, err });
        return status.of(err);
    };

    var report_buffer: [512]u8 = undefined;
    var report: std.Io.Writer = .fixed(&report_buffer);
    writeReport(&report, info) catch unreachable; // nine short lines fit in 512 bytes
    return status.writeStdout(io, "zffprobe", report.buffered());
}

fn writeReport(out: *std.Io.Writer, info: av.detect.Probed) std.Io.Writer.Error!void {
    const format = info.format;
    try out.print(
        \\format={s}
        \\codec={s}
        \\sample_fmt={s}
        \\channels={d}
        \\channel_layout={s}
        \\sample_rate={d}
        \\
    , .{
        info.container.name(),
        info.codec.name(),
        format.sample_format.name(),
        format.channelCount(),
        format.layout.name(),
        format.sample_rate,
    });
    if (info.frame_count) |frames| {
        try out.print("nb_samples={d}\nduration_num={d}\nduration_den={d}\n", .{ frames, frames, format.sample_rate });
    } else {
        // Unknown-length data, which zffprobe does not enable yet: no count
        // or duration, as ffprobe's N/A.
        try out.writeAll("nb_samples=N/A\nduration_num=N/A\nduration_den=N/A\n");
    }
}
