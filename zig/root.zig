// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project.
//! `av`: the native Zig multimedia library module.
//!
//! This file is the module's public facade. It exports nothing yet: the PCM
//! kernels, audio/time types and WAV parser arrive in T04–T06. Export only
//! supported features here and keep internal declarations in their own files.
//!
//! Zig analyzes files lazily, so tests run only in files this module imports.
//! When a file with tests is added, reference it from a `test` block here.
