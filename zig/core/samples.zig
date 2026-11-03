// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// The size, line and plane rules follow av_samples_get_buffer_size,
// av_samples_fill_arrays, av_samples_set_silence and av_samples_copy in
// libavutil/samplefmt.c at the pinned reference revision; see port.md.
//! Decoded sample storage (TODO.md T20a): how many bytes a buffer of samples
//! needs, where each plane starts, silence and copying, for every
//! `audio.SampleFormat`, packed or planar.
//!
//! `Layout.init` computes the sizes. A packed format has one plane holding
//! every channel interleaved; a planar format has one plane per channel. Each
//! plane is `linesize` bytes, the sample data padded as `Alignment` asks, and
//! plane `i` starts `i * linesize` bytes into the buffer. Like FFmpeg, no
//! buffer may reach 2^31 bytes. `Buffer` is a view of a caller's bytes laid
//! out that way; `Buffer.alloc` returns an `Owned` buffer, filled with silence.

const std = @import("std");
const audio = @import("audio.zig");

/// The largest buffer, in bytes: FFmpeg's `INT_MAX` bound.
pub const max_buffer_bytes: u32 = std.math.maxInt(i32);

/// Memory alignment of `Buffer.alloc`, the largest FFmpeg's `av_malloc` uses.
pub const memory_alignment: std.mem.Alignment = .@"64";

pub const Alignment = union(enum) {
    /// FFmpeg's `align = 0`: the sample count rounds up to a multiple of 32
    /// and lines are not padded further.
    sample_padding,
    /// Each line rounds up to a multiple of this power of two (FFmpeg's
    /// `align = n`); 1 means no padding.
    line: u32,
};

pub const LayoutError = error{
    /// No channels, no samples, or a line alignment that is not a power of
    /// two (FFmpeg does not check the last; its results then are not
    /// meaningful).
    InvalidArgument,
    /// The buffer would reach `max_buffer_bytes`.
    SizeOverflow,
};

pub const Layout = struct {
    format: audio.SampleFormat,
    channels: u32,
    /// Samples per channel the buffer holds, as requested (without padding).
    samples: u32,
    /// Bytes per plane, padding included.
    linesize: u32,
    /// Bytes of the whole buffer: `linesize * planeCount()`.
    size: u32,

    pub fn init(format: audio.SampleFormat, channels: u32, samples: u32, alignment: Alignment) LayoutError!Layout {
        if (channels == 0 or samples == 0) return error.InvalidArgument;
        const max: u64 = max_buffer_bytes;
        const sample_size: u64 = format.bytesPerSample();
        var padded: u64 = samples;
        const line_align: u64 = switch (alignment) {
            .sample_padding => blk: {
                if (samples > max - 31) return error.SizeOverflow;
                padded = std.mem.alignForward(u64, padded, 32);
                break :blk 1;
            },
            .line => |line| blk: {
                if (line == 0 or !std.math.isPowerOfTwo(line)) return error.InvalidArgument;
                break :blk line;
            },
        };
        // FFmpeg's bound, in its order: padding every channel's line must
        // still leave the data below max. The first test keeps the product
        // in the second below max, so the subtraction cannot wrap.
        if (channels > max / line_align or
            channels * padded > (max - line_align * channels) / sample_size) return error.SizeOverflow;
        const data_per_line = if (format.isPlanar()) padded * sample_size else padded * sample_size * channels;
        const linesize = std.mem.alignForward(u64, data_per_line, line_align);
        const planes: u64 = if (format.isPlanar()) channels else 1;
        // Both are at most max by the bound above.
        return .{
            .format = format,
            .channels = channels,
            .samples = samples,
            .linesize = @intCast(linesize),
            .size = @intCast(linesize * planes),
        };
    }

    /// One plane per channel when planar, else one.
    pub fn planeCount(layout: Layout) u32 {
        return if (layout.format.isPlanar()) layout.channels else 1;
    }

    /// Where plane `index` starts in the buffer.
    pub fn planeOffset(layout: Layout, index: u32) usize {
        std.debug.assert(index < layout.planeCount());
        const plane: usize = index; // Widen first: the product may pass u32.
        return plane * layout.linesize;
    }

    /// Bytes one sample position takes in a plane: one sample (planar) or
    /// one per channel (packed).
    pub fn blockAlign(layout: Layout) usize {
        const per_sample: usize = layout.format.bytesPerSample();
        return if (layout.format.isPlanar()) per_sample else per_sample * layout.channels;
    }
};

/// Samples in a caller's bytes, laid out by `layout`. A view: it never owns
/// `bytes`, and copying it copies only the view.
pub const Buffer = struct {
    layout: Layout,
    /// At least `layout.size` bytes; only those are used.
    bytes: []u8,

    /// A view of `bytes` (FFmpeg's `av_samples_fill_arrays`).
    pub fn init(layout: Layout, bytes: []u8) error{BufferTooSmall}!Buffer {
        if (bytes.len < layout.size) return error.BufferTooSmall;
        return .{ .layout = layout, .bytes = bytes[0..layout.size] };
    }

    /// All `linesize` bytes of plane `index`, padding included.
    pub fn plane(buffer: Buffer, index: u32) []u8 {
        return buffer.bytes[buffer.layout.planeOffset(index)..][0..buffer.layout.linesize];
    }

    /// Writes silence over `count` samples per channel from `offset` (FFmpeg's
    /// `av_samples_set_silence`).
    pub fn setSilence(buffer: Buffer, offset: u32, count: u32) void {
        const start: u64 = offset;
        std.debug.assert(start + count <= buffer.layout.samples);
        const block = buffer.layout.blockAlign();
        for (0..buffer.layout.planeCount()) |i| {
            const data = buffer.plane(@intCast(i));
            @memset(data[offset * block ..][0 .. count * block], buffer.layout.format.silenceByte());
        }
    }

    /// Copies `count` samples per channel from `src` at `src_offset` to `dst`
    /// at `dst_offset` (FFmpeg's `av_samples_copy`). The buffers must share
    /// format and channel count; they may overlap, even be the same buffer.
    pub fn copy(dst: Buffer, src: Buffer, dst_offset: u32, src_offset: u32, count: u32) void {
        std.debug.assert(dst.layout.format == src.layout.format and dst.layout.channels == src.layout.channels);
        const dst_start: u64 = dst_offset;
        const src_start: u64 = src_offset;
        std.debug.assert(dst_start + count <= dst.layout.samples);
        std.debug.assert(src_start + count <= src.layout.samples);
        const block = dst.layout.blockAlign();
        for (0..dst.layout.planeCount()) |i| {
            const to = dst.plane(@intCast(i))[dst_offset * block ..][0 .. count * block];
            const from = src.plane(@intCast(i))[src_offset * block ..][0 .. count * block];
            @memmove(to, from);
        }
    }

    /// A buffer that owns its bytes, allocated `memory_alignment`-aligned.
    pub const Owned = struct {
        /// `buffer.bytes` is owned; do not free it or point it elsewhere.
        buffer: Buffer,
        gpa: std.mem.Allocator,

        pub fn deinit(owned: *Owned) void {
            const bytes: []align(memory_alignment.toByteUnits()) u8 = @alignCast(owned.buffer.bytes);
            owned.gpa.free(bytes);
            owned.* = undefined;
        }
    };

    /// Allocates a buffer for `layout` and fills it with silence (FFmpeg's
    /// `av_samples_alloc`). On failure nothing is allocated.
    pub fn alloc(gpa: std.mem.Allocator, layout: Layout) std.mem.Allocator.Error!Owned {
        const bytes = try gpa.alignedAlloc(u8, memory_alignment, layout.size);
        const buffer: Buffer = .{ .layout = layout, .bytes = bytes };
        buffer.setSilence(0, layout.samples);
        return .{ .buffer = buffer, .gpa = gpa };
    }
};

// zig/testing/vectors/samplefmt.txt comes from the pinned FFmpeg's libavutil
// through zig/testing/reference/samplefmt_vectors.c. Every line is checked;
// the counts make a truncated or missing file fail.
const vectors = @embedFile("../testing/vectors/samplefmt.txt");

/// The next field of a vector line; a short line is malformed, not a panic.
fn field(fields: *std.mem.TokenIterator(u8, .scalar)) error{MalformedVector}![]const u8 {
    return fields.next() orelse error.MalformedVector;
}
const format_vector_count = 12;
const buffer_vector_count = 3516;

test "every sample format has FFmpeg's size, planarity, forms and silence" {
    var lines = std.mem.tokenizeAny(u8, vectors, "\r\n");
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line[0] != 'F') continue;
        var fields = std.mem.tokenizeScalar(u8, line[2..], ' ');
        const format = audio.SampleFormat.fromName(try field(&fields)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(try std.fmt.parseInt(u8, try field(&fields), 10), format.bytesPerSample());
        try std.testing.expectEqual(std.mem.eql(u8, try field(&fields), "1"), format.isPlanar());
        try std.testing.expectEqualStrings(try field(&fields), format.packedForm().name());
        try std.testing.expectEqualStrings(try field(&fields), format.planarForm().name());
        try std.testing.expectEqual(try std.fmt.parseInt(u8, try field(&fields), 10), format.silenceByte());
        seen += 1;
    }
    try std.testing.expectEqual(format_vector_count, seen);
    try std.testing.expectEqual(format_vector_count, @typeInfo(audio.SampleFormat).@"enum".field_names.len);
    try std.testing.expectEqual(null, audio.SampleFormat.fromName("dsd"));
}

test "buffer sizes, line sizes and plane offsets equal FFmpeg's for every format" {
    var lines = std.mem.tokenizeAny(u8, vectors, "\r\n");
    var seen: usize = 0;
    while (lines.next()) |line| {
        if (line[0] != 'B') continue;
        var fields = std.mem.tokenizeScalar(u8, line[2..], ' ');
        const format = audio.SampleFormat.fromName(try field(&fields)) orelse return error.TestUnexpectedResult;
        const channels = try std.fmt.parseInt(u32, try field(&fields), 10);
        const samples = try std.fmt.parseInt(u32, try field(&fields), 10);
        const align_value = try std.fmt.parseInt(u32, try field(&fields), 10);
        const alignment: Alignment = if (align_value == 0) .sample_padding else .{ .line = align_value };
        const result = Layout.init(format, channels, samples, alignment);
        const size_text = try field(&fields);
        seen += 1;
        if (std.mem.eql(u8, size_text, "E")) {
            if (result) |_| {
                std.debug.print("vector \"{s}\": FFmpeg fails, Layout.init succeeds\n", .{line});
                return error.TestExpectedError;
            } else |_| continue;
        }
        const layout = result catch |err| {
            std.debug.print("vector \"{s}\": {t}\n", .{ line, err });
            return err;
        };
        try std.testing.expectEqual(try std.fmt.parseInt(u32, size_text, 10), layout.size);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, try field(&fields), 10), layout.linesize);
        const offset_text = try field(&fields);
        if (!std.mem.eql(u8, offset_text, "-")) {
            const last_plane = layout.planeCount() - 1;
            try std.testing.expectEqual(try std.fmt.parseInt(usize, offset_text, 10), layout.planeOffset(last_plane));
        }
    }
    try std.testing.expectEqual(buffer_vector_count, seen);
}

test "zero counts and bad alignments are invalid, sizes past the bound overflow" {
    try std.testing.expectError(error.InvalidArgument, Layout.init(.s16, 0, 1, .{ .line = 1 }));
    try std.testing.expectError(error.InvalidArgument, Layout.init(.s16, 1, 0, .sample_padding));
    try std.testing.expectError(error.InvalidArgument, Layout.init(.s16, 1, 1, .{ .line = 0 }));
    try std.testing.expectError(error.InvalidArgument, Layout.init(.s16, 1, 1, .{ .line = 3 }));
    try std.testing.expectError(error.SizeOverflow, Layout.init(.u8, 1, max_buffer_bytes, .{ .line = 1 }));
    try std.testing.expectError(error.SizeOverflow, Layout.init(.dblp, std.math.maxInt(u32), std.math.maxInt(u32), .{ .line = 64 }));
    const largest = try Layout.init(.u8, 1, max_buffer_bytes - 1, .{ .line = 1 });
    try std.testing.expectEqual(max_buffer_bytes - 1, largest.size);
}

test "a buffer view checks its size and exposes each plane" {
    const layout = try Layout.init(.s16p, 3, 5, .{ .line = 16 });
    try std.testing.expectEqual(16, layout.linesize);
    try std.testing.expectEqual(48, layout.size);
    var bytes: [64]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, Buffer.init(layout, bytes[0..47]));
    const buffer = try Buffer.init(layout, &bytes);
    try std.testing.expectEqual(48, buffer.bytes.len);
    try std.testing.expectEqual(&bytes[32], &buffer.plane(2)[0]);
    const packed_layout = try Layout.init(.s16, 3, 5, .{ .line = 16 });
    try std.testing.expectEqual(1, packed_layout.planeCount());
    try std.testing.expectEqual(32, packed_layout.linesize);
}

test "silence is 0x80 for unsigned 8-bit and zero otherwise, only where asked" {
    var bytes: [32]u8 = undefined;
    @memset(&bytes, 0xff);
    const u8_buffer = try Buffer.init(try Layout.init(.u8p, 2, 4, .{ .line = 8 }), &bytes);
    u8_buffer.setSilence(1, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x80, 0x80, 0xff }, bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x80, 0x80, 0xff }, bytes[8..12]);

    @memset(&bytes, 0xff);
    const s16_buffer = try Buffer.init(try Layout.init(.s16, 2, 2, .{ .line = 1 }), &bytes);
    s16_buffer.setSilence(0, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0xff }, bytes[0..5]);
}

test "copying moves whole sample positions and allows overlap" {
    var a: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var b: [16]u8 = @splat(0);
    const layout = try Layout.init(.s16, 2, 4, .{ .line = 1 }); // 4 bytes per position
    const src = try Buffer.init(layout, &a);
    const dst = try Buffer.init(layout, &b);
    Buffer.copy(dst, src, 1, 2, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 9, 10, 11, 12, 13, 14, 15, 16, 0, 0, 0, 0 }, &b);
    // Overlapping, forward and backward, within one buffer.
    Buffer.copy(src, src, 1, 0, 3);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, &a);
    Buffer.copy(src, src, 0, 1, 3);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 9, 10, 11, 12 }, &a);

    var planar_bytes: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const planar = try Buffer.init(try Layout.init(.u8p, 2, 8, .{ .line = 1 }), &planar_bytes);
    Buffer.copy(planar, planar, 0, 6, 2);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 3, 4, 5, 6, 7, 8, 15, 16, 11, 12, 13, 14, 15, 16 }, &planar_bytes);
}

test "an allocated buffer is aligned, silent and released" {
    const gpa = std.testing.allocator;
    var owned = try Buffer.alloc(gpa, try Layout.init(.u8, 2, 1000, .sample_padding));
    defer owned.deinit();
    try std.testing.expectEqual(0, @intFromPtr(owned.buffer.bytes.ptr) % memory_alignment.toByteUnits());
    try std.testing.expectEqual(2048, owned.buffer.bytes.len);
    for (owned.buffer.bytes[0..2000]) |byte| try std.testing.expectEqual(0x80, byte);
}

fn allocAndRelease(gpa: std.mem.Allocator) !void {
    var owned = try Buffer.alloc(gpa, try Layout.init(.fltp, 2, 64, .{ .line = 32 }));
    owned.deinit();
}

test "allocation failure leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocAndRelease, .{});
}
