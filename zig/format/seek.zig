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

/// What `seekFile` returns for a `seekFrame` of type `F`: its result, or
/// its errors and `InvalidRange`.
fn SeekFileResult(comptime F: type) type {
    const eu = @typeInfo(@typeInfo(F).@"fn".return_type.?).error_union;
    return (eu.error_set || error{InvalidRange})!eu.payload;
}

/// `seek_file`'s fallback onto `av_seek_frame`, which every demuxer here
/// uses: `seekFrame` toward the nearer bound's side, then, if that fails,
/// to that bound and back. `seekFrame` is `fn (@TypeOf(context), i32,
/// i64, Flags) E!R` for the demuxer's own errors and result, hence
/// `anytype`. `avformat_seek_file`'s preroll and start-time adjustments
/// are the caller's (none for PCM).
pub fn seekFile(
    context: anytype,
    comptime seekFrame: anytype,
    stream: i32,
    min_ts: i64,
    ts: i64,
    max_ts: i64,
    flags: Flags,
) SeekFileResult(@TypeOf(seekFrame)) {
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

/// `AV_NOPTS_VALUE`.
const nopts: i64 = std.math.minInt(i64);

/// An index entry (`AVIndexEntry`): a keyframe a demuxer returned. Every
/// entry here is a keyframe, which is every packet of the supported codecs.
pub const IndexEntry = struct {
    pos: i64,
    timestamp: i64,
    min_distance: i64 = 0,
};

/// A stream's index (`FFStream.index_entries`), sorted by timestamp, as
/// libavformat builds it for a format with AVFMT_GENERIC_INDEX.
pub const Index = struct {
    entries: std.ArrayList(IndexEntry) = .empty,

    /// `ff_reduce_index`'s bound: the default `max_index_size` (1 MiB) of
    /// 24-byte entries.
    const max_entries = (1 << 20) / 24;

    pub fn deinit(x: *Index, gpa: std.mem.Allocator) void {
        x.entries.deinit(gpa);
    }

    /// ff_index_search_timestamp: the last entry at or before `wanted`
    /// with `backward`, else the first at or after it; null for none.
    pub fn search(x: *const Index, wanted: i64, flags: Flags) ?usize {
        const entries = x.entries.items;
        var a: isize = -1;
        var b: isize = @intCast(entries.len);
        if (b > 0 and entries[entries.len - 1].timestamp < wanted) a = b - 1;
        while (b - a > 1) {
            const m = @divTrunc(a + b, 2);
            const timestamp = entries[@intCast(m)].timestamp;
            if (timestamp >= wanted) b = m;
            if (timestamp <= wanted) a = m;
        }
        // Every entry is a keyframe, so `any` changes nothing.
        const m = if (flags.backward) a else b;
        if (m < 0 or m >= entries.len) return null;
        return @intCast(m);
    }

    /// ff_reduce_index, then ff_add_index_entry for a keyframe: a
    /// timestamp already there updated, an earlier one inserted in order.
    /// `timestamp` is absolute: the caller removes libavformat's relative
    /// base first, as ff_add_index_entry does. A missing timestamp adds
    /// nothing (FFmpeg's `AVERROR(EINVAL)`, which its callers ignore).
    pub fn add(x: *Index, gpa: std.mem.Allocator, pos: i64, timestamp: i64) error{OutOfMemory}!void {
        if (timestamp == nopts) return;
        if (x.entries.items.len >= max_entries) {
            var i: usize = 0;
            while (2 * i < x.entries.items.len) : (i += 1) x.entries.items[i] = x.entries.items[2 * i];
            x.entries.shrinkRetainingCapacity(i);
        }
        const entries = x.entries.items;
        if (x.search(timestamp, .{ .any = true })) |i| {
            if (entries[i].timestamp != timestamp) {
                if (entries[i].timestamp <= timestamp) return;
                try x.entries.insert(gpa, i, .{ .pos = pos, .timestamp = timestamp });
                return;
            }
            // The same timestamp: the newer position, at distance 0.
            entries[i].pos = pos;
            entries[i].min_distance = 0;
            return;
        }
        try x.entries.append(gpa, .{ .pos = pos, .timestamp = timestamp });
    }

    /// ff_seek_frame_binary's bounds from the index: the entry at or
    /// before `target`, and the one at or after it.
    pub fn bounds(x: *const Index, target: i64, any: bool) Bounds {
        var out: Bounds = .{};
        const entries = x.entries.items;
        if (entries.len == 0) return out;
        const below = x.search(target, .{ .backward = true, .any = any }) orelse 0;
        const e = entries[below];
        if (e.timestamp <= target or e.pos == e.min_distance) {
            out.pos_min = e.pos;
            out.ts_min = e.timestamp;
        }
        if (x.search(target, .{ .any = any })) |above| {
            const f = entries[above];
            out.pos_max = f.pos;
            out.ts_max = f.timestamp;
            out.pos_limit = f.pos - f.min_distance;
        }
        return out;
    }
};

/// ff_gen_search's starting bounds; the timestamps unknown by default.
pub const Bounds = struct {
    pos_min: i64 = 0,
    pos_max: i64 = 0,
    pos_limit: i64 = -1,
    ts_min: i64 = nopts,
    ts_max: i64 = nopts,
};

/// Where ff_gen_search lands: a byte position and its timestamp.
pub const Found = struct { pos: i64, ts: i64 };

/// ff_gen_search and ff_find_last_ts over a demuxer's `read_timestamp`:
/// `readTimestamp(context, &pos, pos_limit)` gives the timestamp of the
/// first packet found from `pos` (no further than `pos_limit` where the
/// demuxer honors it), or `nopts`, and moves `pos` to that packet.
pub fn Search(
    comptime Context: type,
    comptime E: type,
    comptime readTimestamp: fn (Context, *i64, i64) E!i64,
) type {
    return struct {
        /// ff_find_last_ts: the last packet's timestamp and position,
        /// searched back from the end in doubling steps, then forward.
        /// Null when no packet has a timestamp.
        pub fn findLastTs(context: Context, file_size: i64) E!?Found {
            var step: i64 = 1024;
            var pos_max = file_size - 1;
            var limit: i64 = undefined;
            var ts_max: i64 = undefined;
            while (true) {
                limit = pos_max;
                pos_max = @max(0, pos_max -% step);
                ts_max = try readTimestamp(context, &pos_max, limit);
                // C's int64_t `step += step` and `2*limit` wrap on the
                // reference build when the size is near 2^63 (a seeker that
                // reports no real size); notes.md "Follow the reference build".
                step +%= step;
                if (!(ts_max == nopts and 2 *% limit > step)) break;
            }
            if (ts_max == nopts) return null;
            while (true) {
                var tmp_pos = pos_max + 1;
                const tmp_ts = try readTimestamp(context, &tmp_pos, std.math.maxInt(i64));
                if (tmp_ts == nopts) break;
                ts_max = tmp_ts;
                pos_max = tmp_pos;
                if (tmp_pos >= file_size) break;
            }
            return .{ .pos = pos_max, .ts = ts_max };
        }

        /// ff_gen_search: interpolation, then bisection, then a linear
        /// scan between the bounds. Null where FFmpeg's gives -1.
        pub fn genSearch(context: Context, data_offset: i64, file_size: i64, target_ts: i64, start: Bounds, backward: bool) E!?Found {
            var pos_min = start.pos_min;
            var pos_max = start.pos_max;
            var pos_limit = start.pos_limit;
            var ts_min = start.ts_min;
            var ts_max = start.ts_max;
            if (ts_min == nopts) {
                pos_min = data_offset;
                ts_min = try readTimestamp(context, &pos_min, std.math.maxInt(i64));
                if (ts_min == nopts) return null;
            }
            if (ts_min >= target_ts) return .{ .pos = pos_min, .ts = ts_min };
            if (ts_max == nopts) {
                const last = try findLastTs(context, file_size) orelse return null;
                pos_max = last.pos;
                ts_max = last.ts;
                pos_limit = pos_max;
            }
            if (ts_max <= target_ts) return .{ .pos = pos_max, .ts = ts_max };
            var no_change: u32 = 0;
            while (pos_min < pos_limit) {
                var pos: i64 = switch (no_change) {
                    // Timestamps far apart overflow int64_t here; the
                    // reference build wraps (notes.md "Follow the reference
                    // build"), and av_rescale takes the wrapped values.
                    0 => rational.rescale(target_ts -% ts_min, pos_max -% pos_min, ts_max -% ts_min) +% pos_min -% (pos_max -% pos_limit),
                    1 => (pos_min + pos_limit) >> 1,
                    else => pos_min,
                };
                if (pos <= pos_min) {
                    pos = pos_min + 1;
                } else if (pos > pos_limit) {
                    pos = pos_limit;
                }
                const start_pos = pos;
                const ts = try readTimestamp(context, &pos, std.math.maxInt(i64));
                no_change = if (pos == pos_max) no_change + 1 else 0;
                if (ts == nopts) return null; // "read_timestamp() failed in the middle"
                if (target_ts <= ts) {
                    pos_limit = start_pos - 1;
                    pos_max = pos;
                    ts_max = ts;
                }
                if (target_ts >= ts) {
                    pos_min = pos;
                    ts_min = ts;
                }
            }
            return if (backward) .{ .pos = pos_min, .ts = ts_min } else .{ .pos = pos_max, .ts = ts_max };
        }
    };
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

test "the index keeps keyframes in order, updates a timestamp it has, and gives a search its bounds" {
    const gpa = std.testing.allocator;
    var index: Index = .{};
    defer index.deinit(gpa);
    try index.add(gpa, 100, 0);
    try index.add(gpa, 300, 2048);
    try index.add(gpa, 200, 1024);
    try index.add(gpa, 250, 1024); // the same timestamp: the newer position
    try index.add(gpa, 400, nopts); // no timestamp: nothing
    try std.testing.expectEqual(3, index.entries.items.len);
    try std.testing.expectEqual(250, index.entries.items[1].pos);
    try std.testing.expectEqual(1, index.search(1500, .{ .backward = true }));
    try std.testing.expectEqual(2, index.search(1500, .{}));
    try std.testing.expectEqual(null, index.search(3000, .{}));
    try std.testing.expectEqual(null, index.search(-1, .{ .backward = true }));
    const b = index.bounds(1500, false);
    try std.testing.expectEqual(250, b.pos_min);
    try std.testing.expectEqual(1024, b.ts_min);
    try std.testing.expectEqual(300, b.pos_max);
    try std.testing.expectEqual(2048, b.ts_max);
    try std.testing.expectEqual(300, b.pos_limit);
    // Past the last entry: no upper bound.
    try std.testing.expectEqual(nopts, index.bounds(5000, false).ts_max);
}

test "the generic search lands on the packet at or around the target" {
    // Packets every 100 bytes from 0, each timestamped with its position.
    const Packets = struct {
        fn readTimestamp(_: void, pos: *i64, pos_limit: i64) error{}!i64 {
            _ = pos_limit;
            const next = @divFloor(pos.* + 99, 100) * 100;
            if (next >= 1000) return nopts;
            pos.* = next;
            return next;
        }
    };
    const S = Search(void, error{}, Packets.readTimestamp);
    const forward = (try S.genSearch({}, 0, 1000, 455, .{}, false)).?;
    try std.testing.expectEqual(Found{ .pos = 500, .ts = 500 }, forward);
    const backward = (try S.genSearch({}, 0, 1000, 455, .{}, true)).?;
    try std.testing.expectEqual(Found{ .pos = 400, .ts = 400 }, backward);
    try std.testing.expectEqual(Found{ .pos = 900, .ts = 900 }, (try S.findLastTs({}, 1000)).?);
}

test "the last-timestamp search wraps as the reference build's int64_t near 2^63" {
    // No packet anywhere, with sizes whose `2*limit` and `step += step`
    // overflow int64_t: the search ends as the reference build's does.
    const Empty = struct {
        fn readTimestamp(_: void, pos: *i64, pos_limit: i64) error{}!i64 {
            _ = pos;
            _ = pos_limit;
            return nopts;
        }
    };
    const S = Search(void, error{}, Empty.readTimestamp);
    for ([_]i64{ std.math.maxInt(i64), (1 << 62) + 1, (1 << 62) - 1, 1 << 40 }) |size| {
        try std.testing.expectEqual(null, try S.findLastTs({}, size));
    }
}
