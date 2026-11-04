// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/vlc.c (build_table, alloc_table,
// ff_vlc_init_sparse, compare_vlcspec) and get_bits.h (GET_VLC, get_vlc2)
// at the pinned reference revision.
// Copyright (c) 2000, 2001 Fabrice Bellard
// Copyright (c) 2002-2004 Michael Niedermayer <michaelni@gmx.at>
// Copyright (c) 2010 Loren Merritt
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's VLC decoding tables (TODO.md T18c): `ff_vlc_init_sparse`
//! builds multi-level lookup tables from code lengths and codewords, each
//! level indexed by up to `nb_bits` bits, and `get` (`get_vlc2`) decodes
//! one symbol through at most `max_depth` levels.
//!
//! The tables are FFmpeg's entry for entry (vectors/vlc.txt), including
//! the int16 symbols and subtable offsets, the -1 symbol of an unused
//! entry and the codes FFmpeg refuses. `build` fills a caller's buffer,
//! so a codec can build a static table at compile time; `Vlc.init`
//! allocates one at run time (Vorbis' codebooks).

const std = @import("std");
const bits = @import("bits.zig");

/// `VLCElem`: a symbol and its length, or for a longer code the offset
/// of its subtable and the negated bits that index it. An entry no code
/// reaches has length 0 and symbol -1.
pub const Elem = struct {
    sym: i16,
    len: i16,
};

pub const Flags = struct {
    /// VLC_INIT_INPUT_LE: a codeword's first bit is its least significant.
    input_le: bool = false,
    /// VLC_INIT_OUTPUT_LE: the table is for an LSB-first reader.
    output_le: bool = false,

    /// VLC_INIT_LE, Vorbis' choice.
    pub const le: Flags = .{ .input_le = true, .output_le = true };
};

pub const Error = error{
    /// A length above 32 or 3 * nb_bits, a codeword wider than its length,
    /// or a level above 30 bits (FFmpeg's EINVAL).
    InvalidLength,
    /// Two codes claim the same entry (FFmpeg's INVALIDDATA, "incorrect
    /// codes").
    IncorrectCodes,
    /// A subtable offset that does not fit the int16 symbol (FFmpeg's
    /// PATCHWELCOME, "strange codes").
    StrangeCodes,
    /// `build`'s buffer is too small (FFmpeg's static tables abort).
    TableTooSmall,
};

/// `VLCcode`: a codeword left-aligned in 32 bits, its first bit to read in
/// the most significant.
pub const Code = struct {
    bits: u8,
    symbol: i16,
    code: u32,
};

/// The table being built: `size` entries of `elems` used.
const Builder = struct {
    elems: []Elem,
    size: usize = 0,

    /// alloc_table: `n` fresh entries, zeroed as FFmpeg's realloc leaves them.
    fn alloc(b: *Builder, n: usize) Error!usize {
        if (b.elems.len - b.size < n) return error.TableTooSmall;
        const index = b.size;
        @memset(b.elems[index..][0..n], .{ .sym = 0, .len = 0 });
        b.size += n;
        return index;
    }
};

fn bitswap32(x: u32) u32 {
    return @bitReverse(x);
}

/// build_table: the level of `table_nb_bits` bits for `codes` (whose codes
/// going into the same subtable are contiguous), its subtables after it;
/// returns the level's offset.
fn buildTable(b: *Builder, table_nb_bits: u32, codes: []Code, flags: Flags) Error!usize {
    if (table_nb_bits > 30) return error.InvalidLength;
    const table_size = @as(usize, 1) << @intCast(table_nb_bits);
    const table_index = try b.alloc(table_size);
    var i: usize = 0;
    while (i < codes.len) : (i += 1) {
        var n: u32 = codes[i].bits;
        const code = codes[i].code;
        const symbol = codes[i].symbol;
        if (n <= table_nb_bits) {
            // No need for another level.
            var j: usize = if (table_nb_bits == 0) 0 else code >> @intCast(32 - table_nb_bits);
            const nb = @as(usize, 1) << @intCast(table_nb_bits - n);
            var inc: usize = 1;
            if (flags.output_le) {
                j = bitswap32(code);
                inc = @as(usize, 1) << @intCast(n);
            }
            for (0..nb) |_| {
                const e = &b.elems[table_index + j];
                if ((e.len != 0 or e.sym != 0) and (e.len != n or e.sym != symbol)) return error.IncorrectCodes;
                e.* = .{ .len = @intCast(n), .sym = symbol };
                j += inc;
            }
        } else {
            // A subtable for the codes sharing this prefix.
            n -= table_nb_bits;
            const code_prefix = code >> @intCast(32 - table_nb_bits);
            var subtable_bits = n;
            codes[i].bits = @intCast(n);
            codes[i].code = code << @intCast(table_nb_bits);
            var k = i + 1;
            while (k < codes.len) : (k += 1) {
                if (codes[k].bits <= table_nb_bits) break;
                const rest: u32 = codes[k].bits - table_nb_bits;
                const other = codes[k].code;
                if (other >> @intCast(32 - table_nb_bits) != code_prefix) break;
                codes[k].bits = @intCast(rest);
                codes[k].code = other << @intCast(table_nb_bits);
                subtable_bits = @max(subtable_bits, rest);
            }
            subtable_bits = @min(subtable_bits, table_nb_bits);
            const j: usize = if (flags.output_le) bitswap32(code_prefix) >> @intCast(32 - table_nb_bits) else code_prefix;
            b.elems[table_index + j].len = -@as(i16, @intCast(subtable_bits));
            const index = try buildTable(b, subtable_bits, codes[i..k], flags);
            // FFmpeg stores the offset in the int16 symbol and refuses one
            // that does not survive it.
            const stored: i16 = @truncate(@as(isize, @intCast(index)));
            if (stored != @as(isize, @intCast(index))) return error.StrangeCodes;
            b.elems[table_index + j].sym = stored;
            i = k - 1;
        }
    }
    for (b.elems[table_index..][0..table_size]) |*e| {
        if (e.len == 0) e.sym = -1;
    }
    return table_index;
}

/// The codes `ff_vlc_init_sparse` builds from: those longer than
/// `nb_bits` first, sorted by codeword (FFmpeg compares `code >> 1`),
/// then the others in their order; a zero length is no code. `codes`
/// holds at least `lens.len` entries; returns how many it filled.
fn collect(codes: []Code, nb_bits: u32, lens: []const u8, codewords: []const u32, symbols: ?[]const i16, flags: Flags) Error![]Code {
    var j: usize = 0;
    for (0..2) |pass| {
        for (lens, codewords, 0..) |len, codeword, i| {
            const long = len > nb_bits;
            if (if (pass == 0) !long else !(len != 0 and !long)) continue;
            if (len > 3 * nb_bits or len > 32) return error.InvalidLength;
            if (@as(u64, codeword) >= @as(u64, 1) << @intCast(len)) return error.InvalidLength;
            codes[j] = .{
                .bits = len,
                .code = if (flags.input_le) bitswap32(codeword) else if (len == 0) 0 else codeword << @intCast(32 - @as(u32, len)),
                // VLCBaseType: an int16, as FFmpeg truncates the index.
                .symbol = if (symbols) |s| s[i] else @truncate(@as(isize, @intCast(i))),
            };
            j += 1;
        }
        if (pass == 0) {
            std.sort.pdq(Code, codes[0..j], {}, struct {
                fn lessThan(_: void, a: Code, b: Code) bool {
                    return a.code >> 1 < b.code >> 1;
                }
            }.lessThan);
        }
    }
    return codes[0..j];
}

/// `ff_vlc_init_sparse` into `out`: returns the entries used. `work` holds
/// at least `lens.len` codes, which the build rewrites.
pub fn build(out: []Elem, work: []Code, nb_bits: u5, lens: []const u8, codewords: []const u32, symbols: ?[]const i16, flags: Flags) Error!usize {
    std.debug.assert(lens.len == codewords.len and work.len >= lens.len);
    if (symbols) |s| std.debug.assert(s.len == lens.len);
    const codes = try collect(work, nb_bits, lens, codewords, symbols, flags);
    var b: Builder = .{ .elems = out };
    _ = try buildTable(&b, nb_bits, codes, flags);
    return b.size;
}

/// A table built at run time.
pub const Vlc = struct {
    nb_bits: u5,
    table: []Elem,

    /// `ff_vlc_init_sparse` (`vlc_init`): the table for `lens[i]` and
    /// `codewords[i]` (symbol i, or `symbols[i]`).
    pub fn init(gpa: std.mem.Allocator, nb_bits: u5, lens: []const u8, codewords: []const u32, symbols: ?[]const i16, flags: Flags) (Error || error{OutOfMemory})!Vlc {
        const work = try gpa.alloc(Code, lens.len);
        defer gpa.free(work);
        // The levels' sizes are not known before the build: grow and retry.
        var capacity: usize = @as(usize, 1) << nb_bits;
        while (true) {
            const table = try gpa.alloc(Elem, capacity);
            const used = build(table, work, nb_bits, lens, codewords, symbols, flags) catch |err| {
                gpa.free(table);
                if (err == error.TableTooSmall) {
                    capacity *= 2;
                    continue;
                }
                return err;
            };
            return .{ .nb_bits = nb_bits, .table = gpa.realloc(table, used) catch table[0..used] };
        }
    }

    pub fn deinit(v: *Vlc, gpa: std.mem.Allocator) void {
        gpa.free(v.table);
        v.* = undefined;
    }

    /// `get_vlc2` on an LSB-first reader (the table built with
    /// `output_le`): the symbol, or -1 for a code the table lacks, which
    /// consumes nothing at its level.
    pub fn get(v: *const Vlc, r: *bits.LsbReader, max_depth: u2) i32 {
        return lookup(v.table, r, v.nb_bits, max_depth);
    }
};

/// GET_VLC over `table`, whose first level has `nb_bits` bits.
pub fn lookup(table: []const Elem, r: *bits.LsbReader, nb_bits: u5, max_depth: u2) i32 {
    var index: usize = r.peek(nb_bits);
    var code: i32 = table[index].sym;
    var n: i32 = table[index].len;
    if (max_depth > 1 and n < 0) {
        r.skip(nb_bits);
        var level_bits: u6 = @intCast(-n);
        index = @as(usize, r.peek(level_bits)) + @as(usize, @intCast(code));
        code = table[index].sym;
        n = table[index].len;
        if (max_depth > 2 and n < 0) {
            r.skip(level_bits);
            level_bits = @intCast(-n);
            index = @as(usize, r.peek(level_bits)) + @as(usize, @intCast(code));
            code = table[index].sym;
            n = table[index].len;
        }
    }
    if (n >= 0) {
        r.skip(@intCast(n));
    } else {
        // A code longer than `max_depth` levels (never for a table whose
        // codes fit them): FFmpeg's unsigned index steps back, or wraps
        // and saturates at the end plus 8.
        const back: usize = @intCast(-n);
        r.index = if (r.index >= back) r.index - back else r.size + 8;
    }
    return code;
}

const testing = std.testing;
const vectors = @embedFile("../testing/vectors/vlc.txt");

/// vlc_vectors.c's generator.
const Generator = struct {
    state: u32,

    fn next(g: *Generator) u32 {
        g.state = g.state *% 1103515245 +% 12345;
        return g.state >> 16;
    }

    /// make_lengths: a complete prefix code of up to `count` leaves.
    fn lengths(g: *Generator, lens: []u8, count: usize, max_len: u8) usize {
        var n: usize = 1;
        lens[0] = 0;
        while (n < count) {
            var idx: usize = g.next() % n;
            var tries: usize = 0;
            while (lens[idx] >= max_len and tries < n) {
                idx = (idx + 1) % n;
                tries += 1;
            }
            if (tries == n) break;
            lens[idx] += 1;
            lens[n] = lens[idx];
            n += 1;
        }
        return n;
    }
};

/// make_codes: canonical codewords, reversed within their length for LE.
fn canonicalCodes(lens: []const u8, codes: []u32, le: bool) void {
    var count: [34]u64 = @splat(0);
    var next_code: [34]u64 = @splat(0);
    for (lens) |len| count[len] += 1;
    count[0] = 0;
    for (1..34) |len| next_code[len] = (next_code[len - 1] + count[len - 1]) << 1;
    for (lens, codes) |len, *code| {
        if (len == 0) continue;
        var c: u32 = @truncate(next_code[len]);
        next_code[len] += 1;
        if (le) c = @bitReverse(c) >> @intCast(32 - @as(u32, len));
        code.* = c;
    }
}

test "every table equals FFmpeg's entry for entry (vectors/vlc.txt)" {
    const gpa = testing.allocator;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    var cases: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "V ")) continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next();
        const count = try std.fmt.parseInt(usize, f.next().?, 10);
        const max_len = try std.fmt.parseInt(u8, f.next().?, 10);
        const nb_bits = try std.fmt.parseInt(u5, f.next().?, 10);
        const le = std.mem.eql(u8, f.next().?, "1");
        const seed = try std.fmt.parseInt(u32, f.next().?, 10);
        const drop = try std.fmt.parseInt(usize, f.next().?, 10);
        const variant = try std.fmt.parseInt(u8, f.next().?, 10);
        var lens: [1024]u8 = undefined;
        var codes: [1024]u32 = undefined;
        var symbols: [1024]i16 = undefined;
        var g: Generator = .{ .state = seed };
        const n = g.lengths(&lens, count, max_len);
        canonicalCodes(lens[0..n], codes[0..n], le);
        for (symbols[0..n], 0..) |*s, i| s.* = @truncate(@as(isize, @intCast(i)) * 3 - 50);
        if (drop != 0) {
            var i = drop - 1;
            while (i < n) : (i += drop) lens[i] = 0;
        }
        if (variant == 2 and n > 2) {
            lens[1] = lens[0];
            codes[1] = codes[0];
        }
        if (variant == 3 and lens[0] < 32) codes[0] |= @as(u32, 1) << @intCast(lens[0]);
        const flags: Flags = if (le) .le else .{};
        var got: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&got);
        if (Vlc.init(gpa, nb_bits, lens[0..n], codes[0..n], if (variant == 1) symbols[0..n] else null, flags)) |built| {
            var v = built;
            defer v.deinit(gpa);
            var md5: std.crypto.hash.Md5 = .init(.{});
            for (v.table) |e| {
                var entry: [4]u8 = undefined;
                std.mem.writeInt(i16, entry[0..2], e.sym, .little);
                std.mem.writeInt(i16, entry[2..4], e.len, .little);
                md5.update(&entry);
            }
            var digest: [16]u8 = undefined;
            md5.final(&digest);
            try w.print("R 0 {d} {x}", .{ v.table.len, digest });
        } else |err| {
            const name = switch (err) {
                error.IncorrectCodes => "INVALIDDATA",
                error.InvalidLength => "EINVAL",
                else => return err,
            };
            try w.print("R {s} 0 d41d8cd98f00b204e9800998ecf8427e", .{name});
        }
        testing.expectEqualStrings(lines.next().?, w.buffered()) catch |err| {
            std.debug.print("{s}\n", .{line});
            return err;
        };
        cases += 1;
    }
    try testing.expectEqual(678, cases);
}

test "every code decodes back to its symbol through the levels, LSB first" {
    const gpa = testing.allocator;
    for ([_]u5{ 3, 6, 9 }) |nb_bits| {
        var lens: [300]u8 = undefined;
        var codes: [300]u32 = undefined;
        var g: Generator = .{ .state = nb_bits };
        const n = g.lengths(&lens, 300, 3 * @as(u8, nb_bits));
        canonicalCodes(lens[0..n], codes[0..n], true);
        var v = try Vlc.init(gpa, nb_bits, lens[0..n], codes[0..n], null, .le);
        defer v.deinit(gpa);
        // Every symbol in turn, packed LSB first.
        var stream: [4096]u8 = @splat(0);
        var at: usize = 0;
        for (lens[0..n], codes[0..n]) |len, code| {
            for (0..len) |b| {
                if ((code >> @intCast(b)) & 1 != 0) stream[at >> 3] |= @as(u8, 1) << @intCast(at & 7);
                at += 1;
            }
        }
        var r = try bits.LsbReader.init(stream[0 .. (at + 7) / 8]);
        for (0..n) |i| try testing.expectEqual(@as(i32, @intCast(i)), v.get(&r, 3));
        try testing.expectEqual(at, r.count());
    }
}

test "an incomplete code reads -1 where no code reaches, consuming nothing there" {
    const gpa = testing.allocator;
    // Lengths 1 and 2: the code 11 (LSB first) is missing.
    var v = try Vlc.init(gpa, 2, &.{ 1, 2 }, &.{ 0, 1 }, null, .le);
    defer v.deinit(gpa);
    var r = try bits.LsbReader.init(&.{0b0000_0011});
    try testing.expectEqual(-1, v.get(&r, 1));
    try testing.expectEqual(0, r.count());
    // Past the end, the reader's zeros decode as the 1-bit code.
    var empty = try bits.LsbReader.init(&.{});
    try testing.expectEqual(0, v.get(&empty, 1));
    try testing.expectEqual(1, empty.count());
}
