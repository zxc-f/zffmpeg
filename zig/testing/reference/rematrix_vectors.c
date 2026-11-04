// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T23c rematrix oracle (zig/testing/vectors/rematrix.txt) from the
// pinned FFmpeg's libswresample: the matrices swr_build_matrix2 builds. The
// lines:
//
//   M <in> <out> <clev> <slev> <lfe> <maxval> <volume> <encoding> E
//   M <in> <out> <clev> <slev> <lfe> <maxval> <volume> <encoding> <entries>
//       the input and output layouts (av_channel_layout_from_string text,
//       hex), the options as C99 hex floats (the mix levels as libswresample
//       stores them, in a float), the matrix encoding (0 none, 1 Dolby,
//       2 Dolby Pro Logic II), then E when the function fails, else the
//       nonzero coefficients as out,in=value (value a hex float) joined by
//       ";", or "-" when there are none.
//
// See zig/testing/reference/README.md for the build commands.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/channel_layout.h"
#include "libswresample/swresample.h"

#define CH_MAX 64

static void hex(const char *text)
{
    for (const unsigned char *p = (const unsigned char *)text; *p; p++)
        printf("%02x", *p);
}

static void matrix_case(const char *in_text, const char *out_text, double clev, double slev, double lfe,
                        double maxval, double volume, enum AVMatrixEncoding encoding)
{
    AVChannelLayout in = { 0 }, out = { 0 };
    static double matrix[CH_MAX * CH_MAX];
    int first = 1;

    if (av_channel_layout_from_string(&in, in_text) < 0 || av_channel_layout_from_string(&out, out_text) < 0) {
        fprintf(stderr, "bad layout %s or %s\n", in_text, out_text);
        return;
    }
    memset(matrix, 0, sizeof(matrix));
    printf("M ");
    hex(in_text);
    printf(" ");
    hex(out_text);
    printf(" %a %a %a %a %a %d ", clev, slev, lfe, maxval, volume, (int)encoding);
    if (swr_build_matrix2(&in, &out, clev, slev, lfe, maxval, volume, matrix, CH_MAX, encoding, NULL) < 0) {
        printf("E\n");
    } else {
        for (int o = 0; o < out.nb_channels; o++)
            for (int i = 0; i < in.nb_channels; i++)
                if (matrix[o * CH_MAX + i] != 0.0) {
                    printf("%s%d,%d=%a", first ? "" : ";", o, i, matrix[o * CH_MAX + i]);
                    first = 0;
                }
        if (first)
            printf("-");
        printf("\n");
    }
    av_channel_layout_uninit(&in);
    av_channel_layout_uninit(&out);
}

int main(void)
{
    /* libswresample's defaults, stored in its float options: clev and slev
     * C_30DB, lfe_mix_level 0, rematrix_volume 1. maxval is 1 for integer
     * output and INT_MAX for float output (auto_matrix). */
    const double c30 = (float)M_SQRT1_2;
    const double int_max = 2147483647.0;
    const AVChannelLayout *a, *b;
    void *oa = NULL;
    char in_name[128], out_name[128];

    av_log_set_level(AV_LOG_QUIET);

    /* Every pair of named layouts, with integer and float output. */
    while ((a = av_channel_layout_standard(&oa))) {
        void *ob = NULL;
        av_channel_layout_describe(a, in_name, sizeof(in_name));
        while ((b = av_channel_layout_standard(&ob))) {
            av_channel_layout_describe(b, out_name, sizeof(out_name));
            matrix_case(in_name, out_name, c30, c30, 0, 1.0, 1.0, AV_MATRIX_ENCODING_NONE);
            matrix_case(in_name, out_name, c30, c30, 0, int_max, 1.0, AV_MATRIX_ENCODING_NONE);
        }
    }

    /* Options on downmixes: mix levels, LFE, volume, and the matrix
     * encodings, which only change a mix into front left and right. */
    {
        static const char *ins[] = { "5.1", "5.1(side)", "7.1", "6.1", "4.0", "quad", "3.0(back)", "2.1",
                                     "5.0", "22.2", "7.1.4", "hexagonal", "6.1(back)" };
        static const char *outs[] = { "stereo", "mono", "2.1", "3.0", "quad" };
        const double levels[][3] = { { 1.0, 1.0, 1.0 }, { 0.5, 0.25, 0.75 }, { (float)0.123, (float)-0.5, (float)2.5 } };
        for (int i = 0; i < (int)(sizeof(ins) / sizeof(*ins)); i++)
            for (int o = 0; o < (int)(sizeof(outs) / sizeof(*outs)); o++) {
                for (int l = 0; l < 3; l++)
                    matrix_case(ins[i], outs[o], levels[l][0], levels[l][1], levels[l][2], 1.0, 1.0,
                                AV_MATRIX_ENCODING_NONE);
                matrix_case(ins[i], outs[o], c30, c30, 0, 1.0, 0.5, AV_MATRIX_ENCODING_NONE);
                matrix_case(ins[i], outs[o], c30, c30, 0, 1.0, -1.0, AV_MATRIX_ENCODING_NONE);
                matrix_case(ins[i], outs[o], c30, c30, 0, 1.0, -0.5, AV_MATRIX_ENCODING_NONE);
                matrix_case(ins[i], outs[o], c30, c30, 0, 2.0, 1.0, AV_MATRIX_ENCODING_NONE);
                matrix_case(ins[i], outs[o], c30, c30, 0, 1.0, 1.0, AV_MATRIX_ENCODING_DOLBY);
                matrix_case(ins[i], outs[o], c30, c30, 0, 1.0, 1.0, AV_MATRIX_ENCODING_DPLII);
            }
    }

    /* Custom orders, unused channels, a lone channel taken as mono, the
     * stereo downmix pair, user and unknown channels, and layouts the
     * builder refuses. */
    {
        static const char *layouts[] = {
            "FR+FL", "FC+FL+FR", "FL+FR+FC+LFE+SL+SR", "SR+SL+LFE+FC+FR+FL", "UNSD+FL+FR", "FL+UNSD+FR",
            "FL", "FR", "BC", "UNSD+FR", "FL+UNSD", "DL+DR", "DR+DL", "FL+FR+DL+DR", "FL+FL", "FL+FR+FL",
            "FL+FR+BC+BC", "LFE", "FL+FR+LFE+LFE", "FL+FR+USR40", "FL+FR+USR63", "UNK+UNK", "FL+UNK",
            "3 channels", "FC+BL", "FL+BL+BR", "FL+FR+SL", "FL+FR+TFL", "FL+FR+FLC", "BIL+BIR",
            "FL+FR+TBL+TBR", "FL+FR+TSL+TSR", "FL+FR+BFL+BFR", "FL+FR+LFE2", "FC+TC", "FC+BFC",
        };
        static const char *targets[] = { "mono", "stereo", "5.1", "7.1", "FR+FL", "FC+FL+FR", "downmix", "UNSD+FL+FR",
                                         "5.1.4", "22.2" };
        for (int i = 0; i < (int)(sizeof(layouts) / sizeof(*layouts)); i++)
            for (int t = 0; t < (int)(sizeof(targets) / sizeof(*targets)); t++) {
                matrix_case(layouts[i], targets[t], c30, c30, 0, 1.0, 1.0, AV_MATRIX_ENCODING_NONE);
                matrix_case(targets[t], layouts[i], c30, c30, 0, 1.0, 1.0, AV_MATRIX_ENCODING_NONE);
            }
    }
    return 0;
}
