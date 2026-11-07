#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Prints what the pinned FFmpeg makes of each ADPCM WAV fixture (T31a),
# vectors/adpcm_wav.txt:
#
#   bash zig/testing/reference/adpcm_wav_vectors.sh <ffmpeg-install-prefix> >zig/testing/vectors/adpcm_wav.txt
#
# For each fixture, in the manifest's order:
#   F <name>
#   S <codec_name> <sample_fmt> <channels> <sample_rate> <duration_ts>
#     (ffprobe's first audio stream; "S error" when ffprobe fails)
#   D <samples a channel> <SHA-256 of the samples as interleaved s16le>
#     (the ffmpeg program's decoding; "D error" when it fails)
set -euo pipefail

prefix=$(realpath "${1:?usage: adpcm_wav_vectors.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
dir="$root/zig/testing/fixtures/adpcm"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -n 's/^ *\.name = "\(.*\)",$/\1/p' "$dir/manifest.zon" | while read -r name; do
    file="$dir/$name.wav"
    printf 'F %s\n' "$name"
    if probe=$("$prefix/bin/ffprobe" -v error -select_streams a:0 -show_entries \
        stream=codec_name,sample_fmt,channels,sample_rate,duration_ts -of csv=p=0 "$file" 2>/dev/null) &&
        [[ -n $probe ]]; then
        # csv prints the fields in the stream section's order.
        IFS=, read -r codec fmt rate channels duration <<<"$probe"
        printf 'S %s %s %s %s %s\n' "$codec" "$fmt" "$channels" "$rate" "$duration"
    else
        printf 'S error\n'
    fi
    if "$prefix/bin/ffmpeg" -nostdin -v error -i "$file" -map 0:a:0 -f s16le -c:a pcm_s16le "$work/out.raw" \
        2>/dev/null; then
        channels=$("$prefix/bin/ffprobe" -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$file")
        bytes=$(stat -c %s "$work/out.raw")
        printf 'D %s %s\n' "$((bytes / 2 / channels))" "$(sha256sum "$work/out.raw" | cut -d' ' -f1)"
    else
        printf 'D error\n'
    fi
    rm -f "$work/out.raw"
done
