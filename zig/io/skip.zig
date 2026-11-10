// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Skips of untrusted lengths on a `std.Io.Reader`.
//!
//! Zig 0.17.0's `Reader.discardShort` adds `n` to the buffer position without
//! an overflow check (`seek + n` in lib/std/Io/Reader.zig), and `discardAll`
//! and `discardAll64` go through it. A skip near `maxInt(usize)` from a
//! position past 0 therefore panics in Debug and ReleaseSafe and, in
//! ReleaseFast, wraps the position backward so old bytes are read again. A
//! 64-bit chunk size reaches it on every target, a 32-bit one on 32-bit
//! targets. These helpers discard in steps of at most `max_step` bytes,
//! which no reader position can overflow, with the std functions' results:
//! a short count, or `error.EndOfStream`, when the stream ends first.

const std = @import("std");
const Reader = std.Io.Reader;

/// The most bytes handed to the std reader in one call. A reader buffer
/// position stays below `maxInt(usize) - max_step` on every target: 32-bit
/// address spaces cannot hold a 3 GiB reader buffer next to the program.
pub const max_step: usize = 1 << 30;

/// Skips up to `n` bytes and returns how many were skipped, fewer than `n`
/// only when the stream ended (`Reader.discardShort` for a u64 count).
pub fn discardShort(r: *Reader, n: u64) Reader.ShortError!u64 {
    std.debug.assert(r.buffer.len <= std.math.maxInt(usize) - max_step);
    var done: u64 = 0;
    while (done < n) {
        // At most max_step, so it fits in usize.
        const step: usize = @min(n - done, max_step);
        const skipped = try r.discardShort(step);
        done += skipped;
        if (skipped < step) break;
    }
    return done;
}

/// Skips exactly `n` bytes; `error.EndOfStream` when the stream ends first
/// (`Reader.discardAll64`). Some bytes may have been skipped by then.
pub fn discardAll(r: *Reader, n: u64) Reader.Error!void {
    if (try discardShort(r, n) != n) return error.EndOfStream;
}

test "a huge skip after reading ends short instead of overflowing" {
    const bytes = "0123456789";
    var reader: Reader = .fixed(bytes);
    try std.testing.expectEqualStrings("01", try reader.take(2));
    // reader.discardShort(maxInt(usize) - 1) overflows `seek + n` here.
    try std.testing.expectEqual(8, try discardShort(&reader, std.math.maxInt(u64) - 1));
    try std.testing.expectError(error.EndOfStream, reader.takeByte());

    var again: Reader = .fixed(bytes);
    _ = try again.take(2);
    try std.testing.expectError(error.EndOfStream, discardAll(&again, std.math.maxInt(u64) - 1));
}

test "a huge skip on a fragmented stream ends short" {
    const bytes = "0123456789";
    var buffer: [4]u8 = undefined;
    var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
    source.artificial_limit = .limited(3);
    try std.testing.expectEqualStrings("01", try source.interface.take(2));
    try std.testing.expect(source.interface.seek >= 2);
    try std.testing.expectEqual(8, try discardShort(&source.interface, std.math.maxInt(u64) - 1));
}

test "skips within the stream are exact" {
    const bytes = "0123456789";
    var reader: Reader = .fixed(bytes);
    try discardAll(&reader, 0);
    try discardAll(&reader, 3);
    try std.testing.expectEqual('3', try reader.takeByte());
    try std.testing.expectEqual(6, try discardShort(&reader, 6));
    try std.testing.expectEqual(0, try discardShort(&reader, 1));
    try std.testing.expectError(error.EndOfStream, discardAll(&reader, 1));
}

test "a read failure is passed through" {
    var reader: Reader = .failing;
    try std.testing.expectError(error.ReadFailed, discardShort(&reader, std.math.maxInt(u64)));
}
