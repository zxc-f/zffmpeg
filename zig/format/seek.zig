// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/seek.c (av_seek_frame, avformat_seek_file, seek_file,
// seek_frame_byte) and avformat.h (the AVSEEK_FLAG_* flags, AV_TIME_BASE) at
// the pinned reference revision describe the API, restated here.
//! The seek API (TODO.md T52a): FFmpeg's `av_seek_frame` and
//! `avformat_seek_file` requests, and the seekable source a demuxer
//! repositions. Each container implements the seek itself (WAV first,
//! format/wav.zig); this file holds what they share.
//!
//! A source is seekable when the caller can reposition the stream the
//! parser reads: a `Seeker` over the same reader, with its logical position
//! and, for byte seeking, its size. Detection's replay reader is not
//! seekable; a parser that seeks reads its source directly.

const std = @import("std");
const rational = @import("../core/rational.zig");

/// `AV_TIME_BASE`: the units of a seek on the default stream.
pub const time_base_units: i64 = 1_000_000;

/// `AVSEEK_FLAG_*`.
pub const Flags = struct {
    /// Land at or before the timestamp (`AVSEEK_FLAG_BACKWARD`).
    backward: bool = false,
    /// The timestamp is a byte position (`AVSEEK_FLAG_BYTE`).
    byte: bool = false,
    /// Any frame, not only a keyframe (`AVSEEK_FLAG_ANY`); every PCM frame
    /// is a keyframe.
    any: bool = false,
};

pub const Error = error{
    /// The stream index is neither -1 (the default stream, in
    /// `time_base_units`) nor one of the input's (`AVERROR(EINVAL)`).
    InvalidStream,
    /// `min > ts` or `max < ts` in `seekFile`.
    InvalidRange,
    /// The source failed to reposition.
    IoFailure,
};

/// Where a seek landed.
pub const Position = struct {
    /// The byte offset in the source of the next data read.
    offset: u64,
    /// The next sample's timestamp in the stream's time base; null after a
    /// byte seek, which gives no timestamp.
    timestamp: ?i64,
    /// The data is exhausted there: the next read is the end of the stream.
    at_end: bool,
};

/// A source the caller can reposition: the stream a parser reads.
pub const Seeker = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Reads continue from `offset`; past the end they find the end.
        seekTo: *const fn (context: *anyopaque, offset: u64) error{IoFailure}!void,
        /// The offset of the next byte the parser reads.
        position: *const fn (context: *anyopaque) u64,
        /// The source's length, when known.
        size: *const fn (context: *anyopaque) ?u64,
    };

    pub fn seekTo(s: Seeker, offset: u64) error{IoFailure}!void {
        return s.vtable.seekTo(s.context, offset);
    }

    pub fn position(s: Seeker) u64 {
        return s.vtable.position(s.context);
    }

    pub fn size(s: Seeker) ?u64 {
        return s.vtable.size(s.context);
    }

    /// A reader over a fixed buffer (`std.Io.Reader.fixed`).
    pub fn fixed(reader: *std.Io.Reader) Seeker {
        return .{ .context = reader, .vtable = &fixed_vtable };
    }

    const fixed_vtable: VTable = .{
        .seekTo = struct {
            fn seekTo(context: *anyopaque, offset: u64) error{IoFailure}!void {
                const r: *std.Io.Reader = @ptrCast(@alignCast(context));
                r.seek = std.math.cast(usize, @min(offset, r.end)) orelse r.end;
            }
        }.seekTo,
        .position = struct {
            fn position(context: *anyopaque) u64 {
                const r: *std.Io.Reader = @ptrCast(@alignCast(context));
                return r.seek;
            }
        }.position,
        .size = struct {
            fn size(context: *anyopaque) ?u64 {
                const r: *std.Io.Reader = @ptrCast(@alignCast(context));
                return r.end;
            }
        }.size,
    };

    /// A file reader; its `interface` is what the parser reads.
    pub fn file(reader: *std.Io.File.Reader) Seeker {
        return .{ .context = reader, .vtable = &file_vtable };
    }

    const file_vtable: VTable = .{
        .seekTo = struct {
            fn seekTo(context: *anyopaque, offset: u64) error{IoFailure}!void {
                const r: *std.Io.File.Reader = @ptrCast(@alignCast(context));
                r.seekTo(offset) catch return error.IoFailure;
            }
        }.seekTo,
        .position = struct {
            fn position(context: *anyopaque) u64 {
                const r: *std.Io.File.Reader = @ptrCast(@alignCast(context));
                return r.logicalPos();
            }
        }.position,
        .size = struct {
            fn size(context: *anyopaque) ?u64 {
                const r: *std.Io.File.Reader = @ptrCast(@alignCast(context));
                return r.getSize() catch null;
            }
        }.size,
    };
};

/// An output the caller can reposition, as a seekable `AVIOContext` lets a
/// muxer rewrite its header at the end (T26c). Writes go through the
/// writer the muxer was given; this only moves it.
pub const OutputSeeker = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Flushes, then writes continue at `offset`.
        seekTo: *const fn (context: *anyopaque, offset: u64) error{IoFailure}!void,
        /// The offset of the next byte written.
        position: *const fn (context: *anyopaque) u64,
    };

    pub fn seekTo(s: OutputSeeker, offset: u64) error{IoFailure}!void {
        return s.vtable.seekTo(s.context, offset);
    }

    pub fn position(s: OutputSeeker) u64 {
        return s.vtable.position(s.context);
    }

    /// A writer over a fixed buffer (`std.Io.Writer.fixed`): moving back
    /// keeps the bytes after the new position, so moving forward again to
    /// the old end restores them.
    pub fn fixed(writer: *std.Io.Writer) OutputSeeker {
        return .{ .context = writer, .vtable = &fixed_vtable };
    }

    const fixed_vtable: VTable = .{
        .seekTo = struct {
            fn seekTo(context: *anyopaque, offset: u64) error{IoFailure}!void {
                const w: *std.Io.Writer = @ptrCast(@alignCast(context));
                const end = std.math.cast(usize, offset) orelse return error.IoFailure;
                if (end > w.buffer.len) return error.IoFailure;
                w.end = end;
            }
        }.seekTo,
        .position = struct {
            fn position(context: *anyopaque) u64 {
                const w: *std.Io.Writer = @ptrCast(@alignCast(context));
                return w.end;
            }
        }.position,
    };

    /// A file writer; its `interface` is what the muxer writes to.
    pub fn file(writer: *std.Io.File.Writer) OutputSeeker {
        return .{ .context = writer, .vtable = &file_vtable };
    }

    const file_vtable: VTable = .{
        .seekTo = struct {
            fn seekTo(context: *anyopaque, offset: u64) error{IoFailure}!void {
                const w: *std.Io.File.Writer = @ptrCast(@alignCast(context));
                w.seekTo(offset) catch return error.IoFailure;
            }
        }.seekTo,
        .position = struct {
            fn position(context: *anyopaque) u64 {
                const w: *std.Io.File.Writer = @ptrCast(@alignCast(context));
                return w.logicalPos();
            }
        }.position,
    };
};

/// `seek_file`'s fallback onto `av_seek_frame`, which every demuxer here
/// uses: `seekFrame` toward the nearer bound's side, then, if that fails,
/// to that bound and back. `avformat_seek_file`'s preroll and start-time
/// adjustments are none for PCM.
pub fn seekFile(
    context: anytype,
    comptime seekFrame: fn (@TypeOf(context), i32, i64, Flags) Error!Position,
    stream: i32,
    min_ts: i64,
    ts: i64,
    max_ts: i64,
    flags: Flags,
) Error!Position {
    if (min_ts > ts or max_ts < ts) return error.InvalidRange;
    var f = flags;
    f.backward = false;
    // Toward the nearer bound: backward when `ts` is farther from `min_ts`.
    const below: u64 = @bitCast(ts -% min_ts);
    const above: u64 = @bitCast(max_ts -% ts);
    f.backward = below > above;
    return seekFrame(context, stream, ts, f) catch |err| {
        if (ts != min_ts and max_ts != ts) {
            _ = try seekFrame(context, stream, if (f.backward) max_ts else min_ts, f);
            var other = f;
            other.backward = !f.backward;
            return seekFrame(context, stream, ts, other);
        }
        return err;
    };
}

/// A timestamp on the default stream (`AV_TIME_BASE` units) in a stream's
/// time base, as `seek_frame_internal` converts it.
pub fn defaultStreamTimestamp(ts: i64, time_base: rational.Rational) i64 {
    return rational.rescale(ts, time_base.den, time_base_units * time_base.num);
}

test "a fixed reader seeks within its buffer, clamped to the end" {
    var reader: std.Io.Reader = .fixed("abcdef");
    const seeker: Seeker = .fixed(&reader);
    try std.testing.expectEqual(6, seeker.size());
    try seeker.seekTo(4);
    try std.testing.expectEqual(4, seeker.position());
    try std.testing.expectEqual('e', try reader.takeByte());
    try seeker.seekTo(100);
    try std.testing.expectEqual(6, seeker.position());
    try std.testing.expectError(error.EndOfStream, reader.takeByte());
}

test "a file reader seeks and reports its position and size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "0123456789" });
    const f = try tmp.dir.openFile(io, "f", .{});
    defer f.close(io);
    var buffer: [4]u8 = undefined;
    var reader = f.reader(io, &buffer);
    const seeker: Seeker = .file(&reader);
    try std.testing.expectEqual(10, seeker.size());
    try std.testing.expectEqual('0', try reader.interface.takeByte());
    try std.testing.expectEqual(1, seeker.position());
    try seeker.seekTo(7);
    try std.testing.expectEqual('7', try reader.interface.takeByte());
    try seeker.seekTo(2);
    try std.testing.expectEqual('2', try reader.interface.takeByte());
}

test "an output seeker rewrites earlier bytes of a file and of a buffer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "out", .{});
    var buffer: [4]u8 = undefined;
    var writer = f.writerStreaming(io, &buffer);
    const seeker: OutputSeeker = .file(&writer);
    try writer.interface.writeAll("0123456789");
    try std.testing.expectEqual(10, seeker.position());
    try seeker.seekTo(2);
    try writer.interface.writeAll("ab");
    try seeker.seekTo(10);
    try writer.interface.writeAll("!");
    try writer.interface.flush();
    f.close(io);
    var read_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("01ab456789!", try tmp.dir.readFile(io, "out", &read_buffer));

    var bytes: [16]u8 = undefined;
    var fixed_writer: std.Io.Writer = .fixed(&bytes);
    const fixed_seeker: OutputSeeker = .fixed(&fixed_writer);
    try fixed_writer.writeAll("0123456789");
    try fixed_seeker.seekTo(2);
    try fixed_writer.writeAll("ab");
    try fixed_seeker.seekTo(10);
    try std.testing.expectEqualStrings("01ab456789", fixed_writer.buffered());
    try std.testing.expectError(error.IoFailure, fixed_seeker.seekTo(17));
}
