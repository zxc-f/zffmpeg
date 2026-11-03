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
//! - `wav`: bounded RIFF/WAVE parsing and known-length writing for s16 PCM
//!   (`format/wav.zig`).
//! - `au`: bounded Sun AU parsing and known-length writing for s16 big-endian
//!   PCM (`format/au.zig`).
//! - `detect`: WAV or AU content detection that hands the bytes it read to the
//!   chosen parser (`format/detect.zig`).
//! - `file`: file and stream adapters for the WAV and AU paths, with
//!   borrowed-handle and path variants (`io/file.zig`).
//!
//! Zig analyzes files lazily, so tests run only in files this module imports.
//! When a file with tests is added, reference it from the `test` block here.

pub const pcm = @import("codec/pcm.zig");
pub const audio = @import("core/audio.zig");
pub const time = @import("core/time.zig");
pub const wav = @import("format/wav.zig");
pub const au = @import("format/au.zig");
pub const detect = @import("format/detect.zig");
pub const file = @import("io/file.zig");

test {
    _ = @import("codec/pcm.zig");
    _ = @import("core/audio.zig");
    _ = @import("core/time.zig");
    _ = @import("format/wav.zig");
    _ = @import("format/au.zig");
    _ = @import("format/detect.zig");
    _ = @import("format/prefix.zig");
    _ = @import("io/file.zig");
    // Test-only files: the WAV and AU fixture contracts and their integrity checks.
    _ = @import("testing/fixtures.zig");
}
