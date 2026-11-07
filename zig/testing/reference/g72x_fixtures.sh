#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Makes the FFmpeg-made G.722 and G.726 fixtures: the
# zig/testing/fixtures/g72x/g72x_ffmpeg_*.au files (T31c), with the
# reference build's g722 and g726le encoders and AU muxer:
#
#   bash zig/testing/reference/g72x_fixtures.sh <ffmpeg-install-prefix>
#
# Each input is generate.py's (`--g72x-input NAME`, mono s16le), each
# command adds the encoder options generate.py records, with bit-exact
# flags and no metadata. The files are committed and checked against the
# hashes generate.py records, as the other FFmpeg-made fixtures are. After
# changing one, record the printed hashes in generate.py's G72X_FFMPEG
# table and rerun generate.py.
set -euo pipefail

prefix=$(realpath "${1:?usage: g72x_fixtures.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generate="$root/zig/testing/fixtures/generate.py"
out="$root/zig/testing/fixtures/g72x"

python3 - "$generate" <<'PY' |
import importlib.util, sys
spec = importlib.util.spec_from_file_location("generate", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
for name, (rate, _, _, _, options, _) in g.G72X_FFMPEG.items():
    print(name, rate, options)
PY
while read -r name rate options; do
    # shellcheck disable=SC2086 # the options are words
    python3 "$generate" --g72x-input "$name" |
        "$prefix/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y \
            -f s16le -ar "$rate" -ch_layout mono -i pipe:0 \
            -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
            $options -f au "$out/$name.au"
    printf '%s %s\n' "$name" "$(sha256sum "$out/$name.au" | cut -d' ' -f1)"
done
