// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T15 oracle (zig/testing/vectors/rational.txt) from the pinned
// FFmpeg's libavutil: its rational arithmetic and timestamp helpers on a
// fixed set of inputs, extremes of int and int64_t included. The lines:
//
//   G <a> <b> <gcd>                       av_gcd
//   R <num> <den> <max> <num'> <den'> <exact>
//                                         av_reduce
//   M <op> <a/b> <c/d> <num/den>          av_mul_q, av_div_q, av_add_q,
//                                         av_sub_q (op m, d, a, s)
//   C <a/b> <c/d> <cmp>                   av_cmp_q
//   N <q> <q1> <q2> <nearer>              av_nearer_q
//   Q <double bits hex> <max> <num/den>   av_d2q of the double whose bits
//                                         are given
//   S <a> <b> <c> <rnd> <result>          av_rescale_rnd (rnd 0..3, 5, and
//                                         8192 | each for PASS_MINMAX)
//   T <ts_a> <a/b> <ts_b> <c/d> <cmp>     av_compare_ts
//   W <a> <b> <mod> <result>              av_compare_mod
//   D <in_tb> <in_ts> <fs_tb> <duration> <last> <out_tb> <result> <last'>
//                                         av_rescale_delta (last N for
//                                         AV_NOPTS_VALUE)
//   A <ts_tb> <ts> <inc_tb> <inc> <result> av_add_stable
//   X <a> <b> <add> <sub>                 av_sat_add64, av_sat_sub64
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/avutil.h"
#include "libavutil/common.h"
#include "libavutil/mathematics.h"
#include "libavutil/rational.h"

static const int64_t i64s[] = {
    0, 1, -1, 2, -2, 3, 7, -7, 10, 100, 1000, 44100, -44100, 48000, 90000,
    1000000, -1000000, 6, 12, 15, 36, 1001, 30000, 24000,
    INT32_MAX, INT32_MIN, (int64_t)INT32_MAX + 1, (int64_t)INT32_MIN - 1,
    INT64_C(1) << 32, INT64_C(1) << 33, (INT64_C(1) << 33) - 1, INT64_C(1) << 40,
    INT64_C(123456789012345), -INT64_C(987654321098765),
    INT64_MAX, INT64_MIN, INT64_MAX - 1, INT64_MIN + 1, INT64_MAX / 2, INT64_MIN / 2,
};
#define N_I64 (sizeof(i64s) / sizeof(i64s[0]))

static const AVRational qs[] = {
    { 0, 1 }, { 1, 1 }, { -1, 1 }, { 1, 2 }, { -1, 2 }, { 2, 4 }, { 1, 3 },
    { 2, 3 }, { -2, 3 }, { 1, 44100 }, { 1, 48000 }, { 1, 90000 }, { 1, 1000000 },
    { 1001, 30000 }, { 1, 25 }, { 25, 1 }, { 1, 0 }, { -1, 0 }, { 0, 0 },
    { INT_MAX, 1 }, { 1, INT_MAX }, { INT_MAX, INT_MAX - 1 }, { INT_MIN + 1, 7 },
    { 3, -5 }, { -3, -5 }, { 1000, 1 }, { 1, 1000 },
};
#define N_Q (sizeof(qs) / sizeof(qs[0]))

/* Valid time bases (positive num and den) for the timestamp helpers. */
static const AVRational tbs[] = {
    { 1, 1 }, { 1, 2 }, { 1, 3 }, { 1, 44100 }, { 1, 48000 }, { 1, 90000 },
    { 1, 1000000 }, { 1001, 30000 }, { 1, 25 }, { 25, 1 }, { 1, 8000 }, { 3, 7 },
    { INT_MAX, 1 }, { 1, INT_MAX },
};
#define N_TB (sizeof(tbs) / sizeof(tbs[0]))

static void print_ts(int64_t v)
{
    if (v == AV_NOPTS_VALUE)
        printf("N");
    else
        printf("%" PRId64, v);
}

int main(void)
{
    for (size_t i = 0; i < N_I64; i++)
        for (size_t j = 0; j < N_I64; j++) {
            int64_t a = i64s[i], b = i64s[j];
            // av_gcd's llabs is undefined for INT64_MIN.
            if (a == INT64_MIN || b == INT64_MIN)
                continue;
            printf("G %" PRId64 " %" PRId64 " %" PRId64 "\n", a, b, av_gcd(a, b));
        }

    static const int64_t maxes[] = { INT_MAX, 1000, 1 };
    for (size_t i = 0; i < N_I64; i++)
        for (size_t j = 0; j < N_I64; j++)
            for (size_t k = 0; k < sizeof(maxes) / sizeof(maxes[0]); k++) {
                int64_t num = i64s[i], den = i64s[j];
                // FFABS and av_gcd are undefined at INT64_MIN.
                if (num == INT64_MIN || den == INT64_MIN)
                    continue;
                int n, d;
                int exact = av_reduce(&n, &d, num, den, maxes[k]);
                printf("R %" PRId64 " %" PRId64 " %" PRId64 " %d %d %d\n", num, den, maxes[k], n, d, exact);
            }

    for (size_t i = 0; i < N_Q; i++)
        for (size_t j = 0; j < N_Q; j++) {
            AVRational b = qs[i], c = qs[j];
            AVRational r;
            r = av_mul_q(b, c);
            printf("M m %d/%d %d/%d %d/%d\n", b.num, b.den, c.num, c.den, r.num, r.den);
            r = av_div_q(b, c);
            printf("M d %d/%d %d/%d %d/%d\n", b.num, b.den, c.num, c.den, r.num, r.den);
            r = av_add_q(b, c);
            printf("M a %d/%d %d/%d %d/%d\n", b.num, b.den, c.num, c.den, r.num, r.den);
            r = av_sub_q(b, c);
            printf("M s %d/%d %d/%d %d/%d\n", b.num, b.den, c.num, c.den, r.num, r.den);
            printf("C %d/%d %d/%d %d\n", b.num, b.den, c.num, c.den, av_cmp_q(b, c));
        }

    for (size_t i = 0; i < N_Q; i++)
        for (size_t j = 0; j < N_Q; j += 2)
            for (size_t k = 1; k < N_Q; k += 2) {
                AVRational q = qs[i], q1 = qs[j], q2 = qs[k];
                // av_nearer_q needs positive denominators.
                if (q.den <= 0 || q1.den <= 0 || q2.den <= 0)
                    continue;
                printf("N %d/%d %d/%d %d/%d %d\n", q.num, q.den, q1.num, q1.den, q2.num, q2.den,
                       av_nearer_q(q, q1, q2));
            }

    static const double ds[] = {
        0.0, -0.0, 1.0, -1.0, 0.5, 1.0 / 3.0, -2.0 / 3.0, 29.97, 30000.0 / 1001.0, 23.976,
        44100.0, 1e-9, 1e-12, 3.141592653589793, 2147483647.0, 2147483650.0, 2147483651.0,
        -2147483650.0, 1e300, -1e300, 0.1, 0.2, 59.94, 1.5e-5, 123456.789,
    };
    static const int dmax[] = { INT_MAX, 1001, 100, 1, 65535 };
    for (size_t i = 0; i < sizeof(ds) / sizeof(ds[0]); i++)
        for (size_t k = 0; k < sizeof(dmax) / sizeof(dmax[0]); k++) {
            uint64_t bits;
            memcpy(&bits, &ds[i], 8);
            AVRational r = av_d2q(ds[i], dmax[k]);
            printf("Q %016" PRIx64 " %d %d/%d\n", bits, dmax[k], r.num, r.den);
        }
    {
        // Infinities and NaN.
        static const double specials[] = { INFINITY, -INFINITY, NAN };
        for (size_t i = 0; i < 3; i++) {
            uint64_t bits;
            memcpy(&bits, &specials[i], 8);
            AVRational r = av_d2q(specials[i], INT_MAX);
            printf("Q %016" PRIx64 " %d %d/%d\n", bits, INT_MAX, r.num, r.den);
        }
    }

    static const int rnds[] = { AV_ROUND_ZERO, AV_ROUND_INF, AV_ROUND_DOWN, AV_ROUND_UP, AV_ROUND_NEAR_INF };
    // Every value for a; for b and c, the sizes that take each of
    // av_rescale_rnd's three paths.
    static const int64_t factors[] = {
        0, 1, 3, 1000, 44100, INT32_MAX, INT64_C(1) << 32, INT64_C(1) << 40, INT64_MAX,
    };
    for (size_t i = 0; i < N_I64; i++)
        for (size_t j = 0; j < sizeof(factors) / sizeof(factors[0]); j++)
            for (size_t k = 1; k < sizeof(factors) / sizeof(factors[0]); k++) {
                int64_t a = i64s[i], b = factors[j], c = factors[k];
                // AV_ROUND_PASS_MINMAX only changes the extremes.
                int passes = (a == INT64_MIN || a == INT64_MAX) ? 2 : 1;
                for (size_t r = 0; r < 5; r++)
                    for (int pass = 0; pass < passes; pass++) {
                        int rnd = rnds[r] | (pass ? AV_ROUND_PASS_MINMAX : 0);
                        printf("S %" PRId64 " %" PRId64 " %" PRId64 " %d %" PRId64 "\n", a, b, c, rnd,
                               av_rescale_rnd(a, b, c, rnd));
                    }
            }

    for (size_t i = 0; i < N_I64; i += 2)
        for (size_t j = 0; j < N_TB; j += 2)
            for (size_t k = 0; k < N_I64; k += 4)
                for (size_t l = 1; l < N_TB; l += 2) {
                    int64_t a = i64s[i], b = i64s[k];
                    // FFABS64U is defined at INT64_MIN, but the products are
                    // not: skip the values av_compare_ts cannot take.
                    if (a == INT64_MIN || b == INT64_MIN)
                        continue;
                    printf("T %" PRId64 " %d/%d %" PRId64 " %d/%d %d\n", a, tbs[j].num, tbs[j].den, b,
                           tbs[l].num, tbs[l].den, av_compare_ts(a, tbs[j], b, tbs[l]));
                }

    static const uint64_t mods[] = { 1ULL << 33, 1ULL << 32, 1ULL << 63, 2, 1 };
    for (size_t i = 0; i < N_I64; i++)
        for (size_t j = 0; j < N_I64; j += 2)
            for (size_t k = 0; k < sizeof(mods) / sizeof(mods[0]); k++)
                printf("W %" PRId64 " %" PRId64 " %" PRIu64 " %" PRId64 "\n", i64s[i], i64s[j], mods[k],
                       av_compare_mod(i64s[i], i64s[j], mods[k]));

    {
        // av_rescale_delta as an audio decoder's timestamps use it: in_tb
        // and out_tb, the sample rate's fs_tb, frame durations in samples,
        // and the running `last`.
        static const AVRational in_tbs[] = { { 1, 1000 }, { 1, 90000 }, { 1, 44100 }, { 1, 48000 }, { 1, 1000000 } };
        static const AVRational fs_tbs[] = { { 1, 44100 }, { 1, 48000 }, { 1, 8000 } };
        static const AVRational out_tbs[] = { { 1, 44100 }, { 1, 1000 }, { 1, 90000 } };
        static const int64_t starts[] = { 0, 23, -23, 90000, -1000000 };
        static const int durations[] = { 0, 1024, 1152, 441 };
        for (size_t a = 0; a < 5; a++)
            for (size_t b = 0; b < 3; b++)
                for (size_t c = 0; c < 3; c++)
                    for (size_t d = 0; d < 5; d++)
                        for (size_t e = 0; e < 4; e++) {
                            int64_t last = AV_NOPTS_VALUE;
                            int64_t ts = starts[d];
                            // A run of frames whose input timestamps are
                            // rounded, as a container's are.
                            for (int f = 0; f < 6; f++) {
                                int64_t before = last;
                                int64_t r = av_rescale_delta(in_tbs[a], ts, fs_tbs[b], durations[e], &last, out_tbs[c]);
                                printf("D %d/%d %" PRId64 " %d/%d %d ", in_tbs[a].num, in_tbs[a].den, ts,
                                       fs_tbs[b].num, fs_tbs[b].den, durations[e]);
                                print_ts(before);
                                printf(" %d/%d %" PRId64 " ", out_tbs[c].num, out_tbs[c].den, r);
                                print_ts(last);
                                printf("\n");
                                ts += av_rescale_q(durations[e], fs_tbs[b], in_tbs[a]) + (f & 1);
                            }
                        }
    }

    static const int64_t incs[] = { 0, 1, 2, 7, 1000, 44100, INT32_MAX };
    for (size_t i = 0; i < N_TB; i += 2)
        for (size_t j = 0; j < N_I64; j += 2)
            for (size_t k = 1; k < N_TB; k += 2)
                for (size_t l = 0; l < sizeof(incs) / sizeof(incs[0]); l++) {
                    int64_t ts = i64s[j], inc = incs[l];
                    // av_add_stable's products overflow for these.
                    if (inc < 0 || inc > INT_MAX || ts == INT64_MIN)
                        continue;
                    printf("A %d/%d %" PRId64 " %d/%d %" PRId64 " %" PRId64 "\n", tbs[i].num, tbs[i].den, ts,
                           tbs[k].num, tbs[k].den, inc, av_add_stable(tbs[i], ts, tbs[k], inc));
                }

    for (size_t i = 0; i < N_I64; i++)
        for (size_t j = 0; j < N_I64; j++)
            printf("X %" PRId64 " %" PRId64 " %" PRId64 " %" PRId64 "\n", i64s[i], i64s[j],
                   av_sat_add64(i64s[i], i64s[j]), av_sat_sub64(i64s[i], i64s[j]));
    return 0;
}
