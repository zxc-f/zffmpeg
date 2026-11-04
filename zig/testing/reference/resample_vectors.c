// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T24 resampling oracle (zig/testing/vectors/resample.txt) from
// the pinned FFmpeg's libswresample with its default options: swr_convert
// on generated input, all of it in one call, then drained as FFmpeg's
// aresample filter drains it (NULL input, 4096 frames at a time, until
// nothing comes out). The lines:
//
//   R <in rate> <out rate> <in fmt> <out fmt> <channels> <frames> <delay> <out frames> <bytes>
//       the rates, the packed sample format names, the channel count, the
//       input frame count, swr_get_delay(out rate) after the input call, the
//       output frame count, and the output's bytes in hex (interleaved,
//       little-endian).
//
// The input comes from the 64-bit linear congruential generator of
// remix_vectors.c, scaled to a quarter of full scale and smoothed by a
// one-pole low-pass, so that the resampler sees band-limited audio rather
// than noise; u8, s16 and s32 are its rounded value, flt and dbl the value
// itself. See zig/testing/reference/README.md for the build commands.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/channel_layout.h"
#include "libavutil/mem.h"
#include "libavutil/samplefmt.h"
#include "libswresample/swresample.h"

static uint64_t state;

/* A smoothed pseudo-random signal in [-0.25, 0.25]. */
static double next_sample(double *memory)
{
    state = state * 6364136223846793005ULL + 1442695040888963407ULL;
    double white = (double)(int32_t)(state >> 32) / 2147483648.0 * 0.25;
    *memory = *memory * 0.9 + white * 0.1;
    return *memory * 4;
}

static void store(uint8_t *p, enum AVSampleFormat fmt, double v)
{
    switch (fmt) {
    case AV_SAMPLE_FMT_U8:  *p = (uint8_t)lrint(v * 127 + 128); break;
    case AV_SAMPLE_FMT_S16: { int16_t s = (int16_t)lrint(v * 32767); memcpy(p, &s, 2); break; }
    case AV_SAMPLE_FMT_S32: { int32_t s = (int32_t)lrint(v * 2147483647.0); memcpy(p, &s, 4); break; }
    case AV_SAMPLE_FMT_FLT: { float s = (float)v; memcpy(p, &s, 4); break; }
    case AV_SAMPLE_FMT_DBL: memcpy(p, &v, 8); break;
    default: break;
    }
}

static void resample_case(int in_rate, int out_rate, enum AVSampleFormat in_fmt, enum AVSampleFormat out_fmt,
                          int channels, int frames)
{
    AVChannelLayout layout;
    SwrContext *swr = NULL;
    int in_bps = av_get_bytes_per_sample(in_fmt), out_bps = av_get_bytes_per_sample(out_fmt);
    int capacity = (int)((int64_t)frames * out_rate / in_rate) + 8192;
    uint8_t *in = av_malloc((size_t)frames * channels * in_bps);
    uint8_t *out = av_mallocz((size_t)capacity * channels * out_bps);
    double memory[8] = { 0 };
    int total = 0, got;
    int64_t delay;

    av_channel_layout_default(&layout, channels);
    swr_alloc_set_opts2(&swr, &layout, out_fmt, out_rate, &layout, in_fmt, in_rate, 0, NULL);
    if (swr_init(swr) < 0) {
        printf("R %d %d %s %s %d %d E\n", in_rate, out_rate, av_get_sample_fmt_name(in_fmt),
               av_get_sample_fmt_name(out_fmt), channels, frames);
        goto done;
    }
    state = 1;
    for (int f = 0; f < frames; f++)
        for (int c = 0; c < channels; c++)
            store(in + ((size_t)f * channels + c) * in_bps, in_fmt, next_sample(&memory[c]));
    {
        uint8_t *out_planes[1] = { out };
        const uint8_t *in_planes[1] = { in };
        got = swr_convert(swr, out_planes, capacity, in_planes, frames);
        total += got > 0 ? got : 0;
    }
    delay = swr_get_delay(swr, out_rate);
    do {
        uint8_t *out_planes[1] = { out + (size_t)total * channels * out_bps };
        got = swr_convert(swr, out_planes, FFMIN(4096, capacity - total), NULL, 0);
        total += got > 0 ? got : 0;
    } while (got > 0 && total < capacity);
    printf("R %d %d %s %s %d %d %lld %d ", in_rate, out_rate, av_get_sample_fmt_name(in_fmt),
           av_get_sample_fmt_name(out_fmt), channels, frames, (long long)delay, total);
    if (total == 0)
        printf("-");
    for (size_t i = 0; i < (size_t)total * channels * out_bps; i++)
        printf("%02x", out[i]);
    printf("\n");
done:
    swr_free(&swr);
    av_free(in);
    av_free(out);
}

int main(void)
{
    static const int rates[][2] = {
        { 44100, 48000 }, { 48000, 44100 }, { 8000, 44100 }, { 44100, 8000 }, { 22050, 44100 },
        { 44100, 22050 }, { 96000, 44100 }, { 16000, 48000 }, { 48000, 16000 }, { 8000, 8001 },
        { 11025, 192000 }, { 192000, 8000 },
    };
    static const enum AVSampleFormat pairs[][2] = {
        { AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16 }, { AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_DBL },
        { AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLT }, { AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBL },
        { AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_U8 }, { AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_S16 },
        { AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32 },
    };

    av_log_set_level(AV_LOG_QUIET);
    for (int r = 0; r < (int)(sizeof(rates) / sizeof(*rates)); r++)
        for (int p = 0; p < (int)(sizeof(pairs) / sizeof(*pairs)); p++)
            resample_case(rates[r][0], rates[r][1], pairs[p][0], pairs[p][1], 1, 300);
    /* Stereo, and inputs shorter than the filter. */
    resample_case(44100, 48000, AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16, 2, 300);
    resample_case(48000, 44100, AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLT, 2, 300);
    for (int n = 0; n <= 40; n += 5)
        resample_case(44100, 48000, AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBL, 1, n);
    resample_case(192000, 8000, AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_DBL, 1, 100);
    return 0;
}
