// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Process exit statuses shared by zffprobe and zffmpeg (port.md "Initial
//! probe output" and "zffmpeg command"): typed inside the tools and converted
//! to a number once, in `main`.

const std = @import("std");
const av = @import("av");

pub const ExitStatus = enum(u8) {
    ok = 0,
    usage = 1,
    invalid = 2,
    unsupported = 3,
    io = 4,
    limit = 5,
    canceled = 6,
};

/// Every error either tool classifies: the library's media and conversion
/// errors and the file operations around them.
pub const Error = av.convert.Error ||
    std.Io.File.OpenError ||
    std.Io.File.Reader.Error ||
    std.Io.File.Writer.Error;

/// Contract errors map to their categories; every remaining platform error in
/// `Error` is an I/O failure.
pub fn of(err: Error) ExitStatus {
    return switch (err) {
        error.InvalidRiff, error.InvalidWave, error.InvalidAu, error.InvalidFormat, error.Truncated => .invalid,
        error.UnsupportedFormat, error.UnsupportedStreamingSize, error.UnsupportedOperation => .unsupported,
        error.LimitExceeded,
        error.SizeOverflow,
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => .limit,
        error.Canceled => .canceled,
        else => .io,
    };
}

/// Writes one formatted line to stderr. A failing stderr is ignored: the
/// exit status still reports the outcome.
pub fn printError(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr_writer.interface.print(fmt, args) catch return;
    stderr_writer.interface.flush() catch return;
}

/// Writes `bytes` to stdout and flushes; returns the exit status.
pub fn writeStdout(io: std.Io, tool: []const u8, bytes: []const u8) ExitStatus {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch |err| {
        printError(io, "{s}: cannot write output: {t}\n", .{ tool, err });
        return of(err);
    };
    return .ok;
}
