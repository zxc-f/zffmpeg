// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libswresample/rematrix.c (swr_build_matrix2, build_matrix, clean_layout,
// clean_downmix, sane_layout), options.c and swresample_internal.h at the
// pinned reference revision describe the behavior and give the mix rules,
// which are restated here; see port.md "Rematrixing".
//! Channel rematrixing (TODO.md T23c), part 1: the matrix libswresample builds
//! to mix one channel layout into another (`swr_build_matrix2`), equal to it
//! on zig/testing/vectors/rematrix.txt, coefficients bit for bit.
//!
//! Channels both layouts have pass through; each other input channel is
//! mixed into the nearest output channels by libswresample's rules (the
//! center into front left and right at the center mix level, surrounds into
//! the fronts at the surround mix level, LFE at the LFE mix level, and so
//! on), optionally as Dolby or Dolby Pro Logic II matrixed stereo. The
//! matrix is then scaled so that no output channel sums to more than
//! `maxval` (1 for integer output, which libswresample clips; `INT_MAX`, so
//! never, for float output), and multiplied by the rematrix volume. A layout
//! libswresample cannot mix (an unspecified one, a channel past bit 63 or an
//! asymmetric pair, when the channels change) is `UnsupportedLayout`.
//! Nothing allocates.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples = @import("../core/samples.zig");
const audioconvert = @import("audioconvert.zig");
const dither = @import("dither.zig");
const channel_layout = @import("../core/channel_layout.zig");
const Channel = channel_layout.Channel;
const Layout = channel_layout.Layout;

/// libswresample's `SWR_CH_MAX`: the matrix's size in each direction.
pub const max_channels = 64;

/// The matrix: `[output channel][input channel]`, in the layouts' orders.
pub const Matrix = [max_channels][max_channels]f64;

/// `AVMatrixEncoding`, as far as the matrix uses it.
pub const MatrixEncoding = enum { none, dolby, dplii };

/// libswresample's options for the matrix. The mix levels are `float`
/// options there (`clev`, `slev`, `lfe_mix_level`, `rematrix_volume`): a
/// value set here must already be one a `float` holds to give its result.
pub const Options = struct {
    /// `C_30DB`, as its `float` option stores it.
    center_mix_level: f64 = c_30db,
    surround_mix_level: f64 = c_30db,
    lfe_mix_level: f64 = 0,
    /// Multiplies the matrix; a negative value scales it to its absolute
    /// value as the largest output sum instead.
    rematrix_volume: f64 = 1,
    matrix_encoding: MatrixEncoding = .none,
};

pub const Error = error{
    /// libswresample cannot mix this layout (`swr_build_matrix2` fails).
    UnsupportedLayout,
};

/// `C_30DB` (`M_SQRT1_2`) rounded to `float`, as libswresample's options
/// store it.
pub const c_30db: f64 = c_30db_float;
const c_30db_float: f32 = std.math.sqrt1_2;

const sqrt1_2 = std.math.sqrt1_2;
const sqrt1_3 = 0.57735026918962576451;
const sqrt2_3 = 0.81649658092772603273;
const sqrt3_2 = 1.22474487139158904909;

/// The named channels the mix rules know: `NUM_NAMED_CHANNELS`.
const named = 41;

// The channel ids the rules use.
const FL = 0;
const FR = 1;
const FC = 2;
const LFE = 3;
const BL = 4;
const BR = 5;
const FLC = 6;
const FRC = 7;
const BC = 8;
const SL = 9;
const SR = 10;
const TC = 11;
const TFL = 12;
const TFC = 13;
const TFR = 14;
const TBL = 15;
const TBC = 16;
const TBR = 17;
const DL = 29;
const DR = 30;
const LFE2 = 35;
const TSL = 36;
const TSR = 37;
const BFC = 38;
const BFL = 39;
const BFR = 40;

fn bit(comptime id: u6) u64 {
    const one: u64 = 1;
    return one << id;
}

const stereo = bit(FL) | bit(FR);
const surround = stereo | bit(FC);
const downmix = bit(DL) | bit(DR);

/// `av_channel_layout_subset(layout, ~0)`: the channels below 64 present.
fn presentMask(layout: *const Layout) u64 {
    switch (layout.*) {
        .native => |mask| return mask,
        .unspecified => return 0,
        .custom => |*custom| {
            var mask: u64 = 0;
            const one: u64 = 1;
            for (custom.slice()) |c| {
                const id = c.channel.id();
                if (id >= 0 and id < 64) mask |= one << @intCast(id);
            }
            return mask;
        },
    }
}

/// `av_channel_layout_index_from_channel` for a channel below 64.
fn indexOf(layout: *const Layout, id: u6) ?u32 {
    switch (layout.*) {
        .native => |mask| {
            const one: u64 = 1;
            if (mask & (one << id) == 0) return null;
            return @popCount(mask & ((one << id) - 1));
        },
        .unspecified => return null,
        .custom => |*custom| {
            for (custom.slice(), 0..) |c, i| {
                if (c.channel.id() == id) return @intCast(i);
            }
            return null;
        },
    }
}

/// `clean_layout`: a layout with one channel in use, other than front
/// center, is mixed as mono, the channel keeping its place.
fn cleanLayout(layout: Layout) Layout {
    var used = layout.channelCount();
    var index: u32 = 0;
    if (layout == .custom and used > 1) {
        used = 0;
        for (layout.custom.slice(), 0..) |c, i| {
            if (c.channel != .unused) {
                index = @intCast(i);
                used += 1;
            }
        }
    }
    if (used != 1 or layout.channel(index) == .front_center) return layout;
    if (layout.channelCount() == 1) return .mono;
    var custom = layout.custom;
    custom.channels[index].channel = .front_center;
    return .{ .custom = custom };
}

/// `clean_downmix`: a layout of the stereo downmix pair alone is mixed as
/// stereo, unless the other layout has downmix channels too.
fn cleanDownmix(layout: *Layout, other: *const Layout) void {
    if (presentMask(layout) != downmix or presentMask(other) & downmix != 0) return;
    switch (layout.*) {
        .native => layout.* = .{ .native = stereo },
        .custom => |*custom| for (custom.channels[0..custom.count]) |*c| {
            if (c.channel == .stereo_left) c.channel = .front_left;
            if (c.channel == .stereo_right) c.channel = .front_right;
        },
        .unspecified => {},
    }
}

/// `even`: neither or both of a pair.
fn even(mask: u64) bool {
    return mask == 0 or mask & (mask - 1) != 0;
}

/// `av_channel_layout_check` and `sane_layout`.
fn sane(layout: *const Layout, mixed: bool) bool {
    if (layout.channelCount() > max_channels) return false;
    switch (layout.*) {
        .unspecified => return false,
        .native => {},
        .custom => |*custom| for (custom.slice()) |c| {
            if (c.channel == .unused) continue;
            if (c.channel.id() < 0 or c.channel.id() >= 64) return false;
        },
    }
    if (!mixed) return true;
    const mask = presentMask(layout);
    if (mask & surround == 0) return false;
    const pairs = [_]u64{
        stereo,              bit(SL) | bit(SR),   bit(BL) | bit(BR),   bit(FLC) | bit(FRC),
        bit(TFL) | bit(TFR), bit(TBL) | bit(TBR), bit(TSL) | bit(TSR), bit(BFL) | bit(BFR),
    };
    for (pairs) |pair| {
        if (!even(mask & pair)) return false;
    }
    return true;
}

/// `swr_build_matrix2`: the matrix that mixes `in` into `out`, scaled so that
/// no output channel's coefficients sum to more than `maxval`, then
/// multiplied by a positive rematrix volume. Entries outside the layouts'
/// channel counts are 0.
pub fn build(in_layout: Layout, out_layout: Layout, options: Options, maxval: f64, matrix: *Matrix) Error!void {
    const cleaned = try clean(in_layout, out_layout);
    matrix.* = @splat(@splat(0));
    buildMatrix(&cleaned.in, &cleaned.out, options, maxval, matrix);
    if (options.rematrix_volume > 0) {
        for (matrix) |*row| {
            for (row) |*value| value.* *= options.rematrix_volume;
        }
    }
}

/// `swr_build_matrix2`'s layouts after `clean_layout` and `clean_downmix`,
/// once they pass `sane_layout`.
fn clean(in_layout: Layout, out_layout: Layout) Error!struct { in: Layout, out: Layout } {
    var in = cleanLayout(in_layout);
    var out = cleanLayout(out_layout);
    cleanDownmix(&out, &in);
    cleanDownmix(&in, &out);
    // The same channels on both sides change their places at most.
    const mixed = presentMask(&in) != presentMask(&out);
    if (!sane(&in, mixed) or !sane(&out, mixed)) return error.UnsupportedLayout;
    return .{ .in = in, .out = out };
}

/// Whether libswresample rematrixes from `in` to `out` at the default
/// volume, checked as `swr_init` does: false for the same layout, true when
/// it can mix them, `UnsupportedLayout` when it cannot. Unspecified layouts
/// take the default for their counts.
pub fn needed(in: Layout, out: Layout) Error!bool {
    const in_layout = withDefault(in);
    const out_layout = withDefault(out);
    if (in_layout.eql(&out_layout)) return false;
    _ = try clean(in_layout, out_layout);
    return true;
}

/// `build_matrix`, which `swr_build_matrix2` calls after its checks.
fn buildMatrix(in: *const Layout, out: *const Layout, options: Options, maxval: f64, matrix: *Matrix) void {
    const clev = options.center_mix_level;
    const slev = options.surround_mix_level;
    const lfe = options.lfe_mix_level;
    const encoding = options.matrix_encoding;
    const in_mask = presentMask(in);
    const out_mask = presentMask(out);
    const unaccounted = in_mask & ~out_mask;
    // `[output][input]` by channel id, for the named channels.
    var m: [named][named]f64 = @splat(@splat(0));
    const one: u64 = 1;
    for (0..named) |i| {
        if (in_mask & out_mask & (one << @intCast(i)) != 0) m[i][i] = 1;
    }

    if (unaccounted & bit(FC) != 0) {
        // The checks leave an output with front left and right here.
        std.debug.assert(out_mask & stereo == stereo);
        const level = if (in_mask & stereo != 0) clev else sqrt1_2;
        m[FL][FC] += level;
        m[FR][FC] += level;
    }
    if (unaccounted & stereo != 0) {
        std.debug.assert(out_mask & bit(FC) != 0);
        m[FC][FL] += sqrt1_2;
        m[FC][FR] += sqrt1_2;
        if (in_mask & bit(FC) != 0) m[FC][FC] = clev * std.math.sqrt2;
    }

    if (unaccounted & bit(BC) != 0) {
        if (out_mask & bit(BL) != 0) {
            m[BL][BC] += sqrt1_2;
            m[BR][BC] += sqrt1_2;
        } else if (out_mask & bit(SL) != 0) {
            m[SL][BC] += sqrt1_2;
            m[SR][BC] += sqrt1_2;
        } else if (out_mask & bit(FL) != 0) {
            if (encoding == .dolby or encoding == .dplii) {
                const level = if (unaccounted & (bit(BL) | bit(SL)) != 0) slev * sqrt1_2 else slev;
                m[FL][BC] -= level;
                m[FR][BC] += level;
            } else {
                m[FL][BC] += slev * sqrt1_2;
                m[FR][BC] += slev * sqrt1_2;
            }
        } else if (out_mask & bit(FC) != 0) {
            m[FC][BC] += slev * sqrt1_2;
        } else unreachable; // the checks leave a front channel
    }
    if (unaccounted & bit(BL) != 0) {
        if (out_mask & bit(BC) != 0) {
            m[BC][BL] += sqrt1_2;
            m[BC][BR] += sqrt1_2;
        } else if (out_mask & bit(SL) != 0) {
            const level: f64 = if (in_mask & bit(SL) != 0) sqrt1_2 else 1;
            m[SL][BL] += level;
            m[SR][BR] += level;
        } else if (out_mask & bit(FL) != 0) {
            surroundIntoFronts(&m, BL, BR, slev, encoding);
        } else if (out_mask & bit(FC) != 0) {
            m[FC][BL] += slev * sqrt1_2;
            m[FC][BR] += slev * sqrt1_2;
        } else unreachable;
    }

    if (unaccounted & bit(SL) != 0) {
        if (out_mask & bit(BL) != 0) {
            // Copied to the backs if the input has none, else mixed in.
            const level: f64 = if (in_mask & bit(BL) != 0) sqrt1_2 else 1;
            m[BL][SL] += level;
            m[BR][SR] += level;
        } else if (out_mask & bit(BC) != 0) {
            m[BC][SL] += sqrt1_2;
            m[BC][SR] += sqrt1_2;
        } else if (out_mask & bit(FL) != 0) {
            surroundIntoFronts(&m, SL, SR, slev, encoding);
        } else if (out_mask & bit(FC) != 0) {
            m[FC][SL] += slev * sqrt1_2;
            m[FC][SR] += slev * sqrt1_2;
        } else unreachable;
    }

    if (unaccounted & bit(FLC) != 0) {
        if (out_mask & bit(FL) != 0) {
            m[FL][FLC] += 1;
            m[FR][FRC] += 1;
        } else if (out_mask & bit(FC) != 0) {
            m[FC][FLC] += sqrt1_2;
            m[FC][FRC] += sqrt1_2;
        } else unreachable;
    }

    if (unaccounted & bit(TFL) != 0) {
        if (out_mask & bit(TFC) != 0) {
            m[TFC][TFL] += sqrt1_2;
            m[TFC][TFR] += sqrt1_2;
            if (in_mask & bit(TFC) != 0) m[TFC][TFC] = clev * std.math.sqrt2;
        } else if (out_mask & bit(FL) != 0) {
            // U+030 -> M+030 in ITU-R BS.2127-1, Table 16.
            m[FL][TFL] += 1;
            m[FR][TFR] += 1;
        } else if (out_mask & bit(FC) != 0) {
            m[FC][TFL] += sqrt1_2;
            m[FC][TFR] += sqrt1_2;
        } else unreachable;
    }

    if (unaccounted & bit(TFC) != 0) {
        if (out_mask & bit(TFL) != 0) {
            m[TFL][TFC] += sqrt1_2;
            m[TFR][TFC] += sqrt1_2;
        } else if (out_mask & bit(FC) != 0) {
            m[FC][TFC] += 1;
        } else if (out_mask & bit(FL) != 0) {
            m[FL][TFC] += clev;
            m[FR][TFC] += clev;
        } else unreachable;
    }

    if (unaccounted & bit(TBL) != 0) {
        if (out_mask & bit(TBC) != 0) {
            m[TBC][TBL] += sqrt1_2;
            m[TBC][TBR] += sqrt1_2;
        } else if (out_mask & bit(TFL) != 0) {
            // IAMF v1.1.0, Section 7.3.2.1.1.
            m[TFL][TBL] += sqrt1_2;
            m[TFR][TBR] += sqrt1_2;
        } else if (out_mask & bit(BL) != 0) {
            m[BL][TBL] += 1;
            m[BR][TBR] += 1;
        } else if (out_mask & bit(SL) != 0) {
            m[SL][TBL] += 1;
            m[SR][TBR] += 1;
        } else if (out_mask & bit(FL) != 0) {
            m[FL][TBL] += slev;
            m[FR][TBR] += slev;
        } else if (out_mask & bit(FC) != 0) {
            m[FC][TBL] += slev * sqrt1_2;
            m[FC][TBR] += slev * sqrt1_2;
        } else unreachable;
    }

    // BS.2127-1 maps U+180 to rear outputs before front outputs.
    if (unaccounted & bit(TBC) != 0) {
        if (out_mask & bit(TBL) != 0) {
            m[TBL][TBC] += sqrt1_2;
            m[TBR][TBC] += sqrt1_2;
        } else if (out_mask & bit(BL) != 0) {
            m[BL][TBC] += sqrt1_2;
            m[BR][TBC] += sqrt1_2;
        } else if (out_mask & bit(SL) != 0) {
            m[SL][TBC] += sqrt1_2;
            m[SR][TBC] += sqrt1_2;
        } else if (out_mask & bit(FL) != 0) {
            m[FL][TBC] += 0.5;
            m[FR][TBC] += 0.5;
        } else if (out_mask & bit(FC) != 0) {
            m[FC][TBC] += 0.5;
        } else unreachable;
    }

    if (unaccounted & bit(TSL) != 0) {
        if (out_mask & (bit(TFL) | bit(TBC)) == bit(TFL) | bit(TBC)) {
            // UH+180 = sqrt(1/3); U±045 = sqrt(2/3)
            m[TFL][TSL] += sqrt2_3;
            m[TFR][TSR] += sqrt2_3;
            m[TBC][TSL] += sqrt1_3;
            m[TBC][TSR] += sqrt1_3;
        } else if (out_mask & (bit(TFL) | bit(TBL)) == bit(TFL) | bit(TBL)) {
            // U±030 = U±110 = sqrt(1/2)
            m[TFL][TSL] += sqrt1_2;
            m[TFR][TSR] += sqrt1_2;
            m[TBL][TSL] += sqrt1_2;
            m[TBR][TSR] += sqrt1_2;
        } else if (out_mask & bit(TFL) != 0 and out_mask & (bit(BL) | bit(SL)) != 0) {
            // U±030 = M±110 = sqrt(1/2)
            m[TFL][TSL] += sqrt1_2;
            m[TFR][TSR] += sqrt1_2;
            if (out_mask & bit(BL) != 0) {
                m[BL][TSL] += sqrt1_2;
                m[BR][TSR] += sqrt1_2;
            } else {
                m[SL][TSL] += sqrt1_2;
                m[SR][TSR] += sqrt1_2;
            }
        } else if (out_mask & bit(SL) != 0) {
            // M±090 = 1
            m[SL][TSL] += 1;
            m[SR][TSR] += 1;
        } else if (out_mask & bit(FL) != 0) {
            // M±030 = M±110 = sqrt(1/2)
            m[FL][TSL] += slev;
            m[FR][TSR] += slev;
            if (out_mask & bit(BL) != 0) {
                m[BL][TSL] += sqrt1_2;
                m[BR][TSR] += sqrt1_2;
            }
        } else if (out_mask & bit(FC) != 0) {
            m[FC][TSL] += slev * sqrt1_2;
            m[FC][TSR] += slev * sqrt1_2;
        } else unreachable;
    }

    if (unaccounted & bit(TC) != 0) {
        if (out_mask & (bit(TFL) | bit(TBL)) == bit(TFL) | bit(TBL)) {
            // U+045 = U-045 = U+135 = U-135 = sqrt(1/4)
            m[TFL][TC] += 0.5;
            m[TFR][TC] += 0.5;
            m[TBL][TC] += 0.5;
            m[TBR][TC] += 0.5;
        } else if (out_mask & (bit(TFL) | bit(TBC)) == bit(TFL) | bit(TBC)) {
            // U+045 = U-045 = UH+180 = sqrt(1/3)
            m[TFL][TC] += sqrt1_3;
            m[TFR][TC] += sqrt1_3;
            m[TBC][TC] += sqrt1_3;
        } else if (out_mask & bit(TFL) != 0 and out_mask & (bit(BL) | bit(SL)) != 0) {
            m[TFL][TC] += 0.5;
            m[TFR][TC] += 0.5;
            if (out_mask & bit(BL) != 0) {
                m[BL][TC] += 0.5;
                m[BR][TC] += 0.5;
            } else {
                m[SL][TC] += 0.5;
                m[SR][TC] += 0.5;
            }
        } else if (out_mask & bit(FL) != 0) {
            m[FL][TC] += 0.5;
            m[FR][TC] += 0.5;
            if (out_mask & bit(BL) != 0) {
                m[BL][TC] += 0.5;
                m[BR][TC] += 0.5;
            } else if (out_mask & bit(SL) != 0) {
                m[SL][TC] += 0.5;
                m[SR][TC] += 0.5;
            }
        } else if (out_mask & bit(FC) != 0) {
            m[FC][TC] += 0.5;
        } else unreachable;
    }

    if (unaccounted & bit(BFC) != 0) {
        if (out_mask & bit(FC) != 0) {
            m[FC][BFC] += 1;
        } else if (out_mask & bit(FL) != 0) {
            m[FL][BFC] += clev;
            m[FR][BFC] += clev;
        } else unreachable;
    }

    if (unaccounted & bit(BFL) != 0) {
        if (out_mask & bit(BFC) != 0) {
            m[BFC][BFL] += sqrt1_2;
            m[BFC][BFR] += sqrt1_2;
            if (in_mask & bit(BFC) != 0) m[BFC][BFC] = clev * std.math.sqrt2;
        } else if (out_mask & bit(FL) != 0) {
            // M±030 = 1
            m[FL][BFL] += 1;
            m[FR][BFR] += 1;
        } else if (out_mask & bit(FC) != 0) {
            m[FC][BFL] += sqrt1_2;
            m[FC][BFR] += sqrt1_2;
        } else unreachable;
    }

    // LFE into front left and right, or center.
    if (unaccounted & bit(LFE) != 0) {
        if (out_mask & bit(FC) != 0) {
            m[FC][LFE] += lfe;
        } else if (out_mask & bit(FL) != 0) {
            m[FL][LFE] += lfe * sqrt1_2;
            m[FR][LFE] += lfe * sqrt1_2;
        } else unreachable;
    }

    // LFE2 into LFE, front left and right, or center.
    if (unaccounted & bit(LFE2) != 0) {
        if (out_mask & bit(LFE) != 0) {
            m[LFE][LFE2] += sqrt1_2;
        } else if (out_mask & bit(FC) != 0) {
            m[FC][LFE2] += lfe;
        } else if (out_mask & bit(FL) != 0) {
            m[FL][LFE2] += lfe * sqrt1_2;
            m[FR][LFE2] += lfe * sqrt1_2;
        } else unreachable;
    }

    // Into the layouts' orders; each output's coefficients sum to maxcoef
    // at most.
    var maxcoef: f64 = 0;
    for (0..64) |i| {
        const out_index = indexOf(out, @intCast(i)) orelse continue;
        var sum: f64 = 0;
        for (0..64) |j| {
            const in_index = indexOf(in, @intCast(j)) orelse continue;
            const value: f64 = if (i < named and j < named)
                m[i][j]
            else if (i == j and in_mask & out_mask & (one << @intCast(i)) != 0) 1 else 0;
            matrix[out_index][in_index] = value;
            sum += @abs(value);
        }
        maxcoef = @max(maxcoef, sum);
    }
    if (options.rematrix_volume < 0) maxcoef = -options.rematrix_volume;
    if (maxcoef > maxval or options.rematrix_volume < 0) {
        maxcoef /= maxval;
        for (matrix) |*row| {
            for (row) |*value| value.* /= maxcoef;
        }
    }
}

/// A pair of surround channels into front left and right: added, or
/// matrixed into Dolby or Dolby Pro Logic II stereo.
fn surroundIntoFronts(m: *[named][named]f64, comptime left: u6, comptime right: u6, slev: f64, encoding: MatrixEncoding) void {
    switch (encoding) {
        .dolby => {
            m[FL][left] -= slev * sqrt1_2;
            m[FL][right] -= slev * sqrt1_2;
            m[FR][left] += slev * sqrt1_2;
            m[FR][right] += slev * sqrt1_2;
        },
        .dplii => {
            m[FL][left] -= slev * sqrt3_2;
            m[FL][right] -= slev * sqrt1_2;
            m[FR][left] += slev * sqrt1_2;
            m[FR][right] += slev * sqrt3_2;
        },
        .none => {
            m[FL][left] += slev;
            m[FR][right] += slev;
        },
    }
}

/// A rematrix as libswresample sets one up for a conversion at one rate
/// (`swr_init`, `swri_rematrix_init`) and applies it (`swri_rematrix`): the
/// matrix, the internal format it mixes in, and the coefficients in that
/// format. Large (about 50 KiB): keep it where it lives, not on a hot stack.
pub const Remix = struct {
    in_channels: u32,
    out_channels: u32,
    /// libswresample's internal format: s16p, s32p, fltp or dblp.
    internal: audio.SampleFormat,
    /// The matrix mixes channels, rather than only copying or silencing
    /// them (`swri_rematrix_build`), which changes the internal format.
    mixing: bool,
    matrix: Matrix,
    /// `native_matrix` of s16p and s32p: each row's coefficients times
    /// 32768, rounded through `lrintf` with the rounding error carried on.
    ints: [max_channels][max_channels]i32,
    /// s16p's kernels clip: some row's integer coefficients sum past 32768.
    clip: bool,
    /// `matrix_ch`: each output channel's inputs with a nonzero coefficient.
    sources: [max_channels]Sources,
    special: Special,

    const Sources = struct {
        count: u8 = 0,
        index: [max_channels]u8 = undefined,
    };

    /// `get_mix_any_func`: 5.1 or 5.1(side) to stereo, or 7.1 to stereo,
    /// with a symmetric center and LFE, mixed by one kernel.
    const Special = enum { none, six_to_two, eight_to_two };

    /// Sets up the mix from `in` to `out_layout` in `out_format` and
    /// returns true, or returns false when libswresample would not
    /// rematrix: the same layout, and a volume of 1. An unspecified layout
    /// takes the default for its channel count, as `swr_init` gives it.
    pub fn init(r: *Remix, in: audio.Format, out_layout: Layout, out_format: audio.SampleFormat, options: Options) Error!bool {
        return r.initFor(in, out_layout, out_format, options, false);
    }

    /// `init` for a conversion that also changes the rate (T24), which
    /// changes libswresample's internal format.
    pub fn initFor(r: *Remix, in: audio.Format, out_layout: Layout, out_format: audio.SampleFormat, options: Options, resampling: bool) Error!bool {
        const in_layout = withDefault(in.layout);
        const out = withDefault(out_layout);
        if (in_layout.eql(&out) and options.rematrix_volume == 1) return false;
        // auto_matrix: integer output is clipped, so mixes keep within 1.
        const maxval: f64 = switch (out_format.packedForm()) {
            .u8, .s16, .s32 => 1,
            else => std.math.maxInt(i32),
        };
        try build(in_layout, out, options, maxval, &r.matrix);
        r.in_channels = in_layout.channelCount();
        r.out_channels = out.channelCount();
        r.mixing = false;
        for (0..r.out_channels) |i| {
            var count: u32 = 0;
            for (r.matrix[i][0..r.in_channels]) |coefficient| {
                if (coefficient == 0) continue;
                if (coefficient != 1 or count > 0) r.mixing = true;
                count += 1;
            }
        }
        r.internal = dither.internalFormatResampling(in.sample_format, out_format, r.mixing, resampling);
        r.clip = false;
        if (r.internal == .s16p or r.internal == .s32p) {
            var max_sum: i64 = 0;
            for (0..r.out_channels) |i| {
                var rem: f64 = 0;
                var sum: i64 = 0;
                for (0..r.in_channels) |j| {
                    const target = r.matrix[i][j] * 32768 + rem;
                    const native = lrintf(target);
                    r.ints[i][j] = native;
                    const native_wide: f64 = @floatFromInt(native);
                    rem += target - native_wide;
                    sum += @abs(native);
                }
                max_sum = @max(max_sum, sum);
            }
            r.clip = r.internal == .s16p and max_sum > 32768;
        }
        for (0..max_channels) |i| {
            var sources: Sources = .{};
            for (0..max_channels) |j| {
                if (r.matrix[i][j] == 0) continue;
                sources.index[sources.count] = @intCast(j);
                sources.count += 1;
            }
            r.sources[i] = sources;
        }
        r.special = special(&in_layout, &out, &r.matrix);
        return true;
    }

    /// Bytes of scratch `convert` needs for `count` frames.
    pub fn scratchLen(r: *const Remix, count: u32) usize {
        const frames: usize = count;
        return frames * (r.in_channels + r.out_channels) * r.internal.bytesPerSample();
    }

    /// Mixes `count` frames of `in` into `out`, both planar in the internal
    /// format (`swri_rematrix`).
    pub fn apply(r: *const Remix, out: samples.Buffer, in: samples.View, count: u32) void {
        std.debug.assert(out.layout.format == r.internal and in.layout.format == r.internal);
        std.debug.assert(out.layout.channels == r.out_channels and in.layout.channels == r.in_channels);
        switch (r.internal) {
            inline .s16p, .s32p, .fltp, .dblp => |format| r.applyIn(format, out, in, count),
            else => unreachable, // init picks one of these
        }
    }

    fn applyIn(r: *const Remix, comptime format: audio.SampleFormat, out: samples.Buffer, in: samples.View, count: u32) void {
        const K = Kernel(format);
        switch (r.special) {
            .six_to_two => return K.mixToTwo(r, 6, out, in, count),
            .eight_to_two => return K.mixToTwo(r, 8, out, in, count),
            .none => {},
        }
        for (0..r.out_channels) |o| {
            const plane = out.plane(@intCast(o));
            const sources = &r.sources[o];
            switch (sources.count) {
                0 => @memset(plane[0 .. count * @sizeOf(K.Sample)], 0),
                1 => {
                    const i = sources.index[0];
                    if (r.matrix[o][i] == 1) {
                        const bytes = count * @sizeOf(K.Sample);
                        @memcpy(plane[0..bytes], in.plane(i)[0..bytes]);
                    } else {
                        const coefficient = K.coefficient(r, o, i);
                        for (0..count) |n| K.store(plane, n, K.round(r, K.mul(coefficient, K.load(in.plane(i), n))));
                    }
                },
                2 => {
                    const a = sources.index[0];
                    const b = sources.index[1];
                    const ca = K.coefficient(r, o, a);
                    const cb = K.coefficient(r, o, b);
                    for (0..count) |n| {
                        K.store(plane, n, K.round(r, K.add(K.mul(ca, K.load(in.plane(a), n)), K.mul(cb, K.load(in.plane(b), n)))));
                    }
                },
                else => K.mixMany(r, o, plane, in, count),
            }
        }
    }

    /// The kernels of one internal format, as rematrix_template.c and
    /// `swri_rematrix` write them: `Inter` is the arithmetic type.
    fn Kernel(comptime format: audio.SampleFormat) type {
        return struct {
            const Sample = switch (format) {
                .s16p => i16,
                .s32p => i32,
                .fltp => f32,
                .dblp => f64,
                else => unreachable,
            };
            const Inter = switch (format) {
                .s16p => i32,
                .s32p => i64,
                .fltp => f32,
                .dblp => f64,
                else => unreachable,
            };
            const Bits = @Int(.unsigned, @bitSizeOf(Sample));
            const integer = format == .s16p or format == .s32p;

            /// C's `int` and `int64_t` arithmetic, which wraps on x86-64
            /// where an extreme volume overflows it; floats as they are.
            fn mul(a: Inter, b: Inter) Inter {
                return if (integer) a *% b else a * b;
            }

            fn add(a: Inter, b: Inter) Inter {
                return if (integer) a +% b else a + b;
            }

            fn load(plane: []const u8, n: usize) Inter {
                const bits = std.mem.readInt(Bits, plane[n * @sizeOf(Sample) ..][0..@sizeOf(Sample)], native_endian);
                const sample: Sample = @bitCast(bits);
                return sample;
            }

            fn store(plane: []u8, n: usize, value: Sample) void {
                std.mem.writeInt(Bits, plane[n * @sizeOf(Sample) ..][0..@sizeOf(Sample)], @bitCast(value), native_endian);
            }

            /// `native_matrix[out][in]`.
            fn coefficient(r: *const Remix, o: usize, i: usize) Inter {
                return switch (format) {
                    .s16p, .s32p => r.ints[o][i],
                    .fltp => @floatCast(r.matrix[o][i]),
                    .dblp => r.matrix[o][i],
                    else => unreachable,
                };
            }

            /// `R(x)`: integers round by 2^15, wrapping into the sample
            /// unless s16p clips; floats are as they are.
            fn round(r: *const Remix, x: Inter) Sample {
                switch (format) {
                    .s16p => {
                        const scaled = (x +% 16384) >> 15;
                        if (r.clip) return @intCast(std.math.clamp(scaled, std.math.minInt(i16), std.math.maxInt(i16)));
                        return @truncate(scaled);
                    },
                    .s32p => return @truncate((x +% 16384) >> 15),
                    .fltp, .dblp => return x,
                    else => unreachable,
                }
            }

            /// `mix6to2` and `mix8to2`: the center and LFE once, shared.
            fn mixToTwo(r: *const Remix, comptime n_in: usize, out: samples.Buffer, in: samples.View, count: u32) void {
                const left = out.plane(0);
                const right = out.plane(1);
                const c = struct {
                    fn of(rr: *const Remix, o: usize, i: usize) Inter {
                        return coefficient(rr, o, i);
                    }
                };
                for (0..count) |n| {
                    var v: [n_in]Inter = undefined;
                    inline for (0..n_in) |i| v[i] = load(in.plane(i), n);
                    // C's order: t, then each product added left to right.
                    const t = add(mul(v[2], c.of(r, 0, 2)), mul(v[3], c.of(r, 0, 3)));
                    var l = add(add(t, mul(v[0], c.of(r, 0, 0))), mul(v[4], c.of(r, 0, 4)));
                    var rr = add(add(t, mul(v[1], c.of(r, 1, 1))), mul(v[5], c.of(r, 1, 5)));
                    if (n_in == 8) {
                        l = add(l, mul(v[6], c.of(r, 0, 6)));
                        rr = add(rr, mul(v[7], c.of(r, 1, 7)));
                    }
                    store(left, n, round(r, l));
                    store(right, n, round(r, rr));
                }
            }

            /// More than two inputs: floats in `float` or `double` with the
            /// plain coefficients; integers as s16 with `lrintf(c * 32768)`
            /// coefficients, unclipped (s32p never mixes this way).
            fn mixMany(r: *const Remix, o: usize, plane: []u8, in: samples.View, count: u32) void {
                const sources = &r.sources[o];
                for (0..count) |n| {
                    switch (format) {
                        .fltp, .dblp => {
                            var v: Inter = 0;
                            for (sources.index[0..sources.count]) |i| {
                                const c: Inter = @floatCast(r.matrix[o][i]);
                                v += load(in.plane(i), n) * c;
                            }
                            store(plane, n, v);
                        },
                        .s16p => {
                            var v: i32 = 0;
                            for (sources.index[0..sources.count]) |i| {
                                v +%= @as(i32, @intCast(load(in.plane(i), n))) *% lrintf(r.matrix[o][i] * 32768);
                            }
                            store(plane, n, @truncate((v +% 16384) >> 15));
                        },
                        else => unreachable,
                    }
                }
            }
        };
    }
};

/// An unspecified layout as `swr_init` takes it: the default for its count.
fn withDefault(layout: Layout) Layout {
    return switch (layout) {
        .unspecified => |count| .default(count),
        .native, .custom => layout,
    };
}

/// `get_mix_any_func`'s condition.
fn special(in: *const Layout, out: *const Layout, m: *const Matrix) Remix.Special {
    if (!out.eql(&Layout.stereo)) return .none;
    const symmetric = m[0][2] == m[1][2] and m[0][3] == m[1][3] and
        m[0][1] == 0 and m[0][5] == 0 and m[1][0] == 0 and m[1][4] == 0;
    if (!symmetric) return .none;
    const five_one: Layout = .{ .native = bit(FL) | bit(FR) | bit(FC) | bit(LFE) | bit(SL) | bit(SR) };
    const five_one_back: Layout = .{ .native = bit(FL) | bit(FR) | bit(FC) | bit(LFE) | bit(BL) | bit(BR) };
    if (in.eql(&five_one) or in.eql(&five_one_back)) return .six_to_two;
    const seven_one: Layout = .{ .native = five_one.native | bit(BL) | bit(BR) };
    if (in.eql(&seven_one) and m[0][7] == 0 and m[1][6] == 0) return .eight_to_two;
    return .none;
}

/// `lrintf` of a double, as C converts it: to `float`, then to the nearest
/// integer, ties to even. The coefficients keep it far inside `int`.
fn lrintf(x: f64) i32 {
    const f: f32 = @floatCast(x);
    const floor = @floor(f);
    const diff = f - floor;
    const up = diff > 0.5 or (diff == 0.5 and @mod(floor, 2) != 0);
    const rounded = if (up) floor + 1 else floor;
    return @trunc(rounded);
}

const native_endian = @import("builtin").cpu.arch.endian();

/// Converts `count` frames from `in` to `out` as `swr_convert` does with a
/// layout change and no resampling: `in` into the internal format, the mix,
/// `dither` if given (made by `Dither.initInternal` for the output's
/// channels in `r.internal`), then into `out`. `scratch` holds
/// `r.scratchLen(count)` bytes.
pub fn convert(r: *const Remix, out: samples.Buffer, in: samples.View, count: u32, scratch: []u8, dithering: ?*dither.Dither) void {
    if (count == 0) return;
    const in_layout = samples.Layout.init(r.internal, r.in_channels, count, .{ .line = 1 }) catch unreachable;
    const out_layout = samples.Layout.init(r.internal, r.out_channels, count, .{ .line = 1 }) catch unreachable;
    const mid_in = samples.Buffer.init(in_layout, scratch[0..in_layout.size]) catch unreachable;
    const mid_out = samples.Buffer.init(out_layout, scratch[in_layout.size..]) catch unreachable;
    audioconvert.convert(mid_in, in, 0, 0, count);
    r.apply(mid_out, mid_in.view(), count);
    if (dithering) |d| d.applyInternal(mid_out, count);
    audioconvert.convert(out, mid_out.view(), 0, 0, count);
}

const vectors = @embedFile("../testing/vectors/rematrix.txt");
const vector_count = 4833;

fn field(fields: *std.mem.TokenIterator(u8, .scalar)) error{MalformedVector}![]const u8 {
    return fields.next() orelse error.MalformedVector;
}

fn layoutField(fields: *std.mem.TokenIterator(u8, .scalar)) !Layout {
    const text = try field(fields);
    var buffer: [128]u8 = undefined;
    if (text.len % 2 != 0 or text.len / 2 > buffer.len) return error.MalformedVector;
    const bytes = try std.fmt.hexToBytes(buffer[0 .. text.len / 2], text);
    return Layout.parse(bytes);
}

fn floatField(fields: *std.mem.TokenIterator(u8, .scalar)) !f64 {
    return std.fmt.parseFloat(f64, try field(fields));
}

fn checkVector(line: []const u8, matrix: *Matrix, expected: *Matrix) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, try field(&fields), "M")) return error.MalformedVector;
    const in = try layoutField(&fields);
    const out = try layoutField(&fields);
    var options: Options = .{};
    options.center_mix_level = try floatField(&fields);
    options.surround_mix_level = try floatField(&fields);
    options.lfe_mix_level = try floatField(&fields);
    const maxval = try floatField(&fields);
    options.rematrix_volume = try floatField(&fields);
    options.matrix_encoding = switch (try std.fmt.parseInt(u8, try field(&fields), 10)) {
        0 => .none,
        1 => .dolby,
        2 => .dplii,
        else => return error.MalformedVector,
    };
    const entries = try field(&fields);
    const result = build(in, out, options, maxval, matrix);
    if (std.mem.eql(u8, entries, "E")) return std.testing.expectError(error.UnsupportedLayout, result);
    try result;
    expected.* = @splat(@splat(0));
    if (!std.mem.eql(u8, entries, "-")) {
        var items = std.mem.tokenizeScalar(u8, entries, ';');
        while (items.next()) |item| {
            const comma = std.mem.findScalar(u8, item, ',') orelse return error.MalformedVector;
            const equals = std.mem.findScalar(u8, item, '=') orelse return error.MalformedVector;
            const o = try std.fmt.parseInt(usize, item[0..comma], 10);
            const i = try std.fmt.parseInt(usize, item[comma + 1 .. equals], 10);
            expected[o][i] = try std.fmt.parseFloat(f64, item[equals + 1 ..]);
        }
    }
    for (expected, matrix) |want_row, got_row| {
        for (want_row, got_row) |want, got| {
            // Bit for bit, so that -0 and +0 differ as in FFmpeg's.
            const want_bits: u64 = @bitCast(want);
            const got_bits: u64 = @bitCast(got);
            if (want == 0 and got == 0) continue;
            try std.testing.expectEqual(want_bits, got_bits);
        }
    }
}

test "matrices equal libswresample's on every vector" {
    var matrix: Matrix = undefined;
    var expected: Matrix = undefined;
    var lines = std.mem.tokenizeScalar(u8, vectors, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        checkVector(line, &matrix, &expected) catch |err| {
            std.debug.print("vector {d}: {s}\n", .{ count + 1, line[0..@min(line.len, 120)] });
            return err;
        };
    }
    try std.testing.expectEqual(vector_count, count);
}

test "downmixing 5.1 to stereo uses the default levels" {
    var matrix: Matrix = undefined;
    try build(.default(6), .stereo, .{}, 1, &matrix);
    // FL takes FL, FC and BL at 1, C_30DB and C_30DB, scaled to sum to 1.
    const sum = 1 + 2 * c_30db;
    try std.testing.expectEqual(1 / sum, matrix[0][0]);
    try std.testing.expectEqual(c_30db / sum, matrix[0][2]);
    try std.testing.expectEqual(0, matrix[0][3]);
    try std.testing.expectError(error.UnsupportedLayout, build(.{ .unspecified = 3 }, .stereo, .{}, 1, &matrix));
}

const remix_vectors = @embedFile("../testing/vectors/remix.txt");
const remix_vector_count = 1792;

/// The generator's input: a 64-bit LCG, one step per sample (remix_vectors.c).
const Lcg = struct {
    state: u64 = 1,

    fn next(g: *Lcg) u64 {
        g.state = g.state *% 6364136223846793005 +% 1442695040888963407;
        return g.state;
    }
};

fn writeSample(bytes: []u8, format: audio.SampleFormat, v: u64) void {
    const top: i32 = @bitCast(@as(u32, @truncate(v >> 32)));
    switch (format.packedForm()) {
        .u8 => bytes[0] = @truncate(v >> 56),
        .s16 => std.mem.writeInt(i16, bytes[0..2], @bitCast(@as(u16, @truncate(v >> 48))), native_endian),
        .s32 => std.mem.writeInt(i32, bytes[0..4], top, native_endian),
        .s64 => std.mem.writeInt(i64, bytes[0..8], @bitCast(v), native_endian),
        .flt => {
            const wide: f64 = @as(f64, @floatFromInt(top)) * 1.25 / 2147483648.0;
            const narrow: f32 = @floatCast(wide);
            std.mem.writeInt(u32, bytes[0..4], @bitCast(narrow), native_endian);
        },
        .dbl => {
            const wide: f64 = @as(f64, @floatFromInt(top)) * 1.25 / 2147483648.0;
            std.mem.writeInt(u64, bytes[0..8], @bitCast(wide), native_endian);
        },
        else => unreachable,
    }
}

fn checkRemixVector(line: []const u8, gpa: std.mem.Allocator) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, try field(&fields), "X")) return error.MalformedVector;
    const in_layout = try layoutField(&fields);
    const out_layout = try layoutField(&fields);
    const in_format = audio.SampleFormat.fromName(try field(&fields)) orelse return error.MalformedVector;
    const out_format = audio.SampleFormat.fromName(try field(&fields)) orelse return error.MalformedVector;
    const frames = try std.fmt.parseInt(u32, try field(&fields), 10);
    const method: ?dither.Method = switch (try std.fmt.parseInt(u8, try field(&fields), 10)) {
        0 => null,
        2 => .triangular,
        3 => .triangular_hp,
        69 => .shibata,
        else => return error.MalformedVector,
    };
    const want = try std.fmt.parseInt(u64, try field(&fields), 16);

    const in: audio.Format = try .initLayout(8000, in_layout, in_format);
    const remix = try gpa.create(Remix);
    defer gpa.destroy(remix);
    try std.testing.expect(try remix.init(in, out_layout, out_format, .{}));
    const in_buffer_layout = try samples.Layout.init(in_format, in_layout.channelCount(), frames, .{ .line = 1 });
    const out_buffer_layout = try samples.Layout.init(out_format, remix.out_channels, frames, .{ .line = 1 });
    const in_bytes = try gpa.alloc(u8, in_buffer_layout.size);
    defer gpa.free(in_bytes);
    const out_bytes = try gpa.alloc(u8, out_buffer_layout.size);
    defer gpa.free(out_bytes);
    const scratch = try gpa.alloc(u8, remix.scratchLen(frames));
    defer gpa.free(scratch);
    const in_buffer = try samples.Buffer.init(in_buffer_layout, in_bytes);
    var lcg: Lcg = .{};
    const width = in_format.bytesPerSample();
    for (0..frames) |f| {
        for (0..in_layout.channelCount()) |c| {
            const bytes = if (in_format.isPlanar())
                in_buffer.plane(@intCast(c))[f * width ..]
            else
                in_buffer.plane(0)[(f * in_layout.channelCount() + c) * width ..];
            writeSample(bytes, in_format, lcg.next());
        }
    }
    var dithered: ?dither.Dither = if (method) |m|
        dither.Dither.initInternal(remix.internal, remix.out_channels, 8000, out_format, .{ .method = m })
    else
        null;
    const out_buffer = try samples.Buffer.init(out_buffer_layout, out_bytes);
    convert(remix, out_buffer, in_buffer.view(), frames, scratch, if (dithered) |*d| d else null);

    // FNV-1a over the output's bytes, planes in order, little-endian.
    pcm_little.storedToLittle(out_format, out_bytes);
    var hash: u64 = 0xcbf29ce484222325;
    const planes = out_buffer_layout.planeCount();
    const plane_bytes = if (out_format.isPlanar()) frames * out_format.bytesPerSample() else frames * remix.out_channels * out_format.bytesPerSample();
    for (0..planes) |p| {
        for (out_buffer.plane(@intCast(p))[0..plane_bytes]) |b| {
            hash ^= b;
            hash *%= 0x100000001b3;
        }
    }
    try std.testing.expectEqual(want, hash);
}

const pcm_little = @import("../codec/pcm.zig");

test "remixed samples equal libswresample's on every vector" {
    const gpa = std.testing.allocator;
    var lines = std.mem.tokenizeScalar(u8, remix_vectors, '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        checkRemixVector(line, gpa) catch |err| {
            std.debug.print("remix vector {d}: {s}\n", .{ count + 1, line });
            return err;
        };
    }
    try std.testing.expectEqual(remix_vector_count, count);
}
