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
//   D <function> <distribution> small <count> <md5>
//   D <function> <distribution> large <count> <md5>
//                              a double function of 20000 inputs drawn
//                              from a distribution (see sample), digested
//                              in two parts: the inputs below 1e8 in
//                              magnitude (and NaNs), then the others, where
//                              glibc releases before 2.40 reduce sin, cos
//                              and tan's argument differently
//   C <function> ...           the same for sinh, cosh and tanh, which
//                              glibc computes correctly rounded since 2.44
//
// Each MD5 covers the results as float32 (or float64 for D lines)
// little-endian, in order (sinf before cosf). See zig/testing/reference/README.md for the build commands.

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

static void put_double(struct AVMD5 *md5, double v)
{
    uint64_t u;
    memcpy(&u, &v, 8);
    uint8_t b[8];
    for (int i = 0; i < 8; i++)
        b[i] = (uint8_t)(u >> (8 * i));
    av_md5_update(md5, b, 8);
}

static uint64_t xs_state;

static uint64_t xs_next(void)
{
    xs_state ^= xs_state << 13;
    xs_state ^= xs_state >> 7;
    xs_state ^= xs_state << 17;
    return xs_state;
}

static double unit(void)
{
    return (double)(xs_next() >> 11) * 0x1p-53;
}

/* The input distributions: any bit pattern, uniform in [-10, 10],
 * [-1000, 1000] and [-1, 1], near a multiple of pi/2 up to 1000 of them,
 * uniform in [-1e9, 1e9] and [-800, 800], and a power of two from 2^-60 to
 * 2^59 times [0.5, 1.5) with a random sign. */
static double sample(int dist)
{
    switch (dist) {
    case 0: {
        uint64_t u = xs_next();
        double d;
        memcpy(&d, &u, 8);
        return d;
    }
    case 1: return (unit() * 2 - 1) * 10;
    case 2: return (unit() * 2 - 1) * 1000;
    case 3: return unit() * 2 - 1;
    case 4: {
        double k = (double)((int64_t)(xs_next() % 2001) - 1000);
        return k * (M_PI / 2) + (unit() - 0.5) * 1e-6;
    }
    case 5: return (unit() * 2 - 1) * 1e9;
    case 6: return (unit() * 2 - 1) * 800;
    default: {
        double m = unit() + 0.5;
        int e = (int)(xs_next() % 120) - 60;
        return ldexp(m, e) * ((xs_next() & 1) ? -1.0 : 1.0);
    }
    }
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

    /* One-argument functions, then pow (of |x|), atan2 and hypot, whose
     * second argument comes from the distribution three places on, then
     * sinh, cosh and tanh, correctly rounded since glibc 2.44 and on C
     * lines so that an older glibc's differences stand apart. */
    static const struct {
        const char *name;
        double (*fn)(double);
        double (*fn2)(double, double);
        char kind;
    } funcs[] = {
        { "sin", sin, NULL, 'D' },     { "cos", cos, NULL, 'D' },     { "exp", exp, NULL, 'D' },
        { "exp2", exp2, NULL, 'D' },   { "atan", atan, NULL, 'D' },   { "tan", tan, NULL, 'D' },
        { "asin", asin, NULL, 'D' },   { "acos", acos, NULL, 'D' },   { "log", log, NULL, 'D' },
        { "pow", NULL, pow, 'D' },     { "atan2", NULL, atan2, 'D' }, { "hypot", NULL, hypot, 'D' },
        { "sinh", sinh, NULL, 'C' },   { "cosh", cosh, NULL, 'C' },   { "tanh", tanh, NULL, 'C' },
    };
    struct AVMD5 *large = av_md5_alloc();
    for (size_t fi = 0; fi < sizeof(funcs) / sizeof(funcs[0]); fi++)
        for (int dist = 0; dist < 8; dist++) {
            xs_state = 0x9E3779B97F4A7C15ull + 1000003ull * (fi * 8 + dist);
            av_md5_init(md5);
            av_md5_init(large);
            uint32_t n_small = 0, n_large = 0;
            for (int i = 0; i < 20000; i++) {
                double x = sample(dist);
                double y;
                if (funcs[fi].fn2) {
                    double x2 = sample((dist + 3) % 8);
                    y = funcs[fi].fn2(funcs[fi].fn2 == pow ? fabs(x) : x, x2);
                } else {
                    y = funcs[fi].fn(x);
                }
                if (fabs(x) >= 1e8) {
                    put_double(large, y);
                    n_large++;
                } else {
                    put_double(md5, y);
                    n_small++;
                }
            }
            uint8_t ds[16], dl[16];
            av_md5_final(md5, ds);
            av_md5_final(large, dl);
            printf("%c %s %d small %u ", funcs[fi].kind, funcs[fi].name, dist, n_small);
            for (int i = 0; i < 16; i++)
                printf("%02x", ds[i]);
            printf("\n%c %s %d large %u ", funcs[fi].kind, funcs[fi].name, dist, n_large);
            for (int i = 0; i < 16; i++)
                printf("%02x", dl[i]);
            printf("\n");
        }
    av_freep(&large);

    av_freep(&md5);
    return 0;
}
