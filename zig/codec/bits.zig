// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavcodec/get_bits.h (the checked, uncached reader: get_bits,
// get_bits_long, get_bits1, get_sbits_long, show_bits_long, skip_bits,
// skip_bits_long, align_get_bits, get_bits_left), unary.h (get_unary),
// golomb.h (get_ur_golomb_jpegls, get_sr_golomb_flac), put_bits.h
// (put_bits, put_sbits, put_bits32, put_bits63, put_sbits63,
// flush_put_bits), flacenc.c (set_sr_golomb_flac) and libavutil/crc.c
// (AV_CRC_8_ATM, AV_CRC_16_ANSI) at the pinned reference revision describe
// the behavior, restated here.
//! An MSB-first bit reader over a borrowed slice (TODO.md T18a), with the
//! over-read rules of FFmpeg's checked reader, its LSB-first counterpart
//! (`LsbReader`, FFmpeg's reader under BITSTREAM_READER_LE, T18c), its
//! writer counterpart (T18b), and the CRCs FLAC uses.
//!
//! FFmpeg's input buffers carry zero padding past their end, and its
//! checked reader stops its bit count 8 bits past the end. This reader
//! models both without touching memory past the slice: every bit past the
//! end reads as 0, and the count saturates at the size in bits plus 8, so a
//! decoder sees exactly the values FFmpeg's does and can tell an over-read
//! from `left()` going negative. That holds in every optimize mode; no read
//! depends on runtime safety checks.

const std = @import("std");

/// FLAC's frame header CRC: polynomial 0x07, initial 0, no reflection or
/// final XOR, FFmpeg's `AV_CRC_8_ATM`.
pub const Crc8 = std.hash.crc.@"CRC-8/SMBUS";

/// FLAC's frame CRC: polynomial 0x8005, initial 0, no reflection or final
/// XOR, FFmpeg's `AV_CRC_16_ANSI`. FFmpeg keeps this CRC byte-swapped; FLAC
/// only asks whether it is zero, which the swap does not change.
pub const Crc16 = std.hash.crc.@"CRC-16/UMTS";

pub const BitReader = struct {
    bytes: []const u8,
    /// The bits read so far, at most `size + 8`.
    index: usize = 0,
    /// `bytes.len * 8`.
    size: usize,

    pub const InitError = error{InputTooLarge};

    /// `init_get_bits8`: FFmpeg refuses buffers whose size in bits, plus
    /// its padding, does not fit an int.
    pub fn init(bytes: []const u8) InitError!BitReader {
        const limit = (std.math.maxInt(i32) - 64 * 8) / 8;
        if (bytes.len >= limit) return error.InputTooLarge;
        return .{ .bytes = bytes, .size = bytes.len * 8 };
    }

    /// `init_get_bits8` over the first `size` bytes of `memory`: the reads
    /// past them, up to the count's 8 bits of slack, see the bytes that
    /// follow in `memory` (zeros past it), as FFmpeg's reader sees the rest
    /// of the packet in a frame that is not the packet's last.
    pub fn initIn(memory: []const u8, size: usize) InitError!BitReader {
        std.debug.assert(size <= memory.len);
        var r = try init(memory[0..size]);
        r.bytes = memory;
        return r;
    }

    fn byteAt(r: *const BitReader, at: usize) u8 {
        return if (at < r.bytes.len) r.bytes[at] else 0;
    }

    /// The next 57 or more bits, left-aligned; zeros past the end.
    fn window(r: *const BitReader) u64 {
        const start = r.index >> 3;
        const shift: u6 = @intCast(r.index & 7);
        if (start + 8 <= r.bytes.len) {
            return std.mem.readInt(u64, r.bytes[start..][0..8], .big) << shift;
        }
        var w: u64 = 0;
        for (0..8) |k| w = (w << 8) | r.byteAt(start + k);
        return w << shift;
    }

    /// `show_bits_long`: the next `n` bits (0 to 32) without consuming them.
    pub fn peek(r: *const BitReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        const drop: u6 = @intCast(64 - @as(u7, n));
        return @intCast(r.window() >> drop);
    }

    /// `skip_bits`: consumes `n` bits, the count saturating 8 bits past the
    /// end.
    pub fn skip(r: *BitReader, n: usize) void {
        r.index = @min(r.size + 8, r.index + @min(n, r.size + 8));
    }

    /// `get_bits_long`: the next `n` bits (0 to 32).
    pub fn bits(r: *BitReader, n: u6) u32 {
        const value = r.peek(n);
        r.skip(n);
        return value;
    }

    /// `get_bits1`.
    pub fn bit(r: *BitReader) u1 {
        return @intCast(r.bits(1));
    }

    /// `get_sbits_long`: the next `n` bits (0 to 32), sign-extended.
    pub fn signed(r: *BitReader, n: u6) i32 {
        if (n == 0) return 0;
        const value = r.bits(n);
        const shift: u5 = @intCast(32 - @as(u7, n));
        const wide: i32 = @bitCast(value << shift);
        return wide >> shift;
    }

    /// `get_bits64`: the next `n` bits (0 to 64), the high part first.
    pub fn bits64(r: *BitReader, n: u7) u64 {
        std.debug.assert(n <= 64);
        if (n <= 32) return r.bits(@intCast(n));
        const high: u64 = r.bits(@intCast(n - 32));
        return high << 32 | r.bits(32);
    }

    /// `get_sbits64`: the next `n` bits (1 to 64), sign-extended.
    pub fn signed64(r: *BitReader, n: u7) i64 {
        std.debug.assert(n >= 1 and n <= 64);
        const shift: u6 = @intCast(64 - @as(u8, n));
        const wide: i64 = @bitCast(r.bits64(n) << shift);
        return wide >> shift;
    }

    /// `align_get_bits`: skips to the next byte boundary.
    pub fn alignByte(r: *BitReader) void {
        r.skip((8 - (r.index & 7)) & 7);
    }

    /// `get_bits_count`.
    pub fn count(r: *const BitReader) usize {
        return r.index;
    }

    /// `get_bits_left`: negative after an over-read.
    pub fn left(r: *const BitReader) i64 {
        const size: i64 = @intCast(r.size);
        const index: i64 = @intCast(r.index);
        return size - index;
    }

    /// `get_unary`: counts bits until one equals `stop`, consuming it, or
    /// `len` bits.
    pub fn unary(r: *BitReader, stop: u1, len: i64) i64 {
        var i: i64 = 0;
        while (i < len and r.bit() != stop) i += 1;
        return i;
    }

    /// `get_ur_golomb_jpegls` with the uncached reader: a unary quotient of
    /// at most `limit` zeros, then `k` bits; `0xffffffff` when the zeros run
    /// past the end of the input or reach `limit`, with `esc_len` bits plus
    /// one at `limit - 1`.
    pub fn golombJpegls(r: *BitReader, k: u5, limit: i32, esc_len: u6) u32 {
        const min_cache_bits = 25;
        const cache = r.peek(32);
        const log: i32 = if (cache == 0) 0 else 31 - @as(i32, @clz(cache));
        if (log - @as(i32, k) >= 32 - min_cache_bits and 32 - log < limit) {
            const fall: u5 = @intCast(log - @as(i32, k));
            const base: u32 = @bitCast(30 -% log);
            const value = (cache >> fall) +% (base << k);
            r.skip(@intCast(32 + @as(i32, k) - log));
            return value;
        }
        var i: i32 = 0;
        while (i + min_cache_bits <= limit and r.peek(min_cache_bits) == 0) : (i += min_cache_bits) {
            if (r.size <= r.index) return 0xffff_ffff;
            r.skip(min_cache_bits);
        }
        while (i < limit and r.peek(1) == 0) : (i += 1) r.skip(1);
        r.skip(1);
        if (i < limit - 1) {
            const quotient: u32 = @intCast(i);
            return r.bits(k) +% (quotient << k);
        } else if (esc_len != 0 and i == limit - 1) {
            return r.bits(esc_len) +% 1;
        }
        return 0xffff_ffff;
    }

    /// `get_sr_golomb_flac`: `golombJpegls` folded to a signed value.
    pub fn riceFlac(r: *BitReader, k: u5, limit: i32, esc_len: u6) i32 {
        const v = r.golombJpegls(k, limit, esc_len);
        return @bitCast((v >> 1) ^ (0 -% (v & 1)));
    }
};

/// FFmpeg's checked reader under BITSTREAM_READER_LE (Vorbis, T18c): the
/// first bit read is each byte's least significant, and a value's first
/// bit is its least significant. Over-reads behave as `BitReader`'s.
pub const LsbReader = struct {
    bytes: []const u8,
    /// The bits read so far, at most `size + 8`.
    index: usize = 0,
    /// `bytes.len * 8`.
    size: usize,

    pub const InitError = BitReader.InitError;

    /// `init_get_bits8`.
    pub fn init(bytes: []const u8) InitError!LsbReader {
        const limit = (std.math.maxInt(i32) - 64 * 8) / 8;
        if (bytes.len >= limit) return error.InputTooLarge;
        return .{ .bytes = bytes, .size = bytes.len * 8 };
    }

    /// The next 57 or more bits, the first in bit 0; zeros past the end.
    fn window(r: *const LsbReader) u64 {
        const start = r.index >> 3;
        const shift: u6 = @intCast(r.index & 7);
        if (start + 8 <= r.bytes.len) {
            return std.mem.readInt(u64, r.bytes[start..][0..8], .little) >> shift;
        }
        var w: u64 = 0;
        for (0..8) |k| {
            const at = start + k;
            const byte: u64 = if (at < r.bytes.len) r.bytes[at] else 0;
            w |= byte << @intCast(8 * k);
        }
        return w >> shift;
    }

    /// `show_bits_long`: the next `n` bits (0 to 32) without consuming them.
    pub fn peek(r: *const LsbReader, n: u6) u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        const mask = (@as(u64, 1) << n) - 1;
        return @intCast(r.window() & mask);
    }

    /// `skip_bits`: consumes `n` bits, the count saturating 8 bits past the
    /// end.
    pub fn skip(r: *LsbReader, n: usize) void {
        r.index = @min(r.size + 8, r.index + @min(n, r.size + 8));
    }

    /// `get_bits_long`: the next `n` bits (0 to 32).
    pub fn bits(r: *LsbReader, n: u6) u32 {
        const value = r.peek(n);
        r.skip(n);
        return value;
    }

    /// `get_bits1`.
    pub fn bit(r: *LsbReader) u1 {
        return @intCast(r.bits(1));
    }

    /// `get_bits_count`.
    pub fn count(r: *const LsbReader) usize {
        return r.index;
    }

    /// `get_bits_left`: negative after an over-read.
    pub fn left(r: *const LsbReader) i64 {
        const size: i64 = @intCast(r.size);
        const index: i64 = @intCast(r.index);
        return size - index;
    }
};

const testing = std.testing;

/// An MSB-first bit writer over a caller's slice (TODO.md T18b), FFmpeg's
/// `PutBitContext` as the FLAC encoder uses it. Bits gather in a small
/// accumulator and whole bytes go to the slice; `flush` pads the last byte
/// with zeros. A write that would pass the end of the slice is dropped and
/// sets `overflow`, as FFmpeg's writer drops it with an error, so no write
/// touches memory past the slice in any optimize mode.
pub const BitWriter = struct {
    bytes: []u8,
    /// Whole bytes written to `bytes`.
    pos: usize = 0,
    /// Bits not yet in `bytes`, right-aligned: fewer than 8 between calls.
    acc: u64 = 0,
    acc_len: u6 = 0,
    /// A write was dropped for lack of room.
    overflow: bool = false,

    pub fn init(bytes: []u8) BitWriter {
        return .{ .bytes = bytes };
    }

    /// `put_bits_count`: the bits written so far.
    pub fn count(w: *const BitWriter) usize {
        return w.pos * 8 + w.acc_len;
    }

    /// The low `n` bits (0 to 56) of `value`, which must not have higher
    /// bits set (FFmpeg's `put_bits` assumes the same).
    fn putShort(w: *BitWriter, n: u6, value: u64) void {
        std.debug.assert(n <= 56);
        std.debug.assert(value >> n == 0);
        if (n == 0) return;
        if (w.count() + n > w.bytes.len * 8) {
            w.overflow = true;
            return;
        }
        w.acc = (w.acc << n) | value;
        var len: u7 = @as(u7, w.acc_len) + n;
        while (len >= 8) {
            len -= 8;
            w.bytes[w.pos] = @truncate(w.acc >> @intCast(len));
            w.pos += 1;
        }
        w.acc_len = @intCast(len);
        w.acc &= (@as(u64, 1) << w.acc_len) - 1;
    }

    /// `put_bits`, `put_bits32` and `put_bits63`: the low `n` bits (0 to
    /// 64) of `value`, the high part first.
    pub fn bits(w: *BitWriter, n: u7, value: u64) void {
        std.debug.assert(n <= 64);
        std.debug.assert(n == 64 or value >> @intCast(n) == 0);
        if (n > 32) {
            w.putShort(@intCast(n - 32), value >> 32);
            w.putShort(32, value & 0xffff_ffff);
        } else {
            w.putShort(@intCast(n), value);
        }
    }

    /// `put_sbits` and `put_sbits63`: the low `n` bits (0 to 64) of a
    /// signed value, two's complement.
    pub fn signed(w: *BitWriter, n: u7, value: i64) void {
        const raw: u64 = @bitCast(value);
        const mask: u64 = if (n == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
        w.bits(n, raw & mask);
    }

    /// `set_sr_golomb_flac`: FLAC's Rice code of `value` with parameter
    /// `k`: the folded value's quotient in unary (zeros then a one), then
    /// its low `k` bits.
    pub fn riceFlac(w: *BitWriter, value: i32, k: u5) void {
        const v: u32 = @bitCast((value << 1) ^ (value >> 31));
        // FFmpeg's `e` is unsigned; a 64-bit count keeps the impossible
        // all-ones value with k = 0 from wrapping.
        var e: u64 = (@as(u64, v) >> k) + 1;
        while (e > 31) : (e -= 31) w.bits(31, 0);
        w.bits(@intCast(e), 1);
        if (k != 0) w.bits(k, v & ((@as(u32, 1) << k) - 1));
    }

    /// `flush_put_bits`: pads the last byte with zero bits.
    pub fn flush(w: *BitWriter) void {
        if (w.acc_len == 0) return;
        const pad: u6 = 8 - w.acc_len;
        w.putShort(pad, 0);
    }

    /// The bytes written; after `flush`, every bit.
    pub fn written(w: *const BitWriter) []u8 {
        return w.bytes[0..w.pos];
    }
};

/// The bit at `at` of `bytes`, MSB first, 0 past the end: the reference the
/// reader is checked against.
fn naiveBit(bytes: []const u8, at: usize) u32 {
    if (at / 8 >= bytes.len) return 0;
    const shift: u3 = @intCast(7 - at % 8);
    return (bytes[at / 8] >> shift) & 1;
}

fn naiveBits(bytes: []const u8, at: usize, n: u6) u32 {
    var value: u32 = 0;
    for (0..n) |k| value = (value << 1) | naiveBit(bytes, at + k);
    return value;
}

test "every width at every offset reads as the bits do, zeros past the end" {
    var pattern: [13]u8 = undefined;
    var x: u64 = 1;
    for (&pattern) |*b| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        b.* = @truncate(x >> 56);
    }
    for (0..pattern.len + 2) |len| {
        const bytes = pattern[0..@min(len, pattern.len)];
        for (0..bytes.len * 8 + 8) |offset| {
            for (0..33) |width| {
                const n: u6 = @intCast(width);
                var r = try BitReader.init(bytes);
                r.skip(offset);
                const expected = naiveBits(bytes, r.count(), n);
                try testing.expectEqual(expected, r.peek(n));
                try testing.expectEqual(expected, r.bits(n));
                try testing.expectEqual(@min(bytes.len * 8 + 8, offset + width), r.count());
            }
        }
    }
}

test "signed reads sign-extend, as get_sbits_long" {
    const bytes = [_]u8{ 0xff, 0x80, 0x00, 0x01, 0x7f, 0xff, 0xff, 0xff };
    var r = try BitReader.init(&bytes);
    try testing.expectEqual(-1, r.signed(8));
    try testing.expectEqual(-32768, r.signed(16));
    try testing.expectEqual(1, r.signed(8));
    try testing.expectEqual(std.math.maxInt(i32), r.signed(32));
    r = try BitReader.init(&bytes);
    try testing.expectEqual(0, r.signed(0));
    try testing.expectEqual(-1, r.signed(1));
    const expected: i32 = @bitCast(naiveBits(&bytes, 1, 32));
    try testing.expectEqual(expected, r.signed(32));
}

test "over-reads give zeros and saturate the count 8 bits past the end" {
    const bytes = [_]u8{ 0xab, 0xcd };
    var r = try BitReader.init(&bytes);
    try testing.expectEqual(0xabcd0000, r.bits(32));
    try testing.expectEqual(24, r.count());
    try testing.expectEqual(-8, r.left());
    try testing.expectEqual(0, r.bits(32));
    try testing.expectEqual(0, r.bit());
    try testing.expectEqual(24, r.count());
    r.alignByte();
    try testing.expectEqual(24, r.count());
    r = try BitReader.init(&bytes);
    r.skip(std.math.maxInt(usize));
    try testing.expectEqual(24, r.count());
    // An empty slice reads zeros too.
    var empty = try BitReader.init(&.{});
    try testing.expectEqual(0, empty.bits(17));
    try testing.expectEqual(-8, empty.left());
}

test "a frame inside a packet reads the packet's next bytes past its end, as FFmpeg's reader does" {
    const packet = [_]u8{ 0xab, 0xcd, 0x12, 0x34, 0x56 };
    var r = try BitReader.initIn(&packet, 2);
    try testing.expectEqual(0xabcd, r.bits(16));
    try testing.expectEqual(0, r.left());
    // The count stops 8 bits on, so every later read sees the byte after.
    try testing.expectEqual(0x12, r.bits(8));
    try testing.expectEqual(0x34, r.bits(8));
    try testing.expectEqual(0x34, r.bits(8));
    try testing.expectEqual(24, r.count());
    // Past the packet, its zero padding.
    var last = try BitReader.initIn(packet[3..], 1);
    try testing.expectEqual(0x34, last.bits(8));
    try testing.expectEqual(0x5600, last.bits(16));
}

test "64-bit reads: 33-bit samples, sign-extended" {
    const bytes = [_]u8{ 0x80, 0x00, 0x00, 0x00, 0x7f, 0xff, 0xff, 0xff, 0xc0 };
    var r = try BitReader.init(&bytes);
    // 1 followed by 32 zeros: -2^32 in 33 bits.
    try testing.expectEqual(-(@as(i64, 1) << 32), r.signed64(33));
    try testing.expectEqual(33, r.count());
    r = try BitReader.init(&bytes);
    try testing.expectEqual(0x8000_0000_7fff_ffff, r.bits64(64));
    try testing.expectEqual(0xc0, r.bits64(8));
}

test "alignment and unary codes" {
    const bytes = [_]u8{ 0b1010_0000, 0b0001_0000, 0xff };
    var r = try BitReader.init(&bytes);
    try testing.expectEqual(1, r.bit());
    r.alignByte();
    try testing.expectEqual(8, r.count());
    // Three zeros, then the stopping 1.
    try testing.expectEqual(3, r.unary(1, 100));
    try testing.expectEqual(12, r.count());
    // A length bound stops early without a stop bit.
    try testing.expectEqual(2, r.unary(1, 2));
    try testing.expectEqual(14, r.count());
}

/// FLAC's Rice code of `value` with parameter `k`, as bits into `out`.
fn putRice(out: *std.ArrayList(u1), gpa: std.mem.Allocator, value: i32, k: u5) !void {
    const folded: u32 = @bitCast((value << 1) ^ (value >> 31));
    const quotient = folded >> k;
    try out.appendNTimes(gpa, 0, quotient);
    try out.append(gpa, 1);
    var bit_index: u6 = k;
    while (bit_index > 0) {
        bit_index -= 1;
        try out.append(gpa, @intCast((folded >> @intCast(bit_index)) & 1));
    }
}

fn packBits(gpa: std.mem.Allocator, bit_list: []const u1) ![]u8 {
    const out = try gpa.alloc(u8, (bit_list.len + 7) / 8);
    @memset(out, 0);
    for (bit_list, 0..) |b, i| {
        const shift: u3 = @intCast(7 - i % 8);
        out[i / 8] |= @as(u8, b) << shift;
    }
    return out;
}

/// FLAC's limit for Rice parameter `k`, as flacdec.c's decode_residuals.
fn flacLimit(k: u5) i32 {
    const max: i32 = std.math.maxInt(i32);
    return if (k > 1) (max >> (k - 1)) + 2 else max;
}

test "Rice codes round trip for every parameter, quotients long and short" {
    const gpa = testing.allocator;
    const values = [_]i32{ 0, 1, -1, 2, -2, 7, -8, 100, -100, 1000, -1000, 32767, -32768, 65535, -65536, 1 << 20, -(1 << 20) };
    for (0..31) |kk| {
        const k: u5 = @intCast(kk);
        var stream: std.ArrayList(u1) = .empty;
        defer stream.deinit(gpa);
        var expected: std.ArrayList(i32) = .empty;
        defer expected.deinit(gpa);
        for (values) |v| {
            const folded: u32 = @bitCast((v << 1) ^ (v >> 31));
            // Keep quotients encodable within the limit and short enough
            // for the test.
            if (folded >> k > 3000) continue;
            if (@as(i64, folded >> k) >= flacLimit(k) - 1) continue;
            try putRice(&stream, gpa, v, k);
            try expected.append(gpa, v);
        }
        const bytes = try packBits(gpa, stream.items);
        defer gpa.free(bytes);
        var r = try BitReader.init(bytes);
        for (expected.items) |v| try testing.expectEqual(v, r.riceFlac(k, flacLimit(k), 1));
        try testing.expectEqual(stream.items.len, r.count());
    }
}

test "a quotient that runs past the end is FFmpeg's invalid residual" {
    // 30 zero bits and nothing after: the 25-bit steps reach the end.
    const bytes = [_]u8{ 0, 0, 0, 0 };
    var r = try BitReader.init(&bytes[0..3].*);
    try testing.expectEqual(std.math.minInt(i32), r.riceFlac(0, flacLimit(0), 1));
    // A quotient at the limit is invalid too; one below it escapes.
    const limit = flacLimit(30);
    try testing.expectEqual(5, limit);
    const at_limit = [_]u8{0b0000_0000};
    r = try BitReader.init(&at_limit);
    try testing.expectEqual(std.math.minInt(i32), r.riceFlac(30, limit, 1));
    // Four zeros (limit - 1), the 1, then esc_len = 1 bit (1), plus one: 2,
    // which folds to 1.
    const escaped = [_]u8{0b0000_1100};
    r = try BitReader.init(&escaped);
    try testing.expectEqual(1, r.riceFlac(30, limit, 1));
}

test "the CRCs equal FFmpeg's on the standard check input" {
    // FFmpeg's av_crc(AV_CRC_8_ATM, 0, "123456789", 9) is 0xf4; its
    // AV_CRC_16_ANSI result is the byte-swapped 0xe8fe of CRC-16/UMTS's
    // 0xfee8.
    try testing.expectEqual(0xf4, Crc8.hash("123456789"));
    try testing.expectEqual(0xfee8, Crc16.hash("123456789"));
    // A message followed by its CRC checks to zero, which is all FLAC asks.
    const header = [_]u8{ 0xff, 0xf8, 0x69, 0x08, 0x00, 0x00 };
    var with_crc: [7]u8 = undefined;
    @memcpy(with_crc[0..6], &header);
    with_crc[6] = Crc8.hash(&header);
    try testing.expectEqual(0, Crc8.hash(&with_crc));
    var crc: Crc16 = .init();
    crc.update(with_crc[0..3]);
    crc.update(with_crc[3..]);
    const value = crc.final();
    var framed: [9]u8 = undefined;
    @memcpy(framed[0..7], &with_crc);
    std.mem.writeInt(u16, framed[7..9], value, .big);
    try testing.expectEqual(0, Crc16.hash(&framed));
}

test "the writer round-trips every width at every offset through the reader" {
    var buffer: [64]u8 = undefined;
    var x: u64 = 7;
    for (0..8) |offset| {
        for (0..65) |width| {
            @memset(&buffer, 0xaa);
            var w: BitWriter = .init(&buffer);
            const n: u7 = @intCast(width);
            w.bits(@intCast(offset), 0);
            var values: [3]u64 = undefined;
            for (&values) |*v| {
                x = x *% 6364136223846793005 +% 1442695040888963407;
                v.* = if (n == 64) x else x & ((@as(u64, 1) << @intCast(n)) - 1);
                w.bits(n, v.*);
            }
            try testing.expectEqual(offset + 3 * width, w.count());
            w.flush();
            try testing.expect(!w.overflow);
            try testing.expectEqual((offset + 3 * width + 7) / 8, w.written().len);
            var r = try BitReader.init(w.written());
            r.skip(offset);
            for (values) |v| try testing.expectEqual(v, r.bits64(n));
            // flush pads with zeros, never with what the buffer held.
            try testing.expectEqual(0, r.bits64(@intCast(r.left())));
        }
    }
}

test "signed writes round-trip, 33-bit samples included" {
    var buffer: [32]u8 = undefined;
    var w: BitWriter = .init(&buffer);
    const values = [_]struct { u7, i64 }{ .{ 1, -1 }, .{ 5, -16 }, .{ 5, 15 }, .{ 16, -32768 }, .{ 32, std.math.minInt(i32) }, .{ 33, -(1 << 32) }, .{ 33, (1 << 32) - 1 }, .{ 64, std.math.minInt(i64) } };
    for (values) |v| w.signed(v[0], v[1]);
    w.flush();
    var r = try BitReader.init(w.written());
    for (values) |v| try testing.expectEqual(v[1], r.signed64(v[0]));
}

test "Rice writes round-trip through the reader for every parameter" {
    const values = [_]i32{ 0, 1, -1, 2, -2, 7, -8, 100, -100, 1000, -1000, 32767, -32768, 65535, -65536, 1 << 20, -(1 << 20) };
    for (0..31) |kk| {
        const k: u5 = @intCast(kk);
        var buffer: [16384]u8 = undefined;
        var w: BitWriter = .init(&buffer);
        var expected: [values.len]i32 = undefined;
        var n: usize = 0;
        for (values) |v| {
            const folded: u32 = @bitCast((v << 1) ^ (v >> 31));
            if (folded >> k > 3000) continue;
            if (@as(i64, folded >> k) >= flacLimit(k) - 1) continue;
            w.riceFlac(v, k);
            expected[n] = v;
            n += 1;
        }
        const bits_written = w.count();
        w.flush();
        try testing.expect(!w.overflow);
        var r = try BitReader.init(w.written());
        for (expected[0..n]) |v| try testing.expectEqual(v, r.riceFlac(k, flacLimit(k), 1));
        try testing.expectEqual(bits_written, r.count());
    }
    // A quotient past 31 is written in runs of 31 zeros, as FFmpeg's is.
    var buffer: [16]u8 = undefined;
    var w: BitWriter = .init(&buffer);
    w.riceFlac(40, 0);
    try testing.expectEqual(81, w.count());
}

test "a write past the end is dropped and flagged, nothing past the slice touched" {
    var backing = [_]u8{ 0, 0, 0x55 };
    var w: BitWriter = .init(backing[0..2]);
    w.bits(12, 0xabc);
    w.bits(4, 0xd);
    try testing.expect(!w.overflow);
    w.bits(1, 1);
    try testing.expect(w.overflow);
    try testing.expectEqual(16, w.count());
    w.flush();
    try testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 0x55 }, &backing);
}

test "the LSB-first reader takes each byte's low bits first, values low bit first" {
    var r = try LsbReader.init(&.{ 0b1010_1101, 0x34, 0x12, 0xff, 0x01 });
    try testing.expectEqual(1, r.bit());
    try testing.expectEqual(0b110, r.bits(3));
    try testing.expectEqual(0b1010, r.bits(4));
    try testing.expectEqual(0x1234, r.bits(16));
    try testing.expectEqual(0x1ff, r.peek(9));
    // 16 bits were left: the rest reads as zeros, the count stops 8 bits on.
    try testing.expectEqual(0x1ff, r.bits(32));
    try testing.expectEqual(-8, r.left());
}

test "the LSB-first reader reads zeros past the end and stops counting 8 bits on" {
    var r = try LsbReader.init(&.{0xff});
    try testing.expectEqual(0xff, r.bits(32));
    try testing.expectEqual(-8, r.left());
    try testing.expectEqual(0, r.bits(32));
    try testing.expectEqual(16, r.count());
    try testing.expectEqual(0, r.bit());
    try testing.expectEqual(16, r.count());
    var empty = try LsbReader.init(&.{});
    try testing.expectEqual(0, empty.bits(32));
    try testing.expectEqual(8, empty.count());
}
