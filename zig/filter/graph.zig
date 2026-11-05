// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavfilter/avfilter.c (avfilter_link, avfilter_insert_filter,
// ff_filter_config_links, ff_filter_frame, ff_filter_activate,
// filter_activate_default, filter_frame_to_filter, forward_status_change,
// request_frame_to_filter, ff_request_frame, the inlink and outlink
// functions), avfiltergraph.c (graph_check_validity, graph_config_links,
// ff_filter_graph_run_once), filters.h (the FORWARD macros),
// framequeue.c (the queue limit), buffersrc.c, buffersink.c
// (get_frame_internal), graphparser.c (avfilter_graph_parse_ptr,
// avfilter_graph_segment_link) and the activate functions of aresample,
// trim.c, setpts.c, split.c, af_channelsplit.c and af_amix.c at the pinned
// reference revision describe the behavior, restated here.
//! An audio filter graph (TODO.md T25a–T25c): buffer sources, filters
//! (filters.zig, multi.zig) and buffer sinks, configured as
//! `avfilter_graph_config` configures them (negotiate.zig) and run by
//! libavfilter's scheduler.
//!
//! `init` builds a linear chain of filters given by name; `initText` the
//! chain of filtergraph text between one source and one sink; `initGraph`
//! a graph of several sources and sinks whose names label the text's open
//! pads, as `avfilter_graph_parse_ptr` links them. `configure` checks that
//! every pad is linked, negotiates the formats (inserting converters) and
//! configures the links.
//!
//! Running follows libavfilter: each link has a frame queue, a status as
//! its source set it and as its destination saw it, and the flags saying a
//! frame is wanted or the source is blocked; filters are activated by
//! priority, one at a time (`ff_filter_graph_run_once`). `sendTo` is
//! `av_buffersrc_add_frame` (the frame is copied and queued), `closeSource`
//! ends a source, and `receiveFrom` is `av_buffersink_get_frame`: it runs
//! the graph until the sink has a frame (`output`), every source would
//! need input (`need_input`), or the sink's input ended (`drained`). The
//! graph's queue limit, as `avfilter_graph_set_max_buffered_frames`, is the
//! backpressure: a frame past it fails (`QueueFull`). A received frame
//! stays valid until the next call on the graph. Equal to FFmpeg on
//! zig/testing/vectors/graph.txt and multigraph.txt.

const std = @import("std");
const audio = @import("../core/audio.zig");
const channel_layout = @import("../core/channel_layout.zig");
const time = @import("../core/time.zig");
const stage = @import("../core/stage.zig");
const diagnostics = @import("../core/diagnostics.zig");
const Frame = @import("../core/frame.zig").Frame;
const formats = @import("formats.zig");
const filters = @import("filters.zig");
const multi = filters.multi;
const negotiate = @import("negotiate.zig");
const parse = @import("parse.zig");
const Layout = channel_layout.Layout;
const SampleFormat = audio.SampleFormat;
const Owned = filters.Owned;

pub const Option = filters.Option;

/// A buffer source: the format of every frame sent, and their time base
/// (1 / rate when null).
pub const SourceSpec = struct {
    format: audio.Format,
    time_base: ?time.TimeBase = null,
};

/// A buffer sink's lists (abuffersink's `sample_formats`, `samplerates`
/// and `channel_layouts`); an empty one takes anything.
pub const SinkSpec = struct {
    sample_formats: []const SampleFormat = &.{},
    sample_rates: []const u32 = &.{},
    layouts: []const Layout = &.{},
};

/// A source or sink of `initGraph`, its name the label that links it.
pub fn Named(comptime Spec: type) type {
    return struct { name: []const u8, spec: Spec };
}

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
    /// The most frames the graph's queues may hold together
    /// (`avfilter_graph_set_max_buffered_frames`); 0 for no limit.
    max_queued_frames: u32 = 0,
    /// Where FFmpeg's messages go; none by default.
    diagnostics: ?diagnostics.Sink = null,
};

pub const InitError = filters.CreateError || error{
    /// More than libswresample's 64 channels.
    LimitExceeded,
    /// Filtergraph text FFmpeg refuses (parse.zig), or more link labels
    /// than a filter has pads.
    InvalidSyntax,
};

pub const ConfigureError = filters.CreateError || filters.VolumeRun.Error || filters.ResampleRun.Error || formats.CheckError || error{
    /// "Impossible to convert between the formats supported by the
    /// filter ... and the filter ...".
    CannotConvert,
    /// "Cannot select sample rate" or "Cannot select channel layout".
    CannotSelect,
    /// A pad no link connects ("... not connected to any source" or
    /// "destination").
    Unconnected,
    /// channelmap's input channel is not in its input layout.
    InvalidChannelMap,
    /// `configure` was called before.
    AlreadyConfigured,
};

pub const RunError = filters.ResampleRun.Error || filters.VolumeRun.Error || error{
    /// A frame past the graph's queue limit ("Exhausted frame queue
    /// capacity").
    QueueFull,
};

pub const SendError = stage.SendError || RunError || error{
    NotConfigured,
    /// The frame's format is not the source's ("Changing audio frame
    /// properties on the fly is not supported").
    FormatChange,
    /// A frame of no samples; the port refuses it.
    EmptyFrame,
    /// The source has ended, closed or closed by the graph (atrim's end),
    /// as `av_buffersrc_add_frame`'s `AVERROR_EOF`.
    GraphEnded,
};

pub const ReceiveError = RunError || error{NotConfigured};

/// A link's status: libavfilter's EOF (errors stop the graph instead).
pub const Status = enum { none, eof };

pub const Node = struct {
    /// The instance's name, owned.
    label: []u8,
    kind: union(enum) {
        source: struct { index: u32, eof: bool = false, last_pts: ?i64 = null },
        sink: struct { index: u32 },
        filter: filters.Filter,
    },
    /// The links of the node's input and output pads, owned.
    inputs: []?u32,
    outputs: []?u32,
    run: Run = .none,
    /// `ready`: the activation priority.
    ready: u32 = 0,
};

const Run = union(enum) {
    none,
    volume: filters.VolumeRun,
    resample: filters.ResampleRun,
    trim: filters.TrimRun,
    setpts: filters.SetPtsRun,
    pan: multi.PanRun,
    mix: multi.MixRun,
};

/// A link between two pads: its format once configured, and its queue
/// and statuses while the graph runs.
pub const Link = struct {
    src: u32,
    src_pad: u32,
    dst: u32,
    dst_pad: u32,
    sample_format: SampleFormat = undefined,
    sample_rate: u32 = 0,
    layout: Layout = undefined,
    time_base: time.TimeBase = undefined,
    picked: bool = false,
    configured: bool = false,
    /// The queued frames, from `head`.
    fifo: std.ArrayList(Owned) = .empty,
    head: usize = 0,
    status_in: Status = .none,
    status_in_pts: ?i64 = null,
    status_out: Status = .none,
    frame_wanted_out: bool = false,
    frame_blocked_in: bool = false,
    current_pts: ?i64 = null,
    frame_count_out: u64 = 0,

    pub fn format(l: *const Link) audio.Format {
        return .{ .sample_rate = l.sample_rate, .layout = l.layout, .sample_format = l.sample_format };
    }

    fn queued(l: *const Link) usize {
        return l.fifo.items.len - l.head;
    }
};

const Source = struct { spec: SourceSpec, time_base: time.TimeBase, node: u32 };

const Sink = struct {
    /// Owned.
    formats: []SampleFormat,
    rates: []u32,
    layouts: []Layout,
    node: u32,
};

/// What an activation did (`FFERROR_BUFFERSRC_EMPTY` apart).
const Activation = enum { ok, buffersrc_empty };

pub const Graph = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    links: std.ArrayList(Link) = .empty,
    sources: std.ArrayList(Source) = .empty,
    sinks: std.ArrayList(Sink) = .empty,
    /// The converter options, owned, in one buffer.
    converter: []Option = &.{},
    converter_text: []u8 = &.{},
    diagnostics: ?diagnostics.Sink,
    max_queued: usize,
    queued: usize = 0,
    /// `configure` was called; a failed configuration is not retried.
    configure_called: bool = false,
    configured: bool = false,
    last: ?Owned = null,

    /// Creates the source, the chain's filters with their options, and
    /// the sink, linked in that order.
    pub fn init(gpa: std.mem.Allocator, source: SourceSpec, chain: []const FilterSpec, sink: SinkSpec, opts: Options) InitError!Graph {
        var g = try start(gpa, opts);
        errdefer g.deinit();
        try g.addSource("in", source);
        for (chain) |spec| _ = try g.addFilter(spec.label orelse spec.name, try filters.Filter.create(gpa, spec.name, spec.options, opts.diagnostics));
        try g.addSink("out", sink);
        // in, the chain, out: each node to the next. A filter of other
        // pads leaves them unlinked, which `configure` refuses.
        for (0..g.nodes.items.len - 1) |i| {
            const src: u32 = @intCast(i);
            if (g.nodes.items[src].outputs.len == 0 or g.nodes.items[src + 1].inputs.len == 0) continue;
            _ = try g.addLink(src, 0, src + 1, 0);
        }
        return g;
    }

    /// The chain of filtergraph `text` between one source (`in`) and one
    /// sink (`out`): `initGraph` with those names.
    pub fn initText(gpa: std.mem.Allocator, source: SourceSpec, text: []const u8, sink: SinkSpec, opts: Options) InitError!Graph {
        return initGraph(gpa, &.{.{ .name = "in", .spec = source }}, text, &.{.{ .name = "out", .spec = sink }}, opts);
    }

    /// The graph of filtergraph `text` (parse.zig) between `sources` and
    /// `sinks`, created first, as `avfilter_graph_parse_ptr` builds it:
    /// every filter created (`Parsed_<name>_<n>`, or `<name>@<instance>`),
    /// then every filter's options set (an unknown option failing only
    /// once all are set), then every filter initialized, then the pads
    /// linked by label and along each chain, the first filter's input
    /// labelled `in` and the last one's output `out` when unlabelled, and
    /// the open pads to the sources and sinks of their labels' names.
    pub fn initGraph(gpa: std.mem.Allocator, sources: []const Named(SourceSpec), text: []const u8, sinks: []const Named(SinkSpec), opts: Options) InitError!Graph {
        var g = try start(gpa, opts);
        errdefer g.deinit();
        for (sources) |s| try g.addSource(s.name, s.spec);
        for (sinks) |s| try g.addSink(s.name, s.spec);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = parse.parse(a, text, opts.diagnostics) catch |err| return switch (err) {
            error.InvalidSyntax => error.InvalidSyntax,
            error.OutOfMemory => error.OutOfMemory,
        };
        const first = g.nodes.items.len;
        for (parsed.filters, 0..) |pf, i| {
            const f = filters.Filter.alloc(pf.name) catch |err| {
                diagnostics.report(opts.diagnostics, .err, "No such filter: '{s}'", .{pf.name});
                return err;
            };
            const label = if (pf.instance) |inst| try a.print("{s}@{s}", .{ pf.name, inst }) else try a.print("Parsed_{s}_{d}", .{ pf.name, i });
            try g.addNodeOf(label, .{ .filter = f }, 0, 0);
        }
        // avfilter_graph_segment_apply_opts.
        var unknown: ?Option = null;
        for (parsed.filters, first..) |pf, node| {
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
        for (first..g.nodes.items.len) |node| {
            const f = &g.nodes.items[node].kind.filter;
            try f.init(gpa, opts.diagnostics);
            const pads = f.pads();
            try g.setPads(@intCast(node), pads.inputs, pads.outputs);
        }
        try g.linkSegment(a, parsed, first, sources, sinks);
        return g;
    }

    /// `avfilter_graph_segment_link` and `avfilter_graph_parse_ptr`'s
    /// matching of the open pads to the sources and sinks.
    fn linkSegment(g: *Graph, a: std.mem.Allocator, parsed: parse.Parsed, first: usize, sources: []const Named(SourceSpec), sinks: []const Named(SinkSpec)) InitError!void {
        const count = parsed.filters.len;
        // The labels, the defaults added: [in] before the first filter and
        // [out] after the last, each with one such pad and none given.
        const in_labels = try a.alloc([]const []const u8, count);
        const out_labels = try a.alloc([]const []const u8, count);
        for (parsed.filters, 0..) |pf, i| {
            in_labels[i] = pf.inputs;
            out_labels[i] = pf.outputs;
        }
        if (count > 0) {
            if (g.nodes.items[first].inputs.len == 1 and in_labels[0].len == 0) in_labels[0] = &.{"in"};
            if (g.nodes.items[first + count - 1].outputs.len == 1 and out_labels[count - 1].len == 0) out_labels[count - 1] = &.{"out"};
        }
        const Open = struct { node: u32, pad: u32, label: ?[]const u8 };
        var open_inputs: std.ArrayList(Open) = .empty;
        var open_outputs: std.ArrayList(Open) = .empty;
        for (0..count) |fi| {
            const node: u32 = @intCast(first + fi);
            // link_inputs.
            const n_in = g.nodes.items[node].inputs.len;
            if (n_in < in_labels[fi].len) {
                diagnostics.report(g.diagnostics, .err, "More input link labels specified for filter '{s}' than it has inputs: {d} > {d}", .{ parsed.filters[fi].name, in_labels[fi].len, n_in });
                return error.InvalidSyntax;
            }
            for (0..n_in) |pad| {
                if (g.nodes.items[node].inputs[pad] != null) continue;
                const label: ?[]const u8 = if (pad < in_labels[fi].len) in_labels[fi][pad] else null;
                if (label) |l| {
                    if (g.findLabel(out_labels, first, fi, l, true)) |found| {
                        _ = try g.addLink(found.node, found.pad, node, @intCast(pad));
                        continue;
                    }
                }
                try open_inputs.append(a, .{ .node = node, .pad = @intCast(pad), .label = label });
            }
            // link_outputs.
            const n_out = g.nodes.items[node].outputs.len;
            if (n_out < out_labels[fi].len) {
                diagnostics.report(g.diagnostics, .err, "More output link labels specified for filter '{s}' than it has outputs: {d} > {d}", .{ parsed.filters[fi].name, out_labels[fi].len, n_out });
                return error.InvalidSyntax;
            }
            outputs: for (0..n_out) |pad| {
                if (g.nodes.items[node].outputs[pad] != null) continue;
                const label: ?[]const u8 = if (pad < out_labels[fi].len) out_labels[fi][pad] else null;
                if (label) |l| {
                    if (g.findLabel(in_labels, first, fi, l, false)) |found| {
                        _ = try g.addLink(node, @intCast(pad), found.node, found.pad);
                        continue;
                    }
                } else {
                    // An unlabelled output links to the next filter of its
                    // chain's first free unlabelled input.
                    if (fi + 1 < count and parsed.filters[fi + 1].chain == parsed.filters[fi].chain) {
                        const next: u32 = @intCast(first + fi + 1);
                        for (g.nodes.items[next].inputs, 0..) |l, in| {
                            if (l == null and (in >= in_labels[fi + 1].len)) {
                                _ = try g.addLink(node, @intCast(pad), next, @intCast(in));
                                continue :outputs;
                            }
                        }
                    }
                }
                try open_outputs.append(a, .{ .node = node, .pad = @intCast(pad), .label = label });
            }
        }
        // The open inputs to the sources, the open outputs to the sinks,
        // by name; the rest stay unlinked.
        for (open_inputs.items) |o| {
            const label = o.label orelse continue;
            for (sources, 0..) |s, i| {
                const src = g.sources.items[i].node;
                if (std.mem.eql(u8, s.name, label) and g.nodes.items[src].outputs[0] == null) {
                    _ = try g.addLink(src, 0, o.node, o.pad);
                    break;
                }
            }
        }
        for (open_outputs.items) |o| {
            const label = o.label orelse continue;
            for (sinks, 0..) |s, j| {
                const dst = g.sinks.items[j].node;
                if (std.mem.eql(u8, s.name, label) and g.nodes.items[dst].inputs[0] == null) {
                    _ = try g.addLink(o.node, o.pad, dst, 0);
                    break;
                }
            }
        }
    }

    /// `find_linklabel`: from filter `from` on, a free pad labelled
    /// `label` (an output when `want_output`).
    fn findLabel(g: *const Graph, labels: []const []const []const u8, first: usize, from: usize, label: []const u8, want_output: bool) ?struct { node: u32, pad: u32 } {
        for (from..labels.len) |fi| {
            const n = &g.nodes.items[first + fi];
            const pads = if (want_output) n.outputs else n.inputs;
            for (0..@min(labels[fi].len, pads.len)) |i| {
                if (pads[i] == null and std.mem.eql(u8, labels[fi][i], label)) return .{ .node = @intCast(first + fi), .pad = @intCast(i) };
            }
        }
        return null;
    }

    /// A graph with no nodes yet, the converter options copied.
    fn start(gpa: std.mem.Allocator, opts: Options) InitError!Graph {
        var g: Graph = .{
            .gpa = gpa,
            .diagnostics = opts.diagnostics,
            .max_queued = if (opts.max_queued_frames == 0) std.math.maxInt(usize) else opts.max_queued_frames,
        };
        errdefer g.deinit();
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

    fn addSource(g: *Graph, name: []const u8, spec: SourceSpec) InitError!void {
        if (spec.format.channelCount() > 64) return error.LimitExceeded;
        const index: u32 = @intCast(g.sources.items.len);
        const node: u32 = @intCast(g.nodes.items.len);
        try g.sources.append(g.gpa, .{
            .spec = spec,
            .time_base = spec.time_base orelse time.TimeBase.ofSampleRate(spec.format.sample_rate) catch unreachable,
            .node = node,
        });
        try g.addNodeOf(name, .{ .source = .{ .index = index } }, 0, 1);
    }

    fn addSink(g: *Graph, name: []const u8, spec: SinkSpec) InitError!void {
        // abuffersink's rates are ints.
        for (spec.sample_rates) |r| {
            if (r == 0 or r > std.math.maxInt(i32)) return error.OutOfRange;
        }
        const index: u32 = @intCast(g.sinks.items.len);
        const node: u32 = @intCast(g.nodes.items.len);
        const sample_formats = try g.gpa.dupe(SampleFormat, spec.sample_formats);
        errdefer g.gpa.free(sample_formats);
        const rates = try g.gpa.dupe(u32, spec.sample_rates);
        errdefer g.gpa.free(rates);
        const layouts = try g.gpa.dupe(Layout, spec.layouts);
        errdefer g.gpa.free(layouts);
        try g.addNodeOf(name, .{ .sink = .{ .index = index } }, 1, 0);
        try g.sinks.append(g.gpa, .{ .formats = sample_formats, .rates = rates, .layouts = layouts, .node = node });
    }

    /// Adds a filter node with its pads; it takes `f` (freed on failure).
    pub fn addFilter(g: *Graph, label: []const u8, f: filters.Filter) error{OutOfMemory}!u32 {
        var filter = f;
        const pads = filter.pads();
        g.addNodeOf(label, .{ .filter = filter }, pads.inputs, pads.outputs) catch |err| {
            filter.deinit(g.gpa);
            return err;
        };
        return @intCast(g.nodes.items.len - 1);
    }

    fn addNodeOf(g: *Graph, label: []const u8, kind: @FieldType(Node, "kind"), inputs: u32, outputs: u32) error{OutOfMemory}!void {
        const copy = try g.gpa.dupe(u8, label);
        errdefer g.gpa.free(copy);
        const in = try g.gpa.alloc(?u32, inputs);
        errdefer g.gpa.free(in);
        const out = try g.gpa.alloc(?u32, outputs);
        errdefer g.gpa.free(out);
        @memset(in, null);
        @memset(out, null);
        try g.nodes.append(g.gpa, .{ .label = copy, .kind = kind, .inputs = in, .outputs = out });
    }

    /// Gives `node` its pads, all unlinked, once its filter is initialized.
    fn setPads(g: *Graph, node: u32, inputs: u32, outputs: u32) error{OutOfMemory}!void {
        const n = &g.nodes.items[node];
        const in = try g.gpa.alloc(?u32, inputs);
        errdefer g.gpa.free(in);
        const out = try g.gpa.alloc(?u32, outputs);
        @memset(in, null);
        @memset(out, null);
        g.gpa.free(n.inputs);
        g.gpa.free(n.outputs);
        n.inputs = in;
        n.outputs = out;
    }

    /// `avfilter_link`.
    pub fn addLink(g: *Graph, src: u32, src_pad: u32, dst: u32, dst_pad: u32) error{OutOfMemory}!u32 {
        try g.links.append(g.gpa, .{ .src = src, .src_pad = src_pad, .dst = dst, .dst_pad = dst_pad });
        const index: u32 = @intCast(g.links.items.len - 1);
        g.nodes.items[src].outputs[src_pad] = index;
        g.nodes.items[dst].inputs[dst_pad] = index;
        return index;
    }

    pub fn deinit(g: *Graph) void {
        for (g.nodes.items) |*n| {
            g.gpa.free(n.label);
            g.gpa.free(n.inputs);
            g.gpa.free(n.outputs);
            switch (n.kind) {
                .filter => |*f| f.deinit(g.gpa),
                else => {},
            }
            switch (n.run) {
                .resample => |*r| r.deinit(),
                .volume => |*v| v.deinit(),
                .setpts => |*r| r.deinit(),
                .pan => |*r| r.deinit(g.gpa),
                .mix => |*r| r.deinit(),
                .none, .trim => {},
            }
        }
        for (g.links.items) |*l| {
            for (l.fifo.items[l.head..]) |*f| f.free(g.gpa);
            l.fifo.deinit(g.gpa);
        }
        for (g.sinks.items) |*s| {
            g.gpa.free(s.formats);
            g.gpa.free(s.rates);
            g.gpa.free(s.layouts);
        }
        g.nodes.deinit(g.gpa);
        g.links.deinit(g.gpa);
        g.sources.deinit(g.gpa);
        g.sinks.deinit(g.gpa);
        g.gpa.free(g.converter);
        g.gpa.free(g.converter_text);
        if (g.last) |*l| l.free(g.gpa);
        g.* = undefined;
    }

    /// For a single chain: the nodes from the first source to its sink,
    /// each with the link that leaves it (null for the sink).
    pub fn chainIterator(g: *const Graph) ChainIterator {
        return .{ .graph = g, .node = g.sources.items[0].node };
    }

    pub const ChainIterator = struct {
        graph: *const Graph,
        node: ?u32,

        pub fn next(it: *ChainIterator) ?struct { label: []const u8, link: ?*const Link } {
            const index = it.node orelse return null;
            const n = &it.graph.nodes.items[index];
            const link: ?*const Link = if (n.outputs.len > 0) &it.graph.links.items[n.outputs[0].?] else null;
            it.node = if (link) |l| l.dst else null;
            return .{ .label = n.label, .link = link };
        }
    };

    /// The link into sink `j`: the output's format and time base.
    pub fn sinkLink(g: *const Graph, j: usize) *const Link {
        return &g.links.items[g.nodes.items[g.sinks.items[j].node].inputs[0].?];
    }

    // Configuration ---------------------------------------------------------

    /// `avfilter_graph_config`: every pad linked, the formats negotiated
    /// (converters inserted), then the links configured.
    pub fn configure(g: *Graph) ConfigureError!void {
        if (g.configure_called) return error.AlreadyConfigured;
        g.configure_called = true;
        try g.checkValidity();
        try negotiate.negotiate(g);
        for (0..g.nodes.items.len) |i| {
            for (g.nodes.items[i].inputs) |l| try g.configLink(l.?);
        }
        g.configured = true;
    }

    /// `graph_check_validity`.
    fn checkValidity(g: *Graph) ConfigureError!void {
        for (g.nodes.items) |n| {
            for (n.inputs, 0..) |l, pad| {
                if (l == null) {
                    diagnostics.report(g.diagnostics, .err, "Input pad {d} of the filter instance \"{s}\" not connected to any source", .{ pad, n.label });
                    return error.Unconnected;
                }
            }
            for (n.outputs, 0..) |l, pad| {
                if (l == null) {
                    diagnostics.report(g.diagnostics, .err, "Output pad {d} of the filter instance \"{s}\" not connected to any destination", .{ pad, n.label });
                    return error.Unconnected;
                }
            }
        }
    }

    /// `ff_filter_config_links` of one link: its source's links first, then
    /// the source's output configuration, the default time base, and the
    /// destination's input configuration.
    fn configLink(g: *Graph, link: u32) ConfigureError!void {
        if (g.links.items[link].configured) return;
        g.links.items[link].configured = true;
        const src = g.links.items[link].src;
        for (g.nodes.items[src].inputs) |l| try g.configLink(l.?);
        const l = &g.links.items[link];
        const n = &g.nodes.items[src];
        const first_in: ?*Link = if (n.inputs.len > 0) &g.links.items[n.inputs[0].?] else null;
        var time_base: ?time.TimeBase = null;
        switch (n.kind) {
            .source => |s| time_base = g.sources.items[s.index].time_base,
            .sink => unreachable,
            .filter => |*f| switch (f.*) {
                .volume => |*v| {
                    const run = try filters.VolumeRun.init(v, first_in.?.format(), first_in.?.time_base, g.diagnostics);
                    n.run = .{ .volume = run };
                },
                .aresample => |a| {
                    // Built first: assigning the union while `init` runs
                    // would leave its tag set on failure.
                    const run = try filters.ResampleRun.init(g.gpa, a, first_in.?.format(), l.format(), first_in.?.time_base, g.diagnostics);
                    n.run = .{ .resample = run };
                    time_base = time.TimeBase.ofSampleRate(l.sample_rate) catch unreachable;
                },
                .amix => |*a| {
                    const run = try multi.MixRun.init(g.gpa, a, l.format());
                    n.run = .{ .mix = run };
                    time_base = time.TimeBase.ofSampleRate(l.sample_rate) catch unreachable;
                },
                else => {},
            },
        }
        l.time_base = time_base orelse if (first_in) |in| in.time_base else time.TimeBase.ofSampleRate(l.sample_rate) catch unreachable;
        // The destination's input configuration.
        const d = &g.nodes.items[l.dst];
        switch (d.kind) {
            .filter => |*f| switch (f.*) {
                .atrim => |a| d.run = .{ .trim = .init(a, l.format(), l.time_base) },
                .asetpts => |*a| d.run = .{ .setpts = .init(a, l.format(), l.time_base) },
                .channelmap => |*c| try c.configInput(&l.layout, g.diagnostics),
                .pan => |*p| {
                    const run = try multi.PanRun.init(g.gpa, p, l.format(), g.links.items[d.outputs[0].?].format());
                    d.run = .{ .pan = run };
                },
                else => {},
            },
            else => {},
        }
    }

    // The scheduler ---------------------------------------------------------

    fn linkAt(g: *Graph, index: u32) *Link {
        return &g.links.items[index];
    }

    /// `ff_filter_set_ready`.
    fn setReady(g: *Graph, node: u32, priority: u32) void {
        const n = &g.nodes.items[node];
        n.ready = @max(n.ready, priority);
    }

    /// `filter_unblock`: the node's outputs are no longer blocked.
    fn unblock(g: *Graph, node: u32) void {
        for (g.nodes.items[node].outputs) |o| g.linkAt(o.?).frame_blocked_in = false;
    }

    fn updatePts(l: *Link, pts: ?i64) void {
        if (pts) |p| l.current_pts = p;
    }

    /// `ff_avfilter_link_set_in_status` (`ff_outlink_set_status`).
    fn setInStatus(g: *Graph, index: u32, status: Status, pts: ?i64) void {
        const l = g.linkAt(index);
        if (l.status_in == status) return;
        std.debug.assert(l.status_in == .none);
        l.status_in = status;
        l.status_in_pts = pts;
        l.frame_wanted_out = false;
        l.frame_blocked_in = false;
        g.unblock(l.dst);
        g.setReady(l.dst, 200);
    }

    /// `link_set_out_status`.
    fn setOutStatus(g: *Graph, index: u32, status: Status, pts: ?i64) void {
        const l = g.linkAt(index);
        std.debug.assert(!l.frame_wanted_out and l.status_out == .none);
        l.status_out = status;
        updatePts(l, pts);
        g.unblock(l.dst);
        g.setReady(l.src, 200);
    }

    /// `ff_request_frame`: the link's status once acknowledged, or none
    /// with a frame requested.
    fn requestFrame(g: *Graph, index: u32) Status {
        const l = g.linkAt(index);
        if (l.status_out != .none) return l.status_out;
        if (l.status_in != .none) {
            if (l.queued() > 0) return .none;
            g.setOutStatus(index, l.status_in, l.status_in_pts);
            return g.linkAt(index).status_out;
        }
        l.frame_wanted_out = true;
        g.setReady(l.src, 100);
        return .none;
    }

    /// `request_frame_to_filter`: a request on an output of a filter that
    /// activates by default, passed to its first input.
    fn requestFrameToFilter(g: *Graph, index: u32) void {
        const l = g.linkAt(index);
        l.frame_blocked_in = true;
        const src = &g.nodes.items[l.src];
        const status = g.requestFrame(src.inputs[0].?);
        if (status != .none and status != g.linkAt(index).status_in) g.setInStatus(index, status, g.linkAt(index).status_in_pts);
    }

    /// `ff_filter_frame`: queues `frame` on the link; past the graph's
    /// limit it is dropped and the queue is full.
    fn filterFrame(g: *Graph, index: u32, frame: Owned) RunError!void {
        var f = frame;
        const l = g.linkAt(index);
        l.frame_blocked_in = false;
        l.frame_wanted_out = false;
        g.unblock(l.dst);
        if (g.queued >= g.max_queued) {
            f.free(g.gpa);
            diagnostics.report(g.diagnostics, .err, "Exhausted frame queue capacity ({d} frames)", .{g.max_queued});
            return error.QueueFull;
        }
        l.fifo.append(g.gpa, f) catch |err| {
            f.free(g.gpa);
            return err;
        };
        g.queued += 1;
        g.setReady(l.dst, 300);
    }

    /// `ff_inlink_consume_frame`.
    fn consumeFrame(g: *Graph, index: u32) ?Owned {
        const l = g.linkAt(index);
        if (l.queued() == 0) return null;
        const frame = l.fifo.items[l.head];
        l.head += 1;
        if (l.head == l.fifo.items.len) {
            l.fifo.clearRetainingCapacity();
            l.head = 0;
        }
        g.queued -= 1;
        updatePts(l, frame.pts);
        l.frame_count_out += 1;
        return frame;
    }

    const Acknowledged = struct { status: Status, pts: ?i64 };

    /// `ff_inlink_acknowledge_status`: the input's status, once its queue
    /// is empty.
    fn acknowledgeStatus(g: *Graph, index: u32) ?Acknowledged {
        const l = g.linkAt(index);
        if (l.queued() > 0) return null;
        if (l.status_out != .none) return .{ .status = l.status_out, .pts = l.current_pts };
        if (l.status_in == .none) return null;
        l.status_out = l.status_in;
        updatePts(l, l.status_in_pts);
        return .{ .status = l.status_out, .pts = l.current_pts };
    }

    /// `ff_inlink_request_frame`.
    fn inlinkRequestFrame(g: *Graph, index: u32) void {
        const l = g.linkAt(index);
        l.frame_wanted_out = true;
        g.setReady(l.src, 100);
    }

    /// `ff_inlink_set_status`: the input is closed from the destination;
    /// its queued frames are dropped.
    fn inlinkSetStatus(g: *Graph, index: u32, status: Status) void {
        const l = g.linkAt(index);
        if (l.status_out != .none) return;
        l.frame_wanted_out = false;
        l.frame_blocked_in = false;
        g.setOutStatus(index, status, null);
        const l2 = g.linkAt(index);
        for (l2.fifo.items[l2.head..]) |*f| {
            f.free(g.gpa);
            g.queued -= 1;
        }
        l2.fifo.clearRetainingCapacity();
        l2.head = 0;
        if (l2.status_in == .none) l2.status_in = status;
    }

    /// `ff_outlink_get_status`.
    fn outlinkStatus(g: *Graph, index: u32) Status {
        return g.linkAt(index).status_in;
    }

    /// `ff_filter_graph_run_once`: activates the most ready filter, the
    /// first in graph order among equals; null when none is ready.
    fn runOnce(g: *Graph) RunError!?Activation {
        var best: u32 = 0;
        for (g.nodes.items, 0..) |n, i| {
            if (n.ready > g.nodes.items[best].ready) best = @intCast(i);
        }
        if (g.nodes.items[best].ready == 0) return null;
        return try g.activate(best);
    }

    /// `ff_filter_activate`.
    fn activate(g: *Graph, node: u32) RunError!Activation {
        const n = &g.nodes.items[node];
        n.ready = 0;
        switch (n.kind) {
            .source => return g.activateSource(node),
            // buffersink: the frame waits for get_frame_internal.
            .sink => return .ok,
            .filter => |*f| switch (f.*) {
                .anull, .aformat, .volume, .channelmap, .pan => try g.activateDefault(node),
                .aresample => try g.activateResample(node),
                .atrim => try g.activateTrim(node),
                .asetpts => try g.activateSetPts(node),
                .asplit => try g.activateSplit(node),
                .channelsplit => try g.activateChannelSplit(node),
                .amix => try g.activateMix(node),
            },
        }
        return .ok;
    }

    /// buffersrc's `activate`.
    fn activateSource(g: *Graph, node: u32) Activation {
        const n = &g.nodes.items[node];
        const s = &n.kind.source;
        const out = n.outputs[0].?;
        if (!s.eof and g.outlinkStatus(out) != .none) {
            s.eof = true;
            return .ok;
        }
        if (s.eof) {
            g.setInStatus(out, .eof, s.last_pts);
            return .ok;
        }
        return .buffersrc_empty;
    }

    /// `filter_activate_default`, for the filters with `filter_frame`.
    fn activateDefault(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        var eofs: usize = 0;
        for (n.outputs) |o| eofs += @intFromBool(g.outlinkStatus(o.?) == .eof);
        if (n.outputs.len > 0 and eofs == n.outputs.len) {
            for (n.inputs) |i| g.inlinkSetStatus(i.?, .eof);
            return;
        }
        for (n.inputs) |i| {
            if (g.linkAt(i.?).queued() > 0) return g.filterFrameToFilter(i.?);
        }
        for (n.inputs) |i| {
            const l = g.linkAt(i.?);
            if (l.status_in != .none and l.status_out == .none) return g.forwardStatusChange(node, i.?);
        }
        for (n.outputs) |o| {
            const l = g.linkAt(o.?);
            if (l.frame_wanted_out and !l.frame_blocked_in) return g.requestFrameToFilter(o.?);
        }
        for (n.outputs) |o| {
            if (g.linkAt(o.?).frame_wanted_out) return g.requestFrameToFilter(o.?);
        }
    }

    /// `filter_frame_to_filter`.
    fn filterFrameToFilter(g: *Graph, index: u32) RunError!void {
        const frame = g.consumeFrame(index).?;
        const dst = g.linkAt(index).dst;
        g.unblock(dst);
        // filter_frame sees the count before the frame.
        g.linkAt(index).frame_count_out -= 1;
        try g.callFilterFrame(dst, index, frame);
        g.linkAt(index).frame_count_out += 1;
        g.setReady(dst, 300);
    }

    /// The `filter_frame` of the filters activated by default.
    fn callFilterFrame(g: *Graph, node: u32, in: u32, frame: Owned) RunError!void {
        var f = frame;
        const n = &g.nodes.items[node];
        const out = n.outputs[0].?;
        switch (n.run) {
            .volume => |*v| v.filterFrame(f.data, f.frameCount(), f.pts, g.linkAt(in).frame_count_out) catch |err| {
                f.free(g.gpa);
                return err;
            },
            .pan => |*p| {
                defer f.free(g.gpa);
                return g.filterFrame(out, try p.filterFrame(g.gpa, &f));
            },
            else => if (n.kind.filter == .channelmap) {
                defer f.free(g.gpa);
                return g.filterFrame(out, try n.kind.filter.channelmap.output(g.gpa, &f, g.linkAt(out).format()));
            },
        }
        // anull, aformat and volume pass the frame on.
        try g.filterFrame(out, f);
    }

    /// `forward_status_change`: requests on the outputs until the input's
    /// status is acknowledged, or every output is closed.
    fn forwardStatusChange(g: *Graph, node: u32, in: u32) void {
        const outputs = g.nodes.items[node].outputs;
        if (outputs.len == 0) return;
        var out: usize = 0;
        var progress: usize = 0;
        while (g.linkAt(in).status_out == .none) {
            const o = outputs[out].?;
            if (g.linkAt(o).status_in == .none) {
                progress += 1;
                g.requestFrameToFilter(o);
            }
            out += 1;
            if (out == outputs.len) {
                if (progress == 0) {
                    g.setOutStatus(in, g.linkAt(in).status_in, g.linkAt(in).status_in_pts);
                    return;
                }
                progress = 0;
                out = 0;
            }
        }
        g.setReady(node, 200);
    }

    /// `FF_FILTER_FORWARD_STATUS_BACK`: true when the output is closed,
    /// which closes the input.
    fn forwardStatusBack(g: *Graph, out: u32, in: u32) bool {
        const status = g.outlinkStatus(out);
        if (status == .none) return false;
        g.inlinkSetStatus(in, status);
        return true;
    }

    /// `FF_FILTER_FORWARD_WANTED`.
    fn forwardWanted(g: *Graph, out: u32, in: u32) void {
        if (g.linkAt(out).frame_wanted_out) g.inlinkRequestFrame(in);
    }

    /// aresample's `activate`.
    fn activateResample(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        const in = n.inputs[0].?;
        const out = n.outputs[0].?;
        const r = &n.run.resample;
        if (g.forwardStatusBack(out, in)) return;
        if (r.more()) {
            if (try r.flush(false)) |o| return g.filterFrame(out, o);
        }
        r.clearMore();
        while (g.consumeFrame(in)) |frame| {
            var f = frame;
            defer f.free(g.gpa);
            if (try r.filterFrame(&f)) |o| return g.filterFrame(out, o);
        }
        if (g.acknowledgeStatus(in)) |st| {
            if (try r.flush(true)) |o| return g.filterFrame(out, o);
            g.setInStatus(out, st.status, null);
            return;
        }
        g.forwardWanted(out, in);
    }

    /// atrim's `activate`.
    fn activateTrim(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        const in = n.inputs[0].?;
        const out = n.outputs[0].?;
        const t = &n.run.trim;
        if (g.forwardStatusBack(out, in)) return;
        while (g.consumeFrame(in)) |frame| {
            var f = frame;
            defer f.free(g.gpa);
            const was_eof = t.eof;
            const result = try t.filterFrame(g.gpa, &f);
            if (t.eof and !was_eof) {
                // The end: both sides closed.
                g.inlinkSetStatus(in, .eof);
                g.setInStatus(out, .eof, f.pts);
            }
            if (result) |o| return g.filterFrame(out, o);
        }
        if (g.acknowledgeStatus(in)) |st| return g.setInStatus(out, st.status, st.pts);
        g.forwardWanted(out, in);
    }

    /// asetpts's `activate`.
    fn activateSetPts(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        const in = n.inputs[0].?;
        const out = n.outputs[0].?;
        if (g.forwardStatusBack(out, in)) return;
        if (g.consumeFrame(in)) |frame| {
            var f = frame;
            f.pts = n.run.setpts.filterFrame(f.pts, f.frameCount());
            return g.filterFrame(out, f);
        }
        if (g.acknowledgeStatus(in)) |st| return g.setInStatus(out, st.status, null);
        g.forwardWanted(out, in);
    }

    /// asplit's `activate`: a copy of each frame to every open output.
    fn activateSplit(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        const in = n.inputs[0].?;
        var eofs: usize = 0;
        for (n.outputs) |o| eofs += @intFromBool(g.outlinkStatus(o.?) == .eof);
        if (eofs == n.outputs.len) return g.inlinkSetStatus(in, .eof);
        if (g.consumeFrame(in)) |frame| {
            var f = frame;
            defer f.free(g.gpa);
            for (n.outputs) |o| {
                if (g.outlinkStatus(o.?) != .none) continue;
                const copy = try cloneOwned(g.gpa, &f);
                try g.filterFrame(o.?, copy);
            }
            return;
        }
        if (g.acknowledgeStatus(in)) |st| {
            for (n.outputs) |o| {
                if (g.outlinkStatus(o.?) == .none) g.setInStatus(o.?, st.status, st.pts);
            }
            return;
        }
        for (n.outputs) |o| {
            if (g.linkAt(o.?).frame_wanted_out) return g.inlinkRequestFrame(in);
        }
    }

    /// channelsplit's `activate`: each output its channel's plane.
    fn activateChannelSplit(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        const in = n.inputs[0].?;
        for (n.outputs) |o| {
            const status = g.outlinkStatus(o.?);
            if (status != .none) {
                for (n.inputs) |i| g.inlinkSetStatus(i.?, status);
                return;
            }
        }
        if (g.consumeFrame(in)) |frame| {
            var f = frame;
            defer f.free(g.gpa);
            for (n.outputs, 0..) |o, i| {
                if (g.outlinkStatus(o.?) != .none) continue;
                const part = try n.kind.filter.channelsplit.output(g.gpa, &f, i, g.linkAt(o.?).format());
                try g.filterFrame(o.?, part);
            }
        }
        if (g.acknowledgeStatus(in)) |st| {
            for (n.outputs) |o| {
                if (g.outlinkStatus(o.?) == .none) g.setInStatus(o.?, st.status, st.pts);
            }
            return;
        }
        for (n.outputs) |o| {
            if (g.linkAt(o.?).frame_wanted_out) return g.inlinkRequestFrame(in);
        }
    }

    /// amix's `activate`.
    fn activateMix(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        const out = n.outputs[0].?;
        const r = &n.run.mix;
        const out_status = g.outlinkStatus(out);
        if (out_status != .none) {
            for (n.inputs) |i| g.inlinkSetStatus(i.?, out_status);
            return;
        }
        for (n.inputs, 0..) |in, i| {
            const frame = g.consumeFrame(in.?) orelse continue;
            var f = frame;
            defer f.free(g.gpa);
            var pts: ?i64 = null;
            if (i == 0) {
                // av_rescale_q of AV_NOPTS_VALUE is -INT64_MAX's.
                const value = f.pts orelse -std.math.maxInt(i64);
                pts = time.rescale(value, g.linkAt(in.?).time_base, g.linkAt(out).time_base, .nearest) catch value;
            }
            try r.write(i, &f, pts);
            try g.mixOutput(node);
        }
        for (n.inputs, 0..) |in, i| {
            const st = g.acknowledgeStatus(in.?) orelse continue;
            if (st.status == .eof) {
                r.endInput(i);
                if (!r.isOn(i) and r.inputs == 1) return g.setInStatus(out, st.status, st.pts);
            }
        }
        if (r.ended()) return g.setInStatus(out, .eof, r.next_pts);
        if (g.linkAt(out).frame_wanted_out) {
            if (!r.isOn(0)) return g.mixRequest(node, 1);
            if (r.frameCount() == 0) return g.inlinkRequestFrame(n.inputs[0].?);
            return g.mixRequest(node, r.nextFrameSize());
        }
    }

    /// amix's `output_frame`, its result sent on.
    fn mixOutput(g: *Graph, node: u32) RunError!void {
        const n = &g.nodes.items[node];
        const out = n.outputs[0].?;
        switch (try n.run.mix.output()) {
            .none => {},
            .frame => |f| try g.filterFrame(out, f),
            .end => g.setInStatus(out, .eof, n.run.mix.next_pts),
        }
    }

    /// amix's `request_samples`: a frame wanted from the first open input
    /// short of `min` samples, else the output.
    fn mixRequest(g: *Graph, node: u32, min_in: u32) RunError!void {
        const n = &g.nodes.items[node];
        const r = &n.run.mix;
        // FFmpeg asserts several inputs here.
        if (r.inputs < 2) return g.mixOutput(node);
        var min = min_in;
        if (min == 1 and r.duration == .first) min = r.fifoSize(0);
        for (1..r.inputs) |i| {
            if (!r.isOn(i) or r.isEof(i)) continue;
            if (r.fifoSize(i) >= min) continue;
            return g.inlinkRequestFrame(n.inputs[i].?);
        }
        return g.mixOutput(node);
    }

    // Frames ----------------------------------------------------------------

    /// `av_buffersrc_add_frame` on source `i`: the frame is copied and
    /// queued on its link.
    pub fn sendTo(g: *Graph, i: usize, frame: Frame) SendError!void {
        if (!g.configured) return error.NotConfigured;
        const source = g.sources.items[i];
        const n = &g.nodes.items[source.node];
        if (n.kind.source.eof) return error.GraphEnded;
        g.freeLast();
        const out = n.outputs[0].?;
        const want = source.spec.format;
        // An unspecified layout takes the link's (config_props), and so
        // does a frame's of the same count.
        const layout = g.linkAt(out).layout;
        var frame_layout = frame.format.layout;
        if (frame_layout == .unspecified and frame_layout.channelCount() == layout.channelCount()) frame_layout = layout;
        if (frame.format.sample_rate != want.sample_rate or frame.format.sample_format != want.sample_format or !frame_layout.eql(&layout))
            return error.FormatChange;
        const count = std.math.cast(u32, frame.frameCount()) orelse return error.OutOfMemory;
        if (count == 0) return error.EmptyFrame;
        n.kind.source.last_pts = frame.pts;
        var format = frame.format;
        format.layout = layout;
        const owned = try Owned.alloc(g.gpa, format, count, frame.pts);
        @memcpy(owned.data, frame.data);
        try g.filterFrame(out, owned);
    }

    /// Ends source `i` (`av_buffersrc_add_frame(NULL)`). Idempotent.
    pub fn closeSource(g: *Graph, i: usize) void {
        const n = &g.nodes.items[g.sources.items[i].node];
        n.kind.source.eof = true;
        if (g.configured) g.setInStatus(n.outputs[0].?, .eof, n.kind.source.last_pts);
    }

    /// `av_buffersink_get_frame` on sink `j` (`get_frame_internal`).
    pub fn receiveFrom(g: *Graph, j: usize) ReceiveError!stage.Receive(Frame) {
        if (!g.configured) return error.NotConfigured;
        g.freeLast();
        const in = g.nodes.items[g.sinks.items[j].node].inputs[0].?;
        var sources_empty = false;
        while (true) {
            if (g.consumeFrame(in)) |o| {
                g.last = o;
                return .{ .output = .{ .format = o.format, .data = o.data, .pts = o.pts } };
            }
            if (g.acknowledgeStatus(in) != null) return .drained;
            if (g.linkAt(in).frame_wanted_out) {
                if (try g.runOnce()) |result| {
                    if (result == .buffersrc_empty) sources_empty = true;
                } else {
                    if (sources_empty) return .need_input;
                    g.inlinkRequestFrame(in);
                }
            } else {
                g.inlinkRequestFrame(in);
            }
        }
    }

    /// `sendTo` the first source, as a stage: always `accepted`, as
    /// libavfilter queues every frame.
    pub fn send(g: *Graph, frame: Frame) SendError!stage.Send {
        try g.sendTo(0, frame);
        return .accepted;
    }

    /// `closeSource` of the first source.
    pub fn finishInput(g: *Graph) void {
        g.closeSource(0);
    }

    /// `receiveFrom` the first sink.
    pub fn receive(g: *Graph) ReceiveError!stage.Receive(Frame) {
        return g.receiveFrom(0);
    }

    fn freeLast(g: *Graph) void {
        if (g.last) |*l| l.free(g.gpa);
        g.last = null;
    }
};

/// `av_frame_clone`, as an owned copy.
fn cloneOwned(gpa: std.mem.Allocator, f: *const Owned) error{OutOfMemory}!Owned {
    const copy = try Owned.alloc(gpa, f.format, f.frameCount(), f.pts);
    @memcpy(copy.data, f.data);
    return copy;
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
    const r = try g.receive();
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&[_]i16{ 2, -4, 32767 }), r.output.data);
    try testing.expectEqual(5, r.output.pts);
    try testing.expectEqual(.need_input, try g.receive());
    g.finishInput();
    try testing.expectEqual(.drained, try g.receive());
    try testing.expectError(error.GraphEnded, g.send(try Frame.fromS16(format, &values, 8)));
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
        hostile.fuzzSeed("\x00s16|flt", &.{}),
        hostile.fuzzSeed("\x028000|44100", &.{}),
        hostile.fuzzSeed("\x02stereo|5.1", &.{}),
        hostile.fuzzSeed("\x030.5", &.{}),
        hostile.fuzzSeed("\x05-1", &.{}),
        hostile.fuzzSeed("\x07FL+FR+LFE", &.{}),
        hostile.fuzzSeed("\x0911", &.{}),
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
        hostile.fuzzSeed("volume=0.5:fixed,aformat=s16p|flt:44100:mono", &.{}),
        hostile.fuzzSeed("aresample=48000:osf=s16p, volume@a='if(lt(t,1),n,2)':eval=frame", &.{}),
        hostile.fuzzSeed("[a]anull[b];volume", &.{}),
        hostile.fuzzSeed("sws_flags=x;volume=1\\,5", &.{}),
        hostile.fuzzSeed("atrim=0.001:duration=2ms,asetpts=N/SR/TB", &.{}),
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

fn branchingGraph(gpa: std.mem.Allocator) !void {
    const stereo = try audio.Format.init(8000, 2, .s16);
    const mono = try audio.Format.init(8000, 1, .flt);
    var g = try Graph.initGraph(gpa, &.{ .{ .name = "a", .spec = .{ .format = stereo } }, .{ .name = "b", .spec = .{ .format = mono } } }, "[a]asplit[x][y];[x]channelsplit[l][r];[l]pan=mono|c0=0.5*c0[l2];[l2][b]amix[out0];[y]channelmap=1|0[out1];[r]anull[out2]", &.{ .{ .name = "out0", .spec = .{} }, .{ .name = "out1", .spec = .{} }, .{ .name = "out2", .spec = .{} } }, .{ .max_queued_frames = 64 });
    defer g.deinit();
    try g.configure();
    var values: [200]i16 = @splat(1000);
    const floats: [100]f32 = @splat(0.25);
    for (0..2) |_| {
        try g.sendTo(0, try Frame.fromS16(stereo, &values, null));
        try g.sendTo(1, try Frame.init(mono, std.mem.sliceAsBytes(&floats), null));
        for (0..3) |j| while (try g.receiveFrom(j) == .output) {};
    }
    g.closeSource(0);
    g.closeSource(1);
    for (0..3) |j| while (try g.receiveFrom(j) == .output) {};
}

test "a branching graph leaks nothing when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, branchingGraph, .{});
}

test "the queue limit stops an unread branch" {
    const gpa = testing.allocator;
    const format = try audio.Format.init(8000, 1, .s16);
    var g = try Graph.initGraph(gpa, &.{.{ .name = "in", .spec = .{ .format = format } }}, "[in]asplit[out0][out1]", &.{ .{ .name = "out0", .spec = .{} }, .{ .name = "out1", .spec = .{} } }, .{ .max_queued_frames = 2 });
    defer g.deinit();
    try g.configure();
    const values = [_]i16{ 1, 2, 3, 4 };
    try g.sendTo(0, try Frame.fromS16(format, &values, 0));
    // Read on one branch: the other keeps every frame.
    try testing.expect(try g.receiveFrom(0) == .output);
    try testing.expectEqual(1, g.queued);
    try g.sendTo(0, try Frame.fromS16(format, &values, 4));
    try testing.expectError(error.QueueFull, g.receiveFrom(0));
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
                    try checkOutput(lines[at], frame);
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
                try checkOutput(lines[at], frame);
                at += 1;
            },
            .need_input => return error.TestUnexpectedResult,
            .drained => break,
        }
    }
    try testing.expectEqualStrings("D", lines[at]);
    try testing.expectEqual(lines.len, at + 1);
}

fn checkOutput(line: []const u8, frame: Frame) !void {
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
    try testing.expectEqualSlices(u8, expected, little[0..frame.data.len]);
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

// zig/testing/vectors/multigraph.txt comes from the pinned FFmpeg's
// libavfilter through zig/testing/reference/multigraph_vectors.c, which
// documents its lines.
const multi_vectors = @embedFile("../testing/vectors/multigraph.txt");
const multi_case_count = 48;

const MultiCase = struct {
    lines: []const []const u8,
    at: usize = 0,

    fn next(c: *MultiCase) []const u8 {
        if (c.at >= c.lines.len) return "";
        defer c.at += 1;
        return c.lines[c.at];
    }

    fn peek(c: *const MultiCase) []const u8 {
        return if (c.at < c.lines.len) c.lines[c.at] else "";
    }
};

/// A sink's frame against the next line, `O <sink> ...`.
fn expectFrame(arena: std.mem.Allocator, c: *MultiCase, sink: usize, frame: Frame) !void {
    const line = c.next();
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, fields.next() orelse "", "O")) {
        std.debug.print("an extra frame of {d} on sink {d}, wanted '{s}'\n", .{ frame.frameCount(), sink, line });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(sink, try std.fmt.parseInt(usize, fields.next().?, 10));
    try checkOutput(try arena.print("O {s}", .{fields.rest()}), frame);
}

fn expectEvent(c: *MultiCase, kind: []const u8, sink: usize) !void {
    const line = c.next();
    const want = try std.fmt.allocPrint(testing.allocator, "{s} {d}", .{ kind, sink });
    defer testing.allocator.free(want);
    if (!std.mem.eql(u8, line, want)) {
        std.debug.print("wanted '{s}', got '{s}'\n", .{ line, want });
        return error.TestUnexpectedResult;
    }
}

/// Reads sink `j` until it has no frame or ends; returns whether it ended.
fn readSink(arena: std.mem.Allocator, c: *MultiCase, g: *Graph, j: usize) !bool {
    while (true) {
        switch (try g.receiveFrom(j)) {
            .output => |frame| try expectFrame(arena, c, j, frame),
            .need_input => {
                try expectEvent(c, "W", j);
                return false;
            },
            .drained => {
                try expectEvent(c, "D", j);
                return true;
            },
        }
    }
}

fn runMultiCase(gpa: std.mem.Allocator, lines: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: MultiCase = .{ .lines = lines, .at = 1 };
    var buffer: [512]u8 = undefined;
    var sources: std.ArrayList(Named(SourceSpec)) = .empty;
    var first_pts: std.ArrayList(?i64) = .empty;
    while (std.mem.startsWith(u8, c.peek(), "I ")) {
        var fields = std.mem.tokenizeScalar(u8, c.next(), ' ');
        _ = fields.next();
        const i = try std.fmt.parseInt(usize, fields.next().?, 10);
        const sample_format = SampleFormat.fromName(fields.next().?).?;
        const rate = try std.fmt.parseInt(u32, fields.next().?, 10);
        const layout = try Layout.parse(try hexText(&buffer, fields.next().?));
        const tb = try time.TimeBase.init(try std.fmt.parseInt(u32, fields.next().?, 10), try std.fmt.parseInt(u32, fields.next().?, 10));
        const pts_text = fields.next().?;
        try first_pts.append(arena, if (std.mem.eql(u8, pts_text, "-")) null else try std.fmt.parseInt(i64, pts_text, 10));
        try sources.append(arena, .{ .name = try arena.print("in{d}", .{i}), .spec = .{ .format = try audio.Format.initLayout(rate, layout, sample_format), .time_base = tb } });
    }
    var sinks: std.ArrayList(Named(SinkSpec)) = .empty;
    while (std.mem.startsWith(u8, c.peek(), "K ")) {
        var fields = std.mem.tokenizeScalar(u8, c.next(), ' ');
        _ = fields.next();
        const j = try std.fmt.parseInt(usize, fields.next().?, 10);
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
        try sinks.append(arena, .{ .name = try arena.print("out{d}", .{j}), .spec = .{ .sample_formats = sink_formats.items, .sample_rates = sink_rates.items, .layouts = sink_layouts.items } });
    }
    const limit = try std.fmt.parseInt(u32, c.next()[2..], 10);
    const text = try arena.dupe(u8, try hexText(&buffer, c.next()[2..]));
    const script = c.next()[2..];
    const outcome = c.peek();
    var recorder: diagnostics.Recorder = .{};
    var g = Graph.initGraph(gpa, sources.items, text, sinks.items, .{ .max_queued_frames = limit, .diagnostics = recorder.sink(.err) }) catch |err| {
        if (std.mem.eql(u8, outcome, "X")) return;
        if (std.mem.eql(u8, outcome, "E parse")) {
            const want = try hexText(&buffer, lines[c.at + 1][2..]);
            if (recorder.count > 0) try testing.expectEqualStrings(want, recorder.firstMessage());
            return;
        }
        return err;
    };
    defer g.deinit();
    if (std.mem.eql(u8, outcome, "E parse") or std.mem.eql(u8, outcome, "X")) return error.TestUnexpectedResult;
    g.configure() catch |err| {
        if (std.mem.eql(u8, outcome, "E config")) return;
        return err;
    };
    // L: every filter's outputs, in graph order.
    for (g.nodes.items) |n| {
        for (n.outputs, 0..) |o, pad| {
            const l = &g.links.items[o.?];
            var describe: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&describe);
            try l.layout.describe(&w);
            var hex_layout: [512]u8 = undefined;
            var hw: std.Io.Writer = .fixed(&hex_layout);
            for (w.buffered()) |b| try hw.print("{x:0>2}", .{b});
            const want = try arena.print("L {s} {d} {s} {d} {s} {d} {s} {d} {d}", .{
                n.label,       pad,             g.nodes.items[l.dst].label, l.dst_pad, l.sample_format.name(), l.sample_rate,
                hw.buffered(), l.time_base.num, l.time_base.den,
            });
            try testing.expectEqualStrings(c.next(), want);
        }
    }
    // The script.
    var signals: std.ArrayList(resample.Signal) = .empty;
    var sent: std.ArrayList(u64) = .empty;
    for (sources.items, 0..) |_, i| {
        try signals.append(arena, .{ .state = 1 + i });
        try sent.append(arena, 0);
    }
    const ended = try arena.alloc(bool, sinks.items.len);
    @memset(ended, false);
    var steps = std.mem.tokenizeScalar(u8, script, ',');
    var step: usize = 0;
    while (steps.next()) |tok| : (step += 1) {
        const index = try std.fmt.parseInt(usize, std.mem.sliceTo(tok[1..], ':'), 10);
        const result: anyerror!void = switch (tok[0]) {
            's' => send: {
                const s = sources.items[index].spec;
                const n = try std.fmt.parseInt(u32, tok[std.mem.findScalar(u8, tok, ':').? + 1 ..], 10);
                const sample_format = s.format.sample_format;
                const channels = s.format.channelCount();
                const width = sample_format.bytesPerSample();
                const data = try arena.alloc(u8, n * s.format.bytesPerFrame());
                for (0..n) |k| {
                    for (0..channels) |ch| {
                        const offset = if (sample_format.isPlanar()) (ch * n + k) * width else (k * channels + ch) * width;
                        storeGenerated(data[offset..], sample_format, signals.items[index].next(ch));
                    }
                }
                const pts: ?i64 = if (first_pts.items[index]) |p| p + try time.rescale(@intCast(sent.items[index]), try time.TimeBase.ofSampleRate(s.format.sample_rate), s.time_base.?, .nearest) else null;
                sent.items[index] += n;
                break :send g.sendTo(index, try Frame.init(s.format, data, pts));
            },
            'c' => g.closeSource(index),
            'r' => read: {
                if (ended[index]) break :read;
                ended[index] = readSink(arena, &c, &g, index) catch |err| {
                    if (err == error.QueueFull) break :read err;
                    return err;
                };
            },
            else => return error.MalformedVector,
        };
        result catch |err| {
            if (err != error.QueueFull and err != error.GraphEnded) return err;
            try testing.expectEqualStrings(try arena.print("F {d}", .{step}), c.next());
            return;
        };
    }
    for (0..sinks.items.len) |j| {
        if (ended[j]) continue;
        ended[j] = readSink(arena, &c, &g, j) catch |err| {
            if (err != error.QueueFull) return err;
            try testing.expectEqualStrings(try arena.print("F {d}", .{step + j}), c.next());
            return;
        };
    }
    try testing.expectEqualStrings("Z", c.next());
    try testing.expectEqual(lines.len, c.at);
}

test "every graph of several inputs and outputs equals FFmpeg's" {
    const gpa = testing.allocator;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, multi_vectors, '\n');
    while (it.next()) |line| try lines.append(gpa, line);
    var count: usize = 0;
    var start: usize = 0;
    while (start < lines.items.len) : (count += 1) {
        var end = start + 1;
        while (end < lines.items.len and !std.mem.startsWith(u8, lines.items[end], "G ")) end += 1;
        runMultiCase(gpa, lines.items[start..end]) catch |err| {
            std.debug.print("multigraph vector {s}: {t}\n", .{ lines.items[start], err });
            return err;
        };
        start = end;
    }
    try testing.expectEqual(multi_case_count, count);
}

const hostile = @import("../testing/hostile.zig");
