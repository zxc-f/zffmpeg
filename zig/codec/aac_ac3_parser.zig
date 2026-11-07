// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/aac_ac3_parser.c (ff_aac_ac3_parse, the
// frame splitting shared by the AAC and AC-3 parsers) at the pinned
// reference revision.
// Copyright (c) 2003 Fabrice Bellard
// Copyright (c) 2003 Michael Niedermayer
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! The frame splitting of `ff_aac_ac3_parse`, `PARSER_FLAG_COMPLETE_FRAMES`
//! off: a sync search over the last bytes seen, then `ff_combine_frame`.
//! The AAC parser (codec/adts.zig) and the AC-3 parser (codec/ac3.zig)
//! each add what they read from a frame whose header was found.

const std = @import("std");
const parser = @import("parser.zig");

/// `END_NOT_FOUND`, which the parser returns as its index on the flush.
pub const end_not_found: i64 = -100;

/// What a codec's sync callback gives for a header in the last bytes of
/// the state: the frame's size, and its `new_frame_start` and
/// `need_next_header`.
pub const Sync = struct { frame_size: u32, new_frame_start: bool, need_next_header: bool };

/// The splitting state for a codec whose headers are `header_size` bytes
/// and whose sync callback is `sync`.
pub fn Splitter(comptime header_size: comptime_int, comptime sync: fn (u64) ?Sync) type {
    return struct {
        const Self = @This();

        pc: parser.ParseContext = .{},
        /// The bytes of the current frame still to come (an int, which can
        /// go below 0 when a frame's header began in an earlier call).
        remaining_size: i64 = 0,
        /// The last 8 bytes seen, for the sync search.
        state: u64 = 0,
        need_next_header: bool = false,

        pub fn deinit(p: *Self, gpa: std.mem.Allocator) void {
            p.pc.deinit(gpa);
            p.* = undefined;
        }

        pub const Step = struct {
            /// The parser's index (`av_parser_parse2`'s): the bytes of
            /// `buf` consumed, or a negative count the next call reads again
            /// (the frame ended among held bytes), `end_not_found` on the
            /// flush.
            index: i64,
            /// A frame, valid until the next call; null when none is
            /// complete (an empty output is none: parse_packet skips it).
            frame: ?[]const u8,
            /// Whether a header was found in this call (`got_frame`).
            got_frame: bool,
        };

        /// One call up to `*poutbuf = buf`: `buf` (empty at the end)
        /// scanned for frame starts.
        pub fn split(p: *Self, gpa: std.mem.Allocator, buf: []const u8) std.mem.Allocator.Error!Step {
            const buf_size: i64 = @intCast(buf.len);
            var got_frame = false;
            var i: ?i64 = null;
            while (true) {
                i = null;
                if (p.remaining_size > buf_size) break;
                if (p.remaining_size != 0 and !p.need_next_header) {
                    i = p.remaining_size;
                    p.remaining_size = 0;
                    break;
                }
                // A header first: from where the frame's known bytes end.
                var at = p.remaining_size;
                var found: ?Sync = null;
                while (at < buf_size) : (at += 1) {
                    // A negative start reads nothing here: FFmpeg's loop
                    // from a negative index would read before the buffer,
                    // which no caller reaches (`remaining_size` is negative
                    // only after a header found before the buffer, then
                    // consumed below).
                    if (at >= 0) p.state = (p.state << 8) +% buf[@intCast(at)];
                    found = sync(p.state);
                    if (found != null) break;
                }
                const s = found orelse break;
                p.need_next_header = s.need_next_header;
                got_frame = true;
                p.state = 0;
                const start = at - (header_size - 1);
                p.remaining_size = s.frame_size;
                const held: i64 = @intCast(p.pc.index);
                if (!s.new_frame_start or held + start <= 0) {
                    // The header starts the held bytes (or the buffer with
                    // nothing held), or continues a frame: the frame goes
                    // on past it.
                    p.remaining_size += start;
                    continue;
                }
                if (start < 0) p.remaining_size += start;
                i = start;
                break;
            }
            const frame = try p.pc.combine(gpa, i, buf) orelse {
                p.remaining_size -= @min(p.remaining_size, buf_size);
                return .{ .index = buf_size, .frame = null, .got_frame = false };
            };
            const index = i orelse end_not_found;
            if (frame.len == 0) return .{ .index = index, .frame = null, .got_frame = got_frame };
            return .{ .index = index, .frame = frame, .got_frame = got_frame };
        }
    };
}
