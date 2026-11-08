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
//! (`AVPROBE_SCORE_RETRY`), doubling its probe buffer up to `probe_max`
//! (1 MiB) and accepting a low score only at the end of the input or of that
//! buffer (`av_probe_input_buffer2`); this file does the same since T29a,
//! because MP3's probe looks as far as the buffer goes. Before scoring, a
//! leading ID3v2 tag is skipped for every probe, as
//! `av_probe_input_format3` skips it; then the formats with
//! `FF_INFMT_FLAG_ID3V2_AUTO` read the tags before their header, as
//! avformat_open_input does (`Input.readLeadingTags`: WAV and FLAC here,
//! the MP3 demuxer itself), and the others start at the tag (T30a). A
//! demuxer without a probe (a format without a content signature) is never
//! chosen by content.
//!
//! A file name, when the caller has one, adds FFmpeg's extension hints
//! (`av_match_ext`): a demuxer without a probe whose extension matches scores
//! 50 (`AVPROBE_SCORE_EXTENSION`), so the raw PCM formats (T22c) are chosen
//! by name only when no content probe recognizes the stream, and a probing
//! demuxer's match scores at least 1 (FLAC's `flac`). MIME types (HTTP only)
//! are not ported.

const std = @import("std");
const audio = @import("../core/audio.zig");
const pcm = @import("../codec/pcm.zig");
const metadata = @import("../core/metadata.zig");
const wav = @import("wav.zig");
const au = @import("au.zig");
const aiff = @import("aiff.zig");
const raw = @import("raw.zig");
const caf = @import("caf.zig");
const alac = @import("../codec/alac.zig");
const flac = @import("flac.zig");
const ogg = @import("ogg.zig");
const mp3 = @import("mp3.zig");
const aac = @import("aac.zig");
const ac3 = @import("ac3.zig");
const mov = @import("mov.zig");
const rational = @import("../core/rational.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");
const codecs = @import("../codec/registry.zig");
const registry = @import("registry.zig");
const Replay = @import("replay.zig").Replay;
const id3v2 = @import("id3v2.zig");
const skip = @import("../io/skip.zig");

pub const Container = registry.Container;

/// The WAV, AU, AIFF, raw PCM, CAF and FLAC contract errors, which share
/// their common names, `UnknownFormat` for a stream no demuxer recognizes,
/// and `UnusedOption`.
pub const Error = wav.Error || au.Error || aiff.Error || raw.Error || caf.Error || flac.Error || ogg.Error || mp3.Error || aac.Error || mov.Error || error{
    /// No demuxer's probe scored the stream, as FFmpeg's "Invalid data found
    /// when processing input"; force a format to parse it anyway.
    UnknownFormat,
    /// FFmpeg's Vorbis decoder refuses the stream's headers, so ffprobe
    /// cannot open it ("Could not open codec", T27d).
    InvalidVorbis,
    /// FFmpeg's Opus decoder refuses the OpusHead, so ffprobe cannot open
    /// it (T28a).
    InvalidOpus,
    /// More than two thirds of an Ogg stream's decodes failed, which the
    /// ffmpeg program's `-max_error_rate` fails (T27d).
    DecodeErrorRate,
    /// Raw PCM parameters were given for an input whose format has its own.
    UnusedOption,
};

pub const Limits = struct {
    /// The largest leading ID3v2 tag read for its tags before a WAV or
    /// FLAC demuxer (`Input.readLeadingTags`), as MP3's limit
    /// (`mp3.Limits.max_id3v2_bytes`); a tag only skipped has none.
    max_id3v2_bytes: u32 = 64 << 20,
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
    /// The probed reader's own seeker, when it can seek (a file read from
    /// its start): Ogg's durations come from scans of the whole input, as
    /// FFmpeg's ogg_get_length makes them on a seekable input (T27a).
    seeker: ?seek.Seeker = null,
    /// For a probe buffer past the first 2048 bytes (FFmpeg's retries).
    gpa: ?std.mem.Allocator = null,
};

/// FFmpeg's first probe size (`PROBE_BUF_MIN`).
pub const probe_len = 2048;

/// `AVPROBE_SCORE_MAX`.
const max_score = 100;
/// `AVPROBE_SCORE_EXTENSION`: a probe-less demuxer whose extension matches.
const extension_score = 50;

/// `PROBE_BUF_MAX`: probing's largest buffer.
pub const probe_max = 1 << 20;
/// `AVPROBE_SCORE_RETRY`: a score at most this asks for more data.
const retry_score = max_score / 4;

/// FFmpeg's winner for a stream whose bytes are all `head` (named
/// `file_name`, null when it has none): `av_probe_input_buffer2`'s rounds
/// over growing prefixes of it.
pub fn probeHead(head: []const u8, file_name: ?[]const u8) ?Container {
    var rounds: Rounds = .{};
    while (true) {
        const want = rounds.probe_size - rounds.buf_offset;
        const got = @min(want, head.len - rounds.buf_offset);
        if (rounds.step(head[0 .. rounds.buf_offset + got], got, want, file_name)) |result| return result;
    }
}

/// `av_probe_input_buffer2`'s loop: a probe buffer of 2048 bytes, doubled
/// each round up to 1 MiB, the winner taken when it scores above 25, or
/// above 0 once a read finds the end or the buffer is at its largest.
const Rounds = struct {
    probe_size: usize = probe_len,
    buf_offset: usize = 0,

    /// One round with `buf`, the bytes read so far, `got` of the `want`
    /// this round asked for. Null asks for another round; otherwise the
    /// outcome, a container or none.
    fn step(r: *Rounds, buf: []const u8, got: usize, want: usize, file_name: ?[]const u8) ??Container {
        var threshold: u8 = if (r.probe_size < probe_max) retry_score else 0;
        // avio_read's AVERROR_EOF: nothing more to read.
        const at_end = want > 0 and got == 0;
        if (at_end) threshold = 0;
        r.buf_offset += got;
        const result = probeRound(&registry.formats, buf, file_name);
        if (result.score > threshold) {
            if (result.container) |c| return c;
        }
        if (at_end or r.probe_size >= probe_max) return @as(?Container, null);
        r.probe_size = @min(r.probe_size * 2, probe_max);
        return null;
    }
};

const Round = struct { container: ?Container, score: u8 };

/// `probe_input_format_internal`: the demuxers' scores for `buf` after the
/// ID3v2 tags it can skip, the highest one's container (none on a tie), and
/// the extension hints, which an ID3v2 tag longer than the buffer raises.
fn probeRound(formats: []const registry.Format, buf_in: []const u8, file_name: ?[]const u8) Round {
    const NoData = enum { no_id3, almost_greater, greater, greater_max };
    var nodat: NoData = .no_id3;
    var buf = buf_in;
    while (buf.len > 10 and id3v2.match(buf)) {
        const id3len = id3v2.tagLen(buf[0..id3v2.header_size]);
        if (buf.len > @as(u64, id3len) + 16) {
            if (buf.len < 2 * @as(u64, id3len) + 16) nodat = .almost_greater;
            buf = buf[id3len..];
        } else if (id3len >= probe_max) {
            nodat = .greater_max;
            break;
        } else {
            nodat = .greater;
            break;
        }
    }
    var best: u8 = 0;
    var chosen: ?Container = null;
    for (formats) |format| {
        const demuxer = format.demuxer orelse continue;
        const named = if (file_name) |name| registry.matchesExtension(name, demuxer.extensions) else false;
        var score: u8 = 0;
        if (demuxer.probe) |score_buf| {
            score = score_buf(buf);
            if (named) score = switch (nodat) {
                .no_id3 => @max(score, 1),
                .greater, .almost_greater => @max(score, extension_score / 2 - 1),
                .greater_max => @max(score, extension_score),
            };
        } else if (named) score = extension_score;
        std.debug.assert(score <= max_score);
        if (score > best) {
            best = score;
            chosen = format.container;
        } else if (score == best) {
            chosen = null;
        }
    }
    if (nodat == .greater) best = @min(extension_score / 2 - 1, best);
    return .{ .container = chosen, .score = best };
}

/// A stream opened for parsing: its format, and a reader that replays the
/// bytes probing read before the rest of the source.
pub const Input = struct {
    head_buffer: [probe_len]u8,
    /// Bytes read past the probe buffer that `readLeadingTags` gives back:
    /// a header that was not a tag's, or the end of a tag's body that
    /// `id3v2_parse` stopped before.
    pending: [id3v2.header_size]u8 = undefined,
    /// The probe buffer once probing read more than `probe_len` bytes.
    extra: ?[]u8 = null,
    gpa: ?std.mem.Allocator = null,
    replay: Replay,
    container: Container,
    /// The container came from the caller, not from probing.
    forced: bool,
    source: Source,

    /// Probes `reader`, or with `source.format` takes that format without
    /// reading anything. Fills `input` in place; it must not move afterward,
    /// because `reader` points into it. Only a failing reader, a stream no
    /// demuxer recognizes, or raw parameters for another format are errors.
    ///
    /// Probing reads more than the first `probe_len` bytes only for a
    /// stream every demuxer scores at most 25 (FFmpeg's retries, up to
    /// 1 MiB); that buffer comes from `source.gpa`, without which such a
    /// stream is `OutOfMemory`. `deinit` frees it.
    pub fn open(input: *Input, reader_in: *std.Io.Reader, source: Source) error{ IoFailure, UnknownFormat, UnusedOption, OutOfMemory }!void {
        input.* = .{
            .head_buffer = undefined,
            // A forced format reads nothing, so it never needs the allocator.
            .gpa = if (source.format == null) source.gpa else null,
            .replay = .init(&.{}, reader_in),
            .container = source.format orelse undefined,
            .forced = source.format != null,
            .source = source,
        };
        // One guard for every failure from here on: the raw-option check
        // below runs after probing may have grown `extra`.
        errdefer input.deinit();
        if (source.format == null) {
            var rounds: Rounds = .{};
            var end_seen = false;
            const chosen = while (true) {
                const want = rounds.probe_size - rounds.buf_offset;
                var got: usize = 0;
                // A short read was the end: the next one reads nothing.
                if (!end_seen) {
                    const buf = try input.probeBuffer(rounds.probe_size);
                    got = reader_in.readSliceShort(buf[rounds.buf_offset..rounds.probe_size]) catch return error.IoFailure;
                    if (got < want) end_seen = true;
                }
                const bytes = input.probed(rounds.buf_offset + got);
                if (rounds.step(bytes, got, want, source.file_name)) |result| break result;
            };
            input.replay = .init(input.probed(rounds.buf_offset), reader_in);
            input.container = chosen orelse return error.UnknownFormat;
        }
        if (source.raw != null and input.container.family() != .raw) return error.UnusedOption;
    }

    pub fn deinit(input: *Input) void {
        if (input.extra) |b| input.gpa.?.free(b);
        input.extra = null;
    }

    /// The probe buffer with room for `size` bytes, its bytes kept.
    fn probeBuffer(input: *Input, size: usize) error{OutOfMemory}![]u8 {
        if (size <= probe_len) return &input.head_buffer;
        const gpa = input.gpa orelse return error.OutOfMemory;
        if (input.extra) |old| {
            if (old.len >= size) return old;
            const grown = try gpa.realloc(old, size);
            input.extra = grown;
            return grown;
        }
        const buf = try gpa.alloc(u8, size);
        @memcpy(buf[0..probe_len], &input.head_buffer);
        input.extra = buf;
        return buf;
    }

    /// The first `len` bytes probing read.
    fn probed(input: *const Input, len: usize) []const u8 {
        return if (input.extra) |b| b[0..len] else input.head_buffer[0..len];
    }

    pub fn reader(input: *Input) *std.Io.Reader {
        return &input.replay.interface;
    }

    /// avformat_open_input's `ff_id3v2_read_dict` before a demuxer with
    /// `FF_INFMT_FLAG_ID3V2_AUTO` (WAV and FLAC here; the MP3 demuxer reads
    /// its own): every ID3v2 tag that follows the one before, from the
    /// stream's start, each resumed after where `id3v2_parse` stops. With
    /// `gpa` the tags are parsed (one larger than `max_bytes` is
    /// `LimitExceeded`); without, only skipped. The reader then serves the
    /// bytes after them.
    pub fn readLeadingTags(input: *Input, gpa: ?std.mem.Allocator, max_bytes: u32) LeadingTags.Error!LeadingTags {
        var result: LeadingTags = .{ .id3 = if (gpa) |g| .init(g) else null };
        errdefer result.deinit();
        while (true) {
            var header: [id3v2.header_size]u8 = undefined;
            const r = &input.replay;
            const in_head = r.head.len - r.pos;
            if (in_head >= header.len) {
                header = r.head[r.pos..][0..header.len].*;
                if (!id3v2.match(&header)) break;
                r.pos += header.len;
            } else {
                // The probe buffer ends inside the header: its rest and the
                // source's next bytes, served again unless they are a tag's.
                @memcpy(input.pending[0..in_head], r.head[r.pos..]);
                const got = in_head + (r.source.readSliceShort(input.pending[in_head..]) catch return error.IoFailure);
                input.replay = .init(input.pending[0..got], r.source);
                if (got < header.len or !id3v2.match(&input.pending)) break;
                header = input.pending;
                input.replay.pos = header.len;
            }
            result.len += header.len;
            const body_len = id3v2.bodyLen(&header);
            // Read the body (only its first bytes when skipping), noting
            // whether all of it came from the replayed head, where a stop
            // before its end rewinds.
            const head_left = input.replay.head.len - input.replay.pos;
            var prefix: [4]u8 = undefined;
            var body: []u8 = &.{};
            defer if (result.id3) |*id3| id3.gpa.free(body);
            var read: []const u8 = undefined;
            if (result.id3) |*id3| {
                if (body_len > max_bytes) return error.LimitExceeded;
                body = try id3.gpa.alloc(u8, body_len);
                read = body[0 .. input.reader().readSliceShort(body) catch return error.IoFailure];
            } else {
                read = prefix[0 .. input.reader().readSliceShort(prefix[0..@min(prefix.len, body_len)]) catch return error.IoFailure];
            }
            const resume_at = if (result.id3) |*id3| try id3.parseTag(&header, read) else id3v2.resumeLen(&header, read);
            result.len += resume_at;
            if (resume_at >= read.len) {
                skip.discardAll(input.reader(), resume_at - read.len) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return error.IoFailure,
                };
                continue;
            }
            // Stopped before the bytes read (at most a footer's 10): serve
            // them again.
            const back: usize = @intCast(read.len - resume_at);
            if (read.len <= head_left) {
                input.replay.pos -= back;
            } else {
                @memcpy(input.pending[0..back], read[@intCast(resume_at)..]);
                input.replay = .init(input.pending[0..back], input.replay.source);
            }
        }
        if (result.id3) |*id3| try id3.finish();
        return result;
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

/// The ID3v2 tags `Input.readLeadingTags` read.
pub const LeadingTags = struct {
    /// The bytes the tags took, as `id3v2_parse` resumed after each.
    len: u64 = 0,
    /// Their tags, when parsed.
    id3: ?id3v2.Reader = null,

    pub const Error = error{ IoFailure, LimitExceeded } || std.mem.Allocator.Error;

    pub fn deinit(t: *LeadingTags) void {
        if (t.id3) |*r| r.deinit();
        t.id3 = null;
    }

    /// avformat_open_input after the demuxer's header: the ID3v2 tags
    /// become the input's when the demuxer set none, else they are
    /// discarded ("Discarding ID3 tags because more suitable tags were
    /// found"); then the PRIV frames are added (`ff_id3v2_parse_priv`).
    /// `tags` uses the allocator the tags were read with.
    pub fn merge(t: *LeadingTags, tags: *metadata.Dictionary) std.mem.Allocator.Error!void {
        const r = if (t.id3) |*r| r else return;
        if (tags.count() == 0) std.mem.swap(metadata.Dictionary, tags, &r.tags);
        try r.addPriv(tags);
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
    /// For a stream whose time base is not 1/rate (MPEG audio's
    /// 1/14112000): its duration in that time base, ffprobe's
    /// `duration_ts`; `frame_count` is it in samples, rounded.
    time_base_duration: ?struct { ts: i64, den: u32 } = null,
};

pub const Options = struct {
    /// The format, file name, length and raw parameters the caller knows.
    source: Source = .{},
    /// Also add the stream's tags to the empty `tags.dictionary`, under
    /// FFmpeg's names (`wav.genericTags`): RIFF and RF64's INFO and `bext`,
    /// and FLAC's VORBIS_COMMENT (T26b). On failure the dictionary may hold
    /// some of them.
    tags: ?wav.Tags = null,
    /// The allocator Ogg's demuxer needs (T27a); else the tags'. An Ogg
    /// input without either is `UnsupportedFormat`.
    gpa: ?std.mem.Allocator = null,
};

/// Detects the container, then validates the whole stream without decoding
/// its samples.
pub fn probe(reader: *std.Io.Reader, limits: Limits) Error!Probed {
    return probeWith(reader, limits, .{});
}

/// `probe`, with what the caller knows about the source, or tags.
pub fn probeWith(reader: *std.Io.Reader, limits: Limits, options: Options) Error!Probed {
    var input: Input = undefined;
    var source = options.source;
    if (source.gpa == null) source.gpa = options.gpa orelse if (options.tags) |t| t.gpa else null;
    try input.open(reader, source);
    defer input.deinit();
    switch (input.container.family()) {
        .wav => {
            var leading: LeadingTags = if (input.container.readsLeadingId3v2())
                try input.readLeadingTags(if (options.tags) |t| t.gpa else null, limits.max_id3v2_bytes)
            else
                .{};
            defer leading.deinit();
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
                try leading.merge(t.dictionary);
            }
            std.debug.assert(Container.ofWav(info.variant) == input.container);
            // ADPCM (T31a): the decoder's sample format, the demuxer's
            // duration. ffprobe opens the decoder, and fails when it refuses
            // the stream ("Invalid number of channels", IMA WAV bits
            // outside 2 to 5).
            if (info.adpcm) |a| a.params.check() catch return error.UnsupportedFormat;
            const codec: codecs.Codec = if (info.adpcm) |a| switch (a.params.codec) {
                .ima_wav => .adpcm_ima_wav,
                .ms => .adpcm_ms,
            } else .{ .pcm = info.codec };
            return .{ .container = input.container, .codec = codec, .format = info.format, .frame_count = info.frame_count };
        },
        .au => {
            var parser: au.Parser = .init(input.reader(), limits.au);
            const info = try parser.readHeader();
            try parser.finish();
            // G.722 and G.726 (T31c): the decoders' mono s16, the
            // demuxer's duration.
            const codec: codecs.Codec = if (info.g72x) |g| switch (g.codec) {
                .g722 => .adpcm_g722,
                .g726le => .adpcm_g726le,
            } else .{ .pcm = info.codec };
            return .{ .container = .au, .codec = codec, .format = info.format, .frame_count = info.frame_count };
        },
        .aiff => {
            var parser: aiff.Parser = .init(input.reader(), limits.aiff);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = .aiff, .codec = .{ .pcm = info.codec }, .format = info.format, .frame_count = info.frame_count };
        },
        .caf => {
            // ALAC (T31b) needs an allocator for the packet table, and a
            // table after the samples a seekable input read from its start.
            const gpa = options.gpa orelse if (options.tags) |t| t.gpa else null;
            var parser: caf.Parser = if (gpa != null and options.source.seeker != null) seekable: {
                const sk = options.source.seeker.?;
                sk.seekTo(0) catch return error.IoFailure;
                break :seekable .init(reader, limits.caf);
            } else .init(input.reader(), limits.caf);
            if (gpa) |g| parser.enableAlac(g, options.source.seeker);
            defer parser.deinit();
            const info = try parser.readHeader();
            if (info.alac) |a| {
                // ffprobe opens the decoder, and fails when it refuses the
                // stream: no cookie, a sample size or channel count it does
                // not take.
                const cookie = a.cookie orelse return error.UnsupportedFormat;
                _ = alac.Config.parse(&cookie, a.channels) catch return error.UnsupportedFormat;
                var buffer: [4096]u8 = undefined;
                const big = if (a.max_packet > buffer.len) try gpa.?.alloc(u8, a.max_packet) else null;
                defer if (big) |b| gpa.?.free(b);
                const packet_buffer = big orelse buffer[0..];
                while (try parser.nextPacket(packet_buffer)) |_| {}
            }
            try parser.finish();
            const codec: codecs.Codec = if (info.alac != null) .alac else .{ .pcm = info.codec };
            return .{ .container = .caf, .codec = codec, .format = info.format, .frame_count = info.frame_count };
        },
        .raw => {
            var parser = input.rawParser(limits.raw);
            const info = try parser.readHeader();
            try parser.finish();
            return .{ .container = input.container, .codec = .{ .pcm = info.codec }, .format = info.format, .frame_count = parser.framesRead() };
        },
        .flac => {
            // The frames are the decoder's to check; FFmpeg's probe reads
            // the header, and the duration comes from STREAMINFO. Tags come
            // from VORBIS_COMMENT (T26b), else a leading ID3v2 tag.
            std.debug.assert(input.container.readsLeadingId3v2());
            var leading = try input.readLeadingTags(if (options.tags) |t| t.gpa else null, limits.max_id3v2_bytes);
            defer leading.deinit();
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
                try leading.merge(t.dictionary);
            }
            return probed;
        },
        .ogg => return probeOgg(reader, &input, options),
        .mp3 => return probeMp3(reader, &input, options),
        .aac => return probeAac(reader, &input, options),
        .ac3 => return probeAc3(reader, &input, options),
        .mov => return probeMov(reader, &input, options),
        // Output only (T29d): detection never names it, nor does a forced
        // input format (`findDemuxer`).
        .mp2, .adts => return error.UnsupportedFormat,
    }
}

/// The decoded stream of a FLAC input: packed s16 or s32 in FFmpeg's
/// layout; a rate neither STREAMINFO nor the first frame gives is
/// `UnsupportedFormat`.
/// Ogg (T27a): the demuxer and libavformat's read-ahead, as ffprobe opens
/// the input; the first stream with a known codec, as `-select_streams
/// a:0` reports it. Ogg's comments are stream tags, and the format has
/// none, so no tags are added.
fn probeOgg(reader: *std.Io.Reader, input: *Input, options: Options) Error!Probed {
    const gpa = options.gpa orelse if (options.tags) |t| t.gpa else return error.UnsupportedFormat;
    const d = if (options.source.seeker) |sk| blk: {
        // Read from the start through the reader itself, which seeks.
        sk.seekTo(0) catch return error.IoFailure;
        break :blk try ogg.Demuxer.initSeekable(gpa, reader, sk);
    } else try ogg.Demuxer.init(gpa, input.reader());
    defer d.deinit();
    var layer = demux.Layer(ogg.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    for (0..d.streamCount()) |i| {
        const info = d.stream(i);
        const codec: codecs.Codec = switch (info.codec orelse continue) {
            .flac => .flac,
            .vorbis => .vorbis,
            .opus => .opus,
        };
        // ffprobe opens the decoder: FLAC's gives its storage and layout,
        // Vorbis' and Opus' planar float and their layouts, and refuse
        // what they cannot parse.
        if (codec == .vorbis and info.decoder_refuses) return error.InvalidVorbis;
        if (codec == .opus and info.decoder_refuses) return error.InvalidOpus;
        const sample_format: audio.SampleFormat = switch (codec) {
            .flac => if (flacBps(info) > 16) .s32 else .s16,
            .vorbis, .opus => .fltp,
            else => .s16,
        };
        const layout: audio.ChannelLayout = switch (codec) {
            .flac => flac_codec.channelLayout(info.channels),
            .vorbis => vorbis_codec.channelLayout(info.channels),
            .opus => (opus_dec.Head.parse(info.extradata.items) catch return error.UnsupportedFormat).layout,
            else => .{ .unspecified = info.channels },
        };
        return .{
            .container = .ogg,
            .codec = codec,
            .format = audio.Format.initLayout(info.sample_rate, layout, sample_format) catch return error.UnsupportedFormat,
            .frame_count = if (info.duration >= 0) @intCast(info.duration) else null,
        };
    }
    return error.UnsupportedFormat;
}

/// MPEG audio (T29a): the demuxer and libavformat's read-ahead, as ffprobe
/// opens the input, without a decoder: the parser's codec, rate and
/// channels (FFmpeg's default layout for the count), no sample format, and
/// the duration in the stream's 1/14112000 time base. The format's tags
/// (ID3v2, else ID3v1, and PRIV) are the input's.
fn probeMp3(reader: *std.Io.Reader, input: *Input, options: Options) Error!Probed {
    const gpa = options.gpa orelse if (options.tags) |t| t.gpa else return error.UnsupportedFormat;
    const d = if (options.source.seeker) |sk| blk: {
        sk.seekTo(0) catch return error.IoFailure;
        break :blk try mp3.Demuxer.initSeekable(gpa, reader, sk, .{});
    } else try mp3.Demuxer.init(gpa, input.reader(), .{});
    defer d.deinit();
    var layer = demux.Layer(mp3.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    const params = try layer.codecParams(0);
    if (params.sample_rate == 0 or params.channels == 0) return error.UnsupportedFormat;
    const codec: codecs.Codec = switch (params.mpa_codec orelse .mp3) {
        .mp1 => .mp1,
        .mp2 => .mp2,
        .mp3 => .mp3,
    };
    if (options.tags) |t| {
        std.debug.assert(t.dictionary.count() == 0);
        std.mem.swap(metadata.Dictionary, t.dictionary, &d.tags);
    }
    const duration = d.info.duration;
    return .{
        .container = .mp3,
        .codec = codec,
        // fltp, the sample format the reference build's mp3float decoder
        // sets when avformat_find_stream_info opens it, for MP1 and MP2 as
        // well: the demuxer starts every stream as mp3 and the parser names
        // the layer only after that open (notes.md "MP3").
        .format = audio.Format.initLayout(params.sample_rate, .default(params.channels), .fltp) catch return error.UnsupportedFormat,
        .frame_count = if (duration >= 0) @intCast(rational.rescale(duration, params.sample_rate, mp3.time_base.den)) else null,
        .time_base_duration = if (duration >= 0) .{ .ts = duration, .den = @intCast(mp3.time_base.den) } else null,
    };
}

/// ADTS (T30a, T30b): the demuxer and libavformat's read-ahead, which
/// decodes the first packets with FFmpeg's AAC decoder, as ffprobe opens the
/// input: the decoder's rate, channels and layout, planar float, and the
/// duration in the stream's 1/28224000 time base. A stream no packet of
/// which decodes has no rate (ffprobe prints 0): `UnsupportedFormat`
/// (notes.md "AAC decoder scope"). The format's tags (ID3v1, else APE, else
/// ID3v2) are the input's.
fn probeAac(reader: *std.Io.Reader, input: *Input, options: Options) Error!Probed {
    const gpa = options.gpa orelse if (options.tags) |t| t.gpa else return error.UnsupportedFormat;
    const d = if (options.source.seeker) |sk| blk: {
        sk.seekTo(0) catch return error.IoFailure;
        break :blk try aac.Demuxer.initSeekable(gpa, reader, sk, .{});
    } else try aac.Demuxer.init(gpa, input.reader(), .{});
    defer d.deinit();
    var layer = demux.Layer(aac.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    const params = try layer.codecParams(0);
    if (params.sample_rate == 0 or params.channels == 0) return error.UnsupportedFormat;
    const layout: audio.ChannelLayout = if (params.mask != 0)
        .{ .native = params.mask }
    else
        .{ .unspecified = std.math.cast(u8, params.channels) orelse return error.UnsupportedFormat };
    if (options.tags) |t| {
        std.debug.assert(t.dictionary.count() == 0);
        std.mem.swap(metadata.Dictionary, t.dictionary, &d.tags);
    }
    const duration = d.duration;
    return .{
        .container = .aac,
        .codec = .aac,
        .format = audio.Format.initLayout(params.sample_rate, layout, .fltp) catch return error.UnsupportedFormat,
        .frame_count = if (duration >= 0) @intCast(rational.rescale(duration, params.sample_rate, aac.time_base.den)) else null,
        .time_base_duration = if (duration >= 0) .{ .ts = duration, .den = @intCast(aac.time_base.den) } else null,
    };
}

/// Raw AC-3 (T32a): the demuxer and libavformat's read-ahead, whose
/// parser gives the rate, channels and layout and whose decoder sets planar
/// float when it opens, as ffprobe opens the input, and the duration in the
/// 1/90000 time base (estimated from the bit rate). A stream none of whose
/// frames the parser checked has no rate: `UnsupportedFormat`, as ffprobe
/// prints none.
fn probeAc3(reader: *std.Io.Reader, input: *Input, options: Options) Error!Probed {
    const gpa = options.gpa orelse if (options.tags) |t| t.gpa else return error.UnsupportedFormat;
    const codec: ac3.Codec = if (input.container == .eac3) .eac3 else .ac3;
    const d = if (options.source.seeker) |sk| blk: {
        sk.seekTo(0) catch return error.IoFailure;
        break :blk try ac3.Demuxer.initSeekable(gpa, reader, sk, codec);
    } else try ac3.Demuxer.init(gpa, input.reader(), codec);
    defer d.deinit();
    var layer = demux.Layer(ac3.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    const params = try layer.codecParams(0);
    if (params.sample_rate == 0 or params.channels == 0) return error.UnsupportedFormat;
    const layout: audio.ChannelLayout = if (params.mask != 0)
        .{ .native = params.mask }
    else
        .{ .unspecified = std.math.cast(u8, params.channels) orelse return error.UnsupportedFormat };
    const duration = d.duration;
    return .{
        .container = input.container,
        // The parser names E-AC-3 once it meets a frame of it.
        .codec = if (codec == .eac3 or params.eac3) .eac3 else .ac3,
        .format = audio.Format.initLayout(params.sample_rate, layout, .fltp) catch return error.UnsupportedFormat,
        .frame_count = if (duration >= 0) @intCast(rational.rescale(duration, params.sample_rate, ac3.time_base.den)) else null,
        .time_base_duration = if (duration >= 0) .{ .ts = duration, .den = @intCast(ac3.time_base.den) } else null,
    };
}

/// MP4 and QuickTime (T33a1): the demuxer and libavformat's read-ahead,
/// as ffprobe opens the input; the first audio track, as `-select_streams
/// a:0` reports it, with the sample format its decoder gives. A codec the
/// port has no decoder for is `UnsupportedFormat`. The format's tags are
/// the input's (`ftyp`, `mvhd`).
fn probeMov(reader: *std.Io.Reader, input: *Input, options: Options) Error!Probed {
    const gpa = options.gpa orelse if (options.tags) |t| t.gpa else return error.UnsupportedFormat;
    const d = if (options.source.seeker) |sk| blk: {
        sk.seekTo(0) catch return error.IoFailure;
        break :blk try mov.Demuxer.initSeekable(gpa, reader, sk, .{});
    } else try mov.Demuxer.init(gpa, input.reader(), .{});
    defer d.deinit();
    var layer = demux.Layer(mov.Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    for (0..d.streamCount()) |i| {
        const info = try mov.streamInfo(d, &layer, i);
        if (info.media != .audio) continue;
        const codec = codecs.find(info.codec) orelse return error.UnsupportedFormat;
        const rate = std.math.cast(u32, info.sample_rate) orelse return error.UnsupportedFormat;
        if (rate == 0 or info.time_base.num != 1) return error.UnsupportedFormat;
        // The decoders' sample formats, as ffprobe reports them once
        // avformat_find_stream_info opened them.
        const sample_format: audio.SampleFormat = switch (codec) {
            .pcm => |p| p.storage(),
            .flac => if (info.extradata.len >= flac_codec.streaminfo_size and
                flac_codec.StreamInfo.parse(info.extradata[0..flac_codec.streaminfo_size]).bps > 16) .s32 else .s16,
            .alac => blk: {
                const config = alac.Config.parse(info.extradata, info.layout.channelCount()) catch return error.UnsupportedFormat;
                break :blk if (config.sample_size == 16) .s16p else .s32p;
            },
            else => .fltp,
        };
        if (options.tags) |t| {
            std.debug.assert(t.dictionary.count() == 0);
            std.mem.swap(metadata.Dictionary, t.dictionary, &d.tags);
        }
        const den = std.math.cast(u32, info.time_base.den) orelse return error.UnsupportedFormat;
        return .{
            .container = .mov,
            .codec = codec,
            .format = audio.Format.initLayout(rate, info.layout, sample_format) catch return error.UnsupportedFormat,
            .frame_count = if (info.duration >= 0) @intCast(rational.rescale(info.duration, rate, den)) else null,
            .time_base_duration = if (info.duration >= 0) .{ .ts = info.duration, .den = den } else null,
        };
    }
    return error.UnsupportedFormat;
}

/// The bits per sample of an Ogg FLAC stream's STREAMINFO.
fn flacBps(info: *const ogg.StreamInfo) u8 {
    const e = info.extradata.items;
    if (e.len < flac_codec.streaminfo_size) return 16;
    return flac_codec.StreamInfo.parse(e[0..flac_codec.streaminfo_size]).bps;
}

const flac_codec = @import("../codec/flac.zig");
const vorbis_codec = @import("../codec/vorbis.zig");
const opus_dec = @import("../codec/opusdec.zig");

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
    // A headerless FLAC stream scores 13: probing reads a second round,
    // which allocates.
    const got = probeWith(&source.interface, .{}, .{ .source = .{ .gpa = std.testing.allocator } });
    if (detected == null) return std.testing.expectError(error.UnknownFormat, got);
    if (comptime detected.? == .mp3) {
        // FFmpeg's MP3 probe claims a few tiny files of other formats
        // (T29a); its demuxer, which allocates, then finds no frames.
        var again: std.Io.Reader = .fixed(bytes);
        return std.testing.expectError(error.InvalidMp3, probeWith(&again, .{}, .{ .gpa = std.testing.allocator }));
    }
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
        // FFmpeg's MP3 probe claims two of them (T29a), as the manifest says.
        const detected: ?Container = if (fixture.detected) |d| containerOf(d) else null;
        try std.testing.expectEqual(detected, probeHead(bytes, null));
        try std.testing.expectEqual(detected, probeHead(bytes, fixture.name ++ ".raw"));
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
    // Without it, FFmpeg's MP3 probe finds a frame header in the bytes
    // and, at the end of the input, wins with a score of 1 (T29a).
    try std.testing.expectEqual(Container.mp3, probeHead(&rf64, null));
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
    const always: registry.Demuxer = .{ .probe = alwaysProbe };
    var both = [2]registry.Format{ Container.wav.format().*, Container.aiff.format().* };
    both[0].demuxer = always;
    both[1].demuxer = always;
    try std.testing.expectEqual(null, probeRound(&both, wav_bytes, null).container);
    // Two probe-less demuxers claiming one extension tie too.
    const twins = [2]registry.Format{ Container.alaw.format().*, Container.alaw.format().* };
    try std.testing.expectEqual(null, probeRound(&twins, undetected, "take.al").container);
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

test "raw parameters refused after a grown probe buffer free it" {
    // A leading ID3v2 tag declaring a 10000-byte body keeps every score at
    // or below 25, so probing reads past `probe_len` before the `.mp3`
    // extension chooses MP3; the raw parameters are then refused.
    var bytes: [5000]u8 = @splat(0);
    @memcpy(bytes[0..10], &[_]u8{ 'I', 'D', '3', 4, 0, 0, 0, 0, 78, 16 });
    var reader: std.Io.Reader = .fixed(&bytes);
    var input: Input = undefined;
    try std.testing.expectError(error.UnusedOption, input.open(&reader, .{
        .file_name = "x.mp3",
        .raw = .{},
        .gpa = std.testing.allocator,
    }));
    // A forced non-raw format with raw parameters is refused the same way.
    var forced: std.Io.Reader = .fixed(&bytes);
    try std.testing.expectError(error.UnusedOption, input.open(&forced, .{ .format = .wav, .raw = .{}, .gpa = std.testing.allocator }));
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
        // avformat_open_input's leading ID3v2 tags come first.
        .wav, .flac => {
            const lead = id3v2.leadingLen(bytes);
            var after: std.Io.Reader = .fixed(bytes[@intCast(@min(lead, bytes.len))..]);
            if (container.family() == .wav)
                try expectSameResult(wav.probe(&after, .{}), got, container)
            else
                try expectSameResult(flacProbe(&after), got, .flac);
        },
        // Ogg's, MP3's and MP4's demuxers need an allocator, which this
        // probe has not.
        .ogg, .mp3, .aac, .ac3, .mov => try std.testing.expectError(error.UnsupportedFormat, got),
        .raw, .mp2, .adts => unreachable, // no content probe chooses raw PCM or the output-only formats
    } else try std.testing.expectError(error.UnknownFormat, got);
}

test "fuzz: detection agrees with the direct parser on arbitrary input" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        hostile.fuzzSeed(fixtures.bytes("mono_8k"), &.{}),
        hostile.fuzzSeed(fixtures.au.bytes("au_mono_8k"), &.{}),
        hostile.fuzzSeed(fixtures.au.bytes("au_annotation_odd_length"), &.{}),
        hostile.fuzzSeed(fixtures.bytes("w64_alaw_mono_8k"), &.{}),
        hostile.fuzzSeed(fixtures.bytes("rf64"), &.{}),
        hostile.fuzzSeed(fixtures.aiff.bytes("aifc_sowt"), &.{}),
        hostile.fuzzSeed(fixtures.aiff.bytes("aiff_other_chunks"), &.{}),
        hostile.fuzzSeed(fixtures.caf.bytes("caf_chunks_around_data"), &.{}),
        hostile.fuzzSeed(fixtures.flac.bytes("flac_constant_mono_8k"), &.{}),
    } });
}

/// An ID3v2.3 tag of TIT2 `title`, then `padding` zeros; a v2.4 tag with
/// a footer when `footer` is set.
fn testTag(comptime title: []const u8, comptime padding: usize, comptime footer: bool) []const u8 {
    const text = "\x00" ++ title;
    const frame_size: [4]u8 = if (footer) .{ 0, 0, 0, text.len } else std.mem.toBytes(std.mem.nativeToBig(u32, text.len));
    const body = "TIT2" ++ frame_size ++ "\x00\x00" ++ text ++ @as([padding]u8, @splat(0));
    const size = [4]u8{ @truncate(body.len >> 21 & 0x7f), @truncate(body.len >> 14 & 0x7f), @truncate(body.len >> 7 & 0x7f), @truncate(body.len & 0x7f) };
    const flags: u8 = if (footer) 0x10 else 0;
    const version: u8 = if (footer) 4 else 3;
    const head = "ID3" ++ [_]u8{ version, 0, flags } ++ size;
    return head ++ body ++ if (footer) "3DI" ++ [_]u8{ version, 0, flags } ++ size else "";
}

test "WAV and FLAC open after leading ID3v2 tags, whose tags they take only when they have none" {
    const gpa = std.testing.allocator;
    const tags = comptime testTag("First", 0, false) ++ testTag("Second", 6000, true);
    const wav_mono = try std.mem.concat(gpa, u8, &.{ tags, fixtures.bytes("mono_8k") });
    defer gpa.free(wav_mono);
    const wav_info = try std.mem.concat(gpa, u8, &.{ tags, fixtures.bytes("info_tags") });
    defer gpa.free(wav_info);
    const flac_mono = try std.mem.concat(gpa, u8, &.{ tags, fixtures.flac.bytes("flac_constant_mono_8k") });
    defer gpa.free(flac_mono);
    const cases = .{
        .{ wav_mono, Container.wav, @as(?u64, 8), "First" },
        .{ wav_info, Container.wav, @as(?u64, 4), "Title" },
        .{ flac_mono, Container.flac, @as(?u64, 256), "First" },
    };
    inline for (cases) |case| {
        // The second tag runs past the probe buffer; a reader giving one
        // byte at a time serves it as a pipe would.
        var one_buffer: [16]u8 = undefined;
        var one: std.testing.Reader = .init(&one_buffer, &.{.{ .buffer = case[0] }});
        one.artificial_limit = .limited(1);
        for ([_]bool{ false, true }) |collect| {
            var reader: std.Io.Reader = .fixed(case[0]);
            var dictionary: metadata.Dictionary = .empty;
            defer dictionary.deinit(gpa);
            // The tags past the probe buffer make FFmpeg probe again with a
            // larger one, which takes the allocator.
            const options: Options = if (collect) .{ .tags = .{ .gpa = gpa, .dictionary = &dictionary } } else .{ .gpa = gpa };
            const probed = try probeWith(&reader, .{}, options);
            try std.testing.expectEqual(case[1], probed.container);
            try std.testing.expectEqual(case[2], probed.frame_count);
            if (collect) try std.testing.expectEqualStrings(case[3], dictionary.get("title").?);
        }
        try std.testing.expectEqual(case[2], (try probeWith(&one.interface, .{}, .{ .gpa = gpa })).frame_count);
    }
    // FFmpeg resumes a tag whose extended header is longer than the tag
    // before its footer, which is then neither a tag nor RIFF.
    const broken = "ID3\x04\x00\x50\x00\x00\x00\x08" ++ "\x00\x00\x00\x20" ++ "\x00\x00\x00\x00" ++ "3DI\x04\x00\x50\x00\x00\x00\x08";
    const stopped = try std.mem.concat(gpa, u8, &.{ broken, fixtures.bytes("mono_8k") });
    defer gpa.free(stopped);
    var stop: std.Io.Reader = .fixed(stopped);
    try std.testing.expectError(error.InvalidRiff, probe(&stop, .{}));
    // A tag read for its tags has a limit; one only skipped has none.
    var big: std.Io.Reader = .fixed(wav_mono);
    var dictionary: metadata.Dictionary = .empty;
    defer dictionary.deinit(gpa);
    try std.testing.expectError(error.LimitExceeded, probeWith(&big, .{ .max_id3v2_bytes = 100 }, .{ .tags = .{ .gpa = gpa, .dictionary = &dictionary } }));
    var skipped: std.Io.Reader = .fixed(wav_mono);
    try std.testing.expectEqual(8, (try probeWith(&skipped, .{ .max_id3v2_bytes = 100 }, .{ .gpa = gpa })).frame_count);
    // A tag claiming more than the input holds leaves nothing to parse
    // (probing gives such an input to MP3; `-f wav` forces it).
    var past: std.Io.Reader = .fixed((comptime testTag("Cut", 100, false))[0..60]);
    try std.testing.expectError(error.Truncated, probeWith(&past, .{}, .{ .source = .{ .format = .wav } }));
    try std.testing.expectEqual(tags.len, id3v2.leadingLen(wav_mono));
}

test "detection gives every ADTS fixture FFmpeg opens to the aac demuxer, by content or by its extension" {
    // ffprobe's format for each (`probe_score` 51, 50, 25 or 1); the two
    // it refuses are refused alike by the demuxer (vectors/aac.txt).
    const gpa = std.testing.allocator;
    inline for (fixtures.aac.all) |fixture| {
        var reader: std.Io.Reader = .fixed(fixtures.aac.bytes(fixture.name));
        var input: Input = undefined;
        try input.open(&reader, .{ .file_name = fixture.name ++ ".aac", .gpa = gpa });
        defer input.deinit();
        if (fixture.expected == .accept) std.testing.expectEqual(Container.aac, input.container) catch |err| {
            std.debug.print("aac fixture {s}\n", .{fixture.name});
            return err;
        };
    }
}

test "a failing reader reports IoFailure" {
    var reader: std.Io.Reader = .failing;
    try std.testing.expectError(error.IoFailure, probe(&reader, .{}));
}

const hostile = @import("../testing/hostile.zig");
