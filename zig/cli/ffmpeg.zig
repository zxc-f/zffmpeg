// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
// fftools/ffmpeg_opt.c at the pinned reference revision was read for the -y/-n
// and same-file behavior; see port.md "zffmpeg command" for the differences.
//! zffmpeg: converts or stream-copies one WAV, Wave64, AU, AIFF, CAF (input
//! only), FLAC or raw PCM stream (TODO.md T13b, T21b, T22b, T22c, T22d,
//! T26a, T26c).
//!
//!     zffmpeg [-y | -n] [-f <format>] [-sample_rate <rate> | -ar <rate>]
//!             [-ch_layout <layout> | -ac <channels>] -i <input | -> [-c copy|<encoder>]
//!             [-ar <rate>] [-ac <channels> | -ch_layout <layout>]
//!             [-dither_method <method>] [-dither_scale <scale>]
//!             [FLAC encoder options] [-f <format>] <output | ->
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

const usage = "usage: zffmpeg [-y | -n] [-f <format>] [-sample_rate <rate>] [-ch_layout <layout>] -i <input | -> [-c copy|<encoder>] [-ar <rate>] [-ac <channels> | -ch_layout <layout>] [-dither_method <method>] [-dither_scale <scale>] [FLAC encoder options] [-f <format>] <output | ->\n";
const help = usage ++
    \\
    \\Converts one WAV, Wave64, AU, AIFF, CAF (input only), FLAC, Ogg (Vorbis
    \\and FLAC input, FLAC output) or raw PCM stream (standard input or output
    \\with -). The input container is detected
    \\from content, or for raw PCM from the name (.sb, .ub, .al, .ul, .sw), or
    \\forced with -f before -i.
    \\Before -i, -sample_rate (or -ar) and -ch_layout (or -ac) describe raw
    \\PCM input, 44100 Hz mono by default. The output container is the -f after
    \\-i, or the output name's extension (.wav, .w64, .au, .aif, .aiff, .afc,
    \\.aifc, .flac, .ogg, .oga, .opus, .sb, .ub, .al, .ul, .sw). Formats: wav,
    \\w64, au, aiff, flac, ogg, oga, opus and the raw formats u8, s8, s16le,
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
    \\-c flac (the default for .flac, .ogg and .oga) encodes FLAC as FFmpeg
    \\does, into FLAC or Ogg, with its options: -compression_level (0 to 12,
    \\default 5), -lpc_type (none,
    \\fixed, levinson, cholesky), -lpc_passes, -lpc_coeff_precision,
    \\-min_prediction_order, -max_prediction_order, -prediction_order_method
    \\(estimation, 2level, 4level, 8level, search, log), -min_partition_order,
    \\-max_partition_order, -ch_mode (auto, indep, left_side, right_side,
    \\mid_side), -exact_rice_parameters, -multi_dim_quant, and -strict
    \\experimental for 32 bits per sample.
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
    /// The FLAC encoder's options after `-i` (T26c).
    flac: av.flacenc.AvOptions,
    dither: av.dither.Options,
    overwrite: bool,
};

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
    if (command.codec) |name| {
        if (std.mem.eql(u8, name, "copy")) {
            mode = .copy;
        } else {
            // An encoder, as FFmpeg names it (T23a, T26c).
            const found = av.codecs.findEncoder(name) orelse {
                printError(io, "zffmpeg: unknown encoder: {s}\n" ++ usage, .{name});
                return .usage;
            };
            encoder = found.codec;
        }
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
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
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
    var flac: av.flacenc.AvOptions = .{};
    var dither_method: ?[]const u8 = null;
    var dither_scale: ?[]const u8 = null;
    var yes = false;
    var no = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (output != null) return .{ .usage = .{ .reason = "options after the output are not supported", .arg = arg } };
        if (std.mem.eql(u8, arg, "-y")) {
            yes = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-n")) {
            no = true;
            continue;
        }
        // Every other option takes a value, into its slot.
        const slot: *?[]const u8 = if (std.mem.eql(u8, arg, "-i")) slot: {
            if (input != null) return .{ .usage = .{ .reason = "only one input is supported" } };
            break :slot &input;
        } else if (input == null) slot: {
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
            if (std.mem.eql(u8, arg, "-dither_method")) break :slot &dither_method;
            if (std.mem.eql(u8, arg, "-dither_scale")) break :slot &dither_scale;
            if (isFlacOption(arg)) {
                // The FLAC encoder's options, in FFmpeg's syntax (T26c);
                // FFmpeg leaves them unused for another encoder, as
                // zffmpeg does.
                i += 1;
                if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
                av.options.set(av.flacenc.AvOptions, &flac, arg[1..], args[i]) catch
                    return .{ .usage = .{ .reason = "invalid value for", .arg = arg } };
                continue;
            }
            if (arg.len > 1 and arg[0] == '-') return .{ .usage = .{ .reason = "unknown option", .arg = arg } };
            output = arg;
            continue;
        };
        i += 1;
        if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
        slot.* = args[i];
    }
    if (yes and no) return .{ .usage = .{ .reason = "-y and -n contradict each other" } };
    var dither: av.dither.Options = .{};
    if (dither_method) |text| dither.method = av.dither.methodFromOption(text) catch
        return .{ .usage = .{ .reason = "invalid -dither_method", .arg = text } };
    if (dither_scale) |text| dither.scale = av.dither.scaleFromOption(text) catch
        return .{ .usage = .{ .reason = "invalid -dither_scale", .arg = text } };
    return .{ .command = .{
        .input = input orelse return .{ .usage = .{ .reason = "missing -i <input>" } },
        .output = output orelse return .{ .usage = .{ .reason = "missing output" } },
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
        .flac = flac,
        .dither = dither,
        .overwrite = yes,
    } };
}

fn outputContainer(command: Command) error{ FormatRequired, UnknownFormat, UnknownExtension }!av.convert.Container {
    if (command.format) |name| {
        return av.formats.findMuxer(name) orelse error.UnknownFormat;
    }
    if (isStdio(command.output)) return error.FormatRequired;
    // The muxers' extensions, without regard to case, as FFmpeg matches them.
    return av.formats.muxerForExtension(std.fs.path.extension(command.output)) orelse error.UnknownExtension;
}

fn isFlacOption(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    inline for (av.flacenc.AvOptions.option_specs) |spec| {
        if (std.mem.eql(u8, arg[1..], spec.name)) return true;
    }
    return false;
}

/// The options zffmpeg takes only after `-i`, where they apply to the
/// output: FFmpeg would apply them to the input before it.
fn isOutputOnly(arg: []const u8) bool {
    for ([_][]const u8{ "-c", "-c:a", "-dither_method", "-dither_scale" }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn isStdio(path: []const u8) bool {
    return std.mem.eql(u8, path, "-");
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

    var conversion = av.convert.Conversion.init(&source, request, .{}) catch |err| {
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
