// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! `av`: the native Zig multimedia library module.
//!
//! This file is the module's public facade. It exports the supported features
//! directly; internal declarations stay in their own files.
//!
//! - `pcm`: signed 16-bit PCM sample conversion (`codec/pcm.zig`).
//! - `audio`: channel layouts, sample formats, stream formats and borrowed
//!   interleaved samples (`core/audio.zig`).
//! - `channel_layout`: FFmpeg's channels and channel layouts (native,
//!   custom, unspecified), their names, parsing and descriptions
//!   (`core/channel_layout.zig`).
//! - `time`: time bases and FFmpeg-compatible timestamp rescaling
//!   (`core/time.zig`).
//! - `rational`: FFmpeg's rational arithmetic and timestamp helpers with its
//!   exact results: reduction, `av_d2q`, `av_rescale_rnd`,
//!   `av_compare_ts`, `av_compare_mod`, `av_rescale_delta`,
//!   `av_add_stable` (`core/rational.zig`).
//! - `samples`: decoded sample storage for every sample format, packed or
//!   planar: buffer sizes, plane offsets, silence and copying
//!   (`core/samples.zig`).
//! - `packet`, `frame`: encoded packets and decoded audio frames, as views
//!   with explicit `clone`d ownership (`core/packet.zig`, `core/frame.zig`).
//! - `stage`: the send/receive contract of buffering stages, which
//!   `pcm.Decoder` and `pcm.Encoder` follow (`core/stage.zig`).
//! - `metadata`: the tag dictionary, ordered with owned storage and FFmpeg's
//!   duplicate-key policies (`core/metadata.zig`).
//! - `eval`: FFmpeg's expression evaluator (`core/eval.zig`).
//! - `bits`: an MSB-first bit reader with FFmpeg's over-read rules, Rice
//!   codes, a bit writer, and the CRC-8 and CRC-16 FLAC uses
//!   (`codec/bits.zig`).
//! - `flacenc`: FFmpeg's FLAC encoder, packet for packet, with its LPC
//!   analysis (`codec/flacenc.zig`, `codec/lpc.zig`).
//! - `flacmux`: FFmpeg's FLAC muxer with the encoder before it, a PCM
//!   writer as the other containers' (`format/flacmux.zig`).
//! - `wav`: bounded RIFF/WAVE, RF64/BW64 and Sony Wave64 parsing and
//!   known-length writing for the WAV PCM encodings (`format/wav.zig`).
//! - `au`: bounded Sun AU parsing and known-length writing for s16 big-endian
//!   PCM (`format/au.zig`).
//! - `aiff`: bounded AIFF and AIFF-C parsing and known-length writing for
//!   their PCM encodings (`format/aiff.zig`).
//! - `raw`: raw PCM reading with given stream parameters and writing, as
//!   FFmpeg's raw demuxers and muxers (`format/raw.zig`).
//! - `caf`: bounded Apple CAF reading for linear PCM, A-law and µ-law
//!   (`format/caf.zig`).
//! - `flac`: native FLAC with 16-bit samples, read as FFmpeg's demuxer,
//!   parser and decoder read it: packets with libavformat's timestamps and
//!   their decoding to s16 (`format/flac.zig`, `codec/flac.zig`,
//!   `codec/flac_parser.zig`, `codec/flacdec.zig`).
//! - `ogg`: FFmpeg's Ogg demuxer with the FLAC, Opus and Vorbis mappings,
//!   without decoding (`format/ogg.zig`, `format/vorbiscomment.zig`).
//! - `demux`: libavformat's generic layer over a demuxer: timestamps, the
//!   stream-info read-ahead, timings and seeking; Ogg reads through it
//!   (`format/demux.zig`).
//! - `tx`: FFmpeg's float FFT and MDCT for power-of-two lengths, bit for
//!   bit its C codelets (`codec/tx.zig`).
//! - `vlc`: FFmpeg's VLC decoding tables and lookup, for the LSB-first
//!   reader in `bits` (`codec/vlc.zig`).
//! - `vorbis`: FFmpeg's Vorbis decoder, bit for bit (`codec/vorbis.zig`).
//! - `opusdec`: FFmpeg's Opus decoder, CELT, SILK and hybrid frames and
//!   multistream packets, bit for bit (`codec/opusdec.zig`, with
//!   `codec/celt.zig` and `codec/silk.zig`).
//! - `oggdecode`: an Ogg stream decoded as the ffmpeg program decodes it
//!   (`format/oggdecode.zig`).
//! - `framehash`: FFmpeg's framecrc, framemd5 and streamhash muxers' text
//!   for one audio stream (`format/framehash.zig`).
//! - `seek`: the seek API, FFmpeg's `av_seek_frame` and
//!   `avformat_seek_file` with a seekable source, and the binary search
//!   and index they share; WAV, Wave64, FLAC and Ogg implement it
//!   (`format/seek.zig`, `wav.Parser.seekFrame`, `flac.Demuxer.seekFrame`,
//!   `demux.Layer.seekFrame`).
//! - `audioconvert`: sample format conversion between every format, packed
//!   or planar, as libswresample converts (`resample/audioconvert.zig`).
//! - `dither`: libswresample's dithered conversion, every method, noise
//!   shaping included (`resample/dither.zig`).
//! - `codecs`: codec descriptors and the decoder and encoder registries, as
//!   FFmpeg names them (`codec/registry.zig`).
//! - `formats`: the format registry, with each container's demuxer probe and
//!   muxer extensions and codecs, as FFmpeg names them (`format/registry.zig`).
//! - `detect`: content detection with FFmpeg's winner, or a forced format,
//!   replaying the bytes it read to the chosen parser (`format/detect.zig`,
//!   `format/replay.zig`).
//! - `convert`: synchronous WAV/Wave64/AU/AIFF conversion and stream copy, with
//!   every check made before output starts (`format/convert.zig`).
//! - `filter`: the audio filter graph: a linear chain of anull, aformat,
//!   volume and aresample between a buffer source and sink, negotiated and
//!   run as FFmpeg's libavfilter does, built from filtergraph text too
//!   (`filter/graph.zig`, with `filter/filters.zig`, `filter/formats.zig`
//!   and `filter/parse.zig`).
//! - `file`: file and stream adapters for the WAV and AU paths, with
//!   borrowed-handle and path variants (`io/file.zig`).
//!
//! Zig analyzes files lazily, so tests run only in files this module imports.
//! When a file with tests is added, reference it from the `test` block here.

pub const pcm = @import("codec/pcm.zig");
pub const audio = @import("core/audio.zig");
pub const channel_layout = @import("core/channel_layout.zig");
pub const time = @import("core/time.zig");
pub const rational = @import("core/rational.zig");
pub const samples = @import("core/samples.zig");
pub const packet = @import("core/packet.zig");
pub const frame = @import("core/frame.zig");
pub const stage = @import("core/stage.zig");
pub const metadata = @import("core/metadata.zig");
pub const number = @import("core/number.zig");
pub const options = @import("core/options.zig");
pub const diagnostics = @import("core/diagnostics.zig");
pub const eval = @import("core/eval.zig");
pub const bits = @import("codec/bits.zig");
pub const wav = @import("format/wav.zig");
pub const au = @import("format/au.zig");
pub const aiff = @import("format/aiff.zig");
pub const raw = @import("format/raw.zig");
pub const caf = @import("format/caf.zig");
pub const flac = @import("format/flac.zig");
pub const flacenc = @import("codec/flacenc.zig");
pub const flacmux = @import("format/flacmux.zig");
pub const ogg = @import("format/ogg.zig");
pub const demux = @import("format/demux.zig");
pub const oggmux = @import("format/oggmux.zig");
pub const tx = @import("codec/tx.zig");
pub const vlc = @import("codec/vlc.zig");
pub const vorbis = @import("codec/vorbis.zig");
pub const opusdec = @import("codec/opusdec.zig");
pub const oggdecode = @import("format/oggdecode.zig");
pub const framehash = @import("format/framehash.zig");
pub const seek = @import("format/seek.zig");
pub const audioconvert = @import("resample/audioconvert.zig");
pub const dither = @import("resample/dither.zig");
pub const codecs = @import("codec/registry.zig");
pub const formats = @import("format/registry.zig");
pub const detect = @import("format/detect.zig");
pub const convert = @import("format/convert.zig");
pub const filter = @import("filter/graph.zig");
pub const file = @import("io/file.zig");

test {
    _ = @import("codec/pcm.zig");
    _ = @import("codec/g711.zig");
    _ = @import("codec/registry.zig");
    _ = @import("codec/bits.zig");
    _ = @import("codec/flac.zig");
    _ = @import("codec/flac_parser.zig");
    _ = @import("codec/flacdec.zig");
    _ = @import("codec/flacenc.zig");
    _ = @import("codec/lpc.zig");
    _ = @import("core/audio.zig");
    _ = @import("core/channel_layout.zig");
    _ = @import("core/time.zig");
    _ = @import("core/samples.zig");
    _ = @import("core/packet.zig");
    _ = @import("core/frame.zig");
    _ = @import("core/stage.zig");
    _ = @import("core/metadata.zig");
    _ = @import("core/number.zig");
    _ = @import("core/options.zig");
    _ = @import("core/diagnostics.zig");
    _ = @import("core/eval.zig");
    _ = @import("core/rational.zig");
    _ = @import("format/wav.zig");
    _ = @import("format/au.zig");
    _ = @import("format/aiff.zig");
    _ = @import("format/raw.zig");
    _ = @import("format/caf.zig");
    _ = @import("format/flac.zig");
    _ = @import("format/flacmux.zig");
    _ = @import("format/vorbiscomment.zig");
    _ = @import("format/ogg.zig");
    _ = @import("format/avlanguage.zig");
    _ = @import("format/id3v1.zig");
    _ = @import("format/id3v2.zig");
    _ = @import("codec/mpegaudio.zig");
    _ = @import("format/demux.zig");
    _ = @import("format/oggmux.zig");
    _ = @import("format/oggdecode.zig");
    _ = @import("codec/tx.zig");
    _ = @import("codec/vlc.zig");
    _ = @import("codec/xiph.zig");
    _ = @import("codec/vorbis.zig");
    _ = @import("codec/opus_rc.zig");
    _ = @import("codec/opus.zig");
    _ = @import("core/libm.zig");
    _ = @import("codec/float_dsp.zig");
    _ = @import("codec/celt.zig");
    _ = @import("codec/opusdec.zig");
    _ = @import("codec/silk.zig");
    _ = @import("format/framehash.zig");
    _ = @import("format/seek.zig");
    _ = @import("format/mov_chan.zig");
    _ = @import("resample/audioconvert.zig");
    _ = @import("resample/dither.zig");
    _ = @import("resample/rematrix.zig");
    _ = @import("resample/resample.zig");
    _ = @import("resample/swr.zig");
    _ = @import("filter/formats.zig");
    _ = @import("filter/filters.zig");
    _ = @import("filter/parse.zig");
    _ = @import("filter/negotiate.zig");
    _ = @import("filter/multi.zig");
    _ = @import("filter/graph.zig");
    _ = @import("format/registry.zig");
    _ = @import("format/detect.zig");
    _ = @import("format/replay.zig");
    _ = @import("format/convert.zig");
    _ = @import("io/file.zig");
    // Test-only files: the WAV and AU fixture contracts and their integrity
    // checks, and the controlled buffering stage for the stage contract.
    _ = @import("testing/fixtures.zig");
    _ = @import("testing/delay_stage.zig");
    _ = @import("testing/synthetic.zig");
}
