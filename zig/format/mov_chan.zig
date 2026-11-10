// SPDX-License-Identifier: LGPL-2.1-or-later
// The layout tags and their channel lists are data from
// libavformat/mov_chan.h and mov_chan.c (mov_ch_layout_map, by Justin
// Ruggles and the FFmpeg developers), and the writer's table from
// libavformat/isom.c (mov_channel_layout), at the pinned reference
// revision, LGPL-2.1-or-later; the code is original.
//! Apple's channel layout chunk, `CHAN` in AIFF and `chan` in CAF (TODO.md
//! T23b): reading it as FFmpeg's `ff_mov_read_chan` does, and writing it as
//! `ff_mov_write_chan` does, equal to both on zig/testing/vectors/chan.txt.
//!
//! The body is a layout tag, a channel bitmap and a count of 20-byte channel
//! descriptions, all big-endian. A tag names a channel list (its low 16 bits
//! are the count); `use_bitmap` takes FFmpeg's channel mask from the bitmap,
//! below bit 18; `use_descriptions` takes one channel per description. What a
//! tag or bitmap gives replaces the stream's layout only when its channel
//! count agrees with the stream's, as in FFmpeg; a stream whose count is not
//! known yet (an AIFF `CHAN` before `COMM`) takes the tag's. A channel list
//! is put in FFmpeg's canonical order (`channel_layout.Layout.canonical`).
//!
//! One difference: a body too short for the descriptions it declares is
//! `InvalidFormat`, where FFmpeg keeps the layout and goes on reading after
//! the first 12 bytes, inside the chunk. Nothing allocates.

const std = @import("std");
const channel_layout = @import("../core/channel_layout.zig");
const skip = @import("../io/skip.zig");
const Channel = channel_layout.Channel;
const Layout = channel_layout.Layout;

pub const Error = error{
    /// FFmpeg rejects the body too (`AVERROR_INVALIDDATA`), or it is too
    /// short for its descriptions.
    InvalidFormat,
    /// The input ends inside the body.
    Truncated,
    /// More than `channel_layout.max_custom_channels` descriptions, which
    /// only a channel limit above the default allows.
    LimitExceeded,
    IoFailure,
};

/// The fixed fields: the layout tag, the bitmap and the description count.
pub const header_len = 12;
/// One channel description: the label, flags and three coordinates.
pub const description_len = 20;

/// FFmpeg's `MovChannelLayoutTag`: the tag number shifted by 16, the count
/// in the low 16 bits.
pub const tags = struct {
    pub const use_descriptions = 0x00000000;
    pub const use_bitmap = 0x00010000;
    pub const discreteinorder = 0x00930000;
    pub const mono = 0x00640001;
    pub const stereo = 0x00650002;
    pub const stereoheadphones = 0x00660002;
    pub const matrixstereo = 0x00670002;
    pub const midside = 0x00680002;
    pub const xy = 0x00690002;
    pub const binaural = 0x006a0002;
    pub const ambisonic_b_format = 0x006b0004;
    pub const quadraphonic = 0x006c0004;
    pub const pentagonal = 0x006d0005;
    pub const hexagonal = 0x006e0006;
    pub const octagonal = 0x006f0008;
    pub const cube = 0x00700008;
    pub const mpeg_3_0_a = 0x00710003;
    pub const mpeg_3_0_b = 0x00720003;
    pub const mpeg_4_0_a = 0x00730004;
    pub const mpeg_4_0_b = 0x00740004;
    pub const mpeg_5_0_a = 0x00750005;
    pub const mpeg_5_0_b = 0x00760005;
    pub const mpeg_5_0_c = 0x00770005;
    pub const mpeg_5_0_d = 0x00780005;
    pub const mpeg_5_1_a = 0x00790006;
    pub const mpeg_5_1_b = 0x007a0006;
    pub const mpeg_5_1_c = 0x007b0006;
    pub const mpeg_5_1_d = 0x007c0006;
    pub const mpeg_6_1_a = 0x007d0007;
    pub const mpeg_7_1_a = 0x007e0008;
    pub const mpeg_7_1_b = 0x007f0008;
    pub const mpeg_7_1_c = 0x00800008;
    pub const emagic_default_7_1 = 0x00810008;
    pub const smpte_dtv = 0x00820008;
    pub const itu_2_1 = 0x00830003;
    pub const itu_2_2 = 0x00840004;
    pub const dvd_4 = 0x00850003;
    pub const dvd_5 = 0x00860004;
    pub const dvd_6 = 0x00870005;
    pub const dvd_10 = 0x00880004;
    pub const dvd_11 = 0x00890005;
    pub const dvd_18 = 0x008a0005;
    pub const audiounit_6_0 = 0x008b0006;
    pub const audiounit_7_0 = 0x008c0007;
    pub const audiounit_7_0_front = 0x00940007;
    pub const aac_6_0 = 0x008d0006;
    pub const aac_6_1 = 0x008e0007;
    pub const aac_7_0 = 0x008f0007;
    pub const aac_octagonal = 0x00900008;
    pub const tmh_10_2_std = 0x00910010;
    pub const tmh_10_2_full = 0x00920015;
    pub const ac3_1_0_1 = 0x00950002;
    pub const ac3_3_0 = 0x00960003;
    pub const ac3_3_1 = 0x00970004;
    pub const ac3_3_0_1 = 0x00980004;
    pub const ac3_2_1_1 = 0x00990004;
    pub const ac3_3_1_1 = 0x009a0005;
    pub const eac3_6_0_a = 0x009b0006;
    pub const eac3_7_0_a = 0x009c0007;
    pub const eac3_6_1_a = 0x009d0007;
    pub const eac3_6_1_b = 0x009e0007;
    pub const eac3_6_1_c = 0x009f0007;
    pub const eac3_7_1_a = 0x00a00008;
    pub const eac3_7_1_b = 0x00a10008;
    pub const eac3_7_1_c = 0x00a20008;
    pub const eac3_7_1_d = 0x00a30008;
    pub const eac3_7_1_e = 0x00a40008;
    pub const eac3_7_1_f = 0x00a50008;
    pub const eac3_7_1_g = 0x00a60008;
    pub const eac3_7_1_h = 0x00a70008;
    pub const dts_3_1 = 0x00a80004;
    pub const dts_4_1 = 0x00a90005;
    pub const dts_6_0_a = 0x00aa0006;
    pub const dts_6_0_b = 0x00ab0006;
    pub const dts_6_0_c = 0x00ac0006;
    pub const dts_6_1_a = 0x00ad0007;
    pub const dts_6_1_b = 0x00ae0007;
    pub const dts_6_1_c = 0x00af0007;
    pub const dts_6_1_d = 0x00b60007;
    pub const dts_7_0 = 0x00b00007;
    pub const dts_7_1 = 0x00b10008;
    pub const dts_8_0_a = 0x00b20008;
    pub const dts_8_0_b = 0x00b30008;
    pub const dts_8_1_a = 0x00b40009;
    pub const dts_8_1_b = 0x00b50009;
};

/// The highest bitmap FFmpeg takes: bits above 17 are not channels it maps.
const max_bitmap = 0x40000;

const TagEntry = struct { tag: u32, channels: []const Channel };

fn ambisonic(component: i32) Channel {
    return @fromBackingInt(0x400 + component);
}

/// `mov_ch_layout_map`. FFmpeg's channels without a counterpart (`Csd`, `HI`,
/// `VI`, `Haptic`) are `unknown`, as `mov_get_channel_layout` makes them.
const tag_map = [_]TagEntry{
    .{ .tag = tags.mono, .channels = &.{.front_center} },
    .{ .tag = tags.stereo, .channels = &.{ .front_left, .front_right } },
    .{ .tag = tags.stereoheadphones, .channels = &.{ .front_left, .front_right } },
    .{ .tag = tags.binaural, .channels = &.{ .front_left, .front_right } },
    .{ .tag = tags.midside, .channels = &.{ .front_left, .front_right } },
    .{ .tag = tags.xy, .channels = &.{ .front_left, .front_right } },
    .{ .tag = tags.matrixstereo, .channels = &.{ .stereo_left, .stereo_right } },
    .{ .tag = tags.ac3_1_0_1, .channels = &.{ .front_center, .low_frequency } },
    .{ .tag = tags.mpeg_3_0_a, .channels = &.{ .front_left, .front_right, .front_center } },
    .{ .tag = tags.mpeg_3_0_b, .channels = &.{ .front_center, .front_left, .front_right } },
    .{ .tag = tags.ac3_3_0, .channels = &.{ .front_left, .front_center, .front_right } },
    .{ .tag = tags.itu_2_1, .channels = &.{ .front_left, .front_right, .back_center } },
    .{ .tag = tags.dvd_4, .channels = &.{ .front_left, .front_right, .low_frequency } },
    .{ .tag = tags.ambisonic_b_format, .channels = &.{ ambisonic(0), ambisonic(3), ambisonic(1), ambisonic(2) } },
    .{ .tag = tags.quadraphonic, .channels = &.{ .front_left, .front_right, .back_left, .back_right } },
    .{ .tag = tags.mpeg_4_0_a, .channels = &.{ .front_left, .front_right, .front_center, .back_center } },
    .{ .tag = tags.mpeg_4_0_b, .channels = &.{ .front_center, .front_left, .front_right, .back_center } },
    .{ .tag = tags.ac3_3_1, .channels = &.{ .front_left, .front_center, .front_right, .back_center } },
    .{ .tag = tags.itu_2_2, .channels = &.{ .front_left, .front_right, .side_left, .side_right } },
    .{ .tag = tags.dvd_5, .channels = &.{ .front_left, .front_right, .low_frequency, .back_center } },
    .{ .tag = tags.ac3_2_1_1, .channels = &.{ .front_left, .front_right, .back_center, .low_frequency } },
    .{ .tag = tags.dvd_10, .channels = &.{ .front_left, .front_right, .front_center, .low_frequency } },
    .{ .tag = tags.ac3_3_0_1, .channels = &.{ .front_left, .front_center, .front_right, .low_frequency } },
    .{ .tag = tags.dts_3_1, .channels = &.{ .front_center, .front_left, .front_right, .low_frequency } },
    .{ .tag = tags.pentagonal, .channels = &.{ .front_left, .front_right, .back_left, .back_right, .front_center } },
    .{ .tag = tags.mpeg_5_0_a, .channels = &.{ .front_left, .front_right, .front_center, .side_left, .side_right } },
    .{ .tag = tags.mpeg_5_0_b, .channels = &.{ .front_left, .front_right, .side_left, .side_right, .front_center } },
    .{ .tag = tags.mpeg_5_0_c, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right } },
    .{ .tag = tags.mpeg_5_0_d, .channels = &.{ .front_center, .front_left, .front_right, .side_left, .side_right } },
    .{ .tag = tags.dvd_6, .channels = &.{ .front_left, .front_right, .low_frequency, .side_left, .side_right } },
    .{ .tag = tags.dvd_18, .channels = &.{ .front_left, .front_right, .side_left, .side_right, .low_frequency } },
    .{ .tag = tags.dvd_11, .channels = &.{ .front_left, .front_right, .front_center, .low_frequency, .back_center } },
    .{ .tag = tags.ac3_3_1_1, .channels = &.{ .front_left, .front_center, .front_right, .back_center, .low_frequency } },
    .{ .tag = tags.dts_4_1, .channels = &.{ .front_center, .front_left, .front_right, .back_center, .low_frequency } },
    .{ .tag = tags.hexagonal, .channels = &.{ .front_left, .front_right, .back_left, .back_right, .front_center, .back_center } },
    .{ .tag = tags.dts_6_0_c, .channels = &.{ .front_center, .back_center, .front_left, .front_right, .back_left, .back_right } },
    .{ .tag = tags.mpeg_5_1_a, .channels = &.{ .front_left, .front_right, .front_center, .low_frequency, .side_left, .side_right } },
    .{ .tag = tags.mpeg_5_1_b, .channels = &.{ .front_left, .front_right, .side_left, .side_right, .front_center, .low_frequency } },
    .{ .tag = tags.mpeg_5_1_c, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency } },
    .{ .tag = tags.mpeg_5_1_d, .channels = &.{ .front_center, .front_left, .front_right, .side_left, .side_right, .low_frequency } },
    .{ .tag = tags.audiounit_6_0, .channels = &.{ .front_left, .front_right, .side_left, .side_right, .front_center, .back_center } },
    .{ .tag = tags.aac_6_0, .channels = &.{ .front_center, .front_left, .front_right, .side_left, .side_right, .back_center } },
    .{ .tag = tags.eac3_6_0_a, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .back_center } },
    .{ .tag = tags.dts_6_0_a, .channels = &.{ .front_left_of_center, .front_right_of_center, .front_left, .front_right, .side_left, .side_right } },
    .{ .tag = tags.dts_6_0_b, .channels = &.{ .front_center, .front_left, .front_right, .back_left, .back_right, .top_center } },
    .{ .tag = tags.mpeg_6_1_a, .channels = &.{ .front_left, .front_right, .front_center, .low_frequency, .side_left, .side_right, .back_center } },
    .{ .tag = tags.aac_6_1, .channels = &.{ .front_center, .front_left, .front_right, .side_left, .side_right, .back_center, .low_frequency } },
    .{ .tag = tags.eac3_6_1_a, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .back_center } },
    .{ .tag = tags.dts_6_1_d, .channels = &.{ .front_center, .front_left, .front_right, .side_left, .side_right, .low_frequency, .back_center } },
    .{ .tag = tags.audiounit_7_0, .channels = &.{ .front_left, .front_right, .side_left, .side_right, .front_center, .back_left, .back_right } },
    .{ .tag = tags.aac_7_0, .channels = &.{ .front_center, .front_left, .front_right, .side_left, .side_right, .back_left, .back_right } },
    .{ .tag = tags.eac3_7_0_a, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .back_left, .back_right } },
    .{ .tag = tags.audiounit_7_0_front, .channels = &.{ .front_left, .front_right, .side_left, .side_right, .front_center, .front_left_of_center, .front_right_of_center } },
    .{ .tag = tags.dts_7_0, .channels = &.{ .front_left_of_center, .front_center, .front_right_of_center, .front_left, .front_right, .side_left, .side_right } },
    .{ .tag = tags.eac3_6_1_b, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .top_center } },
    .{ .tag = tags.eac3_6_1_c, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .top_front_center } },
    .{ .tag = tags.dts_6_1_a, .channels = &.{ .front_left_of_center, .front_right_of_center, .front_left, .front_right, .side_left, .side_right, .low_frequency } },
    .{ .tag = tags.dts_6_1_b, .channels = &.{ .front_center, .front_left, .front_right, .back_left, .back_right, .top_center, .low_frequency } },
    .{ .tag = tags.dts_6_1_c, .channels = &.{ .front_center, .back_center, .front_left, .front_right, .back_left, .back_right, .low_frequency } },
    .{ .tag = tags.octagonal, .channels = &.{ .front_left, .front_right, .back_left, .back_right, .front_center, .back_center, .side_left, .side_right } },
    .{ .tag = tags.aac_octagonal, .channels = &.{ .front_center, .front_left, .front_right, .side_left, .side_right, .back_left, .back_right, .back_center } },
    .{ .tag = tags.cube, .channels = &.{ .front_left, .front_right, .back_left, .back_right, .top_front_left, .top_front_right, .top_back_left, .top_back_right } },
    .{ .tag = tags.mpeg_7_1_a, .channels = &.{ .front_left, .front_right, .front_center, .low_frequency, .side_left, .side_right, .front_left_of_center, .front_right_of_center } },
    .{ .tag = tags.mpeg_7_1_b, .channels = &.{ .front_center, .front_left_of_center, .front_right_of_center, .front_left, .front_right, .side_left, .side_right, .low_frequency } },
    .{ .tag = tags.emagic_default_7_1, .channels = &.{ .front_left, .front_right, .side_left, .side_right, .front_center, .low_frequency, .front_left_of_center, .front_right_of_center } },
    .{ .tag = tags.eac3_7_1_b, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .front_left_of_center, .front_right_of_center } },
    .{ .tag = tags.dts_7_1, .channels = &.{ .front_left_of_center, .front_center, .front_right_of_center, .front_left, .front_right, .side_left, .side_right, .low_frequency } },
    .{ .tag = tags.mpeg_7_1_c, .channels = &.{ .front_left, .front_right, .front_center, .low_frequency, .side_left, .side_right, .back_left, .back_right } },
    .{ .tag = tags.eac3_7_1_a, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .back_left, .back_right } },
    .{ .tag = tags.smpte_dtv, .channels = &.{ .front_left, .front_right, .front_center, .low_frequency, .side_left, .side_right, .stereo_left, .stereo_right } },
    .{ .tag = tags.eac3_7_1_c, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .surround_direct_left, .surround_direct_right } },
    .{ .tag = tags.eac3_7_1_d, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .wide_left, .wide_right } },
    .{ .tag = tags.eac3_7_1_e, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .top_front_left, .top_front_right } },
    .{ .tag = tags.eac3_7_1_f, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .back_center, .top_center } },
    .{ .tag = tags.eac3_7_1_g, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .back_center, .top_front_center } },
    .{ .tag = tags.eac3_7_1_h, .channels = &.{ .front_left, .front_center, .front_right, .side_left, .side_right, .low_frequency, .top_center, .top_front_center } },
    .{ .tag = tags.dts_8_0_a, .channels = &.{ .front_left_of_center, .front_right_of_center, .front_left, .front_right, .side_left, .side_right, .back_left, .back_right } },
    .{ .tag = tags.dts_8_0_b, .channels = &.{ .front_left_of_center, .front_center, .front_right_of_center, .front_left, .front_right, .side_left, .back_center, .side_right } },
    .{ .tag = tags.dts_8_1_a, .channels = &.{ .front_left_of_center, .front_right_of_center, .front_left, .front_right, .side_left, .side_right, .back_left, .back_right, .low_frequency } },
    .{ .tag = tags.dts_8_1_b, .channels = &.{ .front_left_of_center, .front_center, .front_right_of_center, .front_left, .front_right, .side_left, .back_center, .side_right, .low_frequency } },
    .{ .tag = tags.tmh_10_2_std, .channels = &.{ .front_left, .front_right, .front_center, .top_front_center, .surround_direct_left, .surround_direct_right, .side_left, .side_right, .top_front_left, .top_front_right, .wide_left, .wide_right, .unknown, .back_center, .low_frequency, .low_frequency_2 } },
    .{ .tag = tags.tmh_10_2_full, .channels = &.{ .front_left, .front_right, .front_center, .top_front_center, .surround_direct_left, .surround_direct_right, .side_left, .side_right, .top_front_left, .top_front_right, .wide_left, .wide_right, .unknown, .back_center, .low_frequency, .low_frequency_2, .front_left_of_center, .front_right_of_center, .unknown, .unknown, .unknown } },
};

fn channelsOf(tag: u32) ?[]const Channel {
    for (tag_map) |entry| {
        if (entry.tag == tag) return entry.channels;
    }
    return null;
}

/// `mov_get_channel_id`: Core Audio's channel labels 1 to 18 are FFmpeg's
/// first 18 channels; 0 is unused.
fn channelFor(label: u32) Channel {
    return switch (label) {
        0 => .unused,
        1...18 => @fromBackingInt(@intCast(label - 1)),
        35 => .wide_left,
        36 => .wide_right,
        37 => .low_frequency_2,
        38 => .stereo_left,
        39 => .stereo_right,
        else => .unknown,
    };
}

/// Reads a `chan` body of `size` bytes, its whole declared size, and
/// returns the stream's layout after it, given the layout before it
/// (`current`; an unspecified layout of 0 channels when the count is not
/// known yet).
pub fn read(reader: *std.Io.Reader, size: u64, current: Layout) Error!Layout {
    if (size < header_len) return error.InvalidFormat;
    var fields: [header_len]u8 = undefined;
    reader.readSliceAll(&fields) catch |err| return mapRead(err);
    const tag = std.mem.readInt(u32, fields[0..4], .big);
    const bitmap = std.mem.readInt(u32, fields[4..8], .big);
    const described = std.mem.readInt(u32, fields[8..12], .big);
    // At most 2^32 descriptions of 20 bytes: no overflow in 64 bits.
    const described_wide: u64 = described;
    const described_bytes = described_wide * description_len;
    if (size - header_len < described_bytes) return error.InvalidFormat;

    const count = current.channelCount();
    var rest = size - header_len;
    var layout = current;
    if (tag == tags.use_descriptions) {
        // Fewer descriptions than channels, or a stream of no channels, is
        // an error to FFmpeg; more are capped at the channel count.
        if (described == 0 or described < count or count == 0) return error.InvalidFormat;
        if (count > channel_layout.max_custom_channels) return error.LimitExceeded;
        var channels: [channel_layout.max_custom_channels]Channel = undefined;
        for (channels[0..count]) |*channel| {
            var description: [description_len]u8 = undefined;
            reader.readSliceAll(&description) catch |err| return mapRead(err);
            channel.* = channelFor(std.mem.readInt(u32, description[0..4], .big));
        }
        const read_bytes: u64 = count * description_len;
        rest -= read_bytes;
        layout = canonical(channels[0..count]);
    } else if (tag == tags.use_bitmap) {
        if ((count == 0 or @popCount(bitmap) == count) and bitmap < max_bitmap) {
            // An empty bitmap leaves a stream of no channels, as FFmpeg's
            // failing `av_channel_layout_from_mask` does.
            layout = Layout.fromMask(bitmap) orelse .{ .unspecified = 0 };
        }
    } else if (tag & 0xFFFF != 0) {
        const tag_count = tag & 0xFFFF;
        if (count == 0) layout = .{ .unspecified = tag_count };
        if (tag_count == layout.channelCount()) {
            if (channelsOf(tag)) |channels| layout = canonical(channels);
        }
    }
    skip.discardAll(reader, rest) catch |err| return mapRead(err);
    return layout;
}

/// A channel list from the table or the descriptions, at most 64 channels
/// with no ambisonic order among them.
fn canonical(channels: []const Channel) Layout {
    return Layout.canonical(channels) catch |err| switch (err) {
        // The callers bound the count by max_custom_channels.
        error.LimitExceeded => unreachable,
        // No table entry or label gives the ambisonic components in order.
        error.UnsupportedLayout => unreachable,
    };
}

fn mapRead(err: std.Io.Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.Truncated,
        error.ReadFailed => error.IoFailure,
    };
}

fn maskOf(comptime channels: []const Channel) u64 {
    var mask: u64 = 0;
    const one: u64 = 1;
    for (channels) |channel| mask |= one << channel.id();
    return mask;
}

const stereo = maskOf(&.{ .front_left, .front_right });
const surround = stereo | maskOf(&.{.front_center});
const lfe = maskOf(&.{.low_frequency});
const @"2_1" = stereo | maskOf(&.{.back_center});
const @"2_2" = stereo | maskOf(&.{ .side_left, .side_right });
const quad = stereo | maskOf(&.{ .back_left, .back_right });
const @"4point0" = surround | maskOf(&.{.back_center});
const @"5point0" = surround | maskOf(&.{ .side_left, .side_right });
const @"5point0_back" = surround | maskOf(&.{ .back_left, .back_right });

/// `mov_channel_layout` in isom.c, in its order: the first entry with the
/// mask gives the tag.
const write_map = [_]struct { mask: u64, tag: u32 }{
    .{ .mask = maskOf(&.{.front_center}), .tag = tags.mono },
    .{ .mask = stereo, .tag = tags.stereo },
    .{ .mask = stereo, .tag = tags.stereoheadphones },
    .{ .mask = @"2_1", .tag = tags.itu_2_1 },
    .{ .mask = quad, .tag = tags.itu_2_2 },
    .{ .mask = @"2_2", .tag = tags.itu_2_2 },
    .{ .mask = quad, .tag = tags.quadraphonic },
    .{ .mask = surround, .tag = tags.mpeg_3_0_a },
    .{ .mask = @"4point0", .tag = tags.mpeg_4_0_a },
    .{ .mask = @"5point0_back", .tag = tags.mpeg_5_0_a },
    .{ .mask = @"5point0", .tag = tags.mpeg_5_0_a },
    .{ .mask = @"5point0_back" | lfe, .tag = tags.mpeg_5_1_a },
    .{ .mask = @"5point0" | lfe, .tag = tags.mpeg_5_1_a },
    .{ .mask = @"5point0" | lfe | maskOf(&.{ .back_left, .back_right }), .tag = tags.mpeg_7_1_c },
    .{ .mask = @"5point0" | lfe | maskOf(&.{ .front_left_of_center, .front_right_of_center }), .tag = tags.mpeg_7_1_a },
    .{ .mask = @"5point0_back" | lfe | maskOf(&.{ .stereo_left, .stereo_right }), .tag = tags.smpte_dtv },
    .{ .mask = stereo | lfe, .tag = tags.dvd_4 },
    .{ .mask = @"2_1" | lfe, .tag = tags.dvd_5 },
    .{ .mask = quad | lfe, .tag = tags.dvd_6 },
    .{ .mask = @"2_2" | lfe, .tag = tags.dvd_6 },
    .{ .mask = surround | lfe, .tag = tags.dvd_10 },
    .{ .mask = @"4point0" | lfe, .tag = tags.dvd_11 },
};

/// The body FFmpeg's `ff_mov_write_chan` writes for a native layout's mask:
/// its tag when the table names the mask, else the bitmap tag with the
/// mask's low 32 bits; no descriptions.
pub fn encode(mask: u64) [header_len]u8 {
    var body: [header_len]u8 = @splat(0);
    for (write_map) |entry| {
        if (entry.mask == mask) {
            std.mem.writeInt(u32, body[0..4], entry.tag, .big);
            return body;
        }
    }
    std.mem.writeInt(u32, body[0..4], tags.use_bitmap, .big);
    std.mem.writeInt(u32, body[4..8], @truncate(mask), .big);
    return body;
}

const vectors = @embedFile("../testing/vectors/chan.txt");
const vector_count = 2516;

fn field(fields: *std.mem.TokenIterator(u8, .scalar)) error{MalformedVector}![]const u8 {
    return fields.next() orelse error.MalformedVector;
}

fn hexBytes(text: []const u8, buffer: []u8) error{MalformedVector}![]const u8 {
    if (std.mem.eql(u8, text, "-")) return "";
    if (text.len % 2 != 0 or text.len / 2 > buffer.len) return error.MalformedVector;
    return std.fmt.hexToBytes(buffer[0 .. text.len / 2], text) catch error.MalformedVector;
}

fn checkRead(fields: *std.mem.TokenIterator(u8, .scalar)) !void {
    const before = try std.fmt.parseInt(u32, try field(fields), 10);
    const size = try std.fmt.parseInt(u64, try field(fields), 10);
    var buffer: [512]u8 = undefined;
    const body = try hexBytes(try field(fields), &buffer);
    var reader: std.Io.Reader = .fixed(body);
    const result = read(&reader, size, .{ .unspecified = before });
    const order = try field(fields);
    if (order[0] == 'E') {
        // FFmpeg reads zeros past the end of its input; this reports it.
        const expected: Error = if (body.len < size) error.Truncated else error.InvalidFormat;
        return std.testing.expectError(expected, result);
    }
    const channels = try std.fmt.parseInt(u32, try field(fields), 10);
    const mask = try std.fmt.parseInt(u64, try field(fields), 16);
    const map = try field(fields);
    const consumed = try std.fmt.parseInt(u64, try field(fields), 10);
    // FFmpeg stopped inside a body too short for its descriptions.
    if (consumed != size) return std.testing.expectError(error.InvalidFormat, result);
    const layout = try result;
    try std.testing.expectEqual(size, reader.seek);
    try std.testing.expectEqual(channels, layout.channelCount());
    switch (order[0]) {
        'U' => try std.testing.expect(layout == .unspecified),
        'N' => try std.testing.expectEqual(Layout{ .native = mask }, layout),
        'C' => try std.testing.expect(layout == .custom),
        else => return error.MalformedVector,
    }
    if (order[0] == 'U') return;
    var ids = std.mem.tokenizeScalar(u8, map, ',');
    var index: u32 = 0;
    while (ids.next()) |id| : (index += 1) {
        try std.testing.expectEqual(try std.fmt.parseInt(i32, id, 10), layout.channel(index).id());
    }
    try std.testing.expectEqual(channels, index);
}

fn checkWrite(fields: *std.mem.TokenIterator(u8, .scalar)) !void {
    const mask = try std.fmt.parseInt(u64, try field(fields), 16);
    var buffer: [header_len]u8 = undefined;
    const expected = try hexBytes(try field(fields), &buffer);
    try std.testing.expectEqualSlices(u8, expected, &encode(mask));
}

test "reading and writing equal FFmpeg's on every vector" {
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = try field(&fields);
        switch (kind[0]) {
            'R' => try checkRead(&fields),
            'W' => try checkWrite(&fields),
            else => return error.MalformedVector,
        }
    }
    try std.testing.expectEqual(vector_count, count);
}

test "every table entry has as many channels as its tag says" {
    for (tag_map) |entry| try std.testing.expectEqual(entry.tag & 0xFFFF, entry.channels.len);
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, read(&reader, header_len, .{ .unspecified = 2 }));
}

test "fragmented input gives the same layout" {
    // Two descriptions: front right (label 2), then front left (label 1).
    var body: [header_len + 2 * description_len]u8 = @splat(0);
    std.mem.writeInt(u32, body[8..12], 2, .big);
    std.mem.writeInt(u32, body[12..16], 2, .big);
    std.mem.writeInt(u32, body[32..36], 1, .big);
    var buffer: [1]u8 = undefined;
    var one: std.testing.Reader = .init(&buffer, &.{.{ .buffer = &body }});
    one.artificial_limit = .limited(1);
    const layout = try read(&one.interface, body.len, .{ .unspecified = 2 });
    try std.testing.expectEqual(2, layout.channelCount());
    try std.testing.expectEqual(Channel.front_right, layout.channel(0));
    try std.testing.expectEqual(Channel.front_left, layout.channel(1));
}
