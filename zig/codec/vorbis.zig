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
const channel_layout = @import("../core/channel_layout.zig");

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
    /// The caller took `skip_samples` (libavcodec reads it once, after the
    /// first frame).
    first_frame_consumed: bool = false,

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

    // Audio packets ----------------------------------------------------

    /// vorbis_decode_frame: an audio packet into `planes` (the output's
    /// channel planes in FFmpeg's order, each holding blocksize[1] / 2
    /// samples), returning the frame's sample count, or null for a packet
    /// that gives no frame (a header packet in the stream, or a decode
    /// that returned no samples). The first frame's count becomes
    /// `skip_samples`, which libavcodec discards.
    pub fn decodePacket(d: *Decoder, packet: []const u8, planes: []const []f32) Error!?u32 {
        if (packet.len == 0) return null;
        if (packet[0] == 1 and packet.len > 7) {
            // An identification header in the stream starts over.
            const first_frame = d.first_frame;
            const skip = d.skip_samples;
            d.free();
            d.first_frame = first_frame;
            d.skip_samples = skip;
            var r = bits.LsbReader.init(packet[1..]) catch return error.InvalidData;
            d.parseIdHeader(&r) catch |err| {
                d.free();
                d.first_frame = first_frame;
                d.skip_samples = skip;
                return err;
            };
            return null;
        }
        if (packet[0] == 3 and packet.len > 7) return null; // a comment header
        if (packet[0] == 5 and packet.len > 7 and d.channel_residues.len != 0 and !d.have_setup) {
            var r = bits.LsbReader.init(packet[1..]) catch return error.InvalidData;
            d.parseSetupHeader(&r) catch |err| {
                const first_frame = d.first_frame;
                const skip = d.skip_samples;
                d.free();
                d.first_frame = first_frame;
                d.skip_samples = skip;
                return err;
            };
            return null;
        }
        if (d.channel_residues.len == 0 or !d.have_setup) return error.InvalidData; // before valid headers
        std.debug.assert(planes.len == d.channels);
        var floor_ptr: [255][]f32 = undefined;
        for (planes, 0..) |plane, i| {
            std.debug.assert(plane.len >= d.blocksize[1] / 2);
            const ch = if (d.channels > 8) i else data.channel_layout_offsets[d.channels - 1][i];
            floor_ptr[ch] = plane;
        }
        var r = bits.LsbReader.init(packet) catch return error.InvalidData;
        const len = try d.parseAudioPacket(&r, floor_ptr[0..d.channels]);
        if (len == 0) return null;
        if (!d.first_frame) {
            d.first_frame = true;
            d.skip_samples = len;
        }
        return len;
    }

    /// vorbis_decode_flush: the overlap and the first-frame state cleared.
    pub fn flush(d: *Decoder) void {
        @memset(d.saved, 0);
        d.previous_window = -1;
        d.first_frame = false;
    }

    /// vorbis_parse_audio_packet: returns the samples the packet completes.
    fn parseAudioPacket(d: *Decoder, r: *bits.LsbReader, floor_ptr: [][]f32) Error!u32 {
        if (r.bit() == 1) return error.InvalidData; // not an audio packet
        const mode_number: u32 = if (d.modes.len == 1) 0 else try validated(r, ilog(@intCast(d.modes.len - 1)), d.modes.len);
        d.mode_number = @intCast(mode_number);
        const mode = d.modes[mode_number];
        const mapping = &d.mappings[mode.mapping];
        const blockflag = mode.blockflag;
        const blocksize = d.blocksize[blockflag];
        const vlen = blocksize / 2;
        var previous_window = d.previous_window;
        if (blockflag == 1) {
            const code = r.bits(2);
            if (previous_window < 0) previous_window = @intCast(code >> 1);
        } else if (previous_window < 0) previous_window = 0;
        const channels: usize = d.channels;
        @memset(d.channel_residues[0 .. channels * vlen], 0);
        for (floor_ptr) |f| @memset(f[0..vlen], 0);

        var no_residue: [255]u8 = undefined;
        for (0..channels) |i| {
            const floor_index = if (mapping.submaps > 1) mapping.submap_floor[mapping.mux[i]] else mapping.submap_floor[0];
            no_residue[i] = switch (d.floors[floor_index]) {
                .floor0 => |*f0| try d.floor0Decode(r, f0, floor_ptr[i]),
                .floor1 => |*f1| try d.floor1Decode(r, f1, floor_ptr[i]),
            };
        }
        // A coupled channel with a residue gives its partner one.
        var step: usize = mapping.coupling_steps;
        while (step > 0) {
            step -= 1;
            if (no_residue[mapping.magnitude[step]] & no_residue[mapping.angle[step]] == 0) {
                no_residue[mapping.magnitude[step]] = 0;
                no_residue[mapping.angle[step]] = 0;
            }
        }
        var res_chan: [255]u8 = undefined;
        var do_not_decode: [255]u8 = undefined;
        var res_num: u32 = 0;
        var ch_res_off: usize = 0;
        var ch_left: u32 = d.channels;
        for (0..mapping.submaps) |i| {
            var ch: u32 = 0;
            for (0..channels) |j| {
                if (mapping.submaps == 1 or i == mapping.mux[j]) {
                    res_chan[j] = @intCast(res_num);
                    do_not_decode[ch] = if (no_residue[j] != 0) 1 else 0;
                    ch += 1;
                    res_num += 1;
                }
            }
            const residue = &d.residues[mapping.submap_residue[i]];
            if (ch_left < ch) return error.InvalidData;
            if (ch != 0) try d.residueDecode(r, residue, ch, do_not_decode[0..ch], d.channel_residues[ch_res_off..], vlen, ch_left);
            ch_res_off += @as(usize, ch) * vlen;
            ch_left -= ch;
        }
        if (ch_left > 0) return error.InvalidData;
        // Inverse coupling.
        step = mapping.coupling_steps;
        while (step > 0) {
            step -= 1;
            const mag = d.channel_residues[@as(usize, res_chan[mapping.magnitude[step]]) * vlen ..][0..vlen];
            const ang = d.channel_residues[@as(usize, res_chan[mapping.angle[step]]) * vlen ..][0..vlen];
            inverseCoupling(mag, ang);
        }
        // The floor times the residue, then the inverse MDCT.
        const mdct = &d.mdct[blockflag].?;
        var j: usize = channels;
        while (j > 0) {
            j -= 1;
            const res = d.channel_residues[@as(usize, res_chan[j]) * vlen ..][0..vlen];
            if (no_residue[j] != 0) {
                @memset(res, 0);
                continue;
            }
            const f = floor_ptr[j][0..vlen];
            for (f, res) |*a, b| a.* = a.* * b;
            mdct.run(res, f);
        }
        // Overlap-add with the saved half of the previous block.
        const prev: u1 = @intCast(previous_window);
        const retlen = (blocksize + d.blocksize[prev]) / 4;
        const bs0 = d.blocksize[0];
        const bs1 = d.blocksize[1];
        for (0..channels) |c| {
            const buf = d.channel_residues[@as(usize, res_chan[c]) * vlen ..][0..vlen];
            const saved = d.saved[c * bs1 / 4 ..][0 .. bs1 / 4];
            const ret = floor_ptr[c];
            const win = d.win[blockflag & prev];
            if (blockflag == prev) {
                fmulWindow(ret, saved, buf, win, blocksize / 4);
            } else if (blockflag > prev) {
                fmulWindow(ret, saved, buf, win, bs0 / 4);
                @memcpy(ret[bs0 / 2 ..][0 .. (bs1 - bs0) / 4], buf[bs0 / 4 ..][0 .. (bs1 - bs0) / 4]);
            } else {
                @memcpy(ret[0 .. (bs1 - bs0) / 4], saved[0 .. (bs1 - bs0) / 4]);
                fmulWindow(ret[(bs1 - bs0) / 4 ..], saved[(bs1 - bs0) / 4 ..], buf, win, bs0 / 4);
            }
            @memcpy(saved[0 .. blocksize / 4], buf[blocksize / 4 ..][0 .. blocksize / 4]);
        }
        d.previous_window = @intCast(blockflag);
        return retlen;
    }

    /// vorbis_floor0_decode: 1 for an unused channel. FFmpeg computes the
    /// LSP curve in a mix of single and double precision, kept here.
    fn floor0Decode(d: *Decoder, r: *bits.LsbReader, f: *Floor0, vec: []f32) Error!u8 {
        const lsp = f.lsp;
        const blockflag = d.modes[d.mode_number].blockflag;
        if (f.amplitude_bits == 0) return 1;
        // get_bits64 under BITSTREAM_READER_LE: the low 32 bits first.
        var amplitude: u64 = undefined;
        if (f.amplitude_bits <= 32) {
            amplitude = r.bits(@intCast(f.amplitude_bits));
        } else {
            const low: u64 = r.bits(32);
            amplitude = low | @as(u64, r.bits(@intCast(f.amplitude_bits - 32))) << 32;
        }
        if (amplitude == 0) return 1;
        var last: f32 = 0;
        var lsp_len: usize = 0;
        var book_idx = r.bits(ilog(@intCast(f.book_list.len)));
        if (book_idx >= f.book_list.len) book_idx = 0; // "booknumber too high"
        const codebook = &d.codebooks[f.book_list[book_idx]];
        const vectors = codebook.codevectors orelse return error.InvalidData;
        while (lsp_len < f.order) {
            const vec_off_raw = codebook.get(r);
            if (vec_off_raw < 0) return error.InvalidData;
            const vec_off = @as(usize, @intCast(vec_off_raw)) * codebook.dimensions;
            if (vec_off + codebook.dimensions > vectors.len or lsp_len + codebook.dimensions > lsp.len) return error.InvalidData;
            for (0..codebook.dimensions) |idx| lsp[lsp_len + idx] = vectors[vec_off + idx] + last;
            last = lsp[lsp_len + codebook.dimensions - 1];
            lsp_len += codebook.dimensions;
        }
        const order: usize = f.order;
        const wstep: f32 = @floatCast(std.math.pi / @as(f64, @floatFromInt(f.bark_map_size)));
        for (lsp[0..order]) |*v| v.* = @floatCast(2.0 * @cos(@as(f64, v.*)));
        const map = f.map[blockflag];
        var i: usize = 0;
        while (i < f.map_size[blockflag]) {
            const iter_cond = map[i];
            var p: f32 = 0.5;
            var q: f32 = 0.5;
            const two_cos_w: f32 = @floatCast(2.0 * @cos(@as(f64, wstep * @as(f32, @floatFromInt(iter_cond)))));
            var j: usize = 0;
            while (j + 1 < order) : (j += 2) {
                q *= lsp[j] - two_cos_w;
                p *= lsp[j + 1] - two_cos_w;
            }
            if (j == order) {
                p *= p * (2.0 - two_cos_w);
                q *= q * (2.0 + two_cos_w);
            } else {
                q *= two_cos_w - lsp[j];
                p *= p * (4.0 - two_cos_w * two_cos_w);
                q *= q;
            }
            if (p + q == 0.0) return error.InvalidData;
            const numerator: f64 = @floatFromInt(amplitude *% f.amplitude_offset);
            const scale: f64 = @floatFromInt((@as(u64, 1) << @intCast(f.amplitude_bits)) - 1);
            const exponent = (numerator / (scale * @sqrt(@as(f64, p + q))) - @as(f64, @floatFromInt(f.amplitude_offset))) * @as(f64, @as(f32, 0.11512925));
            const value: f32 = @floatCast(@exp(exponent));
            while (true) {
                if (i >= vec.len) return error.InvalidData;
                vec[i] = value;
                i += 1;
                if (map[i] != iter_cond) break;
            }
        }
        return 0;
    }

    /// vorbis_floor1_decode: 1 for an unused channel.
    fn floor1Decode(d: *Decoder, r: *bits.LsbReader, f: *Floor1, vec: []f32) Error!u8 {
        const range_v = [4]u32{ 256, 128, 86, 64 };
        const range = range_v[f.multiplier - 1];
        var y: [258]u16 = undefined;
        var y_final: [258]u16 = undefined;
        var flag: [258]bool = undefined;
        if (r.bit() == 0) return 1; // silence
        y[0] = @intCast(r.bits(ilog(range - 1)));
        y[1] = @intCast(r.bits(ilog(range - 1)));
        var offset: usize = 2;
        for (f.partition_class[0..f.partitions]) |pclass| {
            const cdim = f.class_dimensions[pclass];
            const cbits: u5 = @intCast(f.class_subclasses[pclass]);
            const csub = (@as(u32, 1) << cbits) - 1;
            var cval: u32 = 0;
            if (cbits != 0) cval = @bitCast(d.codebooks[f.class_masterbook[pclass]].get(r));
            for (0..cdim) |j| {
                const book = f.subclass_books[pclass][cval & csub];
                cval >>= cbits;
                if (book > -1) {
                    const v = d.codebooks[@intCast(book)].get(r);
                    if (v < 0) return error.InvalidData;
                    y[offset + j] = @intCast(v);
                } else y[offset + j] = 0;
            }
            offset += cdim;
        }
        flag[0] = true;
        flag[1] = true;
        y_final[0] = y[0];
        y_final[1] = y[1];
        const list = f.list;
        for (2..f.x_list_dim) |i| {
            const low = list[i].low;
            const high = list[i].high;
            const dy: i32 = @as(i32, y_final[high]) - y_final[low];
            const adx: i32 = @as(i32, list[high].x) - list[low].x;
            const ady: i32 = @intCast(@abs(dy));
            const err = ady * (@as(i32, list[i].x) - list[low].x);
            const off = @divTrunc(err, adx);
            const predicted: i32 = if (dy < 0) y_final[low] - off else y_final[low] + off;
            // FFmpeg's unsigned room arithmetic.
            const val: u32 = y[i];
            const highroom: u32 = range -% @as(u32, @bitCast(predicted));
            const lowroom: u32 = @bitCast(predicted);
            const room: u32 = if (highroom < lowroom) highroom *% 2 else lowroom *% 2;
            const p: u32 = @bitCast(predicted);
            if (val != 0) {
                flag[low] = true;
                flag[high] = true;
                flag[i] = true;
                y_final[i] = clipU16(@bitCast(if (val >= room)
                    (if (highroom > lowroom) val -% lowroom +% p else p -% val +% highroom -% 1)
                else if (val & 1 != 0)
                    p -% (val + 1) / 2
                else
                    p +% val / 2));
            } else {
                flag[i] = false;
                y_final[i] = clipU16(predicted);
            }
        }
        render(list[0..f.x_list_dim], y_final[0..f.x_list_dim], flag[0..f.x_list_dim], f.multiplier, vec, list[1].x);
        return 0;
    }

    /// vorbis_residue_decode with setup_classifs.
    fn residueDecode(d: *Decoder, r: *bits.LsbReader, vr: *Residue, ch: u32, do_not_decode: []u8, vec: []f32, vlen: u32, ch_left: u32) Error!void {
        if (vr.kind > 2) return error.InvalidData;
        const c_p_c: u32 = d.codebooks[vr.classbook].dimensions;
        var max_output: u32 = (ch - 1) *% vlen;
        var ptns_to_read: i32 = vr.ptns_to_read;
        var libvorbis_bug = false;
        var ch_used: u32 = ch;
        if (vr.kind == 2) {
            for (1..ch) |j| do_not_decode[0] &= do_not_decode[j];
            if (do_not_decode[0] != 0) return;
            ch_used = 1;
            max_output +%= vr.end / ch;
        } else max_output +%= vr.end;
        if (max_output > ch_left *% vlen) {
            if (max_output <= ch_left *% vlen +% vr.partition_size *% ch_used / ch) {
                ptns_to_read -= 1;
                libvorbis_bug = true;
            } else return error.InvalidData; // "Insufficient output buffer"
        }
        var pass: u32 = 0;
        while (pass <= vr.maxpass) : (pass += 1) {
            var voffset: u32 = vr.begin;
            var partition_count: i32 = 0;
            while (partition_count < ptns_to_read) {
                if (pass == 0) try d.setupClassifs(r, vr, do_not_decode, ch_used, partition_count, ptns_to_read);
                var i: u32 = 0;
                while (i < c_p_c and partition_count < ptns_to_read) : (i += 1) {
                    var j_times: usize = 0;
                    for (0..ch_used) |j| {
                        defer j_times += @intCast(ptns_to_read);
                        if (do_not_decode[j] != 0) continue;
                        const vqclass = vr.classifs[j_times + @as(usize, @intCast(partition_count))];
                        const vqbook = vr.books[vqclass][pass];
                        if (vqbook < 0) continue;
                        const codebook = &d.codebooks[@intCast(vqbook)];
                        const vectors = codebook.codevectors orelse continue;
                        const dim: u32 = codebook.dimensions;
                        const step = fastdiv(vr.partition_size << 1, dim << 1);
                        if (r.left() < 0) return; // "Overread"
                        try decodePartition(r, codebook, vectors, vr.kind, ch, @intCast(j), dim, step, voffset, vec, vlen);
                    }
                    partition_count += 1;
                    voffset +%= vr.partition_size;
                }
            }
            if (libvorbis_bug and pass == 0) {
                for (0..ch_used) |j| {
                    if (do_not_decode[j] == 0) _ = d.codebooks[vr.classbook].get(r);
                }
            }
        }
    }

    /// setup_classifs: each channel's partition classes from the class
    /// book, `c_p_c` at a time.
    fn setupClassifs(d: *Decoder, r: *bits.LsbReader, vr: *Residue, do_not_decode: []const u8, ch_used: u32, partition_count: i32, ptns_to_read: i32) Error!void {
        const codebook = &d.codebooks[vr.classbook];
        const c_p_c: i32 = codebook.dimensions;
        const inverse_class = inverse[vr.classifications];
        var p: usize = 0;
        for (0..ch_used) |j| {
            // FFmpeg steps by the partitions it reads, one less after the
            // libvorbis workaround.
            defer p += @intCast(ptns_to_read);
            if (do_not_decode[j] != 0) continue;
            var temp = codebook.get(r);
            if (temp < 0) return error.InvalidData;
            var i: i32 = partition_count + c_p_c - 1;
            while (i >= partition_count) : (i -= 1) {
                if (vr.classifications == 1) {
                    if (i < ptns_to_read) vr.classifs[p + @as(usize, @intCast(i))] = 0;
                } else {
                    const temp2: i32 = @intCast((@as(u64, @intCast(temp)) * inverse_class) >> 32);
                    if (i < ptns_to_read) vr.classifs[p + @as(usize, @intCast(i))] = @truncate(@as(u32, @bitCast(temp - temp2 * @as(i32, vr.classifications))));
                    temp = temp2;
                }
            }
        }
    }
};

/// ff_vorbis_ch_layouts: the decoder's layout for 1 to 8 channels, by
/// FFmpeg's names (mono, stereo, 3.0, quad, 5.0, 5.1, 6.1, 7.1); more
/// channels have none.
pub fn channelLayout(channels: u8) channel_layout.Layout {
    if (channels == 0 or channels > 8) return .{ .unspecified = channels };
    return .{ .native = layout_masks[channels - 1] };
}

const layout_masks = masks: {
    const names = [8][]const u8{ "mono", "stereo", "3.0", "quad", "5.0", "5.1", "6.1", "7.1" };
    var out: [8]u64 = undefined;
    for (names, &out) |name, *m| {
        m.* = for (channel_layout.named_layouts) |n| {
            if (std.mem.eql(u8, n.name, name)) break n.mask;
        } else @compileError("no named layout " ++ name);
    }
    break :masks out;
};

/// BARK: single-precision products, double-precision arctangents.
fn bark(x: f32) f64 {
    const a: f64 = @as(f32, 0.00074) * x;
    const b: f64 = @as(f32, 1.85e-8) * x * x;
    const c: f32 = @as(f32, 1e-4) * x;
    return @as(f64, @as(f32, 13.1)) * std.math.atan(a) + @as(f64, @as(f32, 2.24)) * std.math.atan(b) + @as(f64, c);
}

fn clipU16(v: i32) u16 {
    return @intCast(std.math.clamp(v, 0, 65535));
}

fn clipU8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn dbAt(y: i32) f32 {
    return data.floor1_inverse_db_table[clipU8(y)];
}

/// render_line_unrolled: the common case of a shallow line.
fn renderLineUnrolled(x_start: isize, y_start: i32, x1: i32, sy: i32, ady: i32, adx: i32, buf: []f32) void {
    var err: i32 = -adx;
    var y = y_start;
    const base: isize = x1 - 1;
    var x: isize = x_start - base;
    while (true) {
        x += 1;
        if (!(x < 0)) break;
        err += ady;
        if (err >= 0) {
            err += ady - adx;
            y += sy;
            buf[@intCast(base + x)] = dbAt(y);
            x += 1;
        }
        buf[@intCast(base + x)] = dbAt(y);
    }
    if (x <= 0) {
        if (err + ady >= 0) y += sy;
        buf[@intCast(base + x)] = dbAt(y);
    }
}

/// render_line: floor 1's segment from (x0, y0) to (x1, y1), x1 excluded.
fn renderLine(x0: i32, y0: i32, x1: i32, y1: i32, buf: []f32) void {
    const dy = y1 - y0;
    const adx = x1 - x0;
    var ady: i32 = @intCast(@abs(dy));
    const sy: i32 = if (dy < 0) -1 else 1;
    buf[@intCast(x0)] = dbAt(y0);
    if (ady * 2 <= adx) {
        renderLineUnrolled(x0, y0, x1, sy, ady, adx, buf);
    } else {
        const base = @divTrunc(dy, adx);
        var x = x0;
        var y = y0;
        var err = -adx;
        ady -= @as(i32, @intCast(@abs(base))) * adx;
        while (true) {
            x += 1;
            if (!(x < x1)) break;
            y += base;
            err += ady;
            if (err >= 0) {
                err -= adx;
                y += sy;
            }
            buf[@intCast(x)] = dbAt(y);
        }
    }
}

/// ff_vorbis_floor1_render_list: the floor's points joined by lines in x
/// order, up to `samples`.
fn render(list: []const Floor1Entry, y_list: []const u16, flag: []const bool, multiplier: u8, out: []f32, samples_in: u16) void {
    const samples: i32 = samples_in;
    var lx: i32 = 0;
    var ly: i32 = @as(i32, y_list[0]) * multiplier;
    for (1..list.len) |i| {
        const pos = list[i].sort;
        if (flag[pos]) {
            const x1: i32 = list[pos].x;
            const y1: i32 = @as(i32, y_list[pos]) * multiplier;
            if (lx < samples) renderLine(lx, ly, @min(x1, samples), y1, out);
            lx = x1;
            ly = y1;
        }
        if (lx >= samples) break;
    }
    if (lx < samples) renderLine(lx, ly, samples, ly, out);
}

/// vorbis_inverse_coupling_c.
fn inverseCoupling(mag: []f32, ang: []f32) void {
    for (mag, ang) |*m, *a| {
        const angi = a.*;
        const magi = m.*;
        if (magi > 0.0) {
            if (angi > 0.0) {
                a.* = magi - angi;
            } else {
                a.* = magi;
                m.* = magi + angi;
            }
        } else {
            if (angi > 0.0) {
                a.* = magi + angi;
            } else {
                a.* = magi;
                m.* = magi - angi;
            }
        }
    }
}

/// vector_fmul_window_c: `dst[0 .. 2 * len]` from the end of the saved
/// block and the start of the new one under the window `win[0 .. 2 * len]`.
fn fmulWindow(dst: []f32, src0: []const f32, src1: []const f32, win: []const f32, len: usize) void {
    for (0..len) |n| {
        const m = 2 * len - 1 - n;
        const s0 = src0[n];
        const s1 = src1[len - 1 - n];
        const wi = win[n];
        const wj = win[m];
        dst[n] = s0 * wj - s1 * wi;
        dst[m] = s0 * wi + s1 * wj;
    }
}

/// `vec[idx] += v`, refusing an index past the residues, where FFmpeg's
/// earlier checks leave none.
fn addAt(vec: []f32, idx: usize, v: f32) Error!void {
    if (idx >= vec.len) return error.InvalidData;
    vec[idx] += v;
}

/// One partition of one channel: `step` vectors of `dim` values each, added
/// as the residue type lays them out.
fn decodePartition(r: *bits.LsbReader, codebook: *const Codebook, vectors: []const f32, kind: u16, ch: u32, j: u32, dim: u32, step: u32, voffset: u32, vec: []f32, vlen: u32) Error!void {
    const next = struct {
        fn vector(rr: *bits.LsbReader, cb: *const Codebook, vs: []const f32, width: u32) Error![]const f32 {
            const raw = cb.get(rr);
            if (raw < 0) return error.InvalidData;
            const start = @as(usize, @intCast(raw)) * width;
            if (start + width > vs.len) return error.InvalidData;
            return vs[start..][0..width];
        }
    }.vector;
    if (kind == 0) {
        const voffs: usize = voffset + j * vlen;
        for (0..step) |k| {
            const v = try next(r, codebook, vectors, dim);
            for (0..dim) |l| try addAt(vec, voffs + k + l * step, v[l]);
        }
    } else if (kind == 1) {
        var voffs: usize = voffset + j * vlen;
        for (0..step) |_| {
            const v = try next(r, codebook, vectors, dim);
            for (0..dim) |l| {
                try addAt(vec, voffs, v[l]);
                voffs += 1;
            }
        }
    } else if (ch == 2 and voffset & 1 == 0 and dim & 1 == 0) {
        // The most frequent case, laid out directly.
        var voffs: usize = voffset >> 1;
        if (dim == 2) {
            for (0..step) |k| {
                const v = try next(r, codebook, vectors, 2);
                try addAt(vec, voffs + k, v[0]);
                try addAt(vec, voffs + k + vlen, v[1]);
            }
        } else if (dim == 4) {
            for (0..step) |_| {
                const v = try next(r, codebook, vectors, 4);
                try addAt(vec, voffs, v[0]);
                try addAt(vec, voffs + 1, v[2]);
                try addAt(vec, voffs + vlen, v[1]);
                try addAt(vec, voffs + vlen + 1, v[3]);
                voffs += 2;
            }
        } else {
            for (0..step) |_| {
                const v = try next(r, codebook, vectors, dim);
                var l: usize = 0;
                while (l < dim) : (l += 2) {
                    try addAt(vec, voffs, v[l]);
                    try addAt(vec, voffs + vlen, v[l + 1]);
                    voffs += 1;
                }
            }
        }
    } else {
        var voffs_div: u32 = if (ch == 1) voffset else fastdiv(voffset, ch);
        var voffs_mod: u32 = voffset -% voffs_div *% ch;
        for (0..step) |_| {
            const v = try next(r, codebook, vectors, dim);
            for (0..dim) |l| {
                try addAt(vec, @as(usize, voffs_div) + @as(usize, voffs_mod) * vlen, v[l]);
                voffs_mod += 1;
                if (voffs_mod == ch) {
                    voffs_div += 1;
                    voffs_mod = 0;
                }
            }
        }
    }
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
