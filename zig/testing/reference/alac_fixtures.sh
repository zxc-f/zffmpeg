#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Makes the FFmpeg-made ALAC fixtures: the zig/testing/fixtures/alac/
# alac_ffmpeg_*.caf files (T31b), with the reference build's ALAC encoder
# and CAF muxer:
#
#   bash zig/testing/reference/alac_fixtures.sh <ffmpeg-install-prefix>
#
# Each input is generate.py's (`--alac-input NAME`: s16le, or s32le with
# 24 bits at the top), each command adds the encoder options generate.py
# records, with bit-exact flags and no metadata. The files are committed
# and checked against the hashes generate.py records, as the other
# FFmpeg-made fixtures are. After changing one, record the printed hashes
# in generate.py's ALAC_FFMPEG table and rerun generate.py.
set -euo pipefail

prefix=$(realpath "${1:?usage: alac_fixtures.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generate="$root/zig/testing/fixtures/generate.py"
out="$root/zig/testing/fixtures/alac"

# ALAC's layouts (ff_alac_ch_layouts), so that the encoder takes the
# channels as they are.
layouts=(mono stereo 3.0 4.0 5.0 5.1 "6.1(back)" "7.1(wide)")

python3 - "$generate" <<'PY' |
import importlib.util, sys
spec = importlib.util.spec_from_file_location("generate", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
for name, (channels, rate, _, _, _, bits, options, _) in g.ALAC_FFMPEG.items():
    print(name, channels, rate, bits, options)
PY
while read -r name channels rate bits options; do
    format=s16le
    [ "$bits" = 24 ] && format=s32le
    layout=${layouts[$((channels - 1))]}
    # shellcheck disable=SC2086 # the options are words
    python3 "$generate" --alac-input "$name" |
        "$prefix/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y \
            -f "$format" -ar "$rate" -ch_layout "$layout" -i pipe:0 \
            -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
            $options -f caf "$out/$name.caf"
    printf '%s %s\n' "$name" "$(sha256sum "$out/$name.caf" | cut -d' ' -f1)"
done
