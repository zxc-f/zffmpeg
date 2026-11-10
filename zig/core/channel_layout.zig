// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source. The
// channel ids, names, descriptions and the named layouts' masks follow
// libavutil/channel_layout.h and channel_layout.c at the pinned reference
// revision, and parsing follows av_channel_layout_from_string with the
// av_opt_get_key_value and av_get_token tokenizers it uses.
//! Audio channel layouts (TODO.md T23b): FFmpeg's channel ids, native
//! (bit mask), custom (ordered channel list, optionally named) and
//! unspecified (a count only) layouts, the 42 named layouts, and
//! `av_channel_layout_describe`, `from_string`, `default` and `compare`,
//! equal to FFmpeg's on zig/testing/vectors/layout.txt.
//!
//! Ambisonic layouts and channels are out of scope (T23b): parsing one is
//! `UnsupportedLayout`. A custom layout holds at most `max_custom_channels`
//! channels (`LimitExceeded` beyond, where FFmpeg allocates), each with a
//! name of at most 15 bytes, as FFmpeg's fixed field truncates it. Layouts
//! are values: nothing allocates.
//!
//! Number parsing follows the C library on Linux x86-64, the reference
//! platform, where `long` has 64 bits: a channel count or `USR` id past 32
//! bits is truncated as C converts it to `int`.

const std = @import("std");

/// FFmpeg's `AVChannel`: a speaker position. Ids without a name are user
/// channels (`USR<id>`).
pub const Channel = enum(i32) {
    front_left = 0,
    front_right,
    front_center,
    low_frequency,
    back_left,
    back_right,
    front_left_of_center,
    front_right_of_center,
    back_center,
    side_left,
    side_right,
    top_center,
    top_front_left,
    top_front_center,
    top_front_right,
    top_back_left,
    top_back_center,
    top_back_right,
    stereo_left = 29,
    stereo_right,
    wide_left,
    wide_right,
    surround_direct_left,
    surround_direct_right,
    low_frequency_2,
    top_side_left,
    top_side_right,
    bottom_front_center,
    bottom_front_left,
    bottom_front_right,
    side_surround_left,
    side_surround_right,
    top_surround_left,
    top_surround_right,
    binaural_left = 61,
    binaural_right,
    /// Not a channel: FFmpeg's "invalid" result.
    none = -1,
    /// A channel that is empty or skipped.
    unused = 0x200,
    /// A channel of unknown position.
    unknown = 0x300,
    _,

    const ambisonic_base = 0x400;
    const ambisonic_end = 0x7ff;

    pub const ParseError = error{
        /// Not a channel FFmpeg names (`AV_CHAN_NONE`).
        InvalidChannel,
        /// An ambisonic component (`AMBI<n>`), out of scope.
        UnsupportedChannel,
    };

    pub fn id(c: Channel) i32 {
        return @backingInt(c);
    }

    fn isAmbisonic(c: Channel) bool {
        return c.id() >= ambisonic_base and c.id() <= ambisonic_end;
    }

    fn entry(c: Channel) ?Name {
        const index = std.math.cast(usize, c.id()) orelse return null;
        if (index >= names.len) return null;
        return names[index];
    }

    /// FFmpeg's short name (`av_channel_name`): `FL`, `USR18`, `UNK`, ...
    pub fn writeName(c: Channel, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (c.isAmbisonic()) return w.print("AMBI{d}", .{c.id() - ambisonic_base});
        if (c.entry()) |e| return w.writeAll(e.short);
        switch (c) {
            .none => try w.writeAll("NONE"),
            .unknown => try w.writeAll("UNK"),
            .unused => try w.writeAll("UNSD"),
            else => try w.print("USR{d}", .{c.id()}),
        }
    }

    /// FFmpeg's description (`av_channel_description`): `front left`, ...
    pub fn writeDescription(c: Channel, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (c.isAmbisonic()) return w.print("ambisonic ACN {d}", .{c.id() - ambisonic_base});
        if (c.entry()) |e| return w.writeAll(e.description);
        switch (c) {
            .none => try w.writeAll("none"),
            .unknown => try w.writeAll("unknown"),
            .unused => try w.writeAll("unused"),
            else => try w.print("user {d}", .{c.id()}),
        }
    }

    /// The channel `text` names, as `av_channel_from_string` reads it: a
    /// short name, `UNK`, `UNSD`, or `USR` and a C integer (`strtol` base 0,
    /// so `USR0x10` and `USR010`, and `USR` alone is 0) of at least 0.
    pub fn parse(text: []const u8) ParseError!Channel {
        if (std.mem.startsWith(u8, text, "AMBI")) {
            // FFmpeg reads the number without checking where it ends.
            const n = strtol(text[4..], 0).value;
            if (n < 0 or n > ambisonic_end - ambisonic_base) return error.InvalidChannel;
            return error.UnsupportedChannel;
        }
        for (names, 0..) |maybe, i| {
            const e = maybe orelse continue;
            if (std.mem.eql(u8, text, e.short)) return @fromBackingInt(@intCast(i));
        }
        if (std.mem.eql(u8, text, "UNK")) return .unknown;
        if (std.mem.eql(u8, text, "UNSD")) return .unused;
        if (!std.mem.startsWith(u8, text, "USR")) return error.InvalidChannel;
        const number = strtol(text[3..], 0);
        if (number.end != text.len - 3) return error.InvalidChannel;
        // Converted to int as C converts a long.
        const value: i32 = @truncate(number.value);
        if (value < 0) return error.InvalidChannel;
        const channel: Channel = @fromBackingInt(value);
        if (channel.isAmbisonic()) return error.UnsupportedChannel;
        return channel;
    }
};

const Name = struct { short: []const u8, description: []const u8 };

/// `channel_names`, indexed by channel id.
const names = table: {
    var t: [63]?Name = @splat(null);
    const entries = .{
        .{ Channel.front_left, "FL", "front left" },
        .{ Channel.front_right, "FR", "front right" },
        .{ Channel.front_center, "FC", "front center" },
        .{ Channel.low_frequency, "LFE", "low frequency" },
        .{ Channel.back_left, "BL", "back left" },
        .{ Channel.back_right, "BR", "back right" },
        .{ Channel.front_left_of_center, "FLC", "front left-of-center" },
        .{ Channel.front_right_of_center, "FRC", "front right-of-center" },
        .{ Channel.back_center, "BC", "back center" },
        .{ Channel.side_left, "SL", "side left" },
        .{ Channel.side_right, "SR", "side right" },
        .{ Channel.top_center, "TC", "top center" },
        .{ Channel.top_front_left, "TFL", "top front left" },
        .{ Channel.top_front_center, "TFC", "top front center" },
        .{ Channel.top_front_right, "TFR", "top front right" },
        .{ Channel.top_back_left, "TBL", "top back left" },
        .{ Channel.top_back_center, "TBC", "top back center" },
        .{ Channel.top_back_right, "TBR", "top back right" },
        .{ Channel.stereo_left, "DL", "downmix left" },
        .{ Channel.stereo_right, "DR", "downmix right" },
        .{ Channel.wide_left, "WL", "wide left" },
        .{ Channel.wide_right, "WR", "wide right" },
        .{ Channel.surround_direct_left, "SDL", "surround direct left" },
        .{ Channel.surround_direct_right, "SDR", "surround direct right" },
        .{ Channel.low_frequency_2, "LFE2", "low frequency 2" },
        .{ Channel.top_side_left, "TSL", "top side left" },
        .{ Channel.top_side_right, "TSR", "top side right" },
        .{ Channel.bottom_front_center, "BFC", "bottom front center" },
        .{ Channel.bottom_front_left, "BFL", "bottom front left" },
        .{ Channel.bottom_front_right, "BFR", "bottom front right" },
        .{ Channel.side_surround_left, "SSL", "side surround left" },
        .{ Channel.side_surround_right, "SSR", "side surround right" },
        .{ Channel.top_surround_left, "TTL", "top surround left" },
        .{ Channel.top_surround_right, "TTR", "top surround right" },
        .{ Channel.binaural_left, "BIL", "binaural left" },
        .{ Channel.binaural_right, "BIR", "binaural right" },
    };
    for (entries) |e| t[@backingInt(e[0])] = .{ .short = e[1], .description = e[2] };
    break :table t;
};

fn bit(c: Channel) u64 {
    const one: u64 = 1;
    return one << @intCast(c.id());
}

fn bits(channels: []const Channel) u64 {
    var mask: u64 = 0;
    for (channels) |c| mask |= bit(c);
    return mask;
}

/// One of FFmpeg's named layouts (`channel_layout_map`).
pub const NamedLayout = struct {
    name: []const u8,
    mask: u64,
};

/// FFmpeg's named layouts, in its order: a description takes the first name
/// whose mask matches, and `default` the first with the channel count.
pub const named_layouts = table: {
    const FL = Channel.front_left;
    const FR = Channel.front_right;
    const FC = Channel.front_center;
    const LFE = Channel.low_frequency;
    const BL = Channel.back_left;
    const BR = Channel.back_right;
    const FLC = Channel.front_left_of_center;
    const FRC = Channel.front_right_of_center;
    const BC = Channel.back_center;
    const SL = Channel.side_left;
    const SR = Channel.side_right;
    const TC = Channel.top_center;
    const TFL = Channel.top_front_left;
    const TFC = Channel.top_front_center;
    const TFR = Channel.top_front_right;
    const TBL = Channel.top_back_left;
    const TBC = Channel.top_back_center;
    const TBR = Channel.top_back_right;
    const stereo = bits(&.{ FL, FR });
    const surround = stereo | bit(FC);
    const @"2_2" = stereo | bits(&.{ SL, SR });
    const quad = stereo | bits(&.{ BL, BR });
    const @"3point1" = surround | bit(LFE);
    const @"4point0" = surround | bit(BC);
    const @"5point0" = surround | bits(&.{ SL, SR });
    const @"5point1" = @"5point0" | bit(LFE);
    const @"5point0_back" = surround | bits(&.{ BL, BR });
    const @"5point1_back" = @"5point0_back" | bit(LFE);
    const @"6point0_front" = @"2_2" | bits(&.{ FLC, FRC });
    const @"7point1" = @"5point1" | bits(&.{ BL, BR });
    const @"5point1point2" = @"5point1" | bits(&.{ TFL, TFR });
    const @"5point1point4" = @"5point1point2" | bits(&.{ TBL, TBR });
    const @"7point1point2" = @"7point1" | bits(&.{ TFL, TFR });
    const @"7point1point4" = @"7point1point2" | bits(&.{ TBL, TBR });
    const @"9point1point4" = @"7point1point4" | bits(&.{ FLC, FRC });
    const @"9point1point6" = @"9point1point4" | bits(&.{ Channel.top_side_left, Channel.top_side_right });
    const octagonal = @"5point0" | bits(&.{ BL, BC, BR });
    break :table [_]NamedLayout{
        .{ .name = "mono", .mask = bit(FC) },
        .{ .name = "stereo", .mask = stereo },
        .{ .name = "2.1", .mask = stereo | bit(LFE) },
        .{ .name = "3.0", .mask = surround },
        .{ .name = "3.0(back)", .mask = stereo | bit(BC) },
        .{ .name = "4.0", .mask = @"4point0" },
        .{ .name = "quad", .mask = quad },
        .{ .name = "quad(side)", .mask = @"2_2" },
        .{ .name = "3.1", .mask = @"3point1" },
        .{ .name = "5.0", .mask = @"5point0_back" },
        .{ .name = "5.0(side)", .mask = @"5point0" },
        .{ .name = "4.1", .mask = @"4point0" | bit(LFE) },
        .{ .name = "5.1", .mask = @"5point1_back" },
        .{ .name = "5.1(side)", .mask = @"5point1" },
        .{ .name = "6.0", .mask = @"5point0" | bit(BC) },
        .{ .name = "6.0(front)", .mask = @"6point0_front" },
        .{ .name = "3.1.2", .mask = @"3point1" | bits(&.{ TFL, TFR }) },
        .{ .name = "hexagonal", .mask = @"5point0_back" | bit(BC) },
        .{ .name = "6.1", .mask = @"5point1" | bit(BC) },
        .{ .name = "6.1(back)", .mask = @"5point1_back" | bit(BC) },
        .{ .name = "6.1(front)", .mask = @"6point0_front" | bit(LFE) },
        .{ .name = "7.0", .mask = @"5point0" | bits(&.{ BL, BR }) },
        .{ .name = "7.0(front)", .mask = @"5point0" | bits(&.{ FLC, FRC }) },
        .{ .name = "7.1", .mask = @"7point1" },
        .{ .name = "7.1(wide)", .mask = @"5point1_back" | bits(&.{ FLC, FRC }) },
        .{ .name = "7.1(wide-side)", .mask = @"5point1" | bits(&.{ FLC, FRC }) },
        .{ .name = "5.1.2", .mask = @"5point1point2" },
        .{ .name = "5.1.2(back)", .mask = @"5point1_back" | bits(&.{ TFL, TFR }) },
        .{ .name = "octagonal", .mask = octagonal },
        .{ .name = "cube", .mask = quad | bits(&.{ TFL, TFR, TBL, TBR }) },
        .{ .name = "5.1.4", .mask = @"5point1point4" },
        .{ .name = "5.1.6", .mask = @"5point1point4" | bits(&.{ TFC, TC }) },
        .{ .name = "7.1.2", .mask = @"7point1point2" },
        .{ .name = "7.1.4", .mask = @"7point1point4" },
        .{ .name = "7.1.6", .mask = @"7point1point4" | bits(&.{ TFC, TC }) },
        .{ .name = "7.2.3", .mask = @"7point1point2" | bits(&.{ TBC, Channel.low_frequency_2 }) },
        .{ .name = "9.1.4", .mask = @"9point1point4" },
        .{ .name = "9.1.6", .mask = @"9point1point6" },
        .{ .name = "hexadecagonal", .mask = octagonal | bits(&.{ Channel.wide_left, Channel.wide_right, TBL, TBR, TBC, TFC, TFL, TFR }) },
        .{ .name = "binaural", .mask = bits(&.{ Channel.binaural_left, Channel.binaural_right }) },
        .{ .name = "downmix", .mask = bits(&.{ Channel.stereo_left, Channel.stereo_right }) },
        .{ .name = "22.2", .mask = @"9point1point6" | bits(&.{ BC, Channel.low_frequency_2, TFC, TC, TBC, Channel.bottom_front_center, Channel.bottom_front_left, Channel.bottom_front_right }) },
    };
};

/// The most channels a custom layout holds here; FFmpeg has no limit.
pub const max_custom_channels = 64;
/// The longest channel name, FFmpeg's `name[16]` without its terminator.
pub const max_name_len = 15;

/// One channel of a custom layout, with an optional name.
pub const CustomChannel = struct {
    channel: Channel,
    name_len: u8 = 0,
    name_bytes: [max_name_len]u8 = @splat(0),

    /// `label` truncated to `max_name_len` bytes, as FFmpeg stores it.
    pub fn init(channel: Channel, label: []const u8) CustomChannel {
        var c: CustomChannel = .{ .channel = channel };
        const kept = label[0..@min(label.len, max_name_len)];
        @memcpy(c.name_bytes[0..kept.len], kept);
        c.name_len = @intCast(kept.len);
        return c;
    }

    pub fn name(c: *const CustomChannel) []const u8 {
        return c.name_bytes[0..c.name_len];
    }
};

/// A custom layout's channels, in order.
pub const Custom = struct {
    count: u32,
    channels: [max_custom_channels]CustomChannel = @splat(.{ .channel = .none }),

    pub fn slice(c: *const Custom) []const CustomChannel {
        return c.channels[0..c.count];
    }

    fn hasNames(c: *const Custom) bool {
        for (c.slice()) |ch| if (ch.name_len != 0) return true;
        return false;
    }

    /// `masked_description`: the mask of channels below 63 in strictly
    /// rising order, or null.
    fn mask(c: *const Custom) ?u64 {
        var m: u64 = 0;
        for (c.slice()) |ch| {
            const n = ch.channel.id();
            if (n < 0 or n >= 63) return null;
            if (m >= bit(ch.channel)) return null;
            m |= bit(ch.channel);
        }
        return m;
    }
};

/// FFmpeg's `AVChannelLayout` without the ambisonic order.
pub const Layout = union(enum) {
    /// Only a channel count (`AV_CHANNEL_ORDER_UNSPEC`).
    unspecified: u32,
    /// The channels whose bits are set, in bit order
    /// (`AV_CHANNEL_ORDER_NATIVE`); never 0.
    native: u64,
    /// Channels in any order, possibly named (`AV_CHANNEL_ORDER_CUSTOM`).
    custom: Custom,

    pub const ParseError = error{
        /// FFmpeg rejects the text too (`EINVAL`).
        InvalidLayout,
        /// An ambisonic layout or channel, out of scope.
        UnsupportedLayout,
        /// A custom layout of more than `max_custom_channels` channels.
        LimitExceeded,
    };

    pub const mono: Layout = .{ .native = bit(.front_center) };
    pub const stereo: Layout = .{ .native = bits(&.{ .front_left, .front_right }) };

    /// `av_channel_layout_from_mask`; null for an empty mask.
    pub fn fromMask(mask: u64) ?Layout {
        if (mask == 0) return null;
        return .{ .native = mask };
    }

    /// A custom layout of `channels` as given, not canonicalized: what a
    /// demuxer builds from a channel list.
    pub fn fromChannels(channels: []const Channel) error{LimitExceeded}!Layout {
        if (channels.len > max_custom_channels) return error.LimitExceeded;
        var custom: Custom = .{ .count = channels.len };
        for (channels, 0..) |c, i| custom.channels[i] = .{ .channel = c };
        return .{ .custom = custom };
    }

    /// An unnamed channel list in FFmpeg's canonical order
    /// (`av_channel_layout_retype` with `AV_CHANNEL_LAYOUT_RETYPE_FLAG_CANONICAL`
    /// on a custom layout): unspecified when every channel is `unknown`,
    /// native when the channels rise below 63, else custom. What a demuxer
    /// that builds a channel list reports, as `ff_mov_read_chan` does. A
    /// list in ambisonic order, which FFmpeg makes an ambisonic layout, is
    /// `UnsupportedLayout`.
    pub fn canonical(channels: []const Channel) error{ LimitExceeded, UnsupportedLayout }!Layout {
        var list: List = .{};
        for (channels) |c| list.add(c, "");
        list.ambisonic = ambisonicOrder(channels);
        return list.finish() catch |err| switch (err) {
            error.LimitExceeded => error.LimitExceeded,
            error.UnsupportedLayout => error.UnsupportedLayout,
            // finish never reports InvalidLayout.
            error.InvalidLayout => unreachable,
        };
    }

    /// `av_channel_layout_default`: the first named layout with `count`
    /// channels, else `count` unspecified channels.
    pub fn default(count: u32) Layout {
        for (named_layouts) |n| {
            if (@popCount(n.mask) == count) return .{ .native = n.mask };
        }
        return .{ .unspecified = count };
    }

    pub fn channelCount(l: *const Layout) u32 {
        return switch (l.*) {
            .unspecified => |count| count,
            .native => |mask| @popCount(mask),
            .custom => |*custom| custom.count,
        };
    }

    /// The channel at `index` (`av_channel_layout_channel_from_index`):
    /// `none` past the end or in an unspecified layout.
    pub fn channel(l: *const Layout, index: u32) Channel {
        switch (l.*) {
            .unspecified => return .none,
            .native => |mask| {
                var left = index;
                var rest = mask;
                while (rest != 0) : (rest &= rest - 1) {
                    if (left == 0) return @fromBackingInt(@ctz(rest));
                    left -= 1;
                }
                return .none;
            },
            .custom => |*custom| return if (index < custom.count) custom.channels[index].channel else .none,
        }
    }

    /// Whether `a` and `b` are the same layout (`av_channel_layout_compare`
    /// returns 0): the same count, both unspecified, or the same channels
    /// in the same order. Names are not compared.
    pub fn eql(a: *const Layout, b: *const Layout) bool {
        const count = a.channelCount();
        if (count != b.channelCount()) return false;
        const a_unspecified = a.* == .unspecified;
        if (a_unspecified != (b.* == .unspecified)) return false;
        if (a_unspecified) return true;
        if (a.* == .native and b.* == .native) return a.native == b.native;
        for (0..count) |i| {
            if (a.channel(@intCast(i)) != b.channel(@intCast(i))) return false;
        }
        return true;
    }

    /// FFmpeg's description (`av_channel_layout_describe`): a named
    /// layout's name, else `N channels (FL+FR+...)` with `@name` after a
    /// named custom channel, or `N channels` when unspecified.
    pub fn describe(l: *const Layout, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (l.*) {
            .unspecified => |count| return w.print("{d} channels", .{count}),
            .native => |mask| {
                for (named_layouts) |n| {
                    if (n.mask == mask) return w.writeAll(n.name);
                }
            },
            .custom => |*custom| {
                if (!custom.hasNames()) {
                    if (custom.mask()) |mask| {
                        if (mask != 0) {
                            const native: Layout = .{ .native = mask };
                            return native.describe(w);
                        }
                    }
                }
            },
        }
        const count = l.channelCount();
        if (count == 0) return w.writeAll("0 channels");
        try w.print("{d} channels (", .{count});
        for (0..count) |i| {
            if (i != 0) try w.writeByte('+');
            try l.channel(@intCast(i)).writeName(w);
            switch (l.*) {
                .custom => |*custom| {
                    const name = custom.channels[i].name();
                    if (name.len != 0) try w.print("@{s}", .{name});
                },
                .unspecified, .native => {},
            }
        }
        try w.writeByte(')');
    }

    /// `av_channel_layout_from_string`: a named layout; `N channels
    /// (list)` or a list of channels joined by `+`, each `NAME` or
    /// `NAME@label` (canonicalized: native when the channels rise, as a
    /// mask; unspecified when all are `UNK`); a C integer mask (`3`, `0x3`,
    /// `03`); `Nc`, the default layout for N channels when it is native; or
    /// `NC` or `N channels`, N unspecified channels. Text after a NUL byte
    /// is ignored, as C stops there.
    pub fn parse(full_text: []const u8) ParseError!Layout {
        const text = std.mem.sliceTo(full_text, 0);
        for (named_layouts) |n| {
            if (std.mem.eql(u8, text, n.name)) return .{ .native = n.mask };
        }
        if (std.mem.startsWith(u8, text, "ambisonic ")) return error.UnsupportedLayout;

        // `%d channels (%[^)]`: the list inside, when all of it matches.
        const scanned = scanChannels(text);
        const list_text = if (scanned) |s| s.list else text;
        if (parseList(list_text)) |parsed| {
            var list = parsed;
            if (scanned) |s| {
                const close = std.mem.findScalar(u8, text, ')') orelse return error.InvalidLayout;
                if (s.count != list.count or close + 1 != text.len) return error.InvalidLayout;
            }
            return list.finish();
        } else |err| switch (err) {
            // Not a channel list: try the other forms.
            error.InvalidLayout => {},
        }

        // A mask: an unsigned C integer, any base, no minus sign.
        const mask = strtoull(text);
        if (!mask.overflow and mask.end == text.len and std.mem.findScalar(u8, text, '-') == null and mask.value != 0) {
            return .{ .native = mask.value };
        }

        // A channel count: `Nc`, or `NC` and `N channels`.
        const number = strtol(text, 10);
        if (number.overflow) return error.InvalidLayout;
        const count: i32 = @truncate(number.value);
        if (count <= 0) return error.InvalidLayout;
        const end = text[number.end..];
        if (std.mem.eql(u8, end, "c")) {
            const layout = default(@intCast(count));
            if (layout == .native) return layout;
            return error.InvalidLayout;
        }
        if (std.mem.eql(u8, end, "C") or std.mem.eql(u8, end, " channels")) {
            return .{ .unspecified = @intCast(count) };
        }
        return error.InvalidLayout;
    }
};

/// A channel list being parsed: everything `canonical_order` needs, and the
/// channels a custom result keeps.
const List = struct {
    count: u32 = 0,
    custom: Custom = .{ .count = 0 },
    /// A channel past `max_custom_channels` was dropped.
    overflow: bool = false,
    names: bool = false,
    known: bool = false,
    ambisonic: bool = false,
    /// The channels so far rise below 63: their mask.
    mask: ?u64 = 0,

    fn add(list: *List, channel: Channel, name: []const u8) void {
        if (list.count < max_custom_channels) {
            list.custom.channels[list.count] = .init(channel, name);
        } else {
            list.overflow = true;
        }
        list.count += 1;
        if (name.len != 0) list.names = true;
        if (channel != .unknown) list.known = true;
        if (list.mask) |m| {
            const n = channel.id();
            list.mask = if (n >= 0 and n < 63 and m < bit(channel)) m | bit(channel) else null;
        }
    }

    /// `av_channel_layout_retype` to the canonical order.
    fn finish(list: *List) Layout.ParseError!Layout {
        if (list.ambisonic) return error.UnsupportedLayout;
        if (!list.names) {
            if (!list.known) return .{ .unspecified = list.count };
            if (list.mask) |m| return .{ .native = m };
        }
        if (list.overflow) return error.LimitExceeded;
        list.custom.count = list.count;
        return .{ .custom = list.custom };
    }
};

/// Whether an unnamed channel list is an ambisonic layout to FFmpeg's
/// `canonical_order`: `av_channel_layout_ambisonic_order` finds a complete
/// order (the components first, each at its own index, `(n + 1)²` of them),
/// and the channels after them rise below 63.
fn ambisonicOrder(channels: []const Channel) bool {
    var highest: ?usize = null;
    for (channels, 0..) |c, i| {
        const ambisonic = c.isAmbisonic();
        if (i > 0 and ambisonic and !channels[i - 1].isAmbisonic()) return false;
        if (ambisonic and c.id() - Channel.ambisonic_base != i) return false;
        if (ambisonic) highest = i;
    }
    const last = highest orelse return false;
    const order: usize = std.math.sqrt(last);
    const components = (order + 1) * (order + 1);
    if (components != last + 1) return false;
    var mask: u64 = 0;
    for (channels[components..]) |c| {
        const n = c.id();
        if (n < 0 or n >= 63 or mask >= bit(c)) return false;
        mask |= bit(c);
    }
    return true;
}

/// `parse_channel_list`: channels joined by `+`, each a key and `@` and a
/// label, or a token alone (`av_opt_get_key_value` with an implicit key).
fn parseList(text: []const u8) error{InvalidLayout}!List {
    var list: List = .{};
    var pos: usize = 0;
    while (pos < text.len) {
        const key = getKey(text, pos);
        if (key) |k| pos = k.next;
        var value_buffer: [max_token_len]u8 = undefined;
        const value = getToken(text, &pos, &value_buffer);
        if (pos < text.len) pos += 1; // the `+`
        const channel_text = if (key) |k| k.text else channel: {
            // No channel's text is this long (a limit FFmpeg lacks: it
            // would read `USR` with that many leading zeros).
            if (value.len > max_token_len) return error.InvalidLayout;
            break :channel value.kept;
        };
        // A label keeps its first `max_name_len` bytes.
        const name = if (key != null) value.kept[0..@min(value.kept.len, max_name_len)] else "";
        const channel = Channel.parse(channel_text) catch |err| switch (err) {
            error.InvalidChannel => return error.InvalidLayout,
            error.UnsupportedChannel => unsupported: {
                list.ambisonic = true;
                break :unsupported Channel.unknown;
            },
        };
        list.add(channel, name);
    }
    if (list.count == 0) return error.InvalidLayout;
    return list;
}

/// `WHITESPACES` in opt.c and avstring.c.
fn isTokenSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == '\r';
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '/' or c == '.';
}

/// `get_key` with the delimiter `@`: key characters between spaces, then
/// the `@`; null when they are not followed by one.
fn getKey(text: []const u8, start: usize) ?struct { text: []const u8, next: usize } {
    var pos = start;
    while (pos < text.len and isTokenSpace(text[pos])) pos += 1;
    const key_start = pos;
    while (pos < text.len and isKeyChar(text[pos])) pos += 1;
    const key_end = pos;
    while (pos < text.len and isTokenSpace(text[pos])) pos += 1;
    if (pos == text.len or text[pos] != '@') return null;
    return .{ .text = text[key_start..key_end], .next = pos + 1 };
}

/// The most bytes of a token kept: more than any channel's text, so a
/// longer token names no channel, and more than a label keeps.
const max_token_len = 64;

const Token = struct {
    /// The token's first bytes, at most `max_token_len`.
    kept: []const u8,
    /// Its full length.
    len: usize,
};

/// `av_get_token` with the terminator `+`, from `pos.*` to the terminator
/// or the end, where it leaves `pos.*`: leading spaces skipped, `\` escapes
/// the next byte, `'...'` quotes, and trailing spaces dropped back to the
/// last escaped or quoted byte. The unescaped token's first bytes go into
/// `buffer`.
fn getToken(text: []const u8, pos: *usize, buffer: *[max_token_len]u8) Token {
    var p = pos.*;
    while (p < text.len and isTokenSpace(text[p])) p += 1;
    var len: usize = 0;
    // Bytes before `keep` were escaped or quoted, and `content` ends after
    // the last byte that is not a space: the trimmed length is the larger.
    var keep: usize = 0;
    var content: usize = 0;
    while (p < text.len and text[p] != '+') {
        const c = text[p];
        p += 1;
        if (c == '\\' and p < text.len) {
            put(buffer, &len, &content, text[p]);
            p += 1;
            keep = len;
        } else if (c == '\'') {
            while (p < text.len and text[p] != '\'') : (p += 1) put(buffer, &len, &content, text[p]);
            // An unterminated quote protects nothing.
            if (p < text.len) {
                p += 1;
                keep = len;
            }
        } else {
            put(buffer, &len, &content, c);
        }
    }
    pos.* = p;
    const trimmed = @max(keep, content);
    return .{ .kept = buffer[0..@min(trimmed, buffer.len)], .len = trimmed };
}

/// Appends `c` as byte `len.*` of a token, keeping only what fits, and
/// moves `content` past it unless it is a space.
fn put(buffer: *[max_token_len]u8, len: *usize, content: *usize, c: u8) void {
    if (len.* < buffer.len) buffer[len.*] = c;
    len.* += 1;
    if (!isTokenSpace(c)) content.* = len.*;
}

/// What `sscanf(text, "%d channels (%[^)]")` matched: the count, and the
/// list when all of it matched.
fn scanChannels(text: []const u8) ?struct { count: i32, list: []const u8 } {
    const number = strtol(text, 10);
    if (number.end == 0) return null;
    var pos = number.end;
    // A space in the format matches any run of white space, even none.
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    if (!std.mem.startsWith(u8, text[pos..], "channels")) return null;
    pos += "channels".len;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    if (pos == text.len or text[pos] != '(') return null;
    pos += 1;
    const list_end = std.mem.findScalarPos(u8, text, pos, ')') orelse text.len;
    if (list_end == pos) return null;
    return .{ .count = @truncate(number.value), .list = text[pos..list_end] };
}

pub const CNumber = struct {
    /// The value as the function returns it (saturated on overflow).
    value: i64,
    /// Bytes read; 0 when no digits were found.
    end: usize,
    /// `errno` would be `ERANGE`.
    overflow: bool,
};

/// The digits of a C integer from `pos` in `base` (0 detects it), into a
/// magnitude; null on overflow past u64.
fn cDigits(text: []const u8, start: usize, base_in: u8) struct { magnitude: ?u64, end: usize } {
    var pos = start;
    var base = base_in;
    if (base == 0) {
        // `0x` counts only when a hex digit follows it; otherwise the `0`
        // is an octal number that ends there.
        if (pos + 2 < text.len and text[pos] == '0' and (text[pos + 1] | 0x20) == 'x' and std.ascii.isHex(text[pos + 2])) {
            pos += 2;
            base = 16;
        } else {
            base = if (pos < text.len and text[pos] == '0') 8 else 10;
        }
    }
    var magnitude: ?u64 = 0;
    const digits_start = pos;
    while (pos < text.len) : (pos += 1) {
        const digit = std.fmt.charToDigit(text[pos], base) catch break;
        if (magnitude) |m| {
            const times: ?u64 = std.math.mul(u64, m, base) catch null;
            magnitude = if (times) |t| std.math.add(u64, t, digit) catch null else null;
        }
    }
    if (pos == digits_start) return .{ .magnitude = 0, .end = 0 };
    return .{ .magnitude = magnitude, .end = pos };
}

fn skipSign(text: []const u8, start: usize) struct { negative: bool, pos: usize } {
    var pos = start;
    while (pos < text.len and std.ascii.isWhitespace(text[pos])) pos += 1;
    var negative = false;
    if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) {
        negative = text[pos] == '-';
        pos += 1;
    }
    return .{ .negative = negative, .pos = pos };
}

/// `strtol` with a 64-bit `long`.
pub fn strtol(text: []const u8, base: u8) CNumber {
    const sign = skipSign(text, 0);
    const digits = cDigits(text, sign.pos, base);
    if (digits.end == 0) return .{ .value = 0, .end = 0, .overflow = false };
    const limit: u64 = if (sign.negative) 1 << 63 else std.math.maxInt(i64);
    const magnitude = digits.magnitude orelse limit + 1;
    if (magnitude > limit) {
        return .{ .value = if (sign.negative) std.math.minInt(i64) else std.math.maxInt(i64), .end = digits.end, .overflow = true };
    }
    // At most 2^63 when negative, which wraps to the most negative value.
    const bits_value: i64 = @bitCast(magnitude);
    return .{ .value = if (sign.negative) -%bits_value else bits_value, .end = digits.end, .overflow = false };
}

/// `strtoull` in base 0.
fn strtoull(text: []const u8) struct { value: u64, end: usize, overflow: bool } {
    const sign = skipSign(text, 0);
    const digits = cDigits(text, sign.pos, 0);
    if (digits.end == 0) return .{ .value = 0, .end = 0, .overflow = false };
    const magnitude = digits.magnitude orelse return .{ .value = std.math.maxInt(u64), .end = digits.end, .overflow = true };
    return .{ .value = if (sign.negative) 0 -% magnitude else magnitude, .end = digits.end, .overflow = false };
}

// zig/testing/vectors/layout.txt comes from the pinned FFmpeg's libavutil
// through zig/testing/reference/layout_vectors.c, which documents its
// lines. Every line is checked, and the count makes a truncated or missing
// file fail.
const vectors = @embedFile("../testing/vectors/layout.txt");
const vector_count = 662;

fn vectorField(fields: *std.mem.TokenIterator(u8, .scalar)) error{MalformedVector}![]const u8 {
    return fields.next() orelse error.MalformedVector;
}

/// A hex field's bytes ("-" is empty) in `buffer`.
fn unhex(field: []const u8, buffer: []u8) error{MalformedVector}![]const u8 {
    if (std.mem.eql(u8, field, "-")) return "";
    if (field.len % 2 != 0 or field.len / 2 > buffer.len) return error.MalformedVector;
    return std.fmt.hexToBytes(buffer[0 .. field.len / 2], field) catch error.MalformedVector;
}

/// The vectors' map field: channel ids joined by commas, each with an
/// optional `@<hex name>`.
fn expectMap(layout: *const Layout, field: []const u8) !void {
    if (std.mem.eql(u8, field, "-")) return std.testing.expect(layout.* == .unspecified);
    var items = std.mem.tokenizeScalar(u8, field, ',');
    var index: u32 = 0;
    while (items.next()) |item| : (index += 1) {
        const at = std.mem.findScalar(u8, item, '@');
        const id = try std.fmt.parseInt(i32, item[0 .. at orelse item.len], 10);
        try std.testing.expectEqual(id, layout.channel(index).id());
        var name_buffer: [64]u8 = undefined;
        const name = if (at) |a| try unhex(item[a + 1 ..], &name_buffer) else "";
        switch (layout.*) {
            .custom => |*custom| try std.testing.expectEqualStrings(name, custom.channels[index].name()),
            .native, .unspecified => try std.testing.expectEqual(0, name.len),
        }
    }
    try std.testing.expectEqual(layout.channelCount(), index);
}

fn expectDescription(layout: *const Layout, field: []const u8) !void {
    var expected_buffer: [4096]u8 = undefined;
    const expected = try unhex(field, &expected_buffer);
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try layout.describe(&w);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

fn checkVector(line: []const u8) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const kind = try vectorField(&fields);
    var text_buffer: [1024]u8 = undefined;
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    switch (kind[0]) {
        'C' => {
            const channel: Channel = @fromBackingInt(try std.fmt.parseInt(i32, try vectorField(&fields), 10));
            try channel.writeName(&w);
            try std.testing.expectEqualStrings(try unhex(try vectorField(&fields), &text_buffer), w.buffered());
            w.end = 0;
            try channel.writeDescription(&w);
            try std.testing.expectEqualStrings(try unhex(try vectorField(&fields), &text_buffer), w.buffered());
        },
        'S' => {
            const text = try unhex(try vectorField(&fields), &text_buffer);
            const id = try std.fmt.parseInt(i32, try vectorField(&fields), 10);
            if (id == -1) {
                try std.testing.expectError(error.InvalidChannel, Channel.parse(text));
            } else {
                try std.testing.expectEqual(id, (try Channel.parse(text)).id());
            }
        },
        'P' => {
            const text = try unhex(try vectorField(&fields), &text_buffer);
            const order = try vectorField(&fields);
            if (std.mem.eql(u8, order, "E")) return std.testing.expectError(error.InvalidLayout, Layout.parse(text));
            const count = try std.fmt.parseInt(u32, try vectorField(&fields), 10);
            // The port's recorded limit: FFmpeg allocates larger custom maps.
            if (order[0] == 'C' and count > max_custom_channels) {
                return std.testing.expectError(error.LimitExceeded, Layout.parse(text));
            }
            const layout = try Layout.parse(text);
            const expected_tag: std.meta.Tag(Layout) = switch (order[0]) {
                'U' => .unspecified,
                'N' => .native,
                'C' => .custom,
                else => return error.MalformedVector,
            };
            try std.testing.expectEqual(expected_tag, std.meta.activeTag(layout));
            try std.testing.expectEqual(count, layout.channelCount());
            const mask = try std.fmt.parseInt(u64, try vectorField(&fields), 16);
            if (layout == .native) try std.testing.expectEqual(mask, layout.native);
            try expectMap(&layout, try vectorField(&fields));
            try expectDescription(&layout, try vectorField(&fields));
        },
        'D' => {
            const order = try vectorField(&fields);
            const layout: Layout = switch (order[0]) {
                // FFmpeg refuses an empty mask, leaving the layout zeroed:
                // no channels, unspecified.
                'N' => Layout.fromMask(try std.fmt.parseInt(u64, try vectorField(&fields), 16)) orelse .{ .unspecified = 0 },
                'U' => .{ .unspecified = try std.fmt.parseInt(u32, try vectorField(&fields), 10) },
                'C' => custom: {
                    const count = try std.fmt.parseInt(u32, try vectorField(&fields), 10);
                    var custom: Custom = .{ .count = count };
                    var items = std.mem.tokenizeScalar(u8, try vectorField(&fields), ',');
                    for (custom.channels[0..count]) |*c| {
                        const item = items.next() orelse return error.MalformedVector;
                        const at = std.mem.findScalar(u8, item, '@');
                        const id = try std.fmt.parseInt(i32, item[0 .. at orelse item.len], 10);
                        var name_buffer: [64]u8 = undefined;
                        const name = if (at) |a| try unhex(item[a + 1 ..], &name_buffer) else "";
                        c.* = .init(@fromBackingInt(id), name);
                    }
                    break :custom .{ .custom = custom };
                },
                else => return error.MalformedVector,
            };
            try expectDescription(&layout, try vectorField(&fields));
        },
        'F' => {
            const layout: Layout = .default(try std.fmt.parseInt(u32, try vectorField(&fields), 10));
            try expectDescription(&layout, try vectorField(&fields));
        },
        'Q' => {
            const a = try Layout.parse(try unhex(try vectorField(&fields), &text_buffer));
            var other_buffer: [256]u8 = undefined;
            const b = try Layout.parse(try unhex(try vectorField(&fields), &other_buffer));
            const different = std.mem.eql(u8, try vectorField(&fields), "1");
            try std.testing.expectEqual(!different, a.eql(&b));
        },
        else => return error.MalformedVector,
    }
}

test "names, parsing, descriptions and defaults equal the pinned libavutil's" {
    var checked: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        checkVector(line) catch |err| {
            std.debug.print("vector: {s}\n", .{line});
            return err;
        };
        checked += 1;
    }
    try std.testing.expectEqual(vector_count, checked);
}

test "ambisonic layouts and channels are out of scope" {
    try std.testing.expectError(error.UnsupportedLayout, Layout.parse("ambisonic 1"));
    try std.testing.expectError(error.UnsupportedLayout, Layout.parse("AMBI0+AMBI1+AMBI2+AMBI3"));
    try std.testing.expectError(error.UnsupportedLayout, Layout.parse("FL+USR1024"));
    try std.testing.expectError(error.UnsupportedChannel, Channel.parse("AMBI3"));
    // FFmpeg rejects an ACN past 1023 and a list with a bad channel anyway.
    try std.testing.expectError(error.InvalidChannel, Channel.parse("AMBI1024"));
    try std.testing.expectError(error.InvalidLayout, Layout.parse("AMBI0+XX"));
    var buffer: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    const acn: Channel = @fromBackingInt(0x405);
    try acn.writeName(&w);
    try std.testing.expectEqualStrings("AMBI5", w.buffered());
}

test "tokens: escapes, quotes, labels and long texts" {
    // A label keeps 15 bytes; a quoted or escaped trailing space stays.
    const named = try Layout.parse("FL@'a  '+FR@b\\ ");
    try std.testing.expectEqualStrings("a  ", named.custom.channels[0].name());
    try std.testing.expectEqualStrings("b ", named.custom.channels[1].name());
    // An unterminated quote protects nothing.
    const open = try Layout.parse("FL@'ab  ");
    try std.testing.expectEqualStrings("ab", open.custom.channels[0].name());
    // A channel text longer than any channel's is rejected.
    const zeros: [70]u8 = @splat('0');
    try std.testing.expectError(error.InvalidLayout, Layout.parse("USR" ++ zeros ++ "5"));
    // Past the NUL byte nothing counts, as in C.
    try std.testing.expectEqual(Layout.stereo, try Layout.parse("stereo\x00junk"));
}
