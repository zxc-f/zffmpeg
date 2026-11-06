// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! zffmpeg process cases that need files prepared on disk (TODO.md T13b): the
//! overwrite policy, same-file refusal, what preflight leaves alone, removal of
//! a partial output, read and write failures through redirected standard
//! streams, raw PCM through a real pipe and by file name (T22c), and a long
//! stream. Cases that only check stdout, stderr and the
//! status are `convert_cases` in build.zig.
//!
//!     zffmpeg-cases <zffmpeg> <fixture directory> <empty work directory>
//!
//! The fixture directory is zig/testing/fixtures; the files read from it are
//! listed in build.zig's `zffmpeg_case_fixtures`, as the build re-runs the
//! cases only when a listed file changes. `zig build test` runs it in
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
    gpa: std.mem.Allocator,
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

    /// Runs zffmpeg with `input` written to a pipe as its standard input, so
    /// the input has no size; standard output goes to `stdout.bin`.
    fn runPiped(h: *Harness, args: []const []const u8, input: []const u8) !Outcome {
        const io = h.io;
        var argv_buffer: [16][]const u8 = undefined;
        argv_buffer[0] = h.exe;
        @memcpy(argv_buffer[1..][0..args.len], args);
        const stderr_file = try h.dir.createFile(io, "stderr.txt", .{});
        defer stderr_file.close(io);
        const scratch = try h.dir.createFile(io, "stdout.bin", .{});
        defer scratch.close(io);
        var child = try std.process.spawn(io, .{
            .argv = argv_buffer[0 .. args.len + 1],
            .cwd = .{ .dir = h.dir },
            .stdin = .pipe,
            .stdout = .{ .file = scratch },
            .stderr = .{ .file = stderr_file },
        });
        // Spawned with `.pipe`, so the write end exists (`child.stdin.?`). The input fits in
        // the pipe's buffer; a child that exits early may refuse it.
        const stdin = child.stdin.?;
        stdin.writeStreamingAll(io, input) catch {};
        stdin.close(io);
        child.stdin = null;
        const term = try child.wait(io);
        return .{ .term = term, .stderr = try h.dir.readFile(io, "stderr.txt", &h.stderr_buffer) };
    }

    /// Runs zffmpeg with its standard output a pipe that is read to the
    /// end, which the caller frees (`gpa`).
    fn runCapture(h: *Harness, args: []const []const u8) !struct { outcome: Outcome, stdout: []u8 } {
        const io = h.io;
        var argv_buffer: [16][]const u8 = undefined;
        argv_buffer[0] = h.exe;
        @memcpy(argv_buffer[1..][0..args.len], args);
        const stderr_file = try h.dir.createFile(io, "stderr.txt", .{});
        defer stderr_file.close(io);
        var child = try std.process.spawn(io, .{
            .argv = argv_buffer[0 .. args.len + 1],
            .cwd = .{ .dir = h.dir },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .{ .file = stderr_file },
        });
        // Spawned with `.pipe`, so the read end exists; read before waiting,
        // so a full pipe cannot stall the child.
        var buffer: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buffer);
        const stdout = try reader.interface.allocRemaining(h.gpa, .limited(1 << 22));
        errdefer h.gpa.free(stdout);
        const term = try child.wait(io);
        return .{ .outcome = .{ .term = term, .stderr = try h.dir.readFile(io, "stderr.txt", &h.stderr_buffer) }, .stdout = stdout };
    }

    fn run(h: *Harness, args: []const []const u8, stdin: std.process.SpawnOptions.StdIo, stdout: ?std.Io.File) !Outcome {
        return h.runWith(args, stdin, if (stdout) |file| .{ .file = file } else .scratch);
    }

    /// A refusal: status `exit` (not 0) and a stderr containing
    /// `stderr_contains`, which is not empty, as every stderr contains "".
    fn expect(h: *Harness, case: []const u8, outcome: Outcome, exit: u8, stderr_contains: []const u8) void {
        if (exit == 0 or stderr_contains.len == 0) {
            return h.fail(case, "the case table is wrong: expect needs a failure status and stderr text " ++
                "(expectSuccess checks a success)", .{});
        }
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

    /// Status 0 and nothing on stderr: zffmpeg prints nothing on success.
    /// The caller still checks the output.
    fn expectSuccess(h: *Harness, case: []const u8, outcome: Outcome) void {
        const succeeded = switch (outcome.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!succeeded or outcome.stderr.len != 0) {
            h.fail(case, "ended with {any}, stderr \"{s}\"; expected exit 0 and no stderr", .{ outcome.term, outcome.stderr });
        }
    }

    fn expectContent(h: *Harness, case: []const u8, path: []const u8, expected: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        const content = h.dir.readFile(h.io, path, &buffer) catch |err| {
            return h.fail(case, "{s}: {t}", .{ path, err });
        };
        if (!std.mem.eql(u8, content, expected)) h.fail(case, "{s} has unexpected content", .{path});
    }

    fn expectLacking(h: *Harness, case: []const u8, outcome: Outcome, text: []const u8) void {
        if (std.mem.find(u8, outcome.stderr, text) != null) h.fail(case, "stderr \"{s}\" contains \"{s}\"", .{ outcome.stderr, text });
    }

    /// `path` exists and no longer holds `old`: a partial output kept.
    fn expectReplaced(h: *Harness, case: []const u8, path: []const u8, old: []const u8) !void {
        // A longer file fills the buffer, which is not `old` either.
        var buffer: [1024]u8 = undefined;
        const content = h.dir.readFile(h.io, path, &buffer) catch |err| {
            return h.fail(case, "{s}: {t}", .{ path, err });
        };
        if (std.mem.eql(u8, content, old)) h.fail(case, "{s} still holds its old content", .{path});
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
    var work = try std.Io.Dir.cwd().openDir(io, args[3], .{});
    defer work.close(io);
    // The build reuses the output directory when its inputs are unchanged,
    // so files from an earlier (failed) run may still be there: every run
    // starts in an empty subdirectory.
    try work.deleteTree(io, "run");
    var dir = try work.createDirPathOpen(io, "run", .{});
    defer dir.close(io);
    var h: Harness = .{ .io = io, .gpa = init.gpa, .dir = dir, .exe = exe };

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
    h.expectSuccess("-y replaces an existing output", try h.run(&.{ "-y", "-i", "in.wav", "out.au" }, .ignore, null));
    try h.expectContent("-y replaces an existing output", "out.au", au_out);
    // FFmpeg's extension is the text after the name's last dot, so a file
    // named only `.au` is AU output (av_match_ext's strrchr).
    h.expectSuccess("an output named only by its extension", try h.run(&.{ "-i", "in.wav", ".au" }, .ignore, null));
    try h.expectContent("an output named only by its extension", ".au", au_out);
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

    // A failure after the output file was created removes it when this run
    // created it; what -y replaced keeps the partial output, as FFmpeg's.
    {
        const case = "a late failure removes the partial output";
        h.expect(case, try h.run(&.{ "-i", "late.wav", "new.au" }, .ignore, null), 2, "late.wav: InvalidWave");
        h.expectAbsent(case, "new.au");
        const kept = "a late failure keeps what -y replaced";
        try h.write("out.au", previous);
        const outcome = try h.run(&.{ "-y", "-i", "late.wav", "out.au" }, .ignore, null);
        h.expect(kept, outcome, 2, "late.wav: InvalidWave");
        h.expectLacking(kept, outcome, "cannot remove");
        try h.expectReplaced(kept, "out.au", previous);
    }
    // A symbolic link replaced with -y stays a link, its target written
    // through it (POSIX only: Windows needs a privilege to create one).
    if (builtin.os.tag != .windows) {
        const case = "a late failure keeps a linked output";
        try h.write("target.au", previous);
        try dir.symLink(io, "target.au", "link.au", .{});
        h.expect(case, try h.run(&.{ "-y", "-i", "late.wav", "link.au" }, .ignore, null), 2, "late.wav: InvalidWave");
        if (dir.statFile(io, "link.au", .{ .follow_symlinks = false })) |stat| {
            if (stat.kind != .sym_link) h.fail(case, "link.au is now a {t}", .{stat.kind});
        } else |err| h.fail(case, "link.au: {t}", .{err});
        try h.expectReplaced(case, "target.au", previous);
    }
    // A pipe named as the output, Linux's /dev/stdout here (the only name
    // of one that needs no system call to make): FLAC keeps its first
    // STREAMINFO there, as on standard output and as FFmpeg, which only
    // warns that it cannot rewrite it (M13); a failure removes nothing
    // that was there (M14).
    if (builtin.os.tag == .linux) {
        try writeLongWav(io, dir, "pipe.wav");
        const case = "FLAC into a named pipe";
        const named = try h.runCapture(&.{ "-y", "-i", "pipe.wav", "-f", "flac", "/dev/stdout" });
        h.expectSuccess(case, named.outcome);
        h.expectSuccess(case, try h.run(&.{ "-i", "pipe.wav", "-f", "flac", "-" }, .ignore, null));
        const stdout = try dir.readFileAlloc(io, "stdout.bin", h.gpa, .limited(1 << 22));
        defer h.gpa.free(stdout);
        // Equal bytes say nothing when both are empty.
        if (!std.mem.startsWith(u8, stdout, "fLaC")) h.fail(case, "standard output is not FLAC", .{});
        if (!std.mem.eql(u8, named.stdout, stdout)) h.fail(case, "the pipe got other bytes than standard output", .{});
        h.gpa.free(named.stdout);
        const failed = "a late failure into a named pipe removes nothing";
        const late_pipe = try h.runCapture(&.{ "-y", "-i", "late.wav", "-f", "au", "/dev/stdout" });
        h.gpa.free(late_pipe.stdout);
        h.expect(failed, late_pipe.outcome, 2, "late.wav: InvalidWave");
        h.expectLacking(failed, late_pipe.outcome, "cannot remove");
    }
    // A header declaring 2^32 - 256 bytes of data in a 144-byte file, with
    // a rate change: the output's frame count comes at once (H4), and the
    // missing data is the late failure it is without -ar.
    {
        const case = "a huge declared length resampled";
        try h.write("huge.wav", &hugeDeclaredWav());
        h.expect(case, try h.run(&.{ "-i", "huge.wav", "-ar", "48000", "huge-out.wav" }, .ignore, null), 2, "huge.wav: Truncated");
        h.expectAbsent(case, "huge-out.wav");
    }
    // Refusals that depend only on the request come before the output is
    // created (M15): an output in a missing directory is never opened.
    {
        const case = "a resampler refusal before the output";
        // 1 Hz 8-bit in AIFF's 4 KiB packets to 100 kHz: a call's room
        // past the buffers.
        try writeAiff(io, dir, "rate1.aiff", .s8, 1, 8192);
        h.expect(case, try h.run(&.{ "-y", "-i", "rate1.aiff", "-ar", "100000", "-c:a", "pcm_s32le", "missing" ++ std.fs.path.sep_str ++ "o.wav" }, .ignore, null), 3, "rate1.aiff: UnsupportedFormat");
        // 100 Hz in packets of 2048 to 48 kHz: a first output past FLAC's
        // block sizes, which FFmpeg's encoder refuses too.
        try writeAiff(io, dir, "r100.aiff", .s16be, 100, 2000);
        h.expect(case, try h.run(&.{ "-y", "-i", "r100.aiff", "-ar", "48000", "missing" ++ std.fs.path.sep_str ++ "o.flac" }, .ignore, null), 3, "r100.aiff: UnsupportedFormat");
    }

    // Standard streams: a pipe-free round trip, then read and write failures.
    {
        const case = "standard input to standard output";
        const stdin = try dir.openFile(io, "in.wav", .{});
        defer stdin.close(io);
        h.expectSuccess(case, try h.run(&.{ "-i", "-", "-f", "au", "-" }, .{ .file = stdin }, null));
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

    // Raw PCM (T22c): a pipe gives no length for a header's sizes, a file
    // does, and a raw extension names the input format.
    {
        var raw_buffer: [64]u8 = undefined;
        const raw_alaw = try fixture_dir.readFile(io, "raw" ++ std.fs.path.sep_str ++ "raw_alaw_mono_8k.raw", &raw_buffer);
        const case = "raw PCM through a pipe has no length for a header";
        h.expect(case, try h.runPiped(&.{ "-f", "alaw", "-i", "-", "-f", "wav", "-" }, raw_alaw), 3, "zffmpeg: -: UnsupportedStreamingSize");
        const piped = "raw PCM through a pipe to raw PCM";
        h.expectSuccess(piped, try h.runPiped(&.{ "-f", "alaw", "-i", "-", "-c", "copy", "-f", "alaw", "-" }, raw_alaw));
        try h.expectContent(piped, "stdout.bin", raw_alaw);
        try h.write("take.al", raw_alaw);
        const named = "a raw extension names the input format";
        h.expectSuccess(named, try h.run(&.{ "-i", "take.al", "-c", "copy", "-f", "alaw", "-" }, .ignore, null));
        try h.expectContent(named, "stdout.bin", raw_alaw);
        h.expectSuccess(named, try h.run(&.{ "-i", "take.al", "-c", "copy", "take.wav" }, .ignore, null));
        // The copy holds the A-law samples, one byte per mono frame.
        const file = try dir.openFile(io, "take.wav", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        if (av.wav.probe(&reader.interface, .{})) |info| {
            if (info.codec != .alaw or info.format.channelCount() != 1 or info.frame_count != raw_alaw.len) {
                h.fail(named, "take.wav holds {t}, {d} channels, {?d} frames", .{ info.codec, info.format.channelCount(), info.frame_count });
            }
        } else |err| h.fail(named, "take.wav: {t}", .{err});
    }

    // Ogg FLAC whose second frame changes the rate is refused, as native
    // FLAC is, not converted with every sample at the first rate: into a
    // file (at the second frame, the header rewritten at the end being
    // never reached: the partial output removed) and through a pipe.
    {
        const case = "an Ogg FLAC rate change is refused";
        const native = try fixture_dir.readFileAlloc(io, "flac" ++ std.fs.path.sep_str ++ "flac_rate_change.flac", h.gpa, .limited(1 << 16));
        defer h.gpa.free(native);
        const ogg = try oggFromFlac(h.gpa, native);
        defer h.gpa.free(ogg);
        try h.write("rate.ogg", ogg);
        h.expect(case, try h.run(&.{ "-i", "rate.ogg", "rate.wav" }, .ignore, null), 3, "rate.ogg: UnsupportedFormat");
        h.expectAbsent(case, "rate.wav");
        const piped = "an Ogg FLAC rate change through a pipe is refused";
        h.expect(piped, try h.runPiped(&.{ "-i", "-", "-f", "s16le", "-" }, ogg), 3, "zffmpeg: -: UnsupportedFormat");
    }

    // A decoded input from a pipe into a WAV file: no count ahead, the
    // header rewritten at the end, the same bytes as from the file (a stream
    // without gapless trimming, which a pipe would lose).
    {
        const case = "an MP3 stream from a pipe into a WAV file";
        const mp3 = try fixture_dir.readFileAlloc(io, "mp3" ++ std.fs.path.sep_str ++ "mp3_l3_long_stereo.mp3", h.gpa, .limited(1 << 16));
        defer h.gpa.free(mp3);
        try h.write("long.mp3", mp3);
        h.expectSuccess(case, try h.run(&.{ "-y", "-i", "long.mp3", "file.wav" }, .ignore, null));
        h.expectSuccess(case, try h.runPiped(&.{ "-y", "-i", "-", "pipe.wav" }, mp3));
        const from_file = try dir.readFileAlloc(io, "file.wav", h.gpa, .limited(1 << 20));
        defer h.gpa.free(from_file);
        const from_pipe = try dir.readFileAlloc(io, "pipe.wav", h.gpa, .limited(1 << 20));
        defer h.gpa.free(from_pipe);
        // 27648 stereo s16 frames after the 44-byte header.
        if (from_file.len != 44 + 27648 * 4 or !std.mem.eql(u8, from_file, from_pipe)) {
            h.fail(case, "file.wav ({d} bytes) and pipe.wav ({d} bytes) differ", .{ from_file.len, from_pipe.len });
        }
    }

    // Raw parameters refused after probing grew its buffer past the first
    // 2048 bytes: a leading ID3v2 tag declaring a 10000-byte body keeps the
    // scores low until the extension chooses MP3. Debug's allocator logs a
    // leak of the probe buffer to stderr at exit.
    {
        const case = "raw parameters refused after a long probe";
        var tagged: [5000]u8 = @splat(0);
        @memcpy(tagged[0..10], &[_]u8{ 'I', 'D', '3', 4, 0, 0, 0, 0, 78, 16 });
        try h.write("tagged.mp3", &tagged);
        const outcome = try h.run(&.{ "-ar", "8000", "-i", "tagged.mp3", "-f", "wav", "-" }, .ignore, null);
        h.expect(case, outcome, 1, "zffmpeg: tagged.mp3: -sample_rate and -ch_layout apply only to raw PCM input\n");
        h.expectLacking(case, outcome, "leaked");
    }

    // A long stream converts through files with exact frame counts.
    {
        const case = "a long stream converts";
        h.expectSuccess(case, try h.run(&.{ "-i", "long.wav", "long.au" }, .ignore, null));
        const file = try dir.openFile(io, "long.au", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const info = try av.au.probe(&reader.interface, .{});
        if (info.frame_count != long_frames) h.fail(case, "{?d} frames", .{info.frame_count});
    }

    return if (h.failures == 0) 0 else 1;
}

const long_frames = 1 << 16;

/// The review's 144-byte WAV (H4): 8 kHz mono u8 whose `data` chunk
/// declares 2^32 - 256 bytes, with 100 of them present.
fn hugeDeclaredWav() [144]u8 {
    var bytes: [144]u8 = @splat(0x80);
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 0xFFFF_FF24, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, bytes[22..24], 1, .little); // mono
    std.mem.writeInt(u32, bytes[24..28], 8000, .little);
    std.mem.writeInt(u32, bytes[28..32], 8000, .little);
    std.mem.writeInt(u16, bytes[32..34], 1, .little);
    std.mem.writeInt(u16, bytes[34..36], 8, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], 0xFFFF_FF00, .little);
    return bytes;
}

/// A native FLAC file's packets remuxed into Ogg, owned by the caller.
fn oggFromFlac(gpa: std.mem.Allocator, flac_bytes: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(flac_bytes);
    var d = try av.flac.Demuxer.init(gpa, &reader);
    defer d.deinit();
    const streaminfo = d.info.extradata orelse return error.NoStreamInfo;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var mux = try av.oggmux.Muxer.init(gpa, &out.writer, &.{.{ .codec = .flac, .sample_rate = d.info.sample_rate, .extradata = &streaminfo }}, .{});
    defer mux.deinit();
    try mux.writeHeader();
    var pts: i64 = 0;
    while (try d.next()) |p| {
        const duration = p.duration orelse 0;
        try mux.writePacket(0, p.data, pts, duration);
        pts += duration;
    }
    try mux.finish();
    return out.toOwnedSlice();
}

/// A mono AIFF of `frames` silent frames of `codec` at `rate`.
fn writeAiff(io: std.Io, dir: std.Io.Dir, path: []const u8, codec: av.pcm.Codec, rate: u32, frames: u32) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buffer);
    const format = try av.audio.Format.init(rate, 1, codec.storage());
    var writer = try av.aiff.Writer.begin(&file_writer.interface, codec, format, frames, .{});
    const zero: [2]u8 = @splat(0);
    for (0..frames) |_| try writer.writeData(zero[0..codec.bytesPerSample()]);
    try writer.finish();
}

/// 256 KiB of stereo samples: larger than zffmpeg's 64 KiB output buffer.
fn writeLongWav(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writerStreaming(io, &buffer);
    const stereo = try av.audio.Format.init(48000, 2, .s16);
    var writer = try av.wav.Writer.begin(&file_writer.interface, .s16le, stereo, long_frames, .{});
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
