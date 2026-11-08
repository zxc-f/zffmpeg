#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Makes the FFmpeg-made MP4 fixtures (T33a1): the zig/testing/fixtures/mp4/
# files of generate.py's MOV_FFMPEG table, with the reference build's
# encoders and its mp4, mov and ipod muxers:
#
#   bash zig/testing/reference/mov_fixtures.sh <ffmpeg-install-prefix>
#
# Each input is generate.py's (`--mov-input NAME INDEX`, s16le in the channel
# layout generate.py records) or a committed fixture (a stream copy); each
# command adds the options generate.py records, with bit-exact flags and no
# metadata. The files are committed and checked against the hashes
# generate.py records, as the other FFmpeg-made fixtures are. After changing
# one, record the printed hashes in generate.py's MOV_FFMPEG table and rerun
# generate.py.
set -euo pipefail

prefix=$(realpath "${1:?usage: mov_fixtures.sh <ffmpeg-install-prefix>}")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generate="$root/zig/testing/fixtures/generate.py"
fixtures="$root/zig/testing/fixtures"
out="$fixtures/mp4"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

python3 - "$generate" <<'PY' |
import importlib.util, sys
spec = importlib.util.spec_from_file_location("generate", sys.argv[1])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
for name, (ext, inputs, options, _) in g.MOV_FFMPEG.items():
    described = []
    for i, source in enumerate(inputs):
        if isinstance(source, str):
            described.append(f"file:{source}")
        else:
            channels, layout, rate, *_ = source
            described.append(f"signal:{i}:{layout}:{rate}")
    print(name, ext, " ".join(described), "--", options)
PY
while read -r line; do
    name=${line%% *}
    rest=${line#* }
    ext=${rest%% *}
    rest=${rest#* }
    sources=${rest%% -- *}
    options=${rest#* -- }
    args=()
    for source in $sources; do
        case $source in
        file:*)
            args+=(-i "$fixtures/${source#file:}")
            ;;
        signal:*)
            IFS=: read -r _ index layout rate <<<"$source"
            python3 "$generate" --mov-input "$name" "$index" >"$work/$name.$index.s16"
            args+=(-f s16le -ar "$rate" -ch_layout "$layout" -i "$work/$name.$index.s16")
            ;;
        esac
    done
    # shellcheck disable=SC2086 # the options are words
    "$prefix/bin/ffmpeg" -nostdin -hide_banner -loglevel error -y "${args[@]}" \
        -map_metadata -1 -fflags +bitexact -flags:a +bitexact \
        $options "$out/$name.$ext"
    printf '%s %s\n' "$name" "$(sha256sum "$out/$name.$ext" | cut -d' ' -f1)"
done
