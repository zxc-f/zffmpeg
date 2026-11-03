#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Builds the pinned FFmpeg reference (TODO.md T03): Linux x86-64, Clang, and a
# minimal LGPL configuration with only what the WAV/PCM comparisons need.
#
#   bash zig/testing/reference/build-ffmpeg.sh <install-prefix>
#
# The source is the pinned clone in .references/ffmpeg (created if missing);
# the build happens out of tree in .references/ffmpeg-build, so an existing
# checkout's working tree is left alone. Everything lands under the ignored
# .references/ directory or the given prefix.
set -euo pipefail

commit=5d5a38a7e46be296eab75982c0986054f731e19e
prefix=$(realpath -m "${1:?usage: build-ffmpeg.sh <install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
src="$root/.references/ffmpeg"
build="$root/.references/ffmpeg-build"

# Every component is disabled, then only these are enabled: the file and pipe
# protocols, the WAV and AU demuxers, the s16le and s16be PCM decoders, the
# s16le PCM encoder, the raw s16le muxer, and the aresample filter. The ffmpeg
# program selects the few filters it always needs. No GPL, nonfree, external
# or hardware components.
configure_args=(
    --cc=clang
    --disable-everything
    --disable-autodetect
    --disable-doc
    --disable-network
    --disable-x86asm
    --disable-ffplay
    --disable-avdevice
    --enable-protocol=file,pipe
    --enable-demuxer=wav,au
    --enable-decoder=pcm_s16le,pcm_s16be
    --enable-encoder=pcm_s16le
    --enable-muxer=pcm_s16le
    --enable-filter=aresample
)

if [ ! -d "$src/.git" ]; then
    git clone --depth 1 --no-checkout https://github.com/FFmpeg/FFmpeg.git "$src"
fi
if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$commit" ]; then
    git -C "$src" fetch --depth 1 origin "$commit"
    git -C "$src" -c advice.detachedHead=false checkout --detach "$commit"
fi
test "$(git -C "$src" rev-parse HEAD)" = "$commit"

rm -rf "$build"
mkdir -p "$build"
cd "$build"
"$src/configure" --prefix="$prefix" "${configure_args[@]}"
make -j"$(nproc)"
make install

record="$prefix/share/zffmpeg-reference"
mkdir -p "$record"
cp ffbuild/config.log "$record/config.log"
printf '%s\n' "${configure_args[@]}" >"$record/configure-args.txt"
echo "$commit" >"$record/commit.txt"
clang --version | head -n 1 >"$record/compiler.txt"
