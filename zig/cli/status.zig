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
        error.InvalidRiff, error.InvalidWave, error.InvalidAu, error.InvalidAiff, error.InvalidCaf, error.InvalidFormat, error.Truncated => .invalid,
        error.UnsupportedFormat, error.UnsupportedStreamingSize, error.UnsupportedOperation, error.UnknownFormat => .unsupported,
        error.LimitExceeded,
        error.SizeOverflow,
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => .limit,
        error.UnusedOption => .usage,
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

/// Raw PCM parameters from the command line, or the exit status their
/// diagnostic was printed with.
pub const RawParams = union(enum) {
    /// Null when none was given: FFmpeg's defaults then apply to raw input.
    ok: ?av.raw.Params,
    failed: ExitStatus,
};

/// Parses `-sample_rate` (or zffmpeg's `-ar`), `-ch_layout` and zffmpeg's
/// `-ac`, as given; null for each one absent. A rate that is not a decimal
/// number, or a layout FFmpeg cannot parse, is a usage error; a layout of
/// more than two channels (as text or a count) or an ambisonic one is
/// unsupported, until raw PCM widens (T23b); `-ac` gives FFmpeg's default
/// layout for the count.
pub fn rawParams(io: std.Io, tool: []const u8, rate_text: ?[]const u8, layout_text: ?[]const u8, channels_text: ?[]const u8) RawParams {
    if (rate_text == null and layout_text == null and channels_text == null) return .{ .ok = null };
    var params: av.raw.Params = .{};
    if (rate_text) |text| {
        params.sample_rate = std.fmt.parseInt(u32, text, 10) catch {
            printError(io, "{s}: {s}: invalid sample rate\n", .{ tool, text });
            return .{ .failed = .usage };
        };
    }
    if (layout_text) |text| {
        params.layout = av.channel_layout.Layout.parse(text) catch |err| switch (err) {
            error.InvalidLayout => {
                printError(io, "{s}: {s}: invalid channel layout\n", .{ tool, text });
                return .{ .failed = .usage };
            },
            error.UnsupportedLayout, error.LimitExceeded => {
                printError(io, "{s}: {s}: unsupported channel layout\n", .{ tool, text });
                return .{ .failed = .unsupported };
            },
        };
        if (params.layout.channelCount() > 2) {
            printError(io, "{s}: {s}: unsupported channel layout\n", .{ tool, text });
            return .{ .failed = .unsupported };
        }
    }
    if (channels_text) |text| {
        const count = std.fmt.parseInt(u16, text, 10) catch {
            printError(io, "{s}: {s}: invalid channel count\n", .{ tool, text });
            return .{ .failed = .usage };
        };
        if (count == 0 or count > 2) {
            printError(io, "{s}: {s}: unsupported channel count\n", .{ tool, text });
            return .{ .failed = .unsupported };
        }
        params.layout = .default(count);
    }
    return .{ .ok = params };
}
