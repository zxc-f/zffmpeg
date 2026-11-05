// SPDX-License-Identifier: LGPL-2.1-or-later
// Derived from FFmpeg's libavformat/mp3dec.c (mp3_read_probe,
// mp3_read_header, mp3_parse_vbr_tags, mp3_parse_info_tag,
// mp3_parse_vbri_tag, mp3_parse_itunes_smpb, find_itunes_smpb,
// mp3_read_packet, check), demux_utils.c (ff_itunes_parse_smpb),
// replaygain.c (parse_value, ff_replaygain_export) and the ID3v2 reading
// of demux.c's avformat_open_input at the pinned reference revision.
// Copyright (c) 2003 Fabrice Bellard
// FFmpeg is free software; you can redistribute it and/or modify it under
// the terms of the GNU Lesser General Public License as published by the
// Free Software Foundation; either version 2.1 of the License, or (at your
// option) any later version.
//! FFmpeg's MPEG audio demuxer (TODO.md T29a), without decoding: the ID3v2
//! tags libavformat reads before it, ID3v1 at the end of a seekable input
//! when they gave no tag, the first frame's Xing, Info (with LAME's or
//! libavformat's extension) or VBRI header and an iTunSMPB comment for the
//! duration, bit rate and gapless counts, the resync to two consecutive
//! frames, then raw reads of 1024 bytes that demux.zig's layer splits
//! with FFmpeg's mpegaudio parser (codec/mpegaudio.zig).
//!
//! The source is read in order; what FFmpeg reads by seeking within its
//! I/O buffer (the first frame's headers, the 64 KiB resync window) is
//! held in memory, and only ID3v1 and seeking reposition the source.

const std = @import("std");
const metadata = @import("../core/metadata.zig");
const rational = @import("../core/rational.zig");
const mpegaudio = @import("../codec/mpegaudio.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");
const id3v1 = @import("id3v1.zig");
const id3v2 = @import("id3v2.zig");

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA: no two consecutive frames before the
    /// end of the input.
    InvalidMp3,
    /// An ID3v2 tag larger than `Limits.max_id3v2_bytes`.
    LimitExceeded,
    IoFailure,
    OutOfMemory,
};

pub const Limits = struct {
    /// The largest ID3v2 tag read (it is parsed in memory); FFmpeg reads
    /// any (notes.md "MP3").
    max_id3v2_bytes: u32 = 64 << 20,
};

pub const nopts: i64 = std.math.minInt(i64);
/// The lcm of every MPEG audio rate, mp3dec.c's stream time base.
pub const time_base: rational.Rational = .{ .num = 1, .den = 14112000 };

/// `MP3_PACKET_SIZE`.
const packet_size = 1024;
/// The resync's window: 64 KiB of starts and the frame after the last.
const resync_starts = 64 * 1024;
const resync_window = resync_starts + 4096;

pub const Packet = demux.SourcePacket;

/// `AVReplayGain`.
pub const ReplayGain = struct {
    track_gain: i32,
    track_peak: u32,
    album_gain: i32,
    album_peak: u32,
};

/// `PROBE_BUF_MAX`, FFmpeg's largest probe buffer.
pub const probe_buf_max = 1 << 20;

/// mp3_read_probe on a probe buffer (after any ID3v2 tag probing skipped):
/// the longest run of frames from each position, with fewer than three
/// header emulations inside each, the first run's from the first nonzero
/// byte, then FFmpeg's thresholds; a buffer that is mostly an ID3v2 tag
/// scores 12, or 48 once the buffer is at its largest.
pub fn probeScore(buf: []const u8) u8 {
    if (buf.len < 4) return 0;
    const end = buf.len - 4;
    var buf0: usize = 0;
    while (buf0 < end and buf[buf0] == 0) buf0 += 1;
    var max_frames: u32 = 0;
    var first_frames: u32 = 0;
    var max_framesizes: u64 = 0;
    var whole_used = false;
    var start = buf0;
    while (start < end) {
        var pos = start;
        var frames: u32 = 0;
        var framesizes: u64 = 0;
        while (pos < end) : (frames += 1) {
            const header = std.mem.readInt(u32, buf[pos..][0..4], .big);
            const h = mpegaudio.decodeHeader(header) orelse break;
            if (h.freeFormat()) break;
            const available = @min(h.frame_size, end - pos);
            var emulations: u32 = 0;
            var at = pos + 4;
            while (at < pos + available) : (at += 1) {
                const next_sync = std.mem.readInt(u32, buf[at..][0..4], .big);
                if (next_sync & mpegaudio.mp3_mask == header & mpegaudio.mp3_mask) emulations += 1;
            }
            if (emulations > 2) break;
            framesizes += h.frame_size;
            if (available < h.frame_size) {
                frames += 1;
                break;
            }
            pos += h.frame_size;
        }
        max_frames = @max(max_frames, frames);
        max_framesizes = @max(max_framesizes, framesizes);
        if (start == buf0) {
            first_frames = frames;
            // The run ended exactly at the buffer's end.
            if (pos == end + 4) whole_used = true;
        }
        start = pos + 1;
    }
    if (first_frames >= 7) return 50 + 2;
    if (max_frames > 200 and buf.len < 2 * max_framesizes) return 50;
    if (max_frames >= 4 and buf.len < 2 * max_framesizes) return 50 / 2;
    var head: [id3v2.header_size]u8 = @splat(0);
    const rest = buf[buf0..];
    @memcpy(head[0..@min(rest.len, head.len)], rest[0..@min(rest.len, head.len)]);
    if (id3v2.match(&head) and 2 * @as(u64, id3v2.tagLen(&head)) >= buf.len) return if (buf.len < probe_buf_max) 50 / 4 else 50 - 2;
    if (first_frames > 1 and whole_used) return 5;
    if (max_frames >= 1 and buf.len < 10 * max_framesizes) return 1;
    return 0;
}

/// The stream FFmpeg's demuxer sets up.
pub const StreamInfo = struct {
    duration: i64 = nopts,
    start_time: i64 = 0,
    /// codecpar's bit rate: the Xing tag's VBR rate, 0 otherwise.
    bit_rate: i64 = 0,
    start_skip_samples: i64 = 0,
    first_discard_sample: i64 = 0,
    last_discard_sample: i64 = 0,
    replaygain: ?ReplayGain = null,
    /// The stream's tags (LAME's `encoder`).
    tags: metadata.Dictionary = .empty,
};

/// The source with a window of bytes read ahead: `window` holds the bytes
/// from `window_start` up to where the reader is.
const Source = struct {
    reader: *std.Io.Reader,
    seeker: ?seek.Seeker,
    window: std.ArrayList(u8) = .empty,
    window_start: i64 = 0,
    eof: bool = false,

    fn deinit(s: *Source, gpa: std.mem.Allocator) void {
        s.window.deinit(gpa);
    }

    fn windowEnd(s: *const Source) i64 {
        return s.window_start + @as(i64, @intCast(s.window.items.len));
    }

    /// Reads ahead until the window reaches `end` or the input ends.
    fn fill(s: *Source, gpa: std.mem.Allocator, end: i64) Error!void {
        while (!s.eof and s.windowEnd() < end) {
            const want: usize = @intCast(@min(end - s.windowEnd(), 64 * 1024));
            const old = s.window.items.len;
            try s.window.resize(gpa, old + want);
            const n = s.reader.readSliceShort(s.window.items[old..]) catch return error.IoFailure;
            s.window.shrinkRetainingCapacity(old + n);
            if (n < want) s.eof = true;
        }
    }

    /// The bytes at `pos`, at most `len`: fewer at the end of the input.
    /// `pos` must not be before the window.
    fn bytesAt(s: *Source, gpa: std.mem.Allocator, pos: i64, len: usize) Error![]const u8 {
        std.debug.assert(pos >= s.window_start);
        try s.fill(gpa, pos + @as(i64, @intCast(len)));
        if (pos >= s.windowEnd()) return &.{};
        const at: usize = @intCast(pos - s.window_start);
        return s.window.items[at..][0..@min(len, s.window.items.len - at)];
    }

    /// Forgets the window's bytes before `pos`.
    fn drop(s: *Source, pos: i64) void {
        if (pos <= s.window_start) return;
        const n: usize = @intCast(@min(pos - s.window_start, @as(i64, @intCast(s.window.items.len))));
        std.mem.copyForwards(u8, s.window.items[0 .. s.window.items.len - n], s.window.items[n..]);
        s.window.shrinkRetainingCapacity(s.window.items.len - n);
        s.window_start += @intCast(n);
    }

    /// `avio_seek` on a seekable source; `IoFailure` on a pipe.
    fn seekTo(s: *Source, pos: i64) Error!void {
        const seeker = s.seeker orelse return error.IoFailure;
        seeker.seekTo(std.math.cast(u64, pos) orelse return error.IoFailure) catch return error.IoFailure;
        s.window.clearRetainingCapacity();
        s.window_start = pos;
        s.eof = false;
    }
};

pub const Demuxer = struct {
    /// The error set demux.zig's layer returns.
    pub const ReadError = Error;

    gpa: std.mem.Allocator,
    src: Source,
    info: StreamInfo = .{},
    /// The format's tags: the ID3v2 tags, else ID3v1's, then the PRIV
    /// frames.
    tags: metadata.Dictionary = .empty,
    /// libavformat's `data_offset`, where the frames start.
    data_offset: i64 = 0,
    /// The next read's position.
    pos: i64 = 0,
    /// mp3dec.c's `filesize` (0 on a pipe).
    filesize: i64 = 0,
    /// The Xing or VBRI frame and byte counts, the frame duration and
    /// whether the tag said CBR (Info).
    frames: u32 = 0,
    header_filesize: u32 = 0,
    frame_duration: i64 = 0,
    is_cbr: bool = false,
    /// LAME's (or libavformat's) delay and padding.
    start_pad: i64 = 0,
    end_pad: i64 = 0,
    /// The packet returned last.
    current: std.ArrayList(u8) = .empty,

    /// The demuxer on a source that cannot seek (a pipe): no ID3v1 tag,
    /// no file size.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader, limits: Limits) Error!*Demuxer {
        return initWith(gpa, reader, null, limits);
    }

    /// The demuxer on a seekable source read from its start (a file).
    pub fn initSeekable(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: seek.Seeker, limits: Limits) Error!*Demuxer {
        return initWith(gpa, reader, seeker, limits);
    }

    fn initWith(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker, limits: Limits) Error!*Demuxer {
        const d = try gpa.create(Demuxer);
        errdefer gpa.destroy(d);
        d.* = .{ .gpa = gpa, .src = .{ .reader = reader, .seeker = seeker } };
        errdefer d.deinitFields();
        if (seeker) |sk| {
            d.src.window_start = @intCast(sk.position());
            d.pos = d.src.window_start;
        }
        try d.readHeader(limits);
        return d;
    }

    fn deinitFields(d: *Demuxer) void {
        d.src.deinit(d.gpa);
        d.info.tags.deinit(d.gpa);
        d.tags.deinit(d.gpa);
        d.current.deinit(d.gpa);
    }

    pub fn deinit(d: *Demuxer) void {
        d.deinitFields();
        d.gpa.destroy(d);
    }

    /// avformat_open_input's ID3v2 tags, then mp3_read_header.
    fn readHeader(d: *Demuxer, limits: Limits) Error!void {
        var id3: id3v2.Reader = .init(d.gpa);
        defer id3.deinit();
        // ff_id3v2_read_dict: the tags that follow each other.
        while (true) {
            const head = try d.src.bytesAt(d.gpa, d.pos, id3v2.header_size);
            if (head.len < id3v2.header_size or !id3v2.match(head)) break;
            const header = head[0..id3v2.header_size].*;
            const body_len = id3v2.bodyLen(&header);
            if (body_len > limits.max_id3v2_bytes) return error.LimitExceeded;
            const body = try d.src.bytesAt(d.gpa, d.pos + id3v2.header_size, body_len);
            d.pos += id3v2.header_size + @as(i64, @intCast(try id3.parseTag(&header, body)));
            d.src.drop(@min(d.pos, d.src.windowEnd()));
        }
        try id3.finish();
        std.mem.swap(metadata.Dictionary, &d.tags, &id3.tags);
        // A tag may claim more bytes than the input has. The frame search
        // then starts past the end and the input is InvalidMp3, where
        // FFmpeg's seek fails and it resyncs from where its tag parser
        // stopped (notes.md "An ID3v2 tag past the end of the input",
        // an open question).
        if (d.pos > d.src.windowEnd()) {
            try d.src.fill(d.gpa, d.pos);
            d.src.drop(d.src.windowEnd());
            d.src.window_start = d.pos;
        }

        var off = d.pos;
        const size: ?u64 = if (d.src.seeker) |sk| sk.size() else null;
        if (d.tags.count() == 0) try d.readId3v1(size);
        if (size) |n| d.filesize = std.math.cast(i64, n) orelse std.math.maxInt(i64);
        if (try d.parseVbrTags(off, size)) |skip_to| d.pos = skip_to else d.pos = off;
        try d.exportReplayGain();

        // Two consecutive frames with the same header bits, within 64 KiB.
        off = d.pos;
        const window = try d.src.bytesAt(d.gpa, off, resync_window);
        var i: usize = 0;
        while (i < resync_starts) : (i += 1) {
            const first = check(window, i);
            if (first.frame_size > 0) {
                const second = check(window, i + @as(usize, @intCast(first.frame_size)));
                if (second.frame_size >= 0 and first.header & mpegaudio.mp3_mask == second.header & mpegaudio.mp3_mask) break;
            } else if (first.frame_size == check_seek_failed) return error.InvalidMp3;
        }
        if (i < resync_starts) off += @intCast(i);
        d.pos = off;
        d.data_offset = off;
        try id3.addPriv(&d.tags);
    }

    /// ff_id3v1_read on a seekable source larger than a tag.
    fn readId3v1(d: *Demuxer, size: ?u64) Error!void {
        const n = size orelse return;
        if (n <= id3v1.tag_size) return;
        const before = d.src.window_start;
        const kept = try d.gpa.dupe(u8, d.src.window.items);
        defer d.gpa.free(kept);
        const was_eof = d.src.eof;
        try d.src.seekTo(@intCast(n - id3v1.tag_size));
        const tag = try d.src.bytesAt(d.gpa, @intCast(n - id3v1.tag_size), id3v1.tag_size);
        if (tag.len == id3v1.tag_size) try id3v1.parse(d.gpa, tag[0..id3v1.tag_size], &d.tags);
        // Back where the frames start, the window as it was.
        try d.src.seekTo(before + @as(i64, @intCast(kept.len)));
        d.src.window_start = before;
        try d.src.window.appendSlice(d.gpa, kept);
        d.src.eof = was_eof;
    }

    const check_wrong_header = -1;
    const check_seek_failed = -2;

    const Check = struct { frame_size: i64, header: u32 = 0 };

    /// check(): the frame size of a valid header at `at`, or
    /// CHECK_WRONG_HEADER, or CHECK_SEEK_FAILED when fewer than 4 bytes
    /// remain.
    fn check(window: []const u8, at: usize) Check {
        if (at + 4 > window.len) return .{ .frame_size = check_seek_failed };
        const header = std.mem.readInt(u32, window[at..][0..4], .big);
        const h = mpegaudio.decodeHeader(header) orelse return .{ .frame_size = check_wrong_header };
        if (h.freeFormat()) return .{ .frame_size = check_wrong_header };
        return .{ .frame_size = h.frame_size, .header = header };
    }

    /// mp3_parse_vbr_tags at `base`: the first frame's Xing or Info tag,
    /// VBRI header and the iTunSMPB comment. Returns where the frames
    /// start after a tag frame, or null when there is none (FFmpeg seeks
    /// back to `base`); what the tags set stays either way.
    fn parseVbrTags(d: *Demuxer, base: i64, size: ?u64) Error!?i64 {
        const first = try d.src.bytesAt(d.gpa, base, 4096);
        var c: Cursor = .{ .bytes = first };
        const header = c.rb32();
        const h = mpegaudio.decodeHeader(header) orelse return null;
        const vbrtag_size: i64 = h.frame_size;
        if (h.layer != 3) return null;
        const spf: i64 = if (h.lsf) 576 else 1152;
        d.frames = 0;
        d.header_filesize = 0;
        d.frame_duration = rational.rescaleQ(spf, .{ .num = 1, .den = @intCast(h.sample_rate) }, time_base);
        try d.parseInfoTag(&c, h, spf, base, size);
        // mp3_parse_vbri_tag: 32 bytes after the frame header.
        c.pos = 4 + 32;
        if (c.rb32() == std.mem.readInt(u32, "VBRI", .big) and c.rb16() == 1) {
            c.pos += 4;
            d.header_filesize = c.rb32();
            d.frames = c.rb32();
        }
        d.parseItunesSmpb(h, spf);
        // Packets keep the skipped samples, so the timeline shifts.
        if (d.info.start_skip_samples != 0) d.info.start_time = rational.rescaleQ(d.info.start_skip_samples, .{ .num = 1, .den = @intCast(h.sample_rate) }, time_base);
        if (d.frames == 0 and d.header_filesize == 0) return null;
        if (d.frames != 0) {
            const full = @as(i64, d.frames) * spf;
            if (d.info.duration == nopts) d.info.duration = rational.rescaleQ(full - d.start_pad - d.end_pad, .{ .num = 1, .den = @intCast(h.sample_rate) }, time_base);
            if (d.header_filesize != 0 and !d.is_cbr) d.info.bit_rate = rational.rescale(d.header_filesize, 8 * @as(i64, h.sample_rate), full);
        }
        return base + vbrtag_size;
    }

    /// mp3_parse_info_tag: after the side information, `Xing` or `Info`,
    /// its counts, TOC and quality, then LAME's extension: the encoder,
    /// ReplayGain and, for LAME, Lavf or Lavc, the delay and padding; the
    /// encoder tag and ReplayGain only when the tag's CRC holds.
    fn parseInfoTag(d: *Demuxer, c: *Cursor, h: mpegaudio.Header, spf: i64, base: i64, size: ?u64) Error!void {
        // avio_size from after the header: on a pipe FFmpeg's fails, a
        // negative size that reads as huge unsigned.
        const pos: u64 = @intCast(base + 4);
        const raw_size: u64 = size orelse @bitCast(@as(i64, -38));
        const fsize: u64 = if (raw_size >= pos) raw_size - pos else 0;
        const xing_offtbl = [2][2]u32{ .{ 32, 17 }, .{ 17, 9 } };
        c.pos += xing_offtbl[@intFromBool(h.lsf)][@intFromBool(h.nb_channels == 1)];
        const v = c.rb32();
        d.is_cbr = v == std.mem.readInt(u32, "Info", .big);
        if (v != std.mem.readInt(u32, "Xing", .big) and !d.is_cbr) return;
        const flags = c.rb32();
        if (flags & 1 != 0) d.frames = c.rb32();
        if (flags & 2 != 0) d.header_filesize = c.rb32();
        if (fsize != 0 and d.header_filesize != 0) {
            const min = @min(fsize, d.header_filesize);
            const delta = @max(fsize, d.header_filesize) - min;
            // A concatenated file: the bit rate gives the duration.
            if (fsize > d.header_filesize and delta > min >> 4) d.frames = 0;
        }
        // The TOC, read and ignored (the index needs `usetoc`).
        if (flags & 4 != 0) c.pos += 100;
        if (flags & 8 != 0) c.pos += 4;
        var version: [9]u8 = undefined;
        for (&version) |*b| b.* = c.r8();
        c.pos += 2;
        const peak: u32 = @intCast(rational.rescale(c.rb32(), 100000, 1 << 23));
        var r_gain: i32 = std.math.minInt(i32);
        var a_gain: i32 = std.math.minInt(i32);
        const radio = c.rb16();
        if ((radio >> 13) & 7 == 1) {
            r_gain = @intCast((radio & 0x1ff) * 10000);
            if (radio & (1 << 9) != 0) r_gain = -r_gain;
        }
        const audiophile = c.rb16();
        if ((audiophile >> 13) & 7 == 2) {
            a_gain = @intCast((audiophile & 0x1ff) * 10000);
            if (audiophile & (1 << 9) != 0) a_gain = -a_gain;
        }
        c.pos += 2;
        const delays = c.rb24();
        const tag4 = std.mem.readInt(u32, version[0..4], .big);
        if (tag4 == std.mem.readInt(u32, "LAME", .big) or tag4 == std.mem.readInt(u32, "Lavf", .big) or tag4 == std.mem.readInt(u32, "Lavc", .big)) {
            d.start_pad = delays >> 12;
            d.end_pad = delays & 4095;
            d.info.start_skip_samples = d.start_pad + 528 + 1;
            if (d.frames != 0) {
                d.info.first_discard_sample = -d.end_pad + 528 + 1 + @as(i64, d.frames) * spf;
                d.info.last_discard_sample = @as(i64, d.frames) * spf;
            }
        }
        c.pos += 1 + 1 + 2 + 4 + 2;
        // The CRC of the frame's bytes up to it.
        const crc_end: usize = @intCast(@min(c.pos, c.bytes.len));
        const crc = crc16Arc(c.bytes[0..crc_end]);
        if (c.rb16() == crc) {
            if (r_gain != std.math.minInt(i32) or a_gain != std.math.minInt(i32))
                d.info.replaygain = .{ .track_gain = r_gain, .track_peak = peak, .album_gain = a_gain, .album_peak = 0 };
            const end = std.mem.findScalar(u8, &version, 0) orelse version.len;
            putTag(d.gpa, &d.info.tags, "encoder", version[0..end], .replace) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    }

    /// mp3_parse_itunes_smpb: Apple's gapless counts, unless LAME's gave
    /// some.
    fn parseItunesSmpb(d: *Demuxer, h: mpegaudio.Header, spf: i64) void {
        if (d.info.start_skip_samples != 0) return;
        const value = findItunesSmpb(&d.tags) orelse return;
        const counts = parseSmpb(value) orelse return;
        if (counts.priming > 16384 or counts.samples == 0) return;
        // The three counts must add up to the frames' samples.
        if (d.frames != 0 and counts.priming + counts.samples + counts.remainder != @as(i64, d.frames) * spf) return;
        d.info.start_skip_samples = counts.priming;
        d.info.first_discard_sample = counts.priming + counts.samples;
        d.info.last_discard_sample = counts.priming + counts.samples + counts.remainder;
        d.info.duration = rational.rescaleQ(counts.samples, .{ .num = 1, .den = @intCast(h.sample_rate) }, time_base);
    }

    /// ff_replaygain_export from the format's tags: they replace LAME's
    /// values when they have a gain.
    fn exportReplayGain(d: *Demuxer) Error!void {
        const tg = parseGain(d.tags.get("REPLAYGAIN_TRACK_GAIN"), std.math.minInt(i32));
        const tp = parseGain(d.tags.get("REPLAYGAIN_TRACK_PEAK"), 0);
        const ag = parseGain(d.tags.get("REPLAYGAIN_ALBUM_GAIN"), std.math.minInt(i32));
        const ap = parseGain(d.tags.get("REPLAYGAIN_ALBUM_PEAK"), 0);
        if (tg == std.math.minInt(i32) and ag == std.math.minInt(i32)) return;
        d.info.replaygain = .{ .track_gain = tg, .track_peak = @bitCast(tp), .album_gain = ag, .album_peak = @bitCast(ap) };
    }

    pub fn streamCount(d: *const Demuxer) usize {
        _ = d;
        return 1;
    }

    pub fn setup(d: *const Demuxer, i: usize) demux.Setup {
        std.debug.assert(i == 0);
        return .{
            .known = true,
            .time_base = time_base,
            .sample_rate = 0,
            .channels = 0,
            .parse_mpegaudio = true,
            .frame_size_unknown = true,
            .bit_rate = d.info.bit_rate,
            .start_skip_samples = d.info.start_skip_samples,
            .first_discard_sample = d.info.first_discard_sample,
            .last_discard_sample = d.info.last_discard_sample,
        };
    }

    /// mp3_read_packet: up to 1024 bytes, cut at the file's end; null at
    /// the end.
    pub fn next(d: *Demuxer) Error!?Packet {
        var size: i64 = packet_size;
        if (d.filesize > id3v1.tag_size and d.pos < d.filesize) size = @min(size, d.filesize - d.pos);
        const bytes = try d.src.bytesAt(d.gpa, d.pos, @intCast(@max(size, 0)));
        if (bytes.len == 0) return null;
        d.current.clearRetainingCapacity();
        try d.current.appendSlice(d.gpa, bytes);
        const pos = d.pos;
        d.pos += @intCast(bytes.len);
        d.src.drop(d.pos);
        return .{ .stream = 0, .data = d.current.items, .pts = nopts, .dts = nopts, .duration = 0, .flags = 0, .pos = pos };
    }

    pub fn durationOf(d: *Demuxer, i: usize) *i64 {
        std.debug.assert(i == 0);
        return &d.info.duration;
    }

    pub fn startTime(d: *Demuxer, i: usize) *i64 {
        std.debug.assert(i == 0);
        return &d.info.start_time;
    }

    pub fn fileSize(d: *const Demuxer) ?u64 {
        const sk = d.src.seeker orelse return null;
        return sk.size();
    }

    pub fn dataOffset(d: *const Demuxer) i64 {
        return d.data_offset;
    }

    /// libavformat's `avio_seek`: `IoFailure` on a pipe.
    pub fn reposition(d: *Demuxer, pos: i64) Error!void {
        try d.src.seekTo(pos);
        d.pos = pos;
    }

    pub fn ioRepositioned(d: *Demuxer) void {
        _ = d;
    }

    /// No `read_timestamp`: the generic layer seeks without it.
    pub fn readTimestamp(d: *Demuxer, i: usize, pos: *i64, pos_limit: i64) Error!i64 {
        _ = d;
        _ = i;
        _ = pos;
        _ = pos_limit;
        return nopts;
    }

    /// mp3_seek without `usetoc` or fast seeking: the generic index code
    /// (-1).
    pub fn readSeek(d: *Demuxer, layer: anytype, i: usize, ts: i64, flags: seek.Flags) Error!bool {
        _ = d;
        _ = layer;
        _ = i;
        _ = ts;
        _ = flags;
        return false;
    }
};

/// An `AVIOContext` over bytes read ahead: reads past them give zeros.
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn r8(c: *Cursor) u8 {
        defer c.pos += 1;
        return if (c.pos < c.bytes.len) c.bytes[c.pos] else 0;
    }

    fn rb16(c: *Cursor) u32 {
        const hi: u32 = c.r8();
        return hi << 8 | c.r8();
    }

    fn rb24(c: *Cursor) u32 {
        const hi: u32 = c.rb16();
        return hi << 8 | c.r8();
    }

    fn rb32(c: *Cursor) u32 {
        const hi: u32 = c.rb16();
        return hi << 16 | c.rb16();
    }
};

/// `ff_crcA001_update` from 0: CRC-16/ARC.
fn crc16Arc(bytes: []const u8) u32 {
    return std.hash.crc.@"CRC-16/ARC".hash(bytes);
}

fn putTag(gpa: std.mem.Allocator, tags: *metadata.Dictionary, key: []const u8, value: []const u8, duplicates: metadata.Duplicates) std.mem.Allocator.Error!void {
    tags.put(gpa, key, value, duplicates) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The value ends at its first NUL.
        error.InvalidTag => unreachable,
    };
}

/// find_itunes_smpb: `comment-iTunSMPB`, bare or with a three-letter
/// language, else a bare `iTunSMPB` (keys case-insensitive).
fn findItunesSmpb(tags: *const metadata.Dictionary) ?[]const u8 {
    const prefix = "comment-iTunSMPB";
    for (tags.items()) |entry| {
        if (entry.key.len < prefix.len or !std.ascii.eqlIgnoreCase(entry.key[0..prefix.len], prefix)) continue;
        const lang = entry.key[prefix.len..];
        if (lang.len == 0 or (lang[0] == '-' and lang.len == 4)) return entry.value;
    }
    return tags.get("iTunSMPB");
}

const SmpbCounts = struct { priming: i64, remainder: i64, samples: i64 };

/// ff_itunes_parse_smpb: four fields as `%16x` reads them (white space,
/// then within 16 characters a sign, `0x` and hexadecimal digits); a field
/// cut short at 16 characters (a hexadecimal digit after it), or a count
/// past `SMPB_MAX_SAMPLES`, is invalid.
fn parseSmpb(value: []const u8) ?SmpbCounts {
    var fields: [4]u64 = undefined;
    var at: usize = 0;
    for (&fields) |*f| {
        while (at < value.len and std.ascii.isWhitespace(value[at])) at += 1;
        const start = at;
        const width_end = @min(value.len, start + 16);
        var negative = false;
        if (at < width_end and (value[at] == '+' or value[at] == '-')) {
            negative = value[at] == '-';
            at += 1;
        }
        var digits: usize = 0;
        if (at + 1 < width_end and value[at] == '0' and (value[at + 1] == 'x' or value[at + 1] == 'X')) {
            // "0x": the zero counts as a digit even without more.
            at += 2;
            digits = 1;
        }
        var v: u64 = 0;
        while (at < width_end and std.ascii.isHex(value[at])) : (at += 1) {
            v = v << 4 | (std.fmt.charToDigit(value[at], 16) catch unreachable);
            digits += 1;
        }
        if (digits == 0) return null;
        f.* = if (negative) 0 -% v else v;
        if (at < value.len and std.ascii.isHex(value[at])) return null;
    }
    const max: u64 = 1 << 40; // SMPB_MAX_SAMPLES, demux_utils.c
    if (fields[1] > max or fields[2] > max or fields[3] > max) return null;
    return .{ .priming = @intCast(fields[1]), .remainder = @intCast(fields[2]), .samples = @intCast(fields[3]) };
}

/// replaygain.c's parse_value: `strtol`'s whole decibels, then up to five
/// fractional digits, in 1/100000 dB; `min` when absent or out of range.
fn parseGain(text: ?[]const u8, min: i32) i32 {
    const value = text orelse return min;
    var at: usize = 0;
    while (at < value.len and (value[at] == ' ' or value[at] == '\t')) at += 1;
    const sign: i32 = if (at < value.len and value[at] == '-') -1 else 1;
    const parsed = strtol0(value[at..]);
    var mb: i32 = 0;
    var scale: i32 = 10000;
    var rest = value[at + parsed.len ..];
    if (rest.len > 0 and rest[0] == '.') {
        rest = rest[1..];
        var k: usize = 0;
        while (k < rest.len and std.ascii.isDigit(rest[k]) and scale != 0) : (k += 1) {
            mb += scale * @as(i32, rest[k] - '0');
            scale = @divTrunc(scale, 10);
        }
    }
    // `db` is an int from strtol's long.
    const db: i32 = @truncate(parsed.value);
    if (@abs(@as(i64, db)) > @divTrunc(@as(i64, std.math.maxInt(i32)) - mb, 100000)) return min;
    return db *% 100000 +% sign * mb;
}

/// strtol with base 0 as glibc reads it: white space, a sign, then 0x for
/// hexadecimal or 0 for octal; the bytes it used (0 when none).
fn strtol0(text: []const u8) struct { value: i64, len: usize } {
    var i: usize = 0;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    var negative = false;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        negative = text[i] == '-';
        i += 1;
    }
    var base: u8 = 10;
    if (i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X') and i + 2 < text.len and std.ascii.isHex(text[i + 2])) {
        base = 16;
        i += 2;
    } else if (i < text.len and text[i] == '0') base = 8;
    const start = i;
    var v: i64 = 0;
    var overflow = false;
    while (i < text.len) : (i += 1) {
        const digit = std.fmt.charToDigit(text[i], base) catch break;
        v = std.math.mul(i64, v, base) catch blk: {
            overflow = true;
            break :blk v;
        };
        v = std.math.add(i64, v, digit) catch blk: {
            overflow = true;
            break :blk v;
        };
    }
    if (i == start) return .{ .value = 0, .len = 0 };
    if (overflow) return .{ .value = if (negative) std.math.minInt(i64) else std.math.maxInt(i64), .len = i };
    return .{ .value = if (negative) -v else v, .len = i };
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const vectors = @embedFile("../testing/vectors/mp3.txt");

/// The vector lines of one fixture, after its `F` line.
fn block(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, vectors, at, '\n') orelse vectors.len;
        const end = std.mem.findPos(u8, vectors, line_end, "\nF ") orelse vectors.len;
        if (std.mem.eql(u8, vectors[at + 2 .. line_end], name)) return vectors[line_end + 1 .. @min(end + 1, vectors.len)];
        start = end;
    }
    return null;
}

/// Adler-32 from 0, as `av_adler32_update(0, ...)` gives it.
fn adler(data: []const u8) u32 {
    var a: u32 = 0;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeTs(out: *std.ArrayList(u8), gpa: std.mem.Allocator, ts: ?i64) !void {
    if (ts) |v| {
        if (v != nopts) return out.print(gpa, " {d}", .{v});
    }
    try out.appendSlice(gpa, " N");
}

/// mp3_vectors.c's lines for a fixture the demuxer opens, from the
/// demuxer and libavformat's layer (demux.zig); null when it refuses.
fn vectorLines(gpa: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList(u8)) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const d = Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{}) catch |err| switch (err) {
        error.InvalidMp3 => return out.appendSlice(gpa, "O INVALIDDATA\n"),
        else => return err,
    };
    defer d.deinit();
    var layer = demux.Layer(Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    try out.appendSlice(gpa, "O ok\n");
    const params = try layer.codecParams(0);
    const codec = if (params.mpa_codec) |c| @tagName(c) else "mp3";
    try out.print(gpa, "S 0 a {s} {d} {d} 1/14112000", .{ codec, params.sample_rate, params.channels });
    try writeTs(out, gpa, d.info.duration);
    try writeTs(out, gpa, d.info.start_time);
    try out.print(gpa, " 0 {d} 0\n", .{params.bit_rate});
    if (d.info.replaygain) |rg| try out.print(gpa, "Y 0 {d} {d} {d} {d}\n", .{ rg.track_gain, rg.track_peak, rg.album_gain, rg.album_peak });
    for (d.info.tags.items()) |e| try out.print(gpa, "M 0 {s}={s}\n", .{ e.key, e.value });
    try out.appendSlice(gpa, "B");
    try writeTs(out, gpa, layer.start_time);
    try writeTs(out, gpa, layer.duration);
    try out.print(gpa, " {d}\n", .{layer.bit_rate});
    for (d.tags.items()) |e| try out.print(gpa, "G {s}={s}\n", .{ e.key, e.value });
    while (try layer.next()) |p| {
        try out.print(gpa, "P {d} {d}", .{ p.stream, p.data.len });
        try writeTs(out, gpa, p.pts);
        try writeTs(out, gpa, p.dts);
        try out.print(gpa, " {d} {x} {d} {d}\n", .{ p.duration, p.flags, p.pos, adler(p.data) });
        if (p.skip) |k| try out.print(gpa, "K {d} {d}\n", .{ k[0], k[1] });
    }
    try out.appendSlice(gpa, "R EOF\n");
}

/// The lines of FFmpeg's attached-picture stream and chapters, which the
/// port does not model (notes.md "MP3").
fn withoutPicturesAndChapters(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_chapter = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "H ")) {
            in_chapter = true;
            continue;
        }
        if (in_chapter and std.mem.startsWith(u8, line, "G ")) continue;
        in_chapter = false;
        if (std.mem.startsWith(u8, line, "S 1 ") or std.mem.startsWith(u8, line, "M 1 ") or std.mem.startsWith(u8, line, "P 1 ")) continue;
        // The picture stream's duration enters the format's.
        if (std.mem.startsWith(u8, line, "B ")) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

test "every MP3 fixture demuxes as FFmpeg's demuxer and parser demux it (vectors/mp3.txt)" {
    const gpa = testing.allocator;
    inline for (fixtures.mp3.all) |fixture| {
        const want = block(fixture.name) orelse return error.MissingVector;
        if (!std.mem.startsWith(u8, want, "O INVALIDDATA")) {
            var got: std.ArrayList(u8) = .empty;
            defer got.deinit(gpa);
            try vectorLines(gpa, fixtures.mp3.bytes(fixture.name), &got);
            const picture = comptime std.mem.eql(u8, fixture.name, "mp3_apic_chap");
            const expected = if (picture) try withoutPicturesAndChapters(gpa, want) else try gpa.dupe(u8, want);
            defer gpa.free(expected);
            const actual = if (picture) try withoutPicturesAndChapters(gpa, got.items) else try gpa.dupe(u8, got.items);
            defer gpa.free(actual);
            testing.expectEqualStrings(expected, actual) catch |err| {
                std.debug.print("mp3 fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
}

const seek_vectors = @embedFile("../testing/vectors/seek_mp3.txt");

fn seekBlock(name: []const u8) ?[]const u8 {
    var start: ?usize = null;
    var lines = std.mem.splitScalar(u8, seek_vectors, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "F ")) continue;
        const at = @intFromPtr(line.ptr) - @intFromPtr(seek_vectors.ptr);
        if (start) |s| return seek_vectors[s..at];
        if (std.mem.eql(u8, line[2..], name)) start = at + line.len + 1;
    }
    return if (start) |s| seek_vectors[s..] else null;
}

/// The next packet's lines, as seek_vectors.c prints them; the reference
/// build has no MPEG audio decoder (`D none`).
fn nextAfterSeek(gpa: std.mem.Allocator, layer: anytype, out: *std.ArrayList(u8)) !void {
    const p = try layer.next() orelse return out.appendSlice(gpa, "P EOF\n");
    try out.appendSlice(gpa, "P");
    try writeTs(out, gpa, p.pts);
    try out.print(gpa, " {d} {d}\n", .{ p.pos, p.data.len });
    if (p.skip) |skip| try out.print(gpa, "Z {d} {d}\n", .{ skip[0], skip[1] });
    try out.appendSlice(gpa, "D none\n");
}

test "every MP3 fixture seeks as FFmpeg seeks it (vectors/seek_mp3.txt)" {
    const gpa = testing.allocator;
    var compared: usize = 0;
    inline for (fixtures.mp3.all) |fixture| {
        // FFmpeg queues the attached picture again after each seek, which
        // the port does not model (notes.md "MP3").
        if (comptime std.mem.eql(u8, fixture.name, "mp3_apic_chap")) continue;
        const block_text = seekBlock(fixture.name) orelse return error.MissingVector;
        var lines = std.mem.splitScalar(u8, block_text, '\n');
        if (std.mem.eql(u8, lines.next().?, "O ok")) {
            _ = lines.next(); // I
            var pending = lines.next();
            while (pending) |k_line| {
                pending = lines.next();
                if (k_line.len == 0) continue;
                var expected: std.ArrayList(u8) = .empty;
                defer expected.deinit(gpa);
                var f = std.mem.tokenizeScalar(u8, k_line, ' ');
                _ = f.next();
                const api = f.next().?[0];
                const stream_index = try std.fmt.parseInt(i32, f.next().?, 10);
                const ts = try std.fmt.parseInt(i64, f.next().?, 10);
                var min_ts: i64 = 0;
                var max_ts: i64 = 0;
                if (api == 's') {
                    min_ts = try std.fmt.parseInt(i64, f.next().?, 10);
                    max_ts = try std.fmt.parseInt(i64, f.next().?, 10);
                }
                const flag_bits = try std.fmt.parseInt(u8, f.next().?, 16);
                const flags: seek.Flags = .{ .backward = flag_bits & 1 != 0, .byte = flag_bits & 2 != 0, .any = flag_bits & 4 != 0 };
                const ret = f.next().?;
                if (std.mem.eql(u8, ret, "0")) {
                    while (pending) |next_line| {
                        if (next_line.len == 0 or next_line[0] == 'K') break;
                        try expected.appendSlice(gpa, next_line);
                        try expected.append(gpa, '\n');
                        pending = lines.next();
                    }
                }
                var reader: std.Io.Reader = .fixed(fixtures.mp3.bytes(fixture.name));
                const d = try Demuxer.initSeekable(gpa, &reader, .fixed(&reader), .{});
                defer d.deinit();
                var layer = demux.Layer(Demuxer).init(gpa, d);
                defer layer.deinit();
                try layer.findStreamInfo();
                _ = try layer.next();
                const result = if (api == 'f') layer.seekFrame(stream_index, ts, flags) else layer.seekFile(stream_index, min_ts, ts, max_ts, flags);
                var actual: std.ArrayList(u8) = .empty;
                defer actual.deinit(gpa);
                if (result) |_| {
                    try nextAfterSeek(gpa, &layer, &actual);
                } else |err| switch (err) {
                    error.InvalidStream => try actual.appendSlice(gpa, "EINVAL"),
                    error.SeekFailed, error.InvalidRange => try actual.appendSlice(gpa, "-1"),
                    else => return err,
                }
                const want = if (std.mem.eql(u8, ret, "0")) expected.items else ret;
                testing.expectEqualStrings(want, actual.items) catch |err| {
                    std.debug.print("fixture {s}: {s}\n", .{ fixture.name, k_line });
                    return err;
                };
                compared += 1;
            }
        }
    }
    // Every seek of the fixtures FFmpeg opens, but the picture's.
    try testing.expectEqual(2106, compared);
}

test "iTunSMPB counts up to SMPB_MAX_SAMPLES (2^40) are kept, larger ones refuse the tag" {
    const at_max = parseSmpb(" 00000000 0000010000000000 0000010000000000 0000010000000000").?;
    try testing.expectEqual(1 << 40, at_max.priming);
    try testing.expectEqual(1 << 40, at_max.remainder);
    try testing.expectEqual(1 << 40, at_max.samples);
    const typical = parseSmpb(" 00000000 00000210 0000097C 0000000000254D04").?;
    try testing.expectEqual(0x210, typical.priming);
    try testing.expectEqual(0x97c, typical.remainder);
    try testing.expectEqual(0x254d04, typical.samples);
    // The reserved field is not bounded.
    try testing.expect(parseSmpb(" FFFFFFFFFFFFFFFF 00000210 0000097C 0000000000254D04") != null);
    try testing.expectEqual(null, parseSmpb(" 00000000 0000010000000001 00000000 00000000"));
    try testing.expectEqual(null, parseSmpb(" 00000000 00000000 0000010000000001 00000000"));
    try testing.expectEqual(null, parseSmpb(" 00000000 00000000 00000000 0000010000000001"));
    // 2^51, which the port accepted before.
    try testing.expectEqual(null, parseSmpb(" 00000000 00000210 0000097C 0008000000000000"));
}
