// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source. The
// levels are libavutil/log.h's at the pinned reference revision.
//! Diagnostics (TODO.md T17a): where a component reports what FFmpeg would
//! log, passed explicitly instead of FFmpeg's global `av_log`. A sink has a
//! level, FFmpeg's, and receives each message at or below it; a component
//! given no sink reports nothing. The command-line tools give none, so they
//! keep printing errors only (the project owner's choice).

const std = @import("std");

/// FFmpeg's log levels (`AV_LOG_*`): lower is more severe.
pub const Level = enum(i8) {
    quiet = -8,
    panic = 0,
    fatal = 8,
    err = 16,
    warning = 24,
    info = 32,
    verbose = 40,
    debug = 48,
    trace = 56,
};

/// Receives formatted messages. `emit` gets each message at `level` or more
/// severe, without a trailing newline; `context` is the caller's.
pub const Sink = struct {
    context: ?*anyopaque = null,
    emit: *const fn (context: ?*anyopaque, level: Level, message: []const u8) void,
    level: Level = .info,

    /// Formats and emits `format` with `args` if `level` passes; a message
    /// past 1 KiB is cut there.
    pub fn log(sink: Sink, level: Level, comptime format: []const u8, args: anytype) void {
        if (@backingInt(level) > @backingInt(sink.level)) return;
        var buffer: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        w.print(format, args) catch {};
        sink.emit(sink.context, level, w.buffered());
    }
};

/// Reports to `sink` when there is one.
pub fn report(sink: ?Sink, level: Level, comptime format: []const u8, args: anytype) void {
    if (sink) |s| s.log(level, format, args);
}

/// A sink that keeps the first and last messages and counts them: for
/// tests.
pub const Recorder = struct {
    count: usize = 0,
    last_level: Level = .quiet,
    last: [1024]u8 = undefined,
    last_len: usize = 0,
    first: [1024]u8 = undefined,
    first_len: usize = 0,

    pub fn sink(r: *Recorder, level: Level) Sink {
        return .{ .context = r, .emit = emit, .level = level };
    }

    fn emit(context: ?*anyopaque, level: Level, message: []const u8) void {
        const r: *Recorder = @ptrCast(@alignCast(context.?));
        if (r.count == 0) {
            r.first_len = message.len;
            @memcpy(r.first[0..message.len], message);
        }
        r.count += 1;
        r.last_level = level;
        r.last_len = message.len;
        @memcpy(r.last[0..message.len], message);
    }

    pub fn lastMessage(r: *const Recorder) []const u8 {
        return r.last[0..r.last_len];
    }

    pub fn firstMessage(r: *const Recorder) []const u8 {
        return r.first[0..r.first_len];
    }
};

test "a sink receives the messages at or below its level" {
    var recorder: Recorder = .{};
    const sink = recorder.sink(.warning);
    sink.log(.info, "not shown {d}", .{1});
    try std.testing.expectEqual(0, recorder.count);
    sink.log(.warning, "rate {d}", .{8000});
    try std.testing.expectEqual(1, recorder.count);
    try std.testing.expectEqualStrings("rate 8000", recorder.lastMessage());
    report(null, .err, "nothing to report to", .{});
}
