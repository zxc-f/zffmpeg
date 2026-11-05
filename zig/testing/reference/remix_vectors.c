// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T23c remix oracle (zig/testing/vectors/remix.txt) from the
// pinned FFmpeg's libswresample: swr_convert with a channel layout change and
// no resampling, as FFmpeg's command line runs it for -ac, on generated
// input. The lines:
//
//   X <in layout> <out layout> <in fmt> <out fmt> <frames> <dither> <hash>
//       the layouts (av_channel_layout_from_string text, hex), the sample
//       format names, the frame count, the dither method (0 none, else
//       SwrDitherType) and the FNV-1a 64-bit hash of the output's bytes,
//       planes one after another for a planar format, in hex. The input is
//       the generator below, sample by sample in interleaved order.
//   C <in layout> <out layout> <in fmt> <out fmt> <frames> <matrix> <hash>
//       the same with a custom matrix set by swr_set_matrix (as the pan
//       filter sets one): <matrix> is the nonzero coefficients as
//       out,in=value (a C99 hex float, or nan) joined by ";". Huge and NaN
//       coefficients make the s16 path's lrintf leave int, which the
//       reference build narrows to the low 32 bits (notes.md "Undefined C
//       cases").
//
// The input's samples come from a 64-bit linear congruential generator,
// state = state * 6364136223846793005 + 1442695040888963407 from 1, one
// step per sample: u8 is the top 8 bits, s16 the top 16 and s32 the top 32
// as signed, s64 the state as signed, and flt and dbl the top 32 bits as a
// signed integer times 1.25 / 2^31 (in double, then rounded to float for
// flt), so floats reach past full scale. See zig/testing/reference/README.md
// for the build commands.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/channel_layout.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/samplefmt.h"
#include "libswresample/swresample.h"

static uint64_t state;

static uint64_t next(void)
{
    state = state * 6364136223846793005ULL + 1442695040888963407ULL;
    return state;
}

static void fill(uint8_t *p, enum AVSampleFormat fmt)
{
    uint64_t v = next();
    switch (av_get_packed_sample_fmt(fmt)) {
    case AV_SAMPLE_FMT_U8:  *p = (uint8_t)(v >> 56); break;
    case AV_SAMPLE_FMT_S16: { int16_t s = (int16_t)(v >> 48); memcpy(p, &s, 2); break; }
    case AV_SAMPLE_FMT_S32: { int32_t s = (int32_t)(v >> 32); memcpy(p, &s, 4); break; }
    case AV_SAMPLE_FMT_S64: { int64_t s = (int64_t)v; memcpy(p, &s, 8); break; }
    case AV_SAMPLE_FMT_FLT: { float s = (float)((double)(int32_t)(v >> 32) * 1.25 / 2147483648.0); memcpy(p, &s, 4); break; }
    case AV_SAMPLE_FMT_DBL: { double s = (double)(int32_t)(v >> 32) * 1.25 / 2147483648.0; memcpy(p, &s, 8); break; }
    default: break;
    }
}

static void hexstr(const char *text)
{
    for (const unsigned char *p = (const unsigned char *)text; *p; p++)
        printf("%02x", *p);
}

struct coeff { int out, in; double value; };

static void run_case(const char *in_text, const char *out_text, enum AVSampleFormat in_fmt,
                     enum AVSampleFormat out_fmt, int frames, int dither,
                     const struct coeff *coeffs, int ncoeffs)
{
    AVChannelLayout in = { 0 }, out = { 0 };
    SwrContext *swr = NULL;
    uint8_t *in_data[64] = { 0 }, *out_data[64] = { 0 };
    int in_bps = av_get_bytes_per_sample(in_fmt), out_bps = av_get_bytes_per_sample(out_fmt);
    int in_planes, out_planes, got;
    uint64_t hash = 0xcbf29ce484222325ULL;

    if (av_channel_layout_from_string(&in, in_text) < 0 || av_channel_layout_from_string(&out, out_text) < 0)
        return;
    in_planes = av_sample_fmt_is_planar(in_fmt) ? in.nb_channels : 1;
    out_planes = av_sample_fmt_is_planar(out_fmt) ? out.nb_channels : 1;
    if (swr_alloc_set_opts2(&swr, &out, out_fmt, 8000, &in, in_fmt, 8000, 0, NULL) < 0)
        return;
    if (dither)
        av_opt_set_int(swr, "dither_method", dither, 0);
    printf(coeffs ? "C " : "X ");
    hexstr(in_text);
    printf(" ");
    hexstr(out_text);
    printf(" %s %s %d ", av_get_sample_fmt_name(in_fmt), av_get_sample_fmt_name(out_fmt), frames);
    if (coeffs) {
        static double matrix[64 * 64];
        memset(matrix, 0, sizeof(matrix));
        for (int k = 0; k < ncoeffs; k++) {
            matrix[coeffs[k].out * 64 + coeffs[k].in] = coeffs[k].value;
            printf("%s%d,%d=%a", k ? ";" : "", coeffs[k].out, coeffs[k].in, coeffs[k].value);
        }
        printf(" ");
        if (swr_set_matrix(swr, matrix, 64) < 0) {
            printf("E\n");
            goto done;
        }
    } else {
        printf("%d ", dither);
    }
    if (swr_init(swr) < 0) {
        printf("E\n");
        goto done;
    }
    state = 1;
    for (int p = 0; p < in_planes; p++)
        in_data[p] = av_malloc((size_t)frames * in.nb_channels * in_bps);
    for (int p = 0; p < out_planes; p++)
        out_data[p] = av_mallocz((size_t)frames * out.nb_channels * out_bps);
    for (int f = 0; f < frames; f++)
        for (int c = 0; c < in.nb_channels; c++) {
            uint8_t *dst = in_planes > 1 ? in_data[c] + (size_t)f * in_bps
                                         : in_data[0] + ((size_t)f * in.nb_channels + c) * in_bps;
            fill(dst, in_fmt);
        }
    got = swr_convert(swr, out_data, frames, (const uint8_t **)in_data, frames);
    if (got != frames) {
        printf("E\n");
        goto done;
    }
    for (int p = 0; p < out_planes; p++) {
        size_t len = (size_t)frames * out_bps * (out_planes > 1 ? 1 : out.nb_channels);
        for (size_t i = 0; i < len; i++) {
            hash ^= out_data[p][i];
            hash *= 0x100000001b3ULL;
        }
    }
    printf("%016llx\n", (unsigned long long)hash);
done:
    for (int p = 0; p < 64; p++) {
        av_free(in_data[p]);
        av_free(out_data[p]);
    }
    swr_free(&swr);
    av_channel_layout_uninit(&in);
    av_channel_layout_uninit(&out);
}

static void remix_case(const char *in_text, const char *out_text, enum AVSampleFormat in_fmt,
                       enum AVSampleFormat out_fmt, int frames, int dither)
{
    run_case(in_text, out_text, in_fmt, out_fmt, frames, dither, NULL, 0);
}

int main(void)
{
    static const char *pairs[][2] = {
        { "5.1", "stereo" }, { "5.1(side)", "stereo" }, { "7.1", "stereo" }, { "5.1", "mono" },
        { "stereo", "mono" }, { "mono", "stereo" }, { "stereo", "5.1" }, { "quad", "stereo" },
        { "3.0", "stereo" }, { "2.1", "stereo" }, { "7.1", "5.1" }, { "5.1", "7.1" }, { "6.1", "stereo" },
        { "4.0", "mono" }, { "22.2", "stereo" }, { "7.1.4", "5.1" }, { "FR+FL", "stereo" },
        { "FC+FL+FR", "stereo" }, { "hexagonal", "quad" }, { "stereo", "FR+FL" }, { "5.1", "FL+FR+FC" },
        { "7.1(wide)", "stereo" }, { "octagonal", "5.1(side)" }, { "5.0", "stereo" }, { "3.1", "mono" },
    };
    static const enum AVSampleFormat fmts[] = {
        AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_DBL,
        AV_SAMPLE_FMT_S64, AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_FLTP,
    };
    const int nfmt = sizeof(fmts) / sizeof(*fmts);

    av_log_set_level(AV_LOG_QUIET);
    for (int p = 0; p < (int)(sizeof(pairs) / sizeof(*pairs)); p++)
        for (int i = 0; i < nfmt; i++)
            for (int o = 0; o < nfmt; o++)
                remix_case(pairs[p][0], pairs[p][1], fmts[i], fmts[o], 300, 0);
    /* Dither after the mix: triangular and a shaping method, to s16 and u8. */
    for (int p = 0; p < 8; p++)
        for (int i = 0; i < nfmt; i++) {
            remix_case(pairs[p][0], pairs[p][1], fmts[i], AV_SAMPLE_FMT_S16, 300, SWR_DITHER_TRIANGULAR);
            remix_case(pairs[p][0], pairs[p][1], fmts[i], AV_SAMPLE_FMT_U8, 300, SWR_DITHER_TRIANGULAR_HIGHPASS);
            remix_case(pairs[p][0], pairs[p][1], fmts[i], AV_SAMPLE_FMT_S16, 300, SWR_DITHER_NS_SHIBATA);
        }
    /* Custom matrices, as pan sets them, with coefficients whose s16 integer
       form (lrintf(c * 32768)) leaves int, and NaN. */
    {
        static const struct coeff huge[] = { { 0, 0, 1e5 }, { 0, 1, 0.5 } };
        static const struct coeff negative[] = { { 0, 0, -1e5 }, { 0, 1, 0.25 } };
        static const struct coeff nan_gain[] = { { 0, 0, NAN }, { 0, 1, 0.5 } };
        static const struct coeff wrap_sum[] = { { 0, 0, 70000 }, { 0, 1, 70000 }, { 1, 1, 1 } };
        static const struct coeff many[] = { { 0, 0, 1e5 }, { 0, 1, 0.5 }, { 0, 2, -3e4 }, { 0, 3, 2 }, { 0, 4, NAN }, { 0, 5, 1 } };
        static const struct { const char *in, *out; const struct coeff *c; int n; } customs[] = {
            { "stereo", "mono", huge, 2 }, { "stereo", "mono", negative, 2 }, { "stereo", "mono", nan_gain, 2 },
            { "stereo", "stereo", wrap_sum, 3 }, { "5.1", "mono", many, 6 },
        };
        static const enum AVSampleFormat custom_fmts[] = {
            AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_FLT,
        };
        for (int c = 0; c < (int)(sizeof(customs) / sizeof(*customs)); c++)
            for (int i = 0; i < 4; i++)
                for (int o = 0; o < 4; o++)
                    run_case(customs[c].in, customs[c].out, custom_fmts[i], custom_fmts[o], 300, 0, customs[c].c, customs[c].n);
    }
    return 0;
}
