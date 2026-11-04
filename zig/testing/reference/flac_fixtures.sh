#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Makes the FFmpeg-encoded FLAC fixtures (TODO.md T26a), the
# zig/testing/fixtures/flac/flac_ffmpeg_*.flac files, with the reference
# build's FLAC encoder:
#
#   bash zig/testing/reference/flac_fixtures.sh <ffmpeg-install-prefix>
#
# Each input is generate.py's (`--flac-input NAME`, s16le), each command is
# the encoder options generate.py records for the fixture, with bit-exact
# flags and no metadata. The files are committed: the encoder's choices
# (floating-point LPC analysis) are not part of any contract, so the files
# are checked against the hashes generate.py records rather than remade in
# CI. After changing a fixture, record the printed hashes in generate.py's
# FLAC_FFMPEG table and rerun generate.py.
set -euo pipefail

prefix=$(realpath "${1:?usage: flac_fixtures.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generate="$root/zig/testing/fixtures/generate.py"
out="$root/zig/testing/fixtures/flac"

python3 - "$generate" <<'PY' |
import importlib.util, sys
spec = importlib.util.spec_from_file_location("generate", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
for name, (channels, rate, _, _, options, _) in g.FLAC_FFMPEG.items():
    print(name, channels, rate, options)
PY
while read -r name channels rate options; do
    # shellcheck disable=SC2086 # the options are words
    python3 "$generate" --flac-input "$name" |
        "$prefix/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y \
            -f s16le -ar "$rate" -ac "$channels" -i pipe:0 \
            -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
            -c:a flac $options -f flac "$out/$name.flac"
    printf '%s %s\n' "$name" "$(sha256sum "$out/$name.flac" | cut -d' ' -f1)"
done
