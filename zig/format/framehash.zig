// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/framecrcenc.c, framehash.c (ff_framehash_write_header) and
// hashenc.c (the framemd5 and streamhash muxers, format version 2) at the
// pinned reference revision describe the output, restated here.
//! FFmpeg's hash muxers for audio and video streams (TODO.md T19b, several
//! streams since T33a3): `framecrc`
//! (each packet's Adler-32), `framemd5` (each packet's MD5) and
//! `streamhash` (the SHA-256 of every packet's bytes), written as FFmpeg
//! writes them with `-fflags +bitexact`, so the text compares byte for byte.
//!
//! framecrc starts each packet's Adler-32 from 0 (`av_adler32_update(0,
//! ...)`), not the usual 1. A packet's line holds its stream index, dts, pts,
//! duration, size and hash; a missing timestamp prints as FFmpeg's
//! `AV_NOPTS_VALUE` and a missing duration as 0, the values FFmpeg's packet
//! holds. Equal hashes alone do not prove equal media: the boundaries, time
//! base and stream description are part of the text.

const std = @import("std");
const packet = @import("../core/packet.zig");
const time = @import("../core/time.zig");
const channel_layout = @import("../core/channel_layout.zig");

pub const Kind = enum {
    framecrc,
    framemd5,
    streamhash,

    /// The FFmpeg muxer names.
    pub fn fromName(name: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, name);
    }
};

/// The stream description the header prints.
pub const Stream = struct {
    time_base: time.TimeBase,
    /// The codec, as FFmpeg names it (`avcodec_get_name`).
    codec: []const u8,
    /// An audio stream's rate and layout.
    sample_rate: u32 = 0,
    layout: channel_layout.Layout = .{ .unspecified = 0 },
    /// The codec's extradata, hashed in the header when present.
    extradata: ?[]const u8 = null,
    /// A video stream's picture: then `#dimensions` and `#sar` replace the
    /// audio lines.
    video: ?Video = null,
};

/// A video stream's header fields: the codec's size and the stream's
/// sample aspect ratio.
pub const Video = struct {
    width: i32,
    height: i32,
    sar_num: i32,
    sar_den: i32,
};

/// The streams one writer takes.
pub const max_streams = 8;

/// A packet's side data as framecrc names it (`av_packet_side_data_name`).
pub const SideData = struct {
    name: []const u8,
    data: []const u8,
};

const nopts: i64 = std.math.minInt(i64);
const Md5 = std.crypto.hash.Md5;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Frame checksums with the Adler-32 FFmpeg's framecrc uses: from 0.
pub fn adler32(bytes: []const u8) u32 {
    return std.hash.Adler32.permute(0, bytes);
}

/// `value` as C's `%d` prints it: Zig's padded `{d}` would add a `+` to a
/// signed value, so the padding goes on the text.
fn decimal(buf: *[24]u8, value: i64) []const u8 {
    // An i64 takes at most 20 characters.
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
}

pub const Writer = struct {
    kind: Kind,
    out: *std.Io.Writer,
    /// The streams, by output index (`init`'s one stream is `single`).
    single: [1]Stream = undefined,
    many: ?[]const Stream = null,
    /// streamhash's running hash and byte count, by stream.
    sha: [max_streams]Sha256 = @splat(.init(.{})),
    size: [max_streams]u64 = @splat(0),

    /// One audio stream, index 0.
    pub fn init(kind: Kind, out: *std.Io.Writer, stream: Stream) Writer {
        return .{ .kind = kind, .out = out, .single = .{stream} };
    }

    /// Several streams in output order, borrowed until the writer is done.
    pub fn initMany(kind: Kind, out: *std.Io.Writer, list: []const Stream) error{TooManyStreams}!Writer {
        if (list.len > max_streams) return error.TooManyStreams;
        return .{ .kind = kind, .out = out, .many = list };
    }

    fn streamList(w: *const Writer) []const Stream {
        return w.many orelse &w.single;
    }

    /// The muxer's header: framecrc's extradata lines, or framemd5's and
    /// streamhash's format lines and extradata hashes, then
    /// ff_framehash_write_header's lines for each stream.
    pub fn writeHeader(w: *Writer) std.Io.Writer.Error!void {
        const out = w.out;
        switch (w.kind) {
            .framecrc => for (w.streamList(), 0..) |st, i| if (st.extradata) |e| {
                try out.print("#extradata {d}: {d:>8}, 0x{x:0>8}\n", .{ i, e.len, adler32(e) });
            },
            .framemd5, .streamhash => {
                try out.print("#format: {s} checksums\n#version: 2\n#hash: {s}\n", .{
                    if (w.kind == .framemd5) "frame" else "stream",
                    if (w.kind == .framemd5) "MD5" else "SHA256",
                });
                for (w.streamList(), 0..) |st, i| if (st.extradata) |e| {
                    try out.print("#extradata {d}, {d:>31}, ", .{ i, e.len });
                    try w.writeHash(e);
                    try out.writeAll("\n");
                };
            },
        }
        for (w.streamList(), 0..) |st, i| {
            try out.print("#tb {d}: {d}/{d}\n", .{ i, st.time_base.num, st.time_base.den });
            if (st.video) |v| {
                try out.print("#media_type {d}: video\n#codec_id {d}: {s}\n#dimensions {d}: {d}x{d}\n#sar {d}: {d}/{d}\n", .{
                    i, i, st.codec, i, v.width, v.height, i, v.sar_num, v.sar_den,
                });
            } else {
                try out.print("#media_type {d}: audio\n#codec_id {d}: {s}\n#sample_rate {d}: {d}\n#channel_layout_name {d}: ", .{
                    i, i, st.codec, i, st.sample_rate, i,
                });
                try st.layout.describe(out);
                try out.writeAll("\n");
            }
        }
        switch (w.kind) {
            .framecrc => {},
            .framemd5 => try out.writeAll("#stream#, dts,        pts, duration,     size, hash\n"),
            .streamhash => try out.writeAll("#stream#, size, hash\n"),
        }
    }

    /// The hash of `bytes` in lowercase hexadecimal, framemd5's or
    /// streamhash's kind.
    fn writeHash(w: *Writer, bytes: []const u8) std.Io.Writer.Error!void {
        switch (w.kind) {
            .framemd5 => {
                var digest: [Md5.digest_length]u8 = undefined;
                Md5.hash(bytes, &digest, .{});
                try w.out.writeAll(&std.fmt.bytesToHex(digest, .lower));
            },
            .streamhash => {
                var digest: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(bytes, &digest, .{});
                try w.out.writeAll(&std.fmt.bytesToHex(digest, .lower));
            },
            .framecrc => unreachable,
        }
    }

    /// One packet: a line for framecrc and framemd5, the running hash for
    /// streamhash.
    pub fn writePacket(w: *Writer, p: packet.Packet) std.Io.Writer.Error!void {
        return w.writePacketSide(p, &.{});
    }

    /// `writePacket` with the packet's side data, which framecrc lists
    /// after the flags as `, S=<count>` and each one's name, size and
    /// Adler-32 (T27a); framemd5 and streamhash do not show it.
    pub fn writePacketSide(w: *Writer, p: packet.Packet, side: []const SideData) std.Io.Writer.Error!void {
        if (w.kind == .streamhash) {
            if (p.stream_index >= w.streamList().len) return error.WriteFailed;
            w.sha[p.stream_index].update(p.data);
            w.size[p.stream_index] += p.data.len;
            return;
        }
        var dts: [24]u8 = undefined;
        var pts: [24]u8 = undefined;
        var duration: [24]u8 = undefined;
        try w.out.print("{d}, {s:>10}, {s:>10}, {s:>8}, {d:>8}, ", .{
            p.stream_index,
            decimal(&dts, p.dts orelse nopts),
            decimal(&pts, p.pts orelse nopts),
            decimal(&duration, p.duration orelse 0),
            p.data.len,
        });
        if (w.kind == .framemd5) {
            try w.writeHash(p.data);
            try w.out.writeAll("\n");
            return;
        }
        try w.out.print("0x{x:0>8}", .{adler32(p.data)});
        // AV_PKT_FLAG_KEY is 1 and AV_PKT_FLAG_DISCARD 4.
        const flags: u32 = @as(u32, @intFromBool(p.flags.key)) | @as(u32, @intFromBool(p.flags.corrupt)) << 1 |
            @as(u32, @intFromBool(p.flags.discard)) << 2 | @as(u32, @intFromBool(p.flags.disposable)) << 4;
        if (flags != 1) try w.out.print(", F=0x{X}", .{flags});
        if (side.len > 0) {
            try w.out.print(", S={d}", .{side.len});
            for (side) |sd| try w.out.print(", {s}, {d:>8}, 0x{x:0>8}", .{ sd.name, sd.data.len, adler32(sd.data) });
        }
        try w.out.writeAll("\n");
    }

    /// streamhash's trailer; nothing for the others.
    pub fn finish(w: *Writer) std.Io.Writer.Error!void {
        if (w.kind != .streamhash) return;
        for (0..w.streamList().len) |i| {
            var digest: [Sha256.digest_length]u8 = undefined;
            w.sha[i].final(&digest);
            try w.out.print("{d}, {d:>11}, {s}\n", .{ i, w.size[i], &std.fmt.bytesToHex(digest, .lower) });
        }
    }
};

const testing = std.testing;

test "Adler-32 from 0, as framecrc computes it: the seed vectors" {
    // The empty input, `abc`, a split update and separate packets.
    try testing.expectEqual(0x00000000, adler32(""));
    try testing.expectEqual(0x024a0126, adler32("abc"));
    // The usual Adler-32 starts from 1.
    try testing.expectEqual(0x024d0127, std.hash.Adler32.hash("abc"));
    // A split update continues the same sum.
    try testing.expectEqual(adler32("abc"), std.hash.Adler32.permute(adler32("a"), "bc"));
    // Each packet starts again from 0: "ab" then "c" is not "abc".
    try testing.expectEqual(0x00630063, adler32("c"));
}

fn render(kind: Kind, stream: Stream, packets: []const packet.Packet, buf: []u8) ![]const u8 {
    var out: std.Io.Writer = .fixed(buf);
    var w: Writer = .init(kind, &out, stream);
    try w.writeHeader();
    for (packets) |p| try w.writePacket(p);
    try w.finish();
    return out.buffered();
}

test "the three muxers' text, as FFmpeg writes it with +bitexact" {
    const tb = try time.TimeBase.ofSampleRate(44100);
    const stream: Stream = .{ .time_base = tb, .codec = "pcm_s16le", .sample_rate = 44100, .layout = .stereo };
    const packets = [_]packet.Packet{
        .{ .data = "abc", .time_base = tb, .pts = 0, .dts = 0, .duration = 1, .flags = .{ .key = true } },
        .{ .data = "", .time_base = tb, .flags = .{ .discard = true } },
    };
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        \\#tb 0: 1/44100
        \\#media_type 0: audio
        \\#codec_id 0: pcm_s16le
        \\#sample_rate 0: 44100
        \\#channel_layout_name 0: stereo
        \\0,          0,          0,        1,        3, 0x024a0126
        \\0, -9223372036854775808, -9223372036854775808,        0,        0, 0x00000000, F=0x4
        \\
    , try render(.framecrc, stream, &packets, &buf));
    try testing.expectEqualStrings(
        \\#format: frame checksums
        \\#version: 2
        \\#hash: MD5
        \\#tb 0: 1/44100
        \\#media_type 0: audio
        \\#codec_id 0: pcm_s16le
        \\#sample_rate 0: 44100
        \\#channel_layout_name 0: stereo
        \\#stream#, dts,        pts, duration,     size, hash
        \\0,          0,          0,        1,        3, 900150983cd24fb0d6963f7d28e17f72
        \\0, -9223372036854775808, -9223372036854775808,        0,        0, d41d8cd98f00b204e9800998ecf8427e
        \\
    , try render(.framemd5, stream, &packets, &buf));
    try testing.expectEqualStrings(
        \\#format: stream checksums
        \\#version: 2
        \\#hash: SHA256
        \\#tb 0: 1/44100
        \\#media_type 0: audio
        \\#codec_id 0: pcm_s16le
        \\#sample_rate 0: 44100
        \\#channel_layout_name 0: stereo
        \\#stream#, size, hash
        \\0,           3, ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        \\
    , try render(.streamhash, stream, &packets, &buf));
}

test "extradata in each header" {
    const tb = try time.TimeBase.ofSampleRate(8000);
    const stream: Stream = .{ .time_base = tb, .codec = "flac", .sample_rate = 8000, .layout = .mono, .extradata = "abc" };
    var buf: [1024]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, try render(.framecrc, stream, &.{}, &buf), "#extradata 0:        3, 0x024a0126\n#tb 0: 1/8000\n"));
    try testing.expect(std.mem.find(u8, try render(.framemd5, stream, &.{}, &buf), "#extradata 0,                               3, 900150983cd24fb0d6963f7d28e17f72\n") != null);
    try testing.expect(std.mem.endsWith(u8, try render(.streamhash, stream, &.{}, &buf), "#stream#, size, hash\n0,           0, e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"));
}
