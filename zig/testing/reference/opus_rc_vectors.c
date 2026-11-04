// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T28a range decoder oracle (zig/testing/vectors/opus_rc.txt):
// what the pinned FFmpeg's Opus range decoder (libavcodec/opus/rc.c, the
// ff_opus_rc_dec_* functions) reads from generated frames through a
// generated sequence of operations of every kind: CDF symbols, log-scaled
// bits, uniform, stepped and triangular integers, Laplace values, raw bits
// from the frame's end, and the bit counts. The frames and the operations
// come from integer arithmetic only (see next), so the Zig test repeats
// them. rc.h is not installed, so the decoder's struct (with get_bits.h's
// GetBitContext) and its prototypes are restated here, as at the pinned
// revision. The lines:
//
//   R <seed> <size> <ops> <md5> <range> <value> <total_bits> <tell> <tell_frac>
//                          a case: the generator's seed, the frame's size,
//                          the operation count, the MD5 of every result
//                          (int32 little-endian, in order) and the decoder's
//                          state after them
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/md5.h"

typedef struct GetBitContext {
    const uint8_t *buffer;
    int index;
    int size_in_bits;
    int size_in_bits_plus8;
} GetBitContext;

typedef struct RawBitsContext {
    const uint8_t *position;
    uint32_t bytes;
    uint32_t cachelen;
    uint32_t cacheval;
} RawBitsContext;

typedef struct OpusRangeCoder {
    GetBitContext gb;
    RawBitsContext rb;
    uint32_t range;
    uint32_t value;
    uint32_t total_bits;
    uint8_t encoder_state[2048]; /* the encoder's fields, unused here */
} OpusRangeCoder;

uint32_t ff_opus_rc_dec_cdf(OpusRangeCoder *rc, const uint16_t *cdf);
uint32_t ff_opus_rc_dec_log(OpusRangeCoder *rc, uint32_t bits);
uint32_t ff_opus_rc_dec_uint_step(OpusRangeCoder *rc, int k0);
uint32_t ff_opus_rc_dec_uint_tri(OpusRangeCoder *rc, int qn);
uint32_t ff_opus_rc_dec_uint(OpusRangeCoder *rc, uint32_t size);
uint32_t ff_opus_rc_get_raw(OpusRangeCoder *rc, uint32_t count);
int ff_opus_rc_dec_laplace(OpusRangeCoder *rc, uint32_t symbol, int decay);
int ff_opus_rc_dec_init(OpusRangeCoder *rc, const uint8_t *data, int size);
void ff_opus_rc_dec_raw_init(OpusRangeCoder *rc, const uint8_t *rightend, uint32_t bytes);

static uint32_t state;

static uint32_t next(void)
{
    state = state * 1103515245u + 12345u;
    return state >> 16;
}

static const uint16_t cdf_a[] = { 32, 4, 12, 20, 28, 32 };
static const uint16_t cdf_b[] = { 256, 1, 128, 255, 256 };
static const uint16_t cdf_c[] = { 128, 64, 96, 112, 120, 124, 126, 127, 128 };

static uint32_t tell(const OpusRangeCoder *rc)
{
    return rc->total_bits - (31 - __builtin_clz(rc->range)) - 1;
}

static uint32_t tell_frac(const OpusRangeCoder *rc)
{
    uint32_t total_bits = rc->total_bits << 3;
    uint32_t rcbuffer = (31 - __builtin_clz(rc->range)) + 1;
    uint32_t range = rc->range >> (rcbuffer - 16);
    for (int i = 0; i < 3; i++) {
        range = range * range >> 15;
        int bit = range >> 16;
        rcbuffer = rcbuffer << 1 | bit;
        range >>= bit;
    }
    return total_bits - rcbuffer;
}

static void run(uint32_t seed, int size, int ops)
{
    static uint8_t frame[1275 + 64];
    static int32_t results[4096];
    state = seed;
    for (int i = 0; i < size; i++)
        frame[i] = (uint8_t)next();
    memset(frame + size, 0, 64); /* FFmpeg's input padding */
    OpusRangeCoder rc;
    memset(&rc, 0, sizeof(rc));
    ff_opus_rc_dec_init(&rc, frame, size);
    ff_opus_rc_dec_raw_init(&rc, frame + size, size);
    int n = 0;
    for (int i = 0; i < ops; i++) {
        switch (next() % 8) {
        case 0: {
            uint32_t t = next() % 3;
            results[n++] = ff_opus_rc_dec_cdf(&rc, t == 0 ? cdf_a : t == 1 ? cdf_b : cdf_c);
            break;
        }
        case 1: results[n++] = ff_opus_rc_dec_log(&rc, next() % 15 + 1); break;
        case 2: {
            uint32_t shift = next() % 20;
            results[n++] = ff_opus_rc_dec_uint(&rc, next() % (1u << shift) + 2);
            break;
        }
        case 3: results[n++] = ff_opus_rc_dec_uint_step(&rc, next() % 16); break;
        case 4: results[n++] = ff_opus_rc_dec_uint_tri(&rc, next() % 60 + 1); break;
        case 5: {
            uint32_t symbol = next() % 32736 + 1;
            results[n++] = ff_opus_rc_dec_laplace(&rc, symbol, next() % 16384);
            break;
        }
        case 6: results[n++] = ff_opus_rc_get_raw(&rc, next() % 25 + 1); break;
        default:
            results[n++] = tell(&rc);
            results[n++] = tell_frac(&rc);
            break;
        }
    }
    uint8_t digest[16];
    av_md5_sum(digest, (const uint8_t *)results, n * 4);
    printf("R %u %d %d ", seed, size, ops);
    for (int i = 0; i < 16; i++)
        printf("%02x", digest[i]);
    printf(" %u %u %u %u %u\n", rc.range, rc.value, rc.total_bits, tell(&rc), tell_frac(&rc));
}

int main(void)
{
    const int sizes[] = { 1, 2, 3, 8, 20, 61, 160, 400, 1275 };
    uint32_t seed = 1;
    for (size_t s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++)
        for (int k = 0; k < 12; k++)
            run(seed++, sizes[s], 40 + 160 * (k % 4));
    return 0;
}
