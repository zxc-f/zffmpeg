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
const FixtureSet = enum { wav, au, aiff, raw, caf, flac, ogg };

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

const usage_line = "usage: zffprobe [-f <format>] [-sample_rate <rate>] [-ch_layout <layout>] <file | ->\n";

const mono_8k_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
    \\sample_rate=8000
    \\nb_samples=0
    \\duration_num=0
    \\duration_den=8000
    \\
;

const aiff_mono_8k_report =
    \\format=aiff
    \\codec=pcm_s16be
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=unknown
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const aifc_fl32_report =
    \\format=aiff
    \\codec=pcm_f32be
    \\sample_fmt=flt
    \\channels=1
    \\channel_layout=unknown
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const caf_s16be_report =
    \\format=caf
    \\codec=pcm_s16be
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=unknown
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const caf_s64le_report =
    \\format=caf
    \\codec=pcm_s64le
    \\sample_fmt=s64
    \\channels=1
    \\channel_layout=unknown
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

const raw_s16le_report =
    \\format=s16le
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

const raw_alaw_defaults_report =
    \\format=alaw
    \\codec=pcm_alaw
    \\sample_fmt=s16
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=44100
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=44100
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
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
    \\channel_layout=unknown
    \\sample_rate=8000
    \\nb_samples=8
    \\duration_num=8
    \\duration_den=8000
    \\
;

/// T09: valid, empty, malformed, unsupported, I/O, resource-limit and usage
/// cases, each checking stdout, stderr and the exit status. T12c adds the same
/// for AU, including a pipe, and a non-AU magic that detection sends to WAV.
// T23b: the layout as ffprobe prints it, from an extensible mask.
const five_one_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=6
    \\channel_layout=5.1
    \\sample_rate=8000
    \\nb_samples=2
    \\duration_num=2
    \\duration_den=8000
    \\
;

const mask_high_report =
    \\format=wav
    \\codec=pcm_s16le
    \\sample_fmt=s16
    \\channels=3
    \\channel_layout=3 channels (FL+FR+USR20)
    \\sample_rate=8000
    \\nb_samples=2
    \\duration_num=2
    \\duration_den=8000
    \\
;

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
    .{ .name = "a 5.1 layout", .fixture = "extensible_5point1", .exit_code = 0, .stdout = five_one_report, .stderr = "" },
    .{ .name = "a mask past WAVE's positions", .fixture = "extensible_mask_high", .exit_code = 0, .stdout = mask_high_report, .stderr = "" },
    .{ .name = "channel limit", .fixture = "fmt_channels65", .exit_code = 5, .stderr_contains = ": LimitExceeded\n" },
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
    // T22b: AIFF and AIFF-C, detected from content.
    .{ .name = "AIFF", .set = .aiff, .fixture = "aiff_mono_8k", .exit_code = 0, .stdout = aiff_mono_8k_report, .stderr = "" },
    .{ .name = "AIFF-C float from a pipe", .set = .aiff, .args = &.{"-"}, .stdin_fixture = "aifc_fl32", .exit_code = 0, .stdout = aifc_fl32_report, .stderr = "" },
    .{ .name = "a FORM size below 4 is not detected", .set = .aiff, .fixture = "aiff_form_size_small", .exit_code = 3, .stderr_contains = ": UnknownFormat\n" },
    .{ .name = "a FORM size below 4, forced", .set = .aiff, .args = &.{ "-f", "aiff" }, .fixture = "aiff_form_size_small", .exit_code = 2, .stderr_contains = ": InvalidAiff\n" },
    .{ .name = "SSND before COMM", .set = .aiff, .fixture = "aiff_ssnd_before_comm", .exit_code = 2, .stderr_contains = ": InvalidAiff\n" },
    .{ .name = "compressed AIFF-C", .set = .aiff, .fixture = "aifc_unknown_type", .exit_code = 3, .stderr_contains = ": UnsupportedFormat\n" },
    .{ .name = "AIFF rate limit", .set = .aiff, .fixture = "aiff_rate_over_limit", .exit_code = 5, .stderr_contains = ": LimitExceeded\n" },
    .{ .name = "truncated AIFF pipe", .set = .aiff, .args = &.{"-"}, .stdin_fixture = "aiff_truncated_data", .exit_code = 2, .stderr = "zffprobe: -: Truncated\n" },
    // T22c: raw PCM, forced with its parameters or FFmpeg's defaults.
    .{ .name = "raw PCM with parameters", .set = .raw, .args = &.{ "-sample_rate", "8000", "-f", "s16le", "-ch_layout", "mono" }, .fixture = "raw_s16le_mono_8k", .exit_code = 0, .stdout = raw_s16le_report, .stderr = "" },
    .{ .name = "raw A-law defaults from a pipe", .set = .raw, .args = &.{ "-f", "alaw", "-" }, .stdin_fixture = "raw_alaw_mono_8k", .exit_code = 0, .stdout = raw_alaw_defaults_report, .stderr = "" },
    .{ .name = "raw PCM is not detected from content", .set = .raw, .fixture = "raw_s16le_mono_8k", .exit_code = 3, .stderr_contains = ": UnknownFormat\n" },
    .{ .name = "a partial raw frame", .set = .raw, .args = &.{ "-f", "s16le", "-ch_layout", "stereo" }, .fixture = "raw_partial_frame", .exit_code = 2, .stderr_contains = ": Truncated\n" },
    .{ .name = "a raw sample rate of 0", .set = .raw, .args = &.{ "-f", "s16le", "-sample_rate", "0" }, .fixture = "raw_rate_zero", .exit_code = 2, .stderr_contains = ": InvalidFormat\n" },
    .{ .name = "raw parameters for WAV", .args = &.{ "-sample_rate", "8000" }, .fixture = "mono_8k", .exit_code = 1, .stderr_contains = ": -sample_rate and -ch_layout apply only to raw PCM input\n" },
    .{ .name = "an invalid sample rate", .args = &.{ "-f", "s16le", "-sample_rate", "fast" }, .fixture = "mono_8k", .exit_code = 1, .stderr = "zffprobe: fast: invalid sample rate\n" },
    .{ .name = "an unsupported channel layout", .args = &.{ "-f", "s16le", "-ch_layout", "ambisonic 1" }, .fixture = "mono_8k", .exit_code = 3, .stderr = "zffprobe: ambisonic 1: unsupported channel layout\n" },
    .{ .name = "an invalid channel layout", .args = &.{ "-f", "s16le", "-ch_layout", "7 speakers" }, .fixture = "mono_8k", .exit_code = 1, .stderr = "zffprobe: 7 speakers: invalid channel layout\n" },
    .{ .name = "raw PCM in a custom order", .set = .raw, .args = &.{ "-f", "s16le", "-sample_rate", "8000", "-ch_layout", "FC+FL+FR" }, .fixture = "raw_s16le_custom", .exit_code = 0, .stdout_contains = "channels=3\nchannel_layout=3 channels (FC+FL+FR)\n", .stderr = "" },
    .{ .name = "raw PCM over the channel limit", .set = .raw, .args = &.{ "-f", "s16le", "-ch_layout", "65C" }, .fixture = "raw_s16le_channels65", .exit_code = 5, .stderr_contains = ": LimitExceeded\n" },
    .{ .name = "an option given twice", .args = &.{ "-f", "s16le", "-f", "s16le" }, .fixture = "mono_8k", .exit_code = 1, .stderr = usage_line },
    .{ .name = "an unknown raw format", .args = &.{ "-f", "s64le" }, .fixture = "mono_8k", .exit_code = 3, .stderr = "zffprobe: s64le: unsupported input format\n" },
    // T22d: CAF, detected from content.
    .{ .name = "CAF", .set = .caf, .fixture = "caf_s16be_mono_8k", .exit_code = 0, .stdout = caf_s16be_report, .stderr = "" },
    .{ .name = "CAF 64-bit integers from a pipe", .set = .caf, .args = &.{"-"}, .stdin_fixture = "caf_s64le_mono", .exit_code = 0, .stdout = caf_s64le_report, .stderr = "" },
    .{ .name = "an unknown CAF data size", .set = .caf, .fixture = "caf_data_size_unknown", .exit_code = 3, .stderr_contains = ": UnsupportedStreamingSize\n" },
    .{ .name = "a CAF packet table", .set = .caf, .fixture = "caf_pakt", .exit_code = 3, .stderr_contains = ": UnsupportedFormat\n" },
    .{ .name = "a CAF without desc", .set = .caf, .args = &.{ "-f", "caf" }, .fixture = "caf_desc_missing", .exit_code = 2, .stderr_contains = ": InvalidCaf\n" },
    .{ .name = "a truncated CAF pipe", .set = .caf, .args = &.{"-"}, .stdin_fixture = "caf_truncated_data", .exit_code = 2, .stderr = "zffprobe: -: Truncated\n" },
    // T26a: FLAC's report comes from STREAMINFO.
    .{ .name = "FLAC", .set = .flac, .fixture = "flac_mid_side", .exit_code = 0, .stdout = flac_mid_side_report, .stderr = "" },
    .{ .name = "FLAC 5.1 from a pipe", .set = .flac, .args = &.{"-"}, .stdin_fixture = "flac_six_channels_48k", .exit_code = 0, .stdout = flac_six_channels_report, .stderr = "" },
    // T26b: every sample size; above 16 bits the samples are s32.
    .{ .name = "24-bit FLAC", .set = .flac, .fixture = "flac_bps24", .exit_code = 0, .stdout = flac_bps24_report, .stderr = "" },
    .{ .name = "FLAC tags", .set = .flac, .fixture = "flac_vorbis_comment", .exit_code = 0, .stdout_contains = "tag:artist=first;second\n", .stderr = "" },
    .{ .name = "FLAC below 4 bits", .set = .flac, .fixture = "flac_bps3", .exit_code = 2, .stderr_contains = ": InvalidFlac\n" },
    .{ .name = "FLAC without STREAMINFO first", .set = .flac, .fixture = "flac_no_streaminfo", .exit_code = 2, .stderr_contains = ": InvalidFlac\n" },
    .{ .name = "a truncated FLAC header from a pipe", .set = .flac, .args = &.{"-"}, .stdin_fixture = "flac_truncated_metadata", .exit_code = 2, .stderr = "zffprobe: -: Truncated\n" },
    // T27a: Ogg's first known stream; without a decoder, no sample format
    // or layout; a file's duration from the demuxer's scans, a pipe's none.
    .{ .name = "Ogg Opus", .set = .ogg, .fixture = "ogg_opus_stereo", .exit_code = 0, .stdout = "format=ogg\ncodec=opus\nsample_fmt=unknown\nchannels=2\nchannel_layout=unknown\nsample_rate=48000\nnb_samples=11520\nduration_num=11520\nduration_den=48000\n", .stderr = "" },
    .{ .name = "Ogg Opus from a pipe", .set = .ogg, .args = &.{"-"}, .stdin_fixture = "ogg_opus_stereo", .exit_code = 0, .stdout_contains = "nb_samples=N/A\n", .stderr = "" },
    .{ .name = "Ogg Vorbis", .set = .ogg, .fixture = "ogg_vorbis_ffmpeg_44k", .exit_code = 0, .stdout = "format=ogg\ncodec=vorbis\nsample_fmt=fltp\nchannels=2\nchannel_layout=stereo\nsample_rate=44100\nnb_samples=30000\nduration_num=30000\nduration_den=44100\n", .stderr = "" },
    .{ .name = "Ogg Vorbis whose setup header the decoder refuses", .set = .ogg, .fixture = "ogg_vorbis_stereo", .exit_code = 2, .stderr_contains = ": InvalidVorbis\n" },
    .{ .name = "Ogg FLAC", .set = .ogg, .fixture = "ogg_flac_stereo", .exit_code = 0, .stdout_contains = "codec=flac\nsample_fmt=s16\nchannels=2\nchannel_layout=stereo\n", .stderr = "" },
    .{ .name = "Ogg beside an unknown stream", .set = .ogg, .fixture = "ogg_unknown_codec", .exit_code = 0, .stdout_contains = "codec=opus\n", .stderr = "" },
    .{ .name = "Ogg without a page", .set = .ogg, .fixture = "ogg_no_pages", .exit_code = 2, .stderr_contains = ": Truncated\n" },
    .{ .name = "Ogg Vorbis without a mode table", .set = .ogg, .fixture = "ogg_vorbis_bad_setup", .exit_code = 2, .stderr_contains = ": InvalidOgg\n" },
};

const flac_mid_side_report =
    \\format=flac
    \\codec=flac
    \\sample_fmt=s16
    \\channels=2
    \\channel_layout=stereo
    \\sample_rate=44100
    \\nb_samples=1152
    \\duration_num=1152
    \\duration_den=44100
    \\
;

const flac_bps24_report =
    \\format=flac
    \\codec=flac
    \\sample_fmt=s32
    \\channels=1
    \\channel_layout=mono
    \\sample_rate=44100
    \\nb_samples=576
    \\duration_num=576
    \\duration_den=44100
    \\
;

const flac_six_channels_report =
    \\format=flac
    \\codec=flac
    \\sample_fmt=s16
    \\channels=6
    \\channel_layout=5.1(side)
    \\sample_rate=48000
    \\nb_samples=256
    \\duration_num=256
    \\duration_den=48000
    \\
;

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

const zffmpeg_usage = "usage: zffmpeg [-y | -n] [-f <format>] [-sample_rate <rate>] [-ch_layout <layout>] -i <input | -> [-c copy|<encoder>] [-ar <rate>] [-ac <channels> | -ch_layout <layout>] [-dither_method <method>] [-dither_scale <scale>] [FLAC encoder options] [-f <format>] <output | ->\n";

// The paired WAV and AU fixtures hold the same samples, so each is the exact
// expected output of converting the other.
const wav_mono_8k = @embedFile("zig/testing/fixtures/wav/mono_8k.wav");
const wav_stereo_44k1 = @embedFile("zig/testing/fixtures/wav/stereo_44k1.wav");
const wav_empty_data = @embedFile("zig/testing/fixtures/wav/empty_data.wav");
// Above 48 kHz the writer emits WAVE_FORMAT_EXTENSIBLE, as FFmpeg's does.
const wav_mono_192k = @embedFile("zig/testing/fixtures/wav/s16_mono_192k_extensible.wav");
const wav_s24_stereo = @embedFile("zig/testing/fixtures/wav/s24_stereo_48k_extensible.wav");
const wav_5point1 = @embedFile("zig/testing/fixtures/wav/extensible_5point1.wav");
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
// T22b: the paired WAV and AU samples as the AIFF writer emits them.
const aiff_mono_8k = @embedFile("zig/testing/fixtures/aiff/aiff_mono_8k.aiff");
const aiff_stereo_44k1 = @embedFile("zig/testing/fixtures/aiff/aiff_stereo_44k1.aiff");
// mono_8k's s16le samples, stream-copied into AIFF-C `sowt`.
const aifc_sowt = @embedFile("zig/testing/fixtures/aiff/aifc_sowt.aiff");
// T22c: the raw payloads of the paired fixtures.
const raw_s16be_stereo_44k1 = @embedFile("zig/testing/fixtures/raw/raw_s16be_stereo_44k1.raw");
const raw_alaw_mono_8k = @embedFile("zig/testing/fixtures/raw/raw_alaw_mono_8k.raw");

/// T13b: every cell of the operation matrix (files and pipes, transcode and
/// copy), the output format from -f or the extension, late and early media
/// errors, read and open failures, and the command line. The overwrite policy,
/// same-file refusal, partial-output removal and write failures need prepared
/// files; zig/testing/zffmpeg_cases.zig runs those.
/// flac_constant_mono_8k's samples: 64 each of 0, 1000, -32768 and 32767.
const flac_constant_s16le = constantSamples(.little);
const flac_constant_s16be = constantSamples(.big);

fn constantSamples(comptime endian: std.builtin.Endian) [512]u8 {
    var out: [512]u8 = undefined;
    for ([_]i16{ 0, 1000, -32768, 32767 }, 0..) |value, block| {
        for (0..64) |i| std.mem.writeInt(i16, out[2 * (64 * block + i) ..][0..2], value, endian);
    }
    return out;
}

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
    .{ .name = "an input option", .args = &.{ "-c", "copy", "-i", "a.wav", "b.wav" }, .exit_code = 1, .stderr_contains = "input options other than -f and the raw PCM ones are not supported; put this after -i <input>: -c\n" },
    .{ .name = "an option after the output", .args = &.{ "-i", "a.wav", "b.wav", "-y" }, .exit_code = 1, .stderr_contains = "options after the output are not supported: -y\n" },
    .{ .name = "no output", .args = &.{ "-i", "a.wav" }, .exit_code = 1, .stderr_contains = "missing output\n" },
    .{ .name = "an unknown option", .args = &.{ "-i", "a.wav", "-vn", "b.wav" }, .exit_code = 1, .stderr_contains = "unknown option: -vn\n" },
    .{ .name = "an unknown encoder", .args = &.{ "-i", "a.wav", "-c", "pcm_dvd", "b.wav" }, .exit_code = 1, .stderr_contains = "unknown encoder: pcm_dvd\n" },
    // T23a: -c:a picks the encoder; the samples convert to its storage.
    .{ .name = "24-bit WAV transcoded to 24 bits", .args = &.{"-i"}, .input = "s24_stereo_48k_extensible", .tail = &.{ "-c:a", "pcm_s24le", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_s24_stereo, .stderr = "" },
    .{ .name = "an encoder the output does not carry", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-c:a", "pcm_s16le", "-f", "au", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    // T23b: FFmpeg's command line gives six unspecified channels the 5.1
    // layout, copied or transcoded, which WAV writes as an extensible mask.
    .{ .name = "six plain channels become 5.1", .args = &.{"-i"}, .input = "fmt_channels6", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_5point1, .stderr = "" },
    .{ .name = "six plain channels copied as 5.1", .args = &.{"-i"}, .input = "fmt_channels6", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_5point1, .stderr = "" },
    .{ .name = "a 5.1 WAV copied unchanged", .args = &.{"-i"}, .input = "extensible_5point1", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_5point1, .stderr = "" },
    // T23a: libswresample's dither options, for the output only. FFmpeg
    // dithers only when the sample format changes, and ignores them for copy.
    .{ .name = "dither options before -i", .args = &.{ "-dither_method", "triangular", "-i", "a.wav", "b.wav" }, .exit_code = 1, .stderr_contains = "put this after -i <input>: -dither_method\n" },
    .{ .name = "an invalid -dither_method", .args = &.{ "-i", "a.wav", "-dither_method", "64", "b.wav" }, .exit_code = 1, .stderr_contains = "invalid -dither_method: 64\n" },
    .{ .name = "an invalid -dither_scale", .args = &.{ "-i", "a.wav", "-dither_scale", "-1", "b.wav" }, .exit_code = 1, .stderr_contains = "invalid -dither_scale: -1\n" },
    .{ .name = "dither without a format change", .args = &.{"-i"}, .input = "s24_stereo_48k_extensible", .tail = &.{ "-c:a", "pcm_s24le", "-dither_method", "shibata", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_s24_stereo, .stderr = "" },
    .{ .name = "dither ignored by stream copy", .set = .aiff, .args = &.{"-i"}, .input = "aifc_sowt", .tail = &.{ "-c", "copy", "-dither_method", "triangular", "-dither_scale", "2", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_mono_8k, .stderr = "" },
    .{ .name = "a missing value", .args = &.{ "-i", "a.wav", "-f" }, .exit_code = 1, .stderr_contains = "missing value for: -f\n" },
    .{ .name = "standard output needs -f", .args = &.{ "-i", "a.wav", "-" }, .exit_code = 1, .stderr_contains = "-f is required when writing to standard output\n" },
    .{ .name = "an unsupported -f", .args = &.{ "-i", "a.wav", "-f", "mp3", "-" }, .exit_code = 3, .stderr = "zffmpeg: mp3: unsupported output format\n" },
    // T22b: AIFF in both directions; copy needs a codec both containers carry.
    .{ .name = "WAV to AIFF", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-f", "aiff", "-" }, .exit_code = 0, .stdout = aiff_mono_8k, .stderr = "" },
    .{ .name = "WAV copy to AIFF-C from a pipe", .args = &.{ "-i", "-" }, .stdin_input = "mono_8k", .tail = &.{ "-c", "copy", "-f", "aiff", "-" }, .exit_code = 0, .stdout = aifc_sowt, .stderr = "" },
    .{ .name = "AIFF to WAV", .set = .aiff, .args = &.{"-i"}, .input = "aiff_stereo_44k1", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_stereo_44k1, .stderr = "" },
    .{ .name = "AIFF-C copy to WAV", .set = .aiff, .args = &.{"-i"}, .input = "aifc_sowt", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_mono_8k, .stderr = "" },
    .{ .name = "AU copy to AIFF", .set = .au, .args = &.{"-i"}, .input = "au_stereo_44k1", .tail = &.{ "-c", "copy", "-f", "aiff", "-" }, .exit_code = 0, .stdout = aiff_stereo_44k1, .stderr = "" },
    .{ .name = "AIFF to AU from a pipe", .set = .aiff, .args = &.{ "-i", "-" }, .stdin_input = "aiff_mono_8k", .tail = &.{ "-f", "au", "-" }, .exit_code = 0, .stdout = au_mono_8k, .stderr = "" },
    .{ .name = "AIFF from the .aif extension", .args = &.{"-i"}, .input = "mono_8k", .output_file = "out.aif", .output_bytes = aiff_mono_8k, .exit_code = 0, .stderr = "" },
    .{ .name = "AIFF from an uppercase .AIFC extension", .set = .au, .args = &.{"-i"}, .input = "au_mono_8k", .tail = &.{ "-c", "copy" }, .output_file = "OUT.AIFC", .output_bytes = aiff_mono_8k, .exit_code = 0, .stderr = "" },
    .{ .name = "plain AIFF copy to WAV is rejected", .set = .aiff, .args = &.{"-i"}, .input = "aiff_mono_8k", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "a non-AIFF input forced as AIFF", .args = &.{ "-f", "aiff", "-i" }, .input = "mono_8k", .tail = &.{ "-f", "wav", "-" }, .exit_code = 2, .stderr_contains = ": InvalidAiff\n" },
    // T22c: raw PCM in and out. A file's size gives the frame count the
    // headers need.
    .{ .name = "raw PCM to WAV", .set = .raw, .args = &.{ "-f", "s16le", "-ar", "8000", "-ac", "1", "-i" }, .input = "raw_s16le_mono_8k", .tail = &.{ "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_mono_8k, .stderr = "" },
    .{ .name = "raw PCM to AIFF with FFmpeg's option names", .set = .raw, .args = &.{ "-f", "s16be", "-sample_rate", "44100", "-ch_layout", "stereo", "-i" }, .input = "raw_s16be_stereo_44k1", .tail = &.{ "-c", "copy", "-f", "aiff", "-" }, .exit_code = 0, .stdout = aiff_stereo_44k1, .stderr = "" },
    .{ .name = "AIFF copy to raw PCM", .set = .aiff, .args = &.{"-i"}, .input = "aiff_stereo_44k1", .tail = &.{ "-c", "copy", "-f", "s16be", "-" }, .exit_code = 0, .stdout = raw_s16be_stereo_44k1, .stderr = "" },
    .{ .name = "A-law copy to raw PCM from the .al extension", .args = &.{"-i"}, .input = "alaw_mono_8k", .tail = &.{ "-c", "copy" }, .output_file = "out.al", .output_bytes = raw_alaw_mono_8k, .exit_code = 0, .stderr = "" },
    .{ .name = "raw PCM from a pipe to raw PCM", .set = .raw, .args = &.{ "-f", "alaw", "-i", "-" }, .stdin_input = "raw_alaw_mono_8k", .tail = &.{ "-c", "copy", "-f", "alaw", "-" }, .exit_code = 0, .stdout = raw_alaw_mono_8k, .stderr = "" },
    .{ .name = "raw parameters for a WAV input", .args = &.{ "-ar", "8000", "-i" }, .input = "mono_8k", .tail = &.{ "-f", "wav", "-" }, .exit_code = 1, .stderr_contains = ": -sample_rate and -ch_layout apply only to raw PCM input\n" },
    .{ .name = "-ac with -ch_layout", .args = &.{ "-ac", "1", "-ch_layout", "mono", "-i", "a.raw", "b.wav" }, .exit_code = 1, .stderr_contains = "given twice: -ch_layout\n" },
    .{ .name = "a negative output -ar", .args = &.{"-i"}, .input = "stereo_44k1", .tail = &.{ "-ar", "-8000", "-f", "wav", "-" }, .exit_code = 1, .stderr = "zffmpeg: -8000: invalid sample rate\n" },
    .{ .name = "an output -ar in FFmpeg's number syntax", .args = &.{"-i"}, .input = "stereo_44k1", .tail = &.{ "-ar", "8k", "-f", "wav", "-" }, .exit_code = 0, .stdout_contains = "WAVEfmt ", .stderr = "" },
    .{ .name = "an output -ar that is not a number", .args = &.{"-i"}, .input = "stereo_44k1", .tail = &.{ "-ar", "8kHz", "-f", "wav", "-" }, .exit_code = 1, .stderr = "zffmpeg: 8kHz: invalid sample rate\n" },
    .{ .name = "a rate change with -c copy", .args = &.{"-i"}, .input = "stereo_44k1", .tail = &.{ "-c", "copy", "-ar", "48000", "-f", "wav", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "-ar twice", .args = &.{ "-i", "a.wav", "-ar", "8000", "-ar", "16000", "b.wav" }, .exit_code = 1, .stderr_contains = "given twice: -ar\n" },
    .{ .name = "an output -ac of 0", .args = &.{"-i"}, .input = "extensible_5point1", .tail = &.{ "-ac", "0", "-f", "wav", "-" }, .exit_code = 1, .stderr = "zffmpeg: 0: invalid channel count\n" },
    .{ .name = "output -ac and -ch_layout together", .args = &.{ "-i", "a.wav", "-ac", "2", "-ch_layout", "mono", "b.wav" }, .exit_code = 1, .stderr_contains = "given twice: -ch_layout\n" },
    .{ .name = "a layout change with -c copy", .args = &.{"-i"}, .input = "extensible_5point1", .tail = &.{ "-c", "copy", "-ac", "2", "-f", "wav", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "a layout libswresample cannot mix", .args = &.{"-i"}, .input = "extensible_5point1", .tail = &.{ "-ch_layout", "FL+FR+SL", "-f", "wav", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedLayout\n" },
    .{ .name = "an invalid channel count", .set = .raw, .args = &.{ "-f", "s16le", "-ac", "0", "-i" }, .input = "raw_s16le_mono_8k", .tail = &.{ "-f", "wav", "-" }, .exit_code = 1, .stderr = "zffmpeg: 0: invalid channel count\n" },
    .{ .name = "-ac gives a count that FFmpeg's guess names", .set = .raw, .args = &.{ "-f", "s16le", "-ar", "8000", "-ac", "6", "-i" }, .input = "raw_s16le_6c", .tail = &.{ "-c", "copy", "-f", "s16le", "-" }, .exit_code = 0, .stdout = "\x00\x00\x01\x00\xff\xff\xff\x7f\x00\x80\x39\x30\xc7\xcf\x00\x01\x00\x00\x01\x00\xff\xff\xff\x7f", .stderr = "" },
    // T22d: CAF is read only.
    .{ .name = "CAF copy to WAV", .set = .caf, .args = &.{"-i"}, .input = "caf_s16le_stereo_44k1", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 0, .stdout = wav_stereo_44k1, .stderr = "" },
    .{ .name = "CAF copy to AU from a pipe", .set = .caf, .args = &.{ "-i", "-" }, .stdin_input = "caf_s16be_mono_8k", .tail = &.{ "-c", "copy", "-f", "au", "-" }, .exit_code = 0, .stdout = au_mono_8k, .stderr = "" },
    // T26a: FLAC decodes; its constant subframes hold 64 each of 0, 1000,
    // -32768 and 32767.
    .{ .name = "FLAC to s16le", .set = .flac, .args = &.{"-i"}, .input = "flac_constant_mono_8k", .tail = &.{ "-f", "s16le", "-" }, .exit_code = 0, .stdout = &flac_constant_s16le, .stderr = "" },
    .{ .name = "FLAC to s16be from a pipe", .set = .flac, .args = &.{ "-i", "-" }, .stdin_input = "flac_constant_mono_8k", .tail = &.{ "-f", "s16be", "-" }, .exit_code = 0, .stdout = &flac_constant_s16be, .stderr = "" },
    .{ .name = "FLAC copy has no output", .set = .flac, .args = &.{"-i"}, .input = "flac_constant_mono_8k", .tail = &.{ "-c", "copy", "-f", "wav", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "FLAC that decodes short of STREAMINFO", .set = .flac, .args = &.{"-i"}, .input = "flac_junk_between_frames", .tail = &.{ "-f", "wav", "-" }, .exit_code = 2, .stdout_contains = "", .stderr_contains = ": FrameCountMismatch\n" },
    .{ .name = "FLAC that decodes short of STREAMINFO to raw PCM", .set = .flac, .args = &.{"-i"}, .input = "flac_junk_between_frames", .tail = &.{ "-f", "s16le", "-" }, .exit_code = 0, .stdout_contains = "", .stderr = "" },
    .{ .name = "CAF output is unsupported", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-f", "caf", "-" }, .exit_code = 3, .stderr = "zffmpeg: caf: unsupported output format\n" },
    // T26c: FLAC output, the ffmpeg program's block size (the input's first
    // frame) and FFmpeg's header; standard output cannot seek back, so its
    // STREAMINFO stays as first written.
    .{ .name = "FLAC to FLAC on standard output", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-compression_level", "8", "-f", "flac", "-" }, .exit_code = 0, .stdout_contains = "fLaC\x00\x00\x00\x22\x04\x80\x04\x80", .stderr = "" },
    .{ .name = "FLAC in WAV is unsupported", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-c:a", "flac", "-f", "wav", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "FLAC copy into FLAC is unsupported", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-c", "copy", "-f", "flac", "-" }, .exit_code = 3, .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "a FLAC first frame under 16 samples", .args = &.{"-i"}, .input = "mono_8k", .tail = &.{ "-f", "flac", "-" }, .exit_code = 3, .stdout = "", .stderr_contains = ": UnsupportedFormat\n" },
    .{ .name = "an invalid FLAC encoder option value", .args = &.{ "-i", "a.wav", "-lpc_type", "burg", "b.flac" }, .exit_code = 1, .stderr_contains = "invalid value for: -lpc_type\n" },
    // T27b: FLAC encoded into Ogg; compare.py checks the bytes against FFmpeg's.
    .{ .name = "FLAC into Ogg on standard output", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-f", "ogg", "-" }, .exit_code = 0, .stdout_contains = "OggS\x00\x02", .stderr = "" },
    .{ .name = "FLAC into Ogg Audio carries the encoder tag", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-f", "oga", "-" }, .exit_code = 0, .stdout_contains = "\x11\x00\x00\x00encoder=Lavc flac", .stderr = "" },
    .{ .name = "Ogg Opus asks for an Opus encoder", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-f", "opus", "-" }, .exit_code = 3, .stdout = "", .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "PCM in Ogg is unsupported", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-c:a", "pcm_s16le", "-f", "ogg", "-" }, .exit_code = 3, .stdout = "", .stderr_contains = ": UnsupportedOperation\n" },
    .{ .name = "FLAC encoder options FFmpeg refuses together", .set = .flac, .args = &.{"-i"}, .input = "flac_ffmpeg_level5_stereo", .tail = &.{ "-min_prediction_order", "9", "-max_prediction_order", "8", "-f", "flac", "-" }, .exit_code = 1, .stderr_contains = ": InvalidOption\n" },
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
    const registry_dump = b.addExecutable(.{
        .name = "registry-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/testing/registry_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "av", .module = av }},
        }),
    });
    const hash_driver = b.addExecutable(.{
        .name = "hash-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig/testing/hash_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "av", .module = av }},
        }),
    });
    const test_tools = b.step("test-tools", "Install the test tools that compare.py runs");
    for ([_]*std.Build.Step.Compile{ write_driver, registry_dump, hash_driver }) |tool| {
        test_tools.dependOn(&b.addInstallArtifact(tool, .{}).step);
        test_step.dependOn(&tool.step);
    }
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
