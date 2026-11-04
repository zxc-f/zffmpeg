// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/format.c (probe_input_format_internal, av_probe_input_buffer2),
// wavdec.c, au.c, aiffdec.c, cafdec.c and flacdec.c at the pinned reference
// revision describe the scoring followed here.
//! Format detection (TODO.md T12c, T16): the content probes of the demuxers
//! in the format registry (`registry.zig`), scored as FFmpeg scores them, so
//! each stream gets FFmpeg's winner.
//!
//! `Input.open` reads up to `probe_len` bytes, FFmpeg's first probe size, and
//! asks every demuxer for a score from 0 to 100. The highest nonzero score
//! wins; a tie at the highest means no winner, as in FFmpeg, and a stream no
//! demuxer scores is `UnknownFormat`. The bytes probing read are served again
//! to the chosen parser through a `Replay` reader, so non-seekable input
//! loses nothing and any source buffer size works. A caller can force a
//! format instead (`ffprobe -f`), which skips probing.
//!
//! FFmpeg reads more and probes again while the best score is at most 25
//! (`AVPROBE_SCORE_RETRY`), accepting a low score only at the end of the
//! input or of its largest probe buffer. Every registered probe reads a
//! fixed number of bytes within the first `probe_len`, which this file
//! checks at compile time, so the later rounds score every demuxer exactly
//! as the first: the loop can delay a low-scoring winner, such as raw
//! FLAC's 13 (T26a), but never change it. A probe that looks further must
//! add the loop. A demuxer without a probe (a format without a content
//! signature) is never chosen by content.
//!
//! A file name, when the caller has one, adds FFmpeg's extension hints
//! (`av_match_ext`): a demuxer without a probe whose extension matches scores
//! 50 (`AVPROBE_SCORE_EXTENSION`), so the raw PCM formats (T22c) are chosen
//! by name only when no content probe recognizes the stream, and a probing
//! demuxer's match scores at least 1 (FLAC's `flac`). MIME types (HTTP only)
//! and FFmpeg's skipping of a leading ID3v2 tag are not ported.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const metadata = @import("../core/metadata.zig");
const wav = @import("wav.zig");
const au = @import("au.zig");
const aiff = @import("aiff.zig");
const raw = @import("raw.zig");
const caf = @import("caf.zig");
const flac = @import("flac.zig");
const codecs = @import("../codec/registry.zig");
const registry = @import("registry.zig");
const Replay = @import("replay.zig").Replay;

pub const Container = registry.Container;

/// The WAV, AU, AIFF, raw PCM, CAF and FLAC contract errors, which share
/// their common names, `UnknownFormat` for a stream no demuxer recognizes,
/// and `UnusedOption`.
pub const Error = wav.Error || au.Error || aiff.Error || raw.Error || caf.Error || flac.Error || error{
    /// No demuxer's probe scored the stream, as FFmpeg's "Invalid data found
    /// when processing input"; force a format to parse it anyway.
    UnknownFormat,
    /// Raw PCM parameters were given for an input whose format has its own.
    UnusedOption,
};

pub const Limits = struct {
    wav: wav.Limits = .{},
    au: au.Limits = .{},
    aiff: aiff.Limits = .{},
    caf: caf.Limits = .{},
    raw: raw.Limits = .{},
};

/// What the caller knows about an input besides its bytes.
pub const Source = struct {
    /// Parse as this container instead of probing (`-f`).
    format: ?Container = null,
    /// The input's file name, for the demuxers' extension hints; null for
    /// standard input, which FFmpeg names without an extension too.
    file_name: ?[]const u8 = null,
    /// The input's length in bytes, when known (a regular file's size): raw
    /// PCM has no header to give its frame count before the samples.
    length: ?u64 = null,
    /// Raw PCM stream parameters (`-sample_rate`, `-ch_layout`); null takes
    /// FFmpeg's defaults. Given for any other format, `UnusedOption`.
    raw: ?raw.Params = null,
};

/// FFmpeg's first probe size (`PROBE_BUF_MIN`).
pub const probe_len = 2048;

/// `AVPROBE_SCORE_MAX`.
const max_score = 100;
/// `AVPROBE_SCORE_EXTENSION`: a probe-less demuxer whose extension matches.
const extension_score = 50;

comptime {
    for (registry.formats) |format| {
        const demuxer = format.demuxer orelse continue;
        if (demuxer.probe_bytes > probe_len) @compileError("a probe reads past the probe buffer: " ++ format.name);
    }
}

/// FFmpeg's winner for `head`, the first bytes of a stream named `file_name`
/// (null when it has no name): the demuxer with the highest nonzero score, or
/// none when no demuxer scores or the highest score is tied.
pub fn probeHead(head: []const u8, file_name: ?[]const u8) ?Container {
    return winner(&registry.formats, head[0..@min(head.len, probe_len)], file_name);
}

/// The winner among `formats`, scored as `av_probe_input_format3` scores
/// them. FFmpeg's order only matters for ties, which mean no winner whatever
/// the order.
fn winner(formats: []const registry.Format, head: []const u8, file_name: ?[]const u8) ?Container {
    var best: u8 = 0;
    var chosen: ?Container = null;
    for (formats) |format| {
        const demuxer = format.demuxer orelse continue;
        const named = if (file_name) |name| registry.matchesExtension(name, demuxer.extensions) else false;
        const score: u8 = if (demuxer.probe) |score_head| score: {
            const content = score_head(head);
            break :score if (named) @max(content, 1) else content;
        } else if (named) extension_score else 0;
        std.debug.assert(score <= max_score);
        if (score > best) {
            best = score;
            chosen = format.container;
        } else if (score == best) {
            chosen = null;
        }
    }
    return chosen;
}

/// A stream opened for parsing: its format, and a reader that replays the
/// bytes probing read before the rest of the source.
pub const Input = struct {
    head_buffer: [probe_len]u8,
    replay: Replay,
    container: Container,
    /// The container came from the caller, not from probing.
    forced: bool,
    source: Source,

    /// Probes `reader`, or with `source.format` takes that format without
    /// reading anything. Fills `input` in place; it must not move afterward,
    /// because `reader` points into it. Only a failing reader, a stream no
    /// demuxer recognizes, or raw parameters for another format are errors.
    pub fn open(input: *Input, reader_in: *std.Io.Reader, source: Source) error{ IoFailure, UnknownFormat, UnusedOption }!void {
        if (source.format) |container| {
            input.* = .{
                .head_buffer = undefined,
                .replay = .init(&.{}, reader_in),
                .container = container,
                .forced = true,
                .source = source,
            };
        } else {
            const len = reader_in.readSliceShort(&input.head_buffer) catch return error.IoFailure;
            input.replay = .init(input.head_buffer[0..len], reader_in);
            input.container = probeHead(input.head_buffer[0..len], source.file_name) orelse return error.UnknownFormat;
            input.forced = false;
            input.source = source;
        }
        if (source.raw != null and input.container.family() != .raw) return error.UnusedOption;
    }

    pub fn reader(input: *Input) *std.Io.Reader {
        return &input.replay.interface;
    }

    /// A WAV parser for a `wav` or `w64` input, which accepts only that
    /// variant, as FFmpeg's demuxers do when forced.
    pub fn wavParser(input: *Input, limits: wav.Limits) wav.Parser {
        const variant: wav.Variant = switch (input.container) {
            .wav => .wav,
            .w64 => .w64,
            else => unreachable, // the caller dispatches on the family
        };
        return .initVariant(input.reader(), limits, variant);
    }

    /// A raw PCM parser for a raw input, with the source's parameters and
    /// length.
    pub fn rawParser(input: *Input, limits: raw.Limits) raw.Parser {
        const codec = input.container.rawCodec() orelse unreachable; // the caller dispatches on the family
        return .init(input.reader(), codec, input.source.raw orelse .{}, input.source.length, limits);
    }
};

pub const Probed = struct {
    container: Container,
    /// The stream's codec, as FFmpeg's `codec_name` names it.
    codec: codecs.Codec,
    /// `sample_format` is the decoded storage: a PCM codec's `storage()`,
    /// s16 for 16-bit FLAC.
    format: audio.Format,
    /// Sample frames in the stream; null for data of unknown length
    /// (`unknown_length`). Raw PCM is counted while validating.
    frame_count: ?u64,
};

pub const Options = struct {
    /// The format, file name, length and raw parameters the caller knows.
    source: Source = .{},
    /// Also add the stream's tags to the empty `tags.dictionary`, under
    /// FFmpeg's names (`wav.genericTags`): RIFF and RF64's INFO and `bext`,
    /// and FLAC's VORBIS_COMMENT (T26b). On failure the dictionary may hold
    /// some of them.
    tags: ?wav.Tags = null,
};

/// Detects the container, then validates the whole stream without decoding
/// its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Probed {
    return probeWith(reader, limits, .{});
}

/// `probe`, with what the caller knows about the source, or tags.
pub fn probeWith(reader: *std.Io.Reader, limits: Limits, options: Options) Error!Probed {
    var input: Input = undefined;
    try input.open(reader, options.source);
    switch (input.container.family()) {
        .wav => {
            var parser = input.wavParser(limits.wav);
            var stored: metadata.Dictionary = .empty;
            defer if (options.tags) |t| stored.deinit(t.gpa);
            if (options.tags) |t| {
                std.debug.assert(t.dictionary.count() == 0);
                parser.collectTags(.{ .gpa = t.gpa, .dictionary = &stored });
            }
            const info = try parser.readHeader();
            try parser.finish();
            if (options.tags) |t| {
                const generic = try wav.genericTags(t.gpa, &stored);
                t.dictionary.deinit(t.gpa);
                t.dictionary.* = generic;
            }
            std.debug.assert(Container.ofWav(info.variant) == input.container);
            return .{ .container = input.container, .codec = .{ .pcm = info.codec }, .format = info.format, .frame_count = info.frame_count };
        },
        .au => {
            var parser: au.Parser = .init(input.reader(), limits.au);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .au, .codec = .{ .pcm = info.codec }, .format = info.format, .frame_count = info.frame_count };
        },
        .aiff => {
            var parser: aiff.Parser = .init(input.reader(), limits.aiff);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .aiff, .codec = .{ .pcm = info.codec }, .format = info.format, .frame_count = info.frame_count };
        },
        .caf => {
            var parser: caf.Parser = .init(input.reader(), limits.caf);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .caf, .codec = .{ .pcm = info.codec }, .format = info.format, .frame_count = info.frame_count };
        },
        .raw => {
            var parser = input.rawParser(limits.raw);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = input.container, .codec = .{ .pcm = info.codec }, .format = info.format, .frame_count = parser.frames_read };
        },
        .flac => {
            // The frames are the decoder's to check; FFmpeg's probe reads
            // the header, and the duration comes from STREAMINFO. Tags come
            // from VORBIS_COMMENT (T26b).
            var info = if (options.tags) |t| try flac.readHeaderAlloc(input.reader(), t.gpa) else try flac.readHeader(input.reader());
            const probed: Probed = .{
                .container = .flac,
                .codec = .flac,
                .format = flacFormat(info) catch |err| {
                    if (options.tags) |t| info.deinit(t.gpa);
                    return err;
                },
                .frame_count = info.duration,
            };
            if (options.tags) |t| {
                std.debug.assert(t.dictionary.count() == 0);
                t.dictionary.deinit(t.gpa);
                t.dictionary.* = info.tags;
                info.tags = .empty;
                info.deinit(t.gpa);
            }
            return probed;
        },
    }
}

/// The decoded stream of a FLAC input: packed s16 or s32 in FFmpeg's
/// layout; a rate neither STREAMINFO nor the first frame gives is
/// `UnsupportedFormat`.
pub fn flacFormat(info: flac.Info) error{UnsupportedFormat}!audio.Format {
    return audio.Format.initLayout(info.sample_rate, info.layout, info.sampleFormat()) catch error.UnsupportedFormat;
}

const fixtures = @import("../testing/fixtures.zig");

/// The implementation's container for a manifest's.
fn containerOf(comptime container: fixtures.Container) Container {
    return comptime std.meta.stringToEnum(Container, @tagName(container)).?;
}

/// Compares a probe through detection with one container parser's own probe.
fn expectSameResult(expected: anytype, got: Error!Probed, container: Container) !void {
    if (expected) |info| {
        const probed = try got;
        try std.testing.expectEqual(container, probed.container);
        try std.testing.expectEqual(info.format, probed.format);
        try std.testing.expectEqual(info.frame_count, probed.frame_count);
    } else |want| {
        try std.testing.expectError(want, got);
    }
}

/// Probes one fixture through detection from one-byte reads: a fixture the
/// manifest records as undetected is `UnknownFormat`; any other gives its
/// container's parser result, and forcing that container gives the same.
fn expectDetection(comptime detected: ?fixtures.Container, bytes: []const u8, direct: anytype) !void {
    var buffer: [1]u8 = undefined;
    var source: std.testing.Reader = .init(&buffer, &.{.{ .buffer = bytes }});
    source.artificial_limit = .limited(1);
    const got = probe(&source.interface, .{});
    if (detected == null) return std.testing.expectError(error.UnknownFormat, got);
    // Not null: checked just above.
    const container = comptime containerOf(detected.?);
    try expectSameResult(direct, got, container);
    var forced: std.Io.Reader = .fixed(bytes);
    try expectSameResult(direct, probeWith(&forced, .{}, .{ .source = .{ .format = container } }), container);
}

test "detection gives every WAV fixture FFmpeg's winner and then the parser's result" {
    inline for (fixtures.all) |fixture| {
        const bytes = fixtures.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, wav.probe(&direct, .{})) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "detection gives every AU fixture FFmpeg's winner and then the parser's result" {
    inline for (fixtures.au.all) |fixture| {
        const bytes = fixtures.au.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, au.probe(&direct, .{})) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "detection gives every AIFF fixture FFmpeg's winner and then the parser's result" {
    inline for (fixtures.aiff.all) |fixture| {
        const bytes = fixtures.aiff.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, aiff.probe(&direct, .{})) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "detection gives every CAF fixture FFmpeg's winner and then the parser's result" {
    inline for (fixtures.caf.all) |fixture| {
        const bytes = fixtures.caf.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, caf.probe(&direct, .{})) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

/// A FLAC header read directly, as `expectSameResult` compares it.
fn flacProbe(reader: *std.Io.Reader) Error!struct { format: audio.Format, frame_count: ?u64 } {
    const info = try flac.readHeader(reader);
    return .{ .format = try flacFormat(info), .frame_count = info.duration };
}

test "detection gives every FLAC fixture FFmpeg's winner and then the demuxer's header" {
    inline for (fixtures.flac.all) |fixture| {
        const bytes = fixtures.flac.bytes(fixture.name);
        var direct: std.Io.Reader = .fixed(bytes);
        expectDetection(fixture.detected, bytes, flacProbe(&direct)) catch |err| {
            std.debug.print("fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "raw fixtures are found by no content probe, by their extension, and read when forced" {
    @setEvalBranchQuota(10_000);
    inline for (fixtures.raw.all) |fixture| {
        const bytes = fixtures.raw.bytes(fixture.name);
        const container = @field(Container, @tagName(fixture.format));
        try std.testing.expectEqual(null, probeHead(bytes, null));
        try std.testing.expectEqual(null, probeHead(bytes, fixture.name ++ ".raw"));
        // Named with the format's extension, if it has one, the format is chosen.
        const extensions = container.format().demuxer.?.extensions; // every raw format has a demuxer
        if (extensions.len > 0) {
            var name_buffer: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "take.{s}", .{extensions[0]});
            try std.testing.expectEqual(container, probeHead(bytes, name));
        }
        const params: ?raw.Params = if (fixture.params) |p| .{
            .sample_rate = p.sample_rate,
            // The manifest's texts parse; checked at compile time.
            .layout = comptime audio.ChannelLayout.parse(p.layout) catch unreachable,
        } else null;
        var forced: std.Io.Reader = .fixed(bytes);
        const got = probeWith(&forced, .{}, .{ .source = .{ .format = container, .raw = params } });
        switch (fixture.expected) {
            .accept => |stream| {
                const probed = try got;
                try std.testing.expectEqual(container, probed.container);
                try std.testing.expectEqual(stream.sample_rate, probed.format.sample_rate);
                try std.testing.expectEqual(stream.frameCount(), probed.frame_count);
            },
            .reject => try std.testing.expect(std.meta.isError(got)),
        }
    }
}

test "the probes need FFmpeg's minimum lengths and nonzero AU fields" {
    // A 33-byte RIFF/WAVE start is detected, 32 bytes are not.
    const wav_head = fixtures.bytes("mono_8k");
    try std.testing.expectEqual(Container.wav, probeHead(wav_head[0..33], null));
    try std.testing.expectEqual(null, probeHead(wav_head[0..32], null));
    // RF64 needs `ds64` at 12.
    var rf64 = fixtures.bytes("rf64")[0..40].*;
    try std.testing.expectEqual(Container.wav, probeHead(&rf64, null));
    rf64[12] = 'x';
    try std.testing.expectEqual(null, probeHead(&rf64, null));
    // Wave64: 41 bytes, not 40.
    const w64_head = fixtures.bytes("w64_mono_8k");
    try std.testing.expectEqual(Container.w64, probeHead(w64_head[0..41], null));
    try std.testing.expectEqual(null, probeHead(w64_head[0..40], null));
    // AU: 24 bytes; a zero data size is not detected.
    try std.testing.expectEqual(Container.au, probeHead(fixtures.au.bytes("au_mono_8k")[0..24], null));
    try std.testing.expectEqual(null, probeHead(fixtures.au.bytes("au_mono_8k")[0..23], null));
    try std.testing.expectEqual(null, probeHead(fixtures.au.bytes("au_empty_data"), null));
    // AIFF: 12 bytes, a FORM size of at least 4, and AIFF or AIFC.
    var aiff_head = fixtures.aiff.bytes("aifc_sowt")[0..12].*;
    try std.testing.expectEqual(Container.aiff, probeHead(&aiff_head, null));
    try std.testing.expectEqual(null, probeHead(aiff_head[0..11], null));
    std.mem.writeInt(u32, aiff_head[4..8], 3, .big);
    try std.testing.expectEqual(null, probeHead(&aiff_head, null));
    try std.testing.expectEqual(null, probeHead("", null));
}

fn alwaysProbe(head: []const u8) u8 {
    _ = head;
    return max_score;
}

test "a probe-less demuxer is chosen only by name, below every content probe" {
    const wav_bytes = fixtures.bytes("mono_8k");
    const undetected = fixtures.au.bytes("au_empty_data");
    // Without a name, or with another extension, raw PCM is never chosen.
    try std.testing.expectEqual(null, probeHead(undetected, null));
    try std.testing.expectEqual(null, probeHead(undetected, "take.raw"));
    // Named `.al`, content no probe recognizes is A-law (score 50) ...
    try std.testing.expectEqual(Container.alaw, probeHead(undetected, "take.al"));
    try std.testing.expectEqual(Container.alaw, probeHead("", "TAKE.AL"));
    try std.testing.expectEqual(Container.mulaw, probeHead(undetected, "take.ul"));
    // ... but a content probe's 99 or 100 wins.
    try std.testing.expectEqual(Container.wav, probeHead(wav_bytes, "take.al"));
    try std.testing.expectEqual(Container.au, probeHead(fixtures.au.bytes("au_mono_8k"), "take.ub"));
    // Two demuxers scoring 100 for the same bytes tie: no winner.
    const always: registry.Demuxer = .{ .probe = alwaysProbe, .probe_bytes = 0 };
    var both = [2]registry.Format{ Container.wav.format().*, Container.aiff.format().* };
    both[0].demuxer = always;
    both[1].demuxer = always;
    try std.testing.expectEqual(null, winner(&both, wav_bytes, null));
    // Two probe-less demuxers claiming one extension tie too.
    const twins = [2]registry.Format{ Container.alaw.format().*, Container.alaw.format().* };
    try std.testing.expectEqual(null, winner(&twins, undetected, "take.al"));
}

test "a raw input takes FFmpeg's defaults, the given parameters, and its length" {
    const bytes = [_]u8{ 0xD5, 0x55, 0xAA, 0x2A };
    var defaults: std.Io.Reader = .fixed(&bytes);
    const probed = try probeWith(&defaults, .{}, .{ .source = .{ .file_name = "take.al" } });
    try std.testing.expectEqual(Container.alaw, probed.container);
    try std.testing.expectEqual(44100, probed.format.sample_rate);
    try std.testing.expectEqual(audio.ChannelLayout.mono, probed.format.layout);
    try std.testing.expectEqual(4, probed.frame_count);
    var stereo: std.Io.Reader = .fixed(&bytes);
    const params: raw.Params = .{ .sample_rate = 8000, .layout = .stereo };
    const forced = try probeWith(&stereo, .{}, .{ .source = .{ .format = .s16le, .raw = params, .length = bytes.len } });
    try std.testing.expectEqual(1, forced.frame_count);
    try std.testing.expectEqual(8000, forced.format.sample_rate);
    // Raw parameters for a format with a header are refused.
    var wav_input: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.UnusedOption, probeWith(&wav_input, .{}, .{ .source = .{ .raw = params } }));
}

test "a forced format parses what probing would not detect, and only that format" {
    var empty_au: std.Io.Reader = .fixed(fixtures.au.bytes("au_empty_data"));
    try std.testing.expectError(error.UnknownFormat, probe(&empty_au, .{}));
    var forced_au: std.Io.Reader = .fixed(fixtures.au.bytes("au_empty_data"));
    try std.testing.expectEqual(0, (try probeWith(&forced_au, .{}, .{ .source = .{ .format = .au } })).frame_count);
    // Forced WAV rejects Wave64, and the other way round, as FFmpeg's demuxers do.
    var w64_as_wav: std.Io.Reader = .fixed(fixtures.bytes("w64_mono_8k"));
    try std.testing.expectError(error.InvalidRiff, probeWith(&w64_as_wav, .{}, .{ .source = .{ .format = .wav } }));
    var wav_as_w64: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.InvalidRiff, probeWith(&wav_as_w64, .{}, .{ .source = .{ .format = .w64 } }));
    var wav_as_au: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.InvalidAu, probeWith(&wav_as_au, .{}, .{ .source = .{ .format = .au } }));
    var au_as_aiff: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_8k"));
    try std.testing.expectError(error.InvalidAiff, probeWith(&au_as_aiff, .{}, .{ .source = .{ .format = .aiff } }));
    var small_form: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_form_size_small"));
    try std.testing.expectError(error.UnknownFormat, probe(&small_form, .{}));
}

test "detection reports the container and passes limits to its parser" {
    var mono: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_8k"));
    const probed = try probe(&mono, .{});
    try std.testing.expectEqual(Container.au, probed.container);
    try std.testing.expectEqualStrings("pcm_s16be", probed.codec.name());
    var fast: std.Io.Reader = .fixed(fixtures.au.bytes("au_mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&fast, .{ .au = .{ .max_sample_rate = 191_999 } }));
    var wav_fast: std.Io.Reader = .fixed(fixtures.bytes("mono_192k_rate_limit"));
    try std.testing.expectError(error.LimitExceeded, probe(&wav_fast, .{ .wav = .{ .max_sample_rate = 191_999 } }));
    var wave64: std.Io.Reader = .fixed(fixtures.bytes("w64_mono_8k"));
    try std.testing.expectEqual(Container.w64, (try probe(&wave64, .{})).container);
    var aifc: std.Io.Reader = .fixed(fixtures.aiff.bytes("aifc_fl32"));
    const probed_aifc = try probe(&aifc, .{});
    try std.testing.expectEqual(Container.aiff, probed_aifc.container);
    try std.testing.expectEqualStrings("pcm_f32be", probed_aifc.codec.name());
    var aiff_fast: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_mono_8k"));
    try std.testing.expectError(error.LimitExceeded, probe(&aiff_fast, .{ .aiff = .{ .max_sample_rate = 7999 } }));
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    const bytes = input[0..len];
    var detected: std.Io.Reader = .fixed(bytes);
    const got = probe(&detected, .{});
    // Replaying the probed bytes loses none: detection agrees with the
    // chosen parser reading the same input directly.
    var direct: std.Io.Reader = .fixed(bytes);
    if (probeHead(bytes, null)) |container| switch (container.family()) {
        .au => try expectSameResult(au.probe(&direct, .{}), got, .au),
        .aiff => try expectSameResult(aiff.probe(&direct, .{}), got, .aiff),
        .caf => try expectSameResult(caf.probe(&direct, .{}), got, .caf),
        .wav => try expectSameResult(wav.probe(&direct, .{}), got, container),
        .flac => try expectSameResult(flacProbe(&direct), got, .flac),
        .raw => unreachable, // no content probe chooses raw PCM
    } else try std.testing.expectError(error.UnknownFormat, got);
}

test "fuzz: detection agrees with the direct parser on arbitrary input" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.bytes("mono_8k"),
        fixtures.au.bytes("au_mono_8k"),
        fixtures.au.bytes("au_annotation_odd_length"),
        fixtures.bytes("w64_alaw_mono_8k"),
        fixtures.bytes("rf64"),
        fixtures.aiff.bytes("aifc_sowt"),
        fixtures.aiff.bytes("aiff_other_chunks"),
        fixtures.caf.bytes("caf_chunks_around_data"),
        fixtures.flac.bytes("flac_constant_mono_8k"),
    } });
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}
