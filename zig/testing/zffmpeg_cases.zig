// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! zffmpeg process cases that need files prepared on disk (TODO.md T13b): the
//! overwrite policy, same-file refusal, what preflight leaves alone, removal of
//! a partial output, read and write failures through redirected standard
//! streams, and a long stream. Cases that only check stdout, stderr and the
//! status are `convert_cases` in build.zig.
//!
//!     zffmpeg-cases <zffmpeg> <fixture directory> <empty work directory>
//!
//! The fixture directory is zig/testing/fixtures. `zig build test` runs it in
//! a fresh work directory and expects no output and status 0; each failing case
//! prints one line to stderr.

const std = @import("std");
const builtin = @import("builtin");
const av = @import("av");

const Outcome = struct {
    term: std.process.Child.Term,
    stderr: []const u8,
};

/// Where zffmpeg's standard output goes.
const Stdout = union(enum) {
    /// `stdout.bin` in the work directory.
    scratch,
    file: std.Io.File,
    /// A pipe whose read end is closed at once, so writing to it fails.
    closed_pipe,
};

const Harness = struct {
    io: std.Io,
    dir: std.Io.Dir,
    exe: []const u8,
    failures: usize = 0,
    stderr_buffer: [4096]u8 = undefined,

    /// Runs zffmpeg in the work directory; standard error is collected from
    /// `stderr.txt`.
    fn runWith(h: *Harness, args: []const []const u8, stdin: std.process.SpawnOptions.StdIo, stdout: Stdout) !Outcome {
        const io = h.io;
        var argv_buffer: [16][]const u8 = undefined;
        argv_buffer[0] = h.exe;
        @memcpy(argv_buffer[1..][0..args.len], args);
        const stderr_file = try h.dir.createFile(io, "stderr.txt", .{});
        defer stderr_file.close(io);
        const scratch: ?std.Io.File = if (stdout == .scratch) try h.dir.createFile(io, "stdout.bin", .{}) else null;
        defer if (scratch) |file| file.close(io);
        var child = try std.process.spawn(io, .{
            .argv = argv_buffer[0 .. args.len + 1],
            .cwd = .{ .dir = h.dir },
            .stdin = stdin,
            .stdout = switch (stdout) {
                .scratch => .{ .file = scratch.? }, // created above for .scratch
                .file => |file| .{ .file = file },
                .closed_pipe => .pipe,
            },
            .stderr = .{ .file = stderr_file },
        });
        if (stdout == .closed_pipe) {
            // Spawned with `.pipe`, so the read end exists.
            child.stdout.?.close(io);
            child.stdout = null;
        }
        const term = try child.wait(io);
        return .{ .term = term, .stderr = try h.dir.readFile(io, "stderr.txt", &h.stderr_buffer) };
    }

    fn run(h: *Harness, args: []const []const u8, stdin: std.process.SpawnOptions.StdIo, stdout: ?std.Io.File) !Outcome {
        return h.runWith(args, stdin, if (stdout) |file| .{ .file = file } else .scratch);
    }

    fn expect(h: *Harness, case: []const u8, outcome: Outcome, exit: u8, stderr_contains: []const u8) void {
        const exited_as_expected = switch (outcome.term) {
            .exited => |code| code == exit,
            else => false,
        };
        if (!exited_as_expected or std.mem.find(u8, outcome.stderr, stderr_contains) == null) {
            h.fail(case, "ended with {any}, stderr \"{s}\"; expected exit {d} and stderr containing \"{s}\"", .{
                outcome.term, outcome.stderr, exit, stderr_contains,
            });
        }
    }

    fn expectContent(h: *Harness, case: []const u8, path: []const u8, expected: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        const content = h.dir.readFile(h.io, path, &buffer) catch |err| {
            return h.fail(case, "{s}: {t}", .{ path, err });
        };
        if (!std.mem.eql(u8, content, expected)) h.fail(case, "{s} has unexpected content", .{path});
    }

    fn expectAbsent(h: *Harness, case: []const u8, path: []const u8) void {
        if (h.dir.statFile(h.io, path, .{})) |_| {
            h.fail(case, "{s} exists", .{path});
        } else |err| if (err != error.FileNotFound) h.fail(case, "{s}: {t}", .{ path, err });
    }

    fn write(h: *Harness, path: []const u8, bytes: []const u8) !void {
        try h.dir.writeFile(h.io, .{ .sub_path = path, .data = bytes });
    }

    fn fail(h: *Harness, case: []const u8, comptime fmt: []const u8, args: anytype) void {
        h.failures += 1;
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writerStreaming(h.io, &buffer);
        const w = &stderr_writer.interface;
        w.print("zffmpeg case \"{s}\": " ++ fmt ++ "\n", .{case} ++ args) catch return;
        w.flush() catch return;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.Usage;
    // zffmpeg runs in the work directory, so a path relative to ours would
    // not resolve there.
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], init.arena.allocator());
    var fixture_dir = try std.Io.Dir.cwd().openDir(io, args[2], .{});
    defer fixture_dir.close(io);
    var dir = try std.Io.Dir.cwd().openDir(io, args[3], .{});
    defer dir.close(io);
    var h: Harness = .{ .io = io, .dir = dir, .exe = exe };

    var wav_buffer: [256]u8 = undefined;
    const wav_in = try fixture_dir.readFile(io, "wav" ++ std.fs.path.sep_str ++ "mono_8k.wav", &wav_buffer);
    var au_buffer: [256]u8 = undefined;
    const au_out = try fixture_dir.readFile(io, "au" ++ std.fs.path.sep_str ++ "au_mono_8k.au", &au_buffer);
    var late_buffer: [256]u8 = undefined;
    const late = try fixture_dir.readFile(io, "wav" ++ std.fs.path.sep_str ++ "duplicate_data.wav", &late_buffer);
    const previous = "previous content";
    try h.write("in.wav", wav_in);
    try h.write("late.wav", late);

    // The overwrite policy: refuse an existing output unless -y.
    inline for (.{
        .{ "an existing output is kept without -y", &[_][]const u8{ "-i", "in.wav", "out.au" } },
        .{ "an existing output is kept with -n", &[_][]const u8{ "-n", "-i", "in.wav", "out.au" } },
    }) |case| {
        try h.write("out.au", previous);
        h.expect(case[0], try h.run(case[1], .ignore, null), 1, "out.au: PathAlreadyExists");
        try h.expectContent(case[0], "out.au", previous);
    }
    try h.write("out.au", previous);
    h.expect("-y replaces an existing output", try h.run(&.{ "-y", "-i", "in.wav", "out.au" }, .ignore, null), 0, "");
    try h.expectContent("-y replaces an existing output", "out.au", au_out);
    try h.write("out.au", previous);
    h.expect("-y with -n is refused", try h.run(&.{ "-y", "-n", "-i", "in.wav", "out.au" }, .ignore, null), 1, "contradict");
    try h.expectContent("-y with -n is refused", "out.au", previous);

    // The input is never the output, however it is named or passed.
    const dotted = "." ++ std.fs.path.sep_str ++ "in.wav";
    for ([_][]const u8{ "in.wav", dotted }) |output| {
        const case = "the input file as the output is refused";
        h.expect(case, try h.run(&.{ "-y", "-i", "in.wav", "-f", "wav", output }, .ignore, null), 1, "the output is the input file");
        try h.expectContent(case, "in.wav", wav_in);
    }
    {
        const case = "standard input redirected from the output is refused";
        const stdin = try dir.openFile(io, "in.wav", .{});
        defer stdin.close(io);
        h.expect(case, try h.run(&.{ "-y", "-i", "-", "-f", "wav", "in.wav" }, .{ .file = stdin }, null), 1, "the output is the input file");
        try h.expectContent(case, "in.wav", wav_in);
    }

    // Preflight failures touch no output.
    {
        const case = "a rejected operation leaves the existing output";
        try h.write("out.au", previous);
        h.expect(case, try h.run(&.{ "-y", "-i", "in.wav", "-c", "copy", "out.au" }, .ignore, null), 3, "UnsupportedOperation");
        try h.expectContent(case, "out.au", previous);
        h.expect(case, try h.run(&.{ "-i", "in.wav", "-c", "copy", "new.au" }, .ignore, null), 3, "UnsupportedOperation");
        h.expectAbsent(case, "new.au");
        h.expect(case, try h.run(&.{ "-i", "in.wav", "out.mp3" }, .ignore, null), 3, "cannot choose an output format");
        h.expectAbsent(case, "out.mp3");
        h.expect(case, try h.run(&.{ "-y", "-i", "missing.wav", "out.au" }, .ignore, null), 4, "missing.wav: FileNotFound");
        try h.expectContent(case, "out.au", previous);
    }

    // A failure after the output file was created removes it.
    {
        const case = "a late failure removes the partial output";
        h.expect(case, try h.run(&.{ "-i", "late.wav", "new.au" }, .ignore, null), 2, "late.wav: InvalidWave");
        h.expectAbsent(case, "new.au");
        try h.write("out.au", previous);
        h.expect(case, try h.run(&.{ "-y", "-i", "late.wav", "out.au" }, .ignore, null), 2, "late.wav: InvalidWave");
        h.expectAbsent(case, "out.au");
    }

    // Standard streams: a pipe-free round trip, then read and write failures.
    {
        const case = "standard input to standard output";
        const stdin = try dir.openFile(io, "in.wav", .{});
        defer stdin.close(io);
        h.expect(case, try h.run(&.{ "-i", "-", "-f", "au", "-" }, .{ .file = stdin }, null), 0, "");
        try h.expectContent(case, "stdout.bin", au_out);
    }
    // A write-only standard input fails to read. On Windows, std's spawn
    // reopens a passed stdio file with the access its stream needs, so this
    // case cannot be set up there (POSIX duplicates the descriptor as is).
    if (builtin.os.tag != .windows) {
        const case = "an unreadable standard input is a read failure";
        // Created files lack read access unless `.read = true`.
        const stdin = try dir.createFile(io, "write-only.bin", .{});
        defer stdin.close(io);
        h.expect(case, try h.run(&.{ "-i", "-", "-f", "wav", "-" }, .{ .file = stdin }, null), 4, "zffmpeg: -: ");
    }
    try writeLongWav(io, dir, "long.wav");
    // A standard output nobody reads: the small output fails at the final
    // flush, the long one while samples are still being transferred (it
    // exceeds the 64 KiB output buffer).
    for ([_][]const u8{ "in.wav", "long.wav" }) |input| {
        const case = "a closed standard output is a write failure";
        const outcome = try h.runWith(&.{ "-i", input, "-f", "au", "-" }, .ignore, .closed_pipe);
        // Portable: the conversion never reports success.
        if (outcome.term == .exited and outcome.term.exited == 0) h.fail(case, "{s}: reported success", .{input});
        if (builtin.os.tag == .windows) {
            h.expect(case, outcome, 4, "zffmpeg: -: ");
        } else if (outcome.term == .exited) {
            // Otherwise SIGPIPE ended it, as it ends any POSIX filter; the
            // tools install no signal handlers.
            h.expect(case, outcome, 4, "zffmpeg: -: ");
        }
    }

    // A long stream converts through files with exact frame counts.
    {
        const case = "a long stream converts";
        h.expect(case, try h.run(&.{ "-i", "long.wav", "long.au" }, .ignore, null), 0, "");
        const file = try dir.openFile(io, "long.au", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const info = try av.au.probe(&reader.interface, .{});
        if (info.frame_count != long_frames) h.fail(case, "{d} frames", .{info.frame_count});
    }

    return if (h.failures == 0) 0 else 1;
}

const long_frames = 1 << 16;

/// 256 KiB of stereo samples: larger than zffmpeg's 64 KiB output buffer.
fn writeLongWav(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buffer);
    const stereo = try av.audio.Format.init(48000, 2, .s16);
    var writer = try av.wav.Writer.begin(&file_writer.interface, stereo, long_frames, .{});
    var chunk: [1024]i16 = undefined;
    var written: usize = 0;
    while (written < long_frames * 2) : (written += chunk.len) {
        for (&chunk, 0..) |*sample, i| {
            const bits: u16 = @truncate(written + i);
            sample.* = @bitCast(bits);
        }
        try writer.writeFrames(&chunk);
    }
    try writer.finish();
}
