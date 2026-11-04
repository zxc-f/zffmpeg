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
# protocols, the WAV, Wave64, AU, AIFF and CAF demuxers, the PCM decoders and encoders T20b
# compares (u8, s8, s16/s24/s32/s64 and f32/f64 in both byte orders, A-law and
# mu-law), the WAV muxer (decoded samples are compared as WAV payloads; T21a),
# the Wave64, AU and AIFF muxers (their files must read in zffprobe; T21b,
# T22a, T22b), the raw PCM demuxers and muxers of every one of those codecs
# FFmpeg has one for, all but s64 (T22c), the FLAC demuxer, parser, decoder,
# encoder and muxer and the framecrc, framemd5 and streamhash muxers (T26a,
# T19b), the Ogg demuxer (T27a), the ogg, oga and opus muxers (T27b), the
# Vorbis decoder and FFmpeg's native Vorbis encoder, which makes the Vorbis
# fixtures (T27d), the Opus decoder and FFmpeg's native Opus encoder, which
# makes the Opus fixtures (T28), and the audio filters T24-T25 compare. The ffmpeg program
# selects the few filters it always needs. No GPL, nonfree, external or
# hardware components.
pcm_codecs=pcm_u8,pcm_s8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_s64le,pcm_s64be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_alaw,pcm_mulaw
pcm_formats=pcm_u8,pcm_s8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_alaw,pcm_mulaw
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
    --enable-demuxer=wav,w64,au,aiff,caf,flac,ogg,mp3,"$pcm_formats"
    --enable-decoder="$pcm_codecs",flac,vorbis,opus
    --enable-encoder="$pcm_codecs",flac,vorbis,opus
    --enable-muxer=wav,w64,au,aiff,flac,ogg,oga,opus,framecrc,framemd5,streamhash,"$pcm_formats"
    --enable-parser=flac,mpegaudio
    --enable-filter=aresample,volume,asetpts,amix,pan,channelmap,channelsplit,asplit
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
