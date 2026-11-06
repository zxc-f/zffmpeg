#!/bin/bash
# med.sh <runs> <command...>: the median MiB/s of the command's "<N> MiB/s" line.
runs=$1
shift
for _ in $(seq "$runs"); do "$@" | grep -o '[0-9]* MiB/s' | cut -d' ' -f1; done |
    sort -n | awk '{a[NR] = $1} END {print a[int((NR + 1) / 2)]}'
