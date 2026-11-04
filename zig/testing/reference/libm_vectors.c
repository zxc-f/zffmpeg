// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the libm oracle (zig/testing/vectors/libm.txt) for T28a: what the
// reference platform's exp2f, sinf and cosf (glibc, whose x86-64 variant
// with FMA runs on every verified machine) return where FFmpeg's CELT
// decoder calls them. The inputs come from integer arithmetic only, so the
// Zig test (core/libm.zig) repeats them. The lines:
//
//   E <stride> <count> <md5>   exp2f of the float with bit pattern
//                              i * stride for i below count
//   T <count> <md5>            sinf and cosf of CELT's exp_rotation angles,
//                              pi * g * g / 4 with g = len / (len +
//                              (20 - 5 * spread) * k) for len to 400,
//                              2k < len and spread 1 to 3, in that order
//   Q <stride> <count> <md5>   sinf and cosf of the float with bit pattern
//                              i * stride, every one below pi/4
//
// Each MD5 covers the results as float32 little-endian, in order (sinf
// before cosf). See zig/testing/reference/README.md for the build commands.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/md5.h"
#include "libavutil/mem.h"

static void put(struct AVMD5 *md5, float v)
{
    uint32_t u;
    memcpy(&u, &v, 4);
    uint8_t b[4] = { u, u >> 8, u >> 16, u >> 24 };
    av_md5_update(md5, b, 4);
}

static void print(const char *head, struct AVMD5 *md5)
{
    uint8_t digest[16];
    av_md5_final(md5, digest);
    printf("%s ", head);
    for (int i = 0; i < 16; i++)
        printf("%02x", digest[i]);
    printf("\n");
}

int main(void)
{
    struct AVMD5 *md5 = av_md5_alloc();
    char head[64];

    const uint32_t stride = 65537;
    av_md5_init(md5);
    for (uint32_t i = 0; i < 65536; i++) {
        float x;
        uint32_t u = i * stride;
        memcpy(&x, &u, 4);
        put(md5, exp2f(x));
    }
    snprintf(head, sizeof(head), "E %u %u", stride, 65536u);
    print(head, md5);

    av_md5_init(md5);
    uint32_t count = 0;
    for (uint32_t len = 1; len <= 400; len++)
        for (uint32_t k = 1; 2 * k < len; k++)
            for (uint32_t spread = 1; spread <= 3; spread++) {
                float gain  = (float)len / (len + (20 - 5 * spread) * k);
                float theta = M_PI * gain * gain / 4;
                put(md5, sinf(theta));
                put(md5, cosf(theta));
                count++;
            }
    snprintf(head, sizeof(head), "T %u", count);
    print(head, md5);

    const uint32_t qstride = 4099;
    av_md5_init(md5);
    count = 0;
    for (uint32_t i = 0;; i++) {
        float x;
        uint32_t u = i * qstride;
        memcpy(&x, &u, 4);
        if (!(x < (float)(M_PI / 4)))
            break;
        put(md5, sinf(x));
        put(md5, cosf(x));
        count++;
    }
    snprintf(head, sizeof(head), "Q %u %u", qstride, count);
    print(head, md5);

    av_freep(&md5);
    return 0;
}
