#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Fetches the FATE samples the optional FLAC coverage uses (TODO.md T26b,
# T19c) into an ignored directory, as FFmpeg's `make fate-rsync` would, but
# only these files:
#
#   bash zig/testing/reference/fate_sync.sh [<directory>]
#
# The default directory is .references/fate-suite. compare.py reads it with
# --fate-suite; missing files are reported as skipped, never as failures.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
dest=${1:-"$root/.references/fate-suite"}
files=(
    audio-reference/luckynight_2ch_44kHz_s16.wav
    audio-reference/divertimenti_2ch_96kHz_s24.wav
    audio-reference/drums_2ch_44kHz_s32_wastedbits.wav
    audio-reference/chorusnoise_2ch_44kHz_s16.wav
    cover_art/cover_art.flac
    filter/hdcd-mix.flac
    filter/hdcd-false-positive.flac
    filter/hdcd-encoding-errors.flac
    filter/hdcd-fake20bit.flac
    filter/seq-3341-7_seq-3342-5-24bit.flac
    filter/out-of-phase-1000hz.flac
)
mkdir -p "$dest"
for f in "${files[@]}"; do
    mkdir -p "$dest/$(dirname "$f")"
    rsync -tLW --timeout=120 "rsync://fate-suite.ffmpeg.org/fate-suite/$f" "$dest/$f"
done
echo "synced ${#files[@]} files into $dest"
