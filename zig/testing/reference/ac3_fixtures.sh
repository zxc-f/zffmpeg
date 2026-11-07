#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Makes the FFmpeg-made AC-3 and E-AC-3 fixtures: the zig/testing/fixtures/
# ac3/ac3_ffmpeg_*.ac3 (T32a) and eac3/eac3_ffmpeg_*.eac3 (T32b) files, with
# the reference build's encoders and raw muxers:
#
#   bash zig/testing/reference/ac3_fixtures.sh <ffmpeg-install-prefix>
#
# Each input is generate.py's (`--ac3-input` or `--eac3-input NAME`, s16le in the channel
# layout generate.py records), each command adds the encoder options
# generate.py records, with bit-exact flags and no metadata. The files are
# committed and checked against the hashes generate.py records, as the
# other FFmpeg-made fixtures are. After changing one, record the printed
# hashes in generate.py's AC3_FFMPEG or EAC3_FFMPEG table and rerun
# generate.py.
set -euo pipefail

prefix=$(realpath "${1:?usage: ac3_fixtures.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generate="$root/zig/testing/fixtures/generate.py"
out="$root/zig/testing/fixtures/ac3"

python3 - "$generate" <<'PY' |
import importlib.util, sys
spec = importlib.util.spec_from_file_location("generate", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
for kind, table in (("ac3", g.AC3_FFMPEG), ("eac3", g.EAC3_FFMPEG)):
    for name, (_, layout, rate, _, _, _, options, _) in table.items():
        print(kind, name, layout, rate, options)
PY
while read -r kind name layout rate options; do
    mkdir -p "$out/../$kind"
    # shellcheck disable=SC2086 # the options are words
    python3 "$generate" --"$kind"-input "$name" |
        "$prefix/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y \
            -f s16le -ar "$rate" -ch_layout "$layout" -i pipe:0 \
            -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
            $options -f "$kind" "$out/../$kind/$name.$kind"
    printf '%s %s\n' "$name" "$(sha256sum "$out/../$kind/$name.$kind" | cut -d' ' -f1)"
done
