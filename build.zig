// SPDX-License-Identifier: LGPL-2.1-or-later
// Original build script for this project.
//! Build graph for the native Zig port: one package and one `av` library module.
//! Commands and the exact-version policy are documented in zig/README.md.

const std = @import("std");
const builtin = @import("builtin");

/// The only compiler version this project is tested with. Keep it equal to
/// `.minimum_zig_version` in build.zig.zon and to `.zig-version`; neither of
/// those rejects another compiler, so this check does.
const tested_zig_version = "0.17.0";

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, tested_zig_version)) {
        @compileError("zffmpeg is tested only with Zig " ++ tested_zig_version ++ "; this compiler is " ++ builtin.zig_version_string);
    }
}

const Example = struct {
    name: []const u8,
    path: []const u8,
};

/// Standalone examples, each tested as its own artifact. Register new examples
/// here explicitly; CI fails when a file in zig/examples/ is missing from this list.
const examples = [_]Example{
    .{ .name = "io_patterns", .path = "zig/examples/io_patterns.zig" },
};

/// The fixture directories: zig/testing/fixtures/wav/ and zig/testing/fixtures/au/.
const FixtureSet = enum { wav, au };

/// A zffprobe process run with its expected exit code and output.
const ProbeCase = struct {
    name: []const u8,
    /// Arguments placed before the fixture path, if any.
    args: []const []const u8 = &.{},
    /// Which fixture directory `fixture` and `stdin_fixture` name a file in.
    set: FixtureSet = .wav,
    /// Passed as the file argument: zig/testing/fixtures/<set>/<name>.<set>.
    fixture: ?[]const u8 = null,
    /// Piped to standard input instead (a non-seekable stream).
    stdin_fixture: ?[]const u8 = null,
    exit_code: u8,
    /// Exact stdout, unless `stdout_contains` is set.
    stdout: []const u8 = "",
    stdout_contains: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    stderr_contains: ?[]const u8 = null,
};

const usage_line = "usage: zffprobe <file.wav | file.au | ->\n";

const mono_8k_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const stereo_44k1_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=2
    \\channel_layout=stereo
    \\sample_rate=44100
    \\nb_samples=4
    \\duration_num=4
    \\duration_den=44100
    \\
;

const empty_data_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=0
    \\duration_num=0
    \\duration_den=8000
    \\
;

const au_mono_8k_report =
    \\format=au
    \\codec=pcm_s16be
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const au_stereo_44k1_report =
    \\format=au
    \\codec=pcm_s16be
    \\sample_fmt=s16
    \\channels=2
    \\channel_layout=stereo
    \\sample_rate=44100
    \\nb_samples=4
    \\duration_num=4
    \\duration_den=44100
    \\
;

const au_empty_data_report =
    \\format=au
    \\codec=pcm_s16be
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=0
    \\duration_num=0
    \\duration_den=8000
    \\
;

/// T09: valid, empty, malformed, unsupported, I/O, resource-limit and usage
/// cases, each checking stdout, stderr and the exit status. T12c adds the same
/// for AU, including a pipe, and a non-AU magic that detection sends to WAV.
const probe_cases = [_]ProbeCase{
    .{ .name = "valid mono file", .fixture = "mono_8k", .exit_code = 0, .stdout = mono_8k_report, .stderr = "" },
    .{ .name = "valid stereo from a pipe", .args = &.{"-"}, .stdin_fixture = "stereo_44k1", .exit_code = 0, .stdout = stereo_44k1_report, .stderr = "" },
    .{ .name = "empty data", .fixture = "empty_data", .exit_code = 0, .stdout = empty_data_report, .stderr = "" },
    .{ .name = "empty input", .fixture = "empty_input", .exit_code = 2, .stderr_contains = ": Truncated\n" },
    .{ .name = "malformed header", .fixture = "not_riff", .exit_code = 2, .stderr_contains = ": InvalidRiff\n" },
    .{ .name = "error after the data", .fixture = "duplicate_data", .exit_code = 2, .stderr_contains = ": InvalidWave\n" },
    .{ .name = "truncated pipe", .args = &.{"-"}, .stdin_fixture = "truncated_data", .exit_code = 2, .stderr = "zffprobe: -: Truncated\n" },
    .{ .name = "unsupported container", .fixture = "rifx_big_endian", .exit_code = 3, .stderr_contains = ": UnsupportedFormat\n" },
    .{ .name = "unknown size", .fixture = "riff_size_unknown", .exit_code = 3, .stderr_contains = ": UnsupportedStreamingSize\n" },
    .{ .name = "chunk limit", .fixture = "chunks_over_limit", .exit_code = 5, .stderr_contains = ": LimitExceeded\n" },
    .{ .name = "missing file", .args = &.{"no-such-file.wav"}, .exit_code = 4, .stderr = "zffprobe: no-such-file.wav: FileNotFound\n" },
    .{ .name = "directory", .args = &.{"zig"}, .exit_code = 4, .stderr = "zffprobe: zig: IsDir\n" },
    .{ .name = "no arguments", .exit_code = 1, .stderr = usage_line },
    .{ .name = "too many arguments", .args = &.{ "a.wav", "b.wav" }, .exit_code = 1, .stderr = usage_line },
    .{ .name = "help", .args = &.{"--help"}, .exit_code = 0, .stdout_contains = usage_line, .stderr = "" },
    .{ .name = "valid AU file", .set = .au, .fixture = "au_mono_8k", .exit_code = 0, .stdout = au_mono_8k_report, .stderr = "" },
    .{ .name = "valid AU from a pipe", .set = .au, .args = &.{"-"}, .stdin_fixture = "au_stereo_44k1", .exit_code = 0, .stdout = au_stereo_44k1_report, .stderr = "" },
    .{ .name = "empty AU data", .set = .au, .fixture = "au_empty_data", .exit_code = 0, .stdout = au_empty_data_report, .stderr = "" },
    .{ .name = "malformed AU header", .set = .au, .fixture = "au_offset_too_small", .exit_code = 2, .stderr_contains = ": InvalidAu\n" },
    .{ .name = "non-AU magic goes to WAV", .set = .au, .fixture = "au_bad_magic", .exit_code = 2, .stderr_contains = ": InvalidRiff\n" },
    .{ .name = "unsupported AU encoding", .set = .au, .fixture = "au_encoding_mulaw", .exit_code = 3, .stderr_contains = ": UnsupportedFormat\n" },
    .{ .name = "unknown AU size", .set = .au, .fixture = "au_unknown_size", .exit_code = 3, .stderr_contains = ": UnsupportedStreamingSize\n" },
    .{ .name = "AU rate limit", .set = .au, .fixture = "au_rate_over_limit", .exit_code = 5, .stderr_contains = ": LimitExceeded\n" },
    .{ .name = "truncated AU pipe", .set = .au, .args = &.{"-"}, .stdin_fixture = "au_truncated_data", .exit_code = 2, .stderr = "zffprobe: -: Truncated\n" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose names contain this text (repeatable)",
    ) orelse &.{};

    const av = b.addModule("av", .{
        .root_source_file = b.path("zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The default install step compiles a real artifact. Registering the module
    // alone would let `zig build` succeed without compiling anything.
    const lib = b.addLibrary(.{
        .name = "zffmpeg",
        .root_module = av,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run the av module, example and zffprobe tests");

    const av_tests = b.addTest(.{
        .name = "av",
        .root_module = av,
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(av_tests).step);

    for (examples) |example| {
        const example_tests = b.addTest(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }

    const probe = b.addExecutable(.{
        .name = "zffprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/cli/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "av", .module = av }},
        }),
    });
    b.installArtifact(probe);

    const run_probe = b.addRunArtifact(probe);
    run_probe.addPassthruArgs();
    b.step("probe", "Run zffprobe; pass its arguments after --").dependOn(&run_probe.step);

    // zffprobe runs as a separate process, so its output never mixes with the
    // test runner's protocol. A -Dtest-filter run skips these process checks.
    if (test_filters.len == 0) {
        for (probe_cases) |case| addProbeCase(b, test_step, probe, case);
    }

    // Test tools for the FFmpeg comparison (zig/testing/reference/compare.py),
    // kept out of the default install. `zig build test-tools` installs them in
    // zig-out/bin; `zig build test` compiles them, so a break shows in every mode.
    const write_driver = b.addExecutable(.{
        .name = "write-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/testing/write_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "av", .module = av }},
        }),
    });
    const test_tools = b.step("test-tools", "Install the test tools that compare.py runs");
    test_tools.dependOn(&b.addInstallArtifact(write_driver, .{}).step);
    test_step.dependOn(&write_driver.step);
}

fn addProbeCase(b: *std.Build, test_step: *std.Build.Step, probe: *std.Build.Step.Compile, case: ProbeCase) void {
    const run = b.addRunArtifact(probe);
    run.setName(b.fmt("zffprobe: {s}", .{case.name}));
    run.setCwd(b.path("."));
    run.addArgs(case.args);
    if (case.fixture) |name| run.addFileArg(fixturePath(b, case.set, name));
    if (case.stdin_fixture) |name| run.setStdIn(.{ .lazy_path = fixturePath(b, case.set, name) });
    run.expectExitCode(case.exit_code);
    if (case.stdout_contains) |text| run.expectStdOutMatch(text) else run.expectStdOutEqual(case.stdout);
    if (case.stderr) |text| run.expectStdErrEqual(text);
    if (case.stderr_contains) |text| run.expectStdErrMatch(text);
    test_step.dependOn(&run.step);
}

fn fixturePath(b: *std.Build, set: FixtureSet, name: []const u8) std.Build.LazyPath {
    return b.path(b.fmt("zig/testing/fixtures/{t}/{s}.{t}", .{ set, name, set }));
}
