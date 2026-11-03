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
//! - `time`: time bases and FFmpeg-compatible timestamp rescaling
//!   (`core/time.zig`).
//! - `samples`: decoded sample storage for every sample format, packed or
//!   planar: buffer sizes, plane offsets, silence and copying
//!   (`core/samples.zig`).
//! - `packet`, `frame`: encoded packets and decoded audio frames, as views
//!   with explicit `clone`d ownership (`core/packet.zig`, `core/frame.zig`).
//! - `stage`: the send/receive contract of buffering stages, which
//!   `pcm.Decoder` and `pcm.Encoder` follow (`core/stage.zig`).
//! - `metadata`: the tag dictionary, ordered with owned storage and FFmpeg's
//!   duplicate-key policies (`core/metadata.zig`).
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
//! - `codecs`: codec descriptors and the decoder and encoder registries, as
//!   FFmpeg names them (`codec/registry.zig`).
//! - `formats`: the format registry, with each container's demuxer probe and
//!   muxer extensions and codecs, as FFmpeg names them (`format/registry.zig`).
//! - `detect`: content detection with FFmpeg's winner, or a forced format,
//!   replaying the bytes it read to the chosen parser (`format/detect.zig`,
//!   `format/replay.zig`).
//! - `convert`: synchronous WAV/Wave64/AU/AIFF conversion and stream copy, with
//!   every check made before output starts (`format/convert.zig`).
//! - `file`: file and stream adapters for the WAV and AU paths, with
//!   borrowed-handle and path variants (`io/file.zig`).
//!
//! Zig analyzes files lazily, so tests run only in files this module imports.
//! When a file with tests is added, reference it from the `test` block here.

pub const pcm = @import("codec/pcm.zig");
pub const audio = @import("core/audio.zig");
pub const time = @import("core/time.zig");
pub const samples = @import("core/samples.zig");
pub const packet = @import("core/packet.zig");
pub const frame = @import("core/frame.zig");
pub const stage = @import("core/stage.zig");
pub const metadata = @import("core/metadata.zig");
pub const wav = @import("format/wav.zig");
pub const au = @import("format/au.zig");
pub const aiff = @import("format/aiff.zig");
pub const raw = @import("format/raw.zig");
pub const caf = @import("format/caf.zig");
pub const codecs = @import("codec/registry.zig");
pub const formats = @import("format/registry.zig");
pub const detect = @import("format/detect.zig");
pub const convert = @import("format/convert.zig");
pub const file = @import("io/file.zig");

test {
    _ = @import("codec/pcm.zig");
    _ = @import("codec/g711.zig");
    _ = @import("codec/registry.zig");
    _ = @import("core/audio.zig");
    _ = @import("core/time.zig");
    _ = @import("core/samples.zig");
    _ = @import("core/packet.zig");
    _ = @import("core/frame.zig");
    _ = @import("core/stage.zig");
    _ = @import("core/metadata.zig");
    _ = @import("format/wav.zig");
    _ = @import("format/au.zig");
    _ = @import("format/aiff.zig");
    _ = @import("format/raw.zig");
    _ = @import("format/caf.zig");
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
