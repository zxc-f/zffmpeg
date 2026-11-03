// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
// fftools/ffmpeg_opt.c at the pinned reference revision was read for the -y/-n
// and same-file behavior; see port.md "zffmpeg command" for the differences.
//! zffmpeg: converts or stream-copies one WAV, Wave64 or AU stream (TODO.md
//! T13b, T21b).
//!
//!     zffmpeg [-y | -n] -i <input | -> [-c copy] [-f wav|w64|au] <output | ->
//!
//! The input container is detected from content. The output container is `-f`,
//! or else the output name's `.wav`, `.w64` or `.au` extension; `-` (standard
//! output) needs `-f`. `-c copy` copies the encoded samples, which works only when both
//! containers carry the same codec; without it the samples are decoded and
//! encoded again. Output options follow `-i`, as in FFmpeg, where an option
//! before `-i` applies to the input.
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

const usage = "usage: zffmpeg [-y | -n] -i <input | -> [-c copy] [-f wav|w64|au] <output | ->\n";
const help = usage ++
    \\
    \\Converts one WAV, Wave64 or AU stream (standard input or output with -). The
    \\output container is -f, or the output name's .wav, .w64 or .au extension.
    \\-c copy keeps the encoded samples and needs the same codec on both sides.
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
    /// The `-f` value, if any; resolved by `outputContainer`.
    format: ?[]const u8,
    mode: av.convert.Mode,
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
            printError(io, "zffmpeg: {s}: cannot choose an output format from the name; use -f wav or -f au\n", .{command.output});
            return .unsupported;
        },
    };
    return convert(io, command, .{ .output = container, .mode = command.mode });
}

fn parse(args: []const [:0]const u8) Parsed {
    if (args.len == 2 and (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help"))) {
        return .help;
    }
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var format: ?[]const u8 = null;
    var copy = false;
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
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-c:a")) {
            // Before -i, FFmpeg applies these to the input; that is not supported.
            if (input == null) return .{ .usage = .{ .reason = "input options are not supported; put this after -i <input>", .arg = arg } };
            i += 1;
            if (i == args.len) return .{ .usage = .{ .reason = "missing value for", .arg = arg } };
            const value: []const u8 = args[i];
            if (arg[1] == 'f') {
                if (format != null) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
                format = value;
            } else {
                if (copy) return .{ .usage = .{ .reason = "given twice", .arg = arg } };
                if (!std.mem.eql(u8, value, "copy")) return .{ .usage = .{ .reason = "only -c copy is supported; got", .arg = value } };
                copy = true;
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage = .{ .reason = "unknown option", .arg = arg } };
        } else {
            if (input == null) return .{ .usage = .{ .reason = "the output must follow -i <input>", .arg = arg } };
            output = arg;
        }
    }
    if (yes and no) return .{ .usage = .{ .reason = "-y and -n contradict each other" } };
    return .{ .command = .{
        .input = input orelse return .{ .usage = .{ .reason = "missing -i <input>" } },
        .output = output orelse return .{ .usage = .{ .reason = "missing output" } },
        .format = format,
        .mode = if (copy) .copy else .transcode,
        .overwrite = yes,
    } };
}

fn outputContainer(command: Command) error{ FormatRequired, UnknownFormat, UnknownExtension }!av.convert.Container {
    if (command.format) |name| {
        return std.meta.stringToEnum(av.convert.Container, name) orelse error.UnknownFormat;
    }
    if (isStdio(command.output)) return error.FormatRequired;
    // FFmpeg matches extensions without regard to case.
    const extension = std.fs.path.extension(command.output);
    if (std.ascii.eqlIgnoreCase(extension, ".wav")) return .wav;
    if (std.ascii.eqlIgnoreCase(extension, ".w64")) return .w64;
    if (std.ascii.eqlIgnoreCase(extension, ".au")) return .au;
    return error.UnknownExtension;
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
    // `conversion` borrows `reader.interface`; both stay in this frame.
    var conversion = av.convert.Conversion.init(&reader.interface, request, .{}) catch |err| {
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
