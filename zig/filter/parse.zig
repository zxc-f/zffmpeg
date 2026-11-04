// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavfilter/graphparser.c (avfilter_graph_segment_parse, chain_parse,
// filter_parse, linklabels_parse, parse_link_name, parse_sws_flags),
// avfilter.c (ff_filter_opt_parse), libavutil/avstring.c (av_get_token) and
// opt.c (av_opt_get_key_value, get_key) at the pinned reference revision
// describe the behavior, restated here.
//! Filtergraph text (TODO.md T25b), parsed as `avfilter_graph_segment_parse`
//! parses it: an optional `sws_flags=...;` prefix, chains separated by `;`,
//! filters separated by `,`, each `[label]...name@instance=options[label]...`.
//! Tokens follow `av_get_token`: a backslash takes the next character as it
//! is, single quotes keep everything up to the next quote, surrounding
//! white space goes. Options are `ff_filter_opt_parse`'s `key=value` pairs
//! separated by `:`, a value without a key setting the filter's next
//! shorthand option until a key is given.
//!
//! The result keeps the labels and chains it found; the graph (graph.zig)
//! takes a single chain without labels, as T25b does. Error messages are
//! FFmpeg's, to the caller's diagnostic sink.

const std = @import("std");
const diagnostics = @import("../core/diagnostics.zig");
const filters = @import("filters.zig");

pub const Error = error{
    /// FFmpeg refuses the text too (`AVERROR(EINVAL)`).
    InvalidSyntax,
    OutOfMemory,
};

pub const Option = filters.Option;

pub const Filter = struct {
    /// The filter's name, before any `@`.
    name: []const u8,
    /// The instance name after `@`, or null.
    instance: ?[]const u8,
    /// The options in order, each shorthand value given its option's name.
    options: []const Option,
};

pub const Parsed = struct {
    /// Every chain's filters, in order.
    filters: []const Filter,
    chains: usize,
    /// Link labels were given.
    labels: bool,
};

/// graphparser.c's and avstring.c's `WHITESPACES`.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == '\r';
}

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,
    sink: ?diagnostics.Sink,

    fn cur(p: *const Parser) u8 {
        return if (p.pos < p.text.len) p.text[p.pos] else 0;
    }

    fn rest(p: *const Parser) []const u8 {
        return p.text[@min(p.pos, p.text.len)..];
    }

    fn skipSpace(p: *Parser) void {
        while (p.pos < p.text.len and isSpace(p.text[p.pos])) p.pos += 1;
    }

    fn fail(p: *const Parser, comptime format: []const u8, args: anytype) Error {
        diagnostics.report(p.sink, .err, format, args);
        return error.InvalidSyntax;
    }
};

/// `av_get_token` of `text` from `pos.*`, up to a character of `term`.
fn token(arena: std.mem.Allocator, text: []const u8, pos: *usize, term: []const u8) error{OutOfMemory}![]u8 {
    var p = pos.*;
    while (p < text.len and isSpace(text[p])) p += 1;
    var out: std.ArrayList(u8) = .empty;
    // Escaped and quoted characters are kept even when they are spaces.
    var end: usize = 0;
    while (p < text.len and std.mem.findScalar(u8, term, text[p]) == null) {
        const c = text[p];
        p += 1;
        if (c == '\\' and p < text.len) {
            try out.append(arena, text[p]);
            p += 1;
            end = out.items.len;
        } else if (c == '\'') {
            while (p < text.len and text[p] != '\'') : (p += 1) try out.append(arena, text[p]);
            if (p < text.len) {
                p += 1;
                end = out.items.len;
            }
        } else {
            try out.append(arena, c);
        }
    }
    while (out.items.len > end and isSpace(out.items[out.items.len - 1])) out.items.len -= 1;
    pos.* = p;
    return out.items;
}

/// `linklabels_parse`: `[label]` after `[label]`; returns how many.
fn labels(p: *Parser) Error!usize {
    var count: usize = 0;
    while (p.cur() == '[') {
        const start = p.pos;
        p.pos += 1;
        const name = try token(p.arena, p.text, &p.pos, "]");
        if (name.len == 0) return p.fail("Bad (empty?) label found in the following: \"{s}\".", .{p.text[start..]});
        if (p.cur() != ']') return p.fail("Mismatched '[' found in the following: \"{s}\".", .{p.text[start..]});
        p.pos += 1;
        count += 1;
        p.skipSpace();
    }
    return count;
}

/// `is_key_char`.
fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '/' or c == '.';
}

/// `ff_filter_opt_parse` of `args` for a filter whose shorthand options are
/// `shorthand`.
fn optionList(p: *Parser, args: []const u8, shorthand: []const []const u8) Error![]const Option {
    var list: std.ArrayList(Option) = .empty;
    var next_short: ?usize = 0;
    var pos: usize = 0;
    while (pos < args.len) {
        var short: ?[]const u8 = null;
        if (next_short) |i| {
            if (i < shorthand.len) {
                short = shorthand[i];
                next_short = i + 1;
            }
        }
        // get_key: a key, then '='.
        var q = pos;
        while (q < args.len and isSpace(args[q])) q += 1;
        const key_start = q;
        while (q < args.len and isKeyChar(args[q])) q += 1;
        const key_end = q;
        while (q < args.len and isSpace(args[q])) q += 1;
        var key: ?[]const u8 = null;
        if (q < args.len and args[q] == '=') {
            key = args[key_start..key_end];
            pos = q + 1;
        } else if (short == null) {
            return p.fail("No option name near '{s}'", .{args[pos..]});
        }
        const value = try token(p.arena, args, &pos, ":");
        if (pos < args.len) pos += 1;
        if (key) |k| {
            // A key ends the shorthand.
            next_short = null;
            try list.append(p.arena, .{ .name = k, .value = value });
        } else {
            try list.append(p.arena, .{ .name = short.?, .value = value });
        }
    }
    return list.items;
}

/// `filter_parse`.
fn filter(p: *Parser, found_labels: *bool) Error!Filter {
    if (try labels(p) > 0) found_labels.* = true;
    const full = try token(p.arena, p.text, &p.pos, "=,;[");
    var name: []const u8 = full;
    var instance: ?[]const u8 = null;
    if (std.mem.findScalar(u8, full, '@')) |at| {
        name = full[0..at];
        instance = full[at + 1 ..];
    }
    var opts: []const Option = &.{};
    if (p.cur() == '=') {
        p.pos += 1;
        const args = try token(p.arena, p.text, &p.pos, "[],;");
        const shorthand: []const []const u8 = if (filters.find(name)) |d| filters.Filter.shorthand(d.kind) else &.{};
        opts = try optionList(p, args, shorthand);
    }
    if (try labels(p) > 0) found_labels.* = true;
    p.skipSpace();
    return .{ .name = name, .instance = instance, .options = opts };
}

/// `avfilter_graph_segment_parse` of `text`, its storage from `arena`.
pub fn parse(arena: std.mem.Allocator, full_text: []const u8, sink: ?diagnostics.Sink) Error!Parsed {
    // A C string ends at its first NUL.
    const text = std.mem.sliceTo(full_text, 0);
    var p: Parser = .{ .arena = arena, .text = text, .sink = sink };
    var list: std.ArrayList(Filter) = .empty;
    var chains: usize = 0;
    var found_labels = false;
    p.skipSpace();
    if (std.mem.startsWith(u8, p.rest(), "sws_flags=")) {
        // Kept by FFmpeg for its scale filters, which audio graphs lack.
        const semicolon = std.mem.findScalarPos(u8, text, p.pos, ';') orelse return p.fail("sws_flags not terminated with ';'.", .{});
        p.pos = semicolon + 1;
    }
    p.skipSpace();
    while (p.pos < text.len) {
        // chain_parse.
        while (p.pos < text.len) {
            try list.append(arena, try filter(&p, &found_labels));
            const c = p.cur();
            if (c != 0 and c != ',' and c != ';') return p.fail("Trailing garbage after a filter: {s}", .{p.rest()});
            if (c != 0) {
                p.pos += 1;
                p.skipSpace();
                if (c == ';') break;
            }
        }
        chains += 1;
        p.skipSpace();
    }
    if (chains == 0) return p.fail("No filters specified in the graph description", .{});
    return .{ .filters = list.items, .chains = chains, .labels = found_labels };
}

const testing = std.testing;

test "tokens unquote and unescape as av_get_token does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var pos: usize = 0;
    try testing.expectEqualStrings("a b", try token(arena.allocator(), "  a b  ,c", &pos, ","));
    try testing.expectEqual(7, pos);
    pos = 0;
    try testing.expectEqualStrings("x,y ", try token(arena.allocator(), "'x,y '", &pos, ","));
    pos = 0;
    try testing.expectEqualStrings("1,5", try token(arena.allocator(), "1\\,5", &pos, ","));
}

test "a chain, its options and shorthand" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), " volume@loud=0.5:fixed , aformat=f=s16\\|flt ", null);
    try testing.expectEqual(1, parsed.chains);
    try testing.expectEqual(2, parsed.filters.len);
    try testing.expectEqualStrings("volume", parsed.filters[0].name);
    try testing.expectEqualStrings("loud", parsed.filters[0].instance.?);
    try testing.expectEqualStrings("precision", parsed.filters[0].options[1].name);
    try testing.expectEqualStrings("fixed", parsed.filters[0].options[1].value);
    try testing.expectEqualStrings("s16|flt", parsed.filters[1].options[0].value);
    var recorder: diagnostics.Recorder = .{};
    try testing.expectError(error.InvalidSyntax, parse(arena.allocator(), "volume=precision=fixed:0.5", recorder.sink(.err)));
    try testing.expectEqualStrings("No option name near '0.5'", recorder.lastMessage());
}
