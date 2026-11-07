#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Prints what the pinned FFmpeg makes of each G.722 and G.726 fixture
# (T31c), vectors/g72x_au.txt:
#
#   bash zig/testing/reference/g72x_au_vectors.sh <ffmpeg-install-prefix> >zig/testing/vectors/g72x_au.txt
#
# For each fixture, in the manifest's order:
#   F <name>
#   S <codec_name> <sample_fmt> <channels> <channel_layout> <sample_rate> <duration_ts>
#     (ffprobe's first audio stream; "S error" when ffprobe fails)
#   D <samples> <SHA-256 of the samples as s16le>
#     (the ffmpeg program's decoding, mono; "D error" when it fails)
set -euo pipefail

prefix=$(realpath "${1:?usage: g72x_au_vectors.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
dir="$root/zig/testing/fixtures/g72x"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -n 's/^ *\.name = "\(.*\)",$/\1/p' "$dir/manifest.zon" | while read -r name; do
    file="$dir/$name.au"
    printf 'F %s\n' "$name"
    # -f au: an AU with data size 0 is not detected by content.
    if probe=$("$prefix/bin/ffprobe" -v error -f au -select_streams a:0 -show_entries \
        stream=codec_name,sample_fmt,channels,channel_layout,sample_rate,duration_ts -of csv=p=0 "$file" 2>/dev/null) &&
        [[ -n $probe ]]; then
        # csv prints the fields in the stream section's order.
        IFS=, read -r codec fmt rate channels layout duration <<<"$probe"
        printf 'S %s %s %s %s %s %s\n' "$codec" "$fmt" "$channels" "$layout" "$rate" "$duration"
    else
        printf 'S error\n'
    fi
    if "$prefix/bin/ffmpeg" -nostdin -v error -f au -i "$file" -map 0:a:0 -f s16le -c:a pcm_s16le "$work/out.raw" \
        2>/dev/null; then
        bytes=$(stat -c %s "$work/out.raw")
        printf 'D %s %s\n' "$((bytes / 2))" "$(sha256sum "$work/out.raw" | cut -d' ' -f1)"
    else
        printf 'D error\n'
    fi
    rm -f "$work/out.raw"
done
