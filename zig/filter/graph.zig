// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavfilter/avfiltergraph.c (query_formats, reduce_formats,
// swap_samplerates, swap_channel_layouts, swap_sample_fmts, pick_format,
// pick_formats, graph_config_links), avfilter.c (avfilter_insert_filter,
// the default time base), buffersrc.c and buffersink.c (their format
// lists, the frame checks) and formats.c (ff_default_query_formats, the
// SET_COMMON_FORMATS rule) at the pinned reference revision describe the
// behavior, restated here.
//! An audio filter graph (TODO.md T25a): a linear chain of filters
//! (filters.zig) between a buffer source and a buffer sink, configured as
//! `avfilter_graph_config` configures one and run as a send/receive stage.
//!
//! `init` creates the filters, in order: the source (`in`), the chain, the
//! sink (`out`). `configure` negotiates: each filter declares the format
//! lists it accepts on its links; lists are merged along each link, and
//! where they cannot merge an `aresample` converter is inserted
//! (`auto_aresample_<n>`, with the graph's converter options); the lists
//! are then reduced, the best sample format, rate and layout moved first,
//! and one of each picked for every link. Equal to FFmpeg on
//! zig/testing/vectors/graph.txt, converters included.
//!
//! Frames are copied in by `send` and come out of `receive` in FFmpeg's
//! counts, sizes and timestamps; `finishInput` ends the input, after which
//! `receive` drains the chain (aresample flushes) and reports `drained`.
//! A received frame stays valid until the next call on the graph.

const std = @import("std");
const audio = @import("../core/audio.zig");
const channel_layout = @import("../core/channel_layout.zig");
const time = @import("../core/time.zig");
const stage = @import("../core/stage.zig");
const diagnostics = @import("../core/diagnostics.zig");
const Frame = @import("../core/frame.zig").Frame;
const formats = @import("formats.zig");
const filters = @import("filters.zig");
const parse = @import("parse.zig");
const Layout = channel_layout.Layout;
const Channel = channel_layout.Channel;
const SampleFormat = audio.SampleFormat;
const Pool = formats.Pool;
const Kind = formats.Kind;
const Owned = filters.Owned;

pub const Option = filters.Option;

/// The buffer source: the format of every frame sent, and their time base
/// (1 / rate when null).
pub const SourceSpec = struct {
    format: audio.Format,
    time_base: ?time.TimeBase = null,
};

/// The buffer sink's lists (abuffersink's `sample_formats`, `samplerates`
/// and `channel_layouts`); an empty one takes anything.
pub const SinkSpec = struct {
    sample_formats: []const SampleFormat = &.{},
    sample_rates: []const u32 = &.{},
    layouts: []const Layout = &.{},
};

/// A filter of the chain: FFmpeg's name, its options, and the instance's
/// name (the filter's name when null).
pub const FilterSpec = struct {
    name: []const u8,
    options: []const Option = &.{},
    label: ?[]const u8 = null,
};

pub const Options = struct {
    /// The options of the converters configuration inserts
    /// (`aresample_swr_opts`).
    converter: []const Option = &.{},
    /// Where FFmpeg's messages go; none by default.
    diagnostics: ?diagnostics.Sink = null,
};

pub const InitError = filters.CreateError || error{
    /// More than libswresample's 64 channels.
    LimitExceeded,
    /// Filtergraph text FFmpeg refuses (parse.zig).
    InvalidSyntax,
    /// Link labels or several chains (TODO.md T25c).
    UnsupportedSyntax,
};

pub const ConfigureError = filters.CreateError || filters.VolumeRun.Error || filters.ResampleRun.Error || formats.CheckError || error{
    /// "Impossible to convert between the formats supported by the
    /// filter ... and the filter ...".
    CannotConvert,
    /// "Cannot select sample rate" or "Cannot select channel layout".
    CannotSelect,
    /// `configure` was called before.
    AlreadyConfigured,
};

pub const SendError = stage.SendError || error{
    NotConfigured,
    /// The frame's format is not the source's ("Changing audio frame
    /// properties on the fly is not supported").
    FormatChange,
    /// A frame of no samples; the port refuses it.
    EmptyFrame,
    /// The graph's output has ended (atrim's end), as
    /// `av_buffersrc_add_frame`'s `AVERROR_EOF`.
    GraphEnded,
    OutOfMemory,
};

pub const ReceiveError = filters.ResampleRun.Error || filters.VolumeRun.Error || error{NotConfigured};

const Node = struct {
    /// The instance's name, owned.
    label: []u8,
    kind: union(enum) {
        source,
        sink,
        filter: filters.Filter,
    },
    input: ?u32 = null,
    output: ?u32 = null,
    run: Run = .none,
    /// aresample: the end of its input was flushed.
    ended: bool = false,
    /// The frames the filter has taken (its input's `frame_count_out`).
    frames_in: u64 = 0,
};

const Run = union(enum) {
    none,
    volume: filters.VolumeRun,
    resample: filters.ResampleRun,
    trim: filters.TrimRun,
    setpts: filters.SetPtsRun,
};

/// A link between two nodes and, once configured, its format.
pub const Link = struct {
    src: u32,
    dst: u32,
    sample_format: SampleFormat = undefined,
    sample_rate: u32 = 0,
    layout: Layout = undefined,
    time_base: time.TimeBase = undefined,
    picked: bool = false,

    pub fn format(l: *const Link) audio.Format {
        return .{ .sample_rate = l.sample_rate, .layout = l.layout, .sample_format = l.sample_format };
    }
};

const Pull = union(enum) {
    frame: Owned,
    need_input,
    eof,
};

pub const Graph = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    links: std.ArrayList(Link) = .empty,
    source: SourceSpec,
    source_time_base: time.TimeBase,
    /// The sink's lists, owned.
    sink_formats: []SampleFormat = &.{},
    sink_rates: []u32 = &.{},
    sink_layouts: []Layout = &.{},
    /// The converter options, owned, in one buffer.
    converter: []Option = &.{},
    converter_text: []u8 = &.{},
    diagnostics: ?diagnostics.Sink,
    /// `configure` was called; a failed configuration is not retried.
    configure_called: bool = false,
    configured: bool = false,
    pending: ?Owned = null,
    last: ?Owned = null,
    input_ended: bool = false,
    drained: bool = false,

    /// Creates the source, the chain's filters with their options, and
    /// the sink, linked in that order.
    pub fn init(gpa: std.mem.Allocator, source: SourceSpec, chain: []const FilterSpec, sink: SinkSpec, opts: Options) InitError!Graph {
        var g = try start(gpa, source, sink, opts);
        errdefer g.deinit();
        try g.addNode("in", .source);
        for (chain) |spec| {
            var f = try filters.Filter.create(gpa, spec.name, spec.options, opts.diagnostics);
            g.addNode(spec.label orelse spec.name, .{ .filter = f }) catch |err| {
                f.deinit(gpa);
                return err;
            };
        }
        try g.addNode("out", .sink);
        for (0..g.nodes.items.len - 1) |i| try g.addLink(@intCast(i), @intCast(i + 1));
        return g;
    }

    /// The chain of filtergraph `text` (parse.zig) between the source and
    /// the sink, as `avfilter_graph_parse_ptr` builds it with them created
    /// first: every filter created (`Parsed_<name>_<n>`, or
    /// `<name>@<instance>`), then every filter's options set, an unknown
    /// option failing only once all are set, then every filter
    /// initialized. Link labels and several chains are `UnsupportedSyntax`
    /// (T25c).
    pub fn initText(gpa: std.mem.Allocator, source: SourceSpec, text: []const u8, sink: SinkSpec, opts: Options) InitError!Graph {
        var g = try start(gpa, source, sink, opts);
        errdefer g.deinit();
        try g.addNode("in", .source);
        try g.addNode("out", .sink);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const parsed = parse.parse(arena.allocator(), text, opts.diagnostics) catch |err| return switch (err) {
            error.InvalidSyntax => error.InvalidSyntax,
            error.OutOfMemory => error.OutOfMemory,
        };
        for (parsed.filters, 0..) |pf, i| {
            var f = filters.Filter.alloc(pf.name) catch |err| {
                diagnostics.report(opts.diagnostics, .err, "No such filter: '{s}'", .{pf.name});
                return err;
            };
            const label = if (pf.instance) |inst|
                try arena.allocator().print("{s}@{s}", .{ pf.name, inst })
            else
                try arena.allocator().print("Parsed_{s}_{d}", .{ pf.name, i });
            g.addNode(label, .{ .filter = f }) catch |err| {
                f.deinit(gpa);
                return err;
            };
        }
        if (parsed.labels or parsed.chains > 1) return error.UnsupportedSyntax;
        // avfilter_graph_segment_apply_opts.
        var unknown: ?Option = null;
        for (parsed.filters, 2..) |pf, node| {
            const f = &g.nodes.items[node].kind.filter;
            for (pf.options) |o| {
                f.set(gpa, o.name, o.value) catch |err| switch (err) {
                    error.UnknownOption => {
                        if (unknown == null) unknown = o;
                    },
                    else => |e| return e,
                };
            }
        }
        if (unknown) |o| {
            diagnostics.report(opts.diagnostics, .err, "Could not set non-existent option '{s}' to value '{s}'", .{ o.name, o.value });
            return error.UnknownOption;
        }
        for (2..g.nodes.items.len) |node| try g.nodes.items[node].kind.filter.init(gpa, opts.diagnostics);
        // The source to the first filter, along the chain, the last to the sink.
        var prev: u32 = 0;
        for (2..g.nodes.items.len) |node| {
            try g.addLink(prev, @intCast(node));
            prev = @intCast(node);
        }
        try g.addLink(prev, 1);
        return g;
    }

    /// A graph with no nodes yet, the sink's lists and the converter
    /// options copied.
    fn start(gpa: std.mem.Allocator, source: SourceSpec, sink: SinkSpec, opts: Options) InitError!Graph {
        if (source.format.channelCount() > 64) return error.LimitExceeded;
        // abuffersink's rates are ints.
        for (sink.sample_rates) |r| {
            if (r == 0 or r > std.math.maxInt(i32)) return error.OutOfRange;
        }
        var g: Graph = .{
            .gpa = gpa,
            .source = source,
            .source_time_base = source.time_base orelse time.TimeBase.ofSampleRate(source.format.sample_rate) catch unreachable,
            .diagnostics = opts.diagnostics,
        };
        errdefer g.deinit();
        g.sink_formats = try gpa.dupe(SampleFormat, sink.sample_formats);
        g.sink_rates = try gpa.dupe(u32, sink.sample_rates);
        g.sink_layouts = try gpa.dupe(Layout, sink.layouts);
        var text_len: usize = 0;
        for (opts.converter) |o| text_len += o.name.len + o.value.len;
        g.converter_text = try gpa.alloc(u8, text_len);
        g.converter = try gpa.alloc(Option, opts.converter.len);
        var at: usize = 0;
        for (opts.converter, g.converter) |o, *copy| {
            @memcpy(g.converter_text[at..][0..o.name.len], o.name);
            copy.name = g.converter_text[at..][0..o.name.len];
            at += o.name.len;
            @memcpy(g.converter_text[at..][0..o.value.len], o.value);
            copy.value = g.converter_text[at..][0..o.value.len];
            at += o.value.len;
        }
        return g;
    }

    pub fn deinit(g: *Graph) void {
        for (g.nodes.items) |*n| {
            g.gpa.free(n.label);
            switch (n.kind) {
                .filter => |*f| f.deinit(g.gpa),
                else => {},
            }
            switch (n.run) {
                .resample => |*r| r.deinit(),
                .volume => |*v| v.deinit(),
                .setpts => |*r| r.deinit(),
                .none, .trim => {},
            }
        }
        g.nodes.deinit(g.gpa);
        g.links.deinit(g.gpa);
        g.gpa.free(g.sink_formats);
        g.gpa.free(g.sink_rates);
        g.gpa.free(g.sink_layouts);
        g.gpa.free(g.converter);
        g.gpa.free(g.converter_text);
        if (g.pending) |*p| p.free(g.gpa);
        if (g.last) |*l| l.free(g.gpa);
        g.* = undefined;
    }

    fn addNode(g: *Graph, label: []const u8, kind: @FieldType(Node, "kind")) error{OutOfMemory}!void {
        const copy = try g.gpa.dupe(u8, label);
        errdefer g.gpa.free(copy);
        try g.nodes.append(g.gpa, .{ .label = copy, .kind = kind });
    }

    fn addLink(g: *Graph, src: u32, dst: u32) error{OutOfMemory}!void {
        try g.links.append(g.gpa, .{ .src = src, .dst = dst });
        const index: u32 = @intCast(g.links.items.len - 1);
        g.nodes.items[src].output = index;
        g.nodes.items[dst].input = index;
    }

    /// The nodes from the source to the sink, as configured: for each, its
    /// name and the link that leaves it (null for the sink).
    pub fn chainIterator(g: *const Graph) ChainIterator {
        return .{ .graph = g, .node = 0 };
    }

    pub const ChainIterator = struct {
        graph: *const Graph,
        node: ?u32,

        pub fn next(it: *ChainIterator) ?struct { label: []const u8, link: ?*const Link } {
            const index = it.node orelse return null;
            const n = &it.graph.nodes.items[index];
            const link: ?*const Link = if (n.output) |o| &it.graph.links.items[o] else null;
            it.node = if (link) |l| l.dst else null;
            return .{ .label = n.label, .link = link };
        }
    };

    /// The link into the sink: the output's format and time base.
    pub fn outputLink(g: *const Graph) *const Link {
        return &g.links.items[g.nodes.items[g.sinkIndex()].input.?];
    }

    fn sinkIndex(g: *const Graph) u32 {
        for (g.nodes.items, 0..) |n, i| {
            if (n.kind == .sink) return @intCast(i);
        }
        unreachable; // init adds it
    }

    // Configuration ---------------------------------------------------------

    /// `avfilter_graph_config`: negotiates every link's format, inserting
    /// converters, then configures the filters.
    pub fn configure(g: *Graph) ConfigureError!void {
        if (g.configure_called) return error.AlreadyConfigured;
        g.configure_called = true;
        var arena: std.heap.ArenaAllocator = .init(g.gpa);
        defer arena.deinit();
        var pool: Pool = .init(arena.allocator());
        for (g.links.items) |_| _ = try pool.addLink();
        try g.queryAll(&pool);
        try g.reduce(&pool);
        g.swapSampleFormats(&pool);
        g.swapRates(&pool);
        g.swapLayouts(&pool);
        try g.pickAll(&pool);
        try g.configLinks();
        g.configured = true;
    }

    /// `query_formats`: each filter's lists, then the merges along links,
    /// converters inserted where they fail.
    fn queryAll(g: *Graph, pool: *Pool) ConfigureError!void {
        for (0..g.nodes.items.len) |i| try g.query(pool, @intCast(i));
        var converters: u32 = 0;
        retry: while (true) {
            for (0..g.nodes.items.len) |i| {
                const input = g.nodes.items[i].input orelse continue;
                if (try g.mergeLink(pool, input, &converters)) continue :retry;
            }
            break;
        }
    }

    /// The merges of one link; inserts a converter and returns true when
    /// they cannot all be made.
    fn mergeLink(g: *Graph, pool: *Pool, link: u32, converters: *u32) ConfigureError!bool {
        const kinds = [_]Kind{ .layouts, .samplerates, .formats };
        var convert = false;
        for (kinds) |kind| {
            const a = pool.slot(link, .in, kind).* orelse continue;
            const b = pool.slot(link, .out, kind).* orelse continue;
            if (a != b and !try pool.canMerge(kind, a, b)) convert = true;
        }
        for (kinds) |kind| {
            // The check may have merged layouts already.
            const a = pool.slot(link, .in, kind).* orelse continue;
            const b = pool.slot(link, .out, kind).* orelse continue;
            if (a == b or convert) continue;
            if (!try pool.merge(kind, a, b)) convert = true;
        }
        if (!convert) return false;
        try g.insertConverter(pool, link, converters);
        return true;
    }

    /// `avfilter_insert_filter` of `auto_aresample_<n>` on `link`, its
    /// lists merged with both sides at once.
    fn insertConverter(g: *Graph, pool: *Pool, link: u32, converters: *u32) ConfigureError!void {
        var name_buffer: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "auto_aresample_{d}", .{converters.*}) catch unreachable;
        converters.* += 1;
        {
            var f = try filters.Filter.create(g.gpa, "aresample", g.converter, g.diagnostics);
            g.addNode(name, .{ .filter = f }) catch |err| {
                f.deinit(g.gpa);
                return err;
            };
        }
        const conv: u32 = @intCast(g.nodes.items.len - 1);
        const dst = g.links.items[link].dst;
        try g.links.append(g.gpa, .{ .src = conv, .dst = dst });
        const after: u32 = @intCast(g.links.items.len - 1);
        _ = try pool.addLink();
        g.links.items[link].dst = conv;
        g.nodes.items[conv].input = link;
        g.nodes.items[conv].output = after;
        g.nodes.items[dst].input = after;
        // The destination's lists move to the new link.
        pool.cfg(after, .out).* = pool.cfg(link, .out).*;
        pool.cfg(link, .out).* = .{};
        try g.query(pool, conv);
        for ([_]Kind{ .layouts, .samplerates, .formats }) |kind| {
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

    /// `SET_COMMON_FORMATS`: `id` on every side of the node that has no
    /// list of the kind yet.
    fn setCommon(g: *Graph, pool: *Pool, node: u32, kind: Kind, id: formats.Id) void {
        const n = &g.nodes.items[node];
        if (n.input) |l| {
            const s = pool.slot(l, .out, kind);
            if (s.* == null) s.* = id;
        }
        if (n.output) |l| {
            const s = pool.slot(l, .in, kind);
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

    /// `filter_query_formats`: the node's own lists, checked, then
    /// `ff_default_query_formats` for the rest: every format, rate and
    /// channel count, one list shared by the node's sides.
    fn query(g: *Graph, pool: *Pool, node: u32) ConfigureError!void {
        const n = &g.nodes.items[node];
        var checks = true;
        switch (n.kind) {
            .source => {
                const f = g.source.format;
                g.setCommon(pool, node, .formats, try pool.newValues(&.{f.sample_format.ffmpegId()}));
                g.setCommon(pool, node, .samplerates, try pool.newValues(&.{@intCast(f.sample_rate)}));
                g.setCommon(pool, node, .layouts, try layoutList(pool, &.{f.layout}));
            },
            .sink => {
                if (g.sink_formats.len > 0) {
                    var ids: std.ArrayList(i32) = .empty;
                    for (g.sink_formats) |f| try ids.append(pool.arena, f.ffmpegId());
                    g.setCommon(pool, node, .formats, try pool.newValues(ids.items));
                }
                if (g.sink_rates.len > 0) {
                    var rates: std.ArrayList(i32) = .empty;
                    for (g.sink_rates) |r| try rates.append(pool.arena, @intCast(r));
                    g.setCommon(pool, node, .samplerates, try pool.newValues(rates.items));
                }
                if (g.sink_layouts.len > 0) g.setCommon(pool, node, .layouts, try layoutList(pool, g.sink_layouts));
            },
            .filter => |*f| switch (f.*) {
                // No format query: every format, rate and layout.
                .anull, .atrim, .asetpts => checks = false,
                .aformat => |*a| {
                    if (a.formats.items.len > 0) g.setCommon(pool, node, .formats, try pool.newValues(a.formatList()));
                    if (a.rates.items.len > 0) g.setCommon(pool, node, .samplerates, try pool.newValues(a.rates.items));
                    if (a.layouts.items.len > 0) g.setCommon(pool, node, .layouts, try layoutList(pool, a.layouts.items));
                },
                .volume => |*v| g.setCommon(pool, node, .formats, try formatIds(pool, filters.VolumeRun.formats(v.rest.precision))),
                .aresample => |*a| {
                    const all = formats.allFormats();
                    const in = n.input.?;
                    const out = n.output.?;
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
            },
        }
        if (checks) try g.checkNode(pool, node);
        // ff_default_query_formats.
        const all = formats.allFormats();
        g.setCommon(pool, node, .formats, try pool.newValues(&all));
        g.setCommon(pool, node, .layouts, try pool.newLayouts(&.{}, true));
        g.setCommon(pool, node, .samplerates, try pool.newValues(&.{}));
    }

    /// `filter_check_formats`: the node's lists of its own.
    fn checkNode(g: *Graph, pool: *Pool, node: u32) formats.CheckError!void {
        const n = &g.nodes.items[node];
        const sides = [_]?struct { link: u32, side: formats.Side }{
            if (n.input) |l| .{ .link = l, .side = .out } else null,
            if (n.output) |l| .{ .link = l, .side = .in } else null,
        };
        for (sides) |maybe| {
            const s = maybe orelse continue;
            const c = pool.cfg(s.link, s.side);
            if (c.formats) |id| try pool.checkValues(id, false);
            if (c.samplerates) |id| try pool.checkValues(id, true);
            if (c.layouts) |id| try pool.checkLayouts(id);
        }
    }

    /// `reduce_formats`: a filter whose input has one format gives it to
    /// its output when the output's list has it, until nothing changes.
    fn reduce(g: *Graph, pool: *Pool) error{OutOfMemory}!void {
        while (true) {
            var reduced = false;
            for (g.nodes.items) |*n| {
                const in = n.input orelse continue;
                const out = n.output orelse continue;
                for ([_]Kind{ .formats, .samplerates }) |kind| {
                    const in_list = pool.values(pool.slot(in, .out, kind).* orelse continue);
                    if (in_list.items.len != 1) continue;
                    const value = in_list.items[0];
                    const out_list = pool.values(pool.slot(out, .in, kind).*.?);
                    if (out_list.items.len == 1) continue;
                    if (out_list.items.len == 0) {
                        try out_list.append(pool.arena, value);
                        reduced = true;
                        continue;
                    }
                    if (std.mem.findScalar(i32, out_list.items, value) != null) {
                        out_list.items[0] = value;
                        out_list.shrinkRetainingCapacity(1);
                        reduced = true;
                    }
                }
                const in_layouts = pool.layouts(pool.slot(in, .out, .layouts).* orelse continue);
                if (in_layouts.items.items.len != 1) continue;
                const layout = in_layouts.items.items[0];
                const out_layouts = pool.layouts(pool.slot(out, .in, .layouts).*.?);
                if (out_layouts.items.items.len == 1) continue;
                if (out_layouts.all) {
                    // Every channel count, so the layout whether known or not.
                    out_layouts.all = false;
                    try out_layouts.items.append(pool.arena, layout);
                    reduced = true;
                    continue;
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
            if (!reduced) return;
        }
    }

    /// The node's input format list when it holds one entry.
    fn singleInput(pool: *Pool, n: *const Node, kind: Kind) ?i32 {
        const in = n.input orelse return null;
        const list = pool.values(pool.slot(in, .out, kind).*.?);
        return if (list.items.len == 1) list.items[0] else null;
    }

    /// `swap_sample_fmts`: the output format closest to the input's first.
    fn swapSampleFormats(g: *Graph, pool: *Pool) void {
        for (g.nodes.items) |*n| {
            const format_id = singleInput(pool, n, .formats) orelse continue;
            const format = SampleFormat.fromFfmpegId(format_id).?;
            const bps: i32 = format.bytesPerSample();
            const out = n.output orelse continue;
            const list = pool.values(pool.slot(out, .in, .formats).*.?);
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

    /// `swap_samplerates`: the output rate closest to the input's first.
    fn swapRates(g: *Graph, pool: *Pool) void {
        for (g.nodes.items) |*n| {
            const rate = singleInput(pool, n, .samplerates) orelse continue;
            const out = n.output orelse continue;
            const list = pool.values(pool.slot(out, .in, .samplerates).*.?);
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

    /// `swap_channel_layouts`: the output layout that best matches the
    /// input's, first.
    fn swapLayouts(g: *Graph, pool: *Pool) void {
        for (g.nodes.items) |*n| {
            const in = n.input orelse continue;
            const in_list = pool.layouts(pool.slot(in, .out, .layouts).*.?);
            if (in_list.items.items.len != 1) continue;
            const out = n.output orelse continue;
            const list = pool.layouts(pool.slot(out, .in, .layouts).*.?);
            if (list.items.items.len < 2) continue;
            const in_layout = &in_list.items.items[0];
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

    /// `pick_formats`: links with one format first, then the outputs of
    /// filters whose input is picked, chosen against it, then the rest.
    fn pickAll(g: *Graph, pool: *Pool) ConfigureError!void {
        while (true) {
            var change = false;
            for (g.nodes.items) |*n| {
                for ([_]?u32{ n.input, n.output }) |maybe| {
                    const l = maybe orelse continue;
                    const id = pool.slot(l, .in, .formats).* orelse continue;
                    if (pool.values(id).items.len == 1) {
                        try g.pick(pool, l, null);
                        change = true;
                    }
                }
                if (n.input) |in| if (n.output) |out| {
                    if (g.links.items[in].picked and !g.links.items[out].picked) {
                        try g.pick(pool, out, in);
                        change = true;
                    }
                };
            }
            if (!change) break;
        }
        for (g.nodes.items) |*n| {
            if (n.input) |l| try g.pick(pool, l, null);
            if (n.output) |l| try g.pick(pool, l, null);
        }
    }

    /// `pick_format`: the link's format, rate and layout, the first of
    /// each list (the sample format chosen against `ref`'s, when given);
    /// the link's lists are then dropped.
    fn pick(g: *Graph, pool: *Pool, link: u32, ref: ?u32) ConfigureError!void {
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

    /// `graph_config_links`, from the source down: each link's time base
    /// and the filter that feeds it.
    fn configLinks(g: *Graph) ConfigureError!void {
        var node: u32 = 0;
        while (g.nodes.items[node].output) |out| : (node = g.links.items[out].dst) {
            const l = &g.links.items[out];
            const n = &g.nodes.items[node];
            switch (n.kind) {
                .source => {
                    l.time_base = g.source_time_base;
                    continue;
                },
                .sink => unreachable,
                .filter => {},
            }
            const in = &g.links.items[n.input.?];
            l.time_base = in.time_base;
            switch (n.kind.filter) {
                .volume => |*v| {
                    const run = try filters.VolumeRun.init(v, in.format(), in.time_base, g.diagnostics);
                    n.run = .{ .volume = run };
                },
                .aresample => |a| {
                    // Built first: assigning the union while `init` runs
                    // would leave its tag set on failure.
                    const run = try filters.ResampleRun.init(g.gpa, a, in.format(), l.format(), in.time_base, g.diagnostics);
                    n.run = .{ .resample = run };
                    l.time_base = time.TimeBase.ofSampleRate(l.sample_rate) catch unreachable;
                },
                .atrim => |a| n.run = .{ .trim = .init(a, in.format(), in.time_base) },
                .asetpts => |*a| n.run = .{ .setpts = .init(a, in.format(), in.time_base) },
                else => {},
            }
        }
    }

    // Frames ----------------------------------------------------------------

    /// The source's layout once configured: an unspecified one takes its
    /// link's (`config_props`).
    fn sourceLayout(g: *const Graph) Layout {
        return g.links.items[g.nodes.items[0].output.?].layout;
    }

    /// Copies `frame` into the graph; `.full` when the previous frame has
    /// not gone in yet, and `receive` must come first.
    pub fn send(g: *Graph, frame: Frame) SendError!stage.Send {
        if (!g.configured) return error.NotConfigured;
        if (g.input_ended) return error.InputAfterEnd;
        if (g.drained) return error.GraphEnded;
        if (g.pending != null) return .full;
        g.freeLast();
        const want = g.source.format;
        const layout = g.sourceLayout();
        var frame_layout = frame.format.layout;
        // An unspecified layout of the count takes the source's.
        if (frame_layout == .unspecified and frame_layout.channelCount() == layout.channelCount()) frame_layout = layout;
        if (frame.format.sample_rate != want.sample_rate or frame.format.sample_format != want.sample_format or !frame_layout.eql(&layout))
            return error.FormatChange;
        const count = std.math.cast(u32, frame.frameCount()) orelse return error.OutOfMemory;
        if (count == 0) return error.EmptyFrame;
        var format = frame.format;
        format.layout = layout;
        const owned = try Owned.alloc(g.gpa, format, count, frame.pts);
        @memcpy(owned.data, frame.data);
        g.pending = owned;
        return .accepted;
    }

    /// Ends the input (`av_buffersrc_add_frame(NULL)`). Idempotent.
    pub fn finishInput(g: *Graph) void {
        g.input_ended = true;
    }

    /// The next output frame, `need_input` when the chain needs a frame
    /// sent, or `drained` once the input has ended and everything came out.
    pub fn receive(g: *Graph) ReceiveError!stage.Receive(Frame) {
        if (!g.configured) return error.NotConfigured;
        g.freeLast();
        if (g.drained) return .drained;
        const sink = &g.nodes.items[g.sinkIndex()];
        switch (try g.pull(g.links.items[sink.input.?].src)) {
            .frame => |o| {
                g.last = o;
                return .{ .output = .{ .format = o.format, .data = o.data, .pts = o.pts } };
            },
            .need_input => return .need_input,
            .eof => {
                g.drained = true;
                return .drained;
            },
        }
    }

    fn freeLast(g: *Graph) void {
        if (g.last) |*l| l.free(g.gpa);
        g.last = null;
    }

    /// The next frame out of `node`, pulled through its upstream.
    fn pull(g: *Graph, node: u32) ReceiveError!Pull {
        const n = &g.nodes.items[node];
        switch (n.kind) {
            .source => {
                if (g.pending) |p| {
                    g.pending = null;
                    return .{ .frame = p };
                }
                return if (g.input_ended) .eof else .need_input;
            },
            .sink => unreachable,
            .filter => {},
        }
        const upstream = g.links.items[n.input.?].src;
        switch (n.run) {
            .none => return g.pull(upstream),
            .volume => |*v| {
                const r = try g.pull(upstream);
                if (r == .frame) {
                    var frame = r.frame;
                    v.filterFrame(frame.data, frame.frameCount(), frame.pts, n.frames_in) catch |err| {
                        frame.free(g.gpa);
                        return err;
                    };
                    n.frames_in += 1;
                }
                return r;
            },
            .trim => |*t| {
                while (true) {
                    if (t.eof) return .eof;
                    switch (try g.pull(upstream)) {
                        .frame => |in| {
                            var frame = in;
                            defer frame.free(g.gpa);
                            if (try t.filterFrame(g.gpa, &frame)) |o| return .{ .frame = o };
                        },
                        .need_input => return .need_input,
                        .eof => return .eof,
                    }
                }
            },
            .setpts => |*r| {
                var result = try g.pull(upstream);
                if (result == .frame) result.frame.pts = r.filterFrame(result.frame.pts, result.frame.frameCount());
                return result;
            },
            .resample => |*r| {
                // aresample's activate: buffered output, then input, then
                // the flush at the end.
                if (r.more()) {
                    if (try r.flush(false)) |o| return .{ .frame = o };
                    r.clearMore();
                }
                while (true) {
                    switch (try g.pull(upstream)) {
                        .frame => |in| {
                            var frame = in;
                            defer frame.free(g.gpa);
                            if (try r.filterFrame(&frame)) |o| return .{ .frame = o };
                        },
                        .need_input => return .need_input,
                        .eof => {
                            if (!n.ended) {
                                if (try r.flush(true)) |o| return .{ .frame = o };
                                n.ended = true;
                            }
                            return .eof;
                        },
                    }
                }
            },
        }
    }
};

/// `find_best_sample_fmt_of_2`: the lower `get_fmt_score`, the second on a
/// tie; -1 is no format.
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

const testing = std.testing;

test "a filter that cannot take the source's format gets a converter before it" {
    const gpa = testing.allocator;
    const format = try audio.Format.init(44100, 2, .s16);
    var g = try Graph.init(gpa, .{ .format = format }, &.{.{ .name = "volume", .options = &.{.{ .name = "volume", .value = "0.5" }}, .label = "f0" }}, .{}, .{});
    defer g.deinit();
    try g.configure();
    var it = g.chainIterator();
    const labels = [_][]const u8{ "in", "auto_aresample_0", "f0", "out" };
    const sample_formats = [_]SampleFormat{ .s16, .flt, .flt };
    var i: usize = 0;
    while (it.next()) |step| : (i += 1) {
        try testing.expectEqualStrings(labels[i], step.label);
        if (step.link) |l| try testing.expectEqual(sample_formats[i], l.sample_format);
    }
    try testing.expectEqual(4, i);
}

test "frames go through the chain and the end drains it" {
    const gpa = testing.allocator;
    const format = try audio.Format.init(8000, 1, .s16);
    var g = try Graph.init(gpa, .{ .format = format }, &.{.{ .name = "volume", .options = &.{ .{ .name = "volume", .value = "2" }, .{ .name = "precision", .value = "fixed" } } }}, .{}, .{});
    defer g.deinit();
    try g.configure();
    const values = [_]i16{ 1, -2, 30000 };
    try testing.expectEqual(stage.Send.accepted, try g.send(try Frame.fromS16(format, &values, 5)));
    try testing.expectEqual(stage.Send.full, try g.send(try Frame.fromS16(format, &values, 8)));
    const r = try g.receive();
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]i16{ 2, -4, 32767 }), r.output.data);
    try testing.expectEqual(5, r.output.pts);
    try testing.expectEqual(.need_input, try g.receive());
    g.finishInput();
    try testing.expectEqual(.drained, try g.receive());
    try testing.expectError(error.InputAfterEnd, g.send(try Frame.fromS16(format, &values, 8)));
    const other = try audio.Format.init(8000, 2, .s16);
    var g2 = try Graph.init(gpa, .{ .format = format }, &.{}, .{}, .{});
    defer g2.deinit();
    try testing.expectError(error.NotConfigured, g2.send(try Frame.fromS16(format, &values, 0)));
    try g2.configure();
    try testing.expectError(error.FormatChange, g2.send(try Frame.fromS16(other, &.{ 1, 2 }, 0)));
}

fn runChain(gpa: std.mem.Allocator) !void {
    const format = try audio.Format.init(44100, 2, .s16);
    var g = try Graph.init(gpa, .{ .format = format }, &.{
        .{ .name = "aformat", .options = &.{.{ .name = "cl", .value = "mono" }} },
        .{ .name = "volume", .options = &.{.{ .name = "volume", .value = "0.5" }} },
        .{ .name = "aresample", .options = &.{.{ .name = "sample_rate", .value = "48000" }} },
    }, .{ .sample_formats = &.{.s16} }, .{ .converter = &.{.{ .name = "dither_method", .value = "triangular" }} });
    defer g.deinit();
    try g.configure();
    var values: [600]i16 = undefined;
    for (&values, 0..) |*v, i| {
        const step: i32 = @intCast(i * 97 % 2000);
        v.* = @intCast(step - 1000);
    }
    for (0..2) |i| {
        _ = try g.send(try Frame.fromS16(format, values[0 .. 200 + 200 * i], null));
        while (try g.receive() == .output) {}
    }
    g.finishInput();
    while (try g.receive() == .output) {}
}

test "a graph leaks nothing when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, runChain, .{});
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [256]u8 = undefined;
    const len = smith.slice(&input);
    if (len < 2) return;
    // The first byte picks a filter and an option; the rest is its value.
    const names = [_][2][]const u8{
        .{ "aformat", "f" },             .{ "aformat", "r" },        .{ "aformat", "cl" },
        .{ "volume", "volume" },         .{ "volume", "precision" }, .{ "aresample", "sample_rate" },
        .{ "aresample", "osf" },         .{ "aresample", "ochl" },   .{ "aresample", "dither_method" },
        .{ "aresample", "filter_size" }, .{ "aresample", "cutoff" }, .{ "aresample", "phase_shift" },
    };
    const pick = names[input[0] % names.len];
    const gpa = testing.allocator;
    const format = try audio.Format.init(8000, 2, .s16);
    var g = Graph.init(gpa, .{ .format = format }, &.{.{ .name = pick[0], .options = &.{.{ .name = pick[1], .value = input[1..len] }} }}, .{}, .{}) catch return;
    defer g.deinit();
    // Any configuration error is acceptable; nothing may crash or leak.
    g.configure() catch return;
    const values = [_]i16{ 1, 2, 3, 4 };
    _ = try g.send(try Frame.fromS16(format, &values, 0));
    while ((g.receive() catch return) == .output) {}
}

test "fuzz: arbitrary option text never crashes a graph" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "\x00s16|flt",
        "\x028000|44100",
        "\x02stereo|5.1",
        "\x030.5",
        "\x05-1",
        "\x07FL+FR+LFE",
        "\x0911",
    } });
}

fn fuzzText(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [256]u8 = undefined;
    const len = smith.slice(&input);
    const gpa = testing.allocator;
    const format = try audio.Format.init(8000, 2, .s16);
    var g = Graph.initText(gpa, .{ .format = format }, input[0..len], .{}, .{}) catch return;
    defer g.deinit();
    // Any error is acceptable; nothing may crash or leak.
    g.configure() catch return;
    const values = [_]i16{ 1, 2, 3, 4 };
    _ = try g.send(try Frame.fromS16(format, &values, 0));
    while ((g.receive() catch return) == .output) {}
}

test "fuzz: arbitrary filtergraph text never crashes a graph" {
    try std.testing.fuzz({}, fuzzText, .{ .corpus = &.{
        "volume=0.5:fixed,aformat=s16p|flt:44100:mono",
        "aresample=48000:osf=s16p, volume@a='if(lt(t,1),n,2)':eval=frame",
        "[a]anull[b];volume",
        "sws_flags=x;volume=1\\,5",
        "atrim=0.001:duration=2ms,asetpts=N/SR/TB",
    } });
}

fn textChain(gpa: std.mem.Allocator) !void {
    const format = try audio.Format.init(44100, 2, .s16);
    var g = try Graph.initText(gpa, .{ .format = format }, "atrim=start_sample=50:end_sample=700,asetpts=PTS-STARTPTS,aformat=cl=mono, volume=n+0.5:eval=frame , aresample=48000", .{ .sample_formats = &.{.s16} }, .{});
    defer g.deinit();
    try g.configure();
    var values: [400]i16 = @splat(100);
    _ = try g.send(try Frame.fromS16(format, &values, 0));
    while (try g.receive() == .output) {}
    g.finishInput();
    while (try g.receive() == .output) {}
}

test "a graph from text leaks nothing when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, textChain, .{});
}

// zig/testing/vectors/graph.txt comes from the pinned FFmpeg's libavfilter
// through zig/testing/reference/graph_vectors.c, which documents its
// lines. Every case is run, and the count makes a truncated file fail.
const vectors = @embedFile("../testing/vectors/graph.txt");
const case_count = 178;
const resample = @import("../resample/resample.zig");
const native_endian = @import("builtin").cpu.arch.endian();

fn hexText(buffer: []u8, hex: []const u8) ![]const u8 {
    if (std.mem.eql(u8, hex, "-")) return "";
    if (hex.len / 2 > buffer.len) return error.MalformedVector;
    return std.fmt.hexToBytes(buffer[0 .. hex.len / 2], hex);
}

/// graph_vectors.c's `store`: the generator's value in `format`, rounded as
/// `lrint` rounds.
fn storeGenerated(bytes: []u8, format: SampleFormat, v: f64) void {
    const rounded = struct {
        fn of(x: f64) i64 {
            const floor = @floor(x);
            const diff = x - floor;
            const up = diff > 0.5 or (diff == 0.5 and @mod(floor, 2) != 0);
            return @intFromFloat(if (up) floor + 1 else floor);
        }
    }.of;
    switch (format.packedForm()) {
        .u8 => bytes[0] = @intCast(rounded(v * 127 + 128)),
        .s16 => std.mem.writeInt(i16, bytes[0..2], @intCast(rounded(v * 32767)), native_endian),
        .s32 => std.mem.writeInt(i32, bytes[0..4], @intCast(rounded(v * 2147483647.0)), native_endian),
        .s64 => std.mem.writeInt(i64, bytes[0..8], rounded(v * 4611686018427387904.0), native_endian),
        .flt => {
            const f: f32 = @floatCast(v);
            std.mem.writeInt(u32, bytes[0..4], @bitCast(f), native_endian);
        },
        .dbl => std.mem.writeInt(u64, bytes[0..8], @bitCast(v), native_endian),
        else => unreachable,
    }
}

fn loadValue(bytes: []const u8, format: SampleFormat) f64 {
    return switch (format.packedForm()) {
        .u8 => @floatFromInt(bytes[0]),
        .s16 => @floatFromInt(std.mem.readInt(i16, bytes[0..2], native_endian)),
        .s32 => @floatFromInt(std.mem.readInt(i32, bytes[0..4], native_endian)),
        .s64 => @floatFromInt(std.mem.readInt(i64, bytes[0..8], native_endian)),
        .flt => @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], native_endian))),
        .dbl => @bitCast(std.mem.readInt(u64, bytes[0..8], native_endian)),
        else => unreachable,
    };
}

/// Runs one case's graph and checks every line after its definition.
fn runCase(gpa: std.mem.Allocator, lines: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var at: usize = 1;
    // S
    var fields = std.mem.tokenizeScalar(u8, lines[at], ' ');
    if (!std.mem.eql(u8, fields.next().?, "S")) return error.MalformedVector;
    const sample_format = SampleFormat.fromName(fields.next().?).?;
    const rate = try std.fmt.parseInt(u32, fields.next().?, 10);
    var buffer: [512]u8 = undefined;
    const layout = try Layout.parse(try hexText(&buffer, fields.next().?));
    const tb = try time.TimeBase.init(try std.fmt.parseInt(u32, fields.next().?, 10), try std.fmt.parseInt(u32, fields.next().?, 10));
    const format = try audio.Format.initLayout(rate, layout, sample_format);
    at += 1;
    // P
    var sizes: std.ArrayList(u32) = .empty;
    var ptss: std.ArrayList(?i64) = .empty;
    fields = std.mem.tokenizeScalar(u8, lines[at], ' ');
    _ = fields.next();
    while (fields.next()) |f| {
        const colon = std.mem.findScalar(u8, f, ':').?;
        try sizes.append(arena, try std.fmt.parseInt(u32, f[0..colon], 10));
        try ptss.append(arena, if (std.mem.eql(u8, f[colon + 1 ..], "-")) null else try std.fmt.parseInt(i64, f[colon + 1 ..], 10));
    }
    at += 1;
    // K
    fields = std.mem.tokenizeScalar(u8, lines[at], ' ');
    _ = fields.next();
    var sink: SinkSpec = .{};
    var sink_formats: std.ArrayList(SampleFormat) = .empty;
    var sink_rates: std.ArrayList(u32) = .empty;
    var sink_layouts: std.ArrayList(Layout) = .empty;
    for (0..3) |k| {
        const text = try arena.dupe(u8, try hexText(&buffer, fields.next().?));
        var items = std.mem.tokenizeScalar(u8, text, ',');
        while (items.next()) |item| switch (k) {
            0 => try sink_formats.append(arena, SampleFormat.fromName(item).?),
            1 => try sink_rates.append(arena, try std.fmt.parseInt(u32, item, 10)),
            else => try sink_layouts.append(arena, try Layout.parse(item)),
        };
    }
    sink = .{ .sample_formats = sink_formats.items, .sample_rates = sink_rates.items, .layouts = sink_layouts.items };
    at += 1;
    // V
    fields = std.mem.tokenizeScalar(u8, lines[at], ' ');
    _ = fields.next();
    var converter: std.ArrayList(Option) = .empty;
    {
        const text = try arena.dupe(u8, try hexText(&buffer, fields.next().?));
        var pairs = std.mem.tokenizeScalar(u8, text, ':');
        while (pairs.next()) |pair| {
            const eq = std.mem.findScalar(u8, pair, '=').?;
            try converter.append(arena, .{ .name = pair[0..eq], .value = pair[eq + 1 ..] });
        }
    }
    at += 1;
    // F, or T
    var text: ?[]const u8 = null;
    if (std.mem.startsWith(u8, lines[at], "T ")) {
        text = try arena.dupe(u8, try hexText(&buffer, lines[at][2..]));
        at += 1;
    }
    var chain: std.ArrayList(FilterSpec) = .empty;
    while (std.mem.startsWith(u8, lines[at], "F ")) : (at += 1) {
        fields = std.mem.tokenizeScalar(u8, lines[at], ' ');
        _ = fields.next();
        const name = fields.next().?;
        var opts: std.ArrayList(Option) = .empty;
        while (fields.next()) |pair| {
            const eq = std.mem.findScalar(u8, pair, '=').?;
            try opts.append(arena, .{ .name = pair[0..eq], .value = try arena.dupe(u8, try hexText(&buffer, pair[eq + 1 ..])) });
        }
        try chain.append(arena, .{ .name = name, .options = opts.items, .label = try arena.print("f{d}", .{chain.items.len}) });
    }
    const outcome = lines[at];
    var recorder: diagnostics.Recorder = .{};
    const graph_options: Options = .{ .converter = converter.items, .diagnostics = recorder.sink(.err) };
    const created = if (text) |t|
        Graph.initText(gpa, .{ .format = format, .time_base = tb }, t, sink, graph_options)
    else
        Graph.init(gpa, .{ .format = format, .time_base = tb }, chain.items, sink, graph_options);
    var g = created catch |err| {
        if (std.mem.eql(u8, outcome, "X")) {
            if (err != error.UnsupportedFunction and err != error.UnsupportedSyntax) return err;
            return;
        }
        if (std.mem.eql(u8, outcome, "E init")) return;
        if (std.mem.eql(u8, outcome, "E parse")) {
            // FFmpeg's first message, where the port reports one: the
            // syntax's and the expressions'; not av_opt_set's own.
            const want = try hexText(&buffer, lines[at + 1][2..]);
            if (recorder.count > 0) try testing.expectEqualStrings(want, recorder.firstMessage());
            return;
        }
        return err;
    };
    defer g.deinit();
    if (std.mem.eql(u8, outcome, "X") or std.mem.eql(u8, outcome, "E init") or std.mem.eql(u8, outcome, "E parse")) return error.TestUnexpectedResult;
    g.configure() catch |err| {
        if (std.mem.eql(u8, outcome, "E config")) return;
        return err;
    };
    // L
    var resampling = false;
    var it = g.chainIterator();
    while (it.next()) |step| {
        const link = step.link orelse break;
        fields = std.mem.tokenizeScalar(u8, lines[at], ' ');
        if (!std.mem.eql(u8, fields.next().?, "L")) return error.MalformedVector;
        try testing.expectEqualStrings(fields.next().?, step.label);
        try testing.expectEqualStrings(fields.next().?, link.sample_format.name());
        try testing.expectEqual(try std.fmt.parseInt(u32, fields.next().?, 10), link.sample_rate);
        var describe: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&describe);
        try link.layout.describe(&w);
        try testing.expectEqualStrings(try hexText(&buffer, fields.next().?), w.buffered());
        try testing.expectEqual(try std.fmt.parseInt(u32, fields.next().?, 10), link.time_base.num);
        try testing.expectEqual(try std.fmt.parseInt(u32, fields.next().?, 10), link.time_base.den);
        at += 1;
    }
    for (g.nodes.items) |n| {
        if (n.run == .resample and n.run.resample.mode == .resample) resampling = true;
    }
    // O, as frames go in and out.
    var signal: resample.Signal = .{};
    const channels = format.channelCount();
    const width = sample_format.bytesPerSample();
    for (sizes.items, ptss.items) |size, pts| {
        const data = try arena.alloc(u8, size * format.bytesPerFrame());
        for (0..size) |s| {
            for (0..channels) |c| {
                const offset = if (sample_format.isPlanar()) (c * size + s) * width else (s * channels + c) * width;
                storeGenerated(data[offset..], sample_format, signal.next(c));
            }
        }
        try testing.expectEqual(stage.Send.accepted, try g.send(try Frame.init(format, data, pts)));
        while (true) {
            switch (try g.receive()) {
                .output => |frame| {
                    try checkOutput(lines[at], frame, resampling);
                    at += 1;
                },
                .need_input => break,
                // The graph ended early (atrim).
                .drained => {
                    try testing.expectEqualStrings("D", lines[at]);
                    try testing.expectEqual(lines.len, at + 1);
                    return;
                },
            }
        }
    }
    g.finishInput();
    while (true) {
        switch (try g.receive()) {
            .output => |frame| {
                try checkOutput(lines[at], frame, resampling);
                at += 1;
            },
            .need_input => return error.TestUnexpectedResult,
            .drained => break,
        }
    }
    try testing.expectEqualStrings("D", lines[at]);
    try testing.expectEqual(lines.len, at + 1);
}

fn checkOutput(line: []const u8, frame: Frame, resampling: bool) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, fields.next().?, "O")) {
        std.debug.print("an extra output frame of {d}\n", .{frame.frameCount()});
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(try std.fmt.parseInt(usize, fields.next().?, 10), frame.frameCount());
    const pts_text = fields.next().?;
    try testing.expectEqual(if (std.mem.eql(u8, pts_text, "-")) null else try std.fmt.parseInt(i64, pts_text, 10), frame.pts);
    const hex = fields.next().?;
    var expected_buffer: [65536]u8 = undefined;
    const expected = try hexText(&expected_buffer, hex);
    try testing.expectEqual(expected.len, frame.data.len);
    // FFmpeg's bytes are little-endian.
    const width = frame.format.sample_format.bytesPerSample();
    var little: [65536]u8 = undefined;
    @memcpy(little[0..frame.data.len], frame.data);
    if (native_endian == .big) {
        var i: usize = 0;
        while (i < frame.data.len) : (i += width) std.mem.reverse(u8, little[i..][0..width]);
    }
    if (!resampling) return testing.expectEqualSlices(u8, expected, little[0..frame.data.len]);
    const limit = resample.tolerance(frame.format.sample_format.packedForm());
    var i: usize = 0;
    while (i < expected.len) : (i += width) {
        const diff = @abs(loadValue(expected[i..], frame.format.sample_format) - loadValue(little[i..], frame.format.sample_format));
        if (diff > limit) {
            std.debug.print("sample {d}: off by {e}\n", .{ i / width, diff });
            return error.TestExpectedApproxEqAbs;
        }
    }
}

test "every graph equals FFmpeg's: its chain, converters and output" {
    const gpa = testing.allocator;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, vectors, '\n');
    while (it.next()) |line| try lines.append(gpa, line);
    var count: usize = 0;
    var start: usize = 0;
    while (start < lines.items.len) : (count += 1) {
        var end = start + 1;
        while (end < lines.items.len and !std.mem.startsWith(u8, lines.items[end], "G ")) end += 1;
        runCase(gpa, lines.items[start..end]) catch |err| {
            std.debug.print("graph vector {s}: {t}\n", .{ lines.items[start], err });
            return err;
        };
        start = end;
    }
    try testing.expectEqual(case_count, count);
}
