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

const usage_line = "usage: zffprobe [-f wav|w64|au] <file.wav | file.w64 | file.au | ->\n";

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

const s24_report =
    \\format=wav
    \\codec=pcm_s24le
    \\sample_fmt=s32
    \\channels=2
    \\channel_layout=stereo
    \\sample_rate=48000
    \\nb_samples=4
    \\duration_num=4
    \\duration_den=48000
    \\
;

const f32_report =
    \\format=wav
    \\codec=pcm_f32le
    \\sample_fmt=flt
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const alaw_report =
    \\format=wav
    \\codec=pcm_alaw
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const w64_mono_8k_report =
    \\format=w64
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

// T21c: the stream lines, then one escaped tag line per tag in FFmpeg's order.
const bext_tags_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=4
    \\duration_num=4
    \\duration_den=8000
    \\tag:comment=Same note
    \\tag:encoded_by=Recorder
    \\tag:originator_reference=REF123
    \\tag:date=2024-05-06
    \\tag:creation_time=07:08:09
    \\tag:time_reference=48000
    \\tag:umid=0x060A2B3401010101010101010101010101010101010101010101010101010101
    \\tag:coding_history=A=PCM,F=8000\r\n
    \\tag:encoded_by=Tech
    \\
;

const info_values_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=4
    \\duration_num=4
    \\duration_den=8000
    \\tag:genre=Pop
    \\tag:IKEY=a
    \\tag:ISBJ=
    \\tag:title=lower
    \\tag:IENG=Engineer
    \\tag:IA=v
    \\
;

const w64_alaw_report =
    \\format=w64
    \\codec=pcm_alaw
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
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
    // T16: no demuxer claims an empty input or a non-RIFF start, as in FFmpeg.
    .{ .name = "empty input", .fixture = "empty_input", .exit_code = 3, .stderr_contains = ": UnknownFormat\n" },
    .{ .name = "forced, an empty input is truncated", .args = &.{ "-f", "wav" }, .fixture = "empty_input", .exit_code = 2, .stderr_contains = ": Truncated\n" },
    .{ .name = "unknown content", .fixture = "not_riff", .exit_code = 3, .stderr_contains = ": UnknownFormat\n" },
    .{ .name = "malformed header", .args = &.{ "-f", "wav" }, .fixture = "not_riff", .exit_code = 2, .stderr_contains = ": InvalidRiff\n" },
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
    // FFmpeg's AU probe needs a nonzero data size, so an empty AU file is read only when forced.
    .{ .name = "empty AU data is not detected", .set = .au, .fixture = "au_empty_data", .exit_code = 3, .stderr_contains = ": UnknownFormat\n" },
    .{ .name = "empty AU data, forced", .set = .au, .args = &.{ "-f", "au" }, .fixture = "au_empty_data", .exit_code = 0, .stdout = au_empty_data_report, .stderr = "" },
    .{ .name = "malformed AU header", .set = .au, .fixture = "au_offset_too_small", .exit_code = 2, .stderr_contains = ": InvalidAu\n" },
    .{ .name = "a wrong AU magic is not detected", .set = .au, .fixture = "au_bad_magic", .exit_code = 3, .stderr_contains = ": UnknownFormat\n" },
    .{ .name = "a wrong AU magic, forced", .set = .au, .args = &.{ "-f", "au" }, .fixture = "au_bad_magic", .exit_code = 2, .stderr_contains = ": InvalidAu\n" },
    .{ .name = "an unknown -f", .args = &.{ "-f", "mp3" }, .fixture = "mono_8k", .exit_code = 3, .stderr = "zffprobe: mp3: unsupported input format\n" },
    .{ .name = "unsupported AU encoding", .set = .au, .fixture = "au_encoding_g726", .exit_code = 3, .stderr_contains = ": UnsupportedFormat\n" },
    .{ .name = "unknown AU size", .set = .au, .fixture = "au_unknown_size", .exit_code = 3, .stderr_contains = ": UnsupportedStreamingSize\n" },
    .{ .name = "AU rate limit", .set = .au, .fixture = "au_rate_over_limit", .exit_code = 5, .stderr_contains = ": LimitExceeded\n" },
    .{ .name = "truncated AU pipe", .set = .au, .args = &.{"-"}, .stdin_fixture = "au_truncated_data", .exit_code = 2, .stderr = "zffprobe: -: Truncated\n" },
    // T21a: the WAV encodings report their codec and storage format.
    .{ .name = "24-bit extensible", .fixture = "s24_stereo_48k_extensible", .exit_code = 0, .stdout = s24_report, .stderr = "" },
    .{ .name = "float from a pipe", .args = &.{"-"}, .stdin_fixture = "f32_mono_8k", .exit_code = 0, .stdout = f32_report, .stderr = "" },
    .{ .name = "A-law", .fixture = "alaw_mono_8k", .exit_code = 0, .stdout = alaw_report, .stderr = "" },
    .{ .name = "an unknown extensible subformat", .fixture = "extensible_unknown_subformat", .exit_code = 3, .stderr_contains = ": UnsupportedFormat\n" },
    // T21b: Wave64, detected from content.
    .{ .name = "Wave64", .fixture = "w64_mono_8k", .exit_code = 0, .stdout = w64_mono_8k_report, .stderr = "" },
    .{ .name = "Wave64 A-law from a pipe", .args = &.{"-"}, .stdin_fixture = "w64_alaw_mono_8k", .exit_code = 0, .stdout = w64_alaw_report, .stderr = "" },
    .{ .name = "a truncated Wave64 header", .fixture = "w64_truncated_chunk_header", .exit_code = 2, .stderr_contains = ": Truncated\n" },
    .{ .name = "unknown Wave64 sizes", .fixture = "w64_unknown_length_pipe", .exit_code = 3, .stderr_contains = ": UnsupportedStreamingSize\n" },
    // T21c: tags follow the stream lines.
    .{ .name = "bext and INFO tags", .fixture = "bext_tags", .exit_code = 0, .stdout = bext_tags_report, .stderr = "" },
    .{ .name = "INFO tag values from a pipe", .args = &.{"-"}, .stdin_fixture = "info_values", .exit_code = 0, .stdout = info_values_report, .stderr = "" },
};

/// A zffmpeg process run: `args`, then the input fixture's path (or standard
/// input), then `tail`, then an output file in a fresh directory if
/// `output_file` names one. Stdout, stderr, the status and the output file's
/// bytes are checked.
const ConvertCase = struct {
    name: []const u8,
    /// Arguments before the input; end with "-i" when `input` is set.
    args: []const []const u8 = &.{},
    set: FixtureSet = .wav,
    /// zig/testing/fixtures/<set>/<name>.<set>, placed after `args`.
    input: ?[]const u8 = null,
    /// Piped to standard input instead; `args` then ends with "-i", "-".
    stdin_input: ?[]const u8 = null,
    /// Output options and the output, after the input.
    tail: []const []const u8 = &.{},
    /// Name of an output file created in a fresh directory, after `tail`.
    output_file: ?[]const u8 = null,
    /// The exact bytes `output_file` must hold.
    output_bytes: ?[]const u8 = null,
    exit_code: u8,
    /// Exact stdout, unless `stdout_contains` is set.
    stdout: []const u8 = "",
    stdout_contains: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    stderr_contains: ?[]const u8 = null,
};

const zffmpeg_usage = "usage: zffmpeg [-y | -n] [-f wav|w64|au] -i <input | -> [-c copy] [-f wav|w64|au] <output | ->\n";

// The paired WAV and AU fixtures hold the same samples, so each is the exact
// expected output of converting the other.
const wav_mono_8k = @embedFile("zig/testing/fixtures/wav/mono_8k.wav");
const wav_stereo_44k1 = @embedFile("zig/testing/fixtures/wav/stereo_44k1.wav");
const wav_empty_data = @embedFile("zig/testing/fixtures/wav/empty_data.wav");
// Above 48 kHz the writer emits WAVE_FORMAT_EXTENSIBLE, as FFmpeg's does.
const wav_mono_192k = @embedFile("zig/testing/fixtures/wav/s16_mono_192k_extensible.wav");
const wav_s24_stereo = @embedFile("zig/testing/fixtures/wav/s24_stereo_48k_extensible.wav");
const au_mono_8k = @embedFile("zig/testing/fixtures/au/au_mono_8k.au");
const au_stereo_44k1 = @embedFile("zig/testing/fixtures/au/au_stereo_44k1.au");
const au_empty_data = @embedFile("zig/testing/fixtures/au/au_empty_data.au");
const au_mono_192k = @embedFile("zig/testing/fixtures/au/au_mono_192k_rate_limit.au");
// mono_8k's samples as the Wave64 writer emits them.
const w64_mono_8k = @embedFile("zig/testing/fixtures/wav/w64_mono_8k.wav");
// alaw_mono_8k's payload in AU, as the AU writer emits it.
const au_alaw_mono_8k = @embedFile("zig/testing/fixtures/au/au_alaw_mono_8k.au");
// T21c: tags as the writer emits them, so the tagged input converts to itself.
const wav_info_tags = @embedFile("zig/testing/fixtures/wav/info_tags.wav");

/// T13b: every cell of the operation matrix (files and pipes, transcode and
/// copy), the output format from -f or the extension, late and early media
/// errors, read and open failures, and the command line. The overwrite policy,
/// same-file refusal, partial-output removal and write failures need prepared
/// files; zig/testing/zffmpeg_cases.zig runs those.
const convert_cases = [_]ConvertCase{
    .{ .name = "WAV to WAV", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_mono_8k, .stderr = "" },
    .{ .name = "WAV copy to WAV from a pipe", .args = &.{ "-i", "-" }, .stdin_input = "stereo_44k1", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_stereo_44k1, .stderr = "" },
    .{ .name = "WAV to AU", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-f", "au", "-" }, .exit_code = 0, .stdout = au_mono_8k, .stderr = "" },
    .{ .name = "WAV to AU from a pipe", .args = &.{ "-i", "-" }, .stdin_input = "stereo_44k1", .tail = &.{ "-f", "au", "-" }, .exit_code = 0, .stdout = au_stereo_44k1, .stderr = "" },
    .{ .name = "WAV at 192 kHz to AU", .args = &.{"-i"}, .input = "mono_192k_rate_limit", .tail = &.{ "-f", "au", "-" }, .exit_code = 0, .stdout = au_mono_192k, .stderr = "" },
    .{ .name = "empty WAV to AU", .args = &.{"-i"}, .input = "empty_data", .tail = &.{ "-f", "au", "-" }, .exit_code = 0, .stdout = au_empty_data, .stderr = "" },
    .{ .name = "AU to AU", .set = .au, .args = &.{"-i"}, .input = "au_mono_8k", .tail = &.{ "-f", "au", "-" }, .exit_code = 0, .stdout = au_mono_8k, .stderr = "" },
    .{ .name = "AU copy to AU", .set = .au, .args = &.{"-i"}, .input = "au_stereo_44k1", .tail = &.{ "-c", "copy", "-f", "au", "-" }, .exit_code = 0, .stdout = au_stereo_44k1, .stderr = "" },
    .{ .name = "AU to WAV", .set = .au, .args = &.{"-i"}, .input = "au_stereo_44k1", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_stereo_44k1, .stderr = "" },
    .{ .name = "AU at 192 kHz to WAV from a pipe", .set = .au, .args = &.{ "-i", "-" }, .stdin_input = "au_mono_192k_rate_limit", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_mono_192k, .stderr = "" },
    // FFmpeg's AU probe needs a nonzero data size: an empty AU input must be forced.
    .{ .name = "empty AU to WAV", .set = .au, .args = &.{ "-f", "au", "-i" }, .input = "au_empty_data", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_empty_data, .stderr = "" },
    .{ .name = "WAV copy to AU is rejected", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-c", "copy", "-f", "au", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "AU copy to WAV is rejected", .set = .au, .args = &.{"-i"}, .input = "au_mono_8k", .tail = &.{ "-c:a", "copy", "-f", "wav", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "output format from the extension", .args = &.{"-i"}, .input = "mono_8k", .output_file = "out.au", .output_bytes = au_mono_8k, .exit_code = 0, .stderr = "" },
    .{ .name = "an uppercase extension", .set = .au, .args = &.{"-i"}, .input = "au_stereo_44k1", .output_file = "OUT.WAV", .output_bytes = wav_stereo_44k1, .exit_code = 0, .stderr = "" },
    .{ .name = "-f wins over the extension", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-f", "wav" }, .output_file = "out.au", .output_bytes = wav_mono_8k, .exit_code = 0, .stderr = "" },
    // T21a: copy keeps any WAV encoding; transcoding needs samples stored as
    // s16 until sample-format conversion (T23a).
    .{ .name = "24-bit copy to WAV", .args = &.{"-i"}, .input = "s24_stereo_48k_extensible", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_s24_stereo, .stderr = "" },
    // T21b: Wave64 in both directions; it carries the WAV codecs.
    .{ .name = "WAV copy to Wave64", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-c", "copy", "-f", "w64", "-" }, .exit_code = 0, .stdout = w64_mono_8k, .stderr = "" },
    .{ .name = "Wave64 to WAV from a pipe", .args = &.{ "-i", "-" }, .stdin_input = "w64_mono_8k", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_mono_8k, .stderr = "" },
    .{ .name = "AU to Wave64 from the extension", .set = .au, .args = &.{"-i"}, .input = "au_mono_8k", .output_file = "out.w64", .output_bytes = w64_mono_8k, .exit_code = 0, .stderr = "" },
    .{ .name = "Wave64 copy to AU is rejected", .args = &.{"-i"}, .input = "w64_mono_8k", .tail = &.{ "-c", "copy", "-f", "au", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    // T21c: tags are carried into WAV, through files and pipes.
    .{ .name = "tags carried to WAV", .args = &.{"-i"}, .input = "info_tags", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_info_tags, .stderr = "" },
    .{ .name = "tags carried by copy from a pipe", .args = &.{ "-i", "-" }, .stdin_input = "info_tags", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_info_tags, .stderr = "" },
    .{ .name = "24-bit transcode is rejected", .args = &.{"-i"}, .input = "s24_stereo_48k_extensible", .tail = &.{ "-f", "au", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    // T22a: AU carries A-law and mu-law too, so they copy between the containers.
    .{ .name = "A-law copy to AU", .args = &.{"-i"}, .input = "alaw_mono_8k", .tail = &.{ "-c", "copy", "-f", "au", "-" }, .exit_code = 0, .stdout = au_alaw_mono_8k, .stderr = "" },
    .{ .name = "24-bit copy to AU is rejected", .args = &.{"-i"}, .input = "s24_stereo_48k_extensible", .tail = &.{ "-c", "copy", "-f", "au", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "an error after the data", .args = &.{"-i"}, .input = "duplicate_data", .tail = &.{ "-f", "au", "-" }, .exit_code = 2, .stderr_contains = ": InvalidWave\n" },
    .{ .name = "a truncated pipe", .set = .au, .args = &.{ "-i", "-" }, .stdin_input = "au_truncated_data", .tail = &.{ "-f", "wav", "-" }, .exit_code = 2, .stderr = "zffmpeg: -: Truncated\n" },
    .{ .name = "unknown content", .args = &.{"-i"}, .input = "not_riff", .tail = &.{ "-f", "au", "-" }, .exit_code = 3, .stderr_contains = ": UnknownFormat\n" },
    .{ .name = "a malformed header, forced", .args = &.{ "-f", "wav", "-i" }, .input = "not_riff", .tail = &.{ "-f", "au", "-" }, .exit_code = 2, .stderr_contains = ": InvalidRiff\n" },
    .{ .name = "an unknown input -f", .args = &.{ "-f", "mp3", "-i" }, .input = "mono_8k", .tail = &.{ "-f", "au", "-" }, .exit_code = 3, .stderr = "zffmpeg: mp3: unsupported input format\n" },
    .{ .name = "an unsupported input", .args = &.{"-i"}, .input = "rifx_big_endian", .tail = &.{ "-f", "au", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedFormat\n" },
    .{ .name = "an input limit", .args = &.{"-i"}, .input = "chunks_over_limit", .tail = &.{ "-f", "au", "-" }, .exit_code = 5, .stderr_contains = ": LimitExceeded\n" },
    .{ .name = "a missing input", .args = &.{ "-i", "no-such-file.wav", "-f", "wav", "-" }, .exit_code = 4, .stderr = "zffmpeg: no-such-file.wav: FileNotFound\n" },
    .{ .name = "a directory as the input", .args = &.{ "-i", "zig", "-f", "wav", "-" }, .exit_code = 4, .stderr = "zffmpeg: zig: IsDir\n" },
    .{ .name = "an output in a missing directory", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-f", "wav", "no-such-dir" ++ std.fs.path.sep_str ++ "out.wav" }, .exit_code = 4, .stderr_contains = ": FileNotFound\n" },
    .{ .name = "no arguments", .exit_code = 1, .stderr = "zffmpeg: missing -i <input>\n" ++ zffmpeg_usage },
    .{ .name = "help", .args = &.{"--help"}, .exit_code = 0, .stdout_contains = zffmpeg_usage, .stderr = "" },
    .{ .name = "-y with -n", .args = &.{ "-y", "-n", "-i", "a.wav", "b.wav" }, .exit_code = 1, .stderr = "zffmpeg: -y and -n contradict each other\n" ++ zffmpeg_usage },
    .{ .name = "two inputs", .args = &.{ "-i", "a.wav", "-i", "b.wav", "c.wav" }, .exit_code = 1, .stderr_contains = "only one input is supported\n" },
    .{ .name = "an input option", .args = &.{ "-c", "copy", "-i", "a.wav", "b.wav" }, .exit_code = 1, .stderr_contains = "input options other than -f are not supported; put this after -i <input>: -c\n" },
    .{ .name = "an option after the output", .args = &.{ "-i", "a.wav", "b.wav", "-y" }, .exit_code = 1, .stderr_contains = "options after the output are not supported: -y\n" },
    .{ .name = "no output", .args = &.{ "-i", "a.wav" }, .exit_code = 1, .stderr_contains = "missing output\n" },
    .{ .name = "an unknown option", .args = &.{ "-i", "a.wav", "-ar", "8000", "b.wav" }, .exit_code = 1, .stderr_contains = "unknown option: -ar\n" },
    .{ .name = "an encoder name", .args = &.{ "-i", "a.wav", "-c", "pcm_s16le", "b.wav" }, .exit_code = 1, .stderr_contains = "only -c copy is supported; got: pcm_s16le\n" },
    .{ .name = "a missing value", .args = &.{ "-i", "a.wav", "-f" }, .exit_code = 1, .stderr_contains = "missing value for: -f\n" },
    .{ .name = "standard output needs -f", .args = &.{ "-i", "a.wav", "-" }, .exit_code = 1, .stderr_contains = "-f is required when writing to standard output\n" },
    .{ .name = "an unsupported -f", .args = &.{ "-i", "a.wav", "-f", "mp3", "-" }, .exit_code = 3, .stderr = "zffmpeg: mp3: unsupported output format\n" },
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

    const test_step = b.step("test", "Run the av module, example, zffprobe and zffmpeg tests");

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

    const zffmpeg = b.addExecutable(.{
        .name = "zffmpeg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/cli/ffmpeg.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "av", .module = av }},
        }),
    });
    b.installArtifact(zffmpeg);

    const run_zffmpeg = b.addRunArtifact(zffmpeg);
    run_zffmpeg.addPassthruArgs();
    b.step("zffmpeg", "Run zffmpeg; pass its arguments after --").dependOn(&run_zffmpeg.step);

    if (test_filters.len == 0) {
        for (convert_cases) |case| addConvertCase(b, test_step, zffmpeg, case);

        // Cases that need prepared files run in a fresh directory each time.
        const cases_tool = b.addExecutable(.{
            .name = "zffmpeg-cases",
            .root_module = b.createModule(.{
                .root_source_file = b.path("zig/testing/zffmpeg_cases.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "av", .module = av }},
            }),
        });
        const run_cases = b.addRunArtifact(cases_tool);
        run_cases.setName("zffmpeg: prepared-file cases");
        run_cases.addArtifactArg(zffmpeg);
        run_cases.addDirectoryArg(b.path("zig/testing/fixtures"));
        _ = run_cases.addOutputDirectoryArg("work");
        run_cases.expectExitCode(0);
        run_cases.expectStdErrEqual("");
        test_step.dependOn(&run_cases.step);
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

fn addConvertCase(b: *std.Build, test_step: *std.Build.Step, zffmpeg: *std.Build.Step.Compile, case: ConvertCase) void {
    const run = b.addRunArtifact(zffmpeg);
    run.setName(b.fmt("zffmpeg: {s}", .{case.name}));
    run.setCwd(b.path("."));
    run.addArgs(case.args);
    if (case.input) |name| run.addFileArg(fixturePath(b, case.set, name));
    if (case.stdin_input) |name| run.setStdIn(.{ .lazy_path = fixturePath(b, case.set, name) });
    run.addArgs(case.tail);
    run.expectExitCode(case.exit_code);
    if (case.stdout_contains) |text| run.expectStdOutMatch(text) else run.expectStdOutEqual(case.stdout);
    if (case.stderr) |text| run.expectStdErrEqual(text);
    if (case.stderr_contains) |text| run.expectStdErrMatch(text);
    if (case.output_file) |name| {
        const output = run.addOutputFileArg(name);
        const check = b.addCheckFile(output, .{ .expected_exact = case.output_bytes.? });
        test_step.dependOn(&check.step);
    }
    test_step.dependOn(&run.step);
}

fn fixturePath(b: *std.Build, set: FixtureSet, name: []const u8) std.Build.LazyPath {
    return b.path(b.fmt("zig/testing/fixtures/{t}/{s}.{t}", .{ set, name, set }));
}
