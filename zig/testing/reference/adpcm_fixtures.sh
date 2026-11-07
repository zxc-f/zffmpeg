#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Makes the FFmpeg-made ADPCM fixtures: the zig/testing/fixtures/adpcm/
# adpcm_ffmpeg_*.wav files (T31a), with the reference build's adpcm_ima_wav
# and adpcm_ms encoders and its WAV muxer:
#
#   bash zig/testing/reference/adpcm_fixtures.sh <ffmpeg-install-prefix>
#
# Each input is generate.py's (`--adpcm-input NAME`, s16le), each command
# adds the encoder options generate.py records, with bit-exact flags and no
# metadata. The files are committed and checked against the hashes
# generate.py records, as the other FFmpeg-made fixtures are. After
# changing one, record the printed hashes in generate.py's ADPCM_FFMPEG
# table and rerun generate.py.
set -euo pipefail

prefix=$(realpath "${1:?usage: adpcm_fixtures.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generate="$root/zig/testing/fixtures/generate.py"
out="$root/zig/testing/fixtures/adpcm"

python3 - "$generate" <<'PY' |
import importlib.util, sys
spec = importlib.util.spec_from_file_location("generate", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
for name, (channels, rate, _, _, _, options, _) in g.ADPCM_FFMPEG.items():
    print(name, channels, rate, options)
PY
while read -r name channels rate options; do
    # shellcheck disable=SC2086 # the options are words
    python3 "$generate" --adpcm-input "$name" |
        "$prefix/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y \
            -f s16le -ar "$rate" -ac "$channels" -i pipe:0 \
            -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
            $options -f wav "$out/$name.wav"
    printf '%s %s\n' "$name" "$(sha256sum "$out/$name.wav" | cut -d' ' -f1)"
done
