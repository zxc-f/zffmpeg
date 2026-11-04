// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project; not translated from FFmpeg source.
// libavformat/oggdec.c (ogg_read_page, ogg_packet, ogg_new_stream,
// ogg_replace_stream, ogg_find_codec, ogg_read_header, ogg_calc_pts,
// ogg_read_packet, ogg_probe), oggdec.h (ogg_gptopts), oggparseflac.c,
// oggparseopus.c, oggparsevorbis.c and libavcodec/vorbis_parser.c at the
// pinned reference revision describe the behavior, restated here.
//! The Ogg demuxer's own layer (TODO.md T27a): pages, packets, logical
//! streams and the FLAC, Opus and Vorbis mappings, giving each packet the
//! timestamps, duration, flags and side data FFmpeg's demuxer gives it,
//! before libavformat's generic layer (demux.zig) completes them.
//!
//! Reading is sequential. FFmpeg seeks back to just after a page's capture
//! pattern when it refuses the page (a CRC or version mismatch); here the
//! page's bytes are pushed back and scanned again, the same bytes. On a
//! seekable input FFmpeg also rescans the previous page's body when the
//! next page is not where it expects it, which finds something else only
//! when a page body holds a valid page (port.md "Ogg contract").

const std = @import("std");
const flac = @import("../codec/flac.zig");
const metadata = @import("../core/metadata.zig");
const rational = @import("../core/rational.zig");
const vorbiscomment = @import("vorbiscomment.zig");
const demux = @import("demux.zig");
const seek = @import("seek.zig");

pub const Error = error{
    /// FFmpeg's AVERROR_INVALIDDATA (and AVERROR_UNKNOWN for a Vorbis
    /// setup header it cannot read, AVERROR(EINVAL) for a chained stream
    /// of another codec).
    InvalidOgg,
    /// The input ended before the headers (FFmpeg's AVERROR_EOF on open).
    Truncated,
    /// A chained stream changes the channels or the rate, or a
    /// multiplexed stream is followed by a chain (AVERROR_PATCHWELCOME).
    UnsupportedFormat,
    IoFailure,
    OutOfMemory,
};

/// FFmpeg's `MAX_PAGE_SIZE`: the longest page, and how far it searches for
/// a capture pattern.
pub const max_page_size = 65307;

pub const nopts: i64 = std.math.minInt(i64);
const no_granule: u64 = std.math.maxInt(u64);

const flag_cont = 1;
const flag_bos = 2;
const flag_eos = 4;

/// The content probe: `OggS` and a header type of at most 7.
pub const probe_bytes = 6;

pub fn probeScore(head: []const u8) u8 {
    if (head.len >= 6 and std.mem.eql(u8, head[0..4], "OggS") and head[4] == 0 and head[5] <= 0x7) return 100;
    // FFmpeg compares five bytes, the fifth a NUL; a shorter head scores 0.
    return 0;
}

/// Ogg's CRC-32: polynomial 0x04C11DB7, initial 0, MSB first, no final
/// XOR (FFmpeg's ff_crc04C11DB7_update).
pub const Crc = std.hash.crc.Generic(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0,
    .reflect_input = false,
    .reflect_output = false,
    .xor_output = 0,
});

pub const Codec = enum { flac, opus, vorbis };

/// What a stream is, as libavformat's `AVStream` and `AVCodecParameters`
/// hold it.
pub const StreamInfo = struct {
    /// Null for a stream whose first packet no supported mapping matched.
    codec: ?Codec = null,
    sample_rate: u32 = 0,
    channels: u8 = 0,
    time_base: rational.Rational = .{ .num = 1, .den = 1_000_000 },
    extradata: std.ArrayList(u8) = .empty,
    tags: metadata.Dictionary = .empty,
    start_time: i64 = nopts,
    duration: i64 = nopts,
    initial_padding: u32 = 0,
    seek_preroll: u32 = 0,
    bit_rate: i64 = 0,

    fn deinit(s: *StreamInfo, gpa: std.mem.Allocator) void {
        s.extradata.deinit(gpa);
        s.tags.deinit(gpa);
    }
};

/// `AVVorbisParseContext` (libavcodec/vorbis_parser.c).
const VorbisParser = struct {
    blocksize: [2]u32 = .{ 0, 0 },
    previous_blocksize: u32 = 0,
    mode_blocksize: [64]u1 = @splat(0),
    mode_count: u32 = 0,
    mode_mask: u32 = 0,
    prev_mask: u32 = 0,

    const flag_header = 1;
    const flag_comment = 2;
    const flag_setup = 4;

    /// ff_vorbis_parse_init from the identification and setup headers.
    fn init(id: []const u8, setup: []const u8) ?VorbisParser {
        var p: VorbisParser = .{};
        if (id.len < 30 or id[0] != 1 or !std.mem.eql(u8, id[1..7], "vorbis") or id[29] & 1 == 0) return null;
        p.blocksize = .{ @as(u32, 1) << @intCast(id[28] & 0xf), @as(u32, 1) << @intCast(id[28] >> 4) };
        if (!p.parseSetup(setup)) return null;
        p.previous_blocksize = p.blocksize[p.mode_blocksize[0]];
        return p;
    }

    /// parse_setup_header: the mode table read backwards from the framing
    /// bit, as get_bits reads the reversed bytes.
    fn parseSetup(p: *VorbisParser, buf: []const u8) bool {
        if (buf.len < 7 or buf[0] != 5 or !std.mem.eql(u8, buf[1..7], "vorbis")) return false;
        const Rev = struct {
            buf: []const u8,
            index: usize = 0,
            fn bit(r: *@This()) u32 {
                // Bit `index` of the reversed bytes, MSB first: byte
                // len-1-index/8 of the original, from its top bit.
                const byte = r.buf[r.buf.len - 1 - r.index / 8];
                const shift: u3 = @intCast(7 - r.index % 8);
                r.index += 1;
                return (byte >> shift) & 1;
            }
            fn bits(r: *@This(), n: u32) u32 {
                var v: u32 = 0;
                for (0..n) |_| v = (v << 1) | r.bit();
                return v;
            }
            fn left(r: *const @This()) isize {
                const size: isize = @intCast(r.buf.len * 8);
                const index: isize = @intCast(r.index);
                return size - index;
            }
        };
        var gb: Rev = .{ .buf = buf };
        var framing: usize = 0;
        while (gb.left() > 97) {
            if (gb.bit() == 1) {
                framing = gb.index;
                break;
            }
        }
        if (framing == 0) return false;
        var mode_count: u32 = 0;
        var last_mode_count: u32 = 0;
        var got_mode_header = false;
        while (gb.left() >= 97) {
            // `get_bits(8) > 63 || get_bits(16) || get_bits(16)`, which
            // stops reading at the first test that fails.
            if (gb.bits(8) > 63) break;
            if (gb.bits(16) != 0) break;
            if (gb.bits(16) != 0) break;
            gb.index += 1;
            mode_count += 1;
            if (mode_count > 64) break;
            var gb0 = gb;
            if (gb0.bits(6) + 1 == mode_count) {
                got_mode_header = true;
                last_mode_count = mode_count;
            }
        }
        if (!got_mode_header or last_mode_count > 63) return false;
        p.mode_count = last_mode_count;
        const log2: u5 = if (last_mode_count - 1 == 0) 0 else @intCast(31 - @clz(last_mode_count - 1));
        p.mode_mask = ((@as(u32, 1) << (log2 + 1)) - 1) << 1;
        p.prev_mask = (p.mode_mask | 1) + 1;
        gb = .{ .buf = buf, .index = framing };
        var i = last_mode_count;
        while (i > 0) {
            i -= 1;
            gb.index += 40;
            p.mode_blocksize[i] = @intCast(gb.bit());
        }
        return true;
    }

    fn reset(p: *VorbisParser) void {
        p.previous_blocksize = p.blocksize[0];
    }

    /// av_vorbis_parse_frame_flags: the packet's duration, or null for
    /// one it refuses; a header packet sets its flag and lasts 0.
    fn frame(p: *VorbisParser, buf: []const u8, flags: *u32) ?u32 {
        if (buf.len == 0) return 0;
        if (buf[0] & 1 != 0) {
            switch (buf[0]) {
                1 => flags.* |= flag_header,
                3 => flags.* |= flag_comment,
                5 => flags.* |= flag_setup,
                else => {},
            }
            return 0;
        }
        const mode: u32 = if (p.mode_count == 1) 0 else (buf[0] & p.mode_mask) >> 1;
        if (mode >= p.mode_count) return null;
        var previous = p.previous_blocksize;
        if (p.mode_blocksize[mode] == 1) previous = p.blocksize[@intFromBool(buf[0] & p.prev_mask != 0)];
        const current = p.blocksize[p.mode_blocksize[mode]];
        p.previous_blocksize = current;
        return (previous + current) >> 2;
    }
};

const VorbisPacketType = enum { data, id, comment, setup, reserved };

/// oggvorbis_private.
const VorbisState = struct {
    packet: [3]?[]u8 = .{ null, null, null },
    last_packet: VorbisPacketType = .data,
    vp: ?VorbisParser = null,
    bos_page_pos: i64 = -1,
    ts_offset: i64 = 0,
    last_page_granule: i64 = 0,
    eos_page_duration: i64 = 0,

    fn deinit(v: *VorbisState, gpa: std.mem.Allocator) void {
        for (&v.packet) |*p| if (p.*) |b| {
            gpa.free(b);
            p.* = null;
        };
    }
};

/// oggopus_private.
const OpusState = struct {
    need_comments: u32 = 0,
    pre_skip: u32 = 0,
    cur_dts: i64 = 0,
};

/// `struct ogg_stream`: a logical stream's page and packet state.
const Stream = struct {
    serial: u32,
    buf: std.ArrayList(u8) = .empty,
    pstart: usize = 0,
    psize: usize = 0,
    pflags: u32 = 0,
    pduration: i64 = 0,
    granule: u64 = no_granule,
    start_granule: u64 = no_granule,
    // ogg_new_stream zeroes the stream: 0, not AV_NOPTS_VALUE.
    lastpts: i64 = 0,
    lastdts: i64 = 0,
    sync_pos: i64 = -1,
    page_pos: i64 = 0,
    flags: u8 = 0,
    /// The mapping, once the first packet named it; `header` is -1 until
    /// then, as FFmpeg's `header` starts.
    codec: ?Codec = null,
    header: i32 = -1,
    nsegs: usize = 0,
    segp: usize = 0,
    segments: [255]u8 = undefined,
    incomplete: bool = false,
    page_start: bool = false,
    page_end: bool = false,
    /// ogg_get_length's progress: 0, -1 waiting for a start, 1 done.
    got_start: i8 = 0,
    got_data: bool = false,
    nb_header: u32 = 0,
    start_trimming: u32 = 0,
    end_trimming: u32 = 0,
    replace: bool = false,
    /// av_packet_pack_dictionary of the tags at their last update, for
    /// the next packet's strings-metadata side data.
    new_metadata: ?[]u8 = null,
    new_extradata: ?[]u8 = null,
    opus: OpusState = .{},
    vorbis: VorbisState = .{},
    /// The `AVStream`.
    info: StreamInfo = .{},

    fn deinit(s: *Stream, gpa: std.mem.Allocator) void {
        s.buf.deinit(gpa);
        s.vorbis.deinit(gpa);
        if (s.new_extradata) |b| gpa.free(b);
        if (s.new_metadata) |b| gpa.free(b);
        s.info.deinit(gpa);
    }

    fn packet(s: *const Stream) []const u8 {
        return s.buf.items[s.pstart..][0..s.psize];
    }

    /// A byte of the buffer, or the zero padding FFmpeg keeps past it.
    fn byteAt(s: *const Stream, at: usize) u8 {
        return if (at < s.buf.items.len) s.buf.items[at] else 0;
    }
};

/// A packet as FFmpeg's demuxer returns it, before libavformat's
/// generic layer (demux.zig): borrowed until the next call. Its flags are
/// AV_PKT_FLAG_CORRUPT's (2) or none; its skip samples, new extradata
/// (a chained Vorbis stream's headers) and strings metadata (packed tags)
/// are side data.
pub const Packet = demux.SourcePacket;

/// ogg_save's state.
const Snapshot = struct {
    pos: i64,
    curidx: i32,
    streams: []Stream,
};

/// A byte source with FFmpeg's seekback for a refused page: pushed-back
/// bytes are read before the reader's.
const Source = struct {
    reader: *std.Io.Reader,
    pushback: std.ArrayList(u8) = .empty,
    /// Bytes of `pushback` already read again.
    pushback_pos: usize = 0,
    /// The offset of the next byte read.
    pos: i64 = 0,
    /// Repositions `reader`, for ogg_get_length's scans; null on a pipe.
    seeker: ?seek.Seeker = null,

    fn deinit(s: *Source, gpa: std.mem.Allocator) void {
        s.pushback.deinit(gpa);
    }

    fn seekTo(s: *Source, pos: i64) Error!void {
        s.seeker.?.seekTo(@intCast(pos)) catch return error.IoFailure;
        s.pushback.clearRetainingCapacity();
        s.pushback_pos = 0;
        s.pos = pos;
    }

    /// Up to `out.len` bytes; fewer only at the end.
    fn read(s: *Source, out: []u8) Error!usize {
        var n: usize = 0;
        if (s.pushback_pos < s.pushback.items.len) {
            const rest = s.pushback.items[s.pushback_pos..];
            n = @min(rest.len, out.len);
            @memcpy(out[0..n], rest[0..n]);
            s.pushback_pos += n;
        }
        if (n < out.len) n += s.reader.readSliceShort(out[n..]) catch return error.IoFailure;
        s.pos += @intCast(n);
        return n;
    }

    /// Makes `bytes` (just read) be read again.
    fn unread(s: *Source, gpa: std.mem.Allocator, bytes: []const u8) Error!void {
        const rest = s.pushback.items[s.pushback_pos..];
        var merged = try gpa.alloc(u8, bytes.len + rest.len);
        defer gpa.free(merged);
        @memcpy(merged[0..bytes.len], bytes);
        @memcpy(merged[bytes.len..], rest);
        s.pushback.clearRetainingCapacity();
        try s.pushback.appendSlice(gpa, merged);
        s.pushback_pos = 0;
        s.pos -= @intCast(bytes.len);
    }
};

pub const Demuxer = struct {
    /// The error set demux.zig's layer returns.
    pub const ReadError = Error;

    gpa: std.mem.Allocator,
    src: Source,
    streams: std.ArrayList(Stream) = .empty,
    chapters: vorbiscomment.Chapters = .{},
    headers: bool = false,
    curidx: i32 = -1,
    page_pos: i64 = -1,
    /// libavformat's `data_offset`.
    data_offset: i64 = 0,
    /// The page buffer for one page's bytes after its capture pattern.
    page: [max_page_size]u8 = undefined,
    /// The packet returned last.
    current: std.ArrayList(u8) = .empty,
    /// The returned packet's side data.
    side_metadata: ?[]u8 = null,
    side_extradata: ?[]u8 = null,

    fn freeSideData(d: *Demuxer) void {
        if (d.side_metadata) |b| d.gpa.free(b);
        if (d.side_extradata) |b| d.gpa.free(b);
        d.side_metadata = null;
        d.side_extradata = null;
    }

    /// ogg_read_header on a source that cannot seek (a pipe): the
    /// streams' headers, read up to the first data packet of any stream.
    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader) Error!*Demuxer {
        return initWith(gpa, reader, null);
    }

    /// ogg_read_header on a seekable source read from its start (a
    /// file): as `init`, then ogg_get_length's scans, which set the
    /// streams' durations and start times and, as FFmpeg's do, leave the
    /// mappings' private state where they leave it.
    pub fn initSeekable(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: seek.Seeker) Error!*Demuxer {
        return initWith(gpa, reader, seeker);
    }

    fn initWith(gpa: std.mem.Allocator, reader: *std.Io.Reader, seeker: ?seek.Seeker) Error!*Demuxer {
        const d = try gpa.create(Demuxer);
        errdefer gpa.destroy(d);
        d.* = .{ .gpa = gpa, .src = .{ .reader = reader, .seeker = seeker } };
        if (seeker) |sk| d.src.pos = @intCast(sk.position());
        errdefer d.deinitFields();
        while (!d.headers) {
            var sid: i32 = -1;
            d.oggPacket(&sid, null, null, null) catch |err| return switch (err) {
                error.EndOfStream => error.Truncated,
                else => |e| e,
            };
        }
        for (d.streams.items) |*os| {
            if (os.header < 0) {
                // "Header parsing failed": the stream loses its codec.
                os.codec = null;
                os.info.codec = null;
            }
            if (os.start_granule != no_granule) {
                const pts = gpToPts(os, os.start_granule, null);
                os.lastpts = pts;
                os.info.start_time = pts;
            }
        }
        if (seeker != null) try d.getLength();
        return d;
    }

    /// ogg_save: the streams' page and packet state, kept for `restore`.
    /// Their buffers are copied for the scan; the mappings' private
    /// state and the stream info stay shared, as FFmpeg's pointers do.
    fn save(d: *Demuxer) Error!Snapshot {
        const saved = try d.gpa.alloc(Stream, d.streams.items.len);
        errdefer d.gpa.free(saved);
        for (d.streams.items, saved) |*os, *copy| {
            copy.* = os.*;
            // Shared: owned by the working stream only.
            copy.info = .{};
            copy.opus = .{};
            copy.vorbis = .{};
        }
        var done: usize = 0;
        errdefer for (d.streams.items[0..done], saved[0..done]) |*os, *copy| {
            os.buf.deinit(d.gpa);
            os.buf = copy.buf;
        };
        for (d.streams.items) |*os| {
            os.buf = .empty;
            try os.buf.appendSlice(d.gpa, saved[done].buf.items);
            os.new_metadata = null;
            os.new_extradata = null;
            done += 1;
        }
        return .{ .pos = d.src.pos, .curidx = d.curidx, .streams = saved };
    }

    /// ogg_restore: the saved state back, the source where it was.
    fn restore(d: *Demuxer, snap: Snapshot) Error!void {
        defer d.gpa.free(snap.streams);
        // Streams a scan added are dropped (FFmpeg keeps their AVStream).
        while (d.streams.items.len > snap.streams.len) {
            var extra = d.streams.pop().?;
            extra.deinit(d.gpa);
        }
        for (d.streams.items, snap.streams) |*os, saved| {
            os.buf.deinit(d.gpa);
            if (os.new_metadata) |b| d.gpa.free(b);
            if (os.new_extradata) |b| d.gpa.free(b);
            const info = os.info;
            const opus = os.opus;
            const vorbis = os.vorbis;
            os.* = saved;
            os.info = info;
            os.opus = opus;
            os.vorbis = vorbis;
        }
        try d.src.seekTo(snap.pos);
        d.page_pos = -1;
        d.curidx = snap.curidx;
    }

    /// ogg_reset: every stream's page and packet state cleared, as after
    /// a seek; a stream read from the data's start starts at 0.
    fn reset(d: *Demuxer) void {
        const start_pos = d.src.pos;
        for (d.streams.items) |*os| {
            os.buf.clearRetainingCapacity();
            os.pstart = 0;
            os.psize = 0;
            os.granule = no_granule;
            os.lastpts = nopts;
            os.lastdts = nopts;
            os.sync_pos = -1;
            os.page_pos = 0;
            os.nsegs = 0;
            os.segp = 0;
            os.incomplete = false;
            os.got_data = false;
            if (start_pos <= d.data_offset) os.lastpts = 0;
            os.start_trimming = 0;
            os.end_trimming = 0;
            if (os.new_metadata) |b| d.gpa.free(b);
            if (os.new_extradata) |b| d.gpa.free(b);
            os.new_metadata = null;
            os.new_extradata = null;
        }
        d.page_pos = -1;
        d.curidx = -1;
    }

    /// ogg_get_length: each stream's duration from the last granule in the
    /// input's last 65307 bytes, less its start, which a scan of the
    /// packets from the data's start finds when no packet set it yet.
    fn getLength(d: *Demuxer) Error!void {
        const seeker = d.src.seeker.?;
        const size: i64 = @intCast(seeker.size() orelse return);
        const end = if (size > max_page_size) size - max_page_size else 0;
        var streams_left: i32 = 0;
        {
            const snap = try d.save();
            errdefer d.gpa.free(snap.streams);
            try d.src.seekTo(end);
            d.page_pos = -1;
            while (true) {
                var i: i32 = -1;
                d.readPage(&i) catch break;
                if (i < 0) continue;
                const os = &d.streams.items[@intCast(i)];
                if (os.granule == no_granule or os.granule == 0 or os.codec == null) continue;
                os.info.duration = gpToPts(os, os.granule, null);
                if (os.info.start_time != nopts) {
                    os.info.duration -= os.info.start_time;
                    streams_left -= @intFromBool(os.got_start == -1);
                    os.got_start = 1;
                } else if (os.got_start == 0) {
                    os.got_start = -1;
                    streams_left += 1;
                }
            }
            try d.restore(snap);
        }
        const snap = try d.save();
        errdefer d.gpa.free(snap.streams);
        try d.src.seekTo(d.data_offset);
        d.reset();
        while (streams_left > 0) {
            var i: i32 = -1;
            d.oggPacket(&i, null, null, null) catch break;
            if (i < 0) continue;
            const os = &d.streams.items[@intCast(i)];
            var unused: i64 = undefined;
            const pts = calcPts(os, &unused);
            if (os.info.duration == nopts) continue;
            if (pts != nopts and os.info.start_time == nopts and os.got_start == 0) {
                os.info.duration -= pts;
                os.got_start = 1;
                streams_left -= 1;
            } else if (os.info.start_time != nopts and os.got_start == 0) {
                os.got_start = 1;
                streams_left -= 1;
            }
        }
        try d.restore(snap);
    }

    fn deinitFields(d: *Demuxer) void {
        d.freeSideData();
        for (d.streams.items) |*s| s.deinit(d.gpa);
        d.streams.deinit(d.gpa);
        d.chapters.deinit(d.gpa);
        d.src.deinit(d.gpa);
        d.current.deinit(d.gpa);
    }

    pub fn deinit(d: *Demuxer) void {
        d.deinitFields();
        d.gpa.destroy(d);
    }

    pub fn streamCount(d: *const Demuxer) usize {
        return d.streams.items.len;
    }

    pub fn stream(d: *const Demuxer, i: usize) *const StreamInfo {
        return &d.streams.items[i].info;
    }

    /// What libavformat's layer needs of stream `i` (demux.zig's Source).
    pub fn setup(d: *const Demuxer, i: usize) demux.Setup {
        const info = &d.streams.items[i].info;
        return .{
            .known = info.codec != null,
            .time_base = info.time_base,
            .sample_rate = info.sample_rate,
            .channels = info.channels,
            .parse_flac = info.codec == .flac,
            // The reference build decodes FLAC, not Opus or Vorbis.
            .has_decoder = info.codec == .flac,
            .bit_rate = info.bit_rate,
        };
    }

    pub fn durationOf(d: *Demuxer, i: usize) *i64 {
        return &d.streams.items[i].info.duration;
    }

    pub fn fileSize(d: *const Demuxer) ?u64 {
        const seeker = d.src.seeker orelse return null;
        return seeker.size();
    }

    pub fn dataOffset(d: *const Demuxer) i64 {
        return d.data_offset;
    }

    /// The stream's start time, which the demuxer and libavformat's layer
    /// both set.
    pub fn startTime(d: *Demuxer, i: usize) *i64 {
        return &d.streams.items[i].info.start_time;
    }

    fn findStream(d: *const Demuxer, serial: u32) ?usize {
        for (d.streams.items, 0..) |s, i| if (s.serial == serial) return i;
        return null;
    }

    fn dataPacketsSeen(d: *const Demuxer) bool {
        for (d.streams.items) |s| if (s.got_data) return true;
        return false;
    }

    /// ogg_read_page: one page into its stream's buffer; `sid` -1 for a
    /// page refused (CRC, version), which is pushed back past its capture
    /// pattern. EndOfStream at the end of the input.
    fn readPage(d: *Demuxer, sid: *i32) (Error || error{EndOfStream})!void {
        var sync: [4]u8 = undefined;
        if (try d.src.read(&sync) < 4) return error.EndOfStream;
        var sp: usize = 0;
        var i: usize = 0;
        while (true) {
            if (sync[sp & 3] == 'O' and sync[(sp + 1) & 3] == 'g' and sync[(sp + 2) & 3] == 'g' and sync[(sp + 3) & 3] == 'S') break;
            var c: [1]u8 = undefined;
            if (try d.src.read(&c) == 0) return error.EndOfStream;
            sync[sp & 3] = c[0];
            sp += 1;
            i += 1;
            if (i >= max_page_size) return error.InvalidOgg; // "cannot find sync word"
        }
        const start_pos = d.src.pos;
        var head: [23]u8 = undefined;
        var got = try d.src.read(&head);
        // FFmpeg's avio_r8 past the end reads zeros, and the page then
        // fails its CRC and the next read ends the input: the end either way.
        if (got < head.len) return error.EndOfStream;
        const version = head[0];
        const flags = head[1];
        const gp = std.mem.readInt(u64, head[2..10], .little);
        const serial = std.mem.readInt(u32, head[10..14], .little);
        const crc = std.mem.readInt(u32, head[18..22], .little);
        const nsegs = head[22];
        const page_pos = start_pos - 4;
        var segments: [255]u8 = undefined;
        got = try d.src.read(segments[0..nsegs]);
        if (got < nsegs) return error.EndOfStream;
        var size: usize = 0;
        for (segments[0..nsegs]) |s| size += s;
        const body = d.page[0..size];
        got = try d.src.read(body);
        if (got < size) return error.EndOfStream;

        var c: Crc = .init();
        c.update("OggS");
        var hdr = head;
        @memset(hdr[18..22], 0);
        c.update(&hdr);
        c.update(segments[0..nsegs]);
        c.update(body);
        if (c.final() != crc or version != 0) {
            // "CRC mismatch!" or "Invalid Ogg vers!": back to just after
            // the capture pattern.
            var all = try d.gpa.alloc(u8, head.len + nsegs + size);
            defer d.gpa.free(all);
            @memcpy(all[0..head.len], &head);
            @memcpy(all[head.len..][0..nsegs], segments[0..nsegs]);
            @memcpy(all[head.len + nsegs ..], body);
            try d.src.unread(d.gpa, all);
            sid.* = -1;
            return;
        }

        var idx = d.findStream(serial);
        if (idx == null) {
            idx = if (d.dataPacketsSeen()) try d.replaceStream(serial, body) else try d.newStream(serial);
        }
        const os = &d.streams.items[idx.?];
        try os.buf.appendSlice(d.gpa, body);
        d.page_pos = page_pos;
        os.page_pos = page_pos;
        os.nsegs = nsegs;
        os.segp = 0;
        os.got_data = flags & flag_bos == 0;
        os.granule = gp;
        os.flags = flags;
        @memcpy(os.segments[0..nsegs], segments[0..nsegs]);
        if (flags & flag_cont != 0 or os.incomplete) {
            if (os.psize == 0) {
                // The packet began before the input: skip to its end.
                while (os.segp < os.nsegs) {
                    const seg = os.segments[os.segp];
                    os.segp += 1;
                    os.pstart += seg;
                    if (seg < 255) break;
                }
                os.sync_pos = os.page_pos;
            }
        } else {
            os.psize = 0;
            os.sync_pos = os.page_pos;
        }
        sid.* = @intCast(idx.?);
    }

    /// ogg_new_stream.
    fn newStream(d: *Demuxer, serial: u32) Error!usize {
        try d.streams.append(d.gpa, .{ .serial = serial });
        return d.streams.items.len - 1;
    }

    /// ogg_replace_stream: a chained stream replaces the only one.
    fn replaceStream(d: *Demuxer, serial: u32, magic: []const u8) Error!usize {
        if (d.streams.items.len != 1) return error.UnsupportedFormat;
        const codec = findCodec(magic) orelse return error.InvalidOgg; // "Cannot identify new stream"
        const os = &d.streams.items[0];
        if (os.codec != codec) return error.InvalidOgg; // AVERROR(EINVAL)
        os.serial = serial;
        os.lastpts = 0;
        os.lastdts = 0;
        os.flags = 0;
        os.start_trimming = 0;
        os.end_trimming = 0;
        os.replace = true;
        return 0;
    }

    /// ogg_packet: the next complete packet; `sid` -1 when none is
    /// returned (a header, a page refused, a stream without a codec).
    fn oggPacket(d: *Demuxer, sid: *i32, dstart: ?*usize, dsize: ?*usize, fpos: ?*i64) (Error || error{EndOfStream})!void {
        sid.* = -1;
        var complete = false;
        var segp: usize = 0;
        var psize: usize = 0;
        var idx: i32 = undefined;
        while (!complete) {
            idx = d.curidx;
            while (idx < 0) try d.readPage(&idx);
            const os = &d.streams.items[@intCast(idx)];
            if (os.codec == null) {
                if (os.header < 0) {
                    os.codec = findCodec(os.buf.items);
                    if (os.codec == null) {
                        // "Codec not found".
                        os.header = 0;
                        return;
                    }
                } else return;
            }
            segp = os.segp;
            psize = os.psize;
            while (os.segp < os.nsegs) {
                const ss = os.segments[os.segp];
                os.segp += 1;
                os.psize += ss;
                if (ss < 255) {
                    complete = true;
                    break;
                }
            }
            if (!complete and os.segp == os.nsegs) {
                d.curidx = -1;
                os.incomplete = os.psize != 0;
            }
        }
        const i: usize = @intCast(idx);
        const os = &d.streams.items[i];
        d.curidx = idx;
        os.incomplete = false;
        os.page_start = segp == 0;
        if (os.header != 0) {
            const ret = try d.header(i);
            os.header = ret;
            if (ret == 0) {
                os.segp = segp;
                os.psize = psize;
                d.headers = true;
                if (d.data_offset == 0) d.data_offset = os.sync_pos;
                for (d.streams.items) |cur| {
                    if (cur.incomplete) d.data_offset = @min(d.data_offset, cur.sync_pos);
                }
            } else {
                os.nb_header += 1;
                os.pstart += os.psize;
                os.psize = 0;
            }
        } else {
            os.pflags = 0;
            os.pduration = 0;
            const ret = try d.packet(i);
            if (ret == 0) {
                sid.* = idx;
                if (dstart) |p| p.* = os.pstart;
                if (dsize) |p| p.* = os.psize;
                if (fpos) |p| p.* = os.sync_pos;
                // FFmpeg copies the packet from the buffer after resetting
                // its indices below, the bytes still there: copy it now.
                if (dstart != null) {
                    d.current.clearRetainingCapacity();
                    try d.current.appendSlice(d.gpa, os.packet());
                }
            }
            os.pstart += os.psize;
            os.psize = 0;
            if (os.pstart == os.buf.items.len) {
                os.buf.clearRetainingCapacity();
                os.pstart = 0;
            }
            os.sync_pos = os.page_pos;
        }
        os.page_end = true;
        for (os.segments[os.segp..os.nsegs]) |seg| {
            if (seg < 255) {
                os.page_end = false;
                break;
            }
        }
        if (os.segp == os.nsegs) d.curidx = -1;
    }

    /// The codec's `header` callback: 1 a header, 0 the first data packet.
    fn header(d: *Demuxer, i: usize) Error!i32 {
        const os = &d.streams.items[i];
        return switch (os.codec.?) {
            .flac => d.flacHeader(os),
            .opus => d.opusHeader(os),
            .vorbis => d.vorbisHeader(os),
        };
    }

    /// The codec's `packet` callback: 0 a data packet, 1 one to skip.
    fn packet(d: *Demuxer, i: usize) Error!i32 {
        const os = &d.streams.items[i];
        return switch (os.codec.?) {
            .flac => d.flacPacket(os),
            .opus => d.opusPacket(os),
            .vorbis => d.vorbisPacket(os),
        };
    }

    // FLAC (oggparseflac.c).

    fn flacHeader(d: *Demuxer, os: *Stream) Error!i32 {
        const p = os.packet();
        // FFmpeg reads the byte at the packet's start even when it is
        // empty: the next packet's, or the buffer's zero padding.
        const first = os.byteAt(os.pstart);
        if (first == 0xff) return 0;
        const mdt = first & 0x7f;
        if (mdt == 0x7f) {
            if (p.len < 1 + 4 + 4 + 4 + 4 + flac.streaminfo_size) return error.InvalidOgg;
            // "FLAC", the major version (1), the minor, the header count,
            // "fLaC", then the block header, which must be 34 bytes long;
            // FFmpeg fails with -1 (EPERM) otherwise.
            if (p[5] != 1) return error.InvalidOgg;
            if (std.mem.readInt(u32, p[13..17], .big) != flac.streaminfo_size) return error.InvalidOgg;
            os.info.codec = .flac;
            os.info.extradata.clearRetainingCapacity();
            try os.info.extradata.appendSlice(d.gpa, p[17..][0..flac.streaminfo_size]);
            const e = os.info.extradata.items;
            const rate: u32 = std.mem.readInt(u24, e[10..13], .big) >> 4;
            if (rate == 0) return error.InvalidOgg;
            os.info.time_base = .{ .num = 1, .den = @intCast(rate) };
            // The rate and channels FFmpeg's avformat_find_stream_info
            // takes from STREAMINFO.
            const si = flac.StreamInfo.parse(e[0..flac.streaminfo_size]);
            os.info.sample_rate = si.sample_rate;
            os.info.channels = si.channels;
        } else if (mdt == 4) {
            if (p.len >= 4) _ = vorbiscomment.parse(d.gpa, &os.info.tags, &d.chapters, p[4..]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // ff_vorbis_stream_comment's failure is ignored here.
                error.InvalidComment => {},
            };
        }
        return 1;
    }

    fn flacPacket(d: *Demuxer, os: *Stream) Error!i32 {
        const p = os.packet();
        if (p.len > 5 and std.mem.eql(u8, p[0..5], "\x7fFLAC")) return 1;
        if (p.len > 0 and p[0] & 0x7f == 4) {
            try d.updateMetadata(os, if (p.len >= 4) p[4..] else &.{});
            return 1;
        }
        return 0;
    }

    /// ff_vorbis_update_metadata: the stream's tags replaced, and a
    /// strings-metadata side data for the next packet.
    fn updateMetadata(d: *Demuxer, os: *Stream, buf: []const u8) Error!void {
        os.info.tags.clear(d.gpa);
        _ = vorbiscomment.parse(d.gpa, &os.info.tags, &d.chapters, buf) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidComment => error.InvalidOgg,
        };
        // av_packet_pack_dictionary: each key and value NUL-terminated;
        // an empty dictionary gives an empty side data.
        var packed_tags: std.ArrayList(u8) = .empty;
        errdefer packed_tags.deinit(d.gpa);
        for (os.info.tags.items()) |entry| {
            try packed_tags.appendSlice(d.gpa, entry.key);
            try packed_tags.append(d.gpa, 0);
            try packed_tags.appendSlice(d.gpa, entry.value);
            try packed_tags.append(d.gpa, 0);
        }
        if (os.new_metadata) |b| d.gpa.free(b);
        os.new_metadata = try packed_tags.toOwnedSlice(d.gpa);
    }

    // Opus (oggparseopus.c).

    fn parseOpusHeader(os: *Stream, p: []const u8, d: *Demuxer) Error!i32 {
        if (p.len < 19 or p[8] & 0xf0 != 0) return error.InvalidOgg;
        os.info.codec = .opus;
        const channels = p[9];
        if (os.info.channels != 0 and channels != os.info.channels) return error.UnsupportedFormat;
        os.info.channels = channels;
        os.opus.pre_skip = std.mem.readInt(u16, p[10..12], .little);
        os.info.initial_padding = os.opus.pre_skip;
        os.start_trimming = os.opus.pre_skip;
        os.info.extradata.clearRetainingCapacity();
        try os.info.extradata.appendSlice(d.gpa, p);
        os.info.sample_rate = 48000;
        os.info.seek_preroll = 3840; // 80 ms
        os.info.time_base = .{ .num = 1, .den = 48000 };
        os.opus.need_comments = 1;
        return 1;
    }

    fn opusHeader(d: *Demuxer, os: *Stream) Error!i32 {
        const p = os.packet();
        if (os.flags & flag_bos != 0) return parseOpusHeader(os, p, d);
        if (os.opus.need_comments != 0) {
            if (p.len < 8 or !std.mem.eql(u8, p[0..8], "OpusTags")) return error.InvalidOgg;
            _ = vorbiscomment.parse(d.gpa, &os.info.tags, &d.chapters, p[8..]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidComment => {},
            };
            os.opus.need_comments -= 1;
            return 1;
        }
        return 0;
    }

    fn opusPacket(d: *Demuxer, os: *Stream) Error!i32 {
        const p = os.packet();
        if (p.len == 0) return error.InvalidOgg;
        if (os.granule > (@as(u64, 1) << 62)) return error.InvalidOgg; // "Unsupported huge granule pos"
        if (p.len > 8 and std.mem.eql(u8, p[0..8], "OpusHead")) {
            _ = try parseOpusHeader(os, p, d);
            return 1;
        }
        if (p.len > 8 and std.mem.eql(u8, p[0..8], "OpusTags")) {
            try d.updateMetadata(os, p[8..]);
            os.opus.need_comments = 0;
            return 1;
        }
        if ((os.lastpts == 0 or os.lastpts == nopts) and os.flags & flag_eos == 0) {
            // FFmpeg's `int duration`, which wraps.
            var duration: i32 = 0;
            const d0 = opusDuration(p) orelse {
                os.pflags |= 2; // AV_PKT_FLAG_CORRUPT
                return 0;
            };
            duration +%= @truncate(d0);
            const base = os.pstart;
            var last_pkt = base + os.psize;
            var next_pkt = last_pkt;
            var seg = os.segp;
            while (seg < os.nsegs) : (seg += 1) {
                next_pkt += os.segments[seg];
                if (os.segments[seg] < 255 and next_pkt != last_pkt) {
                    if (opusDuration(os.buf.items[last_pkt..next_pkt])) |dd| {
                        if (dd > 0) duration +%= @truncate(dd);
                    }
                    last_pkt = next_pkt;
                }
            }
            // `os->granule - duration`, uint64_t arithmetic.
            const lp: i64 = @bitCast(os.granule -% @as(u64, @bitCast(@as(i64, duration))));
            os.lastpts = lp;
            os.lastdts = lp;
        }
        os.pduration = opusDuration(p) orelse return error.InvalidOgg;
        if (os.lastpts != nopts) {
            if (os.info.start_time == nopts) os.info.start_time = os.lastpts;
            os.lastpts -= os.opus.pre_skip;
            os.lastdts = os.lastpts;
            os.opus.cur_dts = os.lastpts;
        }
        os.opus.cur_dts += os.pduration;
        if (os.flags & flag_eos != 0) {
            var skip: i64 = os.opus.cur_dts -% @as(i64, @bitCast(os.granule)) +% os.opus.pre_skip;
            skip = @min(skip, os.pduration);
            if (skip > 0) {
                os.pduration = if (skip < os.pduration) os.pduration - skip else 1;
                os.end_trimming = @intCast(skip);
            }
        }
        return 0;
    }

    // Vorbis (oggparsevorbis.c).

    fn vorbisParseHeader(os: *Stream, p: []const u8) Error!i32 {
        if (p.len != 30) return error.InvalidOgg;
        if (std.mem.readInt(u32, p[7..11], .little) != 0) return error.InvalidOgg;
        const channels = p[11];
        if (os.info.channels != 0 and channels != os.info.channels) return error.UnsupportedFormat;
        os.info.channels = channels;
        const srate = std.mem.readInt(i32, p[12..16], .little);
        os.info.bit_rate = std.mem.readInt(i32, p[20..24], .little);
        const bs0 = p[28] & 15;
        const bs1 = p[28] >> 4;
        if (bs0 > bs1 or bs0 < 6 or bs1 > 13) return error.InvalidOgg;
        if (p[29] != 1) return error.InvalidOgg;
        os.info.codec = .vorbis;
        if (srate > 0) {
            if (os.info.sample_rate != 0 and srate != os.info.sample_rate) return error.UnsupportedFormat;
            os.info.sample_rate = @intCast(srate);
            os.info.time_base = .{ .num = 1, .den = srate };
        }
        return 1;
    }

    fn vorbisHeader(d: *Demuxer, os: *Stream) Error!i32 {
        const p = os.packet();
        const v = &os.vorbis;
        v.bos_page_pos = -1;
        const pkt_type = os.byteAt(os.pstart);
        if (pkt_type & 1 == 0) return if (v.vp != null) 0 else error.InvalidOgg;
        if (pkt_type > 5) return 1; // "Ignoring packet with unknown type"
        if (p.len == 0) return error.InvalidOgg;
        const slot = pkt_type >> 1;
        if (v.packet[slot] != null) return error.InvalidOgg;
        if ((pkt_type > 1 and v.packet[0] == null) or (pkt_type > 3 and v.packet[1] == null)) {
            return if (v.vp != null) 0 else error.InvalidOgg;
        }
        v.packet[slot] = try d.gpa.dupe(u8, p);
        if (pkt_type == 1) return vorbisParseHeader(os, p);
        if (pkt_type == 3) {
            // vorbis_update_metadata: nothing for 8 bytes or fewer; its
            // strings-metadata goes to the first data packet.
            const updated = p.len <= 8 or blk: {
                d.updateMetadata(os, p[7 .. p.len - 1]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk false,
                };
                break :blk true;
            };
            if (updated) {
                // libvorbis needs only the vendor: FFmpeg cuts the rest
                // from the kept header.
                const c = v.packet[1].?;
                if (c.len > 10) {
                    const new_len: usize = 7 + 4 + std.mem.readInt(u32, c[7..11], .little) + 4 + 1;
                    if (new_len >= 16 and new_len < p.len) {
                        std.mem.writeInt(u32, c[new_len - 5 ..][0..4], 0, .little);
                        c[new_len - 1] = 1;
                        v.packet[1] = try d.gpa.realloc(c, new_len);
                    }
                }
            }
        } else {
            if (v.vp != null) return error.InvalidOgg;
            try fixupHeaders(d.gpa, v, &os.info.extradata);
            const parser = VorbisParser.init(v.packet[0].?, v.packet[2].?);
            // fixup_vorbis_headers releases the headers it packs.
            v.deinit(d.gpa);
            // av_vorbis_parse_init's failure is AVERROR_UNKNOWN.
            v.vp = parser orelse return error.InvalidOgg;
        }
        return 1;
    }

    fn checkPacketOrder(d: *Demuxer, v: *VorbisState, kind: VorbisPacketType) bool {
        const last = v.last_packet;
        var bad = false;
        switch (kind) {
            .reserved => return true,
            .data => bad = last == .id or last == .comment,
            .id => bad = last == .id or last == .comment,
            .comment => bad = last != .id,
            .setup => bad = last != .comment,
        }
        if (bad or kind == .id) v.deinit(d.gpa);
        v.last_packet = if (bad and kind != .id) .data else kind;
        return !bad;
    }

    fn vorbisPacket(d: *Demuxer, os: *Stream) Error!i32 {
        const p = os.packet();
        const v = &os.vorbis;
        if (p.len == 0) return error.InvalidOgg;
        if (v.vp == null) return error.InvalidOgg;
        if (v.bos_page_pos < 0) v.bos_page_pos = os.page_pos;
        const bos = os.page_start and os.page_pos == v.bos_page_pos;
        if (bos or (os.page_start and os.lastpts == nopts)) v.vp.?.reset();
        if (bos) v.last_page_granule = 0;
        var flags: u32 = 0;
        const duration = v.vp.?.frame(p, &flags) orelse {
            os.pflags |= 2;
            return 0;
        };
        os.pduration = duration;
        if (v.ts_offset == 0) v.ts_offset = os.pduration;
        if (bos) {
            if (os.lastpts != nopts) {
                if (os.info.start_time == nopts) {
                    os.info.start_time = os.lastpts;
                    if (os.info.duration != nopts) os.info.duration -= os.info.start_time;
                }
                os.lastpts -= v.ts_offset;
            }
            if (os.lastdts != nopts) os.lastdts -= v.ts_offset;
        } else if (os.page_start and os.lastpts == nopts and os.flags & flag_eos == 0 and @as(i64, @bitCast(os.granule)) >= 0) {
            // FFmpeg's `int page_duration`, which wraps.
            var page_duration: i32 = @truncate(os.pduration);
            var last_pkt = os.pstart + os.psize;
            var next_pkt = last_pkt;
            var seg = os.segp;
            while (seg < os.nsegs) : (seg += 1) {
                next_pkt += os.segments[seg];
                if (os.segments[seg] < 255 and next_pkt != last_pkt) {
                    var pkt_flags: u32 = 0;
                    const dd = v.vp.?.frame(os.buf.items[last_pkt..next_pkt], &pkt_flags) orelse {
                        page_duration = @truncate(@as(i64, @bitCast(os.granule)));
                        break;
                    };
                    page_duration +%= @intCast(dd);
                    last_pkt = next_pkt;
                }
            }
            _ = v.vp.?.frame(p, &flags);
            const lp: i64 = @bitCast(os.granule -% @as(u64, @bitCast(@as(i64, page_duration))));
            os.lastpts = lp;
            os.lastdts = lp;
        }
        if (os.granule == 0 and os.pduration != 0) {
            os.lastpts = nopts;
            os.lastdts = nopts;
        }
        if (os.flags & flag_eos != 0) {
            if (os.page_start) v.eos_page_duration = 0;
            if (os.segp != os.nsegs) {
                v.eos_page_duration += os.pduration;
            } else {
                const skip = v.eos_page_duration +% os.pduration -% (@as(i64, @bitCast(os.granule)) -% v.last_page_granule);
                if (skip > 0) os.end_trimming = @intCast(skip);
            }
        } else v.last_page_granule = @bitCast(os.granule);

        var skip_packet = false;
        if (flags & VorbisParser.flag_header != 0) {
            _ = d.checkPacketOrder(v, .id);
            _ = try vorbisParseHeader(os, p);
            try keepPacket(d.gpa, &v.packet[0], p);
            skip_packet = true;
        }
        if (flags & VorbisParser.flag_comment != 0) {
            if (!d.checkPacketOrder(v, .comment)) return 1;
            if (p.len > 8) try d.updateMetadata(os, p[7 .. p.len - 1]);
            try keepPacket(d.gpa, &v.packet[1], p);
            flags = 0;
            skip_packet = true;
        }
        if (flags & VorbisParser.flag_setup != 0) {
            if (!d.checkPacketOrder(v, .setup)) return 1;
            try keepPacket(d.gpa, &v.packet[2], p);
            skip_packet = true;
        }
        if (!skip_packet) _ = d.checkPacketOrder(v, if (p[0] & 1 != 0) .reserved else .data);
        if (v.packet[0] != null and v.packet[1] != null and v.packet[2] != null) {
            var extradata: std.ArrayList(u8) = .empty;
            errdefer extradata.deinit(d.gpa);
            const id = try d.gpa.dupe(u8, v.packet[0].?);
            defer d.gpa.free(id);
            const setup_header = try d.gpa.dupe(u8, v.packet[2].?);
            defer d.gpa.free(setup_header);
            try fixupHeaders(d.gpa, v, &extradata);
            v.deinit(d.gpa);
            if (os.new_extradata) |b| d.gpa.free(b);
            os.new_extradata = try extradata.toOwnedSlice(d.gpa);
            v.vp = VorbisParser.init(id, setup_header) orelse return error.InvalidOgg;
            v.bos_page_pos = -1;
        }
        return @intFromBool(skip_packet);
    }

    /// ogg_read_packet's demuxer part: the next packet with the
    /// timestamps, duration, flags and side data FFmpeg's demuxer gives
    /// it; null at the end.
    pub fn next(d: *Demuxer) Error!?Packet {
        while (true) {
            var idx: i32 = -1;
            var pstart: usize = 0;
            var psize: usize = 0;
            var fpos: i64 = 0;
            d.oggPacket(&idx, &pstart, &psize, &fpos) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => |e| return e,
            };
            if (idx < 0) continue;
            const i: usize = @intCast(idx);
            const os = &d.streams.items[i];
            var dts: i64 = nopts;
            const pts = calcPts(os, &dts);
            std.debug.assert(d.current.items.len == psize);
            var out: Packet = .{
                .stream = i,
                .data = d.current.items,
                .pts = pts,
                .dts = dts,
                .duration = os.pduration,
                .flags = os.pflags,
                .pos = fpos,
            };
            if (os.start_trimming != 0 or os.end_trimming != 0) {
                out.skip = .{ os.start_trimming, os.end_trimming };
                os.start_trimming = 0;
                os.end_trimming = 0;
            }
            if (os.replace) {
                os.replace = false;
                out.pts = nopts;
                out.dts = nopts;
            }
            // The side data passes to the packet, owned until the next call.
            d.freeSideData();
            if (os.new_metadata) |b| {
                d.side_metadata = b;
                out.new_metadata = b;
                os.new_metadata = null;
            }
            if (os.new_extradata) |b| {
                d.side_extradata = b;
                out.new_extradata = b;
                os.new_extradata = null;
            }
            return out;
        }
    }
};

fn keepPacket(gpa: std.mem.Allocator, slot: *?[]u8, p: []const u8) Error!void {
    const copy = try gpa.dupe(u8, p);
    if (slot.*) |old| gpa.free(old);
    slot.* = copy;
}

/// fixup_vorbis_headers: the three headers in Xiph lacing (2, the first
/// two lengths, then the headers), which `vp` is made from; the headers
/// are released.
fn fixupHeaders(gpa: std.mem.Allocator, v: *VorbisState, out: *std.ArrayList(u8)) Error!void {
    const total: u64 = v.packet[0].?.len + v.packet[1].?.len + v.packet[2].?.len;
    if (total + total / 255 + 64 > std.math.maxInt(i32)) return error.InvalidOgg;
    out.clearRetainingCapacity();
    try out.append(gpa, 2);
    for (v.packet[0..2]) |h| {
        var n = h.?.len;
        while (n >= 255) : (n -= 255) try out.append(gpa, 255);
        try out.append(gpa, @intCast(n));
    }
    for (v.packet) |h| try out.appendSlice(gpa, h.?);
}

/// ogg_find_codec over the supported mappings' magics.
fn findCodec(buf: []const u8) ?Codec {
    if (buf.len >= 7 and std.mem.eql(u8, buf[0..7], "\x01vorbis")) return .vorbis;
    if (buf.len >= 5 and std.mem.eql(u8, buf[0..5], "\x7fFLAC")) return .flac;
    if (buf.len >= 8 and std.mem.eql(u8, buf[0..8], "OpusHead")) return .opus;
    return null;
}

/// oggparseopus.c's opus_duration: the packet's samples at 48 kHz from
/// its TOC byte; null for a code-3 packet without its count byte.
fn opusDuration(p: []const u8) ?i64 {
    if (p.len == 0) return 0;
    const toc = p[0];
    const config = toc >> 3;
    const count_code = toc & 3;
    const frame_size: i64 = if (config < 12)
        @max(480, 960 * @as(i64, config & 3))
    else if (config < 16)
        @as(i64, 480) << @intCast(config & 1)
    else
        @as(i64, 120) << @intCast(config & 3);
    var frames: i64 = 1;
    if (count_code == 3) {
        if (p.len < 2) return null;
        frames = p[1] & 0x3f;
    } else if (count_code != 0) frames = 2;
    return frame_size * frames;
}

/// ogg_gptopts: no mapping here converts its granules, so the granule is
/// the timestamp; one above INT64_MAX is none.
fn gpToPts(os: *const Stream, gp: u64, dts: ?*i64) i64 {
    _ = os;
    if (gp > std.math.maxInt(i64)) {
        if (dts) |p| p.* = @bitCast(gp);
        return nopts;
    }
    const pts: i64 = @intCast(gp);
    if (dts) |p| p.* = pts;
    return pts;
}

/// ogg_calc_pts: the timestamp left by the page before, then the page's
/// granule for the packet that ends it.
fn calcPts(os: *Stream, dts: *i64) i64 {
    var pts: i64 = nopts;
    dts.* = nopts;
    if (os.lastpts != nopts) {
        pts = os.lastpts;
        os.lastpts = nopts;
    }
    if (os.lastdts != nopts) {
        dts.* = os.lastdts;
        os.lastdts = nopts;
    }
    if (os.page_end and os.granule != no_granule) {
        // No supported mapping has its granule at the packet's start.
        os.lastpts = gpToPts(os, os.granule, &os.lastdts);
        os.granule = no_granule;
    }
    return pts;
}

const testing = std.testing;
const fixtures = @import("../testing/fixtures.zig");
const vectors = @embedFile("../testing/vectors/ogg.txt");

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

/// The vector lines of one fixture, after its `F` line.
fn block(name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.findPos(u8, vectors, start, "F ")) |at| {
        const line_end = std.mem.findScalarPos(u8, vectors, at, '\n') orelse vectors.len;
        const end = std.mem.findPos(u8, vectors, line_end, "\nF ") orelse vectors.len;
        if (std.mem.eql(u8, vectors[at + 2 .. line_end], name)) return vectors[line_end + 1 .. end];
        start = end;
    }
    return null;
}

fn codecName(c: ?Codec) []const u8 {
    return if (c) |k| @tagName(k) else "none";
}

/// What the demuxer's own layer decides, against FFmpeg's: the streams'
/// codec parameters, and each packet's stream, bytes, position and side
/// data, and how reading ends. Timestamps and durations come from
/// libavformat's layer on top (demux.zig).
fn checkFixture(gpa: std.mem.Allocator, comptime name: []const u8) !void {
    errdefer std.debug.print("ogg fixture {s}\n", .{name});
    const want = block(name) orelse return error.MissingVector;
    var lines = std.mem.splitScalar(u8, want, '\n');
    var reader: std.Io.Reader = .fixed(fixtures.ogg.bytes(name));
    const open_line = lines.next().?;
    // The oracle opens files, which seek.
    const d = Demuxer.initSeekable(gpa, &reader, .fixed(&reader)) catch |err| {
        const expected: Error = if (std.mem.eql(u8, open_line, "O EOF")) error.Truncated else if (std.mem.eql(u8, open_line, "O PATCHWELCOME")) error.UnsupportedFormat else error.InvalidOgg;
        try testing.expectEqual(expected, err);
        return;
    };
    defer d.deinit();
    try testing.expectEqualStrings("O ok", open_line);
    var layer = demux.Layer(Demuxer).init(gpa, d);
    defer layer.deinit();
    try layer.findStreamInfo();
    var buf: [256]u8 = undefined;
    var line = lines.next().?;
    var count: usize = 0;
    while (std.mem.startsWith(u8, line, "S ") or std.mem.startsWith(u8, line, "M ") or std.mem.startsWith(u8, line, "G ")) : (line = lines.next().?) {
        if (!std.mem.startsWith(u8, line, "S ")) continue;
        const info = d.stream(count);
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next();
        _ = f.next();
        try testing.expectEqualStrings(f.next().?, codecName(info.codec));
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}", .{info.sample_rate}));
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}", .{info.channels}));
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}/{d}", .{ info.time_base.num, info.time_base.den }));
        const duration = f.next().?;
        const start = f.next().?;
        {
            var dbuf: [32]u8 = undefined;
            try testing.expectEqualStrings(duration, if (info.duration == nopts) "N" else try std.fmt.bufPrint(&dbuf, "{d}", .{info.duration}));
        }
        {
            var sbuf: [32]u8 = undefined;
            const got_start = if (info.start_time == nopts) "N" else try std.fmt.bufPrint(&sbuf, "{d}", .{info.start_time});
            errdefer std.debug.print("start: want {s} got {s}\n", .{ start, got_start });
            try testing.expectEqualStrings(start, got_start);
        }
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}", .{info.initial_padding}));
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}", .{info.seek_preroll}));
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}", .{info.extradata.items.len}));
        const e_adler: u32 = if (info.extradata.items.len == 0) 0 else adler(info.extradata.items);
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}", .{e_adler}));
        count += 1;
    }
    try testing.expectEqual(count, d.streamCount());
    while (true) {
        if (std.mem.startsWith(u8, line, "R ")) {
            const end = layer.next();
            if (std.mem.eql(u8, line, "R EOF")) {
                try testing.expectEqual(null, try end);
            } else {
                try testing.expectError(error.InvalidOgg, end);
            }
            return;
        }
        try testing.expect(std.mem.startsWith(u8, line, "P "));
        const p = (try layer.next()) orelse return error.TestUnexpectedEnd;
        var got: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&got);
        try w.print("P {d} {d}", .{ p.stream, p.data.len });
        if (p.pts) |v| try w.print(" {d}", .{v}) else try w.writeAll(" N");
        if (p.dts) |v| try w.print(" {d}", .{v}) else try w.writeAll(" N");
        try w.print(" {d} {x} {d} {d}", .{ p.duration, p.flags, p.pos, adler(p.data) });
        try testing.expectEqualStrings(line, w.buffered());
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..8) |_| _ = f.next();
        try testing.expectEqualStrings(f.next().?, try std.fmt.bufPrint(&buf, "{d}", .{adler(p.data)}));
        line = lines.next().?;
        var skip_seen = false;
        while (line.len > 0 and (line[0] == 'K' or line[0] == 'Q' or line[0] == 'T')) : (line = lines.next().?) {
            switch (line[0]) {
                'K' => {
                    skip_seen = true;
                    const skip = p.skip orelse return error.TestExpectedSkip;
                    try testing.expectEqualStrings(line, try std.fmt.bufPrint(&buf, "K {d} {d}", .{ skip[0], skip[1] }));
                },
                'Q' => {
                    const e = p.new_extradata orelse return error.TestExpectedExtradata;
                    try testing.expectEqualStrings(line, try std.fmt.bufPrint(&buf, "Q {d} {d}", .{ e.len, adler(e) }));
                },
                'T' => {
                    const m = p.new_metadata orelse return error.TestExpectedMetadata;
                    try testing.expectEqualStrings(line, try std.fmt.bufPrint(&buf, "T {d} {d}", .{ m.len, adler(m) }));
                },
                else => unreachable,
            }
        }
        if (!skip_seen) try testing.expectEqual(null, p.skip);
    }
}

test "every fixture's streams and packets equal FFmpeg's demuxer (vectors/ogg.txt)" {
    inline for (fixtures.ogg.all) |fixture| {
        try checkFixture(testing.allocator, fixture.name);
    }
}

test "the content probe" {
    try testing.expectEqual(100, probeScore("OggS\x00\x02"));
    try testing.expectEqual(0, probeScore("OggS\x00\x08"));
    try testing.expectEqual(0, probeScore("OggS\x01\x02"));
    try testing.expectEqual(0, probeScore("Ogg"));
}
