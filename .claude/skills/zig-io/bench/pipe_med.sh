#!/bin/bash
# pipe_med.sh <buffer> <chunk>: the median MiB/s of 5 runs reading data.bin
# through a pipe from cat.
for _ in 1 2 3 4 5; do
    cat data.bin | ./io_bench pipe "$1" "$2" | grep -o '[0-9]* MiB/s' | cut -d' ' -f1
done | sort -n | sed -n 3p
