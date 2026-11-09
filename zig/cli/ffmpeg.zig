// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
// fftools/ffmpeg_opt.c at the pinned reference revision was read for the -y/-n
// and same-file behavior; see port.md "zffmpeg command" for the differences.
//! zffmpeg: converts or stream-copies one WAV, Wave64, AU, AIFF, CAF
//! (PCM and ALAC), FLAC, Ogg (FLAC, Vorbis and Opus decoded as input, FLAC written),
//! MPEG audio (every layer decoded as input, MP2 encoded as output) or raw
//! PCM stream (TODO.md T13b, T21b, T22b, T22c, T22d, T26a, T26c, T27b, T27d,
//! T28, T29b to T29d).
//!
//!     zffmpeg [-y | -n] [-f <format>] [-sample_rate <rate> | -ar <rate>]
//!             [-ch_layout <layout> | -ac <channels>] -i <input | -> [-c copy|<encoder>]
//!             [-ar <rate>] [-ac <channels> | -ch_layout <layout>]
//!             [-dither_method <method>] [-dither_scale <scale>]
//!             [encoder options] [-f <format>] <output | ->
//!
//! `-c:a flac`, the default for a `.flac` output, encodes as FFmpeg's FLAC
//! encoder and muxer do (T26c), with its options after `-i` in FFmpeg's
//! syntax; a file output gets the encoder's final STREAMINFO, standard
//! output the first, as FFmpeg's muxer does on a pipe. It is also the
//! default for `.ogg` and `.oga` outputs, which FFmpeg's Ogg muxer writes
//! (T27b).
//!
//! The input container is detected from content as FFmpeg's probing would
//! (T16), with the file name's extension as FFmpeg's fallback for raw PCM
//! (T22c), or forced with a `-f` before `-i`, as in FFmpeg, where an option
//! before `-i` applies to the input. `-sample_rate` (`-ar`) and `-ch_layout`
//! (`-ac`) there describe a raw PCM input, 44100 Hz mono by default; for any
//! other input they are a usage error. The output container is the `-f` after
//! `-i`, or else the output name's extension (`.wav`, `.w64`, `.au`, or as
//! FFmpeg's AIFF muxer `.aif`, `.aiff`, `.afc` and `.aifc`); `-`
//! (standard output) needs `-f`. `-c copy` copies the encoded samples, which
//! works only when both containers carry the same codec; without it the
//! samples are decoded and encoded again. `-dither_method` and
//! `-dither_scale` after `-i` are libswresample's options, which dither a
//! conversion to fewer bits as FFmpeg's would (T23a); `-c copy` ignores them,
//! as FFmpeg does. `-ac` or `-ch_layout` after `-i` names the output's
//! channel layout, which the samples are rematrixed into as FFmpeg's
//! libswresample mixes them (T23c); `-ac N` takes FFmpeg's default layout
//! for N channels. Tags before the input's `data` are carried into a WAV
//! output, as FFmpeg's default `-map_metadata` does (T21c).
//!
//! Every check that does not need the rest of the input happens before the
//! output file is opened: the arguments, the input header, the operation
//! matrix, the output header, then whether the output is the input file. An
//! existing output is never replaced without `-y`. A failure after the output
//! file was created removes it when this run created it; an existing path
//! replaced with `-y` (a file, a pipe, a device) keeps what was written, as
//! FFmpeg keeps it, and so does standard output. An option given again
//! replaces its value, as FFmpeg's last one wins. Exit statuses are those of
//! zffprobe (`status.zig`); the conversion
//! itself is `av.convert`, so this file only handles arguments, files and
//! output.

const std = @import("std");
const av = @import("av");
const status = @import("status.zig");
const ExitStatus = status.ExitStatus;
const printError = status.printError;

const usage = "usage: zffmpeg [-y | -n] [-f <format>] [-sample_rate <rate>] [-ch_layout <layout>] -i <input | -> [-c copy|<encoder>] [-b:a <bit rate>] [-ar <rate>] [-ac <channels> | -ch_layout <layout>] [-dither_method <method>] [-dither_scale <scale>] [encoder options] [-f <format>] <output | ->\n";
const help = usage ++
    \\
    \\Converts one WAV, Wave64, AU, AIFF, CAF (PCM, and ALAC), FLAC, Ogg
    \\(Vorbis, Opus and FLAC input, FLAC output), MPEG audio (MP3, MP2 and MP1
    \\input, MP2 output), ADTS AAC (input and output), raw AC-3 or E-AC-3 (input, and
    \\AC-3 output) or raw PCM stream (standard input or output with -). The
    \\input container is
    \\detected from content, or for raw PCM from the name (.sb, .ub, .al, .ul,
    \\.sw), or forced with -f before -i.
    \\Before -i, -sample_rate (or -ar) and -ch_layout (or -ac) describe raw
    \\PCM input, 44100 Hz mono by default. The output container is the -f after
    \\-i, or the output name's extension (.wav, .w64, .au, .aif, .aiff, .afc,
    \\.aifc, .caf, .flac, .ogg, .oga, .opus, .mp2, .ac3, .aac, .adts, .sb, .ub, .al, .ul,
    \\.sw). Formats: wav, w64, au, aiff, caf, flac, ogg, oga, opus, mp2, ac3, adts
    \\and the raw formats u8, s8, s16le,
    \\s16be, s24le, s24be, s32le, s32be, f32le, f32be, f64le, f64be, alaw and
    \\mulaw.
    \\After -i, -ac <channels> or -ch_layout <layout> remixes into that layout
    \\as FFmpeg does (-ac takes the default layout for the count), and -ar
    \\<rate> resamples as FFmpeg's aresample does.
    \\-c copy keeps the encoded samples and needs the same codec on both sides;
    \\-c <encoder> (such as pcm_s24le) picks the output codec, which the output
    \\must carry. Transcoding converts the sample format as FFmpeg does.
    \\-dither_method (rectangular, triangular, triangular_hp, lipshitz,
    \\f_weighted, modified_e_weighted, improved_e_weighted, shibata,
    \\low_shibata, high_shibata, or FFmpeg's number) and -dither_scale (0 to
    \\2147483647, default 1) dither the conversion as FFmpeg does.
    \\-c mp2 (the default for .mp2, .m2a and .mpa) encodes MPEG audio Layer II
    \\as FFmpeg's mp2 encoder does, -c mp2fixed as its mp2fixed, from mono or
    \\stereo at 32, 44.1, 48, 16, 22.05 or 24 kHz; -b:a sets the bit rate
    \\(default 384k, 160k below 32 kHz).
    \\-c flac (the default for .flac, .ogg and .oga) encodes FLAC as FFmpeg
    \\does, into FLAC or Ogg, with its options: -compression_level (0 to 12,
    \\default 5), -lpc_type (none,
    \\fixed, levinson, cholesky), -lpc_passes, -lpc_coeff_precision,
    \\-min_prediction_order, -max_prediction_order, -prediction_order_method
    \\(estimation, 2level, 4level, 8level, search, log), -min_partition_order,
    \\-max_partition_order, -ch_mode (auto, indep, left_side, right_side,
    \\mid_side), -exact_rice_parameters, -multi_dim_quant, and -strict
    \\experimental for 32 bits per sample.
    \\-c adpcm_ima_wav and -c adpcm_ms encode IMA WAV and Microsoft ADPCM into
    \\WAV as FFmpeg's encoders do, from mono or stereo, with -block_size (32
    \\to 8192, a power of two, default 1024) and -trellis (0 to 16); WAV
    \\input in either is decoded as FFmpeg decodes it.
    \\-c g722 (adpcm_g722) and -c g726le (adpcm_g726le) encode G.722 and
    \\G.726 into AU as FFmpeg's encoders and muxer do, from mono: G.722 with
    \\-trellis (0 to 16), G.726 at 8 kHz with -code_size (2 to 5, default 4)
    \\or -b:a; AU input in either is decoded as FFmpeg decodes it.
    \\-c alac encodes ALAC into CAF (.caf, whose default is pcm_s16be) as
    \\FFmpeg's encoder and muxer do, with -compression_level (0 to 2) and
    \\-min_prediction_order and -max_prediction_order (1 to 30); a CAF output
    \\of ALAC must be a file, which the muxer seeks back in.
    \\-c ac3 (the default for .ac3) encodes AC-3 as FFmpeg's ac3 encoder and
    \\muxer do, from its layouts (mono to 5.1) at 32, 44.1 or 48 kHz; -b:a
    \\sets the bit rate (the nearest of 32k to 640k; by default 96k a full
    \\bandwidth channel, 192k for two, 320k, 384k, 448k), with -cutoff,
    \\-audio_service_type (ma, ef, vi, hi, di, co, em, vo, ka) and the
    \\encoder's options: -center_mixlev, -surround_mixlev, -mixing_level,
    \\-room_type, -per_frame_metadata, -copyright, -dialnorm, -dsur_mode,
    \\-original, -dmix_mode, -ltrt_cmixlev, -ltrt_surmixlev, -loro_cmixlev,
    \\-loro_surmixlev, -dsurex_mode, -dheadphone_mode, -ad_conv_type,
    \\-stereo_rematrixing, -channel_coupling and -cpl_start_band.
    \\-c aac (the default for .aac and .adts) encodes AAC-LC into ADTS, with
    \\-b:a or -q:a, -aac_coder (nmr, twoloop, fast), -aac_rc (cbr, abr),
    \\-aac_nmr_speed (0 to 4), -aac_ms, -aac_is, -aac_pns, -aac_tns,
    \\-aac_pce, -aac_allow_71wide, -cutoff and -profile (aac_low or
    \\mpeg2_aac_low).
    \\-y replaces an existing output; without it (or with -n) an existing output
    \\is an error.
    \\Exit codes: 0 success, 1 usage, 2 invalid or truncated media,
    \\3 unsupported media or operation, 4 I/O failure, 5 resource limit,
    \\6 cancellation.
    \\
;

const Command = struct {
    input: []const u8,
    output: []const u8,
    /// The `-f` value before `-i`, if any: the forced input container.
    input_format: ?[]const u8,
    /// The raw PCM parameters before `-i`, as given: the demuxer's
    /// `-sample_rate`, the program's `-ar` (which FFmpeg sets after the
    /// demuxer's options, so it wins), `-ch_layout` and `-ac`.
    input_sample_rate: ?[]const u8,
    input_ar: ?[]const u8,
    input_layout: ?[]const u8,
    input_channels: ?[]const u8,
    /// `-ch_layout` or `-ac` after `-i`: the output's layout (T23c).
    output_layout: ?[]const u8,
    output_channels: ?[]const u8,
    /// `-ar` after `-i`: the output's sample rate (T24).
    output_rate: ?[]const u8,
    /// The `-f` value after `-i`, if any; resolved by `outputContainer`.
    format: ?[]const u8,
    /// The last `-c` value: `copy` or an encoder's name.
    codec: ?[]const u8,
    /// The last `-b:a` (`-b`, `-ab`) value: the encoder's bit rate (T29d).
    bit_rate: ?[]const u8,
    /// The FLAC encoder's options after `-i` (T26c).
    flac: av.flacenc.AvOptions,
    /// The ADPCM encoders' options (T31a); G.722's encoder takes its
    /// `-trellis` (T31c).
    adpcm: av.adpcm.EncodeOptions,
    /// The G.726 encoder's `-code_size` (T31c).
    g726: av.g726.EncodeOptions,
    /// The AC-3 encoder's options (T32c), its bit rate aside (`bit_rate`).
    ac3: av.ac3enc.Options,
    /// The AAC encoder's options (T32d), its bit rate and cutoff aside.
    aac: av.aacenc.Options,
    /// `-q:a` (`-q`, `-aq`, `-qscale:a`): the encoder's fixed quality.
    quality: ?[]const u8,
    dither: av.dither.Options,
    overwrite: bool,
};

/// Codec-private routing stays next to the typed option specifications.
const EncoderOptions = struct {
    flac: av.flacenc.AvOptions = .{},
    adpcm: av.adpcm.EncodeOptions = .{},
    g726: av.g726.EncodeOptions = .{},
    aac: av.aacenc.Options = .{},
    ac3: av.ac3enc.Options = .{},
};

const EncoderGroup = struct {
    field: []const u8,
    Options: type,
    excluded: []const []const u8 = &.{},

    fn owns(comptime group: EncoderGroup, comptime name: []const u8) bool {
        for (group.excluded) |excluded| {
            if (std.mem.eql(u8, name, excluded)) return false;
        }
        return true;
    }
};

const encoder_groups = [_]EncoderGroup{
    .{ .field = "flac", .Options = av.flacenc.AvOptions },
    .{ .field = "adpcm", .Options = av.adpcm.EncodeOptions },
    .{ .field = "g726", .Options = av.g726.EncodeOptions },
    .{ .field = "aac", .Options = av.aacenc.Options, .excluded = &.{ "b", "cutoff", "global_quality", "qscale" } },
    .{ .field = "ac3", .Options = av.ac3enc.Options, .excluded = &.{"b"} },
};

fn encoderGroupOffset(comptime index: usize) usize {
    var count: usize = 0;
    inline for (encoder_groups[0..index]) |group| count += group.Options.option_specs.len;
    return count;
}

const encoder_option_count = encoderGroupOffset(encoder_groups.len);
const RawEncoderOption = struct { arg: []const u8, value: []const u8, position: usize };

comptime {
    @setEvalBranchQuota(20000);
    for (encoder_groups, 0..) |group, i| {
        if (@FieldType(EncoderOptions, group.field) != group.Options) @compileError("encoder option group type mismatch");
        for (group.Options.option_specs) |spec| {
            if (!group.owns(spec.name)) continue;
            for (encoder_groups[i + 1 ..]) |other| {
                for (other.Options.option_specs) |other_spec| {
                    if (other.owns(other_spec.name) and std.mem.eql(u8, spec.name, other_spec.name))
                        @compileError("encoder option belongs to two groups: " ++ spec.name);
                }
            }
        }
    }
}

fn encoderOptionIndex(arg: []const u8) ?usize {
    if (arg.len < 2 or arg[0] != '-') return null;
    inline for (encoder_groups, 0..) |group, i| {
        inline for (group.Options.option_specs, 0..) |spec, j| {
            if (comptime group.owns(spec.name)) {
                if (std.mem.eql(u8, arg[1..], spec.name)) return encoderGroupOffset(i) + j;
            }
        }
    }
    return null;
}

/// Validate only the final spelling/value of each dictionary option. Apply
/// different names in argument order, preserving order between aliases.
fn resolveEncoderOptions(raw: *const [encoder_option_count]?RawEncoderOption, args: []const [:0]const u8, target: *EncoderOptions) ?Usage {
    for (args, 0..) |_, position| {
        inline for (encoder_groups, 0..) |group, i| {
            inline for (group.Options.option_specs, 0..) |_, j| {
                if (raw[encoderGroupOffset(i) + j]) |option| {
                    if (option.position == position) {
                        av.options.set(group.Options, &@field(target, group.field), option.arg[1..], option.value) catch
                            return .{ .reason = "invalid value for", .arg = option.arg };
                    }
                }
            }
        }
    }
    return null;
}

/// A rejected command line: a reason and, when one is involved, the argument.
const Usage = struct {
    reason: []const u8,
    arg: ?[]const u8 = null,
};

const Parsed = union(enum) {
    help,
    command: Command,
    usage: Usage,
};

/// Argument order carries the paths already accepted. Input options precede
/// `-i`, output options follow it, and the output path closes the command.
const ParsePaths = union(enum) {
    input_options,
    output_options: []const u8,
    complete: struct { input: []const u8, output: []const u8 },
};

pub fn main(init: std.process.Init) u8 {
    return @backingInt(run(init));
}

fn run(init: std.process.Init) ExitStatus {
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        printError(io, "zffmpeg: out of memory\n", .{});
        return .limit;
    };
    const command = switch (parse(args)) {
        .help => return status.writeStdout(io, "zffmpeg", help),
        .usage => |u| {
            if (u.arg) |arg| {
                printError(io, "zffmpeg: {s}: {s}\n" ++ usage, .{ u.reason, arg });
            } else {
                printError(io, "zffmpeg: {s}\n" ++ usage, .{u.reason});
            }
            return .usage;
        },
        .command => |c| c,
    };
    const container = outputContainer(command) catch |err| switch (err) {
        error.FormatRequired => {
            printError(io, "zffmpeg: -f is required when writing to standard output\n" ++ usage, .{});
            return .usage;
        },
        error.UnknownFormat => {
            // outputContainer returns UnknownFormat only for a -f value.
            printError(io, "zffmpeg: {s}: unsupported output format\n", .{command.format.?});
            return .unsupported;
        },
        error.UnknownExtension => {
            printError(io, "zffmpeg: {s}: cannot choose an output format from the name; use -f\n", .{command.output});
            return .unsupported;
        },
    };
    const input_container: ?av.convert.Container = if (command.input_format) |name|
        av.formats.findDemuxer(name) orelse {
            printError(io, "zffmpeg: {s}: unsupported input format\n", .{name});
            return .unsupported;
        }
    else
        null;
    // FFmpeg sets the program's -ar after the demuxer's -sample_rate.
    const input_rate: ?status.RawRate = if (command.input_ar) |text|
        .{ .number = text }
    else if (command.input_sample_rate) |text|
        .{ .option = text }
    else
        null;
    const raw_params = switch (status.rawParams(io, "zffmpeg", input_rate, command.input_layout, command.input_channels)) {
        .ok => |params| params,
        .failed => |exit| return exit,
    };
    const output_layout = switch (status.layoutOption(io, "zffmpeg", command.output_layout, command.output_channels)) {
        .ok => |layout| layout,
        .failed => |exit| return exit,
    };
    // FFmpeg's number syntax (`44.1k`, T17a); 0 keeps the input's rate, as
    // FFmpeg's encoder then takes it.
    const output_rate: ?u32 = if (command.output_rate) |text| rate: {
        const rate = av.number.parseInt(text) catch -1;
        if (rate < 0) {
            printError(io, "zffmpeg: {s}: invalid sample rate\n", .{text});
            return .usage;
        }
        break :rate if (rate == 0) null else @intCast(rate);
    } else null;
    // The last -c only, as FFmpeg takes it: an unknown encoder before it
    // is never looked up.
    var mode: av.convert.Mode = .transcode;
    var encoder: ?av.codecs.Codec = null;
    var mp2: av.mp2enc.Options = .{};
    if (command.codec) |name| {
        if (std.mem.eql(u8, name, "copy")) {
            mode = .copy;
        } else {
            // An encoder, or a codec's first encoder, as FFmpeg finds
            // them (T23a, T26c, T31c).
            const found = av.codecs.findEncoderOrCodec(name) orelse {
                printError(io, "zffmpeg: unknown encoder: {s}\n" ++ usage, .{name});
                return .usage;
            };
            encoder = found.codec;
            // The MP2 encoders share the codec (T29d).
            mp2.fixed = std.mem.eql(u8, found.name, "mp2fixed");
        }
    }
    if (command.bit_rate) |text| {
        mp2.bit_rate = parseBitRate(text) orelse {
            printError(io, "zffmpeg: {s}: invalid bit rate\n", .{text});
            return .usage;
        };
    }
    var ac3 = command.ac3;
    ac3.bit_rate = mp2.bit_rate;
    var aac = command.aac;
    aac.bit_rate = mp2.bit_rate;
    aac.cutoff = ac3.cutoff;
    if (command.quality) |text| {
        // The program's -q: a double; from 0 up, AV_CODEC_FLAG_QSCALE and
        // global_quality = FF_QP2LAMBDA * q.
        const q = av.number.parseNumber(text, .double, -std.math.inf(f64), std.math.inf(f64)) catch {
            printError(io, "zffmpeg: {s}: invalid quality\n", .{text});
            return .usage;
        };
        aac.setQuality(q);
    }
    // The input's tags are carried, as FFmpeg's default -map_metadata does
    // (T21c, the project owner's choice).
    var tags: av.metadata.Dictionary = .empty;
    defer tags.deinit(init.gpa);
    return convert(io, command, .{
        .output = container,
        .mode = mode,
        .codec = encoder,
        .flac = command.flac.toOptions(),
        .mp2 = mp2,
        .ac3 = ac3,
        .aac = aac,
        .adpcm = command.adpcm,
        .alac = alacOptions(command.flac),
        .g72x = .{ .trellis = command.adpcm.trellis, .code_size = command.g726.code_size, .bit_rate = mp2.bit_rate },
        .dither = command.dither,
        .input = .{ .format = input_container, .raw = raw_params },
        // FFmpeg's input -ch_layout names the stream's layout, which its
        // command line then leaves as it is; -ac gives a count it may name.
        .guess_layout = command.input_layout == null,
        .layout = output_layout,
        .sample_rate = output_rate,
        .gpa = init.gpa,
        .tags = .{ .gpa = init.gpa, .dictionary = &tags },
    });
}

/// The command line, in FFmpeg's syntax: an option before `-i` applies to
/// the input, after it to the output. An option given again replaces its
/// value, as FFmpeg's last one wins (FFmpeg warns; zffmpeg prints errors
/// only).
fn parse(args: []const [:0]const u8) Parsed {
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        return .help;
    }
    var paths: ParsePaths = .input_options;
    var input_format: ?[]const u8 = null;
    var input_sample_rate: ?[]const u8 = null;
    var input_ar: ?[]const u8 = null;
    var input_layout: ?[]const u8 = null;
    var input_channels: ?[]const u8 = null;
    var output_layout: ?[]const u8 = null;
    var output_channels: ?[]const u8 = null;
    var output_rate: ?[]const u8 = null;
    var format: ?[]const u8 = null;
    var codec: ?[]const u8 = null;
    var bit_rate: ?[]const u8 = null;
    var raw_encoder_options: [encoder_option_count]?RawEncoderOption = @splat(null);
    var quality: ?[]const u8 = null;
    var dither_method: ?[]const u8 = null;
    var dither_scale: ?[]const u8 = null;
    var yes = false;
    var no = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (paths == .complete) return .{ .usage = .{ .reason = "options after the output are not supported", .arg = arg } };
        if (std.mem.eql(u8, arg, "-y")) {
            yes = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-n")) {
            no = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-i")) {
            if (paths != .input_options) return .{ .usage = .{ .reason = "only one input is supported" } };
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            paths = .{ .output_options = args[i] };
            continue;
        }
        // Every remaining option takes a value, into its slot. The final
        // positional argument transitions the paths to complete instead.
        const slot: *?[]const u8 = if (paths == .input_options) slot: {
            // FFmpeg's raw demuxer options and the -ar/-ac it maps to them
            // (T22c), and -f (T16).
            if (std.mem.eql(u8, arg, "-sample_rate")) break :slot &input_sample_rate;
            if (std.mem.eql(u8, arg, "-ar")) break :slot &input_ar;
            if (std.mem.eql(u8, arg, "-ch_layout")) break :slot &input_layout;
            if (std.mem.eql(u8, arg, "-ac")) break :slot &input_channels;
            if (std.mem.eql(u8, arg, "-f")) break :slot &input_format;
            // FFmpeg would apply these to the input.
            if (isOutputOnly(arg)) return .{ .usage = .{ .reason = "input options other than -f and the raw PCM ones are not supported; put this after -i <input>", .arg = arg } };
            if (arg.len > 1 and arg[0] == '-') return .{ .usage = .{ .reason = "unknown option", .arg = arg } };
            return .{ .usage = .{ .reason = "the output must follow -i <input>", .arg = arg } };
        } else slot: {
            // The output's rate (T24), its layout, which the samples are
            // rematrixed into (T23c), its container, its encoder, and
            // libswresample's dither options (T23a).
            if (std.mem.eql(u8, arg, "-ar")) break :slot &output_rate;
            if (std.mem.eql(u8, arg, "-ch_layout")) break :slot &output_layout;
            if (std.mem.eql(u8, arg, "-ac")) break :slot &output_channels;
            if (std.mem.eql(u8, arg, "-f")) break :slot &format;
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-c:a")) break :slot &codec;
            if (isBitRateOption(arg)) break :slot &bit_rate;
            if (isQualityOption(arg)) break :slot &quality;
            if (std.mem.eql(u8, arg, "-dither_method")) break :slot &dither_method;
            if (std.mem.eql(u8, arg, "-dither_scale")) break :slot &dither_scale;
            if (encoderOptionIndex(arg)) |index| {
                i += 1;
                if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
                raw_encoder_options[index] = .{ .arg = arg, .value = args[i], .position = i };
                continue;
            }
            if (arg.len > 1 and arg[0] == '-') return .{ .usage = .{ .reason = "unknown option", .arg = arg } };
            const accepted_input = paths.output_options;
            paths = .{ .complete = .{ .input = accepted_input, .output = arg } };
            continue;
        };
        i += 1;
        if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
        slot.* = args[i];
    }
    if (yes and no) return .{ .usage = .{ .reason = "-y and -n contradict each other" } };
    var encoder_options: EncoderOptions = .{};
    if (resolveEncoderOptions(&raw_encoder_options, args, &encoder_options)) |problem| return .{ .usage = problem };
    var dither: av.dither.Options = .{};
    if (dither_method) |text| dither.method = av.dither.methodFromOption(text) catch
        return .{ .usage = .{ .reason = "invalid -dither_method", .arg = text } };
    if (dither_scale) |text| dither.scale = av.dither.scaleFromOption(text) catch
        return .{ .usage = .{ .reason = "invalid -dither_scale", .arg = text } };
    const complete = switch (paths) {
        .input_options => return .{ .usage = .{ .reason = "missing -i <input>" } },
        .output_options => return .{ .usage = .{ .reason = "missing output" } },
        .complete => |p| p,
    };
    return .{ .command = .{
        .input = complete.input,
        .output = complete.output,
        .input_format = input_format,
        .input_sample_rate = input_sample_rate,
        .input_ar = input_ar,
        .input_layout = input_layout,
        .input_channels = input_channels,
        .output_layout = output_layout,
        .output_channels = output_channels,
        .output_rate = output_rate,
        .format = format,
        .codec = codec,
        .bit_rate = bit_rate,
        .flac = encoder_options.flac,
        .adpcm = encoder_options.adpcm,
        .g726 = encoder_options.g726,
        .ac3 = encoder_options.ac3,
        .aac = encoder_options.aac,
        .quality = quality,
        .dither = dither,
        .overwrite = yes,
    } };
}

fn outputContainer(command: Command) error{ FormatRequired, UnknownFormat, UnknownExtension }!av.convert.Container {
    if (command.format) |name| {
        return av.formats.findMuxer(name) orelse error.UnknownFormat;
    }
    if (isStdio(command.output)) return error.FormatRequired;
    // The muxers' extensions, without regard to case, after the name's last
    // dot, as FFmpeg's av_match_ext finds them.
    return av.formats.muxerForFileName(command.output) orelse error.UnknownExtension;
}

/// FFmpeg's `-b:a` and its spellings `-b` and `-ab`.
fn isBitRateOption(arg: []const u8) bool {
    for ([_][]const u8{ "-b:a", "-b", "-ab" }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

/// `-b:a` as FFmpeg's `b` option takes it: an `int64` from 0, in FFmpeg's
/// number syntax (`128k`); null when it is not one.
fn parseBitRate(text: []const u8) ?i64 {
    const max: f64 = @floatFromInt(std.math.maxInt(i64));
    const d = av.number.parseNumber(text, .int64, 0, max) catch return null;
    // 2^63 itself is the double nearest INT64_MAX.
    return if (d >= max) std.math.maxInt(i64) else @intFromFloat(d);
}

/// The ALAC encoder's options from the flags it shares with FLAC's
/// (T31b): the codec context's `compression_level` and the private
/// prediction orders, ALAC's defaults (4 and 6) where none was given.
fn alacOptions(flac: av.flacenc.AvOptions) av.alac.EncodeOptions {
    return .{
        .compression_level = flac.compression_level,
        .min_prediction_order = if (flac.min_prediction_order == -1) 4 else flac.min_prediction_order,
        .max_prediction_order = if (flac.max_prediction_order == -1) 6 else flac.max_prediction_order,
    };
}

/// FFmpeg's `-q:a` and its spellings.
fn isQualityOption(arg: []const u8) bool {
    for ([_][]const u8{ "-q:a", "-q", "-aq", "-qscale:a" }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

/// The options zffmpeg takes only after `-i`, where they apply to the
/// output: FFmpeg would apply them to the input before it.
fn isOutputOnly(arg: []const u8) bool {
    for ([_][]const u8{ "-c", "-c:a", "-dither_method", "-dither_scale" }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return isBitRateOption(arg);
}

fn isStdio(path: []const u8) bool {
    return std.mem.eql(u8, path, "-");
}

/// Whether `path` names a regular file, or nothing yet (the output is then
/// created as one); a FIFO or a device cannot seek back.
fn namesRegularOutput(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return err == error.FileNotFound;
    return stat.kind == .file;
}

fn convert(io: std.Io, command: Command, request: av.convert.Request) ExitStatus {
    const cwd = std.Io.Dir.cwd();
    const input_file = if (isStdio(command.input))
        std.Io.File.stdin()
    else
        cwd.openFile(io, command.input, .{}) catch |err| return fail(io, command.input, err);
    defer if (!isStdio(command.input)) input_file.close(io);

    var input_buffer: [av.file.default_buffer_len]u8 = undefined;
    // A regular file is read positionally, which can seek back for Ogg's
    // duration scans (T27d), as zffprobe reads one; a pipe streams.
    const length = av.file.regularLength(io, input_file);
    var reader = if (length != null) input_file.reader(io, &input_buffer) else input_file.readerStreaming(io, &input_buffer);
    // `source` borrows `reader.interface` and `conversion` borrows `source`;
    // all three stay in this frame.
    var source: av.detect.Input = undefined;
    var input = request.input;
    // FFmpeg's extension hints need the name; raw PCM's frame count, a size.
    if (!isStdio(command.input)) input.file_name = command.input;
    input.length = length;
    if (length != null) input.seeker = .file(&reader);
    // Probing past its first 2048 bytes (FFmpeg's retries) allocates.
    input.gpa = request.gpa;
    source.open(&reader.interface, input) catch |err| {
        if (err == error.UnusedOption) {
            printError(io, "zffmpeg: {s}: -sample_rate and -ch_layout apply only to raw PCM input\n", .{command.input});
            return status.of(err);
        }
        return fail(io, command.input, withReadCause(err, &reader));
    };
    defer source.deinit();

    // A regular output file gets a seeker below, so a header written before
    // the samples can be rewritten at the end and a decoded input is
    // decoded once; predicted from what the path names now, before the
    // output exists. `runTo` refuses before writing if it is not one then.
    var seekable_request = request;
    seekable_request.output_seekable = !isStdio(command.output) and namesRegularOutput(io, command.output);
    var conversion = av.convert.Conversion.init(&source, seekable_request, .{}) catch |err| {
        return fail(io, command.input, withReadCause(err, &reader));
    };
    defer conversion.deinit();

    var output_buffer: [av.file.default_buffer_len]u8 = undefined;
    if (isStdio(command.output)) {
        var writer = std.Io.File.stdout().writerStreaming(io, &output_buffer);
        conversion.run(&writer.interface) catch |err| return runFailure(io, command, err, &reader, &writer);
        return .ok;
    }

    if (sameFile(io, input_file, command.output)) {
        printError(io, "zffmpeg: {s}: the output is the input file\n", .{command.output});
        return .usage;
    }
    // Exclusive creation refuses an existing output without a separate,
    // racy existence check, and tells whether this run created the file:
    // only then is it removed after a failure. With -y an existing path is
    // opened as it is, which follows a symbolic link and keeps a pipe or a
    // device what it is.
    var created = true;
    const output_file = cwd.createFile(io, command.output, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => existing: {
            if (!command.overwrite) {
                printError(io, "zffmpeg: {s}: PathAlreadyExists (use -y to replace it)\n", .{command.output});
                return .usage;
            }
            created = false;
            break :existing cwd.createFile(io, command.output, .{}) catch |open_err| return fail(io, command.output, open_err);
        },
        else => return fail(io, command.output, err),
    };
    var writer = output_file.writerStreaming(io, &output_buffer);
    // A regular file can seek back, so a FLAC output's final STREAMINFO
    // replaces the first, as FFmpeg's muxer does on a seekable output
    // (T26c). A pipe or a device keeps the first, as FFmpeg's muxer leaves
    // an unseekable output's (it warns that it cannot rewrite the header).
    const regular = if (output_file.stat(io)) |stat| stat.kind == .file else |_| false;
    const result = conversion.runTo(&writer.interface, if (regular) .file(&writer) else null);
    // Close before removing: a file cannot be deleted while open everywhere.
    output_file.close(io);
    result catch |err| {
        const exit = runFailure(io, command, err, &reader, &writer);
        // A file this run created (a regular one, by exclusive creation);
        // what was there before, replaced with -y, keeps the partial output
        // as FFmpeg's does.
        if (created) cwd.deleteFile(io, command.output) catch |delete_err| {
            printError(io, "zffmpeg: {s}: cannot remove the partial output: {t}\n", .{ command.output, delete_err });
        };
        return exit;
    };
    return .ok;
}

/// Whether `output_path` names the file `input` is open on, by file identity
/// rather than spelling, so `./in.wav` and a redirected standard input are
/// caught too. Without a device number, two files on different volumes with
/// the same index also count as the same: a refusal, never a lost input.
fn sameFile(io: std.Io, input: std.Io.File, output_path: []const u8) bool {
    const input_stat = input.stat(io) catch return false;
    if (input_stat.kind != .file) return false;
    const output_stat = std.Io.Dir.cwd().statFile(io, output_path, .{}) catch return false;
    return output_stat.kind == .file and output_stat.inode == input_stat.inode;
}

/// Reports a failure after the output started: an output failure (a write,
/// or FLAC's seek back to STREAMINFO) names the output and its file error,
/// anything else names the input.
fn runFailure(
    io: std.Io,
    command: Command,
    err: av.convert.RunError,
    reader: *const std.Io.File.Reader,
    writer: *const std.Io.File.Writer,
) ExitStatus {
    if (err == error.WriteFailed) {
        const cause: status.Error = if (writer.err) |e| e else if (writer.seek_err) |e| e else error.WriteFailed;
        return fail(io, command.output, cause);
    }
    // The output's encoder or muxer refusing what the samples became: the
    // AC-3 encoder's bit allocation (T32c), the AAC encoder's NaN check and
    // an ADTS frame too large (T32d).
    switch (err) {
        error.InvalidOption, error.InvalidSamples, error.FrameTooLarge => return fail(io, command.output, err),
        else => {},
    }
    return fail(io, command.input, withReadCause(err, reader));
}

/// The generic reader reports only `IoFailure`; the file adapter keeps the cause.
fn withReadCause(err: status.Error, reader: *const std.Io.File.Reader) status.Error {
    if (err == error.IoFailure) {
        if (reader.err) |cause| return cause;
    }
    return err;
}

fn fail(io: std.Io, path: []const u8, err: status.Error) ExitStatus {
    printError(io, "zffmpeg: {s}: {t}\n", .{ path, err });
    return status.of(err);
}
