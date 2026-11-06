// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Test tool for the FFmpeg comparison (TODO.md T16): prints the codec and
//! format registries, one line per entry, for zig/testing/reference/compare.py
//! to check against the reference build's `ffmpeg -codecs`, `ffmpeg -formats`
//! and `ffmpeg -h muxer=<name>`:
//!
//!     codec <name> <flags> <long name>
//!     format <name> <D|.><E|.> <long name>
//!     demuxer <name> <extensions|->
//!     muxer <name> <extensions|-> <MIME type|-> <default audio codec>
//!
//! `flags` are the six columns of `ffmpeg -codecs`: D (a decoder), E (an
//! encoder), A (audio), I (intra-only), L (lossy) and S (lossless), with `.`
//! for an unset one. Extensions are comma-separated. It takes no arguments;
//! exit status 0, or 2 when standard output fails. It is a test tool, not a
//! product: `zig build test-tools` installs it, and `zig build test` compiles
//! it.

const std = @import("std");
const av = @import("av");

pub fn main(init: std.process.Init) u8 {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    write(&stdout.interface) catch return 2;
    return 0;
}

/// `avcodec_find_decoder` / `avcodec_find_encoder` by codec: any
/// implementation of `codec`.
fn hasImplementation(list: []const av.codecs.Implementation, codec: av.codecs.Codec) bool {
    for (list) |i| if (i.codec.eql(codec)) return true;
    return false;
}

/// show_codecs' ` (decoders: ...)` or ` (encoders: ...)`: every
/// implementation of the codec, when one is named otherwise than the codec.
fn printImplementations(out: *std.Io.Writer, label: []const u8, list: []const av.codecs.Implementation, d: *const av.codecs.Descriptor) std.Io.Writer.Error!void {
    const renamed = for (list) |i| {
        if (i.codec.eql(d.codec) and !std.mem.eql(u8, i.name, d.name())) break true;
    } else false;
    if (!renamed) return;
    try out.print(" ({s}:", .{label});
    for (list) |i| if (i.codec.eql(d.codec)) try out.print(" {s}", .{i.name});
    try out.writeByte(')');
}

fn write(out: *std.Io.Writer) std.Io.Writer.Error!void {
    for (&av.codecs.descriptors) |*d| {
        const flags = [6]u8{
            flag(hasImplementation(&av.codecs.decoders, d.codec), 'D'),
            flag(hasImplementation(&av.codecs.encoders, d.codec), 'E'),
            switch (d.media_type) {
                .audio => 'A',
            },
            flag(d.props.intra_only, 'I'),
            flag(d.props.lossy, 'L'),
            flag(d.props.lossless, 'S'),
        };
        try out.print("codec {s} {s} {s}", .{ d.name(), &flags, d.long_name });
        try printImplementations(out, "decoders", &av.codecs.decoders, d);
        try printImplementations(out, "encoders", &av.codecs.encoders, d);
        try out.writeByte('\n');
    }
    for (&av.formats.formats) |*format| {
        try out.print("format {s} {c}{c} {s}\n", .{
            format.name,
            flag(format.demuxer != null, 'D'),
            flag(format.muxer != null, 'E'),
            format.long_name,
        });
    }
    for (&av.formats.formats) |*format| {
        const demuxer = format.demuxer orelse continue;
        try out.print("demuxer {s} ", .{format.name});
        try writeList(out, demuxer.extensions);
        try out.writeByte('\n');
    }
    for (&av.formats.formats) |*format| {
        const muxer = format.muxer orelse continue;
        try out.print("muxer {s} ", .{format.name});
        try writeList(out, muxer.extensions);
        try out.print(" {s} {s}\n", .{ muxer.mime_type orelse "-", muxer.audio_codec.name() });
    }
    try out.flush();
}

/// Comma-separated, or `-` when empty.
fn writeList(out: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    if (items.len == 0) return out.writeAll("-");
    for (items, 0..) |item, i| {
        if (i > 0) try out.writeByte(',');
        try out.writeAll(item);
    }
}

fn flag(set: bool, letter: u8) u8 {
    return if (set) letter else '.';
}
