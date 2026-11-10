// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! Synchronous conversion and stream copy between the supported containers
//! (TODO.md T13a and subsequent codec tasks): PCM, FLAC, Ogg, MPEG audio,
//! ADTS AAC, AC-3/E-AC-3, ADPCM, ALAC and G.72x, within the registry
//! and operation matrix. MP4 currently supports probing only.
//!
//! The operation matrix (TODO.md T13), where WAV stands for WAV or Wave64 on
//! either side:
//!
//! | Input → output       | `transcode`                  | `copy`                                              |
//! | -------------------- | ---------------------------- | --------------------------------------------------- |
//! | into the same family | yes                          | yes                                                 |
//! | between families     | yes, through the PCM kernels | the codecs both carry, else `UnsupportedOperation` |
//!
//! Transcoding converts between every sample format (T23a), to the output
//! container's default codec or the requested one. Stream copy needs the output to carry the input's codec: WAV and
//! AU share A-law and µ-law, AU and AIFF the big-endian integer and float
//! encodings, and WAV and AIFF u8, s16le (`sowt`), A-law and µ-law.
//!
//! A rate (`Request.sample_rate`, T24) and a channel layout
//! (`Request.layout`, T23c) can be requested, and the samples are resampled
//! and rematrixed as libswresample does; with `copy` either is
//! `UnsupportedOperation`. Otherwise the output has the input's rate and
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
//! With `Request.tags`, supported metadata is carried into containers that
//! write it. Other container-specific chunks are omitted.
//!
//! PCM conversion without tags or resampling uses fixed scratch buffers.
//! Compressed inputs, compressed outputs, collected tags and resampling can
//! allocate; pass `Request.gpa` where required. Call `Conversion.deinit`
//! after every successful `init`, including when `run` fails. Writers and
//! resamplers release their run-local allocations before returning.

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
const flac = @import("flac.zig");
const flacmux = @import("flacmux.zig");
const oggmux = @import("oggmux.zig");
const oggdecode = @import("oggdecode.zig");
const decoded_input = @import("decoded.zig");
const wavadpcm = @import("wavadpcm.zig");
const aug72x = @import("aug72x.zig");
const cafalac = @import("cafalac.zig");
const cafmux = @import("cafmux.zig");
const alac = @import("../codec/alac.zig");
const adpcm = @import("../codec/adpcm.zig");
const mp3 = @import("mp3.zig");
const mp3decode = @import("mp3decode.zig");
const aacdecode = @import("aacdecode.zig");
const ac3decode = @import("ac3decode.zig");
const mp2mux = @import("mp2mux.zig");
const mp2enc = @import("../codec/mp2enc.zig");
const ac3mux = @import("ac3mux.zig");
const ac3enc = @import("../codec/ac3enc.zig");
const aacadts = @import("aacadts.zig");
const aacenc = @import("../codec/aacenc.zig");
const flacenc = @import("../codec/flacenc.zig");
const flac_codec = @import("../codec/flac.zig");
const seek = @import("seek.zig");
const codecs = @import("../codec/registry.zig");
/// FLAC's block size limit, the dither's call size for a headerless input.
const flac_max_frames = 65535;
const detect = @import("detect.zig");
const audioconvert = @import("../resample/audioconvert.zig");
const dither = @import("../resample/dither.zig");
const rematrix = @import("../resample/rematrix.zig");
const resample = @import("../resample/resample.zig");
const swr = @import("../resample/swr.zig");
const Frame = @import("../core/frame.zig").Frame;
const diagnostics = @import("../core/diagnostics.zig");

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
    /// samples convert to its storage as libswresample would: for FLAC
    /// (T26c), packed s16 or s32 as FFmpeg's filters pick them. Not for
    /// `copy`.
    codec: ?codecs.Codec = null,
    /// The FLAC encoder's options (T26c), for a FLAC output. Encoding a
    /// FLAC output needs `gpa`.
    flac: flacenc.Options = .{},
    /// The MP2 encoder's options (T29d), for an MP2 output: the bit rate
    /// (FFmpeg's `-b:a`) and the fixed-point quantizer (`-c:a mp2fixed`).
    mp2: mp2enc.Options = .{},
    /// The AC-3 encoder's options (T32c), for an AC-3 output: `-b:a`,
    /// `-cutoff`, `-audio_service_type` and the encoder's own. Encoding
    /// AC-3 needs `gpa`.
    ac3: ac3enc.Options = .{},
    /// The AAC encoder's options (T32d), for an ADTS output: `-b:a`,
    /// `-cutoff`, `-q:a`, `-profile` and the encoder's own. Encoding AAC
    /// needs `gpa`.
    aac: aacenc.Options = .{},
    /// The ADPCM encoders' options (T31a), for `adpcm_ima_wav` or
    /// `adpcm_ms` into WAV: FFmpeg's `-block_size` and `-trellis`. Encoding
    /// ADPCM needs `gpa`.
    adpcm: wavadpcm.EncodeOptions = .{},
    /// The ALAC encoder's options (T31b), for ALAC into CAF:
    /// `-compression_level`, `-min_prediction_order` and
    /// `-max_prediction_order`. Encoding ALAC needs `gpa` and an output
    /// that can seek back (`output_seekable`).
    alac: alac.EncodeOptions = .{},
    /// The G.722 and G.726 encoders' options (T31c), for `g722` or
    /// `g726le` into AU: FFmpeg's `-trellis`, `-code_size` and `-b:a`.
    /// Encoding them needs `gpa`.
    g72x: aug72x.EncodeOptions = .{},
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
    /// The output will be a regular file `runTo` can seek back in. A decoded
    /// Ogg or MP3 input's WAV, AU or AIFF header then says no frames until
    /// the end and is rewritten there, as FFmpeg's muxers rewrite a seekable
    /// output's header, so the stream is decoded once; otherwise such an
    /// input is decoded ahead once to count its samples. `runTo` without a
    /// seeker then refuses the request (`UnsupportedStreamingSize`) before
    /// writing.
    output_seekable: bool = false,
    /// Where FFmpeg's command line would log a warning (T17a): the guessed
    /// layout. The dither's own go to `dither.diagnostics`.
    diagnostics: ?diagnostics.Sink = null,
    /// The output's channel layout (FFmpeg's output `-ch_layout`; its `-ac N`
    /// gives N unspecified channels), for `transcode` (T23c): the samples
    /// are rematrixed as libswresample mixes them. An unspecified layout
    /// becomes the default for its count, as FFmpeg's command line picks
    /// it for a PCM encoder. Null keeps the input's layout. With `copy`, a
    /// layout other than the input's is `UnsupportedOperation`.
    layout: ?audio.ChannelLayout = null,
    /// The output's sample rate (FFmpeg's output `-ar`), for `transcode`
    /// (T24): the samples are resampled as FFmpeg's `aresample` filter does,
    /// within the resampler's declared tolerance. Null keeps the input's.
    /// With `copy`, another rate is `UnsupportedOperation`.
    sample_rate: ?u32 = null,
    /// The allocator for compressed inputs/outputs and resampling. Paths
    /// that require one refuse `null` with `UnsupportedOperation`.
    gpa: ?std.mem.Allocator = null,
    /// Carry the input's tags (T21c): `init` puts the tags FFmpeg's command
    /// would carry (`carriedTags`) from those before the input's `data` into
    /// the empty `tags.dictionary`, under FFmpeg's names, and a WAV output
    /// gets them as FFmpeg's writer would, in a `LIST`/`INFO` chunk. The
    /// supported FLAC, Ogg, MP3 and ADTS inputs also expose their tags, and
    /// FLAC, Ogg and CAF outputs write the tags their muxers support;
    /// tags after the input's `data` come too late for the output header and
    /// are not carried. The dictionary must outlive the conversion. Without
    /// it no input tag dictionary is collected.
    tags: ?wav.Tags = null,
};

/// Failures before any output exists: the input header, the request and the
/// output header. `LimitExceeded` can come from the input's or the output's
/// limits.
pub const InitError = detect.Error || wav.HeaderError || au.HeaderError || aiff.HeaderError || raw.HeaderError || rematrix.Error || resample.Error || error{
    /// The request is outside the operation matrix: stream copy into a
    /// container that cannot carry the codec, or with another rate or
    /// layout, or a combination the inputs and outputs do not support.
    UnsupportedOperation,
    /// The FLAC encoder refuses its options (T26c), as FFmpeg's
    /// `avcodec_open2` does.
    InvalidOption,
};

/// Failures once output has started: the rest of the input, or the output.
pub const RunError = detect.Error || std.Io.Writer.Error || resample.Error || error{
    /// The AC-3 encoder found no allocation that fits a frame at the bit
    /// rate (FFmpeg's "Bit allocation failed. Try increasing the bitrate.",
    /// EINVAL), which depends on the samples (T32c).
    InvalidOption,
    /// The AAC encoder refuses NaN or infinite samples ("Input contains
    /// (near) NaN/+-Inf", EINVAL; T32d).
    InvalidSamples,
    /// An AAC frame past the ADTS header's 13-bit length (the adts muxer's
    /// "frame size too large", AVERROR_INVALIDDATA; T32d).
    FrameTooLarge,
};

pub const Error = InitError || RunError;

pub const Summary = struct {
    input: Container,
    output: Container,
    mode: Mode,
    /// The encoding of the samples the pipeline reads: the input's PCM
    /// codec, or pcm_s16le for the frames a FLAC input decodes to.
    input_codec: pcm.Codec,
    /// The input stream's codec: `input_codec` for PCM, or FLAC (T26a),
    /// which no output carries, so it is never copied.
    input_stream: codecs.Codec,
    /// The PCM the output writer takes: the input codec when copying; when
    /// transcoding, the requested encoder or the output container's default
    /// codec, or for a FLAC output (T26c) the encoder's input, pcm_s16le or
    /// pcm_s32le.
    output_codec: pcm.Codec,
    /// The output stream's codec: `output_codec` for PCM, or FLAC.
    output_stream: codecs.Codec,
    /// The input's format, with the layout FFmpeg's command line gives it
    /// (`audio.guessLayout`, unless `Request.guess_layout` is off: an
    /// unspecified one becomes the default for its channel count, as for a
    /// plain WAV); the output's has the same rate, the output layout and
    /// the output codec's storage (`outputFormat`).
    format: audio.Format,
    /// The output's layout: the requested one (`Request.layout`), else the
    /// input's. A different one is rematrixed (T23c).
    output_layout: audio.ChannelLayout,
    /// The output's sample rate (`Request.sample_rate`, else the input's);
    /// another is resampled (T24).
    output_rate: u32,
    /// Sample frames in the output: the input's, or what the resampler
    /// gives for them (`resample.outputFrames`). Null when the input's are.
    output_frame_count: ?u64,
    /// Sample frames in the input and the output. The duration is this many
    /// units of `format.timeBase()`, exactly, in both. Null until `run` for an
    /// input of unknown length (raw PCM output only), which `run` counts.
    frame_count: ?u64,

    /// The output's format: the input's rate, the output layout, stored as
    /// the output codec stores.
    pub fn outputFormat(s: Summary) audio.Format {
        var format = s.format;
        format.layout = s.output_layout;
        format.sample_rate = s.output_rate;
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
    /// For a rate change (`Request.gpa`).
    gpa: ?std.mem.Allocator = null,
    /// Frames read so far: the next packet's timestamp.
    next_pts: i64 = 0,
    /// Frames written so far (resampled output).
    output_frames: u64 = 0,

    /// FFmpeg's frames per packet, the last aside: its conversion calls
    /// libswresample once per packet (`ffmpegPacketFrames`).
    packet_frames: u32,
    /// The FLAC encoder's options, for a FLAC output (T26c).
    flac_options: flacenc.Options = .{},
    /// The MP2 encoder's options, for an MP2 output (T29d).
    mp2_options: mp2enc.Options = .{},
    /// The AC-3 encoder's options, for an AC-3 output (T32c).
    ac3_options: ac3enc.Options = .{},
    /// The AAC encoder's options, for an ADTS output (T32d).
    aac_options: aacenc.Options = .{},
    /// The ADPCM encoders' options, for an ADPCM output (T31a).
    adpcm_options: wavadpcm.EncodeOptions = .{},
    /// The ALAC encoder's options, for an ALAC output (T31b).
    alac_options: alac.EncodeOptions = .{},
    /// The G.722 and G.726 encoders' options (T31c).
    g72x_options: aug72x.EncodeOptions = .{},
    /// An Ogg output's stream tags (T27b): the `encoder` tag the ffmpeg
    /// program sets under `-bitexact`; owned (`gpa`).
    stream_tags: metadata.Dictionary = .empty,
    /// The WAV, AU or AIFF header says no frames and `runTo` rewrites it at
    /// the end (`Request.output_seekable`).
    deferred_header: bool = false,

    /// One parser per format family; the WAV parser also reads Wave64. A
    /// FLAC input reads as its decoded frames.
    const Parser = union(enum) {
        wav: wav.Parser,
        au: au.Parser,
        aiff: aiff.Parser,
        caf: caf.Parser,
        flac: flac.DecodedReader,
        /// Ogg decoded (T27d, T28a): Vorbis, Opus, or FLAC in Ogg.
        ogg: oggdecode.DecodedReader,
        /// MP3 decoded (T29b).
        mp3: mp3decode.DecodedReader,
        /// ADTS decoded (T30b).
        aac: aacdecode.DecodedReader,
        /// Raw AC-3 decoded (T32a).
        ac3: ac3decode.DecodedReader,
        /// ADPCM in WAV decoded (T31a): the WAV parser, past its header.
        adpcm: wavadpcm.DecodedReader,
        /// ALAC in CAF decoded (T31b): the CAF parser, past its header.
        alac: cafalac.DecodedReader,
        /// G.722 and G.726 in AU decoded (T31c): the AU parser, past its
        /// header.
        g72x: aug72x.DecodedReader,
        raw: raw.Parser,
    };

    /// Reads the header of the opened `source` (probed, or forced with
    /// `Request.input` when it was opened) and checks the request and the
    /// output header. Reads at most up to the first sample and writes
    /// nothing.
    pub fn init(source: *detect.Input, request: Request, limits: Limits) InitError!Conversion {
        // avformat_open_input's leading ID3v2 tags, before the demuxers
        // with FF_INFMT_FLAG_ID3V2_AUTO that do not read their own.
        // Not Wave64's: its demuxer lacks the flag.
        var leading: detect.LeadingTags = if (source.container.readsLeadingId3v2())
            try source.readLeadingTags(if (request.tags) |t| t.gpa else null, limits.max_id3v2_bytes)
        else
            .{};
        defer leading.deinit();
        var input: Parser = switch (source.container.family()) {
            .wav => .{ .wav = source.wavParser(limits.wav) },
            .au => .{ .au = .init(source.reader(), limits.au) },
            .aiff => .{ .aiff = .init(source.reader(), limits.aiff) },
            // ALAC (T31b) needs the packet table's allocator, and a table
            // after the samples a seekable input read from its start.
            .caf => caf: {
                const gpa = request.gpa orelse break :caf .{ .caf = .init(source.reader(), limits.caf) };
                const sk = try rewound(source);
                var parser: caf.Parser = .init(if (sk != null) source.replay.source else source.reader(), limits.caf);
                parser.enableAlac(gpa, sk);
                break :caf .{ .caf = parser };
            },
            // The demuxer and decoder allocate.
            .flac => .{ .flac = .init(request.gpa orelse return error.UnsupportedOperation, source.reader(), request.diagnostics) },
            // Decoded: Vorbis, Opus (CELT frames) or FLAC; no Ogg stream
            // copy yet. The demuxer reads the input from its start, through the seekable
            // reader when the input can seek (its durations), else after
            // detection's replay.
            .ogg => .{ .ogg = if (try rewound(source)) |sk|
                .init(request.gpa orelse return error.UnsupportedOperation, source.replay.source, sk, request.diagnostics)
            else
                .init(request.gpa orelse return error.UnsupportedOperation, source.reader(), null, request.diagnostics) },
            .raw => .{ .raw = source.rawParser(limits.raw) },
            // Decoded (T29b), read as the Ogg input is.
            .mp3 => .{ .mp3 = if (try rewound(source)) |sk|
                .init(request.gpa orelse return error.UnsupportedOperation, source.replay.source, sk, request.diagnostics)
            else
                .init(request.gpa orelse return error.UnsupportedOperation, source.reader(), null, request.diagnostics) },
            // Output only: detection never names them.
            .mp2, .adts => return error.UnsupportedOperation,
            // MP4 is read without decoding (T33a1): conversion waits for a
            // subtask that gives the decoders a container's packets
            // (notes.md "MP4 demuxing").
            .mov => return error.UnsupportedOperation,
            // Decoded (T30b), read as the MP3 input is.
            .aac => .{ .aac = if (try rewound(source)) |sk|
                .init(request.gpa orelse return error.UnsupportedOperation, source.replay.source, sk, request.diagnostics)
            else
                .init(request.gpa orelse return error.UnsupportedOperation, source.reader(), null, request.diagnostics) },
            // Decoded (T32a), read as the ADTS input is.
            .ac3 => .{ .ac3 = if (try rewound(source)) |sk|
                .init(request.gpa orelse return error.UnsupportedOperation, source.replay.source, sk, request.diagnostics, if (source.container == .eac3) .eac3 else .ac3)
            else
                .init(request.gpa orelse return error.UnsupportedOperation, source.reader(), null, request.diagnostics, if (source.container == .eac3) .eac3 else .ac3) },
        };
        errdefer deinitParser(&input);
        // A header written before the samples needs their count. A decoded
        // Ogg, MP3 or ADTS input counts them ahead (decoding the stream twice)
        // only when that header cannot be rewritten at the end.
        const header_first = switch (request.output.family()) {
            .wav, .au, .aiff => true,
            .raw, .flac, .ogg, .caf, .mp3, .mp2, .aac, .adts, .ac3, .mov => false,
        };
        switch (input) {
            .ogg => |*reader| reader.count_ahead = header_first and !request.output_seekable,
            .mp3 => |*reader| reader.count_ahead = header_first and !request.output_seekable,
            .aac => |*reader| reader.count_ahead = header_first and !request.output_seekable,
            .ac3 => |*reader| reader.count_ahead = header_first and !request.output_seekable,
            .wav, .au, .aiff, .caf, .flac, .adpcm, .alac, .g72x, .raw => {},
        }
        // The tags as the file stores them, renamed once the header is read.
        var stored: metadata.Dictionary = .empty;
        defer if (request.tags) |t| stored.deinit(t.gpa);
        if (request.tags) |t| {
            std.debug.assert(t.dictionary.count() == 0);
            switch (input) {
                .wav => |*parser| parser.collectTags(.{ .gpa = t.gpa, .dictionary = &stored }),
                .au, .aiff, .caf, .flac, .ogg, .mp3, .aac, .ac3, .adpcm, .alac, .g72x, .raw => {},
            }
        }
        // A WAV header naming ADPCM (T31a) makes the input its decoded
        // samples; the decoder and its buffers allocate.
        var wav_info: ?wav.Info = null;
        if (input == .wav) {
            const info = try input.wav.readHeader();
            if (info.adpcm != null) {
                const gpa = request.gpa orelse return error.UnsupportedOperation;
                const reader: wavadpcm.DecodedReader = try .init(gpa, input.wav, info, request.diagnostics);
                input = .{ .adpcm = reader };
                input.adpcm.count_ahead = header_first and !request.output_seekable;
            } else wav_info = info;
        }
        // A CAF header naming ALAC (T31b), likewise.
        var caf_info: ?caf.Info = null;
        if (input == .caf) {
            const info = try input.caf.readHeader();
            if (info.alac != null) {
                const gpa = request.gpa.?; // ALAC needs it: enableAlac above
                const reader: cafalac.DecodedReader = try .init(gpa, input.caf, info, request.diagnostics);
                input = .{ .alac = reader };
                input.alac.count_ahead = header_first and !request.output_seekable;
            } else caf_info = info;
        }
        // An AU header naming G.722 or G.726 (T31c), likewise.
        var au_info: ?au.Info = null;
        if (input == .au) {
            const info = try input.au.readHeader();
            if (info.g72x != null) {
                const gpa = request.gpa orelse return error.UnsupportedOperation;
                const reader: aug72x.DecodedReader = try .init(gpa, input.au, info);
                input = .{ .g72x = reader };
            } else au_info = info;
        }
        var summary: Summary = switch (input) {
            inline else => |*parser, tag| blk: {
                const info = if (tag == .wav) wav_info.? else if (tag == .caf) caf_info.? else if (tag == .au) au_info.? else try parser.readHeader();
                // Unknown for WAV and AU only on request, and for raw PCM
                // without a known length.
                const frame_count: ?u64 = info.frame_count;
                break :blk .{
                    .input = source.container,
                    .output = request.output,
                    .mode = request.mode,
                    .input_codec = info.codec,
                    .input_stream = streamOf(info),
                    // Set below, from the stream's codec.
                    .output_codec = undefined,
                    .output_stream = switch (request.mode) {
                        .copy => streamOf(info),
                        // The requested encoder, else the muxer's default; an
                        // output without a muxer fails the request check below.
                        .transcode => request.codec orelse request.output.defaultCodec() orelse .{ .pcm = info.codec },
                    },
                    .format = guessed: {
                        var format = info.format;
                        // The program guesses before opening the decoder; the
                        // Opus and Vorbis decoders then set their own layout,
                        // an unspecified one included (Opus' mapping family
                        // 255, Vorbis past 8 channels), which the output keeps.
                        if (request.guess_layout and !decoderSetsLayout(streamOf(info))) {
                            const guessed = audio.guessLayout(format.layout);
                            if (format.layout == .unspecified and guessed != .unspecified) {
                                var name: [64]u8 = undefined;
                                var w: std.Io.Writer = .fixed(&name);
                                guessed.describe(&w) catch {};
                                diagnostics.report(request.diagnostics, .warning, "Guessed Channel Layout: {s}", .{w.buffered()});
                            }
                            format.layout = guessed;
                        }
                        break :guessed format;
                    },
                    // Set below, from the request.
                    .output_layout = undefined,
                    .output_rate = info.format.sample_rate,
                    .output_frame_count = frame_count,
                    .frame_count = frame_count,
                };
            },
        };
        var tags: ?*const metadata.Dictionary = null;
        if (request.tags) |t| {
            // Later tags could not reach the output header; `stored` dies here.
            switch (input) {
                .wav => |*parser| parser.tags = null,
                .adpcm => |*reader| reader.parser.tags = null,
                .au, .aiff, .caf, .flac, .ogg, .mp3, .aac, .ac3, .alac, .g72x, .raw => {},
            }
            // FLAC's tags are already under FFmpeg's names (T26b).
            var generic = switch (input) {
                .flac => |*reader| try reader.demuxer.?.info.tags.clone(t.gpa),
                // Ogg's comments are stream tags: the format has none.
                .ogg => metadata.Dictionary.empty,
                // MP3's ID3 and APE tags are the format's, under FFmpeg's
                // names.
                .mp3 => |*reader| try reader.tags().clone(t.gpa),
                // ADTS's ID3 and APE tags, likewise.
                .aac => |*reader| try reader.tags().clone(t.gpa),
                else => try wav.genericTags(t.gpa, &stored),
            };
            defer generic.deinit(t.gpa);
            try leading.merge(&generic);
            const carried = try carriedTags(t.gpa, &generic, request.mode);
            t.dictionary.deinit(t.gpa);
            t.dictionary.* = carried;
            tags = t.dictionary;
        }
        summary.output_codec = switch (summary.output_stream) {
            .pcm => |codec| codec,
            .flac => flacStorage(summary.format.sample_format),
            // No encoder: refused by the operation check below.
            // The MP2 encoders take s16 (T29d), and the ADPCM ones (T31a).
            // The MP2 encoders take s16 (T29d), the ADPCM ones (T31a), and
            // G.722's and G.726's (T31c).
            .mp2, .adpcm_ima_wav, .adpcm_ms, .adpcm_g722, .adpcm_g726le => .s16le,
            // ALAC's encoder takes s16p or s32p, picked as FLAC's (T31b).
            .alac => flacStorage(summary.format.sample_format),
            // The AC-3 encoder takes fltp, which the writer makes of
            // packed float (T32c).
            .ac3 => .f32le,
            // The AAC encoder takes fltp too (T32d).
            .aac => .f32le,
            .vorbis, .opus, .mp1, .mp3, .eac3 => return error.UnsupportedOperation,
        };
        // FFmpeg's set_channel_layout: an unspecified request takes the
        // default for its count.
        summary.output_layout = if (request.layout) |layout| switch (layout) {
            .unspecified => |count| .default(count),
            .native, .custom => layout,
        } else summary.format.layout;
        if (request.sample_rate) |rate| summary.output_rate = rate;
        const resampling = summary.output_rate != summary.format.sample_rate;
        // Any storage converts to any other (T23a); the output must carry
        // the codec, and copy takes no encoder and keeps the layout and the
        // rate; resampling needs an allocator.
        const supported = switch (request.mode) {
            .copy => request.codec == null and summary.input_stream == .pcm and request.output.carries(summary.input_codec) and
                summary.output_layout.eql(&summary.format.layout) and !resampling,
            // The FLAC and ADPCM encoders allocate.
            .transcode => request.output.carriesCodec(summary.output_stream) and (!resampling or request.gpa != null) and
                (adpcmOutput(summary.output_stream) == null or request.gpa != null) and
                (g72xOutput(summary.output_stream) == null or request.gpa != null) and
                (summary.output_stream != .alac or request.gpa != null) and
                (summary.output_stream != .ac3 or request.gpa != null) and
                (summary.output_stream != .aac or request.gpa != null) and
                (summary.output_stream != .flac or request.gpa != null),
        };
        if (!supported) return error.UnsupportedOperation;
        // A layout libswresample cannot mix fails before any output (T23c).
        if (request.mode == .transcode) _ = try rematrix.needed(summary.format.layout, summary.output_layout);
        // Without a count, the decoded input's header is rewritten at the end.
        const deferred_header = header_first and request.output_seekable and summary.frame_count == null and
            (input == .ogg or input == .mp3 or input == .aac or input == .ac3 or input == .adpcm or input == .alac or input == .g72x);
        if (summary.output_rate == 0) return error.InvalidFormat;
        // The resampler's frame count, which the writers' headers need (T24).
        if (resampling) {
            if (summary.frame_count) |count| {
                summary.output_frame_count = try resample.outputFrames(count, summary.format.sample_rate, summary.output_rate, .{});
            }
        }
        switch (request.output.family()) {
            .wav => if (adpcmOutput(summary.output_stream)) |codec|
                try wavadpcm.Writer.check(codec, summary.outputFormat(), if (deferred_header) null else try knownCount(summary), request.adpcm, wavOptions(limits, request.output, tags))
            else
                try wav.Writer.check(summary.output_codec, summary.outputFormat(), try headerCount(summary, deferred_header), wavOptions(limits, request.output, tags)),
            .au => if (g72xOutput(summary.output_stream)) |codec|
                try aug72x.Writer.check(codec, summary.outputFormat(), if (deferred_header) null else try knownCount(summary), request.g72x, limits.au)
            else
                try au.Writer.check(summary.output_codec, summary.outputFormat(), try headerCount(summary, deferred_header), limits.au),
            .aiff => try aiff.Writer.check(summary.output_codec, summary.outputFormat(), try headerCount(summary, deferred_header), aiffOptions(limits)),
            .raw => try raw.Writer.check(summary.output_codec, summary.outputFormat(), rawOptions(limits)),
            .flac => flacmux.Writer.check(request.gpa.?, summary.output_codec, summary.outputFormat(), sourceBits(summary, &input), .{ .encoder = request.flac, .tags = tags }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedFormat => error.UnsupportedFormat,
                error.InvalidOption => error.InvalidOption,
                error.TagsTooLong => error.LimitExceeded,
            },
            // FLAC encoded into Ogg (T27b); no other encoder writes an Ogg codec.
            .ogg => flacmux.Writer.check(request.gpa.?, summary.output_codec, summary.outputFormat(), sourceBits(summary, &input), .{ .encoder = request.flac, .tags = tags, .container = .{ .ogg = .{} } }) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedFormat => error.UnsupportedFormat,
                error.InvalidOption => error.InvalidOption,
                error.TagsTooLong => error.LimitExceeded,
            },
            // FFmpeg's MP2 encoder before its raw muxer (T29d).
            .mp2 => try mp2mux.Writer.check(summary.output_codec, summary.outputFormat(), request.mp2),
            .caf => try cafmux.Writer.check(cafCoding(summary.output_stream, summary.output_codec, request.alac), summary.outputFormat(), request.output_seekable, tags),
            // FFmpeg's AC-3 encoder before its raw muxer (T32c).
            .ac3 => ac3mux.Writer.check(request.gpa.?, summary.output_codec, summary.outputFormat(), request.ac3) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedFormat => error.UnsupportedFormat,
                error.InvalidOption => error.InvalidOption,
            },
            .mp3, .aac, .mov => unreachable, // no muxer: refused above as UnsupportedOperation
            // FFmpeg's AAC encoder before its adts muxer (T32d).
            .adts => aacadts.Writer.check(request.gpa.?, summary.output_codec, summary.outputFormat(), request.aac) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.UnsupportedFormat => error.UnsupportedFormat,
                error.InvalidOption => error.InvalidOption,
            },
        }
        // For a decoded input, the largest frame its decoder gives: the
        // buffers of `transferResampled`, which takes each frame whole.
        const packet_frames = switch (input) {
            // FFmpeg's packets are the FLAC frames.
            .flac => |*reader| if (reader.demuxer.?.info.stream_info) |si| si.max_blocksize else flac_max_frames,
            // The decoder's frames: Vorbis' long block, FLAC's largest.
            .ogg => |*reader| reader.max_frame,
            .mp3 => mp3decode.DecodedReader.max_frame,
            .aac => aacdecode.DecodedReader.max_frame,
            .ac3 => ac3decode.DecodedReader.max_frame,
            // A block's samples; at least one for the resampler's buffers.
            .adpcm => |*reader| @max(1, reader.maxFrame()),
            .alac => |*reader| reader.maxFrame(),
            // A packet's samples.
            .g72x => |*reader| reader.maxFrame(),
            else => ffmpegPacketFrames(summary.input, summary.input_codec, summary.format),
        };
        if (resampling) try checkResampling(summary, packet_frames);
        // Raw PCM has no header to hold STREAMINFO's count, nor has FLAC
        // before its encoder's final STREAMINFO, so a FLAC stream that
        // decodes to another count converts as FFmpeg converts it; the
        // summary's counts are the decoded ones once `run` returns.
        switch (input) {
            .flac => |*reader| if (request.output.family() == .raw or request.output.family() == .flac or request.output.family() == .ogg) {
                reader.expected = null;
                // The dither's calls still follow STREAMINFO's count.
                summary.output_frame_count = null;
            },
            // A stream's duration is the expected count only for an output
            // whose header holds it.
            .ogg => |*reader| if (request.output.family() == .raw or request.output.family() == .flac or request.output.family() == .ogg) {
                reader.expected = null;
                summary.output_frame_count = null;
            },
            inline .mp3, .aac, .ac3, .adpcm, .alac => |*reader| if (request.output.family() == .raw or request.output.family() == .flac or request.output.family() == .ogg) {
                reader.expected = null;
                summary.output_frame_count = null;
            },
            // The data's size gives the decoded count exactly.
            .wav, .au, .aiff, .caf, .g72x, .raw => {},
        }
        var stream_tags: metadata.Dictionary = .empty;
        // Only an Ogg output, which needs `gpa`, holds any.
        errdefer if (request.gpa) |gpa| stream_tags.deinit(gpa);
        if (request.output.family() == .ogg) {
            // The ffmpeg program's set_encoder_id under -bitexact.
            stream_tags.put(request.gpa.?, "encoder", "Lavc flac", .replace) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidTag => unreachable, // a constant
            };
            // Then the input stream's own tags (an Ogg input's), as
            // copy_meta adds them without replacing a key, less those the
            // program drops when it re-encodes.
            switch (input) {
                .ogg => |*reader| try carryStreamTags(request.gpa.?, &stream_tags, reader.streamTags()),
                .wav, .au, .aiff, .caf, .flac, .mp3, .aac, .ac3, .adpcm, .alac, .g72x, .raw => {},
            }
            // The comment header holds the stream tags too, so its bound
            // is checked again with them, before any output exists.
            oggmux.checkTags(request.gpa.?, .flac, &stream_tags, tags) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.TagsTooLong => error.LimitExceeded,
            };
        }
        return .{
            .input = input,
            .limits = limits,
            .summary = summary,
            .tags = tags,
            .dither = request.dither,
            .gpa = request.gpa,
            .packet_frames = packet_frames,
            .flac_options = request.flac,
            .mp2_options = request.mp2,
            .ac3_options = request.ac3,
            .aac_options = request.aac,
            .adpcm_options = request.adpcm,
            .alac_options = request.alac,
            .g72x_options = request.g72x,
            .stream_tags = stream_tags,
            .deferred_header = deferred_header,
        };
    }

    /// Releases the input reader and conversion-owned stream tags. Call
    /// after successful initialization, also when the single run fails.
    pub fn deinit(c: *Conversion) void {
        if (c.gpa) |gpa| c.stream_tags.deinit(gpa);
        deinitParser(&c.input);
    }

    fn deinitParser(input: *Parser) void {
        switch (input.*) {
            .flac => |*reader| reader.deinit(),
            .ogg => |*reader| reader.deinit(),
            .mp3 => |*reader| reader.deinit(),
            .aac => |*reader| reader.deinit(),
            .ac3 => |*reader| reader.deinit(),
            .adpcm => |*reader| reader.deinit(),
            .alac => |*reader| reader.deinit(),
            .g72x => |*reader| reader.deinit(),
            .caf => |*parser| parser.deinit(),
            .wav, .au, .aiff, .raw => {},
        }
    }

    /// What a rate change refuses from the request alone, before any output
    /// (port.md "CLI policy"): what `swr.Swr.init` refuses for FFmpeg's
    /// packet sizes, and into FLAC (or FLAC in Ogg) a first resampled output
    /// outside FLAC's block sizes, which the ffmpeg program opens its
    /// encoder with and fails on. That output depends on the input's
    /// length, which only a PCM input's header gives exactly: a FLAC or Ogg
    /// input's, or one of unknown length, is checked when it comes
    /// (`flacmux.Writer`).
    fn checkResampling(summary: Summary, packet_frames: u32) InitError!void {
        try swr.Swr.check(summary.format, summary.outputFormat(), packet_frames, .{});
        switch (summary.output.family()) {
            .flac, .ogg => {},
            .wav, .au, .aiff, .raw, .caf, .mp3, .mp2, .aac, .adts, .ac3, .mov => return,
        }
        switch (summary.input.family()) {
            .wav, .au, .aiff, .caf, .raw => {},
            .flac, .ogg, .mp3, .mp2, .aac, .adts, .ac3, .mov => return,
        }
        // ADPCM in WAV is a decoded input (T31a).
        if (summary.input_stream != .pcm) return;
        const count = summary.frame_count orelse return;
        const first = try swr.Swr.firstOutputFrames(summary.format.sample_rate, summary.output_rate, packet_frames, count, .{}) orelse return;
        if (first < flac_codec.min_blocksize or first > flac_codec.max_blocksize) return error.UnsupportedFormat;
    }

    /// The frame count a writer's header needs up front.
    /// The count a header-first writer is checked with: the known one, or
    /// none yet for a header rewritten at the end.
    fn headerCount(summary: Summary, deferred: bool) error{UnsupportedStreamingSize}!u64 {
        return if (deferred) 0 else knownCount(summary);
    }

    fn knownCount(summary: Summary) error{UnsupportedStreamingSize}!u64 {
        return summary.output_frame_count orelse error.UnsupportedStreamingSize;
    }

    /// Writes the output header, moves every frame, validates the rest of the
    /// input and finishes the output, which flushes `out`. On failure `out`
    /// may hold a partial stream.
    pub fn run(c: *Conversion, out: *std.Io.Writer) RunError!void {
        return c.runTo(out, null);
    }

    /// `run` on an output that can seek back, where a FLAC output's final
    /// STREAMINFO replaces the first, as FFmpeg's muxer rewrites a seekable
    /// output's (T26c); `seeker` moves `out`.
    /// libswresample's mix levels as the ffmpeg program's aresample sets
    /// them from an (E-)AC-3 decoder's downmix info: the Lt/Rt levels and
    /// the matrix encoding of a preferred Lt/Rt or Pro Logic II downmix
    /// into stereo, else the Lo/Ro levels, and the LFE level; without the
    /// info libswresample's defaults.
    fn mixLevels(c: *const Conversion) rematrix.Options {
        const dm = switch (c.input) {
            .ac3 => |*reader| reader.downmix orelse return .{},
            else => return .{},
        };
        var options: rematrix.Options = .{ .center_mix_level = dm.center_mix_level, .surround_mix_level = dm.surround_mix_level, .lfe_mix_level = dm.lfe_mix_level };
        // "Don't use Dolby Surround compatible coeffs when not downmixing
        // to stereo".
        if (!c.summary.output_layout.eql(&audio.ChannelLayout.stereo)) return options;
        switch (dm.preferred) {
            1, 3 => {
                options.matrix_encoding = if (dm.preferred == 1) .dolby else .dplii;
                options.center_mix_level = dm.center_mix_level_ltrt;
                options.surround_mix_level = dm.surround_mix_level_ltrt;
            },
            else => {},
        }
        return options;
    }

    /// The ffmpeg program's first frame for an encoder that takes its
    /// size from it (FLAC's block size, G.722's frame size): the first
    /// packet's, a decoded input's first frame, or, null, the resampler's
    /// first output (`transferResampled`).
    fn firstFrame(c: *Conversion) RunError!?u32 {
        const s = c.summary;
        if (s.output_rate != s.format.sample_rate) return null;
        return switch (c.input) {
            .flac => |*reader| try reader.firstFrameSamples(),
            .ogg => |*reader| try reader.firstFrameSamples(),
            .mp3 => |*reader| try reader.firstFrameSamples(),
            .aac => |*reader| try reader.firstFrameSamples(),
            .ac3 => |*reader| try reader.firstFrameSamples(),
            .adpcm => |*reader| try reader.firstFrameSamples(),
            .alac => |*reader| try reader.firstFrameSamples(),
            .g72x => |*reader| try reader.firstFrameSamples(),
            else => c.packet_frames,
        };
    }

    pub fn runTo(c: *Conversion, out: *std.Io.Writer, seeker: ?seek.OutputSeeker) RunError!void {
        const s = c.summary;
        // `init` checked that every writer but raw PCM's has a known count,
        // or a header rewritten at the end, which needs the output to seek:
        // without a seeker that is refused before any byte is written.
        const rewrite: ?seek.OutputSeeker = if (c.deferred_header) seeker orelse return error.UnsupportedStreamingSize else null;
        switch (s.output.family()) {
            .wav => if (adpcmOutput(s.output_stream)) |codec| {
                const options = wavOptions(c.limits, s.output, c.tags);
                const count: ?u64 = if (rewrite != null) null else s.output_frame_count.?;
                var writer = wavadpcm.Writer.begin(c.gpa.?, out, codec, s.outputFormat(), count, c.adpcm_options, options) catch |err| return outputFailure(err);
                defer writer.deinit();
                try c.transfer(wavadpcm.Writer, &writer);
                if (rewrite) |sk| writer.rewriteHeader(sk) catch |err| return outputFailure(err);
            } else {
                const options = wavOptions(c.limits, s.output, c.tags);
                const begun = if (rewrite != null)
                    wav.Writer.beginDeferred(out, s.output_codec, s.outputFormat(), options)
                else
                    wav.Writer.begin(out, s.output_codec, s.outputFormat(), s.output_frame_count.?, options);
                var writer = begun catch |err| return outputFailure(err);
                try c.transfer(wav.Writer, &writer);
                if (rewrite) |sk| writer.rewriteHeader(sk) catch |err| return outputFailure(err);
            },
            .au => if (g72xOutput(s.output_stream)) |codec| {
                const count: ?u64 = if (rewrite != null) null else s.output_frame_count.?;
                // G.722's frame size is the first frame's (`aug72x`).
                const first = try c.firstFrame();
                var writer = aug72x.Writer.begin(c.gpa.?, out, codec, s.outputFormat(), count, first, c.g72x_options, c.limits.au) catch |err| return outputFailure(err);
                defer writer.deinit();
                try c.transfer(aug72x.Writer, &writer);
                if (rewrite) |sk| writer.rewriteHeader(sk) catch |err| return outputFailure(err);
            } else {
                const begun = if (rewrite != null)
                    au.Writer.beginDeferred(out, s.output_codec, s.outputFormat(), c.limits.au)
                else
                    au.Writer.begin(out, s.output_codec, s.outputFormat(), s.output_frame_count.?, c.limits.au);
                var writer = begun catch |err| return outputFailure(err);
                try c.transfer(au.Writer, &writer);
                if (rewrite) |sk| writer.rewriteHeader(sk) catch |err| return outputFailure(err);
            },
            .aiff => {
                const begun = if (rewrite != null)
                    aiff.Writer.beginDeferred(out, s.output_codec, s.outputFormat(), aiffOptions(c.limits))
                else
                    aiff.Writer.begin(out, s.output_codec, s.outputFormat(), s.output_frame_count.?, aiffOptions(c.limits));
                var writer = begun catch |err| return outputFailure(err);
                try c.transfer(aiff.Writer, &writer);
                if (rewrite) |sk| writer.rewriteHeader(sk) catch |err| return outputFailure(err);
            },
            .raw => {
                var writer = raw.Writer.begin(out, s.output_codec, s.outputFormat(), s.output_frame_count, rawOptions(c.limits)) catch |err| return outputFailure(err);
                try c.transfer(raw.Writer, &writer);
            },
            .flac => {
                // The ffmpeg program opens the encoder with its first frame:
                // the first packet's, a FLAC input's first decoded frame,
                // or the resampler's first output (`transferResampled`).
                const first = try c.firstFrame();
                var writer = flacmux.Writer.begin(c.gpa.?, out, seeker, s.output_codec, s.outputFormat(), sourceBits(s, &c.input), first, .{ .encoder = c.flac_options, .tags = c.tags }) catch |err| return outputFailure(err);
                defer writer.deinit();
                try c.transfer(flacmux.Writer, &writer);
            },
            // FLAC into Ogg (T27b): the FLAC writer's encoder before
            // FFmpeg's Ogg muxer, which rewrites nothing at the end.
            .ogg => {
                const first = try c.firstFrame();
                var writer = flacmux.Writer.begin(c.gpa.?, out, null, s.output_codec, s.outputFormat(), sourceBits(s, &c.input), first, .{ .encoder = c.flac_options, .tags = c.tags, .container = .{ .ogg = .{ .stream_tags = &c.stream_tags } } }) catch |err| return outputFailure(err);
                defer writer.deinit();
                try c.transfer(flacmux.Writer, &writer);
            },
            .mp2 => {
                var writer = mp2mux.Writer.begin(out, s.output_codec, s.outputFormat(), c.mp2_options) catch |err| return outputFailure(err);
                try c.transfer(mp2mux.Writer, &writer);
            },
            // FFmpeg's CAF muxer (T31b): the trailer seeks back when it can.
            .caf => {
                var writer = cafmux.Writer.begin(c.gpa, out, seeker, cafCoding(s.output_stream, s.output_codec, c.alac_options), s.outputFormat(), c.tags) catch |err| return outputFailure(err);
                defer writer.deinit();
                try c.transfer(cafmux.Writer, &writer);
            },
            .ac3 => {
                var writer = ac3mux.Writer.begin(c.gpa.?, out, s.output_codec, s.outputFormat(), c.ac3_options) catch |err| return outputFailure(err);
                defer writer.deinit();
                try c.transfer(ac3mux.Writer, &writer);
            },
            .adts => {
                var writer = aacadts.Writer.begin(c.gpa.?, out, s.output_codec, s.outputFormat(), c.aac_options) catch |err| return outputFailure(err);
                defer writer.deinit();
                try c.transfer(aacadts.Writer, &writer);
            },
            .mp3, .aac, .mov => unreachable, // no muxer: `init` refused it
        }
        // Every frame was read: an unknown count is now known, and a FLAC
        // stream's decoded count replaces STREAMINFO's (equal unless raw
        // output let them differ).
        const decoded = c.input == .flac;
        if (c.summary.frame_count == null or decoded) c.summary.frame_count = @intCast(c.next_pts);
        if (c.summary.output_frame_count == null or decoded) {
            // `output_frames` counts resampled output only.
            const resampled = c.summary.output_rate != c.summary.format.sample_rate;
            c.summary.output_frame_count = if (resampled) c.output_frames else c.summary.frame_count;
        }
    }

    fn transfer(c: *Conversion, comptime W: type, writer: *W) RunError!void {
        var packet_bytes: [transfer_len]u8 = undefined;
        switch (c.summary.mode) {
            .copy => while (try c.readPacket(&packet_bytes)) |packet| {
                writer.writeData(packet.data) catch |err| return outputFailure(err);
            },
            .transcode => if (c.summary.output_rate != c.summary.format.sample_rate) {
                try c.transferResampled(W, writer);
            } else {
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
                const remixing = remix.init(s.format, out_format.layout, out_format.sample_format, c.mixLevels()) catch unreachable;
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
                // AAC's established dither calls use 1024 samples even
                // when SBR needs room for a complete 2048-sample frame.
                const dither_frames = if (c.input == .aac) 1024 else c.packet_frames;
                if (dithered) |*d| d.setCalls(dither_frames, s.frame_count);
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

    /// Transcoding with a rate change (T24): decoded frames go through
    /// libswresample's conversion as FFmpeg's `aresample` runs it
    /// (resample/swr.zig), each of its calls encoded and written.
    fn transferResampled(c: *Conversion, comptime W: type, writer: *W) RunError!void {
        const s = c.summary;
        // `init` refused a rate change without an allocator.
        const gpa = c.gpa.?;
        const out_format = s.outputFormat();
        var options: swr.Options = .{ .dither = c.dither, .remix = c.mixLevels() };
        // FFmpeg's command line tells libswresample a 24-bit encoder keeps
        // 24 bits of s32.
        options.dither.output_sample_bits = if (s.output_codec.bytesPerSample() == 3) 24 else 0;
        var converter = swr.Swr.init(gpa, s.format, out_format, c.packet_frames, options) catch |err| switch (err) {
            // `init` ran the same checks.
            error.UnsupportedLayout => unreachable,
            else => |e| return e,
        };
        defer converter.deinit();
        const encoded = try gpa.alloc(u8, converter.max_room * s.output_codec.bytesPerSample() * out_format.channelCount());
        defer gpa.free(encoded);
        var encoder: pcm.Encoder = .init(s.output_codec, out_format, encoded);
        switch (c.input) {
            .flac, .ogg, .mp3, .aac, .ac3, .adpcm, .alac, .g72x => try c.resampleFrames(W, writer, &converter, &encoder),
            .wav, .au, .aiff, .caf, .raw => try c.resamplePackets(W, writer, &converter, &encoder),
        }
        encoder.finishInput();
        try writeAllEncoded(W, writer, &encoder);
        std.debug.assert(encoder.receive() == .drained);
    }

    /// A PCM input: FFmpeg's decoder frames are its demuxer's packets of
    /// `packet_frames`, which `take` cuts the samples into.
    fn resamplePackets(c: *Conversion, comptime W: type, writer: *W, converter: *swr.Swr, encoder: *pcm.Encoder) RunError!void {
        const s = c.summary;
        var packet_bytes: [transfer_len]u8 = undefined;
        var decoded: [2 * transfer_len]u8 = undefined;
        var decoder: pcm.Decoder = .init(s.input_codec, s.format, &decoded);
        var input_done = false;
        while (true) {
            if (!input_done) {
                if (try c.readPacket(&packet_bytes)) |packet| {
                    const sent = decoder.send(packet) catch unreachable;
                    std.debug.assert(sent == .accepted);
                } else {
                    decoder.finishInput();
                    input_done = true;
                }
            }
            switch (decoder.receive()) {
                .output => |frame| {
                    const view = frame.view();
                    const count: u32 = @intCast(frame.frameCount());
                    var at: u32 = 0;
                    while (at < count) {
                        at += converter.take(view, at, count - at);
                        while (try converter.next()) |out| try c.encodeResampled(W, writer, encoder, out);
                    }
                },
                .need_input => continue,
                .drained => break,
            }
        }
        converter.finish();
        while (try converter.next()) |out| try c.encodeResampled(W, writer, encoder, out);
    }

    /// A decoded input (FLAC, Ogg): each frame the decoder gives is one
    /// `aresample` call, as the ffmpeg program's filter graph passes it
    /// (af_aresample.c's `activate`): first the output a call that filled
    /// its room left buffered (`flush_frame` without `final`), then the
    /// frame (`filter_frame`); at the end, the resampler flushed. The calls
    /// decide the output frames, and so a FLAC output's block size.
    fn resampleFrames(c: *Conversion, comptime W: type, writer: *W, converter: *swr.Swr, encoder: *pcm.Encoder) RunError!void {
        const s = c.summary;
        const gpa = c.gpa.?;
        // `packet_frames` is the decoder's largest frame, and `readData`
        // returns at most the rest of one frame: a buffer of that many
        // frames receives each frame whole.
        const frame_len = std.math.mul(usize, c.packet_frames, s.format.bytesPerFrame()) catch return error.OutOfMemory;
        std.debug.assert(s.input_codec.bytesPerSample() == s.format.sample_format.bytesPerSample());
        const frame_bytes = try gpa.alloc(u8, frame_len);
        defer gpa.free(frame_bytes);
        const decoded = try gpa.alloc(u8, frame_len);
        defer gpa.free(decoded);
        var decoder: pcm.Decoder = .init(s.input_codec, s.format, decoded);
        while (try c.readPacket(frame_bytes)) |packet| {
            const sent = decoder.send(packet) catch unreachable; // whole frames, decoded into as many bytes
            std.debug.assert(sent == .accepted);
            const frame = switch (decoder.receive()) {
                .output => |f| f,
                .need_input, .drained => unreachable, // a packet was just accepted
            };
            try c.flushBuffered(W, writer, converter, encoder);
            const out = converter.filterFrame(frame.view(), @intCast(frame.frameCount())) catch |err| return switch (err) {
                // `init` checked the layouts, and the frame fits the buffers.
                error.UnsupportedLayout => unreachable,
                else => |e| e,
            };
            if (out) |o| try c.encodeResampled(W, writer, encoder, o);
        }
        try c.flushBuffered(W, writer, converter, encoder);
        while (try converter.flushFrame(true)) |out| try c.encodeResampled(W, writer, encoder, out);
    }

    /// aresample's `more_data`: calls without input while the last one
    /// filled its room.
    fn flushBuffered(c: *Conversion, comptime W: type, writer: *W, converter: *swr.Swr, encoder: *pcm.Encoder) RunError!void {
        while (converter.more) {
            const out = try converter.flushFrame(false) orelse break;
            try c.encodeResampled(W, writer, encoder, out);
        }
        converter.more = false;
    }

    /// One resampler output, encoded and written; the first sets a FLAC
    /// output's block size.
    fn encodeResampled(c: *Conversion, comptime W: type, writer: *W, encoder: *pcm.Encoder, out: samples_storage.View) RunError!void {
        if (W == flacmux.Writer and writer.encoder == null and writer.first_frame == null) writer.setFirstFrame(out.layout.samples);
        if (W == aug72x.Writer and writer.pending.len == 0) writer.setFirstFrame(out.layout.samples) catch |err| return outputFailure(err);
        try c.encodeOut(W, writer, encoder, out, c.summary.outputFormat().bytesPerFrame());
    }

    fn encodeOut(c: *Conversion, comptime W: type, writer: *W, encoder: *pcm.Encoder, out: samples_storage.View, frame_bytes: u32) RunError!void {
        const frames = out.layout.samples;
        const frame: Frame = .{ .format = c.summary.outputFormat(), .data = out.bytes[0 .. frames * frame_bytes], .pts = @intCast(c.output_frames) };
        const sent = encoder.send(frame) catch unreachable;
        std.debug.assert(sent == .accepted);
        c.output_frames += frames;
        try writeAllEncoded(W, writer, encoder);
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
/// The FLAC encoder's input for `input`: of its formats, s16 and s32, the
/// one libavfilter's `get_fmt_score` puts closest to the decoded samples,
/// s16 on a tie (u8 and s16 give s16; s32, float, double and s64 give s32).
fn flacStorage(input: audio.SampleFormat) pcm.Codec {
    const score = struct {
        fn of(dst_bytes: i32, input_format: audio.SampleFormat) i32 {
            const src_bytes: i32 = input_format.bytesPerSample();
            var total: i32 = @intFromBool(input_format.isPlanar());
            if (dst_bytes < src_bytes) total += 100 * (src_bytes - dst_bytes) else total += 10 * (dst_bytes - src_bytes);
            // An s32 output for float input.
            if (dst_bytes == 4 and input_format.packedForm() == .flt) total += 20;
            return total;
        }
    }.of;
    return if (score(2, input) <= score(4, input)) .s16le else .s32le;
}

/// copy_meta into a re-encoded stream: `input`'s tags after `out`'s, a key
/// `out` has kept (dictionaries match keys without regard to case), the
/// keys the program drops on re-encoding (`stale_keys`) left out.
fn carryStreamTags(gpa: std.mem.Allocator, out: *metadata.Dictionary, input: *const metadata.Dictionary) error{OutOfMemory}!void {
    for (input.items()) |entry| {
        const dropped = for (stale_keys) |stale| {
            if (stale.matches(entry.key)) break true;
        } else false;
        if (dropped or out.get(entry.key) != null) continue;
        out.put(gpa, entry.key, entry.value, .replace) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidTag => unreachable, // from a dictionary
        };
    }
}

/// The stream a parser's header describes: a PCM codec, or the codec a
/// decoded reader decodes.
/// Whether the input's decoder replaces the layout the ffmpeg program
/// guessed for the demuxed stream (`ff_opus_parse_extradata`,
/// `vorbis_parse_id_hdr`).
fn decoderSetsLayout(stream: codecs.Codec) bool {
    return switch (stream) {
        // The AAC decoder's layout is the stream's after the read-ahead.
        .opus, .vorbis, .aac, .ac3, .eac3 => true,
        else => false,
    };
}

/// The input's seeker moved back to the start, where a seekable demuxer
/// opens (probing read ahead of it), as `detect`'s probes rewind; null for
/// an input that cannot seek, which the demuxer reads after detection's
/// replay instead.
fn rewound(source: *detect.Input) error{IoFailure}!?seek.Seeker {
    const sk = source.source.seeker orelse return null;
    try sk.seekTo(0);
    return sk;
}

fn streamOf(info: anytype) codecs.Codec {
    if (@TypeOf(info) == flac.DecodedReader.Header) return .flac;
    if (@TypeOf(info) == decoded_input.Header) return info.stream;
    return .{ .pcm = info.codec };
}

/// The bits per sample of the decoded source, the ffmpeg program's
/// `bits_per_raw_sample` for the FLAC encoder, which encodes 32 bits for
/// more than 24 under `strict_experimental`: the PCM codec's bits, or the
/// FLAC input's.
fn sourceBits(summary: Summary, input: *const Conversion.Parser) u8 {
    return switch (input.*) {
        .flac => |*reader| reader.bps,
        .ogg => |*reader| reader.bits,
        .mp3, .aac, .ac3 => 32,
        // The decoder's bits_per_raw_sample: the cookie's sample size.
        .alac => |*reader| reader.decoder.config.sample_size,
        else => summary.input_codec.bytesPerSample() * 8,
    };
}

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
        .flac => unreachable, // Conversion.init takes STREAMINFO's block size
        .ogg => unreachable, // Conversion.init takes the decoder's frames
        .mp3 => unreachable, // Conversion.init takes the decoder's frames
        .mp2, .adts => unreachable, // no demuxer
        .aac, .ac3 => unreachable, // Conversion.init takes the decoder's frames
        .mov => unreachable, // Conversion.init refuses it
    };
}

fn writeAllEncoded(comptime W: type, writer: *W, encoder: *pcm.Encoder) RunError!void {
    while (true) switch (encoder.receive()) {
        .output => |p| writer.writeData(p.data) catch |err| return outputFailure(err),
        .need_input, .drained => return,
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
        fn push(t: *Self, packet: ?Packet) RunError!void {
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

        fn writeEncoded(t: *Self) RunError!void {
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

    /// Whether `key` is this one, in exact case (`AV_DICT_MATCH_CASE`).
    fn matches(stale: StaleKey, key: []const u8) bool {
        return if (stale.prefix) std.mem.startsWith(u8, key, stale.key) else std.mem.eql(u8, key, stale.key);
    }
};

/// `reenc_delete_keys`, in its order: exact-case matches. The file's tags
/// (`carriedTags`) and a re-encoded stream's (`carryStreamTags`) both lose
/// them.
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
            if (stale.matches(entry.key)) break entry.key;
        } else null) |key| {
            _ = out.remove(gpa, key);
        }
    }
    // libavformat's init_muxer under `-fflags +bitexact`, which zffmpeg's
    // output always follows: no `encoder` tag, nor any `encoder-...` one.
    _ = out.remove(gpa, "encoder");
    while (for (out.items()) |entry| {
        if (std.ascii.startsWithIgnoreCase(entry.key, "encoder-")) break entry.key;
    } else null) |key| {
        _ = out.remove(gpa, key);
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

/// Every error a writer's `begin`, `writeData` or `finish` returns. A new
/// one fails to compile in `outputFailure`'s switch until it is classified.
const WriterError = wav.RewriteError || au.RewriteError || aiff.RewriteError || raw.WriteError || flacmux.WriteError || mp2mux.WriteError || wavadpcm.RewriteError || cafmux.WriteError || aug72x.RewriteError || ac3mux.WriteError || ac3mux.HeaderError || aacadts.WriteError;

/// A writer's failure once output started: the output's, or FLAC's that
/// only its first frame reveals (T26c: the encoder refusing the block size
/// it gives, an allocation, the seek back for STREAMINFO, an Ogg comment
/// packet past 2 GiB).
fn outputFailure(err: WriterError) RunError {
    return switch (err) {
        error.WriteFailed => error.WriteFailed,
        // FLAC's seek back to rewrite STREAMINFO: the output failed too.
        error.IoFailure => error.WriteFailed,
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedFormat => error.UnsupportedFormat,
        // As `init` reports it for FLAC's container.
        error.TagsTooLong => error.LimitExceeded,
        // `init` ran the header checks `begin` repeats, with the same
        // arguments, and the FLAC and MP2 encoders' option checks, which do
        // not depend on the samples.
        error.InvalidFormat, error.LimitExceeded, error.InvalidOption => unreachable,
        // A deferred header (`Request.output_seekable`) learns the sizes at
        // the end: more data than the container's sizes hold (AU's data
        // limit, AIFF's 32-bit count, RIFF without RF64). A header written
        // first was checked by `init`.
        error.SizeOverflow, error.TooManyFrames => error.LimitExceeded,
        // The parser delivers whole frames of the same format, exactly the
        // count `init` declared (`resample.outputFrames` for a rate change),
        // before `finish`; a deferred header declares none.
        error.IncompleteFrame, error.TooFewFrames => unreachable,
        // FFmpeg's ADPCM encoder crashes there (notes.md "ADPCM").
        error.TrellisOverflow => error.UnsupportedFormat,
        // ALAC into CAF run without the seeker `init` was promised.
        error.UnsupportedStreamingSize => error.UnsupportedStreamingSize,
        // The AC-3 encoder's search, which depends on the samples.
        error.BitAllocationFailed => error.InvalidOption,
        // The AAC encoder's refusal of NaN or infinite samples, and an
        // ADTS frame too large (T32d).
        error.InvalidSamples => error.InvalidSamples,
        error.FrameTooLarge => error.FrameTooLarge,
    };
}

/// What a CAF output's data holds (T31b): ALAC, or the PCM codec.
fn cafCoding(stream: codecs.Codec, codec: pcm.Codec, options: alac.EncodeOptions) cafmux.Coding {
    return if (stream == .alac) .{ .alac = options } else .{ .pcm = codec };
}

/// The ADPCM encoder a stream codec names (T31a), if any.
fn adpcmOutput(stream: codecs.Codec) ?adpcm.Codec {
    return switch (stream) {
        .adpcm_ima_wav => .ima_wav,
        .adpcm_ms => .ms,
        else => null,
    };
}

/// The G.722 or G.726 encoder for an AU output (T31c).
fn g72xOutput(stream: codecs.Codec) ?au.G72x.Codec {
    return switch (stream) {
        .adpcm_g722 => .g722,
        .adpcm_g726le => .g726le,
        else => null,
    };
}

/// Converts one stream: `Conversion.init`, then `run`.
/// Probing past its first 2048 bytes (FFmpeg's retries) allocates from
/// `request.input.gpa`, or else from `request.gpa`, as zffmpeg's does.
pub fn convert(reader: *std.Io.Reader, out: *std.Io.Writer, request: Request, limits: Limits) Error!Summary {
    var input = request.input;
    if (input.gpa == null) input.gpa = request.gpa;
    var source: detect.Input = undefined;
    try source.open(reader, input);
    defer source.deinit();

    var conversion: Conversion = try .init(&source, request, limits);
    defer conversion.deinit();
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
        .flac, .ogg, .mp3, .mp2, .aac, .adts, .ac3, .mov => unreachable, // not this test's outputs
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
        .flac, .ogg, .mp3, .mp2, .aac, .adts, .ac3, .mov => unreachable, // not this test's outputs
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
    const gpa = std.testing.allocator;
    var probe_reader: std.Io.Reader = .fixed(bytes);
    const want = if (detect.probeWith(&probe_reader, .{}, .{ .gpa = gpa })) |_| return error.TestExpectedError else |e| e;
    for ([_]Mode{ .transcode, .copy }) |mode| {
        var reader: std.Io.Reader = .fixed(bytes);
        var buffer: [1024]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        try std.testing.expectError(want, convert(&reader, &out, .{ .output = output, .mode = mode, .gpa = gpa }, .{}));
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
        .{ "major_brand", "M" },   .{ "album", "A" },     .{ "ENCODER", "Lavf56.25.101" },
        .{ "encoder-eng", "x" },
    };
    for (pairs) |pair| try input.put(gpa, pair[0], pair[1], .keep);

    // Copy keeps the encoding provenance; the source-file keys always go,
    // and the encoder ones as FFmpeg's bitexact muxer drops them. Removing
    // creation_time moves the last tag into its place, as av_dict_set does;
    // major_brand likewise.
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

test "the guessed layout is reported as FFmpeg's command line logs it" {
    var recorder: diagnostics.Recorder = .{};
    var buffer: [512]u8 = undefined;
    var reader: std.Io.Reader = .fixed(fixtures.bytes("fmt_channels6"));
    var out: std.Io.Writer = .fixed(&buffer);
    _ = try convert(&reader, &out, .{ .output = .wav, .mode = .transcode, .diagnostics = recorder.sink(.warning) }, .{});
    try std.testing.expectEqual(1, recorder.count);
    try std.testing.expectEqualStrings("Guessed Channel Layout: 5.1", recorder.lastMessage());
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

test "a requested output rate resamples, and only when transcoding with an allocator" {
    const gpa = std.testing.allocator;
    // 300 frames of a 44.1 kHz s16 tone, as a plain WAV.
    var bytes: [44 + 600]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .little);
    @memcpy(bytes[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little);
    std.mem.writeInt(u16, bytes[20..22], 1, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u32, bytes[24..28], 44100, .little);
    std.mem.writeInt(u32, bytes[28..32], 88200, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little);
    std.mem.writeInt(u16, bytes[34..36], 16, .little);
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], 600, .little);
    for (0..300) |i| {
        const t: f64 = @floatFromInt(i);
        const v: i16 = @intFromFloat(@round(@sin(t / 7) * 12000));
        std.mem.writeInt(i16, bytes[44 + 2 * i ..][0..2], v, .little);
    }
    const out_buffer = try gpa.alloc(u8, 4096);
    defer gpa.free(out_buffer);
    var reader: std.Io.Reader = .fixed(&bytes);
    var out: std.Io.Writer = .fixed(out_buffer);
    const summary = try convert(&reader, &out, .{ .output = .wav, .mode = .transcode, .sample_rate = 48000, .gpa = gpa }, .{});
    const want = try resample.outputFrames(300, 44100, 48000, .{});
    try std.testing.expectEqual(want, summary.output_frame_count.?);
    try std.testing.expectEqual(48000, summary.outputFormat().sample_rate);
    try std.testing.expectEqual(44 + want * 2, out.buffered().len);

    // No allocator, or copy, cannot change the rate.
    var no_gpa: std.Io.Reader = .fixed(&bytes);
    var out2: std.Io.Writer = .fixed(out_buffer);
    try std.testing.expectError(error.UnsupportedOperation, convert(&no_gpa, &out2, .{ .output = .wav, .mode = .transcode, .sample_rate = 48000 }, .{}));
    var copy: std.Io.Reader = .fixed(&bytes);
    var out3: std.Io.Writer = .fixed(out_buffer);
    try std.testing.expectError(error.UnsupportedOperation, convert(&copy, &out3, .{ .output = .wav, .mode = .copy, .sample_rate = 48000, .gpa = gpa }, .{}));
    try std.testing.expectEqual(0, out3.buffered().len);
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
            // FLAC input needs an allocator, which these requests lack.
            const supported = if (info.codec.pcmCodec()) |codec| switch (request.mode) {
                .copy => request.output.carries(codec),
                .transcode => true,
            } else false;
            if (!supported) {
                try std.testing.expectError(error.UnsupportedOperation, result);
            } else {
                const summary = try result;
                // The command line's layout guess names an unspecified
                // layout (T23b); the probe reports the stream as stored.
                var expected = info.format;
                if (request.guess_layout) expected.layout = audio.guessLayout(expected.layout);
                try std.testing.expectEqual(expected, summary.format);
                try std.testing.expectEqual(info.frame_count, summary.frame_count);
            }
        } else |_| {
            if (result) |_| return error.TestExpectedError else |_| {}
        }
    }
}

test "fuzz: conversion agrees with probing on arbitrary input" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        hostile.fuzzSeed(fixtures.bytes("mono_8k"), &.{}),
        hostile.fuzzSeed(fixtures.bytes("unknown_chunks"), &.{}),
        hostile.fuzzSeed(fixtures.au.bytes("au_stereo_44k1"), &.{}),
        hostile.fuzzSeed(fixtures.au.bytes("au_truncated_data"), &.{}),
        hostile.fuzzSeed(fixtures.bytes("s24_stereo_48k_extensible"), &.{}),
        hostile.fuzzSeed(fixtures.bytes("alaw_mono_8k"), &.{}),
        hostile.fuzzSeed(fixtures.aiff.bytes("aifc_sowt"), &.{}),
        hostile.fuzzSeed(fixtures.aiff.bytes("aiff_odd_data"), &.{}),
    } });
}

test "every accepted FLAC fixture converts to the samples it encodes" {
    const gpa = std.testing.allocator;
    inline for (fixtures.flac.all) |fixture| {
        if (fixture.expected == .accept) {
            const stream = fixture.expected.accept;
            var reader: std.Io.Reader = .fixed(fixtures.flac.bytes(fixture.name));
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            // FFmpeg's decoded storage, kept exactly.
            const output: Container = if (stream.bps > 16) .s32le else .s16le;
            const summary = try convert(&reader, &out.writer, .{ .output = output, .mode = .transcode, .gpa = gpa }, .{});
            try std.testing.expectEqual(Container.flac, summary.input);
            try std.testing.expect(summary.input_stream == .flac);
            try std.testing.expectEqual(stream.frames, summary.frame_count);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
            try std.testing.expectEqualStrings(stream.pcm_sha256, &std.fmt.bytesToHex(digest, .lower));
            // A header holding STREAMINFO's count is written first (port.md
            // "FLAC contract"); raw PCM has none.
            var header_reader: std.Io.Reader = .fixed(fixtures.flac.bytes(fixture.name));
            const declared = (try flac.readHeader(&header_reader)).duration;
            if (declared != null and declared.? != stream.frames) {
                reader = .fixed(fixtures.flac.bytes(fixture.name));
                out.clearRetainingCapacity();
                try std.testing.expectError(error.FrameCountMismatch, convert(&reader, &out.writer, .{ .output = .wav, .mode = .transcode, .gpa = gpa }, .{}));
            }
        }
    }
}

test "convert frees a probe buffer grown past its first 2048 bytes" {
    // A headerless stream scores 13, so probing reads a second round into
    // an allocated buffer, which the testing allocator checks is freed.
    const gpa = std.testing.allocator;
    const bytes = fixtures.flac.bytes("flac_headerless_mid_side");
    try std.testing.expect(bytes.len > detect.probe_len);
    const sources = [_]detect.Source{ .{}, .{ .gpa = gpa } };
    for (sources) |input| {
        var reader: std.Io.Reader = .fixed(bytes);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const summary = try convert(&reader, &out.writer, .{ .output = .s16le, .mode = .transcode, .input = input, .gpa = gpa }, .{});
        try std.testing.expectEqual(Container.flac, summary.input);
        try std.testing.expectEqual(1152, summary.frame_count);
        try std.testing.expectEqual(1152 * 2 * 2, out.written().len);
    }
    // Without any allocator the second round cannot be read.
    var reader: std.Io.Reader = .fixed(bytes);
    var sink: std.Io.Writer = .failing;
    try std.testing.expectError(error.OutOfMemory, convert(&reader, &sink, .{ .output = .s16le, .mode = .transcode }, .{}));
}

test "FLAC input: no copy, an allocator needed, the frame count checked" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const bytes = fixtures.flac.bytes("flac_mid_side");
    var reader: std.Io.Reader = .fixed(bytes);
    try std.testing.expectError(error.UnsupportedOperation, convert(&reader, &out.writer, .{ .output = .wav, .mode = .copy, .gpa = gpa }, .{}));
    reader = .fixed(bytes);
    try std.testing.expectError(error.UnsupportedOperation, convert(&reader, &out.writer, .{ .output = .wav, .mode = .transcode }, .{}));
    // A frame FFmpeg's parser drops leaves the output short of STREAMINFO's
    // count, which the header holds.
    reader = .fixed(fixtures.flac.bytes("flac_junk_between_frames"));
    var recorder: diagnostics.Recorder = .{};
    try std.testing.expectError(error.FrameCountMismatch, convert(&reader, &out.writer, .{
        .output = .wav,
        .mode = .transcode,
        .gpa = gpa,
        .diagnostics = recorder.sink(.warning),
    }, .{}));
    try std.testing.expectEqualStrings("Decoding error: Invalid data found when processing input", recorder.lastMessage());
    // Raw PCM has no header to hold the count: the stream converts, and the
    // summary has the decoded count.
    var header_reader: std.Io.Reader = .fixed(fixtures.flac.bytes("flac_junk_between_frames"));
    const declared = (try flac.readHeader(&header_reader)).duration.?;
    reader = .fixed(fixtures.flac.bytes("flac_junk_between_frames"));
    out.clearRetainingCapacity();
    const summary = try convert(&reader, &out.writer, .{ .output = .s16le, .mode = .transcode, .gpa = gpa }, .{});
    try std.testing.expect(summary.frame_count.? < declared);
    try std.testing.expectEqual(summary.frame_count, summary.output_frame_count);
    try std.testing.expectEqual(summary.frame_count.? * 2 * summary.format.channelCount(), out.written().len);
}

test "FLAC to a WAV header, rematrixed and resampled" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var reader: std.Io.Reader = .fixed(fixtures.flac.bytes("flac_six_channels_48k"));
    const summary = try convert(&reader, &out.writer, .{
        .output = .wav,
        .mode = .transcode,
        .layout = .stereo,
        .sample_rate = 44100,
        .gpa = gpa,
    }, .{});
    try std.testing.expectEqual(44100, summary.output_rate);
    try std.testing.expect(summary.output_layout.eql(&.stereo));
}

test "FLAC input fails cleanly under every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var reader: std.Io.Reader = .fixed(fixtures.flac.bytes("flac_verbatim_stereo_44k1"));
            var buffer: [4096]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            _ = try convert(&reader, &out, .{ .output = .s16le, .mode = .transcode, .gpa = gpa }, .{});
        }
    }.run, .{});
}

/// A WAV of `frames` stereo s16 frames at `rate`, a smooth signal the FLAC
/// encoder predicts.
fn testWav(gpa: std.mem.Allocator, frames: u32, rate: u32) ![]u8 {
    const format = try audio.Format.init(rate, 2, .s16);
    const bytes = try gpa.alloc(u8, wav.canonical_header_len + @as(usize, frames) * 4);
    errdefer gpa.free(bytes);
    var out: std.Io.Writer = .fixed(bytes);
    var writer = try wav.Writer.begin(&out, .s16le, format, frames, .{});
    var sample: [4]u8 = undefined;
    for (0..frames) |i| {
        const x: i32 = @intCast(i % 200);
        std.mem.writeInt(i16, sample[0..2], @intCast(x * 100 - 10000), .little);
        std.mem.writeInt(i16, sample[2..4], @intCast(5000 - x * 50), .little);
        try writer.writeData(&sample);
    }
    try writer.finish();
    return bytes;
}

/// The samples a FLAC stream decodes to, its MD5 checked when asked.
fn decodeFlac(gpa: std.mem.Allocator, bytes: []const u8, verify_md5: bool) ![]u8 {
    var reader: std.Io.Reader = .fixed(bytes);
    var r: flac.DecodedReader = .init(gpa, &reader, null);
    r.verify_md5 = verify_md5;
    defer r.deinit();
    _ = try r.readHeader();
    var decoded: std.ArrayList(u8) = .empty;
    errdefer decoded.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = try r.readData(&chunk);
        if (got.len == 0) break;
        try decoded.appendSlice(gpa, got);
    }
    try r.finish();
    return decoded.toOwnedSlice(gpa);
}

test "FLAC output: FFmpeg's block size, the samples back, STREAMINFO rewritten only on a seekable output" {
    const gpa = std.testing.allocator;
    const input = try testWav(gpa, 5000, 44100);
    defer gpa.free(input);
    const output = try gpa.alloc(u8, 1 << 16);
    defer gpa.free(output);
    for ([_]bool{ true, false }) |seekable| {
        var reader: std.Io.Reader = .fixed(input);
        var source: detect.Input = undefined;
        try source.open(&reader, .{});
        var conversion = try Conversion.init(&source, .{ .output = .flac, .mode = .transcode, .gpa = gpa }, .{});
        defer conversion.deinit();
        try std.testing.expect(conversion.summary.output_stream == .flac);
        try std.testing.expectEqual(pcm.Codec.s16le, conversion.summary.output_codec);
        var out: std.Io.Writer = .fixed(output);
        try conversion.runTo(&out, if (seekable) .fixed(&out) else null);
        try std.testing.expectEqual(5000, conversion.summary.frame_count);
        // The first packet's 4096 frames (a tenth of a second, rounded
        // down to a power of two) are the block size.
        const si = flac_codec.StreamInfo.parse(out.buffered()[8..42]);
        try std.testing.expectEqual(4096, si.max_blocksize);
        try std.testing.expectEqual(if (seekable) @as(u64, 5000) else 0, si.samples);
        const decoded = try decodeFlac(gpa, out.buffered(), seekable);
        defer gpa.free(decoded);
        try std.testing.expectEqualSlices(u8, input[wav.canonical_header_len..], decoded);
    }
}

test "MP2 output: the encoder's packets, the same on a seekable output, refusals before any output" {
    const gpa = std.testing.allocator;
    const input = try testWav(gpa, 5000, 44100);
    defer gpa.free(input);
    // The encoder's packets for the same samples, five frames, the last
    // padded.
    var e = try mp2enc.Encoder.init(44100, 2, .{ .bit_rate = 192000, .fixed = true });
    var want: [5 * mp2enc.max_packet]u8 = undefined;
    var want_len: usize = 0;
    var start: usize = 0;
    while (start < 5000) : (start += mp2enc.frame_samples) {
        const n: usize = @min(5000 - start, mp2enc.frame_samples);
        var samples: [2 * mp2enc.frame_samples]i16 = undefined;
        for (0..2 * n) |i| samples[i] = std.mem.readInt(i16, input[wav.canonical_header_len + 4 * start + 2 * i ..][0..2], .little);
        var packet: [mp2enc.max_packet]u8 = undefined;
        const got = try e.encodeFrame(samples[0 .. 2 * n], &packet);
        @memcpy(want[want_len..][0..got.len], got);
        want_len += got.len;
    }
    var output: [5 * mp2enc.max_packet]u8 = undefined;
    for ([_]bool{ true, false }) |seekable| {
        var reader: std.Io.Reader = .fixed(input);
        var source: detect.Input = undefined;
        try source.open(&reader, .{});
        var conversion = try Conversion.init(&source, .{ .output = .mp2, .mode = .transcode, .mp2 = .{ .bit_rate = 192000, .fixed = true }, .output_seekable = seekable }, .{});
        defer conversion.deinit();
        var out: std.Io.Writer = .fixed(&output);
        try conversion.runTo(&out, if (seekable) .fixed(&out) else null);
        try std.testing.expectEqual(5000, conversion.summary.frame_count);
        try std.testing.expectEqualSlices(u8, want[0..want_len], out.buffered());
    }

    var out: std.Io.Writer = .fixed(&output);
    var bad_rate: std.Io.Reader = .fixed(input);
    try std.testing.expectError(error.InvalidOption, convert(&bad_rate, &out, .{ .output = .mp2, .mode = .transcode, .mp2 = .{ .bit_rate = 100000 } }, .{}));
    var mono: std.Io.Reader = .fixed(fixtures.bytes("mono_8k"));
    try std.testing.expectError(error.UnsupportedFormat, convert(&mono, &out, .{ .output = .mp2, .mode = .transcode }, .{}));
    var copy: std.Io.Reader = .fixed(input);
    try std.testing.expectError(error.UnsupportedOperation, convert(&copy, &out, .{ .output = .mp2, .mode = .copy }, .{}));
    try std.testing.expectEqual(0, out.buffered().len);
}

test "FLAC to FLAC: the first decoded frame is the block size; encoder options apply" {
    const gpa = std.testing.allocator;
    const output = try gpa.alloc(u8, 1 << 17);
    defer gpa.free(output);
    var reader: std.Io.Reader = .fixed(fixtures.flac.bytes("flac_ffmpeg_level5_stereo"));
    var out: std.Io.Writer = .fixed(output);
    _ = try convert(&reader, &out, .{ .output = .flac, .mode = .transcode, .gpa = gpa, .flac = .{ .compression_level = 0 } }, .{});
    const si = flac_codec.StreamInfo.parse(out.buffered()[8..42]);
    try std.testing.expectEqual(1152, si.max_blocksize);
    // Level 0 has no LPC: every subframe is fixed, verbatim or constant.
    var reader2: std.Io.Reader = .fixed(out.buffered());
    var demuxer = try flac.Demuxer.init(gpa, &reader2);
    defer demuxer.deinit();
    var frames: usize = 0;
    while (try demuxer.next()) |_| frames += 1;
    try std.testing.expect(frames > 1);
    // FLAC output needs an allocator; options FFmpeg refuses fail first.
    reader = .fixed(fixtures.flac.bytes("flac_ffmpeg_level5_stereo"));
    try std.testing.expectError(error.UnsupportedOperation, convert(&reader, &out, .{ .output = .flac, .mode = .transcode }, .{}));
    reader = .fixed(fixtures.flac.bytes("flac_ffmpeg_level5_stereo"));
    try std.testing.expectError(error.InvalidOption, convert(&reader, &out, .{ .output = .flac, .mode = .transcode, .gpa = gpa, .flac = .{ .min_prediction_order = 9, .max_prediction_order = 8 } }, .{}));
    reader = .fixed(fixtures.flac.bytes("flac_ffmpeg_level5_stereo"));
    try std.testing.expectError(error.UnsupportedOperation, convert(&reader, &out, .{ .output = .flac, .mode = .copy, .gpa = gpa }, .{}));
}

test "a decoded input resamples frame by frame: FFmpeg's FLAC block size and bytes" {
    // Each decoded frame is one aresample call, as the ffmpeg program's
    // filter graph makes them, so the first call's output, the encoder's
    // block size, follows the decoder's first frame. The block sizes and
    // hashes are the pinned ffmpeg's (`-bitexact -c:a flac -ar R -f flac -`),
    // which cutting the input at the largest frame did not give (6217 and
    // 1072 samples).
    const gpa = std.testing.allocator;
    const cases = [_]struct { input: []const u8, rate: u32, block: u16, sha256: []const u8 }{
        .{ .input = fixtures.flac.bytes("flac_variable_blocksize"), .rate = 48000, .block = 92, .sha256 = "0cd8ae133c87561cfbe077596d8b66b826ea38146abaeb03a6184b47955c04e5" },
        .{ .input = fixtures.ogg.bytes("ogg_opus_ffmpeg_stereo"), .rate = 44100, .block = 756, .sha256 = "b40898b913622db4b3a48665b3419ed9725accad958e64220c8a2c7e84460c0f" },
    };
    for (cases) |case| {
        var reader: std.Io.Reader = .fixed(case.input);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try convert(&reader, &out.writer, .{ .output = .flac, .mode = .transcode, .gpa = gpa, .sample_rate = case.rate }, .{});
        const si = flac_codec.StreamInfo.parse(out.written()[8..42]);
        try std.testing.expectEqual(case.block, si.max_blocksize);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
        try std.testing.expectEqualStrings(case.sha256, &std.fmt.bytesToHex(digest, .lower));
    }
}

test "a decoded input's header is rewritten at the end on a seekable output: decoded once, the same bytes" {
    const gpa = std.testing.allocator;
    const out_buffer = try gpa.alloc(u8, 1 << 19);
    defer gpa.free(out_buffer);
    const inputs = [_][]const u8{ fixtures.mp3.bytes("mp3_l3_long_stereo"), fixtures.ogg.bytes("ogg_vorbis_ffmpeg_22k_short") };
    for (inputs) |bytes| {
        for ([_]Container{ .wav, .au, .aiff }) |output| {
            // Counted ahead from a seekable input, the header written first.
            var counted_reader: std.Io.Reader = .fixed(bytes);
            var counted_source: detect.Input = undefined;
            try counted_source.open(&counted_reader, .{ .seeker = .fixed(&counted_reader), .length = bytes.len, .gpa = gpa });
            defer counted_source.deinit();
            var counted = try Conversion.init(&counted_source, .{ .output = output, .mode = .transcode, .gpa = gpa }, .{});
            defer counted.deinit();
            try std.testing.expect(!counted.deferred_header);
            var counted_out: std.Io.Writer.Allocating = .init(gpa);
            defer counted_out.deinit();
            try counted.run(&counted_out.writer);

            // From a seekable input and from a pipe, decoded once, the
            // header rewritten.
            for ([_]bool{ true, false }) |seekable_input| {
                var reader: std.Io.Reader = .fixed(bytes);
                var source: detect.Input = undefined;
                try source.open(&reader, .{ .seeker = if (seekable_input) .fixed(&reader) else null, .length = if (seekable_input) bytes.len else null, .gpa = gpa });
                defer source.deinit();
                var conversion = try Conversion.init(&source, .{ .output = output, .mode = .transcode, .gpa = gpa, .output_seekable = true }, .{});
                defer conversion.deinit();
                try std.testing.expect(conversion.deferred_header);
                switch (conversion.input) {
                    .ogg => |*r| try std.testing.expect(!r.count_ahead),
                    .mp3 => |*r| try std.testing.expect(!r.count_ahead),
                    else => return error.TestUnexpectedResult,
                }
                var out: std.Io.Writer = .fixed(out_buffer);
                try conversion.runTo(&out, .fixed(&out));
                try std.testing.expectEqualSlices(u8, counted_out.written(), out.buffered());
            }

            // Promised a seekable output, given none: refused before any byte.
            var reader: std.Io.Reader = .fixed(bytes);
            var source: detect.Input = undefined;
            try source.open(&reader, .{ .gpa = gpa });
            defer source.deinit();
            var conversion = try Conversion.init(&source, .{ .output = output, .mode = .transcode, .gpa = gpa, .output_seekable = true }, .{});
            defer conversion.deinit();
            var out: std.Io.Writer = .fixed(out_buffer);
            try std.testing.expectError(error.UnsupportedStreamingSize, conversion.runTo(&out, null));
            try std.testing.expectEqual(0, out.buffered().len);
        }
    }
}

test "a rate change the request refuses fails in init, before any output" {
    const gpa = std.testing.allocator;
    // A WAV under 20 Hz reads packets of one frame, each call's room the
    // ratio plus 32 frames, more by the delay, so the first output, FLAC's
    // block size as the ffmpeg program opens the encoder with it, is one
    // to two times the ratio: from 1 Hz, 16 kHz fits FLAC's 65,535 frames
    // and 48 kHz does not.
    const cases = [_]struct { out_rate: u32, ok: bool }{ .{ .out_rate = 16000, .ok = true }, .{ .out_rate = 48000, .ok = false } };
    for (cases) |case| {
        const input = try testWav(gpa, 40, 1);
        defer gpa.free(input);
        const out_rate = case.out_rate;
        const first = (try swr.Swr.firstOutputFrames(1, out_rate, 1, 40, .{})).?;
        try std.testing.expectEqual(case.ok, first <= flac_codec.max_blocksize);
        for ([_]Container{ .flac, .ogg }) |output| {
            var reader: std.Io.Reader = .fixed(input);
            var source: detect.Input = undefined;
            try source.open(&reader, .{});
            const request: Request = .{ .output = output, .mode = .transcode, .gpa = gpa, .sample_rate = out_rate };
            if (!case.ok) {
                try std.testing.expectError(error.UnsupportedFormat, Conversion.init(&source, request, .{}));
                continue;
            }
            // Accepted, the encoder opens with the predicted block size.
            var conversion = try Conversion.init(&source, request, .{});
            defer conversion.deinit();
            if (output == .ogg) continue;
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try conversion.run(&out.writer);
            const streaminfo = out.written()[8..][0..34];
            try std.testing.expectEqual(first, std.mem.readInt(u16, streaminfo[0..2], .big));
        }
    }
    // A call's room past the resampler's buffers: 1 Hz in calls of one
    // frame to 2^30 Hz (limits raised so that the writer takes the rate).
    const input = try testWav(gpa, 40, 1);
    defer gpa.free(input);
    var reader: std.Io.Reader = .fixed(input);
    var source: detect.Input = undefined;
    try source.open(&reader, .{});
    var limits: Limits = .{};
    limits.raw.max_sample_rate = 1 << 30;
    try std.testing.expectError(error.UnsupportedFormat, Conversion.init(&source, .{ .output = .s16le, .mode = .transcode, .gpa = gpa, .sample_rate = 1 << 30 }, limits));
}

test "FLAC output fails cleanly under every allocation failure" {
    const input = try testWav(std.testing.allocator, 300, 8000);
    defer std.testing.allocator.free(input);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, bytes: []const u8) !void {
            var reader: std.Io.Reader = .fixed(bytes);
            var buffer: [1 << 14]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            _ = try convert(&reader, &out, .{ .output = .flac, .mode = .transcode, .gpa = gpa }, .{});
        }
    }.run, .{input});
}

const hostile = @import("../testing/hostile.zig");
