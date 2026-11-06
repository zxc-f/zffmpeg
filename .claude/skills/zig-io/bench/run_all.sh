#!/bin/bash
# Reruns every measurement of the zig-io analysis and prints one report with
# the machine's details first, so results from another machine can be
# compared with references/analysis.md.
#
#   run_all.sh <work-dir> <zig> [<zffmpeg> [<label>=]<ffmpeg>...]
#
# <work-dir> needs about 2 GiB free (a 512 MiB test file, a 512 MiB WAV, the
# codec inputs and their outputs); it is created if missing and left in
# place. <zig> is the Zig 0.17.0 compiler. With <zffmpeg> (ReleaseFast:
# `zig build -Doptimize=ReleaseFast`) and one or more FFmpeg builds (the
# pinned reference from zig/testing/reference/build-ffmpeg.sh first; an
# unlabeled one is "reference"), the end-to-end comparisons run too: the PCM
# paths (e2e.sh) against each build, then the codec paths (e2e_codecs.sh,
# which needs hyperfine). strace, when installed, adds the syscall counts.
# Every number is a median: 5 runs, 3 for writes and copies.
set -euo pipefail
work=$1 zig=$2 zffmpeg=${3:-}
shift 2
[ $# -gt 0 ] && shift
ffmpegs=("$@")
ffmpeg=""
if [ ${#ffmpegs[@]} -gt 0 ]; then ffmpeg=${ffmpegs[0]#*=}; fi
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$work"
cp "$here"/io_bench.zig "$here"/med.sh "$here"/pipe_med.sh "$here"/e2e.sh "$here"/e2e_codecs.sh "$here"/hyperfine_table.py "$here"/rss.py "$work"/
cd "$work"
chmod +x med.sh pipe_med.sh e2e.sh e2e_codecs.sh

echo "# zig-io measurements"
echo
echo "date: $(date -u +%Y-%m-%dT%H:%MZ)"
echo "kernel: $(uname -srm)"
echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //'), $(nproc) logical cores"
echo "cpu flags: $(grep -o -m2 -w 'avx2\|fma' /proc/cpuinfo | sort -u | tr '\n' ' ')"
echo "memory: $(free -g | awk '/^Mem:/ {print $2 " GiB"}')"
echo "cpu governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2> /dev/null || echo unknown), energy preference: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2> /dev/null || echo unknown)"
echo "filesystem: $(df -T . | awk 'NR==2 {print $2 " on " $1}')"
echo "pipe max size: $(cat /proc/sys/fs/pipe-max-size)"
echo "zig: $("$zig" version)"
if command -v strace > /dev/null; then echo "strace: $(strace -V | head -1)"; else echo "strace: not installed"; fi
if command -v hyperfine > /dev/null; then echo "hyperfine: $(hyperfine --version)"; else echo "hyperfine: not installed"; fi
for spec in "${ffmpegs[@]}"; do
    label=reference bin=$spec
    if [[ $spec == *=* ]]; then label=${spec%%=*} bin=${spec#*=}; fi
    echo "ffmpeg $label: $("$bin" -hide_banner -version | head -1)"
    echo "  $("$bin" -hide_banner -version | grep -m1 '^configuration:' | cut -c1-400)"
done
echo

"$zig" build-exe -OReleaseFast io_bench.zig
[ -f data.bin ] || ./io_bench gen data.bin 512
cat data.bin > /dev/null

echo "## R1 bulk read of 512 MiB, readSliceShort into a caller chunk (MiB/s)"
printf "%-8s %-6s" buffer mode; for c in 4096 65536 1048576; do printf " chunk%-8s" $c; done; echo
for b in 0 4096 16384 32768 65536 262144 1048576; do
    for m in pos stream; do
        printf "%-8s %-6s" $b $m
        for c in 4096 65536 1048576; do printf " %-13s" "$(./med.sh 5 ./io_bench read data.bin $m $b $c)"; done
        echo
    done
done
echo

echo "## R2 4-byte fields over 64 MiB, positional (MiB/s)"
printf "%-8s %-10s %-10s %-10s\n" buffer slice take int
for b in 4096 65536 1048576; do
    printf "%-8s" $b
    for h in slice take int; do printf " %-10s" "$(./med.sh 5 ./io_bench fields data.bin pos $b $h 64)"; done
    echo
done
echo

echo "## R3 read 4 KiB then skip N, buffer 64 KiB (logical MiB/s, skipped bytes included)"
printf "%-10s %-10s %-10s\n" skip pos stream
for s in 4096 61440 1048576 16777216; do
    printf "%-10s %-10s %-10s\n" $s "$(./med.sh 5 ./io_bench skip data.bin pos 65536 4096 $s)" "$(./med.sh 5 ./io_bench skip data.bin stream 65536 4096 $s)"
done
echo

echo "## R4 512 MiB through a pipe from cat (MiB/s)"
printf "%-8s %-11s %-11s\n" buffer chunk4096 chunk65536
for b in 0 4096 16384 65536 262144 1048576; do
    printf "%-8s %-11s %-11s\n" $b "$(./pipe_med.sh $b 4096)" "$(./pipe_med.sh $b 65536)"
done
echo

echo "## W1 write 256 MiB with writeAll(chunk), then flush (MiB/s)"
printf "%-8s %-6s %-11s %-11s %-11s\n" buffer mode chunk64 chunk4096 chunk1M
for b in 0 4096 32768 65536 262144 1048576; do
    for m in pos stream; do
        printf "%-8s %-6s %-11s %-11s %-11s\n" $b $m "$(./med.sh 3 ./io_bench write out.bin $m $b 64 256)" \
            "$(./med.sh 3 ./io_bench write out.bin $m $b 4096 256)" "$(./med.sh 3 ./io_bench write out.bin $m $b 1048576 256)"
    done
done
rm -f out.bin
echo

echo "## C1 copy 512 MiB file to file: read/write loop or Reader.stream (sendFile) (MiB/s)"
printf "%-8s %-10s %-10s\n" buffer loop64K stream
for b in 4096 32768 65536 1048576; do
    printf "%-8s %-10s %-10s\n" $b "$(./med.sh 3 ./io_bench copy data.bin copy.bin loop $b)" "$(./med.sh 3 ./io_bench copy data.bin copy.bin stream $b)"
done
cmp data.bin copy.bin && echo "copy identical"
rm -f copy.bin
echo

echo "## Q1 packets read and hashed: serial, or two tasks joined by an Io.Queue of capacity N (MiB/s)"
printf "%-7s %-6s %-8s %-6s %-6s %-6s %-6s\n" packet rounds serial q1 q2 q8 q32
for p in 4096 65536; do
    for r in 0 1; do
        printf "%-7s %-6s %-8s" $p $r "$(./med.sh 3 ./io_bench serial data.bin $p $r)"
        for q in 1 2 8 32; do printf " %-6s" "$(./med.sh 3 ./io_bench queue data.bin $q $p $r)"; done
        echo
    done
done
echo

if command -v strace > /dev/null; then
    echo "## S1 syscalls (strace -c)"
    for args in "copy data.bin copy.bin stream 65536" "skip data.bin pos 65536 4096 1048576" "skip data.bin stream 65536 4096 1048576"; do
        # shellcheck disable=SC2086
        strace -f -c -o st.txt ./io_bench $args > /dev/null
        echo "io_bench $args: $(awk '$NF ~ /^(copy_file_range|preadv|readv|pread64|read|writev|write)$/ {printf "%s=%s ", $NF, $4}' st.txt)total=$(awk '$NF == "total" {print $4}' st.txt)"
    done
    rm -f copy.bin st.txt
    echo
fi

if [ -n "$zffmpeg" ] && [ -n "$ffmpeg" ]; then
    [ -f big.wav ] || "$zffmpeg" -f s16le -ar 48000 -ac 2 -i data.bin big.wav
    labeled=()
    for spec in "${ffmpegs[@]}"; do
        label=reference bin=$spec
        if [[ $spec == *=* ]]; then label=${spec%%=*} bin=${spec#*=}; fi
        labeled+=("$label=$bin")
        echo "## E2E zffmpeg against FFmpeg \"$label\" (median wall time of 5 runs)"
        ./e2e.sh "$zffmpeg" "$bin" big.wav 5
        echo
    done
    if command -v hyperfine > /dev/null; then
        echo "## E2E codecs (e2e_codecs.sh)"
        echo
        ./e2e_codecs.sh "$work" "$zffmpeg" "${labeled[@]}"
    fi
    echo "## E2E resources, WAV to AU, one run each"
    echo "zffmpeg: $(python3 -I rss.py "$zffmpeg" -y -i big.wav out.au)"
    echo "ffmpeg:  $(python3 -I rss.py "$ffmpeg" -nostdin -v error -y -i big.wav out.au)"
    if command -v strace > /dev/null; then
        for who in zffmpeg ffmpeg; do
            if [ $who = zffmpeg ]; then set -- "$zffmpeg" -y -i big.wav out.au; else set -- "$ffmpeg" -nostdin -v error -y -i big.wav out.au; fi
            strace -f -c -o st.txt "$@" > /dev/null 2>&1
            echo "$who syscalls: $(awk '$NF ~ /^(preadv|pread64|read|readv|writev|write|pwritev|futex|clone|clone3)$/ {printf "%s=%s ", $NF, $4}' st.txt)total=$(awk '$NF == "total" {print $4}' st.txt)"
        done
        rm -f st.txt
    fi
    rm -f out.au
fi
