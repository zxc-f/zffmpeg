// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavutil/opt.c (av_opt_set: set_string_number, set_string_bool,
// write_number) and eval.c (whitespace removal, the default, min, max, none
// and all constants) at the pinned reference revision describe the
// behavior.
//! Typed component options (TODO.md T17a): a component's options struct
//! declares `option_specs`, FFmpeg's names, help, ranges and named
//! constants for its fields, which `check` validates at compile time, and
//! `set` sets one from text as FFmpeg's `av_opt_set` does, equal to it on
//! zig/testing/vectors/options.txt.
//!
//! A number is `av_strtod`'s (core/number.zig) after white space is
//! removed, a named constant of the option, or one of `default`, `min`,
//! `max`, `none` (0) and `all` (-1); integers round to nearest, ties to
//! even, as `llrint` does; a value outside the range, or NaN, is refused.
//! FFmpeg reads any other text as an expression (`16*2`, `PI`); until its
//! evaluator is ported (T25b) such text is `InvalidValue`. A boolean takes
//! `true`, `y`, `yes`, `enable`, `enabled`, `on` and their negatives,
//! case-insensitively, or a decimal integer, within the range.

const std = @import("std");
const number = @import("number.zig");

pub const Kind = enum { int, bool, double, float };

/// A named value of an option (`AV_OPT_TYPE_CONST` in its unit).
pub const Constant = struct { name: []const u8, value: f64 };

pub const Spec = struct {
    /// FFmpeg's name; two specs may set the same field (an alias).
    name: []const u8,
    /// The options struct's field it sets.
    field: []const u8,
    kind: Kind,
    help: []const u8,
    min: f64,
    max: f64,
    constants: []const Constant = &.{},
};

pub const SetError = error{
    /// No option of that name.
    UnknownOption,
    /// Not a value of the option (or an expression; T25b).
    InvalidValue,
    /// A number outside the option's range.
    OutOfRange,
};

/// Validates `T.option_specs` at compile time: every field described, each
/// spec's field present and of a type its kind can hold, names unique, and
/// each default within its range.
pub fn check(comptime T: type) void {
    comptime {
        const specs = T.option_specs;
        const info = @typeInfo(T).@"struct";
        for (info.field_names) |field| {
            for (specs) |spec| {
                if (std.mem.eql(u8, spec.field, field)) break;
            } else @compileError("option field without a spec: " ++ field);
        }
        for (specs, 0..) |spec, i| {
            if (!@hasField(T, spec.field)) @compileError("spec of a missing field: " ++ spec.field);
            for (specs[i + 1 ..]) |other| {
                if (std.mem.eql(u8, spec.name, other.name)) @compileError("duplicate option name: " ++ spec.name);
            }
            const F = @FieldType(T, spec.field);
            switch (spec.kind) {
                .bool => if (F != bool) @compileError("a bool option needs a bool field: " ++ spec.field),
                .double => if (F != f64) @compileError("a double option needs an f64 field: " ++ spec.field),
                .float => if (F != f32) @compileError("a float option needs an f32 field: " ++ spec.field),
                .int => switch (@typeInfo(F)) {
                    .int, .@"enum" => {},
                    else => @compileError("an int option needs an integer or enum field: " ++ spec.field),
                },
            }
            const default = defaultOf(T, spec);
            if (default < spec.min or default > spec.max) @compileError("default out of range: " ++ spec.name);
        }
    }
}

/// The field's default as `av_opt_set` sees it, a double.
fn defaultOf(comptime T: type, comptime spec: Spec) f64 {
    const defaults: T = .{};
    const value = @field(defaults, spec.field);
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (value) 1 else 0,
        .int => @floatFromInt(value),
        .@"enum" => @floatFromInt(@backingInt(value)),
        .float => value,
        else => unreachable,
    };
}

/// Sets the option `name` of `target` from `text`, as `av_opt_set` would.
/// Nothing changes when it fails.
pub fn set(comptime T: type, target: *T, name: []const u8, text: []const u8) SetError!void {
    inline for (T.option_specs) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return setOne(T, spec, target, text);
    }
    return error.UnknownOption;
}

fn setOne(comptime T: type, comptime spec: Spec, target: *T, text: []const u8) SetError!void {
    const F = @FieldType(T, spec.field);
    if (spec.kind == .bool) {
        const n = boolValue(text) orelse return error.InvalidValue;
        const n_f: f64 = @floatFromInt(n);
        if (n_f < spec.min or n_f > spec.max) return error.InvalidValue;
        @field(target, spec.field) = n != 0;
        return;
    }
    const value = try numberValue(spec, defaultOf(T, spec), text);
    if (value < spec.min or value > spec.max) return error.OutOfRange;
    switch (spec.kind) {
        .double => @field(target, spec.field) = value,
        .float => @field(target, spec.field) = @floatCast(value),
        .int => {
            // write_number: llrint, then C's conversion to int.
            const whole: i64 = @intFromFloat(roundEven(value));
            const int: i32 = @truncate(whole);
            @field(target, spec.field) = switch (@typeInfo(F)) {
                .@"enum" => @fromBackingInt(@intCast(int)),
                // The range keeps it within the field's type.
                else => @intCast(int),
            };
        },
        .bool => unreachable,
    }
}

fn roundEven(x: f64) f64 {
    const floor = @floor(x);
    const diff = x - floor;
    const up = diff > 0.5 or (diff == 0.5 and @mod(floor, 2) != 0);
    return if (up) floor + 1 else floor;
}

/// `set_string_bool`: the words, or a decimal integer (`strtol`: leading
/// white space and a sign, then the whole rest digits).
fn boolValue(text: []const u8) ?i64 {
    for ([_][]const u8{ "true", "y", "yes", "enable", "enabled", "on" }) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return 1;
    }
    for ([_][]const u8{ "false", "n", "no", "disable", "disabled", "off" }) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return 0;
    }
    if (std.mem.eql(u8, text, "auto")) return -1;
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    const digits = text[i..];
    // strtol of nothing is 0, at the start: the whole text must be read,
    // so only an empty text gives that.
    if (digits.len == 0) return if (text.len == 0) 0 else null;
    var value: i64 = 0;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = std.math.mul(i64, value, 10) catch return null;
        value = std.math.add(i64, value, c - '0') catch return null;
    }
    return if (negative) -value else value;
}

/// `set_string_number` without expressions: a constant of the option, then
/// the text without white space as a constant or `av_strtod`'s number.
fn numberValue(comptime spec: Spec, default: f64, text: []const u8) SetError!f64 {
    if (constantValue(spec, default, text)) |v| return v;
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) continue;
        if (len == buffer.len) return error.InvalidValue;
        buffer[len] = c;
        len += 1;
    }
    const stripped = buffer[0..len];
    if (constantValue(spec, default, stripped)) |v| return v;
    const n = number.avStrtod(stripped);
    if (stripped.len == 0 or n.end != stripped.len or std.math.isNan(n.value)) return error.InvalidValue;
    return n.value;
}

fn constantValue(comptime spec: Spec, default: f64, name: []const u8) ?f64 {
    for (spec.constants) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.value;
    }
    if (std.mem.eql(u8, name, "default")) return default;
    if (std.mem.eql(u8, name, "max")) return spec.max;
    if (std.mem.eql(u8, name, "min")) return spec.min;
    if (std.mem.eql(u8, name, "none")) return 0;
    if (std.mem.eql(u8, name, "all")) return -1;
    return null;
}
