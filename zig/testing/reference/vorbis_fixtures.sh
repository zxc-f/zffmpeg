#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Makes the FFmpeg-encoded Vorbis fixtures (TODO.md T27d), the
# zig/testing/fixtures/ogg/ogg_vorbis_ffmpeg_*.ogg files, with the reference
# build's native Vorbis encoder (experimental, stereo only) and Ogg muxer:
#
#   bash zig/testing/reference/vorbis_fixtures.sh <ffmpeg-install-prefix>
#
# Each input is generate.py's (`--vorbis-input NAME`, s16le), each command
# adds the encoder options generate.py records, with bit-exact flags (the
# Ogg serial derived from the headers) and no metadata. The files are
# committed and checked against the hashes generate.py records, as the
# FFmpeg-made FLAC fixtures are (flac_fixtures.sh). After changing one,
# record the printed hashes in generate.py's OGG_FFMPEG table and rerun
# generate.py.
set -euo pipefail

prefix=$(realpath "${1:?usage: vorbis_fixtures.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generate="$root/zig/testing/fixtures/generate.py"
out="$root/zig/testing/fixtures/ogg"

python3 - "$generate" <<'PY' |
import importlib.util, sys
spec = importlib.util.spec_from_file_location("generate", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
for name, (channels, rate, _, _, options, _) in g.OGG_FFMPEG.items():
    print(name, channels, rate, options)
PY
while read -r name channels rate options; do
    # shellcheck disable=SC2086 # the options are words
    python3 "$generate" --vorbis-input "$name" |
        "$prefix/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y \
            -f s16le -ar "$rate" -ac "$channels" -i pipe:0 \
            -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
            -c:a vorbis -strict experimental $options -f ogg "$out/$name.ogg"
    printf '%s %s\n' "$name" "$(sha256sum "$out/$name.ogg" | cut -d' ' -f1)"
done
