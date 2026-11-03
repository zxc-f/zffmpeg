// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T23a dither oracle (zig/testing/vectors/dither.txt) by
// converting sample patterns with the pinned FFmpeg's libswresample and its
// dither_method, dither_scale and output_sample_bits options: for each case,
// the SHA-256 of the output, samples little-endian, of 276005 stereo frames
// (the same rate) converted in calls of either 1000, 70000, 5, 65000 and
// 140000 frames ("mixed": the noise buffer grows and restarts) or a fixed
// size, the last call shorter. The input, interleaved:
//
//   flt  (float)(int32_t)(x >> 32) * 2^-31
//   dbl  (double)(int64_t)x * 2^-63
//   s16, s32, s64  the top bits of x: (int16_t)(x >> 48), (int32_t)(x >> 32),
//        (int64_t)x
//
// with x = x * 6364136223846793005 + 1442695040888963407 (mod 2^64, x0 = 1)
// stepped once per sample. zig/resample/dither.zig's tests regenerate the
// input; the Zig code is not derived from this file. See
// zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/channel_layout.h"
#include "libavutil/macros.h"
#include "libavutil/opt.h"
#include "libavutil/samplefmt.h"
#include "libavutil/sha.h"
#include "libswresample/swresample.h"

#define CHANNELS 2

static const int mixed[] = {1000, 70000, 5, 65000, 140000};
#define MIXED (int)(sizeof(mixed) / sizeof(mixed[0]))
#define TOTAL 276005

static const struct { const char *name; int value; } methods[] = {
    {"rectangular", SWR_DITHER_RECTANGULAR},
    {"triangular", SWR_DITHER_TRIANGULAR},
    {"triangular_hp", SWR_DITHER_TRIANGULAR_HIGHPASS},
    {"lipshitz", SWR_DITHER_NS_LIPSHITZ},
    {"f_weighted", SWR_DITHER_NS_F_WEIGHTED},
    {"modified_e_weighted", SWR_DITHER_NS_MODIFIED_E_WEIGHTED},
    {"improved_e_weighted", SWR_DITHER_NS_IMPROVED_E_WEIGHTED},
    {"shibata", SWR_DITHER_NS_SHIBATA},
    {"low_shibata", SWR_DITHER_NS_LOW_SHIBATA},
    {"high_shibata", SWR_DITHER_NS_HIGH_SHIBATA},
};
#define METHODS (int)(sizeof(methods) / sizeof(methods[0]))

static void fail(const char *what)
{
    fprintf(stderr, "dither_vectors: %s failed\n", what);
    exit(1);
}

/* The interleaved input of `frames` frames, packed. */
static void input(enum AVSampleFormat packed, uint8_t *out, int frames)
{
    uint64_t x = 1;
    for (int i = 0; i < frames * CHANNELS; i++) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        switch (packed) {
        case AV_SAMPLE_FMT_FLT: { float f = (float)(int32_t)(x >> 32) * (1.0f / 2147483648.0f); memcpy(out + 4 * i, &f, 4); break; }
        case AV_SAMPLE_FMT_DBL: { double d = (double)(int64_t)x * (1.0 / 9223372036854775808.0); memcpy(out + 8 * i, &d, 8); break; }
        case AV_SAMPLE_FMT_S16: { int16_t v = (int16_t)(x >> 48); memcpy(out + 2 * i, &v, 2); break; }
        case AV_SAMPLE_FMT_S32: { int32_t v = (int32_t)(x >> 32); memcpy(out + 4 * i, &v, 4); break; }
        case AV_SAMPLE_FMT_S64: { int64_t v = (int64_t)x; memcpy(out + 8 * i, &v, 8); break; }
        default: fail("input format");
        }
    }
}

/* One case; `call` 0 is the mixed calls, else the fixed call size. */
static void run(enum AVSampleFormat in_fmt, enum AVSampleFormat out_fmt, int rate, int method, const char *method_name, double scale, int bits, int call)
{
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    SwrContext *swr = NULL;
    int total = TOTAL, in_bps = av_get_bytes_per_sample(in_fmt), out_bps = av_get_bytes_per_sample(out_fmt);
    uint8_t *packed = malloc((size_t)total * CHANNELS * in_bps);
    uint8_t *chunk_in = malloc((size_t)total * CHANNELS * in_bps);
    uint8_t *chunk_out = malloc((size_t)total * CHANNELS * out_bps);
    struct AVSHA *sha = av_sha_alloc();
    uint8_t digest[32];
    if (!packed || !chunk_in || !chunk_out || !sha)
        fail("malloc");
    input(av_get_packed_sample_fmt(in_fmt), packed, total);
    if (swr_alloc_set_opts2(&swr, &stereo, out_fmt, rate, &stereo, in_fmt, rate, 0, NULL) < 0)
        fail("swr_alloc_set_opts2");
    if (av_opt_set_int(swr, "dither_method", method, 0) < 0 || av_opt_set_double(swr, "dither_scale", scale, 0) < 0 ||
        av_opt_set_int(swr, "output_sample_bits", bits, 0) < 0)
        fail("av_opt_set");
    if (swr_init(swr) < 0)
        fail("swr_init");
    av_sha_init(sha, 256);
    int done = 0;
    for (int c = 0; done < total; c++) {
        int n = call ? FFMIN(call, total - done) : mixed[c];
        const uint8_t *in_planes[CHANNELS];
        uint8_t *out_planes[CHANNELS];
        /* This call's frames, as the input format lays them out. */
        for (int ch = 0; ch < CHANNELS; ch++) {
            if (av_sample_fmt_is_planar(in_fmt)) {
                for (int i = 0; i < n; i++)
                    memcpy(chunk_in + ((size_t)ch * n + i) * in_bps, packed + ((size_t)(done + i) * CHANNELS + ch) * in_bps, in_bps);
                in_planes[ch] = chunk_in + (size_t)ch * n * in_bps;
            } else {
                in_planes[ch] = packed + (size_t)done * CHANNELS * in_bps;
            }
            out_planes[ch] = chunk_out + (av_sample_fmt_is_planar(out_fmt) ? (size_t)ch * n * out_bps : 0);
        }
        if (swr_convert(swr, out_planes, n, in_planes, n) != n)
            fail("swr_convert");
        av_sha_update(sha, chunk_out, (size_t)n * CHANNELS * out_bps);
        done += n;
    }
    av_sha_final(sha, digest);
    printf("%s %s %d %s %g %d ", av_get_sample_fmt_name(in_fmt), av_get_sample_fmt_name(out_fmt), rate, method_name, scale, bits);
    if (call)
        printf("%d ", call);
    else
        printf("mixed ");
    for (int i = 0; i < 32; i++)
        printf("%02x", digest[i]);
    printf("\n");
    swr_free(&swr);
    av_free(sha);
    free(packed);
    free(chunk_in);
    free(chunk_out);
}

int main(void)
{
    static const struct { enum AVSampleFormat in, out; int rate; } pairs[] = {
        {AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, 44100},
        {AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, 48000},
        {AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_S16, 44100},
        {AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S16, 44100},
        {AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_U8, 44100},
        {AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_U8, 46000},
        {AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S32, 44100},
        {AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_S16P, 8000},
        {AV_SAMPLE_FMT_S64, AV_SAMPLE_FMT_S16, 22050},
        {AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_U8, 37800},
    };
    for (int p = 0; p < (int)(sizeof(pairs) / sizeof(pairs[0])); p++)
        for (int m = 0; m < METHODS; m++)
            run(pairs[p].in, pairs[p].out, pairs[p].rate, methods[m].value, methods[m].name, 1, 0, 0);
    run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, 44100, SWR_DITHER_TRIANGULAR, "triangular", 0.5, 0, 0);
    run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, 44100, SWR_DITHER_NS_SHIBATA, "shibata", 2, 0, 0);
    /* FFmpeg's command line sets output_sample_bits 24 for a 24-bit encoder. */
    for (int m = 0; m < METHODS; m++) {
        run(AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32, 44100, methods[m].value, methods[m].name, 1, 24, 0);
        run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S32, 48000, methods[m].value, methods[m].name, 1, 24, 0);
    }
    run(AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_S32, 44100, SWR_DITHER_TRIANGULAR, "triangular", 1, 24, 0);
    run(AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P, 44100, SWR_DITHER_TRIANGULAR, "triangular", 1, 24, 0);
    /* No dither: the plain conversion. */
    run(AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S32, 44100, SWR_DITHER_TRIANGULAR, "triangular", 1, 24, 0);
    run(AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P, 44100, SWR_DITHER_TRIANGULAR, "triangular", 1, 0, 0);
    run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_DBL, 44100, SWR_DITHER_TRIANGULAR, "triangular", 1, 0, 0);
    run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, 44100, SWR_DITHER_TRIANGULAR, "triangular", 0, 0, 0);
    /* Fixed call sizes, as the demuxers' packets make them. */
    run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, 44100, SWR_DITHER_TRIANGULAR, "triangular", 1, 0, 682);
    run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_S16, 44100, SWR_DITHER_NS_SHIBATA, "shibata", 1, 0, 682);
    run(AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S16, 44100, SWR_DITHER_TRIANGULAR_HIGHPASS, "triangular_hp", 1, 0, 4096);
    run(AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_U8, 44100, SWR_DITHER_RECTANGULAR, "rectangular", 1, 0, 100000);
    run(AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_U8, 8000, SWR_DITHER_TRIANGULAR, "triangular", 1, 0, 455);
    return 0;
}
