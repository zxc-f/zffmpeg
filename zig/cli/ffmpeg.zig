// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
// fftools/ffmpeg_opt.c at the pinned reference revision was read for the -y/-n
// and same-file behavior; see port.md "zffmpeg command" for the differences.
//! zffmpeg: converts or stream-copies one WAV, Wave64, AU, AIFF, CAF (input
//! only) or raw PCM stream (TODO.md T13b, T21b, T22b, T22c, T22d).
//!
//!     zffmpeg [-y | -n] [-f <format>] [-sample_rate <rate> | -ar <rate>]
//!             [-ch_layout <layout> | -ac <channels>] -i <input | -> [-c copy|<encoder>]
//!             [-ar <rate>] [-ac <channels> | -ch_layout <layout>]
//!             [-dither_method <method>] [-dither_scale <scale>] [-f <format>] <output | ->
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
//! file was created removes it; output already written to standard output
//! stays. Exit statuses are those of zffprobe (`status.zig`); the conversion
//! itself is `av.convert`, so this file only handles arguments, files and
//! output.

const std = @import("std");
const av = @import("av");
const status = @import("status.zig");
const ExitStatus = status.ExitStatus;
const printError = status.printError;

const usage = "usage: zffmpeg [-y | -n] [-f <format>] [-sample_rate <rate>] [-ch_layout <layout>] -i <input | -> [-c copy|<encoder>] [-ar <rate>] [-ac <channels> | -ch_layout <layout>] [-dither_method <method>] [-dither_scale <scale>] [-f <format>] <output | ->\n";
const help = usage ++
    \\
    \\Converts one WAV, Wave64, AU, AIFF, CAF (input only) or raw PCM stream
    \\(standard input or output with -). The input container is detected from content, or for raw
    \\PCM from the name (.sb, .ub, .al, .ul, .sw), or forced with -f before -i.
    \\Before -i, -sample_rate (or -ar) and -ch_layout (or -ac) describe raw
    \\PCM input, 44100 Hz mono by default. The output container is the -f after
    \\-i, or the output name's extension (.wav, .w64, .au, .aif, .aiff, .afc,
    \\.aifc, .sb, .ub, .al, .ul, .sw). Formats: wav, w64, au, aiff and the raw
    \\formats u8, s8, s16le, s16be, s24le, s24be, s32le, s32be, f32le, f32be,
    \\f64le, f64be, alaw and mulaw.
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
    /// The raw PCM parameters before `-i`, as given.
    input_rate: ?[]const u8,
    input_layout: ?[]const u8,
    input_channels: ?[]const u8,
    /// `-ch_layout` or `-ac` after `-i`: the output's layout (T23c).
    output_layout: ?[]const u8,
    output_channels: ?[]const u8,
    /// `-ar` after `-i`: the output's sample rate (T24).
    output_rate: ?[]const u8,
    /// The `-f` value after `-i`, if any; resolved by `outputContainer`.
    format: ?[]const u8,
    mode: av.convert.Mode,
    /// The `-c` encoder, when it names one rather than `copy`.
    encoder: ?av.pcm.Codec,
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
    const raw_params = switch (status.rawParams(io, "zffmpeg", command.input_rate, command.input_layout, command.input_channels)) {
        .ok => |params| params,
        .failed => |exit| return exit,
    };
    const output_layout = switch (status.layoutOption(io, "zffmpeg", command.output_layout, command.output_channels)) {
        .ok => |layout| layout,
        .failed => |exit| return exit,
    };
    const output_rate: ?u32 = if (command.output_rate) |text| rate: {
        const rate = std.fmt.parseInt(u32, text, 10) catch 0;
        if (rate == 0) {
            printError(io, "zffmpeg: {s}: invalid sample rate\n", .{text});
            return .usage;
        }
        break :rate rate;
    } else null;
    // The input's tags are carried, as FFmpeg's default -map_metadata does
    // (T21c, the project owner's choice).
    var tags: av.metadata.Dictionary = .empty;
    defer tags.deinit(init.gpa);
    return convert(io, command, .{
        .output = container,
        .mode = command.mode,
        .codec = command.encoder,
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

fn parse(args: []const [:0]const u8) Parsed {
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        return .help;
    }
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var input_format: ?[]const u8 = null;
    var input_rate: ?[]const u8 = null;
    var input_layout: ?[]const u8 = null;
    var input_channels: ?[]const u8 = null;
    var output_layout: ?[]const u8 = null;
    var output_channels: ?[]const u8 = null;
    var output_rate: ?[]const u8 = null;
    var format: ?[]const u8 = null;
    var codec_given = false;
    var copy = false;
    var encoder: ?av.pcm.Codec = null;
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
        } else if (std.mem.eql(u8, arg, "-n")) {
            no = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            if (input != null) return .{ .usage = .{ .reason = "only one input is supported" } };
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            input = args[i];
        } else if (input == null and isRawOption(arg)) {
            // FFmpeg's raw demuxer options, and the -ar/-ac it maps to them
            // before -i (T22c).
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            const is_rate = std.mem.eql(u8, arg, "-sample_rate") or std.mem.eql(u8, arg, "-ar");
            if (is_rate) {
                if (input_rate != null) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
                input_rate = args[i];
            } else {
                if (input_layout != null or input_channels != null) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
                if (std.mem.eql(u8, arg, "-ac")) input_channels = args[i] else input_layout = args[i];
            }
        } else if (input != null and std.mem.eql(u8, arg, "-ar")) {
            // After -i, the output's sample rate (T24).
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            if (output_rate != null) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
            output_rate = args[i];
        } else if (input != null and (std.mem.eql(u8, arg, "-ch_layout") or std.mem.eql(u8, arg, "-ac"))) {
            // After -i, the output's layout, which the samples are
            // rematrixed into (T23c).
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            if (output_layout != null or output_channels != null) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
            if (std.mem.eql(u8, arg, "-ac")) output_channels = args[i] else output_layout = args[i];
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-c:a")) {
            // Before -i, FFmpeg applies these to the input; -f is an input
            // option here (T16), -c is not.
            const is_format = arg[1] == 'f';
            if (input == null and !is_format) return .{ .usage = .{ .reason = "input options other than -f and the raw PCM ones are not supported; put this after -i <input>", .arg = arg } };
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            const value: []const u8 = args[i];
            if (is_format) {
                const slot = if (input == null) &input_format else &format;
                if (slot.* != null) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
                slot.* = value;
            } else {
                if (codec_given) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
                codec_given = true;
                if (std.mem.eql(u8, value, "copy")) {
                    copy = true;
                } else {
                    // An encoder, as FFmpeg names it (T23a).
                    const found = av.codecs.findEncoder(value) orelse return .{ .usage = .{ .reason = "unknown encoder", .arg = value } };
                    encoder = found.codec;
                }
            }
        } else if (std.mem.eql(u8, arg, "-dither_method") or std.mem.eql(u8, arg, "-dither_scale")) {
            // libswresample's options, for the output (T23a); before -i
            // FFmpeg takes them for the input and ignores them.
            if (input == null) return .{ .usage = .{ .reason = "input options other than -f and the raw PCM ones are not supported; put this after -i <input>", .arg = arg } };
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            const slot = if (std.mem.eql(u8, arg, "-dither_method")) &dither_method else &dither_scale;
            if (slot.* != null) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
            slot.* = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage = .{ .reason = "unknown option", .arg = arg } };
        } else {
            if (input == null) return .{ .usage = .{ .reason = "the output must follow -i <input>", .arg = arg } };
            output = arg;
        }
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
        .input_rate = input_rate,
        .input_layout = input_layout,
        .input_channels = input_channels,
        .output_layout = output_layout,
        .output_channels = output_channels,
        .output_rate = output_rate,
        .format = format,
        .mode = if (copy) .copy else .transcode,
        .encoder = encoder,
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

fn isRawOption(arg: []const u8) bool {
    for ([_][]const u8{ "-sample_rate", "-ar", "-ch_layout", "-ac" }) |name| {
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
    var reader = input_file.readerStreaming(io, &input_buffer);
    // `source` borrows `reader.interface` and `conversion` borrows `source`;
    // all three stay in this frame.
    var source: av.detect.Input = undefined;
    var input = request.input;
    // FFmpeg's extension hints need the name; raw PCM's frame count, a size.
    if (!isStdio(command.input)) input.file_name = command.input;
    input.length = av.file.regularLength(io, input_file);
    source.open(&reader.interface, input) catch |err| {
        if (err == error.UnusedOption) {
            printError(io, "zffmpeg: {s}: -sample_rate and -ch_layout apply only to raw PCM input\n", .{command.input});
            return status.of(err);
        }
        return fail(io, command.input, withReadCause(err, &reader));
    };

    var conversion = av.convert.Conversion.init(&source, request, .{}) catch |err| {
        return fail(io, command.input, withReadCause(err, &reader));
    };

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
    // racy existence check.
    const output_file = cwd.createFile(io, command.output, .{ .exclusive = !command.overwrite }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            printError(io, "zffmpeg: {s}: PathAlreadyExists (use -y to replace it)\n", .{command.output});
            return .usage;
        },
        else => return fail(io, command.output, err),
    };
    var writer = output_file.writerStreaming(io, &output_buffer);
    const result = conversion.run(&writer.interface);
    // Close before removing: a file cannot be deleted while open everywhere.
    output_file.close(io);
    result catch |err| {
        const exit = runFailure(io, command, err, &reader, &writer);
        cwd.deleteFile(io, command.output) catch |delete_err| {
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

/// Reports a failure after the output started: an output failure names the
/// output and its file error, anything else names the input.
fn runFailure(
    io: std.Io,
    command: Command,
    err: av.convert.RunError,
    reader: *const std.Io.File.Reader,
    writer: *const std.Io.File.Writer,
) ExitStatus {
    if (err == error.WriteFailed) {
        const cause: status.Error = writer.err orelse error.WriteFailed;
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
