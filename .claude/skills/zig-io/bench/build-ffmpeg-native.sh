#!/bin/bash
# Builds the pinned FFmpeg revision as the reference build
# (zig/testing/reference/build-ffmpeg.sh) configures it, with x86 assembly
# (NASM) instead of --disable-x86asm and -march=native (configure's
# --cpu=host): a benchmark build only, never the oracle (TODO.md T57). The
# component list comes from the reference install's recorded arguments, so
# both builds have the same demuxers, codecs and filters.
#
#   build-ffmpeg-native.sh <reference-install> <native-install>
#
# Needs the reference built first (its share/zffmpeg-reference/
# configure-args.txt), the source at .references/ffmpeg, clang and nasm.
# Builds in .references/ffmpeg-native-build.
set -euo pipefail
reference=$(realpath "${1:?usage: build-ffmpeg-native.sh <reference-install> <native-install>}")
prefix=$(realpath -m "${2:?usage: build-ffmpeg-native.sh <reference-install> <native-install>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
src="$root/.references/ffmpeg"
build="$root/.references/ffmpeg-native-build"
command -v nasm > /dev/null || { echo "nasm is required for the x86 assembly" >&2; exit 1; }
test "$(git -C "$src" rev-parse HEAD)" = "$(cat "$reference/share/zffmpeg-reference/commit.txt")"
args=(--cpu=host)
while IFS= read -r arg; do
    [ "$arg" = --disable-x86asm ] || args+=("$arg")
done < "$reference/share/zffmpeg-reference/configure-args.txt"
rm -rf "$build"
mkdir -p "$build"
cd "$build"
"$src/configure" --prefix="$prefix" "${args[@]}"
make -j"$(nproc)"
make install
record="$prefix/share/zffmpeg-reference"
mkdir -p "$record"
printf '%s\n' "${args[@]}" > "$record/configure-args.txt"
git -C "$src" rev-parse HEAD > "$record/commit.txt"
clang --version | head -n 1 > "$record/compiler.txt"
nasm --version > "$record/nasm.txt"
