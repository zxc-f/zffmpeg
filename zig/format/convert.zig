// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Synchronous conversion and stream copy between WAV, Wave64, AU and AIFF
//! (TODO.md T13a, T21b, T22b).
//!
//! The operation matrix (TODO.md T13), where WAV stands for WAV or Wave64 on
//! either side:
//!
//! | Input → output       | `transcode`                  | `copy`                                              |
//! | -------------------- | ---------------------------- | --------------------------------------------------- |
//! | into the same family | yes                          | yes                                                 |
//! | between families     | yes, through the PCM kernels | the codecs both carry, else `UnsupportedOperation` |
//!
//! Transcoding needs samples stored as s16 and writes the output container's
//! s16 codec. Stream copy needs the output to carry the input's codec: WAV and
//! AU share A-law and µ-law, AU and AIFF the big-endian integer and float
//! encodings, and WAV and AIFF u8, s16le (`sowt`), A-law and µ-law.
//!
//! A rate change cannot be requested yet (TODO.md T24); a channel layout can
//! (`Request.layout`, T23c), and the samples are rematrixed into it as
//! libswresample mixes them. Otherwise the output has the input's rate and
//! layout.
//!
//! `Conversion.init` reads the input up to its first sample and makes every
//! check that does not need the rest of it: the input header, the request
//! against the matrix, then the output header's limits and sizes (in that
//! order; the first failure wins). An input of unknown length, such as raw
//! PCM from a pipe, fails the output header check of every container whose
//! header holds the length; raw PCM output needs none. It writes nothing, so a rejected operation
//! leaves no output. `run` writes the output header, moves every frame,
//! validates the rest of the input (so an error after the data still fails the
//! operation) and finishes the output, which flushes. A failure found after
//! samples were written is still a failure; output is not atomic, and what to
//! do with a partial output is the caller's decision.
//!
//! The input is read as packets of whole frames (TODO.md T14a), timestamped in
//! frames since the start (`1/sample_rate`). Stream copy writes those packets'
//! bytes unchanged; transcoding sends them through `pcm.Decoder`, an
//! `audioconvert.Converter` when the sample storage changes or the request
//! dithers (T23a), and `pcm.Encoder` (the core/stage.zig contract) and writes
//! the encoded packets. The dither's noise follows FFmpeg's packet sizes for
//! the input, not this file's packets (`ffmpegPacketFrames`).
//! Neither keeps container metadata: the output has the writer's canonical
//! header, so WAV chunks other than `fmt ` and `data`, AU annotations and AIFF
//! chunks other than `FVER`, `COMM` and `SSND` are dropped.
//!
//! Nothing is allocated. Working memory is fixed, whatever the input length:
//! a 4 KiB packet buffer, for transcoding 8 KiB of decoded samples and 32 KiB
//! each of converted samples, the dither's scratch and encoded bytes, plus
//! the parsers' and writers' own 4 KiB scratch.

const std = @import("std");
const audio = @import("../core/audio.zig");
const samples_storage = @import("../core/samples.zig");
const pcm = @import("../codec/pcm.zig");
const Packet = @import("../core/packet.zig").Packet;
const metadata = @import("../core/metadata.zig");
const wav = @import("wav.zig");
const au = @import("au.zig");
const aiff = @import("aiff.zig");
const raw = @import("raw.zig");
const caf = @import("caf.zig");
const detect = @import("detect.zig");
const audioconvert = @import("../resample/audioconvert.zig");
const dither = @import("../resample/dither.zig");
const rematrix = @import("../resample/rematrix.zig");

pub const Container = detect.Container;

/// Parser limits for the input and writer limits for the output, per container.
pub const Limits = detect.Limits;

pub const Mode = enum {
    /// Decode the samples and encode them for the output container.
    transcode,
    /// Copy the encoded samples unchanged; both containers must carry the
    /// same codec.
    copy,
};

pub const Request = struct {
    output: Container,
    mode: Mode,
    /// The encoder for `transcode` (FFmpeg's `-c:a`, T23a), which the output
    /// must carry; null takes the output container's default codec. The
    /// samples convert to its storage as libswresample would. Not for `copy`.
    codec: ?pcm.Codec = null,
    /// libswresample's dither for `transcode` (FFmpeg's `-dither_method` and
    /// `-dither_scale`, T23a), applied where FFmpeg's would: when the sample
    /// storage changes to a narrower integer one (FFmpeg's filter graph
    /// converts nothing when it stays the same, as from s32 to a 24-bit
    /// encoder). `run` sets `output_sample_bits` as FFmpeg's command line
    /// does, whatever it holds here: 24 for a 24-bit encoder, which scales
    /// the noise. Ignored for `copy`, as FFmpeg ignores it.
    dither: dither.Options = .{},
    /// What the caller knows about the input: a forced format (FFmpeg's input
    /// `-f`, T16), its file name and length, raw PCM parameters (T22c).
    input: detect.Source = .{},
    /// Give an unspecified input layout the default for its channel count,
    /// as FFmpeg's command line does (`guess_input_channel_layout`, T23b),
    /// so the output header records it. FFmpeg skips the guess when its
    /// input `-ch_layout` names the layout, `6C` included; its `-ac` does
    /// not.
    guess_layout: bool = true,
    /// The output's channel layout (FFmpeg's output `-ch_layout`; its `-ac N`
    /// gives N unspecified channels), for `transcode` (T23c): the samples
    /// are rematrixed as libswresample mixes them. An unspecified layout
    /// becomes the default for its count, as FFmpeg's command line picks
    /// it for a PCM encoder. Null keeps the input's layout. With `copy`, a
    /// layout other than the input's is `UnsupportedOperation`.
    layout: ?audio.ChannelLayout = null,
    /// Carry the input's tags (T21c): `init` puts the tags FFmpeg's command
    /// would carry (`carriedTags`) from those before the input's `data` into
    /// the empty `tags.dictionary`, under FFmpeg's names, and a WAV output
    /// gets them as FFmpeg's writer would, in a `LIST`/`INFO` chunk. Only RIFF
    /// and RF64 inputs have tags, and only RIFF and RF64 outputs carry them;
    /// tags after the input's `data` come too late for the output header and
    /// are not carried. The dictionary must outlive the conversion. Without
    /// it nothing is allocated.
    tags: ?wav.Tags = null,
};

/// Failures before any output exists: the input header, the request and the
/// output header. `LimitExceeded` can come from the input's or the output's
/// limits.
pub const InitError = detect.Error || wav.HeaderError || au.HeaderError || aiff.HeaderError || raw.HeaderError || rematrix.Error || error{
    /// The request is outside the operation matrix: stream copy into a
    /// container that cannot carry the codec, or transcoding samples, or
    /// into a codec, not stored as s16 (sample-format conversion waits for
    /// TODO.md T23a).
    UnsupportedOperation,
};

/// Failures once output has started: the rest of the input, or the output.
pub const RunError = detect.Error || std.Io.Writer.Error;

pub const Error = InitError || RunError;

pub const Summary = struct {
    input: Container,
    output: Container,
    mode: Mode,
    input_codec: pcm.Codec,
    /// The input codec when copying; when transcoding, the requested encoder
    /// or the output container's default codec.
    output_codec: pcm.Codec,
    /// The input's format, with the layout FFmpeg's command line gives it
    /// (`audio.guessLayout`, unless `Request.guess_layout` is off: an
    /// unspecified one becomes the default for its channel count, as for a
    /// plain WAV); the output's has the same rate, the output layout and
    /// the output codec's storage (`outputFormat`).
    format: audio.Format,
    /// The output's layout: the requested one (`Request.layout`), else the
    /// input's. A different one is rematrixed (T23c).
    output_layout: audio.ChannelLayout,
    /// Sample frames in the input and the output. The duration is this many
    /// units of `format.timeBase()`, exactly, in both. Null until `run` for an
    /// input of unknown length (raw PCM output only), which `run` counts.
    frame_count: ?u64,

    /// The output's format: the input's rate, the output layout, stored as
    /// the output codec stores.
    pub fn outputFormat(s: Summary) audio.Format {
        var format = s.format;
        format.layout = s.output_layout;
        format.sample_format = s.output_codec.storage();
        return format;
    }
};

/// Bytes moved per transfer step. It holds at least one frame of every
/// encoding, so an empty read always means the end of the data (the parsers
/// read whole frames and return nothing only when none fits or none is left).
const transfer_len = 4096;

comptime {
    const largest_frame: usize = 2 * 8; // stereo s64 or f64
    std.debug.assert(transfer_len >= largest_frame);
}

/// One conversion from an opened input to a borrowed writer. Create it with
/// `init`, then call `run` once. It holds a pointer to the `detect.Input`,
/// which must stay in place, but nothing points into the conversion, so it
/// may be moved between the two calls.
pub const Conversion = struct {
    input: Parser,
    limits: Limits,
    summary: Summary,
    /// The input's tags, for the output header.
    tags: ?*const metadata.Dictionary,
    dither: dither.Options,
    /// Frames read so far: the next packet's timestamp.
    next_pts: i64 = 0,

    /// One parser per format family; the WAV parser also reads Wave64.
    const Parser = union(enum) {
        wav: wav.Parser,
        au: au.Parser,
        aiff: aiff.Parser,
        caf: caf.Parser,
        raw: raw.Parser,
    };

    /// Reads the header of the opened `source` (probed, or forced with
    /// `Request.input` when it was opened) and checks the request and the
    /// output header. Reads at most up to the first sample and writes
    /// nothing.
    pub fn init(source: *detect.Input, request: Request, limits: Limits) InitError!Conversion {
        var input: Parser = switch (source.container.family()) {
            .wav => .{ .wav = source.wavParser(limits.wav) },
            .au => .{ .au = .init(source.reader(), limits.au) },
            .aiff => .{ .aiff = .init(source.reader(), limits.aiff) },
            .caf => .{ .caf = .init(source.reader(), limits.caf) },
            .raw => .{ .raw = source.rawParser(limits.raw) },
        };
        // The tags as the file stores them, renamed once the header is read.
        var stored: metadata.Dictionary = .empty;
        defer if (request.tags) |t| stored.deinit(t.gpa);
        if (request.tags) |t| {
            std.debug.assert(t.dictionary.count() == 0);
            switch (input) {
                .wav => |*parser| parser.collectTags(.{ .gpa = t.gpa, .dictionary = &stored }),
                .au, .aiff, .caf, .raw => {},
            }
        }
        var summary: Summary = switch (input) {
            inline else => |*parser| blk: {
                const info = try parser.readHeader();
                // Unknown for WAV and AU only on request, and for raw PCM
                // without a known length.
                const frame_count: ?u64 = info.frame_count;
                break :blk .{
                    .input = source.container,
                    .output = request.output,
                    .mode = request.mode,
                    .input_codec = info.codec,
                    .output_codec = switch (request.mode) {
                        .copy => info.codec,
                        // The requested encoder, else the muxer's default; an
                        // output without a muxer fails the request check below.
                        .transcode => request.codec orelse request.output.s16Codec() orelse info.codec,
                    },
                    .format = guessed: {
                        var format = info.format;
                        if (request.guess_layout) format.layout = audio.guessLayout(format.layout);
                        break :guessed format;
                    },
                    // Set below, from the request.
                    .output_layout = undefined,
                    .frame_count = frame_count,
                };
            },
        };
        var tags: ?*const metadata.Dictionary = null;
        if (request.tags) |t| {
            // Later tags could not reach the output header; `stored` dies here.
            switch (input) {
                .wav => |*parser| parser.tags = null,
                .au, .aiff, .caf, .raw => {},
            }
            var generic = try wav.genericTags(t.gpa, &stored);
            defer generic.deinit(t.gpa);
            const carried = try carriedTags(t.gpa, &generic, request.mode);
            t.dictionary.deinit(t.gpa);
            t.dictionary.* = carried;
            tags = t.dictionary;
        }
        // FFmpeg's set_channel_layout: an unspecified request takes the
        // default for its count.
        summary.output_layout = if (request.layout) |layout| switch (layout) {
            .unspecified => |count| .default(count),
            .native, .custom => layout,
        } else summary.format.layout;
        // Any storage converts to any other (T23a); the output must carry
        // the codec, and copy takes no encoder and keeps the layout.
        const supported = switch (request.mode) {
            .copy => request.codec == null and request.output.carries(summary.input_codec) and
                summary.output_layout.eql(&summary.format.layout),
            .transcode => request.output.carries(summary.output_codec),
        };
        if (!supported) return error.UnsupportedOperation;
        // A layout libswresample cannot mix fails before any output (T23c).
        if (request.mode == .transcode) _ = try rematrix.needed(summary.format.layout, summary.output_layout);
        switch (request.output.family()) {
            .wav => try wav.Writer.check(summary.output_codec, summary.outputFormat(), try knownCount(summary), wavOptions(limits, request.output, tags)),
            .au => try au.Writer.check(summary.output_codec, summary.outputFormat(), try knownCount(summary), limits.au),
            .aiff => try aiff.Writer.check(summary.output_codec, summary.outputFormat(), try knownCount(summary), aiffOptions(limits)),
            .raw => try raw.Writer.check(summary.output_codec, summary.outputFormat(), rawOptions(limits)),
            .caf => unreachable, // no muxer: refused above as UnsupportedOperation
        }
        return .{ .input = input, .limits = limits, .summary = summary, .tags = tags, .dither = request.dither };
    }

    /// The frame count a writer's header needs up front.
    fn knownCount(summary: Summary) error{UnsupportedStreamingSize}!u64 {
        return summary.frame_count orelse error.UnsupportedStreamingSize;
    }

    /// Writes the output header, moves every frame, validates the rest of the
    /// input and finishes the output, which flushes `out`. On failure `out`
    /// may hold a partial stream.
    pub fn run(c: *Conversion, out: *std.Io.Writer) RunError!void {
        const s = c.summary;
        // `init` checked that every writer but raw PCM's has a known count.
        switch (s.output.family()) {
            .wav => {
                var writer = wav.Writer.begin(out, s.output_codec, s.outputFormat(), s.frame_count.?, wavOptions(c.limits, s.output, c.tags)) catch |err| return outputFailure(err);
                try c.transfer(wav.Writer, &writer);
            },
            .au => {
                var writer = au.Writer.begin(out, s.output_codec, s.outputFormat(), s.frame_count.?, c.limits.au) catch |err| return outputFailure(err);
                try c.transfer(au.Writer, &writer);
            },
            .aiff => {
                var writer = aiff.Writer.begin(out, s.output_codec, s.outputFormat(), s.frame_count.?, aiffOptions(c.limits)) catch |err| return outputFailure(err);
                try c.transfer(aiff.Writer, &writer);
            },
            .raw => {
                var writer = raw.Writer.begin(out, s.output_codec, s.outputFormat(), s.frame_count, rawOptions(c.limits)) catch |err| return outputFailure(err);
                try c.transfer(raw.Writer, &writer);
            },
            .caf => unreachable, // no muxer: `init` refused it
        }
        // Every frame was read: an unknown count is now known.
        if (c.summary.frame_count == null) c.summary.frame_count = @intCast(c.next_pts);
    }

    fn transfer(c: *Conversion, comptime W: type, writer: *W) RunError!void {
        var packet_bytes: [transfer_len]u8 = undefined;
        switch (c.summary.mode) {
            .copy => while (try c.readPacket(&packet_bytes)) |packet| {
                writer.writeData(packet.data) catch |err| return outputFailure(err);
            },
            .transcode => {
                const s = c.summary;
                const out_format = s.outputFormat();
                // A packet holds at most transfer_len samples (1-byte ones),
                // which their storage holds in at most twice the bytes, and
                // any format in at most 8 times.
                var decoded: [2 * transfer_len]u8 = undefined;
                var converted: [8 * transfer_len]u8 = undefined;
                var scratch: [8 * transfer_len]u8 = undefined;
                var encoded: [8 * transfer_len]u8 = undefined;
                // FFmpeg's command line tells libswresample a 24-bit encoder
                // keeps 24 bits of s32.
                var options = c.dither;
                options.output_sample_bits = if (s.output_codec.bytesPerSample() == 3) 24 else 0;
                // A layout change rematrixes as libswresample does (T23c),
                // through the internal format the mix picks, dithered after
                // the mix; `init` checked that it can.
                var remix: rematrix.Remix = undefined;
                const remixing = remix.init(s.format, out_format.layout, out_format.sample_format, .{}) catch unreachable;
                // Without a format change FFmpeg converts nothing.
                const changes = remixing or out_format.sample_format != s.format.sample_format;
                // Without a mix the frames keep the input's layout, which
                // the output's names (an unspecified one, as libswresample
                // reads it); only the writer's header records the name.
                var stage_format = out_format;
                if (!remixing) stage_format.layout = s.format.layout;
                var dithered = if (remixing)
                    dither.Dither.initInternal(remix.internal, remix.out_channels, s.format.sample_rate, out_format.sample_format, options)
                else if (changes)
                    dither.Dither.init(s.format, out_format.sample_format, options)
                else
                    null;
                if (dithered) |*d| d.setCalls(ffmpegPacketFrames(s.input, s.input_codec, s.format), s.frame_count);
                var stages: Transcoder(W) = .{
                    .decoder = .init(s.input_codec, s.format, &decoded),
                    // libswresample's conversion when the storage or the
                    // layout differs, or it dithers (T23a, T23c).
                    .converter = if (remixing)
                        .initRemixed(s.format, out_format, &converted, &remix, dithered, &scratch)
                    else if (dithered) |d|
                        .initDithered(s.format, stage_format, &converted, d, &scratch)
                    else if (changes)
                        .init(s.format, stage_format, &converted)
                    else
                        null,
                    .encoder = .init(s.output_codec, stage_format, &encoded),
                    .writer = writer,
                };
                // The mix's scratch holds both sides in up to 8 bytes a
                // sample, and the output up to 8: fewer frames per packet
                // when the channels are many.
                const in_frame_bytes = s.input_codec.bytesPerSample() * s.format.channelCount();
                const most_frames = scratch.len / (8 * (s.format.channelCount() + out_format.channelCount()));
                const packet_len = if (remixing) @min(packet_bytes.len, most_frames * in_frame_bytes) else packet_bytes.len;
                while (try c.readPacket(packet_bytes[0..packet_len])) |packet| try stages.push(packet);
                try stages.push(null);
            },
        }
        // The input first: an error after its data fails the operation
        // without flushing the output.
        try c.finishInput();
        writer.finish() catch |err| return outputFailure(err);
    }

    /// The next packet of whole frames, or `null` at the end of the data. Its
    /// bytes are in `storage`, which holds at least one frame, and stay valid
    /// until the next call.
    fn readPacket(c: *Conversion, storage: []u8) detect.Error!?Packet {
        const data = try c.readData(storage);
        if (data.len == 0) return null;
        const format = c.summary.format;
        const sample_bytes: usize = c.summary.input_codec.bytesPerSample();
        // At most `storage.len` bytes, so the frame count fits in i64.
        const frames: i64 = @intCast(data.len / (sample_bytes * format.channelCount()));
        const pts = c.next_pts;
        c.next_pts += frames;
        return .{
            .data = data,
            .time_base = format.timeBase(),
            .pts = pts,
            .dts = pts,
            .duration = frames,
            .flags = .{ .key = true },
        };
    }

    fn readData(c: *Conversion, output: []u8) detect.Error![]u8 {
        return switch (c.input) {
            inline else => |*parser| parser.readData(output),
        };
    }

    fn finishInput(c: *Conversion) detect.Error!void {
        return switch (c.input) {
            inline else => |*parser| parser.finish(),
        };
    }
};

/// The frames per packet FFmpeg's demuxer for `container` reads, the last
/// packet aside. FFmpeg's conversion calls libswresample once per packet, and
/// the dither's noise depends on those calls (resample/dither.zig).
fn ffmpegPacketFrames(container: Container, codec: pcm.Codec, format: audio.Format) u32 {
    const sample_bytes: u32 = codec.bytesPerSample();
    const block_align = sample_bytes * format.channelCount();
    return switch (container.family()) {
        // aiffdec.c's MAX_SIZE and cafdec.c's CAF_MAX_PKT_SIZE: 4096 bytes
        // of whole frames.
        .aiff, .caf => 4096 / block_align,
        // ff_pcm_default_packet_size: the frames of a tenth of a second
        // (its bit rate over 80 bytes, over the block size), at most
        // INT_MAX bytes, rounded down to a power of two.
        .wav, .au, .raw => std.math.floorPowerOfTwo(u32, std.math.clamp(format.sample_rate / 10, 1, std.math.maxInt(i32) / block_align)),
    };
}

/// The transcoding stages between the packet reader and the writer `W`.
///
/// `push` empties both stages before it returns, so each holds at most one
/// item and `send` never returns `.full`. Their sends cannot fail either:
/// packets hold whole frames of the input codec, at most `transfer_len`
/// bytes, which both storages hold even for 1-byte codecs; their timestamps are
/// already in the format's time base, so rescaling is exact; and input ends
/// only once, with `push(null)`.
fn Transcoder(comptime W: type) type {
    return struct {
        decoder: pcm.Decoder,
        /// Between them when the sample formats differ.
        converter: ?audioconvert.Converter,
        encoder: pcm.Encoder,
        writer: *W,

        const Self = @This();

        /// Sends `packet` through every stage and writes what comes out;
        /// `null` drains them.
        fn push(t: *Self, packet: ?Packet) std.Io.Writer.Error!void {
            if (packet) |p| {
                const sent = t.decoder.send(p) catch unreachable;
                std.debug.assert(sent == .accepted);
            } else {
                t.decoder.finishInput();
            }
            while (true) switch (t.decoder.receive()) {
                .output => |frame| {
                    const converted = if (t.converter) |*converter| converted: {
                        const sent = converter.send(frame) catch unreachable;
                        std.debug.assert(sent == .accepted);
                        break :converted converter.receive().output;
                    } else frame;
                    const sent = t.encoder.send(converted) catch unreachable;
                    std.debug.assert(sent == .accepted);
                    try t.writeEncoded();
                },
                .need_input => return,
                .drained => {
                    if (t.converter) |*converter| {
                        converter.finishInput();
                        std.debug.assert(converter.receive() == .drained);
                    }
                    t.encoder.finishInput();
                    try t.writeEncoded();
                    std.debug.assert(t.encoder.receive() == .drained);
                    return;
                },
            };
        }

        fn writeEncoded(t: *Self) std.Io.Writer.Error!void {
            while (true) switch (t.encoder.receive()) {
                .output => |p| t.writer.writeData(p.data) catch |err| return outputFailure(err),
                .need_input, .drained => return,
            };
        }
    };
}

/// Keys whose tags describe the source file or its encoding, as
/// `copy_meta` in fftools/ffmpeg_mux_init.c removes them.
const StaleKey = struct {
    key: []const u8,
    /// Also every key that starts with `key` (`AV_DICT_IGNORE_SUFFIX`).
    prefix: bool = false,
    /// Removed only when the audio is re-encoded, not stream-copied.
    reencoded_only: bool = true,
};

/// `reenc_delete_keys`, in its order: exact-case matches.
const stale_keys = [_]StaleKey{
    .{ .key = "iTunPGAP" },
    .{ .key = "comment-iTunPGAP-eng" },
    .{ .key = "iTunSMPB" },
    .{ .key = "comment-iTunSMPB-eng" },
    .{ .key = "gapless_playback" },
    .{ .key = "iTunNORM" },
    .{ .key = "comment-iTunNORM-eng" },
    .{ .key = "encoded_by" },
    .{ .key = "encoding_tool" },
    .{ .key = "vendor_id" },
    .{ .key = "BPS", .prefix = true },
    .{ .key = "DURATION", .prefix = true },
    .{ .key = "NUMBER_OF_BYTES", .prefix = true },
    .{ .key = "NUMBER_OF_FRAMES", .prefix = true },
    .{ .key = "_STATISTICS_TAGS", .prefix = true },
    .{ .key = "_STATISTICS_WRITING_APP", .prefix = true },
    .{ .key = "_STATISTICS_WRITING_DATE_UTC", .prefix = true },
    .{ .key = "major_brand", .reencoded_only = false },
    .{ .key = "minor_version", .reencoded_only = false },
    .{ .key = "compatible_brands", .reencoded_only = false },
};

/// The input tags FFmpeg's command carries by default (`copy_meta`): the
/// first tag of each key (`av_dict_copy` with `AV_DICT_DONT_OVERWRITE`),
/// without `creation_time`, `company_name`, `product_name` and
/// `product_version`, then without the stale keys, the re-encoding ones only
/// when transcoding. Removal follows `av_dict_set` with no value, so the
/// order changes as in FFmpeg. FFmpeg's command also adds its own `encoder`
/// tag unless `-bitexact`; this never does.
fn carriedTags(gpa: std.mem.Allocator, input: *const metadata.Dictionary, mode: Mode) std.mem.Allocator.Error!metadata.Dictionary {
    var out: metadata.Dictionary = .empty;
    errdefer out.deinit(gpa);
    for (input.items()) |entry| {
        if (out.get(entry.key) != null) continue;
        out.put(gpa, entry.key, entry.value, .keep) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTag => unreachable, // copied from a dictionary
        };
    }
    for ([_][]const u8{ "creation_time", "company_name", "product_name", "product_version" }) |key| {
        _ = out.remove(gpa, key);
    }
    for (stale_keys) |stale| {
        if (stale.reencoded_only and mode == .copy) continue;
        // Each exact-case match goes, through a case-insensitive removal.
        while (for (out.items()) |entry| {
            const matches = if (stale.prefix) std.mem.startsWith(u8, entry.key, stale.key) else std.mem.eql(u8, entry.key, stale.key);
            if (matches) break entry.key;
        } else null) |key| {
            _ = out.remove(gpa, key);
        }
    }
    return out;
}

/// The WAV writer's options for a WAV or Wave64 `output`, from the
/// conversion's limits: the same rate limit, for WAV RF64 exactly when
/// 32-bit sizes cannot hold the output, and the carried tags (which the
/// writer leaves out of Wave64).
fn wavOptions(limits: Limits, output: Container, tags: ?*const metadata.Dictionary) wav.WriteOptions {
    return .{
        .max_sample_rate = limits.wav.max_sample_rate,
        .variant = switch (output) {
            .wav => .wav,
            .w64 => .w64,
            else => unreachable, // the other writers have their own options
        },
        .tags = tags,
    };
}

/// The AIFF writer's options: the rate and channel limits of the AIFF limits.
fn aiffOptions(limits: Limits) aiff.WriteOptions {
    return .{ .max_sample_rate = limits.aiff.max_sample_rate, .max_channels = limits.aiff.max_channels };
}

/// The raw PCM writer's options: the rate limit of the raw limits.
fn rawOptions(limits: Limits) raw.WriteOptions {
    return .{ .max_sample_rate = limits.raw.max_sample_rate };
}

/// The writer's own failure. `init` already ran the header checks `begin`
/// repeats, with the same arguments; the parser delivers whole frames of the
/// same format, exactly the declared count, before `finish`. So only the
/// output's I/O failure remains.
fn outputFailure(err: wav.WriteError) std.Io.Writer.Error {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.UnsupportedFormat,
        error.InvalidFormat,
        error.LimitExceeded,
        error.SizeOverflow,
        error.IncompleteFrame,
        error.TooManyFrames,
        error.TooFewFrames,
        => unreachable,
    };
}

/// Converts one stream: `Conversion.init`, then `run`.
pub fn convert(reader: *std.Io.Reader, out: *std.Io.Writer, request: Request, limits: Limits) Error!Summary {
    var source: detect.Input = undefined;
    try source.open(reader, request.input);

    var conversion: Conversion = try .init(&source, request, limits);
    try conversion.run(out);
    return conversion.summary;
}

const fixtures = @import("../testing/fixtures.zig");

const all_cells = [_]Request{
    .{ .output = .wav, .mode = .transcode },
    .{ .output = .wav, .mode = .copy },
    .{ .output = .w64, .mode = .transcode },
    .{ .output = .w64, .mode = .copy },
    .{ .output = .au, .mode = .transcode },
    .{ .output = .au, .mode = .copy },
    .{ .output = .aiff, .mode = .transcode },
    .{ .output = .aiff, .mode = .copy },
    // Raw PCM (T22c): the s16-stored ones transcode, and every one copies its
    // own codec only. Transcoding into A-law or mu-law is lossy, so those
    // cells are compared with FFmpeg's own conversion in compare.py instead.
    .{ .output = .s16le, .mode = .transcode },
    .{ .output = .s16le, .mode = .copy },
    .{ .output = .s16be, .mode = .transcode },
    .{ .output = .alaw, .mode = .copy },
    .{ .output = .f32le, .mode = .transcode },
    .{ .output = .f32le, .mode = .copy },
    .{ .output = .s24be, .mode = .copy },
};

const Decoded = struct {
    format: audio.Format,
    frame_count: u64,
    samples: []const i16,
};

/// Decodes a converted stream with the output container's own parser, not
/// through this file. Raw PCM takes `format`'s parameters and the length.
fn decodeOutput(container: Container, bytes: []const u8, storage: []i16, format: audio.Format) !Decoded {
    var reader: std.Io.Reader = .fixed(bytes);
    switch (container.family()) {
        .wav => {
            var parser: wav.Parser = .init(&reader, .{});
            return decodeWith(wav.Parser, &parser, storage);
        },
        .au => {
            var parser: au.Parser = .init(&reader, .{});
            return decodeWith(au.Parser, &parser, storage);
        },
        .aiff => {
            var parser: aiff.Parser = .init(&reader, .{});
            return decodeWith(aiff.Parser, &parser, storage);
        },
        .raw => {
            // A raw family container has a codec.
            var parser: raw.Parser = .init(&reader, container.rawCodec().?, paramsOf(format), bytes.len, .{});
            return decodeWith(raw.Parser, &parser, storage);
        },
        .caf => {
            var parser: caf.Parser = .init(&reader, .{});
            return decodeWith(caf.Parser, &parser, storage);
        },
    }
}

fn paramsOf(format: audio.Format) raw.Params {
    return .{ .sample_rate = format.sample_rate, .layout = format.layout };
}

fn decodeWith(comptime P: type, parser: *P, storage: []i16) !Decoded {
    const info = try parser.readHeader();
    // Both writers write known lengths, which the default limits require.
    const optional_count: ?u64 = info.frame_count;
    const frame_count = optional_count orelse return error.TestUnexpectedResult;
    var len: usize = 0;
    while (true) {
        const decoded = try parser.readSamples(storage[len..]);
        if (decoded.len == 0) break;
        len += decoded.len;
    }
    // Storage that filled up would hide undelivered samples.
    if (len != frame_count * info.format.channelCount()) return error.TestUnexpectedResult;
    try parser.finish();
    return .{ .format = info.format, .frame_count = frame_count, .samples = storage[0..len] };
}

/// The bytes before the samples in an output the writers produce.
fn headerLenOf(container: Container, codec: pcm.Codec, format: audio.Format) usize {
    return switch (container) {
        .wav => wav.headerLen(codec, format, .riff), // small test outputs: plain RIFF
        .w64 => wav.headerLen(codec, format, .w64),
        .au => au.canonical_header_len,
        .aiff => aiff.headerLen(codec, format),
        else => 0, // raw PCM
    };
}

/// The pad bytes after `data_len` bytes of samples in an output.
fn padOf(container: Container, data_len: usize) usize {
    return switch (container) {
        .wav => wav.Variant.wav.padAfter(data_len),
        .w64 => wav.Variant.w64.padAfter(data_len),
        .aiff => data_len % 2,
        else => 0, // AU and raw PCM
    };
}

/// The container detection names for an input the WAV parser reads.
fn wavContainer(bytes: []const u8) Container {
    return if (std.mem.startsWith(u8, bytes, "riff")) .w64 else .wav;
}

/// A stream's decoded samples, little-endian in their storage format, read by
/// the container's own parser; raw PCM with `format`'s parameters.
fn rawOf(container: Container, bytes: []const u8, out: []u8, format: audio.Format) ![]const u8 {
    var reader: std.Io.Reader = .fixed(bytes);
    var writer: std.Io.Writer = .fixed(out);
    switch (container.family()) {
        .wav => _ = try wav.decodeToRaw(&reader, &writer, .{}),
        .au => _ = try au.decodeToRaw(&reader, &writer, .{}),
        .aiff => _ = try aiff.decodeToRaw(&reader, &writer, .{}),
        .caf => _ = try caf.decodeToRaw(&reader, &writer, .{}),
        .raw => _ = try raw.decodeToRaw(&reader, &writer, container.rawCodec().?, paramsOf(format), bytes.len, .{}), // a raw container has a codec
    }
    return writer.buffered();
}

/// Little-endian samples of `from`'s storage, converted to `to`'s storage
/// and serialized little-endian into `out`.
fn convertedStored(little: []const u8, from: audio.Format, to: audio.Format, frames: usize, out: []u8) []const u8 {
    if (from.sample_format == to.sample_format) return little;
    const out_len = frames * to.bytesPerFrame();
    if (frames == 0) return out[0..0];
    var native: [1024]u8 = undefined;
    @memcpy(native[0..little.len], little);
    pcm.storedToLittle(from.sample_format, native[0..little.len]); // a swap either way
    const count: u32 = @intCast(frames);
    const in_layout = samples_storage.Layout.init(from.sample_format, from.channelCount(), count, .{ .line = 1 }) catch unreachable;
    const out_layout = samples_storage.Layout.init(to.sample_format, to.channelCount(), count, .{ .line = 1 }) catch unreachable;
    const input = samples_storage.View.init(in_layout, native[0..little.len]) catch unreachable;
    const output = samples_storage.Buffer.init(out_layout, out[0..out_len]) catch unreachable;
    audioconvert.convert(output, input, 0, 0, count);
    pcm.storedToLittle(to.sample_format, output.bytes);
    return output.bytes;
}

/// Runs every matrix cell on one accepted fixture. Copy works only into a
/// container that carries the input's codec; transcoding converts any
/// storage to the output's default codec (T23a). An input probing does not detect (`detected` false) is forced, as
/// `-f` would, with `source`'s raw parameters and length.
fn expectEveryCell(input: Container, detected: bool, source: detect.Source, bytes: []const u8, comptime stream: fixtures.Stream, writer_output: bool) !void {
    var expected_buffer: [1024]u8 = undefined;
    const expected = stream.samples.littleEndian(&expected_buffer);
    const input_codec = comptime std.meta.stringToEnum(pcm.Codec, @tagName(stream.codec)["pcm_".len..]).?;
    for (all_cells) |cell| {
        var request = cell;
        request.input = source;
        if (!detected) request.input.format = input;
        var reader: std.Io.Reader = .fixed(bytes);
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        const result = convert(&reader, &out, request, .{});
        const supported = switch (request.mode) {
            .copy => request.output.carries(input_codec),
            // Any storage converts to the output's default codec (T23a).
            .transcode => true,
        };
        if (!supported) {
            try std.testing.expectError(error.UnsupportedOperation, result);
            try std.testing.expectEqual(0, out.buffered().len);
            continue;
        }
        const summary = try result;
        const frame_count = stream.frameCount();
        try std.testing.expectEqual(input, summary.input);
        try std.testing.expectEqual(request.output, summary.output);
        try std.testing.expectEqualStrings(@tagName(stream.codec), summary.input_codec.name());
        try std.testing.expectEqual(stream.sample_rate, summary.format.sample_rate);
        try std.testing.expectEqual(stream.channels, summary.format.channelCount());
        try std.testing.expectEqual(frame_count, summary.frame_count);

        // The output holds the writer's header and exactly the samples, at
        // the same rate and frame count, so the duration is unchanged.
        const written = out.buffered();
        const data_len = frame_count * stream.channels * summary.output_codec.bytesPerSample();
        const header_len = headerLenOf(request.output, summary.output_codec, summary.outputFormat());
        try std.testing.expectEqual(header_len + data_len + padOf(request.output, data_len), written.len);
        var raw_buffer: [1024]u8 = undefined;
        // The input's samples, converted to the output's storage by the
        // kernels the libswresample vectors check.
        var converted_buffer: [2048]u8 = undefined;
        const want = convertedStored(expected, summary.format, summary.outputFormat(), frame_count, &converted_buffer);
        try std.testing.expectEqualSlices(u8, want, try rawOf(request.output, written, &raw_buffer, summary.outputFormat()));

        // A canonical input converts to itself, byte for byte, unless FFmpeg's
        // layout guess changed its layout (six unspecified channels become
        // 5.1, which WAV writes as an extensible mask).
        const same_layout = stream.channelLayout().eql(&summary.format.layout) and std.meta.activeTag(stream.channelLayout()) == std.meta.activeTag(summary.format.layout);
        if (writer_output and same_layout and request.output == input and summary.output_codec == summary.input_codec) {
            try std.testing.expectEqualSlices(u8, bytes, written);
        }
    }
}

test "every accepted fixture gives its samples in every supported cell, and copy across codecs is rejected" {
    inline for (fixtures.all) |fixture| {
        if (fixture.expected == .accept) {
            // The converter writes RF64 only when needed, so an RF64 writer
            // output converts to plain RIFF; Wave64 converts to itself.
            const bytes = fixtures.bytes(fixture.name);
            // Without a tag dictionary in the request, tags are not carried.
            const canonical = fixture.writer_output and fixture.writer_header != .rf64 and fixture.untagged();
            try expectEveryCell(wavContainer(bytes), fixture.detected != null, .{}, bytes, fixture.expected.accept, canonical);
        }
    }
    inline for (fixtures.au.all) |fixture| {
        if (fixture.expected == .accept) {
            try expectEveryCell(.au, fixture.detected != null, .{}, fixtures.au.bytes(fixture.name), fixture.expected.accept, fixture.writer_output);
        }
    }
    inline for (fixtures.aiff.all) |fixture| {
        if (fixture.expected == .accept) {
            expectEveryCell(.aiff, fixture.detected != null, .{}, fixtures.aiff.bytes(fixture.name), fixture.expected.accept, fixture.writer_output) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
    inline for (fixtures.caf.all) |fixture| {
        if (fixture.expected == .accept) {
            expectEveryCell(.caf, fixture.detected != null, .{}, fixtures.caf.bytes(fixture.name), fixture.expected.accept, false) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
    // Raw PCM is forced, with its parameters and its length, as zffmpeg reads a file.

    inline for (fixtures.raw.all) |fixture| {
        if (fixture.expected == .accept) {
            const stream = fixture.expected.accept;
            const bytes = fixtures.raw.bytes(fixture.name);
            const source: detect.Source = .{ .raw = .{ .sample_rate = stream.sample_rate, .layout = stream.channelLayout() }, .length = bytes.len };
            const container = @field(Container, @tagName(fixture.format));
            expectEveryCell(container, false, source, bytes, stream, fixture.writer_output) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
}

test "stream copy between families keeps the codecs both carry, as FFmpeg's muxers tag them" {
    // s16le WAV copies into AIFF-C `sowt` and back; s32be, f64be and µ-law
    // move between AU and AIFF.
    const cases = [_]struct { input: []const u8, output: Container, expected: []const u8 }{
        .{ .input = fixtures.bytes("mono_8k"), .output = .aiff, .expected = fixtures.aiff.bytes("aifc_sowt") },
        .{ .input = fixtures.aiff.bytes("aifc_sowt"), .output = .wav, .expected = fixtures.bytes("mono_8k") },
        .{ .input = fixtures.au.bytes("au_s32_mono"), .output = .aiff, .expected = fixtures.aiff.bytes("aiff_s32_mono") },
        .{ .input = fixtures.aiff.bytes("aifc_fl64_stereo_96k"), .output = .au, .expected = fixtures.au.bytes("au_f64_stereo_96k") },
        .{ .input = fixtures.aiff.bytes("aifc_ulaw"), .output = .au, .expected = fixtures.au.bytes("au_mulaw_mono_8k") },
    };
    for (cases) |case| {
        var reader: std.Io.Reader = .fixed(case.input);
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        _ = try convert(&reader, &out, .{ .output = case.output, .mode = .copy }, .{});
        try std.testing.expectEqualSlices(u8, case.expected, out.buffered());
    }
    // Plain AIFF's s16be has no WAV codec.
    var reader: std.Io.Reader = .fixed(fixtures.aiff.bytes("aiff_mono_8k"));
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.UnsupportedOperation, convert(&reader, &out, .{ .output = .wav, .mode = .copy }, .{}));
}

test "the input is read as contiguous, timestamped packets of whole frames" {
    const gpa = std.testing.allocator;
    const stereo = try audio.Format.init(48000, 2, .s16);
    const frame_count = 5000; // Not a multiple of the 1024-frame packets.
    const bytes = try gpa.alloc(u8, wav.canonical_header_len + frame_count * 4);
    defer gpa.free(bytes);
    var out: std.Io.Writer = .fixed(bytes);
    var writer = try wav.Writer.begin(&out, .s16le, stereo, frame_count, .{});
    const zeros: [frame_count * 2]i16 = @splat(0);
    try writer.writeFrames(&zeros);
    try writer.finish();

    var reader: std.Io.Reader = .fixed(bytes);
    var source: detect.Input = undefined;
    try source.open(&reader, .{});
    var conversion: Conversion = try .init(&source, .{ .output = .au, .mode = .transcode }, .{});
    var storage: [transfer_len]u8 = undefined;
    var expected_pts: i64 = 0;
    while (try conversion.readPacket(&storage)) |packet| {
        try std.testing.expectEqual(expected_pts, packet.pts);
        try std.testing.expectEqual(expected_pts, packet.dts);
        try std.testing.expectEqual(stereo.timeBase(), packet.time_base);
        try std.testing.expect(packet.flags.key);
        const frames: i64 = @intCast(@divExact(packet.data.len, 4));
        try std.testing.expectEqual(frames, packet.duration.?);
        expected_pts += packet.duration.?;
    }
    try std.testing.expectEqual(frame_count, expected_pts);
}

test "copy keeps the encoded data and timing but not the container's metadata" {
    // unknown_chunks and w64_unknown_chunks carry chunks besides `fmt ` and
    // `data`; au_annotation_text has a 16-byte annotation.
    const cases = [_]struct { container: Container, bytes: []const u8 }{
        .{ .container = .wav, .bytes = fixtures.bytes("unknown_chunks") },
        .{ .container = .w64, .bytes = fixtures.bytes("w64_unknown_chunks") },
        .{ .container = .au, .bytes = fixtures.au.bytes("au_annotation_text") },
        .{ .container = .aiff, .bytes = fixtures.aiff.bytes("aiff_other_chunks") },
    };
    for (cases) |case| {
        var copy_reader: std.Io.Reader = .fixed(case.bytes);
        var copy_buffer: [1024]u8 = undefined;
        var copy_out: std.Io.Writer = .fixed(&copy_buffer);
        const copied = try convert(&copy_reader, &copy_out, .{ .output = case.container, .mode = .copy }, .{});

        var storage: [256]i16 = undefined;
        const input = try decodeOutput(case.container, case.bytes, &storage, undefined);

        // Same samples, rate and frame count ...
        var copy_storage: [256]i16 = undefined;
        const output = try decodeOutput(case.container, copy_out.buffered(), &copy_storage, undefined);
        try std.testing.expectEqual(input.format, output.format);
        try std.testing.expectEqual(input.frame_count, output.frame_count);
        try std.testing.expectEqual(input.frame_count, copied.frame_count);
        try std.testing.expectEqualSlices(i16, input.samples, output.samples);
        // ... under the canonical header: the input's other bytes are gone.
        const data_len = 2 * input.samples.len;
        const header_len = headerLenOf(case.container, copied.output_codec, copied.format);
        try std.testing.expectEqual(header_len + data_len + padOf(case.container, data_len), copy_out.buffered().len);
        try std.testing.expect(case.bytes.len > copy_out.buffered().len);
    }
}

/// Converting a rejected stream into its own container, in both modes, fails
/// with the error probing reports. The fixture contracts already pin that
/// error, and for an input without the AU magic it is the WAV parser's.
fn expectProbeError(bytes: []const u8, output: Container) !void {
    var probe_reader: std.Io.Reader = .fixed(bytes);
    const want = if (detect.probe(&probe_reader, .{})) |_| return error.TestExpectedError else |e| e;
    for ([_]Mode{ .transcode, .copy }) |mode| {
        var reader: std.Io.Reader = .fixed(bytes);
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectError(want, convert(&reader, &out, .{ .output = output, .mode = mode }, .{}));
    }
}

test "every rejected fixture fails with the error probing reports" {
    inline for (fixtures.all) |fixture| {
        if (fixture.expected == .reject) {
            expectProbeError(fixtures.bytes(fixture.name), .wav) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
    inline for (fixtures.au.all) |fixture| {
        if (fixture.expected == .reject) {
            expectProbeError(fixtures.au.bytes(fixture.name), .au) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
    inline for (fixtures.aiff.all) |fixture| {
        if (fixture.expected == .reject) {
            expectProbeError(fixtures.aiff.bytes(fixture.name), .aiff) catch |err| {
                std.debug.print("fixture {s}\n", .{fixture.name});
                return err;
            };
        }
    }
}

/// Converts `input` with tags carried and returns the output's tags as the
/// WAV parser reads them back, renamed.
fn convertWithTags(gpa: std.mem.Allocator, input: []const u8, request: Request, output: []u8) !struct { metadata.Dictionary, []const u8 } {
    var tags: metadata.Dictionary = .empty;
    defer tags.deinit(gpa);
    var with_tags = request;
    with_tags.tags = .{ .gpa = gpa, .dictionary = &tags };
    var reader: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer = .fixed(output);
    _ = try convert(&reader, &out, with_tags, .{});
    const written = out.buffered();
    var read_back: metadata.Dictionary = .empty;
    errdefer read_back.deinit(gpa);
    if (request.output == .wav or request.output == .w64) {
        var stored: metadata.Dictionary = .empty;
        defer stored.deinit(gpa);
        var parser_reader: std.Io.Reader = .fixed(written);
        var parser: wav.Parser = .init(&parser_reader, .{});
        parser.collectTags(.{ .gpa = gpa, .dictionary = &stored });
        _ = try parser.readHeader();
        read_back.deinit(gpa);
        read_back = try wav.genericTags(gpa, &stored);
    }
    return .{ read_back, written };
}

test "tags are carried into WAV output as FFmpeg's writer would, and only there" {
    const gpa = std.testing.allocator;
    var buffer: [2048]u8 = undefined;
    // info_tags is the writer's own output, so it converts to itself in both modes.
    for ([_]Mode{ .copy, .transcode }) |mode| {
        var tags, const written = try convertWithTags(gpa, fixtures.bytes("info_tags"), .{ .output = .wav, .mode = mode }, &buffer);
        defer tags.deinit(gpa);
        try std.testing.expectEqualSlices(u8, fixtures.bytes("info_tags"), written);
        try std.testing.expectEqual(5, tags.count());
    }
    // From bext, only what has an INFO code survives: comment, date and the
    // first encoded_by, as FFmpeg's writer chooses them.
    {
        var tags, _ = try convertWithTags(gpa, fixtures.bytes("bext_tags"), .{ .output = .wav, .mode = .copy }, &buffer);
        defer tags.deinit(gpa);
        try std.testing.expectEqual(3, tags.count());
        try std.testing.expectEqualStrings("comment", tags.items()[0].key);
        try std.testing.expectEqualStrings("date", tags.items()[1].key);
        try std.testing.expectEqualStrings("Recorder", tags.get("encoded_by") orelse return error.TestExpectedValue);
    }
    // Tags after the input's data, and Wave64, AU and AIFF outputs, carry none.
    const none = [_]struct { name: []const u8, output: Container }{
        .{ .name = "info_after_data", .output = .wav },
        .{ .name = "info_tags", .output = .w64 },
        .{ .name = "info_tags", .output = .au },
        .{ .name = "info_tags", .output = .aiff },
    };
    inline for (none) |case| {
        var tags, _ = try convertWithTags(gpa, fixtures.bytes(case.name), .{ .output = case.output, .mode = .transcode }, &buffer);
        defer tags.deinit(gpa);
        try std.testing.expectEqual(0, tags.count());
    }
}

test "the carried tags follow FFmpeg's command: first key wins, stale keys go" {
    const gpa = std.testing.allocator;
    var input: metadata.Dictionary = .empty;
    defer input.deinit(gpa);
    const pairs = [_][2][]const u8{
        .{ "creation_time", "x" }, .{ "title", "T" },     .{ "TITLE", "second" },
        .{ "encoded_by", "E" },    .{ "BPS-eng", "128" }, .{ "Encoding_Tool", "kept: not exact case" },
        .{ "major_brand", "M" },   .{ "album", "A" },
    };
    for (pairs) |pair| try input.put(gpa, pair[0], pair[1], .keep);

    // Copy keeps the encoding provenance; the source-file keys always go.
    // Removing creation_time moves the last tag (album) into its place, as
    // av_dict_set does; major_brand likewise.
    var copied = try carriedTags(gpa, &input, .copy);
    defer copied.deinit(gpa);
    const copy_keys = [_][]const u8{ "album", "title", "encoded_by", "BPS-eng", "Encoding_Tool" };
    try std.testing.expectEqual(copy_keys.len, copied.count());
    for (copy_keys, copied.items()) |key, entry| try std.testing.expectEqualStrings(key, entry.key);
    try std.testing.expectEqualStrings("T", copied.get("title") orelse return error.TestExpectedValue);

    // Re-encoding also drops encoded_by and the BPS family.
    var transcoded = try carriedTags(gpa, &input, .transcode);
    defer transcoded.deinit(gpa);
    try std.testing.expectEqual(null, transcoded.get("encoded_by"));
    try std.testing.expectEqual(null, transcoded.get("BPS-eng"));
    try std.testing.expectEqual(3, transcoded.count());
}

test "unknown-length input is refused before any output by the writers that need the length" {
    // Accepted by the parser with the option on, but there is nothing to write
    // in the output header's size fields. The request is checked first, so a
    // copy the output cannot carry is UnsupportedOperation.
    var limits: Limits = .{};
    limits.wav.unknown_length = true;
    for ([_]Mode{ .transcode, .copy }) |mode| {
        for ([_]Container{ .wav, .au, .aiff }) |output| {
            var reader: std.Io.Reader = .fixed(fixtures.bytes("unknown_length_pipe"));
            var buffer: [1024]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            const want = if (mode == .copy and !output.carries(.s16le)) error.UnsupportedOperation else error.UnsupportedStreamingSize;
            try std.testing.expectError(want, convert(&reader, &out, .{ .output = output, .mode = mode }, limits));
            try std.testing.expectEqual(0, out.buffered().len);
        }
    }
    // Raw PCM needs no length: the frames are counted as they pass.
    {
        var reader: std.Io.Reader = .fixed(fixtures.bytes("unknown_length_pipe"));
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        const summary = try convert(&reader, &out, .{ .output = .s16le, .mode = .copy }, limits);
        try std.testing.expectEqual(out.buffered().len / 2, summary.frame_count);
    }
    // Raw input without a length (a pipe) converts only to raw output.
    {
        const bytes = [_]u8{ 1, 0, 2, 0, 3, 0 };
        var reader: std.Io.Reader = .fixed(&bytes);
        var buffer: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectError(error.UnsupportedStreamingSize, convert(&reader, &out, .{ .output = .wav, .mode = .transcode, .input = .{ .format = .s16le } }, .{}));
        var with_length: std.Io.Reader = .fixed(&bytes);
        const summary = try convert(&with_length, &out, .{ .output = .wav, .mode = .copy, .input = .{ .format = .s16le, .length = bytes.len } }, .{});
        try std.testing.expectEqual(3, summary.frame_count);
        try std.testing.expectEqual(44100, summary.format.sample_rate);
    }
    // A known data size in an unknown RIFF extent converts.
    var reader: std.Io.Reader = .fixed(fixtures.bytes("unknown_riff_chunk_after_data"));
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    const summary = try convert(&reader, &out, .{ .output = .wav, .mode = .copy }, limits);
    try std.testing.expectEqual(2, summary.frame_count);
}

test "an unspecified layout is guessed unless the request keeps it" {
    const bytes = fixtures.raw.bytes("raw_s16le_6c");
    const six: raw.Params = .{ .sample_rate = 8000, .layout = .{ .unspecified = 6 } };
    var buffer: [256]u8 = undefined;
    for ([_]bool{ true, false }) |guess| {
        var reader: std.Io.Reader = .fixed(bytes);
        var out: std.Io.Writer = .fixed(&buffer);
        const summary = try convert(&reader, &out, .{
            .output = .wav,
            .mode = .transcode,
            .input = .{ .format = .s16le, .raw = six, .length = bytes.len },
            .guess_layout = guess,
        }, .{});
        // 5.1 as FFmpeg guesses it for `-ac 6`, written in an extensible
        // header; kept unspecified for `-ch_layout 6C`, in a plain one.
        const expected: audio.ChannelLayout = if (guess) .default(6) else .{ .unspecified = 6 };
        try std.testing.expect(expected.eql(&summary.format.layout));
        const header_len: usize = if (guess) 68 else 44;
        try std.testing.expectEqual(header_len, wav.headerLen(.s16le, summary.format, .riff));
        try std.testing.expectEqual(header_len + bytes.len, out.buffered().len);
    }
}

test "a requested output layout rematrixes, and only when transcoding" {
    const five_one = fixtures.bytes("extensible_5point1");
    var buffer: [512]u8 = undefined;
    var reader: std.Io.Reader = .fixed(five_one);
    var out: std.Io.Writer = .fixed(&buffer);
    const summary = try convert(&reader, &out, .{ .output = .wav, .mode = .transcode, .layout = .stereo }, .{});
    try std.testing.expect(summary.output_layout.eql(&audio.ChannelLayout.stereo));
    try std.testing.expectEqual(2, summary.outputFormat().channelCount());
    // Two frames of stereo s16 after the 44-byte plain header.
    try std.testing.expectEqual(44 + 2 * 2 * 2, out.buffered().len);

    // Copy cannot change the layout; transcoding into one libswresample
    // cannot mix (a lone side channel) fails before any output.
    var copy_reader: std.Io.Reader = .fixed(five_one);
    var copy_out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.UnsupportedOperation, convert(&copy_reader, &copy_out, .{ .output = .wav, .mode = .copy, .layout = .stereo }, .{}));
    try std.testing.expectEqual(0, copy_out.buffered().len);
    const lopsided = try audio.ChannelLayout.parse("FL+FR+SL");
    var bad_reader: std.Io.Reader = .fixed(five_one);
    var bad_out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.UnsupportedLayout, convert(&bad_reader, &bad_out, .{ .output = .wav, .mode = .transcode, .layout = lopsided }, .{}));
    try std.testing.expectEqual(0, bad_out.buffered().len);

    // Six unspecified channels into 5.1, their default: nothing is mixed,
    // and the header names 5.1.
    const six = fixtures.raw.bytes("raw_s16le_6c");
    var raw_reader: std.Io.Reader = .fixed(six);
    var raw_out: std.Io.Writer = .fixed(&buffer);
    const unmixed = try convert(&raw_reader, &raw_out, .{
        .output = .wav,
        .mode = .transcode,
        .input = .{ .format = .s16le, .raw = .{ .sample_rate = 8000, .layout = .{ .unspecified = 6 } }, .length = six.len },
        .guess_layout = false,
        .layout = .default(6),
    }, .{});
    try std.testing.expect(unmixed.output_layout.eql(&audio.ChannelLayout.default(6)));
    try std.testing.expectEqualSlices(u8, six, raw_out.buffered()[raw_out.buffered().len - six.len ..]);
}

test "an error found after samples were written fails the conversion" {
    // duplicate_data's error follows its data; au_truncated_data ends inside it.
    var late: std.Io.Reader = .fixed(fixtures.bytes("duplicate_data"));
    var buffer: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.InvalidWave, convert(&late, &out, .{ .output = .au, .mode = .transcode }, .{}));
    // The header and both samples were already written.
    try std.testing.expectEqual(au.canonical_header_len + 4, out.buffered().len);

    // The output had started. A transfer read the input cannot fill delivers
    // nothing, so how many samples precede the failure depends on where the
    // 4 KiB transfer boundaries fall; the failure itself does not.
    var truncated: std.Io.Reader = .fixed(fixtures.au.bytes("au_truncated_data"));
    var copy_out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.Truncated, convert(&truncated, &copy_out, .{ .output = .au, .mode = .copy }, .{}));
    try std.testing.expectEqual(au.canonical_header_len, copy_out.buffered().len);
}

test "an output the writer cannot represent is rejected before any output" {
    // A mono WAV header declaring 2 GiB of data, without the data: the AU
    // writer's data-size bound rejects it once the header is read.
    var header = fixtures.bytes("mono_8k")[0..wav.canonical_header_len].*;
    const data_bytes: u32 = 1 << 31;
    std.mem.writeInt(u32, header[4..8], data_bytes + wav.canonical_header_len - 8, .little);
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var huge: std.Io.Reader = .fixed(&header);
    try std.testing.expectError(error.SizeOverflow, convert(&huge, &out, .{ .output = .au, .mode = .transcode }, .{}));
    // The same stream fits in WAV: init succeeds, and only the missing data fails.
    var huge_again: std.Io.Reader = .fixed(&header);
    var source: detect.Input = undefined;
    try source.open(&huge_again, .{});
    _ = try Conversion.init(&source, .{ .output = .wav, .mode = .copy }, .{});

    // The output's own rate limit is checked too.
    var mono: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.LimitExceeded, convert(&mono, &out, .{ .output = .au, .mode = .transcode }, .{
        .au = .{ .max_sample_rate = 7999 },
    }));
    try std.testing.expectEqual(0, out.buffered().len);
}

test "input and output failures are reported" {
    var failing: std.Io.Reader = .failing;
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.IoFailure, convert(&failing, &out, .{ .output = .wav, .mode = .transcode }, .{}));

    // The header does not fit in 10 bytes.
    var small: [10]u8 = undefined;
    var short: std.Io.Writer = .fixed(&small);
    var mono: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.WriteFailed, convert(&mono, &short, .{ .output = .wav, .mode = .copy }, .{}));

    // Everything fits in the buffer, so the failure surfaces at the final flush.
    var big: [256]u8 = undefined;
    var failing_flush: std.Io.Writer = .{ .vtable = &.{ .drain = std.Io.Writer.failingDrain }, .buffer = &big };
    var stereo: std.Io.Reader = .fixed(fixtures.bytes("stereo_44k1"));
    try std.testing.expectError(error.WriteFailed, convert(&stereo, &failing_flush, .{ .output = .au, .mode = .transcode }, .{}));
}

test "file adapters with empty, tiny and larger buffers give the memory result" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;
    const inputs = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "in.wav", .bytes = fixtures.bytes("stereo_44k1") },
        .{ .name = "in.au", .bytes = fixtures.au.bytes("au_annotation_text") },
        .{ .name = "in.aiff", .bytes = fixtures.aiff.bytes("aiff_other_chunks") },
    };
    for (inputs) |input| {
        try tmp.dir.writeFile(io, .{ .sub_path = input.name, .data = input.bytes });
        for ([_]Request{ .{ .output = .wav, .mode = .transcode }, .{ .output = .au, .mode = .transcode }, .{ .output = .aiff, .mode = .transcode } }) |request| {
            var memory: std.Io.Reader = .fixed(input.bytes);
            var expected_buffer: [1024]u8 = undefined;
            var expected: std.Io.Writer = .fixed(&expected_buffer);
            _ = try convert(&memory, &expected, request, .{});

            for ([_]usize{ 0, 1, 64 }) |capacity| {
                {
                    const in_file = try tmp.dir.openFile(io, input.name, .{});
                    defer in_file.close(io);
                    const out_file = try tmp.dir.createFile(io, "out", .{});
                    defer out_file.close(io);
                    var reader = in_file.readerStreaming(io, read_buffer[0..capacity]);
                    var writer = out_file.writerStreaming(io, write_buffer[0..capacity]);
                    _ = try convert(&reader.interface, &writer.interface, request, .{});
                }
                var content: [1024]u8 = undefined;
                const written = try tmp.dir.readFile(io, "out", &content);
                try std.testing.expectEqualSlices(u8, expected.buffered(), written);
            }
        }
    }
}

fn patternSample(index: u64) i16 {
    const bits: u16 = @truncate(index *% 7919);
    return @bitCast(bits);
}

test "a long stream converts with fixed memory and exact frame counts" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stereo = try audio.Format.init(48000, 2, .s16);
    const frame_count = 1 << 20; // 4 MiB of samples
    var buffer: [64 * 1024]u8 = undefined;

    {
        const file = try tmp.dir.createFile(io, "long.wav", .{});
        defer file.close(io);
        var file_writer = file.writerStreaming(io, &buffer);
        var writer = try wav.Writer.begin(&file_writer.interface, .s16le, stereo, frame_count, .{});
        var chunk: [4096]i16 = undefined;
        var next: u64 = 0;
        while (next < frame_count * 2) : (next += chunk.len) {
            for (&chunk, 0..) |*sample, i| sample.* = patternSample(next + i);
            try writer.writeFrames(&chunk);
        }
        try writer.finish();
    }

    var out_buffer: [64 * 1024]u8 = undefined;
    for ([_]struct { request: Request, path: []const u8 }{
        .{ .request = .{ .output = .au, .mode = .transcode }, .path = "long.au" },
        .{ .request = .{ .output = .wav, .mode = .copy }, .path = "copy.wav" },
    }) |case| {
        const in_file = try tmp.dir.openFile(io, "long.wav", .{});
        defer in_file.close(io);
        const out_file = try tmp.dir.createFile(io, case.path, .{});
        defer out_file.close(io);
        var reader = in_file.readerStreaming(io, &buffer);
        var writer = out_file.writerStreaming(io, &out_buffer);
        const summary = try convert(&reader.interface, &writer.interface, case.request, .{});
        try std.testing.expectEqual(frame_count, summary.frame_count);
    }

    // The AU output has every sample, in order, and the same frame count and rate.
    {
        const file = try tmp.dir.openFile(io, "long.au", .{});
        defer file.close(io);
        var reader = file.readerStreaming(io, &buffer);
        var parser: au.Parser = .init(&reader.interface, .{});
        const info = try parser.readHeader();
        try std.testing.expectEqual(frame_count, info.frame_count);
        // AU has no layout field: FFmpeg's reading leaves it unspecified.
        var unspecified = stereo;
        unspecified.layout = .{ .unspecified = 2 };
        try std.testing.expectEqual(unspecified, info.format);
        var samples: [1000]i16 = undefined;
        var seen: u64 = 0;
        while (true) {
            const decoded = try parser.readSamples(&samples);
            if (decoded.len == 0) break;
            for (decoded, 0..) |sample, i| {
                if (sample != patternSample(seen + i)) return error.TestUnexpectedResult;
            }
            seen += decoded.len;
        }
        try parser.finish();
        try std.testing.expectEqual(frame_count * 2, seen);
    }

    // The input already has the canonical header, so its copy is identical.
    const input_stat = try tmp.dir.statFile(io, "long.wav", .{});
    const copy_stat = try tmp.dir.statFile(io, "copy.wav", .{});
    try std.testing.expectEqual(input_stat.size, copy_stat.size);
    const original = try tmp.dir.openFile(io, "long.wav", .{});
    defer original.close(io);
    const copy = try tmp.dir.openFile(io, "copy.wav", .{});
    defer copy.close(io);
    var original_reader = original.readerStreaming(io, &buffer);
    var copy_reader = copy.readerStreaming(io, &out_buffer);
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    var left = input_stat.size;
    while (left > 0) {
        const n: usize = @intCast(@min(left, a.len));
        try original_reader.interface.readSliceAll(a[0..n]);
        try copy_reader.interface.readSliceAll(b[0..n]);
        try std.testing.expectEqualSlices(u8, a[0..n], b[0..n]);
        left -= n;
    }
}

test "a dithered transcode follows FFmpeg's packets, and only a format change dithers" {
    const gpa = std.testing.allocator;
    // Raw f32 stereo at 44100 Hz: FFmpeg's raw demuxer reads 4096 frames a
    // packet, this file 512, and 140000 frames make the noise restart.
    const frames = 140000;
    const stereo = try audio.Format.init(44100, 2, .flt);
    const input = try gpa.alloc(u8, frames * 8);
    defer gpa.free(input);
    var x: u32 = 1;
    for (0..frames * 2) |i| {
        x = x *% 1664525 +% 1013904223;
        const signed: i32 = @bitCast(x);
        const value: f32 = @floatFromInt(signed);
        std.mem.writeInt(u32, input[4 * i ..][0..4], @bitCast(value * (1.0 / 2147483648.0)), .little);
    }
    const output = try gpa.alloc(u8, frames * 4);
    defer gpa.free(output);
    const source: detect.Source = .{ .format = .f32le, .raw = .{ .layout = .stereo } };
    for ([_]?u64{ null, frames * 8 }) |length| {
        var reader: std.Io.Reader = .fixed(input);
        var out: std.Io.Writer = .fixed(output);
        var known = source;
        known.length = length;
        const options: dither.Options = .{ .method = .triangular, .scale = 0.75 };
        _ = try convert(&reader, &out, .{ .output = .s16le, .mode = .transcode, .dither = options, .input = known }, .{});
        try std.testing.expectEqual(output.len, out.end);

        // The same conversion in FFmpeg's calls.
        var d = dither.Dither.init(stereo, .s16, options).?; // flt to s16 dithers
        const expected = try gpa.alloc(u8, frames * 4);
        defer gpa.free(expected);
        const scratch = try gpa.alloc(u8, d.scratchLen(4096));
        defer gpa.free(scratch);
        const native = try gpa.alloc(u8, 4096 * 8);
        defer gpa.free(native);
        var done: u32 = 0;
        while (done < frames) {
            const n: u32 = @min(4096, frames - done);
            for (0..2 * n) |i| {
                const bits = std.mem.readInt(u32, input[(2 * done + i) * 4 ..][0..4], .little);
                std.mem.writeInt(u32, native[4 * i ..][0..4], bits, @import("builtin").cpu.arch.endian());
            }
            const in_layout = try samples_storage.Layout.init(.flt, 2, n, .{ .line = 1 });
            const in_buffer = try samples_storage.Buffer.init(in_layout, native);
            const out_layout = try samples_storage.Layout.init(.s16, 2, n, .{ .line = 1 });
            const out_buffer = try samples_storage.Buffer.init(out_layout, expected[4 * done ..]);
            d.convert(out_buffer, in_buffer.view(), n, scratch[0..d.scratchLen(n)]);
            done += n;
        }
        pcm.storedToLittle(.s16, expected);
        try std.testing.expectEqualSlices(u8, expected, output);
    }

    // s32 to a 24-bit encoder: FFmpeg's filter graph converts nothing, so
    // there is nothing to dither.
    var plain_out: [64]u8 = undefined;
    var dithered_out: [64]u8 = undefined;
    const s32_input = input[0 .. 8 * 8];
    const s32_source: detect.Source = .{ .format = .s32le, .raw = .{ .layout = .stereo } };
    var plain_reader: std.Io.Reader = .fixed(s32_input);
    var plain: std.Io.Writer = .fixed(&plain_out);
    _ = try convert(&plain_reader, &plain, .{ .output = .s24le, .mode = .transcode, .input = s32_source }, .{});
    var dithered_reader: std.Io.Reader = .fixed(s32_input);
    var dithered: std.Io.Writer = .fixed(&dithered_out);
    _ = try convert(&dithered_reader, &dithered, .{ .output = .s24le, .mode = .transcode, .input = s32_source, .dither = .{ .method = .rectangular } }, .{});
    try std.testing.expectEqualSlices(u8, plain.buffered(), dithered.buffered());
}

fn fuzzOne(context: void, smith: *std.testing.Smith) anyerror!void {
    _ = context;
    var input: [1024]u8 = undefined;
    const len = smith.slice(&input);
    const bytes = input[0..len];
    var probe_reader: std.Io.Reader = .fixed(bytes);
    const probed = detect.probe(&probe_reader, .{});
    for (all_cells) |request| {
        var reader: std.Io.Reader = .fixed(bytes);
        // 1 KiB of input holds at most 1 KiB of data; transcoding 1-byte
        // samples doubles it, under a header of at most 160 bytes.
        var buffer: [4096]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        const result = convert(&reader, &out, request, .{});
        // A stream the probe accepts converts in every supported cell, with
        // the same format and frame count; one it rejects never converts.
        if (probed) |info| {
            const supported = switch (request.mode) {
                .copy => request.output.carries(info.codec),
                .transcode => true,
            };
            if (!supported) {
                try std.testing.expectError(error.UnsupportedOperation, result);
            } else {
                const summary = try result;
                try std.testing.expectEqual(info.format, summary.format);
                try std.testing.expectEqual(info.frame_count, summary.frame_count);
            }
        } else |_| {
            if (result) |_| return error.TestExpectedError else |_| {}
        }
    }
}

test "fuzz: conversion agrees with probing on arbitrary input" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        fixtures.bytes("mono_8k"),
        fixtures.bytes("unknown_chunks"),
        fixtures.au.bytes("au_stereo_44k1"),
        fixtures.au.bytes("au_truncated_data"),
        fixtures.bytes("s24_stereo_48k_extensible"),
        fixtures.bytes("alaw_mono_8k"),
        fixtures.aiff.bytes("aifc_sowt"),
        fixtures.aiff.bytes("aiff_odd_data"),
    } });
}
