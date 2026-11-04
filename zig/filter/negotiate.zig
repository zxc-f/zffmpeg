// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavfilter/avfiltergraph.c (query_formats, reduce_formats_on_filter,
// swap_samplerates_on_filter, swap_channel_layouts_on_filter,
// swap_sample_fmts_on_filter, pick_format, pick_formats, get_fmt_score)
// and formats.c (SET_COMMON_FORMATS, ff_default_query_formats) at the
// pinned reference revision describe the behavior, restated here.
//! Format negotiation of a filter graph (TODO.md T25a, every pad since
//! T25c): each filter's lists on its pads, the merges along each link
//! with `aresample` converters where they fail, the reductions, the swaps
//! that put the best entry first, and the pick of each link's format, as
//! `avfilter_graph_config` makes them, filter by filter in graph order and
//! pad by pad.

const std = @import("std");
const audio = @import("../core/audio.zig");
const channel_layout = @import("../core/channel_layout.zig");
const diagnostics = @import("../core/diagnostics.zig");
const formats = @import("formats.zig");
const filters = @import("filters.zig");
const graph_zig = @import("graph.zig");
const Graph = graph_zig.Graph;
const Node = graph_zig.Node;
const Layout = channel_layout.Layout;
const Channel = channel_layout.Channel;
const SampleFormat = audio.SampleFormat;
const Pool = formats.Pool;
const Kind = formats.Kind;

pub const Error = graph_zig.ConfigureError;

const merge_order = [_]Kind{ .layouts, .samplerates, .formats };

/// Negotiates every link's format (`graph_config_formats`).
pub fn negotiate(g: *Graph) Error!void {
    var arena: std.heap.ArenaAllocator = .init(g.gpa);
    defer arena.deinit();
    var pool: Pool = .init(arena.allocator());
    for (g.links.items) |_| _ = try pool.addLink();
    try queryAll(g, &pool);
    try reduce(g, &pool);
    swapSampleFormats(g, &pool);
    swapRates(g, &pool);
    swapLayouts(g, &pool);
    try pickAll(g, &pool);
}

/// `query_formats`: each filter's lists, then the merges along links,
/// converters inserted where they fail.
fn queryAll(g: *Graph, pool: *Pool) Error!void {
    for (0..g.nodes.items.len) |i| try query(g, pool, @intCast(i));
    var converters: u32 = 0;
    retry: while (true) {
        for (0..g.nodes.items.len) |i| {
            for (0..g.nodes.items[i].inputs.len) |pad| {
                const input = g.nodes.items[i].inputs[pad].?;
                if (try mergeLink(g, pool, input, &converters)) continue :retry;
            }
        }
        break;
    }
}

/// The merges of one link; inserts a converter and returns true when
/// they cannot all be made.
fn mergeLink(g: *Graph, pool: *Pool, link: u32, converters: *u32) Error!bool {
    var convert = false;
    for (merge_order) |kind| {
        const a = pool.slot(link, .in, kind).* orelse continue;
        const b = pool.slot(link, .out, kind).* orelse continue;
        if (a != b and !try pool.canMerge(kind, a, b)) convert = true;
    }
    for (merge_order) |kind| {
        // The check may have merged layouts already.
        const a = pool.slot(link, .in, kind).* orelse continue;
        const b = pool.slot(link, .out, kind).* orelse continue;
        if (a == b or convert) continue;
        if (!try pool.merge(kind, a, b)) convert = true;
    }
    if (!convert) return false;
    try insertConverter(g, pool, link, converters);
    return true;
}

/// `avfilter_insert_filter` of `auto_aresample_<n>` on `link`, its lists
/// merged with both sides at once.
fn insertConverter(g: *Graph, pool: *Pool, link: u32, converters: *u32) Error!void {
    var name_buffer: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "auto_aresample_{d}", .{converters.*}) catch unreachable;
    converters.* += 1;
    const conv = try g.addFilter(name, try filters.Filter.create(g.gpa, "aresample", g.converter, g.diagnostics));
    const dst = g.links.items[link].dst;
    const dst_pad = g.links.items[link].dst_pad;
    const after = try g.addLink(conv, 0, dst, dst_pad);
    _ = try pool.addLink();
    g.links.items[link].dst = conv;
    g.links.items[link].dst_pad = 0;
    g.nodes.items[conv].inputs[0] = link;
    // The destination's lists move to the new link.
    pool.cfg(after, .out).* = pool.cfg(link, .out).*;
    pool.cfg(link, .out).* = .{};
    try query(g, pool, conv);
    for (merge_order) |kind| {
        const ok = try pool.merge(kind, pool.slot(link, .in, kind).*.?, pool.slot(link, .out, kind).*.?) and
            try pool.merge(kind, pool.slot(after, .in, kind).*.?, pool.slot(after, .out, kind).*.?);
        if (!ok) {
            diagnostics.report(g.diagnostics, .err, "Impossible to convert between the formats supported by the filter '{s}' and the filter '{s}'", .{
                g.nodes.items[g.links.items[link].src].label, g.nodes.items[dst].label,
            });
            return error.CannotConvert;
        }
    }
}

/// `SET_COMMON_FORMATS`: `id` on every side of the node that has no list
/// of the kind yet.
fn setCommon(g: *Graph, pool: *Pool, node: u32, kind: Kind, id: formats.Id) void {
    const n = &g.nodes.items[node];
    for (n.inputs) |l| {
        const s = pool.slot(l.?, .out, kind);
        if (s.* == null) s.* = id;
    }
    for (n.outputs) |l| {
        const s = pool.slot(l.?, .in, kind);
        if (s.* == null) s.* = id;
    }
}

fn layoutList(pool: *Pool, items: []const Layout) error{OutOfMemory}!formats.Id {
    return pool.newLayouts(items, false);
}

fn formatIds(pool: *Pool, list: []const SampleFormat) error{OutOfMemory}!formats.Id {
    var ids: [12]i32 = undefined;
    for (list, 0..) |f, i| ids[i] = f.ffmpegId();
    return pool.newValues(ids[0..list.len]);
}

/// `ff_planar_sample_fmts`, in FFmpeg's order.
const planar_formats = [_]SampleFormat{ .u8p, .s16p, .s32p, .fltp, .dblp, .s64p };

/// `filter_query_formats`: the node's own lists, checked, then
/// `ff_default_query_formats` for the rest: every format (or the filter's
/// list), rate and channel count, one list shared by the node's sides.
fn query(g: *Graph, pool: *Pool, node: u32) Error!void {
    const n = &g.nodes.items[node];
    var checks = true;
    var default_formats: ?[]const SampleFormat = null;
    switch (n.kind) {
        .source => |s| {
            const f = g.sources.items[s.index].spec.format;
            setCommon(g, pool, node, .formats, try pool.newValues(&.{f.sample_format.ffmpegId()}));
            setCommon(g, pool, node, .samplerates, try pool.newValues(&.{@intCast(f.sample_rate)}));
            setCommon(g, pool, node, .layouts, try layoutList(pool, &.{f.layout}));
        },
        .sink => |s| {
            const lists = &g.sinks.items[s.index];
            if (lists.formats.len > 0) {
                var ids: std.ArrayList(i32) = .empty;
                for (lists.formats) |f| try ids.append(pool.arena, f.ffmpegId());
                setCommon(g, pool, node, .formats, try pool.newValues(ids.items));
            }
            if (lists.rates.len > 0) {
                var rates: std.ArrayList(i32) = .empty;
                for (lists.rates) |r| try rates.append(pool.arena, @intCast(r));
                setCommon(g, pool, node, .samplerates, try pool.newValues(rates.items));
            }
            if (lists.layouts.len > 0) setCommon(g, pool, node, .layouts, try layoutList(pool, lists.layouts));
        },
        .filter => |*f| switch (f.*) {
            // No format query: every format, rate and layout.
            .anull, .atrim, .asetpts, .asplit => checks = false,
            // FILTER_SAMPLEFMTS: the list in the default query.
            .amix => {
                checks = false;
                default_formats = &.{ .flt, .fltp, .dbl, .dblp };
            },
            .aformat => |*a| {
                if (a.formats.items.len > 0) setCommon(g, pool, node, .formats, try pool.newValues(a.formatList()));
                if (a.rates.items.len > 0) setCommon(g, pool, node, .samplerates, try pool.newValues(a.rates.items));
                if (a.layouts.items.len > 0) setCommon(g, pool, node, .layouts, try layoutList(pool, a.layouts.items));
            },
            .volume => |*v| setCommon(g, pool, node, .formats, try formatIds(pool, filters.VolumeRun.formats(v.rest.precision))),
            .aresample => |*a| {
                const all = formats.allFormats();
                const in = n.inputs[0].?;
                const out = n.outputs[0].?;
                pool.slot(in, .out, .formats).* = try pool.newValues(&all);
                pool.slot(in, .out, .samplerates).* = try pool.newValues(&.{});
                pool.slot(in, .out, .layouts).* = try pool.newLayouts(&.{}, true);
                const rate = a.outRate();
                pool.slot(out, .in, .samplerates).* = try pool.newValues(if (rate > 0) &.{rate} else &.{});
                pool.slot(out, .in, .formats).* = if (a.out_sample_format) |sf|
                    try pool.newValues(&.{sf.ffmpegId()})
                else
                    try pool.newValues(&all);
                pool.slot(out, .in, .layouts).* = if (a.out_layout) |l|
                    try layoutList(pool, &.{l})
                else
                    try pool.newLayouts(&.{}, true);
            },
            .channelsplit => |*c| {
                setCommon(g, pool, node, .formats, try formatIds(pool, &planar_formats));
                pool.slot(n.inputs[0].?, .out, .layouts).* = try layoutList(pool, &.{c.layout});
                for (n.outputs, 0..) |out, i| {
                    pool.slot(out.?, .in, .layouts).* = try layoutList(pool, &.{c.outputLayout(i)});
                }
            },
            .channelmap => |*c| {
                setCommon(g, pool, node, .formats, try formatIds(pool, &planar_formats));
                pool.slot(n.outputs[0].?, .in, .layouts).* = try layoutList(pool, &.{c.output_layout.?});
            },
            .pan => |*p| {
                pool.slot(n.inputs[0].?, .out, .layouts).* = try pool.newLayouts(&.{}, true);
                pool.slot(n.outputs[0].?, .in, .layouts).* = try layoutList(pool, &.{p.layout});
            },
        },
    }
    if (checks) try checkNode(g, pool, node);
    // ff_default_query_formats.
    const all = formats.allFormats();
    setCommon(g, pool, node, .formats, if (default_formats) |list| try formatIds(pool, list) else try pool.newValues(&all));
    setCommon(g, pool, node, .layouts, try pool.newLayouts(&.{}, true));
    setCommon(g, pool, node, .samplerates, try pool.newValues(&.{}));
}

/// `filter_check_formats`: the node's lists of its own.
fn checkNode(g: *Graph, pool: *Pool, node: u32) formats.CheckError!void {
    const n = &g.nodes.items[node];
    for (n.inputs) |l| try checkSide(pool, pool.cfg(l.?, .out));
    for (n.outputs) |l| try checkSide(pool, pool.cfg(l.?, .in));
}

fn checkSide(pool: *Pool, c: *formats.Cfg) formats.CheckError!void {
    if (c.formats) |id| try pool.checkValues(id, false);
    if (c.samplerates) |id| try pool.checkValues(id, true);
    if (c.layouts) |id| try pool.checkLayouts(id);
}

/// `reduce_formats`: a filter's input with one format gives it to the
/// filter's outputs whose list has it, until nothing changes. As FFmpeg's
/// macro does, a list that is filled from empty stops the outputs' loop.
fn reduce(g: *Graph, pool: *Pool) error{OutOfMemory}!void {
    while (true) {
        var reduced = false;
        for (g.nodes.items) |*n| {
            for ([_]Kind{ .formats, .samplerates }) |kind| {
                for (n.inputs) |in| {
                    const in_list = pool.values(pool.slot(in.?, .out, kind).* orelse continue);
                    if (in_list.items.len != 1) continue;
                    const value = in_list.items[0];
                    for (n.outputs) |out| {
                        const out_list = pool.values(pool.slot(out.?, .in, kind).*.?);
                        if (out_list.items.len == 1) continue;
                        if (out_list.items.len == 0) {
                            try out_list.append(pool.arena, value);
                            reduced = true;
                            break;
                        }
                        if (std.mem.findScalar(i32, out_list.items, value) != null) {
                            out_list.items[0] = value;
                            out_list.shrinkRetainingCapacity(1);
                            reduced = true;
                        }
                    }
                }
            }
            for (n.inputs) |in| {
                const in_layouts = pool.layouts(pool.slot(in.?, .out, .layouts).* orelse continue);
                if (in_layouts.items.items.len != 1) continue;
                const layout = in_layouts.items.items[0];
                for (n.outputs) |out| {
                    const out_layouts = pool.layouts(pool.slot(out.?, .in, .layouts).*.?);
                    if (out_layouts.items.items.len == 1) continue;
                    if (out_layouts.all) {
                        // Every channel count, so the layout whether known or not.
                        out_layouts.all = false;
                        try out_layouts.items.append(pool.arena, layout);
                        reduced = true;
                        break;
                    }
                    for (out_layouts.items.items) |*l| {
                        if (l.eql(&layout)) {
                            out_layouts.items.items[0] = layout;
                            out_layouts.items.shrinkRetainingCapacity(1);
                            reduced = true;
                            break;
                        }
                    }
                }
            }
        }
        if (!reduced) return;
    }
}

/// The first input whose list of `kind` holds one entry.
fn singleInput(pool: *Pool, n: *const Node, kind: Kind) ?i32 {
    for (n.inputs) |in| {
        const list = pool.values(pool.slot(in.?, .out, kind).*.?);
        if (list.items.len == 1) return list.items[0];
    }
    return null;
}

/// `swap_sample_fmts`: each output's format closest to the input's, first.
fn swapSampleFormats(g: *Graph, pool: *Pool) void {
    for (g.nodes.items) |*n| {
        const format_id = singleInput(pool, n, .formats) orelse continue;
        const format = SampleFormat.fromFfmpegId(format_id).?;
        const bps: i32 = format.bytesPerSample();
        for (n.outputs) |out| {
            const list = pool.values(pool.slot(out.?, .in, .formats).*.?);
            if (list.items.len < 2) continue;
            var best: ?usize = null;
            var best_score: i32 = std.math.minInt(i32);
            for (list.items, 0..) |id, j| {
                const f = SampleFormat.fromFfmpegId(id).?;
                const out_bps: i32 = f.bytesPerSample();
                if (f.packedForm() == format or f.planarForm() == format) {
                    best = j;
                    break;
                }
                // For s32 and float, double keeps everything.
                if (bps == 4 and out_bps == 8) {
                    best = j;
                    break;
                }
                // The closest higher or equal size.
                const distance: i32 = @intCast(@abs(out_bps - bps));
                var score: i32 = -distance;
                if (out_bps >= bps) score += std.math.maxInt(i32) / 2;
                if (score > best_score) {
                    best_score = score;
                    best = j;
                }
            }
            std.mem.swap(i32, &list.items[0], &list.items[best.?]);
        }
    }
}

/// `swap_samplerates`: each output's rate closest to the input's, first.
fn swapRates(g: *Graph, pool: *Pool) void {
    for (g.nodes.items) |*n| {
        const rate = singleInput(pool, n, .samplerates) orelse continue;
        for (n.outputs) |out| {
            const list = pool.values(pool.slot(out.?, .in, .samplerates).*.?);
            if (list.items.len < 2) continue;
            var best: usize = 0;
            var best_diff: i64 = std.math.maxInt(i32);
            for (list.items, 0..) |r, j| {
                const diff: i64 = @intCast(@abs(@as(i64, rate) - r));
                if (diff < best_diff) {
                    best_diff = diff;
                    best = j;
                }
            }
            std.mem.swap(i32, &list.items[0], &list.items[best]);
        }
    }
}

/// `swap_channel_layouts`: each output's layout that best matches the
/// input's, first.
fn swapLayouts(g: *Graph, pool: *Pool) void {
    for (g.nodes.items) |*n| {
        const in_layout = for (n.inputs) |in| {
            const list = pool.layouts(pool.slot(in.?, .out, .layouts).*.?);
            if (list.items.items.len == 1) break &list.items.items[0];
        } else continue;
        for (n.outputs) |out| {
            const list = pool.layouts(pool.slot(out.?, .in, .layouts).*.?);
            if (list.items.items.len < 2) continue;
            var best: ?usize = null;
            var best_score: i32 = std.math.minInt(i32);
            var best_count_diff: i32 = std.math.maxInt(i32);
            for (list.items.items, 0..) |*out_layout, j| {
                const s = layoutScore(in_layout, out_layout);
                if (s.score > best_score or (s.count_diff < best_count_diff and s.score == best_score)) {
                    best_score = s.score;
                    best = j;
                    best_count_diff = s.count_diff;
                }
            }
            std.mem.swap(Layout, &list.items.items[0], &list.items.items[best.?]);
        }
    }
}

/// `pick_formats`: links with one format first, then the outputs of
/// filters whose first input is picked, chosen against it, then the rest.
fn pickAll(g: *Graph, pool: *Pool) Error!void {
    while (true) {
        var change = false;
        for (g.nodes.items) |*n| {
            for (n.inputs) |l| {
                const id = pool.slot(l.?, .in, .formats).* orelse continue;
                if (pool.values(id).items.len == 1) {
                    try pick(g, pool, l.?, null);
                    change = true;
                }
            }
            for (n.outputs) |l| {
                const id = pool.slot(l.?, .in, .formats).* orelse continue;
                if (pool.values(id).items.len == 1) {
                    try pick(g, pool, l.?, null);
                    change = true;
                }
            }
            if (n.inputs.len > 0 and n.outputs.len > 0 and g.links.items[n.inputs[0].?].picked) {
                for (n.outputs) |out| {
                    if (!g.links.items[out.?].picked) {
                        try pick(g, pool, out.?, n.inputs[0].?);
                        change = true;
                    }
                }
            }
        }
        if (!change) break;
    }
    for (g.nodes.items) |*n| {
        for (n.inputs) |l| try pick(g, pool, l.?, null);
        for (n.outputs) |l| try pick(g, pool, l.?, null);
    }
}

/// `pick_format`: the link's format, rate and layout, the first of each
/// list (the sample format chosen against `ref`'s, when given); the
/// link's lists are then dropped.
fn pick(g: *Graph, pool: *Pool, link: u32, ref: ?u32) Error!void {
    const id = pool.slot(link, .in, .formats).* orelse return;
    const list = pool.values(id);
    if (ref) |r| {
        const src = g.links.items[r].sample_format.ffmpegId();
        var best: i32 = -1;
        for (list.items) |p| best = bestOfTwo(best, p, src);
        list.items[0] = best;
    }
    list.shrinkRetainingCapacity(1);
    const l = &g.links.items[link];
    l.sample_format = SampleFormat.fromFfmpegId(list.items[0]).?;
    const rates = pool.values(pool.slot(link, .in, .samplerates).*.?);
    const layouts = pool.layouts(pool.slot(link, .in, .layouts).*.?);
    if (rates.items.len == 0 or layouts.all) {
        diagnostics.report(g.diagnostics, .err, "Cannot select {s} for the link between filters {s} and {s}.", .{
            if (rates.items.len == 0) "sample rate" else "channel layout",
            g.nodes.items[l.src].label,
            g.nodes.items[l.dst].label,
        });
        return error.CannotSelect;
    }
    rates.shrinkRetainingCapacity(1);
    l.sample_rate = @intCast(rates.items[0]);
    layouts.items.shrinkRetainingCapacity(1);
    l.layout = layouts.items.items[0];
    l.picked = true;
    pool.cfg(link, .in).* = .{};
    pool.cfg(link, .out).* = .{};
}

fn bestOfTwo(dst1: i32, dst2: i32, src: i32) i32 {
    return if (formatScore(dst1, src) < formatScore(dst2, src)) dst1 else dst2;
}

/// `get_fmt_score`; FFmpeg's helpers give an invalid format 0 bytes, not
/// planar, and no packed form.
fn formatScore(dst_id: i32, src_id: i32) i32 {
    const dst = SampleFormat.fromFfmpegId(dst_id);
    const src = SampleFormat.fromFfmpegId(src_id).?;
    const dst_planar = if (dst) |d| d.isPlanar() else false;
    const dst_bps: i32 = if (dst) |d| d.bytesPerSample() else 0;
    const src_bps: i32 = src.bytesPerSample();
    var score: i32 = 0;
    if (dst_planar != src.isPlanar()) score += 1;
    if (dst_bps < src_bps) score += 100 * (src_bps - dst_bps) else score += 10 * (dst_bps - src_bps);
    const dst_packed: ?SampleFormat = if (dst) |d| d.packedForm() else null;
    if (dst_packed == .s32 and src.packedForm() == .flt) score += 20;
    if (dst_packed == .flt and src.packedForm() == .s32) score += 2;
    return score;
}

fn chBit(c: Channel) u64 {
    const one: u64 = 1;
    return one << @intCast(c.id());
}

const center_pair = chBit(.front_left_of_center) | chBit(.front_right_of_center);
const front_pair = chBit(.front_left) | chBit(.front_right);
const wide_pair = chBit(.wide_left) | chBit(.wide_right);
const side_pair = chBit(.side_left) | chBit(.side_right);
const direct_pair = chBit(.surround_direct_left) | chBit(.surround_direct_right);
const back_pair = chBit(.back_left) | chBit(.back_right);
const front_center = chBit(.front_center);
const back_center = chBit(.back_center);
const lfe = chBit(.low_frequency);

/// `ch_subst`: pairs a layout may stand in for, by priority.
const substitutions = [_][2]u64{
    .{ front_pair, center_pair },  .{ front_pair, wide_pair },     .{ front_pair, front_center },
    .{ center_pair, front_pair },  .{ center_pair, wide_pair },    .{ center_pair, front_center },
    .{ wide_pair, front_pair },    .{ wide_pair, center_pair },    .{ wide_pair, front_center },
    .{ front_center, front_pair }, .{ front_center, center_pair }, .{ front_center, wide_pair },
    .{ side_pair, direct_pair },   .{ side_pair, back_pair },      .{ side_pair, back_center },
    .{ back_pair, direct_pair },   .{ back_pair, side_pair },      .{ back_pair, back_center },
    .{ back_center, back_pair },   .{ back_center, direct_pair },  .{ back_center, side_pair },
};

/// A layout as `swap_channel_layouts_on_filter` rewrites it: replaced by a
/// mask when a subset of it is taken (`av_channel_layout_from_mask`, which
/// leaves it unchanged for an empty mask).
const Working = union(enum) {
    /// An unspecified layout, or FFmpeg's zeroed one: no channels.
    none,
    native: u64,
    custom: *const Layout,

    fn of(l: *const Layout) Working {
        return switch (l.*) {
            .unspecified => .none,
            .native => |m| .{ .native = m },
            .custom => .{ .custom = l },
        };
    }

    /// `av_channel_layout_subset`.
    fn subset(w: Working, bits: u64) u64 {
        return switch (w) {
            .none => 0,
            .native => |m| m & bits,
            .custom => |l| bits: {
                var result: u64 = 0;
                for (0..l.channelCount()) |i| {
                    const id = l.channel(@intCast(i)).id();
                    if (id >= 0 and id < 64 and bits & (@as(u64, 1) << @intCast(id)) != 0) result |= @as(u64, 1) << @intCast(id);
                }
                break :bits result;
            },
        };
    }

    fn hasLfe(w: Working) bool {
        return switch (w) {
            .none => false,
            .native => |m| m & lfe != 0,
            .custom => |l| for (0..l.channelCount()) |i| {
                if (l.channel(@intCast(i)) == .low_frequency) break true;
            } else false,
        };
    }

    fn keep(w: *Working, bits: u64) void {
        const m = w.subset(bits);
        if (m != 0) w.* = .{ .native = m };
    }

    /// `u.mask`. FFmpeg reads a custom layout's map pointer here when no
    /// channel but LFE is in the mask; the port counts no channels.
    fn mask(w: Working) u64 {
        return switch (w) {
            .native => |m| m,
            else => 0,
        };
    }
};

/// The score of `out` for an input of `in`, and the channel count change.
fn layoutScore(in_layout: *const Layout, out_layout: *const Layout) struct { score: i32, count_diff: i32 } {
    const in_count: i32 = @intCast(in_layout.channelCount());
    const out_count: i32 = @intCast(out_layout.channelCount());
    const count_diff = out_count - in_count;
    var score: i32 = 100000;
    var in = Working.of(in_layout);
    var out = Working.of(out_layout);
    if (!formats.known(in_layout) or !formats.known(out_layout)) {
        const change: i32 = @intCast(@abs(out_count - in_count));
        const fewer: i32 = if (in_count > out_count) 10000 else 0;
        score -= 10000 + change + fewer;
        in = .none;
        out = .none;
    }
    for (substitutions) |pair| {
        const cmp0 = pair[0];
        const cmp1 = pair[1];
        if (in.subset(cmp0) != 0 and out.subset(cmp0) == 0 and out.subset(cmp1) != 0 and in.subset(cmp1) == 0) {
            in.keep(~cmp0);
            out.keep(~cmp1);
            score += 10 * @as(i32, @popCount(cmp1)) - 2;
        }
    }
    // No penalty for a missing LFE.
    if (in.hasLfe() and out.hasLfe()) score += 10;
    in.keep(~lfe);
    out.keep(~lfe);
    const matched: i32 = @popCount(in.mask() & out.mask());
    const extra: i32 = @popCount(out.mask() & ~in.mask());
    score += 10 * matched - 5 * extra;
    return .{ .score = score, .count_diff = count_diff };
}
