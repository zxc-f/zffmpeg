#!/bin/bash
# End-to-end timing of zffmpeg against the pinned FFmpeg reference on one
# large WAV file, from the page cache. Prints the median wall time of N runs.
# FFmpeg reads standard input as `pipe:`: its `-` means the `fd` protocol,
# which the minimal reference build does not enable.
#
#   e2e.sh <zffmpeg> <ffmpeg> <input.wav> [runs]
set -euo pipefail
zffmpeg=$1 ffmpeg=$2 input=$3 runs=${4:-5}
size=$(stat -c %s "$input")
cat "$input" > /dev/null # warm the page cache

median() { # median wall seconds of `runs` runs of "$@" (a shell command string)
    for _ in $(seq "$runs"); do
        start=$(date +%s.%N)
        bash -c "$1" > /dev/null 2>&1
        end=$(date +%s.%N)
        echo "$end - $start" | bc -l
    done | sort -n | awk '{a[NR]=$1} END {printf "%.3f", a[int((NR+1)/2)]}'
}

row() { # row <label> <zffmpeg command> <ffmpeg command>
    z=$(median "$2"); f=$(median "$3")
    printf '%-34s %8s s %8.0f MiB/s %8s s %8.0f MiB/s\n' "$1" "$z" \
        "$(echo "$size / 1048576 / $z" | bc -l)" "$f" "$(echo "$size / 1048576 / $f" | bc -l)"
}

printf '%-34s %21s %21s\n' "operation ($((size / 1048576)) MiB input)" zffmpeg ffmpeg
row "WAV stream copy to WAV" \
    "$zffmpeg -y -i $input -c copy out_z.wav" \
    "$ffmpeg -nostdin -v error -y -i $input -c copy out_f.wav"
row "WAV s16le to AU s16be (transcode)" \
    "$zffmpeg -y -i $input out_z.au" \
    "$ffmpeg -nostdin -v error -y -i $input out_f.au"
row "WAV to raw s16le" \
    "$zffmpeg -y -i $input -f s16le out_z.raw" \
    "$ffmpeg -nostdin -v error -y -i $input -f s16le out_f.raw"
row "WAV from a pipe to AU" \
    "cat $input | $zffmpeg -y -i - out_z.au" \
    "cat $input | $ffmpeg -nostdin -v error -y -i pipe: out_f.au"
row "WAV to raw s16le on a pipe" \
    "$zffmpeg -y -i $input -f s16le - | cat > /dev/null" \
    "$ffmpeg -nostdin -v error -y -i $input -f s16le - | cat > /dev/null"
rm -f out_z.wav out_f.wav out_z.au out_f.au out_z.raw out_f.raw
