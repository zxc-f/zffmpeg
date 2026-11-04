// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavcodec/vorbisdec.c, vorbis.c (ff_vorbis_len2vlc,
// ff_vorbis_nth_root, ff_vorbis_ready_floor1_list, render_line,
// ff_vorbis_floor1_render_list), vorbisdsp.c (vorbis_inverse_coupling_c),
// libavutil/float_dsp.c (vector_fmul_c, vector_fmul_window_c) and
// mathtables.c (ff_inverse) at the pinned reference revision.
// Vorbis I decoder: copyright (c) 2005 Denes Balatoni ( dbalatoni
// programozo hu ); vorbis.c: copyright (c) 2006 Loren Merritt, Michael
// Niedermayer, Denes Balatoni.
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's Vorbis I decoder (TODO.md T27d), as the reference build's C
//! code runs it: the identification and setup headers (codebooks with
//! their VLCs and vector lookups, floors 0 and 1, residues 0 to 2,
//! mappings, modes), then each audio packet: floors, residues, inverse
//! coupling, the floor times the residue, the inverse MDCT (T27c) and the
//! windowed overlap-add with the previous block.
//!
//! Single-precision operations follow FFmpeg's order, and where FFmpeg
//! computes in double precision (floor 0, its Bark map) so does this, so
//! the samples are FFmpeg's (vectors/vorbis.txt). Integer widths follow
//! FFmpeg's fields, truncations included.

const std = @import("std");
const bits = @import("bits.zig");
const vlc = @import("vlc.zig");
const tx = @import("tx.zig");
const xiph = @import("xiph.zig");
const data = @import("vorbis_data.zig");

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA (and the -1 and EINVAL its header
    /// splitting and VLC building return): the stream is refused.
    InvalidData,
    OutOfMemory,
};

const v_nb_bits = 8;
const v_nb_bits2 = 11;
const v_max_vlcs = 1 << 16;
const v_max_partitions = 1 << 20;

/// `ilog`: av_log2(2 * i), the bits of `i`.
fn ilog(i: u32) u6 {
    const x: u64 = 2 * @as(u64, i);
    if (x == 0) return 0;
    return @intCast(std.math.log2_int(u64, x));
}

/// ff_inverse: ceil(2^32 / i), 2^32 - 1 for 1.
const inverse = table: {
    var t: [257]u32 = undefined;
    t[0] = 0;
    t[1] = 0xffff_ffff;
    for (2..257) |i| t[i] = @intCast(((1 << 32) + i - 1) / i);
    break :table t;
};

/// FASTDIV.
fn fastdiv(a: u32, b: u32) u32 {
    return @intCast((@as(u64, a) * inverse[b]) >> 32);
}

/// ff_vorbis_nth_root: the largest r with r^n <= x, in unsigned
/// arithmetic as FFmpeg computes it.
fn nthRoot(x: u32, n: u32) u32 {
    var ret: u32 = 0;
    while (true) {
        ret +%= 1;
        var j = ret;
        var i: u32 = 0;
        while (i < n -% 1) : (i += 1) j *%= ret;
        if (!(j <= x)) break;
    }
    return ret -% 1;
}

/// ff_vorbis_len2vlc: the codewords of a Vorbis codebook's lengths, which
/// must describe a complete tree (or a single code).
fn len2vlc(lens: []const u8, codes: []u32) bool {
    var exit_at_level: [33]u32 = @splat(0);
    exit_at_level[0] = 404;
    var p: usize = 0;
    while (p < lens.len and lens[p] == 0) p += 1;
    if (p == lens.len) return true;
    codes[p] = 0;
    if (lens[p] > 32) return false;
    for (0..lens[p]) |i| exit_at_level[i + 1] = @as(u32, 1) << @intCast(i);
    p += 1;
    var i = p;
    while (i < lens.len and lens[i] == 0) i += 1;
    if (i == lens.len) return true;
    while (p < lens.len) : (p += 1) {
        const len = lens[p];
        if (len > 32) return false;
        if (len == 0) continue;
        // The exit the tree can grow from.
        var level: usize = len;
        while (level > 0) : (level -= 1) {
            if (exit_at_level[level] != 0) break;
        }
        if (level == 0) return false; // overspecified
        const code = exit_at_level[level];
        exit_at_level[level] = 0;
        var j = level + 1;
        while (j <= len) : (j += 1) exit_at_level[j] = code +% (@as(u32, 1) << @intCast(j - 1));
        codes[p] = code;
    }
    // An underspecified tree is refused.
    for (exit_at_level[1..33]) |e| if (e != 0) return false;
    return true;
}

/// vorbisfloat2float.
fn vorbisFloat(val: u32) f32 {
    var mant: f32 = @floatFromInt(val & 0x1fffff);
    const exp: i32 = @intCast((val & 0x7fe00000) >> 21);
    if (val & 0x80000000 != 0) mant = -mant;
    return std.math.ldexp(mant, exp - 20 - 768);
}

const Codebook = struct {
    dimensions: u8,
    lookup_type: u8,
    maxdepth: u8,
    vlc: vlc.Vlc,
    /// The vectors of the used entries, `dimensions` each; null without a
    /// lookup.
    codevectors: ?[]f32,
    nb_bits: u5,

    fn get(c: *const Codebook, r: *bits.LsbReader) i32 {
        return c.vlc.get(r, 3);
    }
};

const Floor1Entry = struct {
    x: u16 = 0,
    sort: u16 = 0,
    low: u16 = 0,
    high: u16 = 0,
};

const Floor0 = struct {
    order: u8,
    rate: u16,
    bark_map_size: u16,
    map: [2][]i32,
    map_size: [2]u32,
    amplitude_bits: u8,
    amplitude_offset: u8,
    book_list: []u8,
    lsp: []f32,
};

const Floor1 = struct {
    partitions: u8,
    partition_class: [32]u8,
    class_dimensions: [16]u8,
    class_subclasses: [16]u8,
    class_masterbook: [16]u8,
    subclass_books: [16][8]i16,
    multiplier: u8,
    x_list_dim: u16,
    list: []Floor1Entry,
};

const Floor = union(enum) {
    floor0: Floor0,
    floor1: Floor1,
};

const Residue = struct {
    kind: u16,
    begin: u32,
    end: u32,
    partition_size: u32,
    classifications: u8,
    classbook: u8,
    books: [64][8]i16,
    maxpass: u8,
    ptns_to_read: u16,
    classifs: []u8,
};

const Mapping = struct {
    submaps: u8,
    coupling_steps: u16,
    magnitude: []u8,
    angle: []u8,
    mux: []u8,
    submap_floor: [16]u8,
    submap_residue: [16]u8,
};

const Mode = struct {
    blockflag: u1,
    windowtype: u16,
    transformtype: u16,
    mapping: u8,
};

pub const Decoder = struct {
    gpa: std.mem.Allocator,
    channels: u8 = 0,
    sample_rate: u32 = 0,
    blocksize: [2]u32 = .{ 0, 0 },
    win: [2][]const f32 = .{ &.{}, &.{} },
    codebooks: []Codebook = &.{},
    floors: []Floor = &.{},
    residues: []Residue = &.{},
    mappings: []Mapping = &.{},
    modes: []Mode = &.{},
    mdct: [2]?tx.Mdct = .{ null, null },
    channel_residues: []f32 = &.{},
    saved: []f32 = &.{},
    previous_window: i8 = -1,
    mode_number: u8 = 0,
    first_frame: bool = false,
    /// The samples libavcodec's decode.c discards from the next frames
    /// (`avctx->internal->skip_samples`): the first frame's length.
    skip_samples: u32 = 0,
    /// Whether the setup header was parsed (FFmpeg's `vc->modes`).
    have_setup: bool = false,

    /// vorbis_decode_init: the identification and setup headers from the
    /// stream's extradata, Xiph-laced as Ogg carries them.
    pub fn init(gpa: std.mem.Allocator, extradata: []const u8) Error!Decoder {
        var d: Decoder = .{ .gpa = gpa };
        errdefer d.free();
        if (extradata.len == 0) return error.InvalidData;
        const headers = xiph.splitHeaders(extradata, 30) orelse return error.InvalidData;
        var r = bits.LsbReader.init(headers[0]) catch return error.InvalidData;
        if (r.bits(8) != 1) return error.InvalidData; // not the id header
        try d.parseIdHeader(&r);
        r = bits.LsbReader.init(headers[2]) catch return error.InvalidData;
        if (r.bits(8) != 5) return error.InvalidData; // not the setup header
        try d.parseSetupHeader(&r);
        return d;
    }

    pub fn deinit(d: *Decoder) void {
        d.free();
        d.* = undefined;
    }

    /// vorbis_free.
    fn free(d: *Decoder) void {
        const gpa = d.gpa;
        gpa.free(d.channel_residues);
        gpa.free(d.saved);
        for (d.residues) |res| gpa.free(res.classifs);
        gpa.free(d.residues);
        gpa.free(d.modes);
        for (&d.mdct) |*m| if (m.*) |*mdct| mdct.deinit();
        for (d.codebooks) |*cb| {
            if (cb.codevectors) |v| gpa.free(v);
            cb.vlc.deinit(gpa);
        }
        gpa.free(d.codebooks);
        for (d.floors) |f| switch (f) {
            .floor0 => |f0| {
                gpa.free(f0.map[0]);
                gpa.free(f0.map[1]);
                gpa.free(f0.book_list);
                gpa.free(f0.lsp);
            },
            .floor1 => |f1| gpa.free(f1.list),
        };
        gpa.free(d.floors);
        for (d.mappings) |m| {
            gpa.free(m.magnitude);
            gpa.free(m.angle);
            gpa.free(m.mux);
        }
        gpa.free(d.mappings);
        const keep = d.gpa;
        d.* = .{ .gpa = keep };
    }

    fn signature(r: *bits.LsbReader) bool {
        for ("vorbis") |c| if (r.bits(8) != c) return false;
        return true;
    }

    /// vorbis_parse_id_hdr.
    fn parseIdHeader(d: *Decoder, r: *bits.LsbReader) Error!void {
        if (!signature(r)) return error.InvalidData;
        _ = r.bits(32); // version
        d.channels = @intCast(r.bits(8));
        if (d.channels == 0) return error.InvalidData;
        d.sample_rate = r.bits(32);
        // FFmpeg compares the unsigned rate with `<= 0`.
        if (d.sample_rate == 0) return error.InvalidData;
        _ = r.bits(32); // bitrate_maximum
        _ = r.bits(32); // bitrate_nominal
        _ = r.bits(32); // bitrate_minimum
        const bl0 = r.bits(4);
        const bl1 = r.bits(4);
        if (bl0 > 13 or bl0 < 6 or bl1 > 13 or bl1 < 6 or bl1 < bl0) return error.InvalidData;
        d.blocksize = .{ @as(u32, 1) << @intCast(bl0), @as(u32, 1) << @intCast(bl1) };
        d.win = .{ data.vwin[bl0 - 6], data.vwin[bl1 - 6] };
        if (r.bit() == 0) return error.InvalidData; // framing flag
        d.channel_residues = try d.gpa.alloc(f32, d.blocksize[1] / 2 * d.channels);
        d.saved = try d.gpa.alloc(f32, d.blocksize[1] / 4 * d.channels);
        @memset(d.saved, 0);
        d.previous_window = -1;
        for (0..2) |k| {
            d.mdct[k] = tx.Mdct.init(d.gpa, d.blocksize[k] / 2, true, -1.0) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedLength => unreachable, // 32 to 4096
            };
        }
    }

    /// vorbis_parse_setup_hdr.
    fn parseSetupHeader(d: *Decoder, r: *bits.LsbReader) Error!void {
        if (!signature(r)) return error.InvalidData;
        try d.parseCodebooks(r);
        // Time domain transforms, unused in Vorbis I: all zero.
        const time_count = r.bits(6) + 1;
        for (0..time_count) |_| if (r.bits(16) != 0) return error.InvalidData;
        try d.parseFloors(r);
        try d.parseResidues(r);
        try d.parseMappings(r);
        try d.parseModes(r);
        if (r.bit() == 0) return error.InvalidData; // framing flag
        d.have_setup = true;
    }

    /// vorbis_parse_setup_hdr_codebooks. The length and code buffers are
    /// shared by the codebooks, as FFmpeg's are, so an ordered codebook
    /// whose lengths run out keeps the earlier ones'.
    fn parseCodebooks(d: *Decoder, r: *bits.LsbReader) Error!void {
        const gpa = d.gpa;
        const count = r.bits(8) + 1;
        d.codebooks = try gpa.alloc(Codebook, count);
        var made: usize = 0;
        errdefer {
            for (d.codebooks[0..made]) |*cb| {
                if (cb.codevectors) |v| gpa.free(v);
                cb.vlc.deinit(gpa);
            }
            gpa.free(d.codebooks);
            d.codebooks = &.{};
        }
        const tmp_bits = try gpa.alloc(u8, v_max_vlcs);
        defer gpa.free(tmp_bits);
        @memset(tmp_bits, 0);
        const tmp_codes = try gpa.alloc(u32, v_max_vlcs);
        defer gpa.free(tmp_codes);
        @memset(tmp_codes, 0);
        const multiplicands = try gpa.alloc(u16, v_max_vlcs);
        defer gpa.free(multiplicands);
        for (d.codebooks) |*cb| {
            if (r.bits(24) != 0x564342) return error.InvalidData;
            const dimensions: u8 = @truncate(r.bits(16));
            if (dimensions > 16 or dimensions == 0) return error.InvalidData;
            var entries = r.bits(24);
            if (entries > v_max_vlcs) return error.InvalidData;
            const ordered = r.bit();
            var used_entries: u32 = 0;
            if (ordered == 0) {
                if (r.bit() == 1) { // sparse
                    for (0..entries) |ce| {
                        if (r.bit() == 1) {
                            tmp_bits[ce] = @intCast(r.bits(5) + 1);
                            used_entries += 1;
                        } else tmp_bits[ce] = 0;
                    }
                } else {
                    used_entries = entries;
                    for (0..entries) |ce| tmp_bits[ce] = @intCast(r.bits(5) + 1);
                }
            } else {
                var current_entry: u32 = 0;
                var current_length = r.bits(5) + 1;
                used_entries = entries;
                while (current_entry < used_entries and current_length <= 32) : (current_length += 1) {
                    const number = r.bits(ilog(entries - current_entry));
                    var i = current_entry;
                    const stop = @min(number + current_entry, used_entries);
                    while (i < stop) : (i += 1) tmp_bits[i] = @intCast(current_length);
                    current_entry += number;
                }
                if (current_entry > used_entries) return error.InvalidData;
            }
            const lookup_type: u8 = @intCast(r.bits(4));
            var codevectors: ?[]f32 = null;
            errdefer if (codevectors) |v| gpa.free(v);
            if (lookup_type == 1) {
                const lookup_values = nthRoot(entries, dimensions);
                const minimum = vorbisFloat(r.bits(32));
                const delta = vorbisFloat(r.bits(32));
                const value_bits: u6 = @intCast(r.bits(4) + 1);
                const sequence_p = r.bit() == 1;
                if (!std.math.isFinite(minimum) or !std.math.isFinite(delta)) return error.InvalidData;
                for (0..lookup_values) |i| multiplicands[i] = @intCast(r.bits(value_bits));
                if (used_entries != 0) {
                    codevectors = try gpa.alloc(f32, @as(usize, used_entries) * dimensions);
                    @memset(codevectors.?, 0);
                }
                var j: u32 = 0;
                for (0..entries) |i| {
                    if (tmp_bits[i] == 0) continue;
                    var last: f32 = 0;
                    var lookup_offset: u32 = @intCast(i);
                    for (0..dimensions) |k| {
                        const offset = lookup_offset % lookup_values;
                        const v = @as(f32, @floatFromInt(multiplicands[offset])) * delta + minimum + last;
                        codevectors.?[j * dimensions + k] = v;
                        if (sequence_p) last = v;
                        lookup_offset /= lookup_values;
                    }
                    tmp_bits[j] = tmp_bits[i];
                    j += 1;
                }
                if (j != used_entries) return error.InvalidData;
                entries = used_entries;
            } else if (lookup_type >= 2) return error.InvalidData;
            if (!len2vlc(tmp_bits[0..entries], tmp_codes[0..entries])) return error.InvalidData;
            var maxdepth: u32 = 0;
            for (tmp_bits[0..entries]) |b| {
                if (b >= maxdepth) maxdepth = b;
            }
            const nb_bits: u5 = if (maxdepth > 3 * v_nb_bits) v_nb_bits2 else v_nb_bits;
            const table = vlc.Vlc.init(gpa, nb_bits, tmp_bits[0..entries], tmp_codes[0..entries], null, .le) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidData,
            };
            cb.* = .{
                .dimensions = dimensions,
                .lookup_type = lookup_type,
                .maxdepth = @intCast((maxdepth + nb_bits - 1) / nb_bits),
                .vlc = table,
                .codevectors = codevectors,
                .nb_bits = nb_bits,
            };
            codevectors = null;
            made += 1;
        }
    }

    fn validated(r: *bits.LsbReader, n: u6, limit: usize) Error!u32 {
        const idx = r.bits(n);
        if (idx >= limit) return error.InvalidData;
        return idx;
    }

    /// vorbis_parse_setup_hdr_floors.
    fn parseFloors(d: *Decoder, r: *bits.LsbReader) Error!void {
        const gpa = d.gpa;
        const count = r.bits(6) + 1;
        // Every floor starts empty, so the decoder frees what a failed
        // parse leaves.
        const floors = try gpa.alloc(Floor, count);
        for (floors) |*f| f.* = .{ .floor1 = std.mem.zeroes(Floor1) };
        for (floors) |*f| f.floor1.list = &.{};
        d.floors = floors;
        for (floors) |*slot_union| {
            const floor_type: u8 = @truncate(r.bits(16));
            if (floor_type == 1) {
                var f = std.mem.zeroes(Floor1);
                f.partitions = @intCast(r.bits(5));
                var maximum_class: i32 = -1;
                for (0..f.partitions) |j| {
                    f.partition_class[j] = @intCast(r.bits(4));
                    if (f.partition_class[j] > maximum_class) maximum_class = f.partition_class[j];
                }
                var j: i32 = 0;
                while (j <= maximum_class) : (j += 1) {
                    const c: usize = @intCast(j);
                    f.class_dimensions[c] = @intCast(r.bits(3) + 1);
                    f.class_subclasses[c] = @intCast(r.bits(2));
                    if (f.class_subclasses[c] != 0) f.class_masterbook[c] = @intCast(try validated(r, 8, d.codebooks.len));
                    for (0..@as(usize, 1) << @intCast(f.class_subclasses[c])) |k| {
                        const book: i16 = @truncate(@as(i32, @intCast(r.bits(8))) - 1);
                        if (book != -1 and book >= d.codebooks.len) return error.InvalidData;
                        f.subclass_books[c][k] = book;
                    }
                }
                f.multiplier = @intCast(r.bits(2) + 1);
                f.x_list_dim = 2;
                for (0..f.partitions) |p| f.x_list_dim += f.class_dimensions[f.partition_class[p]];
                f.list = try gpa.alloc(Floor1Entry, f.x_list_dim);
                @memset(f.list, .{});
                slot_union.* = .{ .floor1 = f };
                const list = f.list;
                const rangebits: u5 = @intCast(r.bits(4));
                if (rangebits == 0 and f.partitions != 0) return error.InvalidData;
                const rangemax = @as(u32, 1) << rangebits;
                if (rangemax > d.blocksize[1] / 2) return error.InvalidData;
                list[0].x = 0;
                list[1].x = @intCast(rangemax);
                var values: usize = 2;
                for (0..f.partitions) |p| {
                    for (0..f.class_dimensions[f.partition_class[p]]) |_| {
                        list[values].x = @intCast(r.bits(rangebits));
                        values += 1;
                    }
                }
                if (!readyFloor1List(list)) return error.InvalidData;
            } else if (floor_type == 0) {
                var f: Floor0 = .{
                    .order = 0,
                    .rate = 0,
                    .bark_map_size = 0,
                    .map = .{ &.{}, &.{} },
                    .map_size = .{ 0, 0 },
                    .amplitude_bits = 0,
                    .amplitude_offset = 0,
                    .book_list = &.{},
                    .lsp = &.{},
                };
                f.order = @intCast(r.bits(8));
                if (f.order == 0) return error.InvalidData;
                f.rate = @intCast(r.bits(16));
                if (f.rate == 0) return error.InvalidData;
                f.bark_map_size = @intCast(r.bits(16));
                if (f.bark_map_size == 0) return error.InvalidData;
                f.amplitude_bits = @intCast(r.bits(6));
                f.amplitude_offset = @intCast(r.bits(8));
                const num_books: u8 = @intCast(r.bits(4) + 1);
                slot_union.* = .{ .floor0 = f };
                const slot = &slot_union.floor0;
                slot.book_list = try gpa.alloc(u8, num_books);
                var max_codebook_dim: u32 = 0;
                for (slot.book_list) |*b| {
                    const book = try validated(r, 8, d.codebooks.len);
                    b.* = @intCast(book);
                    max_codebook_dim = @max(max_codebook_dim, d.codebooks[book].dimensions);
                }
                try d.createMap(slot);
                slot.lsp = try gpa.alloc(f32, @as(usize, slot.order) + 1 + max_codebook_dim);
            } else return error.InvalidData;
        }
    }

    /// create_map: floor 0's Bark-scale map for both block sizes, in
    /// FFmpeg's mix of single and double precision.
    fn createMap(d: *Decoder, f: *Floor0) Error!void {
        for (0..2) |blockflag| {
            const n = d.blocksize[blockflag] / 2;
            const map = try d.gpa.alloc(i32, n + 1);
            f.map[blockflag] = map;
            const rate: f32 = @floatFromInt(f.rate);
            const bark_size: f64 = @floatFromInt(f.bark_map_size);
            for (0..n) |idx| {
                const x: f32 = (@as(f32, @floatFromInt(f.rate)) * @as(f32, @floatFromInt(idx))) / (2.0 * @as(f32, @floatFromInt(n)));
                const value = @floor(bark(x) * (bark_size / bark(rate / 2.0)));
                map[idx] = @intFromFloat(value);
                if (@as(i32, f.bark_map_size) - 1 < map[idx]) map[idx] = @as(i32, f.bark_map_size) - 1;
            }
            map[n] = -1;
            f.map_size[blockflag] = n;
        }
    }

    /// vorbis_parse_setup_hdr_residues.
    fn parseResidues(d: *Decoder, r: *bits.LsbReader) Error!void {
        const gpa = d.gpa;
        const count = r.bits(6) + 1;
        const residues = try gpa.alloc(Residue, count);
        for (residues) |*res| res.classifs = &.{};
        d.residues = residues;
        for (residues) |*res| {
            res.kind = @intCast(r.bits(16));
            res.begin = r.bits(24);
            res.end = r.bits(24);
            res.partition_size = r.bits(24) + 1;
            if (res.begin > res.end or (res.end - res.begin) / res.partition_size > @min(v_max_partitions, 65535)) return error.InvalidData;
            res.classifications = @intCast(r.bits(6) + 1);
            res.classbook = @intCast(try validated(r, 8, d.codebooks.len));
            res.ptns_to_read = @intCast((res.end - res.begin) / res.partition_size);
            res.classifs = try gpa.alloc(u8, @as(usize, res.ptns_to_read) * d.channels);
            var cascade: [64]u8 = undefined;
            for (cascade[0..res.classifications]) |*c| {
                var high: u32 = 0;
                const low = r.bits(3);
                if (r.bit() == 1) high = r.bits(5);
                c.* = @intCast((high << 3) + low);
            }
            res.maxpass = 0;
            for (0..res.classifications) |j| {
                for (0..8) |k| {
                    if (cascade[j] & (@as(u8, 1) << @intCast(k)) != 0) {
                        res.books[j][k] = @intCast(try validated(r, 8, d.codebooks.len));
                        if (k > res.maxpass) res.maxpass = @intCast(k);
                    } else res.books[j][k] = -1;
                }
            }
        }
    }

    /// vorbis_parse_setup_hdr_mappings.
    fn parseMappings(d: *Decoder, r: *bits.LsbReader) Error!void {
        const gpa = d.gpa;
        const count = r.bits(6) + 1;
        const mappings = try gpa.alloc(Mapping, count);
        for (mappings) |*m| m.* = .{ .submaps = 0, .coupling_steps = 0, .magnitude = &.{}, .angle = &.{}, .mux = &.{}, .submap_floor = @splat(0), .submap_residue = @splat(0) };
        d.mappings = mappings;
        for (mappings) |*m| {
            if (r.bits(16) != 0) return error.InvalidData; // only mapping type 0
            m.submaps = if (r.bit() == 1) @intCast(r.bits(4) + 1) else 1;
            if (r.bit() == 1) {
                m.coupling_steps = @intCast(r.bits(8) + 1);
                if (d.channels < 2) return error.InvalidData;
                m.magnitude = try gpa.alloc(u8, m.coupling_steps);
                @memset(m.magnitude, 0);
                m.angle = try gpa.alloc(u8, m.coupling_steps);
                @memset(m.angle, 0);
                const width = ilog(d.channels - 1);
                for (0..m.coupling_steps) |j| {
                    m.magnitude[j] = @intCast(try validated(r, width, d.channels));
                    m.angle[j] = @intCast(try validated(r, width, d.channels));
                }
            } else m.coupling_steps = 0;
            if (r.bits(2) != 0) return error.InvalidData;
            if (m.submaps > 1) {
                m.mux = try gpa.alloc(u8, d.channels);
                for (m.mux) |*x| x.* = @intCast(r.bits(4));
            }
            for (0..m.submaps) |j| {
                r.skip(8);
                m.submap_floor[j] = @intCast(try validated(r, 8, d.floors.len));
                m.submap_residue[j] = @intCast(try validated(r, 8, d.residues.len));
            }
        }
    }

    /// vorbis_parse_setup_hdr_modes. A window or transform type other than
    /// 0 is only warned about.
    fn parseModes(d: *Decoder, r: *bits.LsbReader) Error!void {
        const count = r.bits(6) + 1;
        const modes = try d.gpa.alloc(Mode, count);
        d.modes = modes;
        for (modes) |*m| {
            m.blockflag = r.bit();
            m.windowtype = @intCast(r.bits(16));
            m.transformtype = @intCast(r.bits(16));
            m.mapping = @intCast(try validated(r, 8, d.mappings.len));
        }
    }
};

/// BARK: single-precision products, double-precision arctangents.
fn bark(x: f32) f64 {
    const a: f64 = @as(f32, 0.00074) * x;
    const b: f64 = @as(f32, 1.85e-8) * x * x;
    const c: f32 = @as(f32, 1e-4) * x;
    return @as(f64, @as(f32, 13.1)) * std.math.atan(a) + @as(f64, @as(f32, 2.24)) * std.math.atan(b) + @as(f64, c);
}

/// ff_vorbis_ready_floor1_list: each point's neighbours and the points'
/// order by x; duplicate x values are refused.
fn readyFloor1List(list: []Floor1Entry) bool {
    list[0].sort = 0;
    list[1].sort = 1;
    for (2..list.len) |i| {
        list[i].low = 0;
        list[i].high = 1;
        list[i].sort = @intCast(i);
        for (2..i) |j| {
            const tmp = list[j].x;
            if (tmp < list[i].x) {
                if (tmp > list[list[i].low].x) list[i].low = @intCast(j);
            } else {
                if (tmp < list[list[i].high].x) list[i].high = @intCast(j);
            }
        }
    }
    for (0..list.len - 1) |i| {
        for (i + 1..list.len) |j| {
            if (list[i].x == list[j].x) return false;
            if (list[list[i].sort].x > list[list[j].sort].x) {
                const tmp = list[i].sort;
                list[i].sort = list[j].sort;
                list[j].sort = tmp;
            }
        }
    }
    return true;
}

const testing = std.testing;

test "len2vlc assigns Vorbis' codewords and refuses incomplete and overfull trees" {
    var codes: [4]u32 = undefined;
    try testing.expect(len2vlc(&.{ 1, 2, 3, 3 }, &codes));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 7 }, &codes);
    try testing.expect(!len2vlc(&.{ 1, 2, 2, 2 }, &codes));
    try testing.expect(!len2vlc(&.{ 2, 2, 2 }, codes[0..3]));
    // A single code is allowed.
    try testing.expect(len2vlc(&.{ 0, 3, 0 }, codes[0..3]));
}

test "nth root and ilog as FFmpeg computes them" {
    try testing.expectEqual(4, nthRoot(16, 2));
    try testing.expectEqual(2, nthRoot(26, 3));
    try testing.expectEqual(3, nthRoot(27, 3));
    try testing.expectEqual(65536, nthRoot(65536, 1));
    try testing.expectEqual(0, ilog(0));
    try testing.expectEqual(1, ilog(1));
    try testing.expectEqual(3, ilog(7));
    try testing.expectEqual(4, ilog(8));
    try testing.expectEqual(1431655766, inverse[3]);
    try testing.expectEqual(10, fastdiv(31, 3));
}
