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
//!
//! Zig analyzes files lazily, so tests run only in files this module imports.
//! When a file with tests is added, reference it from the `test` block here.

pub const pcm = @import("codec/pcm.zig");
pub const audio = @import("core/audio.zig");
pub const time = @import("core/time.zig");

test {
    _ = @import("codec/pcm.zig");
    _ = @import("core/audio.zig");
    _ = @import("core/time.zig");
    // Test-only files: the WAV fixture contract and its integrity checks.
    _ = @import("testing/fixtures.zig");
}
