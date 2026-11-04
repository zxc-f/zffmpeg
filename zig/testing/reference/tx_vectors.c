// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T27c transform oracle (zig/testing/vectors/tx.txt): what the
// pinned FFmpeg's libavutil float FFT and MDCT (av_tx_init with
// AV_TX_FLOAT_FFT and AV_TX_FLOAT_MDCT, out of place, as FFmpeg's decoders
// call them) make of deterministic inputs. The reference build has no x86
// assembly, so these are its C codelets. The inputs come from integer
// arithmetic only (see input_value), so the Zig test makes the same ones.
// The lines:
//
//   T <type> <len> <inv> <scale>  a transform: fft or mdct, its length (an
//                                 MDCT's coefficient count), 1 for the
//                                 inverse, and the MDCT's scale (%a)
//   C <name> <len>                each codelet of av_tx_init's tree, depth
//                                 first, without the _float_c suffix
//   O <count> <md5> <first>       the output: its float count, the MD5 of
//                                 its bytes (little-endian), and its first
//                                 four values (%a)
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/log.h"
#include "libavutil/md5.h"
#include "libavutil/mem.h"
#include "libavutil/tx.h"

/* An input value in [-1, 1): 16 bits of a linear congruential sequence,
 * exact in a float. */
static float input_value(uint32_t i, uint32_t lane)
{
    uint32_t x = i * 1103515245u + 12345u + lane * 2654435761u;
    return (float)((x >> 8) & 0xffff) / 32768.0f - 1.0f;
}

/* The tree av_tx_init logs at AV_LOG_DEBUG: one codelet a line. */
static void log_tree(void *avcl, int level, const char *fmt, va_list vl)
{
    if (level != AV_LOG_DEBUG)
        return;
    char line[1024];
    vsnprintf(line, sizeof(line), fmt, vl);
    const char *name = strstr(line, "_float_c");
    if (!name)
        return;
    const char *start = name;
    while (start > line && start[-1] != ' ')
        start--;
    const char *len = strstr(line, "len: ");
    if (!len)
        return;
    printf("C %.*s %d\n", (int)(name - start), start, atoi(len + 5));
}

static void print_output(const float *out, int count)
{
    uint8_t digest[16];
    av_md5_sum(digest, (const uint8_t *)out, count * (int)sizeof(float));
    printf("O %d ", count);
    for (int i = 0; i < 16; i++)
        printf("%02x", digest[i]);
    for (int i = 0; i < 4 && i < count; i++)
        printf(" %a", out[i]);
    printf("\n");
}

static void run(enum AVTXType type, int len, int inv, float scale)
{
    const int mdct = type == AV_TX_FLOAT_MDCT;
    printf("T %s %d %d %a\n", mdct ? "mdct" : "fft", len, inv, mdct ? scale : 1.0f);
    AVTXContext *ctx = NULL;
    av_tx_fn fn;
    int ret = av_tx_init(&ctx, &fn, type, inv, len, mdct ? &scale : NULL, 0);
    if (ret < 0) {
        printf("E %d\n", ret);
        return;
    }
    /* An FFT takes and gives len complex values; an inverse MDCT takes len
     * coefficients and gives len samples, a forward one 2 * len samples to
     * len coefficients. */
    int in_count = mdct ? (inv ? len : 2 * len) : 2 * len;
    int out_count = mdct ? len : 2 * len;
    float *in = av_malloc(in_count * sizeof(float));
    float *out = av_malloc(out_count * sizeof(float));
    for (int i = 0; i < in_count; i++)
        in[i] = input_value(i, (uint32_t)len * 2 + inv);
    fn(ctx, out, in, mdct ? sizeof(float) : 2 * sizeof(float));
    print_output(out, out_count);
    av_free(in);
    av_free(out);
    av_tx_uninit(&ctx);
}

int main(void)
{
    av_log_set_level(AV_LOG_DEBUG);
    av_log_set_callback(log_tree);
    for (int len = 2; len <= 131072; len *= 2)
        for (int inv = 0; inv < 2; inv++)
            run(AV_TX_FLOAT_FFT, len, inv, 1.0f);
    /* Vorbis' inverse MDCTs take blocksize / 2 coefficients (32 to 4096)
     * with scale -1; the others are what AAC and Opus will ask for. */
    const float scales[] = { 1.0f, -1.0f, 1.0f / 32768.0f, -2.0f };
    for (int len = 4; len <= 16384; len *= 2)
        for (int inv = 0; inv < 2; inv++)
            for (int s = 0; s < 4; s++)
                run(AV_TX_FLOAT_MDCT, len, inv, scales[s]);
    return 0;
}
