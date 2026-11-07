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
/// errors and the file operations around them, a FLAC output's seek back
/// to its STREAMINFO included.
pub const Error = av.convert.Error ||
    std.Io.File.OpenError ||
    std.Io.File.Reader.Error ||
    std.Io.File.Writer.Error ||
    std.Io.File.SeekError;

/// Contract errors map to their categories; every remaining platform error in
/// `Error` is an I/O failure.
pub fn of(err: Error) ExitStatus {
    return switch (err) {
        error.InvalidRiff, error.InvalidWave, error.InvalidAu, error.InvalidAiff, error.InvalidCaf, error.InvalidFlac, error.InvalidOgg, error.InvalidMp3, error.InvalidVorbis, error.InvalidOpus, error.DecodeErrorRate, error.InvalidFormat, error.Truncated, error.FrameCountMismatch, error.InvalidSamples => .invalid,
        error.UnsupportedFormat, error.UnsupportedStreamingSize, error.UnsupportedOperation, error.UnknownFormat, error.UnsupportedLayout => .unsupported,
        error.LimitExceeded,
        error.FrameTooLarge,
        error.SizeOverflow,
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => .limit,
        error.UnusedOption, error.InvalidOption => .usage,
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

/// A raw PCM input's rate as the command line gives it, in FFmpeg's two
/// syntaxes.
pub const RawRate = union(enum) {
    /// The raw demuxers' `sample_rate` AVOption (`-sample_rate`): FFmpeg's
    /// expression (`8k`, `44.1k`), 0 to `INT_MAX`.
    option: []const u8,
    /// The ffmpeg program's `-ar` (`OPT_TYPE_INT`): `parse_number`'s
    /// integer, which the demuxer's option range then bounds.
    number: []const u8,
};

/// The raw demuxers' `sample_rate` option, for `av.options.set`.
const RateOption = struct {
    sample_rate: i32 = 44100,

    pub const option_specs = [_]av.options.Spec{
        .{ .name = "sample_rate", .field = "sample_rate", .kind = .int, .help = "", .min = 0, .max = std.math.maxInt(i32) },
    };

    comptime {
        av.options.check(RateOption);
    }
};

/// Parses `-sample_rate` (or zffmpeg's `-ar`), `-ch_layout` and zffmpeg's
/// `-ac`, as given; null for each one absent. A rate FFmpeg refuses (T17a's
/// number or expression syntax, by option) is a usage error; the layout is
/// `layoutOption`'s.
pub fn rawParams(io: std.Io, tool: []const u8, rate: ?RawRate, layout_text: ?[]const u8, channels_text: ?[]const u8) RawParams {
    if (rate == null and layout_text == null and channels_text == null) return .{ .ok = null };
    var params: av.raw.Params = .{};
    if (rate) |r| {
        const value: ?i32 = switch (r) {
            .option => |text| value: {
                var o: RateOption = .{};
                av.options.set(RateOption, &o, "sample_rate", text) catch break :value null;
                break :value o.sample_rate;
            },
            .number => |text| av.number.parseInt(text) catch null,
        };
        const text = switch (r) {
            inline else => |t| t,
        };
        params.sample_rate = std.math.cast(u32, value orelse -1) orelse {
            printError(io, "{s}: {s}: invalid sample rate\n", .{ tool, text });
            return .{ .failed = .usage };
        };
    }
    switch (layoutOption(io, tool, layout_text, channels_text)) {
        .ok => |layout| if (layout) |l| {
            params.layout = l;
        },
        .failed => |exit| return .{ .failed = exit },
    }
    return .{ .ok = params };
}

/// A channel layout from the command line, or the exit status its
/// diagnostic was printed with.
pub const LayoutOption = union(enum) {
    /// Null when neither option was given.
    ok: ?av.channel_layout.Layout,
    failed: ExitStatus,
};

/// Parses `-ch_layout` or zffmpeg's `-ac`; with both, `-ch_layout` wins,
/// as FFmpeg sets it after `-ac`. Text FFmpeg cannot parse, or a count
/// that is not a positive number, is a usage error; an ambisonic layout,
/// or a custom one past 64 channels, is unsupported. FFmpeg's command line
/// passes `-ac N` on as N channels, unspecified: the layout `NC` to a raw
/// demuxer, an unspecified encoder layout for an output (T23c).
pub fn layoutOption(io: std.Io, tool: []const u8, layout_text: ?[]const u8, channels_text: ?[]const u8) LayoutOption {
    var channels: ?u16 = null;
    if (channels_text) |text| {
        // FFmpeg's number syntax (T17a), within a channel count; checked
        // even when -ch_layout follows, as FFmpeg parses -ac first.
        const value = av.number.parseInt(text) catch -1;
        if (value <= 0 or value > std.math.maxInt(u16)) {
            printError(io, "{s}: {s}: invalid channel count\n", .{ tool, text });
            return .{ .failed = .usage };
        }
        channels = @intCast(value);
    }
    if (layout_text) |text| {
        const layout = av.channel_layout.Layout.parse(text) catch |err| switch (err) {
            error.InvalidLayout => {
                printError(io, "{s}: {s}: invalid channel layout\n", .{ tool, text });
                return .{ .failed = .usage };
            },
            error.UnsupportedLayout, error.LimitExceeded => {
                printError(io, "{s}: {s}: unsupported channel layout\n", .{ tool, text });
                return .{ .failed = .unsupported };
            },
        };
        return .{ .ok = layout };
    }
    if (channels) |count| return .{ .ok = .{ .unspecified = count } };
    return .{ .ok = null };
}
