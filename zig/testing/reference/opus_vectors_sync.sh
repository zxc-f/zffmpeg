#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Original file for this project.
#
# Fetches the RFC 6716 Opus test vectors as updated by RFC 8251 (TODO.md
# T28) into an ignored directory and checks each file against the SHA-256
# recorded in opus_testvectors.txt (their provenance: the archive below, at
# the time they were recorded):
#
#   bash zig/testing/reference/opus_vectors_sync.sh [<directory>]
#
# The default directory is .references/opus-testvectors. They are optional
# coverage, as the FATE samples are (fate_sync.sh): FATE carries them only
# as Matroska rewraps, which the port cannot demux yet. Each testvectorNN.bit
# holds opus_demo's packets (a 32-bit big-endian size, the encoder's final
# range, the packet); testvectorNN.dec and testvectorNNm.dec are the
# reference decoder's 48 kHz stereo and mono output.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
dest=${1:-"$root/.references/opus-testvectors"}
url=https://opus-codec.org/static/testvectors/opus_testvectors-rfc8251.tar.gz
archive_sha256=6b26a22f9ba87b2b836906a9bb7afec5f8e54d49553b1200382520ee6fedfa55
mkdir -p "$dest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sSL --max-time 600 -o "$tmp/vectors.tar.gz" "$url"
echo "$archive_sha256  $tmp/vectors.tar.gz" | sha256sum --quiet -c
tar -xzf "$tmp/vectors.tar.gz" -C "$dest" --strip-components=1 --no-same-owner
(cd "$dest" && sha256sum --quiet -c "$here/opus_testvectors.txt")
echo "fetched and checked $(wc -l <"$here/opus_testvectors.txt") files into $dest"
