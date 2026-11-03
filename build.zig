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

    const test_step = b.step("test", "Run the av module and example tests");

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
}
