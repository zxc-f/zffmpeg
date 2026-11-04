#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Fetches the FATE samples the optional coverage uses (TODO.md T26b, T19c)
# into an ignored directory, as FFmpeg's `make fate-rsync` would, but only
# the files fate_samples.txt lists, then checks each against the SHA-256
# recorded there (their provenance: rsync://fate-suite.ffmpeg.org/fate-suite/
# at the time they were recorded):
#
#   bash zig/testing/reference/fate_sync.sh [<directory>]
#
# The default directory is .references/fate-suite. compare.py reads it with
# --fate-suite; missing files are reported as skipped, never as failures,
# and a file whose bytes differ from the record fails.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
dest=${1:-"$root/.references/fate-suite"}
manifest="$here/fate_samples.txt"
mkdir -p "$dest"
count=0
while read -r _ file; do
    mkdir -p "$dest/$(dirname "$file")"
    rsync -tLW --timeout=120 "rsync://fate-suite.ffmpeg.org/fate-suite/$file" "$dest/$file"
    count=$((count + 1))
done <"$manifest"
(cd "$dest" && sha256sum --quiet -c "$manifest")
echo "synced and checked $count files into $dest"
