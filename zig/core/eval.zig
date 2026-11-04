// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavutil/eval.c (av_expr_parse, parse_expr and the functions below it,
// eval_expr, verify_expr), sfc64.h and reverse.c at the pinned reference
// revision describe the behavior, restated here.
//! FFmpeg's expression evaluator (TODO.md T25b): `av_expr_parse` and
//! `av_expr_eval`, equal to them on zig/testing/vectors/eval.txt.
//!
//! White space is removed, then the text is parsed as FFmpeg's grammar:
//! `;` sequences, `+` and `-`, `*` and `/`, `^` (right after a factor),
//! a sign, numbers in `av_strtod`'s syntax (`44.1k`, `-3dB`), the caller's
//! named constants, `E`, `PI`, `PHI` and `QP2LAMBDA`, parentheses, and
//! FFmpeg's functions. Each expression has ten variables (`st`, `ld`) and
//! a random generator per variable, which persist across evaluations.
//!
//! Functions that call the C library (`sin`, `exp`, `pow`, `hypot`, ...)
//! use Zig's, which may differ from glibc's in the last bit, the tolerance
//! the project owner chose for the resampler (port.md "Resampling"); the
//! rest is exact. `time()`, which reads the clock, is refused
//! (`UnsupportedFunction`), and so are caller-supplied functions, which no
//! component uses.

const std = @import("std");
const number = @import("number.zig");
const diagnostics = @import("diagnostics.zig");

pub const ParseError = error{
    /// FFmpeg refuses the text too (`AVERROR(EINVAL)`).
    InvalidExpression,
    /// `time()`.
    UnsupportedFunction,
    OutOfMemory,
};

/// `VARS`: the variables `st` and `ld` reach.
pub const variable_count = 10;
const max_depth = 100;

const Func0 = enum { sinh, cosh, tanh, sin, cos, tan, atan, asin, acos, exp, log, abs };

const Kind = enum {
    value,
    constant,
    func0,
    squish,
    gauss,
    ld,
    isnan,
    isinf,
    mod,
    max,
    min,
    eq,
    gt,
    gte,
    lte,
    lt,
    pow,
    mul,
    div,
    add,
    last,
    st,
    @"while",
    taylor,
    root,
    floor,
    ceil,
    trunc,
    round,
    sqrt,
    not,
    random,
    hypot,
    gcd,
    @"if",
    ifnot,
    print,
    bitand,
    bitor,
    between,
    clip,
    atan2,
    lerp,
    sgn,
    randomi,
};

/// The functions by name, in FFmpeg's matching order.
const functions = [_]struct { name: []const u8, kind: Kind, func: Func0 = .abs }{
    .{ .name = "sinh", .kind = .func0, .func = .sinh },
    .{ .name = "cosh", .kind = .func0, .func = .cosh },
    .{ .name = "tanh", .kind = .func0, .func = .tanh },
    .{ .name = "sin", .kind = .func0, .func = .sin },
    .{ .name = "cos", .kind = .func0, .func = .cos },
    .{ .name = "tan", .kind = .func0, .func = .tan },
    .{ .name = "atan", .kind = .func0, .func = .atan },
    .{ .name = "asin", .kind = .func0, .func = .asin },
    .{ .name = "acos", .kind = .func0, .func = .acos },
    .{ .name = "exp", .kind = .func0, .func = .exp },
    .{ .name = "log", .kind = .func0, .func = .log },
    .{ .name = "abs", .kind = .func0, .func = .abs },
    // "time" comes here; see `parsePrimary`.
    .{ .name = "squish", .kind = .squish },
    .{ .name = "gauss", .kind = .gauss },
    .{ .name = "mod", .kind = .mod },
    .{ .name = "max", .kind = .max },
    .{ .name = "min", .kind = .min },
    .{ .name = "eq", .kind = .eq },
    .{ .name = "gte", .kind = .gte },
    .{ .name = "gt", .kind = .gt },
    .{ .name = "lte", .kind = .lte },
    .{ .name = "lt", .kind = .lt },
    .{ .name = "ld", .kind = .ld },
    .{ .name = "isnan", .kind = .isnan },
    .{ .name = "isinf", .kind = .isinf },
    .{ .name = "st", .kind = .st },
    .{ .name = "while", .kind = .@"while" },
    .{ .name = "taylor", .kind = .taylor },
    .{ .name = "root", .kind = .root },
    .{ .name = "floor", .kind = .floor },
    .{ .name = "ceil", .kind = .ceil },
    .{ .name = "trunc", .kind = .trunc },
    .{ .name = "round", .kind = .round },
    .{ .name = "sqrt", .kind = .sqrt },
    .{ .name = "not", .kind = .not },
    .{ .name = "pow", .kind = .pow },
    .{ .name = "print", .kind = .print },
    .{ .name = "random", .kind = .random },
    .{ .name = "randomi", .kind = .randomi },
    .{ .name = "hypot", .kind = .hypot },
    .{ .name = "gcd", .kind = .gcd },
    .{ .name = "if", .kind = .@"if" },
    .{ .name = "ifnot", .kind = .ifnot },
    .{ .name = "bitand", .kind = .bitand },
    .{ .name = "bitor", .kind = .bitor },
    .{ .name = "between", .kind = .between },
    .{ .name = "clip", .kind = .clip },
    .{ .name = "atan2", .kind = .atan2 },
    .{ .name = "lerp", .kind = .lerp },
    .{ .name = "sgn", .kind = .sgn },
};

const builtin_constants = [_]struct { name: []const u8, value: f64 }{
    .{ .name = "E", .value = std.math.e },
    .{ .name = "PI", .value = std.math.pi },
    .{ .name = "PHI", .value = std.math.phi },
    .{ .name = "QP2LAMBDA", .value = 118 },
};

const Node = struct {
    kind: Kind,
    /// The number of a `value`; the factor (a sign) of everything else.
    value: f64,
    func: Func0 = .abs,
    /// A constant's index.
    index: u32 = 0,
    params: [3]?u32 = .{ null, null, null },
    depth: u16 = 0,
};

/// libavutil's `FFSFC64`.
const Sfc64 = struct {
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    counter: u64 = 0,

    fn get(s: *Sfc64) u64 {
        const tmp = s.a +% s.b +% s.counter;
        s.counter +%= 1;
        s.a = s.b ^ (s.b >> 11);
        s.b = s.c +% (s.c << 3);
        s.c = std.math.rotl(u64, s.c, 24) +% tmp;
        return tmp;
    }

    fn init(seed: u64) Sfc64 {
        var s: Sfc64 = .{ .a = seed, .b = seed, .c = seed, .counter = 1 };
        for (0..12) |_| _ = s.get();
        return s;
    }
};

/// A parsed expression with its variables and random state.
pub const Expr = struct {
    gpa: std.mem.Allocator,
    nodes: []Node,
    root: u32,
    vars: [variable_count]f64 = @splat(0),
    prng: [variable_count]Sfc64 = @splat(.{}),
    /// Where `print` and the parse errors go.
    sink: ?diagnostics.Sink,

    /// `av_expr_parse` with the constants `names`, whose values `eval`
    /// takes in the same order.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8, names: []const []const u8, sink: ?diagnostics.Sink) ParseError!Expr {
        const stripped = try gpa.alloc(u8, text.len);
        defer gpa.free(stripped);
        var len: usize = 0;
        for (text) |c| {
            if (isSpace(c)) continue;
            stripped[len] = c;
            len += 1;
        }
        var p: Parser = .{ .gpa = gpa, .s = stripped[0..len], .names = names, .sink = sink, .text = text };
        defer p.nodes.deinit(gpa);
        const root = try p.parseExpr();
        if (p.pos < p.s.len) {
            diagnostics.report(sink, .err, "Invalid chars '{s}' at the end of expression '{s}'", .{ p.s[p.pos..], text });
            return error.InvalidExpression;
        }
        if (!p.verify(root)) return error.InvalidExpression;
        return .{ .gpa = gpa, .nodes = try p.nodes.toOwnedSlice(gpa), .root = root, .sink = sink };
    }

    pub fn deinit(e: *Expr) void {
        e.gpa.free(e.nodes);
        e.* = undefined;
    }

    /// Whether the expression names constant `index` (of the parse's
    /// `names`).
    pub fn usesConstant(e: *const Expr, index: usize) bool {
        for (e.nodes) |n| {
            if (n.kind == .constant and n.index == index) return true;
        }
        return false;
    }

    /// `av_expr_eval` with the constants' `values`.
    pub fn eval(e: *Expr, values: []const f64) f64 {
        return e.evalNode(e.root, values);
    }

    fn param(e: *Expr, n: *const Node, i: usize, values: []const f64) f64 {
        return e.evalNode(n.params[i].?, values);
    }

    fn evalNode(e: *Expr, index: u32, values: []const f64) f64 {
        const n = &e.nodes[index];
        const v = n.value;
        switch (n.kind) {
            .value => return v,
            .constant => return v * values[n.index],
            .func0 => return v * func0(n.func, e.param(n, 0, values)),
            .squish => return v / (1 + @exp(4 * e.param(n, 0, values))),
            .gauss => {
                const d = e.param(n, 0, values);
                // C's sqrt(2 * M_PI): of the double, not of the exact 2π.
                const two_pi: f64 = 2 * std.math.pi;
                return v * @exp(-d * d / 2) / @sqrt(two_pi);
            },
            .ld => return v * e.vars[varIndex(e.param(n, 0, values))],
            .isnan => return v * boolValue(std.math.isNan(e.param(n, 0, values))),
            .isinf => return v * boolValue(std.math.isInf(e.param(n, 0, values))),
            .floor => return v * @floor(e.param(n, 0, values)),
            .ceil => return v * @ceil(e.param(n, 0, values)),
            .trunc => return v * @trunc(e.param(n, 0, values)),
            .round => return v * @round(e.param(n, 0, values)),
            .sgn => {
                const d = e.param(n, 0, values);
                return v * (boolValue(d > 0) - boolValue(d < 0));
            },
            .sqrt => return v * @sqrt(e.param(n, 0, values)),
            .not => return v * boolValue(e.param(n, 0, values) == 0),
            .@"if", .ifnot => {
                const c = e.param(n, 0, values) != 0;
                const chosen = if (n.kind == .@"if") c else !c;
                if (chosen) return v * e.param(n, 1, values);
                return v * (if (n.params[2] != null) e.param(n, 2, values) else 0);
            },
            .clip => {
                const x = e.param(n, 0, values);
                const min = e.param(n, 1, values);
                const max = e.param(n, 2, values);
                if (std.math.isNan(min) or std.math.isNan(max) or std.math.isNan(x) or min > max) return std.math.nan(f64);
                return v * (if (x < min) min else if (x > max) max else x);
            },
            .between => {
                const d = e.param(n, 0, values);
                return v * boolValue(d >= e.param(n, 1, values) and d <= e.param(n, 2, values));
            },
            .lerp => {
                const v0 = e.param(n, 0, values);
                const v1 = e.param(n, 1, values);
                const f = e.param(n, 2, values);
                return v * (v0 + (v1 - v0) * f);
            },
            .print => {
                const x = e.param(n, 0, values);
                const level: i32 = if (n.params[1] != null) cInt(e.param(n, 1, values)) else 32;
                if (e.sink) |sink| {
                    for (std.enums.values(diagnostics.Level)) |l| {
                        if (@backingInt(l) == level) sink.log(l, "{d:.6}", .{x});
                    }
                }
                return v * x;
            },
            .random => {
                const r = e.nextRandom(e.param(n, 0, values));
                const r_f: f64 = @floatFromInt(r);
                return r_f * (1.0 / 18446744073709551615.0);
            },
            .randomi => {
                const min = e.param(n, 1, values);
                const max = e.param(n, 2, values);
                const r = e.nextRandom(e.param(n, 0, values));
                const r_f: f64 = @floatFromInt(r);
                return min + (max - min) * r_f / 18446744073709551615.0;
            },
            .@"while" => {
                var d = std.math.nan(f64);
                while (e.param(n, 0, values) != 0) d = e.param(n, 1, values);
                return d;
            },
            .taylor => {
                var t: f64 = 1;
                var d: f64 = 0;
                const x = e.param(n, 1, values);
                const id = if (n.params[2] != null) varIndex(e.param(n, 2, values)) else 0;
                const var0 = e.vars[id];
                for (0..1000) |i| {
                    const ld = d;
                    e.vars[id] = @floatFromInt(i);
                    const value = e.param(n, 0, values);
                    d += t * value;
                    if (ld == d and value != 0) break;
                    const next: f64 = @floatFromInt(i + 1);
                    t *= x / next;
                }
                e.vars[id] = var0;
                return d;
            },
            .root => return e.findRoot(n, values),
            else => {
                const d = e.param(n, 0, values);
                const d2 = e.param(n, 1, values);
                return switch (n.kind) {
                    .mod => v * (d - @floor(if (d2 != 0) d / d2 else d * std.math.inf(f64)) * d2),
                    .gcd => v * intValue(gcd(cLong(d), cLong(d2))),
                    .max => v * (if (d > d2) d else d2),
                    .min => v * (if (d < d2) d else d2),
                    .eq => v * boolValue(d == d2),
                    .gt => v * boolValue(d > d2),
                    .gte => v * boolValue(d >= d2),
                    .lt => v * boolValue(d < d2),
                    .lte => v * boolValue(d <= d2),
                    .pow => v * std.math.pow(f64, d, d2),
                    .mul => v * (d * d2),
                    .div => v * (if (d2 != 0) d / d2 else d * std.math.inf(f64)),
                    .add => v * (d + d2),
                    .last => v * d2,
                    .st => st: {
                        const i = varIndex(d);
                        e.prng[i].counter = 0;
                        e.vars[i] = d2;
                        break :st v * d2;
                    },
                    .hypot => v * std.math.hypot(d, d2),
                    .atan2 => v * std.math.atan2(d, d2),
                    .bitand => if (std.math.isNan(d) or std.math.isNan(d2)) std.math.nan(f64) else v * intValue(cLong(d) & cLong(d2)),
                    .bitor => if (std.math.isNan(d) or std.math.isNan(d2)) std.math.nan(f64) else v * intValue(cLong(d) | cLong(d2)),
                    else => unreachable, // every other kind is handled above
                };
            },
        }
    }

    /// `COMPUTE_NEXT_RANDOM`: variable `at`'s generator, seeded from the
    /// variable on first use; the variable then holds the number.
    fn nextRandom(e: *Expr, at: f64) u64 {
        const idx = varIndex(at);
        const s = &e.prng[idx];
        if (s.counter == 0) {
            const seed: u64 = if (std.math.isNan(e.vars[idx])) 0 else cU64(e.vars[idx]);
            s.* = .init(seed);
        }
        const r = s.get();
        e.vars[idx] = @floatFromInt(r);
        return r;
    }

    /// `root(expr, max)`: a zero of `expr` in variable 0, searched as
    /// FFmpeg searches it.
    fn findRoot(e: *Expr, n: *const Node, values: []const f64) f64 {
        var low: f64 = -1;
        var high: f64 = -1;
        var low_v: f64 = -std.math.floatMax(f64);
        var high_v: f64 = std.math.floatMax(f64);
        const var0 = e.vars[0];
        const x_max = e.param(n, 1, values);
        var i: i32 = -1;
        while (i < 1024) : (i += 1) {
            if (i < 255) {
                const reversed: f64 = @floatFromInt(@bitReverse(@as(u8, @truncate(@as(u32, @bitCast(i))))));
                e.vars[0] = reversed * x_max / 255;
            } else {
                const power: f64 = @floatFromInt(i - 255);
                e.vars[0] = x_max * std.math.pow(f64, 0.9, power);
                if (i & 1 != 0) e.vars[0] *= -1;
                if (i & 2 != 0) e.vars[0] += low else e.vars[0] += high;
            }
            var v = e.param(n, 0, values);
            if (v <= 0 and v > low_v) {
                low = e.vars[0];
                low_v = v;
            }
            if (v >= 0 and v < high_v) {
                high = e.vars[0];
                high_v = v;
            }
            if (low >= 0 and high >= 0) {
                for (0..1000) |_| {
                    e.vars[0] = (low + high) * 0.5;
                    if (low == e.vars[0] or high == e.vars[0]) break;
                    v = e.param(n, 0, values);
                    if (v <= 0) low = e.vars[0];
                    if (v >= 0) high = e.vars[0];
                    if (std.math.isNan(v)) {
                        low = v;
                        high = v;
                        break;
                    }
                }
                break;
            }
        }
        e.vars[0] = var0;
        return if (-low_v < high_v) low else high;
    }
};

fn func0(f: Func0, x: f64) f64 {
    return switch (f) {
        .sinh => std.math.sinh(x),
        .cosh => std.math.cosh(x),
        .tanh => std.math.tanh(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .tan => @tan(x),
        .atan => std.math.atan(x),
        .asin => std.math.asin(x),
        .acos => std.math.acos(x),
        .exp => @exp(x),
        .log => @log(x),
        .abs => @abs(x),
    };
}

fn boolValue(b: bool) f64 {
    return if (b) 1 else 0;
}

fn intValue(x: i64) f64 {
    return @floatFromInt(x);
}

/// A double converted to `int` as x86 converts one: out of range or NaN
/// gives `INT_MIN` (C leaves it undefined).
fn cInt(x: f64) i32 {
    if (!(x > -2147483649.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(@trunc(x));
}

/// The same for a 64-bit `long`.
fn cLong(x: f64) i64 {
    if (!(x >= -9223372036854775808.0 and x < 9223372036854775808.0)) return std.math.minInt(i64);
    return @intFromFloat(@trunc(x));
}

/// A double converted to `uint64_t` as clang lowers it on x86.
fn cU64(x: f64) u64 {
    const two63: f64 = 9223372036854775808.0;
    if (x < two63) return @bitCast(cLong(x));
    const high: u64 = @bitCast(cLong(x - two63));
    return high ^ (@as(u64, 1) << 63);
}

/// `av_clip(x, 0, VARS - 1)` of a double.
fn varIndex(x: f64) usize {
    return @intCast(std.math.clamp(cInt(x), 0, variable_count - 1));
}

/// `av_gcd`.
fn gcd(a: i64, b: i64) i64 {
    if (a == 0) return b;
    if (b == 0) return a;
    const za = @ctz(a);
    const zb = @ctz(b);
    const k = @min(za, zb);
    var u: i64 = wrappingAbs(a >> @intCast(za));
    var v: i64 = wrappingAbs(b >> @intCast(zb));
    while (u != v) {
        if (u > v) std.mem.swap(i64, &u, &v);
        v -%= u;
        v >>= @intCast(@ctz(v));
    }
    const shifted: u64 = @as(u64, @bitCast(u)) << @intCast(k);
    return @bitCast(shifted);
}

fn wrappingAbs(x: i64) i64 {
    return if (x < 0) 0 -% x else x;
}

/// `av_isspace`.
fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// `IS_IDENTIFIER_CHAR`.
fn isIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const Parser = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    /// The text without white space.
    s: []const u8,
    pos: usize = 0,
    /// `stack_index`: how many more nested `parseExpr` calls are allowed.
    stack: i32 = 100,
    names: []const []const u8,
    sink: ?diagnostics.Sink,
    /// The original text, for messages.
    text: []const u8,

    fn at(p: *const Parser, i: usize) u8 {
        return if (i < p.s.len) p.s[i] else 0;
    }

    fn cur(p: *const Parser) u8 {
        return p.at(p.pos);
    }

    fn add(p: *Parser, node: Node) error{OutOfMemory}!u32 {
        try p.nodes.append(p.gpa, node);
        return @intCast(p.nodes.items.len - 1);
    }

    /// `strmatch`: `prefix` at `start`, not followed by an identifier
    /// character.
    fn matches(p: *const Parser, start: usize, prefix: []const u8) bool {
        if (!std.mem.startsWith(u8, p.s[@min(start, p.s.len)..], prefix)) return false;
        return !isIdentifier(p.at(start + prefix.len));
    }

    /// `make_eval_expr`.
    fn binary(p: *Parser, kind: Kind, a: u32, b: u32) ParseError!u32 {
        const depth = @max(p.nodes.items[a].depth, p.nodes.items[b].depth) + 1;
        if (depth > max_depth) return error.InvalidExpression;
        return p.add(.{ .kind = kind, .value = 1, .params = .{ a, b, null }, .depth = depth });
    }

    fn parseExpr(p: *Parser) ParseError!u32 {
        if (p.stack <= 0) return error.InvalidExpression;
        p.stack -= 1;
        var e0 = try p.parseSubexpr();
        while (p.cur() == ';') {
            p.pos += 1;
            const e2 = try p.parseSubexpr();
            e0 = try p.binary(.last, e0, e2);
        }
        p.stack += 1;
        return e0;
    }

    fn parseSubexpr(p: *Parser) ParseError!u32 {
        var e0 = try p.parseTerm();
        while (p.cur() == '+' or p.cur() == '-') {
            const e2 = try p.parseTerm();
            e0 = try p.binary(.add, e0, e2);
        }
        return e0;
    }

    fn parseTerm(p: *Parser) ParseError!u32 {
        var e0 = try p.parseFactor();
        while (p.cur() == '*' or p.cur() == '/') {
            const c = p.cur();
            p.pos += 1;
            const e2 = try p.parseFactor();
            e0 = try p.binary(if (c == '*') .mul else .div, e0, e2);
        }
        return e0;
    }

    fn parseFactor(p: *Parser) ParseError!u32 {
        var sign: i32 = undefined;
        var e0 = try p.parseDb(&sign);
        while (p.cur() == '^') {
            p.pos += 1;
            var sign2: i32 = undefined;
            const e2 = try p.parseDb(&sign2);
            e0 = try p.binary(.pow, e0, e2);
            p.nodes.items[e2].value *= signFactor(sign2);
        }
        p.nodes.items[e0].value *= signFactor(sign);
        return e0;
    }

    fn signFactor(sign: i32) f64 {
        return @floatFromInt(sign | 1);
    }

    /// `parse_dB`: `-3dB` is not `-(3dB)`.
    fn parseDb(p: *Parser, sign: *i32) ParseError!u32 {
        if (p.cur() == '-') {
            const n = number.strtod(p.s[p.pos..]);
            if (n.end != 0 and p.at(p.pos + n.end) == 'd' and p.at(p.pos + n.end + 1) == 'B') {
                sign.* = 0;
                return p.parsePrimary();
            }
        }
        // parse_pow.
        sign.* = @as(i32, @intFromBool(p.cur() == '+')) - @intFromBool(p.cur() == '-');
        if (sign.* & 1 != 0) p.pos += 1;
        return p.parsePrimary();
    }

    fn parsePrimary(p: *Parser) ParseError!u32 {
        const start = p.pos;
        const n = number.avStrtod(p.s[p.pos..]);
        if (n.end != 0) {
            p.pos += n.end;
            return p.add(.{ .kind = .value, .value = n.value });
        }
        for (p.names, 0..) |name, i| {
            if (p.matches(start, name)) {
                p.pos += name.len;
                return p.add(.{ .kind = .constant, .value = 1, .index = @intCast(i) });
            }
        }
        for (builtin_constants) |c| {
            if (p.matches(start, c.name)) {
                p.pos += c.name.len;
                return p.add(.{ .kind = .value, .value = c.value });
            }
        }
        const paren = std.mem.findScalarPos(u8, p.s, start, '(') orelse {
            diagnostics.report(p.sink, .err, "Undefined constant or missing '(' in '{s}'", .{p.s[start..]});
            return error.InvalidExpression;
        };
        p.pos = paren + 1;
        if (p.at(start) == '(') {
            // A parenthesized expression.
            const inner = try p.parseExpr();
            if (p.cur() != ')') {
                diagnostics.report(p.sink, .err, "Missing ')' in '{s}'", .{p.s[start..]});
                return error.InvalidExpression;
            }
            p.pos += 1;
            return inner;
        }
        var params: [3]?u32 = .{ try p.parseExpr(), null, null };
        // FFmpeg ignores a failed second or third argument.
        if (p.cur() == ',') {
            p.pos += 1;
            params[1] = p.parseExpr() catch null;
        }
        if (p.cur() == ',') {
            p.pos += 1;
            params[2] = p.parseExpr() catch null;
        }
        if (p.cur() != ')') {
            diagnostics.report(p.sink, .err, "Missing ')' or too many args in '{s}'", .{p.s[start..]});
            return error.InvalidExpression;
        }
        p.pos += 1;
        var depth: u16 = 0;
        for (params) |maybe| {
            if (maybe) |i| depth = @max(depth, p.nodes.items[i].depth + 1);
        }
        if (depth > max_depth) return error.InvalidExpression;
        for (functions, 0..) |f, i| {
            // "time" is matched after "abs".
            if (i == 12 and p.matches(start, "time")) return error.UnsupportedFunction;
            if (p.matches(start, f.name)) return p.add(.{ .kind = f.kind, .value = 1, .func = f.func, .params = params, .depth = depth });
        }
        diagnostics.report(p.sink, .err, "Unknown function in '{s}'", .{p.s[start..]});
        return error.InvalidExpression;
    }

    /// `verify_expr`: each function has its number of arguments.
    fn verify(p: *const Parser, maybe: ?u32) bool {
        const index = maybe orelse return false;
        const n = p.nodes.items[index];
        const ps = n.params;
        return switch (n.kind) {
            .value, .constant => true,
            .func0, .squish, .ld, .gauss, .isnan, .isinf, .floor, .ceil, .trunc, .round, .sqrt, .not, .random, .sgn => p.verify(ps[0]) and ps[1] == null,
            .print => p.verify(ps[0]) and (ps[1] == null or p.verify(ps[1])),
            .@"if", .ifnot, .taylor => p.verify(ps[0]) and p.verify(ps[1]) and (ps[2] == null or p.verify(ps[2])),
            .between, .clip, .lerp, .randomi => p.verify(ps[0]) and p.verify(ps[1]) and p.verify(ps[2]),
            else => p.verify(ps[0]) and p.verify(ps[1]) and ps[2] == null,
        };
    }
};

comptime {
    // `time` sits between "abs" and "squish" in FFmpeg's chain.
    std.debug.assert(std.mem.eql(u8, functions[11].name, "abs") and std.mem.eql(u8, functions[12].name, "squish"));
}

const testing = std.testing;

// zig/testing/vectors/eval.txt comes from the pinned FFmpeg's libavutil
// through zig/testing/reference/eval_vectors.c, which documents its lines.
const vectors = @embedFile("../testing/vectors/eval.txt");
const vector_count = 200;
const libm_names = [_][]const u8{ "sin", "cos", "tan", "exp", "log", "pow", "hypot", "atan", "squish", "gauss", "root", "dB", "^" };

fn expected(text: []const u8) !f64 {
    if (std.mem.eql(u8, text, "nan")) return std.math.nan(f64);
    if (std.mem.eql(u8, text, "inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, text, "-inf")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, text);
}

test "expressions equal FFmpeg's on every vector" {
    const gpa = testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    var count: usize = 0;
    var tolerated: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next().?;
        const hex = fields.next().?;
        var buffer: [512]u8 = undefined;
        const text = if (std.mem.eql(u8, hex, "-")) "" else try std.fmt.hexToBytes(&buffer, hex);
        errdefer std.debug.print("expression vector {d}: '{s}'\n", .{ count + 1, text });
        if (kind[0] == 'X') {
            try testing.expectError(error.UnsupportedFunction, Expr.parse(gpa, text, &.{ "x", "y", "n" }, null));
            continue;
        }
        const first = fields.next().?;
        if (std.mem.eql(u8, first, "E")) {
            if (Expr.parse(gpa, text, &.{ "x", "y", "n" }, null)) |parsed| {
                var e = parsed;
                e.deinit();
                return error.TestUnexpectedResult;
            } else |err| try testing.expectEqual(error.InvalidExpression, err);
            continue;
        }
        var e = try Expr.parse(gpa, text, &.{ "x", "y", "n" }, null);
        defer e.deinit();
        var want_text: ?[]const u8 = first;
        for (0..3) |_| {
            const want = try expected(want_text.?);
            const got = e.eval(&.{ 0.5, -3, 7 });
            want_text = fields.next();
            if (std.math.isNan(want)) {
                try testing.expect(std.math.isNan(got));
            } else if (@as(u64, @bitCast(want)) != @as(u64, @bitCast(got))) {
                // The C library's functions: within 4 units in the last place.
                const libm = for (libm_names) |name| {
                    if (std.mem.find(u8, text, name) != null) break true;
                } else false;
                if (!libm or !std.math.approxEqRel(f64, want, got, std.math.ldexp(@as(f64, 1), -50))) {
                    std.debug.print("want {e}, got {e}\n", .{ want, got });
                    return error.TestExpectedEqual;
                }
                tolerated += 1;
            }
        }
    }
    try testing.expectEqual(vector_count, count);
}

test "a parse error is reported to the sink" {
    var recorder: diagnostics.Recorder = .{};
    try testing.expectError(error.InvalidExpression, Expr.parse(testing.allocator, "foo + 1", &.{}, recorder.sink(.err)));
    try testing.expectEqualStrings("Undefined constant or missing '(' in 'foo+1'", recorder.lastMessage());
}

fn parseAndFree(gpa: std.mem.Allocator) !void {
    var e = try Expr.parse(gpa, "st(0,1);while(lt(ld(0),5),st(0,ld(0)*2))+max(x,PI)", &.{"x"}, null);
    defer e.deinit();
    try testing.expectEqual(8 + std.math.pi, e.eval(&.{1}));
}

test "parsing leaks nothing when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAndFree, .{});
}
