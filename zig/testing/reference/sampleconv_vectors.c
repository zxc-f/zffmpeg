// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T23a oracle (zig/testing/vectors/sampleconv.txt) by converting
// sample patterns with the pinned FFmpeg's libswresample, the way it converts
// when only the sample format changes (stereo, the same rate, no dither): for
// every pair of the twelve sample formats, packed or planar, and every input
// pattern, the SHA-256 of the output, its planes in order without padding,
// samples little-endian. The patterns, in interleaved order (left, right):
//
//   all    u8: every value 0..255; s16: every value -32768..32767
//   lcg    s32, s64: the bytes of x = x * 6364136223846793005 +
//          1442695040888963407 (mod 2^64, x0 = 1), byte = x >> 56, 4096
//          frames, little-endian
//   unit   flt, dbl: (k - 32768) / 32768 for k = 0..65535, in [-1, 1)
//   rand   flt: (float)(int32_t)(x >> 32) * 2^-31; dbl: (double)(int64_t)x *
//          2^-63; with x from the lcg above, 4096 frames
//   wide   flt, dbl: (k - 32768) * 3 / 65536 for k = 0..65535, in [-1.5, 1.5);
//          not into s64, where C's llrint overflows
//   edge   flt, dbl: the `edge` table below (NaN, infinities, values whose
//          products overflow 32 or 64 bits, rounding ties), as doubles; flt
//          takes (float)d. C leaves lrint and llrint unspecified for some
//          of them: the result is the reference build's (notes.md
//          "Undefined C cases")
//
// zig/resample/audioconvert.zig's tests regenerate the patterns; the Zig code
// is not derived from this file. See zig/testing/reference/README.md for the
// build commands.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libavutil/sha.h"
#include "libswresample/swresample.h"

#define CHANNELS 2

static const enum AVSampleFormat formats[] = {
    AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S64,
    AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_DBL, AV_SAMPLE_FMT_U8P, AV_SAMPLE_FMT_S16P,
    AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S64P, AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_DBLP,
};

static const double edge[] = {
    0.5, -0.5, NAN, -NAN, INFINITY, -INFINITY, 65535.0, 65536.0,
    100000.0, 131072.0, -65537.0, 16777216.0, 3e9, 1e10, 1e19, -1e19,
    3e38, -3e38, 1e300, -1e300, 1.0, -1.0, 0.99999, 0.0,
    -0.0, 0.5 / 32768, 1.5 / 32768, 2.5 / 32768, -2.5 / 32768, 0.5 / 128, 1.5 / 128, -1.5 / 128,
    2147483647.5 / 32768, 4294967296.0 / 128, 1e-40, 0.9999999999999999, -0.9999999999999999, 2.0, 1e-300, -1e-300,
};
#define EDGE (int)(sizeof(edge) / sizeof(edge[0]))

static void fail(const char *what)
{
    fprintf(stderr, "sampleconv_vectors: %s failed\n", what);
    exit(1);
}

/* Writes `n` interleaved samples of the pattern into `out`, packed. */
static int pattern(const char *name, enum AVSampleFormat packed, uint8_t *out)
{
    uint64_t x = 1;
    int n = 0;
    if (!strcmp(name, "all") && packed == AV_SAMPLE_FMT_U8) {
        for (int k = 0; k < 256; k++)
            out[n++] = (uint8_t)k;
        return n;
    }
    if (!strcmp(name, "all") && packed == AV_SAMPLE_FMT_S16) {
        for (int k = 0; k < 65536; k++, n++) {
            int16_t v = (int16_t)(k - 32768);
            memcpy(out + 2 * n, &v, 2);
        }
        return n;
    }
    if (!strcmp(name, "lcg")) {
        int width = av_get_bytes_per_sample(packed);
        for (int i = 0; i < 4096 * CHANNELS * width; i++) {
            x = x * 6364136223846793005ULL + 1442695040888963407ULL;
            out[i] = (uint8_t)(x >> 56);
        }
        return 4096 * CHANNELS;
    }
    if (!strcmp(name, "edge")) {
        for (int k = 0; k < EDGE; k++, n++) {
            double d = edge[k];
            float f = (float)d;
            if (packed == AV_SAMPLE_FMT_FLT)
                memcpy(out + 4 * n, &f, 4);
            else
                memcpy(out + 8 * n, &d, 8);
        }
        return n;
    }
    for (int k = 0; k < (strcmp(name, "rand") ? 65536 : 4096 * CHANNELS); k++, n++) {
        double d;
        float f;
        if (!strcmp(name, "rand")) {
            x = x * 6364136223846793005ULL + 1442695040888963407ULL;
            f = (float)(int32_t)(x >> 32) * (1.0f / 2147483648.0f);
            d = (double)(int64_t)x * (1.0 / 9223372036854775808.0);
        } else if (!strcmp(name, "unit")) {
            f = (float)(k - 32768) / 32768.0f;
            d = (double)(k - 32768) / 32768.0;
        } else {
            f = (float)((k - 32768) * 3) / 65536.0f;
            d = (double)((k - 32768) * 3) / 65536.0;
        }
        if (packed == AV_SAMPLE_FMT_FLT)
            memcpy(out + 4 * n, &f, 4);
        else
            memcpy(out + 8 * n, &d, 8);
    }
    return n;
}

static void run(enum AVSampleFormat in_fmt, enum AVSampleFormat out_fmt, const char *name, const uint8_t *packed_in, int n)
{
    AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
    SwrContext *swr = NULL;
    int frames = n / CHANNELS;
    int in_bps = av_get_bytes_per_sample(in_fmt), out_bps = av_get_bytes_per_sample(out_fmt);
    uint8_t *in_buf = malloc((size_t)n * in_bps), *out_buf = malloc((size_t)n * out_bps);
    const uint8_t *in_planes[CHANNELS];
    uint8_t *out_planes[CHANNELS];
    struct AVSHA *sha = av_sha_alloc();
    uint8_t digest[32];

    if (!in_buf || !out_buf || !sha)
        fail("malloc");
    /* Lay the interleaved pattern out as the input format wants it. */
    if (av_sample_fmt_is_planar(in_fmt)) {
        for (int c = 0; c < CHANNELS; c++)
            for (int i = 0; i < frames; i++)
                memcpy(in_buf + ((size_t)c * frames + i) * in_bps, packed_in + ((size_t)i * CHANNELS + c) * in_bps, in_bps);
    } else {
        memcpy(in_buf, packed_in, (size_t)n * in_bps);
    }
    for (int c = 0; c < CHANNELS; c++) {
        in_planes[c] = in_buf + (av_sample_fmt_is_planar(in_fmt) ? (size_t)c * frames * in_bps : 0);
        out_planes[c] = out_buf + (av_sample_fmt_is_planar(out_fmt) ? (size_t)c * frames * out_bps : 0);
    }
    if (swr_alloc_set_opts2(&swr, &stereo, out_fmt, 8000, &stereo, in_fmt, 8000, 0, NULL) < 0 || swr_init(swr) < 0)
        fail("swr_init");
    if (swr_convert(swr, out_planes, frames, in_planes, frames) != frames)
        fail("swr_convert");
    av_sha_init(sha, 256);
    av_sha_update(sha, out_buf, (size_t)n * out_bps);
    av_sha_final(sha, digest);
    printf("%s %s %s %d ", av_get_sample_fmt_name(in_fmt), av_get_sample_fmt_name(out_fmt), name, frames);
    for (int i = 0; i < 32; i++)
        printf("%02x", digest[i]);
    printf("\n");
    swr_free(&swr);
    av_free(sha);
    free(in_buf);
    free(out_buf);
}

int main(void)
{
    static uint8_t packed_in[65536 * 8];
    int count = sizeof(formats) / sizeof(formats[0]);
    for (int i = 0; i < count; i++) {
        enum AVSampleFormat in_fmt = formats[i], packed = av_get_packed_sample_fmt(in_fmt);
        const char *names[4];
        int names_count = 0;
        if (packed == AV_SAMPLE_FMT_U8 || packed == AV_SAMPLE_FMT_S16)
            names[names_count++] = "all";
        else if (packed == AV_SAMPLE_FMT_S32 || packed == AV_SAMPLE_FMT_S64)
            names[names_count++] = "lcg";
        else {
            names[names_count++] = "unit";
            names[names_count++] = "rand";
            names[names_count++] = "wide";
            names[names_count++] = "edge";
        }
        for (int p = 0; p < names_count; p++) {
            int n = pattern(names[p], packed, packed_in);
            for (int j = 0; j < count; j++) {
                if (!strcmp(names[p], "wide") && av_get_packed_sample_fmt(formats[j]) == AV_SAMPLE_FMT_S64)
                    continue;
                run(in_fmt, formats[j], names[p], packed_in, n);
            }
        }
    }
    return 0;
}
