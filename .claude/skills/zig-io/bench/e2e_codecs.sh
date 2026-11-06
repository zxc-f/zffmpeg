#!/bin/bash
# Codec-heavy end-to-end timing: zffmpeg against one or more FFmpeg builds
# (the pinned reference without assembly, a build with x86 assembly and
# -march=native, a distribution build), with hyperfine. The PCM paths of
# e2e.sh measure I/O; these measure the codecs, where FFmpeg's SIMD kernels
# run (flacdsp, flacencdsp, mpegaudiodsp, float_dsp, vorbisdsp, opusdsp,
# libswresample's resampler and converters).
#
#   e2e_codecs.sh <work-dir> <zffmpeg> <label>=<ffmpeg> [<label>=<ffmpeg>...]
#
# <work-dir> must hold big.wav (run_all.sh makes it: 512 MiB, s16 stereo
# 48 kHz, random bytes). The codec rows use short.wav, 10 minutes of two
# vibrato tones over pink noise (s16 stereo 48 kHz, closer to music than
# random bytes, which FLAC stores verbatim), made by the first FFmpeg given
# that has lavfi (a distribution's), else the first 10 minutes of big.wav.
# The compressed inputs are made from it by the first FFmpeg given that has
# the encoder (libvorbis, libopus and libmp3lame first, else FFmpeg's own;
# MP3 needs libmp3lame, else that row is skipped). Each FFmpeg runs with
# its defaults (threads included) and without -bitexact, as a user runs it.
# Prints a table per operation (hyperfine_table.py): median wall, user and
# system time, peak memory and instructions. Under `taskset -c <core>` every
# command shares one core: the same CPU budget, FFmpeg's threads included.
set -euo pipefail
work=$1 zffmpeg=$2
shift 2
cd "$work"
command -v hyperfine > /dev/null || { echo "hyperfine is required" >&2; exit 1; }
labels=() bins=()
for spec in "$@"; do labels+=("${spec%%=*}"); bins+=("${spec#*=}"); done

encoder() { # encoder <ffmpeg> <name>: whether the build has the encoder
    "$1" -hide_banner -encoders 2> /dev/null | awk '{print $2}' | grep -qx "$2"
}
make_input() { # make_input <file> <encoder> <ffmpeg options...>
    local file=$1 enc=$2
    shift 2
    [ -f "$file" ] && return 0
    for b in "${bins[@]}"; do
        if encoder "$b" "$enc"; then
            "$b" -nostdin -v error -y -i short.wav "$@" "$file"
            return 0
        fi
    done
    return 1
}
[ -f big.wav ] || { echo "big.wav missing (run_all.sh makes it)" >&2; exit 1; }
cat big.wav > /dev/null
if [ ! -f short.wav ]; then
    tone="aevalsrc=0.3*sin(2*PI*(440+3*sin(2*PI*5*t))*t)+0.2*sin(2*PI*660*t)|0.3*sin(2*PI*(554+3*sin(2*PI*4*t))*t)+0.2*sin(2*PI*330*t):s=48000:d=600"
    for b in "${bins[@]}"; do
        if "$b" -hide_banner -filters 2> /dev/null | grep -q ' aevalsrc '; then
            "$b" -nostdin -v error -y -f lavfi -i "$tone" -f lavfi -i "anoisesrc=c=pink:a=0.05:r=48000:d=600" \
                -filter_complex "[1]pan=stereo|c0=c0|c1=c0[n];[0][n]amix=inputs=2:normalize=0" -c:a pcm_s16le short.wav
            break
        fi
    done
    [ -f short.wav ] || "${bins[0]}" -nostdin -v error -y -t 600 -i big.wav -c:a pcm_s16le short.wav
fi
make_input in.flac flac -c:a flac
make_input in.ogg libvorbis -c:a libvorbis -q:a 5 || make_input in.ogg vorbis -c:a vorbis -strict experimental
make_input in.opus libopus -c:a libopus -b:a 128k || make_input in.opus opus -c:a opus -strict experimental -ar 48000
have_mp3=1
make_input in.mp3 libmp3lame -c:a libmp3lame -b:a 192k || have_mp3=0

echo "inputs: $(ls -l in.* short.wav | awk '{printf "%s %d MiB; ", $NF, $5 / 1048576}')"
echo

row() { # row <title> <input> <output options...>: one hyperfine run
    local title=$1 input=$2
    shift 2
    local cmds=("-n" "zffmpeg" "$zffmpeg -y -i $input $* out_z")
    for i in "${!bins[@]}"; do
        cmds+=("-n" "${labels[$i]}" "${bins[$i]} -nostdin -v error -y -i $input $* out_f$i")
    done
    echo "### $title"
    echo
    hyperfine -N --warmup 1 --runs 5 --style none --export-json run.json "${cmds[@]}" > /dev/null 2>&1
    python3 -I "$(dirname "$0")/hyperfine_table.py" run.json zffmpeg "${labels[@]}"
    echo
    rm -f out_z out_f* run.json
}

row "WAV to FLAC (encode, 10 min)" short.wav -f flac
row "FLAC to WAV (decode, 10 min)" in.flac -f wav
row "Ogg Vorbis to WAV (decode, 10 min)" in.ogg -f wav
row "Ogg Opus to WAV (decode, 10 min)" in.opus -f wav
if [ $have_mp3 = 1 ]; then row "MP3 to WAV (decode, 10 min)" in.mp3 -f wav; fi
row "WAV 48 kHz to 44.1 kHz (resample, 10 min)" short.wav -ar 44100 -f wav
row "WAV s16 to f32le (sample conversion, 512 MiB)" big.wav -f f32le
