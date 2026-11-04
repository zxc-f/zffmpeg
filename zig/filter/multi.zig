// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavfilter/split.c, af_channelsplit.c, af_channelmap.c, af_pan.c and
// af_amix.c, libavutil/float_dsp.c (vector_fmac_scalar_c,
// vector_dmac_scalar_c) and libswresample (swr_set_matrix,
// swr_set_channel_mapping) at the pinned reference revision describe the
// behavior, restated here.
//! The filters of several inputs or outputs and the channel filters of
//! the T25c graph: asplit, channelsplit, channelmap, pan and amix. Their
//! options are set as `av_opt_set` sets them; `init` checks them as the
//! filters' `init` does, with FFmpeg's messages; the run types hold their
//! state on configured links. Their activation is graph.zig's.

const std = @import("std");
const audio = @import("../core/audio.zig");
const channel_layout = @import("../core/channel_layout.zig");
const number = @import("../core/number.zig");
const options = @import("../core/options.zig");
const samples = @import("../core/samples.zig");
const time = @import("../core/time.zig");
const diagnostics = @import("../core/diagnostics.zig");
const audioconvert = @import("../resample/audioconvert.zig");
const rematrix = @import("../resample/rematrix.zig");
const filters = @import("filters.zig");
const Layout = channel_layout.Layout;
const Channel = channel_layout.Channel;
const SampleFormat = audio.SampleFormat;
const Owned = filters.Owned;
const CreateError = filters.CreateError;

fn report(sink: ?diagnostics.Sink, comptime format: []const u8, args: anytype) CreateError {
    diagnostics.report(sink, .err, format, args);
    return error.InvalidValue;
}

fn describe(buffer: []u8, l: *const Layout) []const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    l.describe(&w) catch {};
    return w.buffered();
}

fn channelName(buffer: []u8, c: Channel) []const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    c.writeName(&w) catch {};
    return w.buffered();
}

/// An owned copy of option text.
fn setText(gpa: std.mem.Allocator, slot: *?[]u8, text: []const u8) CreateError!void {
    const copy = try gpa.dupe(u8, text);
    if (slot.*) |old| gpa.free(old);
    slot.* = copy;
}

// asplit --------------------------------------------------------------------

pub const ASplit = struct {
    outputs: i32 = 2,

    pub const option_specs = [_]options.Spec{
        .{ .name = "outputs", .field = "outputs", .kind = .int, .help = "set number of outputs", .min = 1, .max = std.math.maxInt(i32) },
    };

    comptime {
        options.check(ASplit);
    }
};

// channelsplit --------------------------------------------------------------

pub const ChannelSplit = struct {
    /// `channel_layout`: the input's layout.
    layout: Layout = .stereo,
    /// `channels`, owned; null for "all".
    channels: ?[]u8 = null,
    /// The input channel of each output (`map`), from `init`.
    map: std.ArrayList(u32) = .empty,
    /// Each output's channel.
    output_channels: std.ArrayList(Channel) = .empty,

    pub fn set(c: *ChannelSplit, gpa: std.mem.Allocator, name: []const u8, text: []const u8) CreateError!void {
        if (std.mem.eql(u8, name, "channel_layout")) {
            c.layout = Layout.parse(text) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "channels")) {
            try setText(gpa, &c.channels, text);
        } else return error.UnknownOption;
    }

    pub fn init(c: *ChannelSplit, gpa: std.mem.Allocator, sink: ?diagnostics.Sink) CreateError!void {
        const all = c.channels == null or std.mem.eql(u8, c.channels.?, "all");
        const picked = if (all) c.layout else Layout.parse(c.channels.?) catch return error.InvalidValue;
        for (0..picked.channelCount()) |i| {
            const channel = picked.channel(@intCast(i));
            var index: u32 = @intCast(i);
            if (!all) {
                index = indexOf(&c.layout, channel) orelse {
                    var name: [64]u8 = undefined;
                    var layout_name: [128]u8 = undefined;
                    return report(sink, "Channel name '{s}' not present in channel layout '{s}'.", .{ channelName(&name, channel), describe(&layout_name, &c.layout) });
                };
            }
            try c.map.append(gpa, index);
            try c.output_channels.append(gpa, c.layout.channel(index));
        }
    }

    /// Output `i`'s layout: its one channel, canonical.
    pub fn outputLayout(c: *const ChannelSplit, i: usize) Layout {
        return Layout.canonical(&.{c.output_channels.items[i]}) catch .{ .unspecified = 1 };
    }

    pub fn deinit(c: *ChannelSplit, gpa: std.mem.Allocator) void {
        if (c.channels) |t| gpa.free(t);
        c.map.deinit(gpa);
        c.output_channels.deinit(gpa);
    }

    /// Output `i` of `in` (planar): the plane of its channel.
    pub fn output(c: *const ChannelSplit, gpa: std.mem.Allocator, in: *const Owned, i: usize, format: audio.Format) error{OutOfMemory}!Owned {
        const frames = in.frameCount();
        const out = try Owned.alloc(gpa, format, frames, in.pts);
        @memcpy(out.data, in.buffer().view().plane(c.map.items[i])[0..out.data.len]);
        return out;
    }
};

/// `av_channel_layout_index_from_channel`.
fn indexOf(l: *const Layout, c: Channel) ?u32 {
    for (0..l.channelCount()) |i| {
        if (l.channel(@intCast(i)) == c) return @intCast(i);
    }
    return null;
}

// channelmap ----------------------------------------------------------------

pub const ChannelMap = struct {
    /// `map`, owned; null when unset.
    mapping: ?[]u8 = null,
    /// `channel_layout`; the output layout once `init` has run.
    output_layout: ?Layout = null,
    mode: Mode = .none,
    entries: std.ArrayList(Entry) = .empty,

    const Mode = enum { none, one_int, one_str, pair_int_int, pair_int_str, pair_str_int, pair_str_str };

    const Entry = struct {
        in_channel: ?Channel = null,
        out_channel: ?Channel = null,
        in_index: ?u32 = null,
        out_index: ?u32 = null,
    };

    pub fn set(c: *ChannelMap, gpa: std.mem.Allocator, name: []const u8, text: []const u8) CreateError!void {
        if (std.mem.eql(u8, name, "map")) {
            try setText(gpa, &c.mapping, text);
        } else if (std.mem.eql(u8, name, "channel_layout")) {
            c.output_layout = Layout.parse(text) catch return error.InvalidValue;
        } else return error.UnknownOption;
    }

    pub fn deinit(c: *ChannelMap, gpa: std.mem.Allocator) void {
        if (c.mapping) |t| gpa.free(t);
        c.entries.deinit(gpa);
    }

    /// `get_channel_idx`: sscanf's `%d` of all of `text`, at least 0.
    fn channelIndex(text: []const u8) ?u32 {
        const n = channel_layout.strtol(text, 10);
        if (n.end == 0 or n.end != text.len) return null;
        const value: i32 = @truncate(n.value);
        return if (value < 0) null else @intCast(value);
    }

    /// `get_channel`: `av_channel_from_string`.
    fn channelNamed(text: []const u8) ?Channel {
        const c = Channel.parse(text) catch return null;
        return if (c.id() < 0) null else c;
    }

    /// The next field of `rest` up to `delim` (`split`); a pair's first
    /// field must end at a dash.
    fn field(rest: *?[]const u8, delim: u8) ?[]const u8 {
        const text = rest.* orelse return null;
        if (std.mem.findScalar(u8, text, delim)) |at| {
            rest.* = text[at + 1 ..];
            return text[0..at];
        }
        if (delim == '-') return null;
        rest.* = null;
        return text;
    }

    pub fn init(c: *ChannelMap, gpa: std.mem.Allocator, sink: ?diagnostics.Sink) CreateError!void {
        var mode: Mode = .none;
        var count: usize = 0;
        if (c.mapping) |m| {
            const first_digit = m.len > 0 and std.ascii.isDigit(m[0]);
            if (std.mem.findScalar(u8, m, '-')) |dash| {
                const after_digit = dash + 1 < m.len and std.ascii.isDigit(m[dash + 1]);
                mode = if (first_digit) (if (after_digit) .pair_int_int else .pair_int_str) else (if (after_digit) .pair_str_int else .pair_str_str);
            } else {
                mode = if (first_digit) .one_int else .one_str;
            }
            count = 1;
            var i: usize = 0;
            while (std.mem.findScalarPos(u8, m, i, '|')) |at| : (i = at + 1) {
                // A trailing separator adds no entry.
                if (at + 1 < m.len) count += 1;
            }
        }
        var out_mask: i64 = 0;
        var rest: ?[]const u8 = c.mapping;
        for (0..count) |i| {
            var e: Entry = .{};
            const fail = "Failed to parse channel map";
            switch (mode) {
                .none => unreachable,
                .one_int => {
                    e.in_index = channelIndex(field(&rest, '|') orelse return report(sink, fail, .{})) orelse return report(sink, fail, .{});
                    e.out_index = @intCast(i);
                },
                .one_str => {
                    e.in_channel = channelNamed(field(&rest, '|') orelse return report(sink, fail, .{})) orelse return report(sink, fail, .{});
                    e.out_index = @intCast(i);
                },
                .pair_int_int, .pair_int_str, .pair_str_int, .pair_str_str => {
                    const first = field(&rest, '-') orelse return report(sink, fail, .{});
                    const second = field(&rest, '|') orelse return report(sink, fail, .{});
                    if (mode == .pair_int_int or mode == .pair_int_str) {
                        e.in_index = channelIndex(first) orelse return report(sink, fail, .{});
                    } else {
                        e.in_channel = channelNamed(first) orelse return report(sink, fail, .{});
                    }
                    if (mode == .pair_int_int or mode == .pair_str_int) {
                        e.out_index = channelIndex(second) orelse return report(sink, fail, .{});
                    } else {
                        const out = channelNamed(second) orelse return report(sink, fail, .{});
                        e.out_channel = out;
                        if (out.id() < 63) out_mask |= @as(i64, 1) << @intCast(out.id()) else out_mask = -1;
                    }
                },
            }
            try c.entries.append(gpa, e);
        }
        c.mode = mode;
        if (c.output_layout == null) {
            if (out_mask > 0) {
                c.output_layout = Layout.fromMask(@bitCast(out_mask));
            } else if (count > 0) {
                c.output_layout = Layout.default(@intCast(count));
            }
        }
        var layout_name: [256]u8 = undefined;
        if (mode == .none) {
            const l = c.output_layout orelse return report(sink, "Output channel layout is not set and cannot be guessed from the maps.", .{});
            for (0..l.channelCount()) |i| try c.entries.append(gpa, .{ .in_index = @intCast(i), .out_index = @intCast(i), .out_channel = l.channel(@intCast(i)) });
        } else if (c.entries.items.len != c.output_layout.?.channelCount()) {
            return report(sink, "Output channel layout {s} does not match the number of channels mapped {d}.", .{ describe(&layout_name, &c.output_layout.?), c.entries.items.len });
        }
        const out = &c.output_layout.?;
        if (mode == .pair_int_str or mode == .pair_str_str) {
            for (c.entries.items) |*e| e.out_index = indexOf(out, e.out_channel.?);
        }
        const used = try gpa.alloc(bool, c.entries.items.len);
        defer gpa.free(used);
        @memset(used, false);
        for (c.entries.items, 0..) |e, i| {
            const index = e.out_index orelse {
                checkFailed(sink, "out", e.out_channel, null, out);
                return error.InvalidValue;
            };
            if (index >= out.channelCount()) {
                checkFailed(sink, "out", e.out_channel, index, out);
                return error.InvalidValue;
            }
            if (used[index]) return report(sink, "Mapping {d} assigns channel #{d} twice in output layout '{s}'.", .{ i + 1, index, describe(&layout_name, out) });
            used[index] = true;
        }
    }

    /// `check_idx_and_id`'s message.
    fn checkFailed(sink: ?diagnostics.Sink, io: []const u8, channel: ?Channel, index: ?u32, l: *const Layout) void {
        var layout_name: [256]u8 = undefined;
        if (channel) |ch| {
            var name: [64]u8 = undefined;
            diagnostics.report(sink, .err, "{s}put channel '{s}' not available from {s}put layout '{s}'", .{ io, channelName(&name, ch), io, describe(&layout_name, l) });
        } else {
            diagnostics.report(sink, .err, "{s}put channel #{d} not available from {s}put layout '{s}'", .{ io, index orelse 0, io, describe(&layout_name, l) });
        }
    }

    /// `channelmap_config_input`: the input channels by name, checked.
    pub fn configInput(c: *ChannelMap, in: *const Layout, sink: ?diagnostics.Sink) error{InvalidChannelMap}!void {
        var failed = false;
        for (c.entries.items) |*e| {
            if (c.mode == .pair_str_int or c.mode == .pair_str_str or c.mode == .one_str) e.in_index = indexOf(in, e.in_channel.?);
            const ok = if (e.in_index) |i| i < in.channelCount() else false;
            if (!ok) {
                checkFailed(sink, "in", e.in_channel, e.in_index, in);
                failed = true;
            }
        }
        if (failed) return error.InvalidChannelMap;
    }

    /// The output of `in` (planar): each output plane a copy of its input's.
    pub fn output(c: *const ChannelMap, gpa: std.mem.Allocator, in: *const Owned, format: audio.Format) error{OutOfMemory}!Owned {
        var out = try Owned.alloc(gpa, format, in.frameCount(), in.pts);
        const view = in.buffer().view();
        const buffer = out.buffer();
        for (c.entries.items) |e| {
            const dst = buffer.plane(e.out_index.?);
            @memcpy(dst, view.plane(e.in_index.?)[0..dst.len]);
        }
        return out;
    }
};

// pan -----------------------------------------------------------------------

pub const max_channels = 64;

pub const Pan = struct {
    /// `args`, owned.
    args: ?[]u8 = null,
    layout: Layout = .mono,
    output_count: u32 = 0,
    gain: *[max_channels][max_channels]f64 = undefined,
    gain_owned: bool = false,
    need_renorm: u64 = 0,
    need_renumber: bool = false,
    pure_gains: bool = false,

    pub fn set(p: *Pan, gpa: std.mem.Allocator, name: []const u8, text: []const u8) CreateError!void {
        if (!std.mem.eql(u8, name, "args")) return error.UnknownOption;
        try setText(gpa, &p.args, text);
    }

    pub fn deinit(p: *Pan, gpa: std.mem.Allocator) void {
        if (p.args) |a| gpa.free(a);
        if (p.gain_owned) gpa.destroy(p.gain);
    }

    fn skipSpaces(text: []const u8, pos: *usize) void {
        while (pos.* < text.len and isCSpace(text[pos.*])) pos.* += 1;
    }

    fn isCSpace(c: u8) bool {
        return c == ' ' or (c >= '\t' and c <= '\r');
    }

    const Named = struct { channel: i32, named: bool };

    /// `parse_channel_name`: up to 7 capitals naming a channel, or `c<n>`.
    fn parseChannel(text: []const u8, pos: *usize) ?Named {
        skipSpaces(text, pos);
        var end = pos.*;
        while (end < text.len and end - pos.* < 7 and text[end] >= 'A' and text[end] <= 'Z') end += 1;
        if (end > pos.*) {
            const c = Channel.parse(text[pos.*..end]) catch return null;
            if (c.id() < 0) return null;
            pos.* = end;
            return .{ .channel = c.id(), .named = true };
        }
        if (pos.* < text.len and text[pos.*] == 'c') {
            const n = channel_layout.strtol(text[pos.* + 1 ..], 10);
            if (n.end == 0) return null;
            const id: i32 = @truncate(n.value);
            if (id < 0 or id >= max_channels) return null;
            pos.* += 1 + n.end;
            return .{ .channel = id, .named = false };
        }
        return null;
    }

    pub fn init(p: *Pan, gpa: std.mem.Allocator, sink: ?diagnostics.Sink) CreateError!void {
        const args = p.args orelse return report(sink, "pan filter needs a channel layout and a set of channel definitions as parameter", .{});
        p.gain = try gpa.create([max_channels][max_channels]f64);
        p.gain_owned = true;
        for (p.gain) |*row| row.* = @splat(0);
        // av_strtok: empty fields are skipped.
        var tokens = std.mem.tokenizeScalar(u8, args, '|');
        const layout_text = tokens.next() orelse return report(sink, "Channel layout not specified", .{});
        p.layout = Layout.parse(layout_text) catch return report(sink, "Invalid channel layout '{s}'", .{layout_text});
        p.output_count = p.layout.channelCount();
        if (p.output_count > max_channels) return report(sink, "af_pan supports a maximum of 64 channels. Feel free to ask for a higher limit.", .{});
        var used_out: [max_channels]bool = @splat(false);
        var counts: [2]u32 = .{ 0, 0 };
        while (tokens.next()) |spec| {
            var used_in: [max_channels]bool = @splat(false);
            var pos: usize = 0;
            const short = spec[0..@min(spec.len, 8)];
            const out = parseChannel(spec, &pos) orelse return report(sink, "Expected out channel name, got \"{s}\"", .{spec[@min(pos, spec.len)..][0..@min(8, spec.len - @min(pos, spec.len))]});
            var out_id = out.channel;
            if (out.named) {
                const ch: Channel = @fromBackingInt(out.channel);
                out_id = if (indexOf(&p.layout, ch)) |i| @intCast(i) else return report(sink, "Channel \"{s}\" does not exist in the chosen layout", .{short});
            }
            if (out_id < 0 or out_id >= p.output_count) return report(sink, "Invalid out channel name \"{s}\"", .{short});
            const o: usize = @intCast(out_id);
            if (used_out[o]) return report(sink, "Can not reference out channel {d} twice", .{o});
            used_out[o] = true;
            skipSpaces(spec, &pos);
            if (pos < spec.len and spec[pos] == '=') {
                pos += 1;
            } else if (pos < spec.len and spec[pos] == '<') {
                p.need_renorm |= @as(u64, 1) << @intCast(o);
                pos += 1;
            } else return report(sink, "Syntax error after channel name in \"{s}\"", .{short});
            var sign: f64 = 1;
            while (true) {
                var gain: f64 = 1;
                // sscanf "%lf%n *%n": a number, then optionally spaces and '*'.
                const n = number.strtod(spec[pos..]);
                if (n.end > 0) {
                    gain = n.value;
                    var after = pos + n.end;
                    var star = after;
                    while (star < spec.len and isCSpace(spec[star])) star += 1;
                    if (star < spec.len and spec[star] == '*') after = star + 1;
                    pos = after;
                }
                const in = parseChannel(spec, &pos) orelse return report(sink, "Expected in channel name, got \"{s}\"", .{spec[pos..][0..@min(8, spec.len - pos)]});
                const named: usize = @intFromBool(in.named);
                counts[named] += 1;
                if (counts[1 - named] > 0) return report(sink, "Can not mix named and numbered channels", .{});
                if (in.channel < 0 or in.channel >= max_channels) return report(sink, "Input channel id {d} is not supported", .{in.channel});
                const ic: usize = @intCast(in.channel);
                if (used_in[ic]) return report(sink, "Can not reference in channel {d} twice", .{ic});
                used_in[ic] = true;
                p.gain[o][ic] = sign * gain;
                skipSpaces(spec, &pos);
                if (pos >= spec.len) break;
                if (spec[pos] == '-') {
                    sign = -1;
                } else if (spec[pos] != '+') {
                    return report(sink, "Syntax error near \"{s}\"", .{spec[pos..][0..@min(8, spec.len - pos)]});
                } else {
                    sign = 1;
                }
                pos += 1;
            }
        }
        p.need_renumber = counts[1] > 0;
        p.pure_gains = pure(p.gain);
    }

    /// `are_gains_pure`: each output a copy of at most one input.
    fn pure(gain: *const [max_channels][max_channels]f64) bool {
        for (gain) |row| {
            var count: u32 = 0;
            for (row) |g| {
                if (g != 0 and g != 1) return false;
                if (g != 0) {
                    if (count > 0) return false;
                    count += 1;
                }
            }
        }
        return true;
    }
};

/// pan on configured links (`config_props`): libswresample with the
/// gains as its matrix, or, when they are pure, its channel mapping.
pub const PanRun = struct {
    format: audio.Format,
    out_format: audio.Format,
    /// The input channel of each output, -1 for silence, when pure.
    map: [max_channels]i32 = @splat(-1),
    pure: bool,
    /// Owned; the mix, when not pure.
    remix: ?*rematrix.Remix = null,
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, p: *Pan, in: audio.Format, out: audio.Format) error{OutOfMemory}!PanRun {
        const in_count = in.channelCount();
        if (p.need_renumber) {
            // Named input channels: their indexes in the input layout.
            var j: usize = 0;
            for (0..max_channels) |i| {
                const ch: Channel = @fromBackingInt(@intCast(i));
                if (indexOf(&in.layout, ch) != null) {
                    for (0..p.output_count) |k| p.gain[k][j] = p.gain[k][i];
                    j += 1;
                }
            }
        }
        var r: PanRun = .{ .format = in, .out_format = out, .pure = p.pure_gains };
        if (r.pure) {
            for (0..p.output_count) |i| {
                for (0..in_count) |j| {
                    if (p.gain[i][j] != 0) {
                        r.map[i] = @intCast(j);
                        break;
                    }
                }
            }
            return r;
        }
        for (0..p.output_count) |i| {
            if ((p.need_renorm >> @intCast(i)) & 1 == 0) continue;
            var t: f64 = 0;
            for (0..in_count) |j| t += @abs(p.gain[i][j]);
            // Almost 0: probably a mistake, left as it is.
            if (t > -1e-5 and t < 1e-5) continue;
            for (0..in_count) |j| p.gain[i][j] /= t;
        }
        const remix = try gpa.create(rematrix.Remix);
        // swr_set_matrix copies the input's columns of the outputs' rows.
        var matrix: rematrix.Matrix = undefined;
        for (&matrix, 0..) |*row, i| {
            row.* = @splat(0);
            if (i < p.output_count) @memcpy(row[0..in_count], p.gain[i][0..in_count]);
        }
        remix.initMatrix(in, out.layout, out.sample_format, &matrix);
        r.remix = remix;
        return r;
    }

    pub fn deinit(r: *PanRun, gpa: std.mem.Allocator) void {
        if (r.remix) |m| gpa.destroy(m);
        r.scratch.deinit(gpa);
    }

    pub fn filterFrame(r: *PanRun, gpa: std.mem.Allocator, in: *const Owned) error{OutOfMemory}!Owned {
        const count = in.frameCount();
        var out = try Owned.alloc(gpa, r.out_format, count, in.pts);
        errdefer out.free(gpa);
        const view = in.buffer().view();
        const buffer = out.buffer();
        if (r.remix) |m| {
            const len = m.scratchLen(count);
            try r.scratch.resize(gpa, @max(len, r.scratch.items.len));
            rematrix.convert(m, buffer, view, count, r.scratch.items[0..len], null);
            return out;
        }
        // The channel mapping: copies, silence where no input is mapped.
        const width = r.format.sample_format.bytesPerSample();
        const in_channels = r.format.channelCount();
        const out_channels = r.out_format.channelCount();
        const silence = r.format.sample_format.silenceByte();
        for (0..out_channels) |o| {
            for (0..count) |s| {
                const dst = if (r.format.sample_format.isPlanar()) buffer.plane(@intCast(o))[s * width ..][0..width] else buffer.plane(0)[(s * out_channels + o) * width ..][0..width];
                if (r.map[o] < 0) {
                    @memset(dst, silence);
                    continue;
                }
                const i: usize = @intCast(r.map[o]);
                const src = if (r.format.sample_format.isPlanar()) view.plane(@intCast(i))[s * width ..][0..width] else view.plane(0)[(s * in_channels + i) * width ..][0..width];
                @memcpy(dst, src);
            }
        }
        return out;
    }
};

// amix ----------------------------------------------------------------------

pub const Duration = enum(u8) { longest, shortest, first };

pub const AMix = struct {
    scalars: Scalars = .{},
    /// `weights`, owned; null for "1 1".
    weights_text: ?[]u8 = null,

    pub const Scalars = struct {
        inputs: i32 = 2,
        duration: Duration = .longest,
        dropout_transition: f32 = 2,
        normalize: bool = true,

        pub const option_specs = [_]options.Spec{
            .{ .name = "inputs", .field = "inputs", .kind = .int, .help = "Number of inputs.", .min = 1, .max = std.math.maxInt(i16) },
            .{ .name = "duration", .field = "duration", .kind = .int, .help = "How to determine the end-of-stream.", .min = 0, .max = 2, .constants = &.{
                .{ .name = "longest", .value = 0 },
                .{ .name = "shortest", .value = 1 },
                .{ .name = "first", .value = 2 },
            } },
            .{ .name = "dropout_transition", .field = "dropout_transition", .kind = .float, .help = "Transition time, in seconds, for volume renormalization when an input stream ends.", .min = 0, .max = std.math.maxInt(i32) },
            .{ .name = "normalize", .field = "normalize", .kind = .bool, .help = "Scale inputs", .min = 0, .max = 1 },
        };

        comptime {
            options.check(Scalars);
        }
    };

    pub fn set(a: *AMix, gpa: std.mem.Allocator, name: []const u8, text: []const u8) CreateError!void {
        if (std.mem.eql(u8, name, "weights")) return setText(gpa, &a.weights_text, text);
        try options.set(Scalars, &a.scalars, name, text);
    }

    pub fn deinit(a: *AMix, gpa: std.mem.Allocator) void {
        if (a.weights_text) |t| gpa.free(t);
    }

    /// `parse_weights`: numbers one character apart, the last repeated.
    fn weights(a: *const AMix, gpa: std.mem.Allocator) error{OutOfMemory}![]f32 {
        const count: usize = @intCast(a.scalars.inputs);
        const out = try gpa.alloc(f32, count);
        const text = a.weights_text orelse "1 1";
        var p: usize = 0;
        var last: f32 = 1;
        var i: usize = 0;
        while (i < count) {
            const n = number.avStrtod(text[p..]);
            last = @floatCast(n.value);
            out[i] = last;
            p += n.end;
            i += 1;
            if (p < text.len) p += 1 else break;
        }
        while (i < count) : (i += 1) out[i] = last;
        return out;
    }
};

const input_on: u8 = 1;
const input_eof: u8 = 2;

/// amix on configured links (`config_output`, `output_frame`): a sample
/// queue per input, the first input's frame sizes, the scales.
pub const MixRun = struct {
    gpa: std.mem.Allocator,
    format: audio.Format,
    inputs: u32,
    duration: Duration,
    dropout_transition: f32,
    normalize: bool,
    weights: []f32,
    weight_sum: f32,
    state: []u8,
    scale: []f32,
    scale_norm: []f32,
    /// Each input's queued samples, as the output format packs them.
    fifos: []Fifo,
    /// The first input's frames not yet mixed: their sizes and pts.
    frames: std.ArrayList(FrameInfo) = .empty,
    next_pts: ?i64 = null,

    const FrameInfo = struct { samples: u32, pts: ?i64 };

    /// An `AVAudioFifo`: samples of one input, plane after plane.
    const Fifo = struct {
        planes: []std.ArrayList(u8),
        start: usize = 0,

        fn size(f: *const Fifo, sample_bytes: usize) u32 {
            return @intCast((f.planes[0].items.len - f.start) / sample_bytes);
        }
    };

    pub fn init(gpa: std.mem.Allocator, a: *const AMix, format: audio.Format) error{OutOfMemory}!MixRun {
        const count: u32 = @intCast(a.scalars.inputs);
        const w = try a.weights(gpa);
        errdefer gpa.free(w);
        var sum: f32 = 0;
        for (w) |x| sum += @abs(x);
        const state = try gpa.alloc(u8, count);
        errdefer gpa.free(state);
        @memset(state, input_on);
        const scale = try gpa.alloc(f32, count);
        errdefer gpa.free(scale);
        const norm = try gpa.alloc(f32, count);
        errdefer gpa.free(norm);
        const fifos = try gpa.alloc(Fifo, count);
        errdefer gpa.free(fifos);
        const plane_count: usize = if (format.sample_format.isPlanar()) format.channelCount() else 1;
        var made: usize = 0;
        errdefer for (fifos[0..made]) |*f| gpa.free(f.planes);
        for (fifos) |*f| {
            const planes = try gpa.alloc(std.ArrayList(u8), plane_count);
            for (planes) |*p| p.* = .empty;
            f.* = .{ .planes = planes };
            made += 1;
        }
        for (norm, w) |*n, x| n.* = sum / @abs(x);
        var r: MixRun = .{
            .gpa = gpa,
            .format = format,
            .inputs = count,
            .duration = a.scalars.duration,
            .dropout_transition = a.scalars.dropout_transition,
            .normalize = a.scalars.normalize,
            .weights = w,
            .weight_sum = sum,
            .state = state,
            .scale = scale,
            .scale_norm = norm,
            .fifos = fifos,
        };
        r.calculateScales(0);
        return r;
    }

    pub fn deinit(r: *MixRun) void {
        for (r.fifos) |*f| {
            for (f.planes) |*p| p.deinit(r.gpa);
            r.gpa.free(f.planes);
        }
        r.gpa.free(r.fifos);
        r.gpa.free(r.weights);
        r.gpa.free(r.state);
        r.gpa.free(r.scale);
        r.gpa.free(r.scale_norm);
        r.frames.deinit(r.gpa);
        r.* = undefined;
    }

    pub fn isOn(r: *const MixRun, i: usize) bool {
        return r.state[i] & input_on != 0;
    }

    pub fn isEof(r: *const MixRun, i: usize) bool {
        return r.state[i] & input_eof != 0;
    }

    fn sampleBytes(r: *const MixRun) usize {
        const per = r.format.sample_format.bytesPerSample();
        return if (r.format.sample_format.isPlanar()) per else per * r.format.channelCount();
    }

    pub fn fifoSize(r: *const MixRun, i: usize) u32 {
        return r.fifos[i].size(r.sampleBytes());
    }

    /// The first input's next frame size (0 without one).
    pub fn nextFrameSize(r: *const MixRun) u32 {
        return if (r.frames.items.len > 0) r.frames.items[0].samples else 0;
    }

    pub fn frameCount(r: *const MixRun) usize {
        return r.frames.items.len;
    }

    /// Queues frame `frame` of input `i`; `pts` is in the output's time
    /// base for the first input.
    pub fn write(r: *MixRun, i: usize, frame: *const Owned, pts: ?i64) error{OutOfMemory}!void {
        if (i == 0) try r.frames.append(r.gpa, .{ .samples = frame.frameCount(), .pts = pts });
        const view = frame.buffer().view();
        const bytes = frame.frameCount() * r.sampleBytes();
        for (r.fifos[i].planes, 0..) |*p, k| try p.appendSlice(r.gpa, view.plane(@intCast(k))[0..bytes]);
    }

    /// `frame_list_remove_samples`.
    fn removeSamples(r: *MixRun, count: u32) void {
        var left = count;
        while (left > 0 and r.frames.items.len > 0) {
            const first = &r.frames.items[0];
            if (first.samples <= left) {
                left -= first.samples;
                _ = r.frames.orderedRemove(0);
            } else {
                first.samples -= left;
                if (first.pts) |*p| p.* += left;
                left = 0;
            }
        }
    }

    /// `calculate_scales`.
    fn calculateScales(r: *MixRun, nb_samples: u32) void {
        var weight_sum: f32 = 0;
        for (0..r.inputs) |i| {
            if (r.isOn(i)) weight_sum += @abs(r.weights[i]);
        }
        const samples_f: f32 = @floatFromInt(nb_samples);
        const rate: f32 = @floatFromInt(r.format.sample_rate);
        const inputs_f: f32 = @floatFromInt(r.inputs);
        for (0..r.inputs) |i| {
            if (!r.isOn(i)) continue;
            const w = @abs(r.weights[i]);
            if (r.scale_norm[i] > weight_sum / w) {
                r.scale_norm[i] -= ((r.weight_sum / w) / inputs_f) * samples_f / (r.dropout_transition * rate);
                r.scale_norm[i] = @max(r.scale_norm[i], weight_sum / w);
            }
        }
        for (0..r.inputs) |i| {
            if (r.isOn(i)) {
                const sign: f32 = if (r.weights[i] > 0) 1 else -1;
                r.scale[i] = if (!r.normalize) @abs(r.weights[i]) else 1.0 / r.scale_norm[i] * sign;
            } else {
                r.scale[i] = 0;
            }
        }
    }

    /// The result of `output_frame`.
    pub const Output = union(enum) {
        none,
        frame: Owned,
        /// The first input closed and nothing is left: the end.
        end,
    };

    /// `output_frame`.
    pub fn output(r: *MixRun) error{OutOfMemory}!Output {
        var nb_samples: u32 = undefined;
        if (r.isOn(0)) {
            nb_samples = r.nextFrameSize();
            for (1..r.inputs) |i| {
                if (!r.isOn(i)) continue;
                const ns = r.fifoSize(i);
                if (ns < nb_samples) {
                    // An open input without enough samples.
                    if (!r.isEof(i)) return .none;
                    nb_samples = ns;
                }
            }
            r.next_pts = if (r.frames.items.len > 0) r.frames.items[0].pts else null;
        } else {
            nb_samples = std.math.maxInt(i32);
            for (1..r.inputs) |i| {
                if (r.isOn(i)) nb_samples = @min(nb_samples, r.fifoSize(i));
            }
            if (nb_samples == std.math.maxInt(i32)) return .end;
        }
        r.removeSamples(nb_samples);
        r.calculateScales(nb_samples);
        if (nb_samples == 0) return .none;
        var out = try Owned.alloc(r.gpa, r.format, nb_samples, r.next_pts);
        @memset(out.data, 0);
        const buffer = out.buffer();
        const bytes = nb_samples * r.sampleBytes();
        for (0..r.inputs) |i| {
            if (!r.isOn(i)) continue;
            const f = &r.fifos[i];
            for (f.planes, 0..) |*p, k| {
                const src = p.items[f.start..][0..bytes];
                const dst = buffer.plane(@intCast(k))[0..bytes];
                switch (r.format.sample_format.packedForm()) {
                    .flt => {
                        const mul = r.scale[i];
                        for (std.mem.bytesAsSlice(f32, dst), std.mem.bytesAsSlice(f32, src)) |*d, s| d.* += s * mul;
                    },
                    else => {
                        const mul: f64 = r.scale[i];
                        for (std.mem.bytesAsSlice(f64, dst), std.mem.bytesAsSlice(f64, src)) |*d, s| d.* += s * mul;
                    },
                }
            }
            f.start += bytes;
            // Compact the queue once it is read through.
            if (f.start == f.planes[0].items.len) {
                for (f.planes) |*p| p.clearRetainingCapacity();
                f.start = 0;
            }
        }
        if (r.next_pts) |*p| p.* += nb_samples;
        return .{ .frame = out };
    }

    /// Marks input `i` ended (`INPUT_EOF`), off once its queue is empty.
    pub fn endInput(r: *MixRun, i: usize) void {
        r.state[i] |= input_eof;
        if (r.fifoSize(i) == 0) r.state[i] &= ~input_on;
    }

    /// `calc_active_inputs`: whether the duration mode ends the output.
    pub fn ended(r: *const MixRun) bool {
        var active: u32 = 0;
        for (0..r.inputs) |i| active += @intFromBool(r.isOn(i));
        return active == 0 or (r.duration == .first and !r.isOn(0)) or (r.duration == .shortest and active != r.inputs);
    }
};
