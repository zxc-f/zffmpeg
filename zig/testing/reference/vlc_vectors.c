// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T18c VLC oracle (zig/testing/vectors/vlc.txt): the tables the
// pinned FFmpeg's libavcodec builds (ff_vlc_init_sparse, the builder behind
// vlc_init) for generated prefix codes. The codes come from integer
// arithmetic only (see make_lengths), so the Zig test makes the same ones.
// vlc.h is not installed, so its VLC struct and the builder's prototype are
// restated here, as at the pinned revision. The lines:
//
//   V <codes> <max_len> <nb_bits> <le> <seed> <drop> <variant>
//                          a case: the code count, the longest length, the
//                          table's bits, 1 for VLC_INIT_LE, the generator's
//                          seed, every drop-th code left out (0: none), and
//                          the variant (0 plain, 1 symbols given, 2 two
//                          codes equal, 3 a codeword wider than its length)
//   R <result> <size> <md5>
//                          the builder's result (0, INVALIDDATA, EINVAL or
//                          the number), the table's entry count and the MD5
//                          of its entries, each sym then len, int16
//                          little-endian
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/md5.h"
#include "libavutil/mem.h"

typedef struct VLCElem {
    int16_t sym, len;
} VLCElem;

typedef struct VLC {
    int bits;
    VLCElem *table;
    int table_size, table_allocated;
} VLC;

int ff_vlc_init_sparse(VLC *vlc, int nb_bits, int nb_codes, const void *bits, int bits_wrap, int bits_size,
                       const void *codes, int codes_wrap, int codes_size, const void *symbols, int symbols_wrap,
                       int symbols_size, int flags);

#define VLC_INIT_LE 12
#define MAX_CODES 1024

static uint32_t rng;

static uint32_t next(void)
{
    rng = rng * 1103515245u + 12345u;
    return rng >> 16;
}

/* A complete prefix code: one leaf, then a leaf split into two one level
 * deeper until there are `count` leaves (a leaf at max_len is not split).
 * Returns the leaves made. */
static int make_lengths(uint8_t *lens, int count, int max_len)
{
    int n = 1;
    lens[0] = 0;
    while (n < count) {
        int idx = next() % n;
        int tries = 0;
        while (lens[idx] >= max_len && tries < n) {
            idx = (idx + 1) % n;
            tries++;
        }
        if (tries == n)
            break;
        lens[idx]++;
        lens[n++] = lens[idx];
    }
    return n;
}

/* Canonical codewords for the lengths, first bit in the most significant;
 * with `le`, each reversed within its length (first bit least
 * significant). */
static void make_codes(const uint8_t *lens, uint32_t *codes, int n, int le)
{
    uint64_t count[34] = { 0 }, next_code[34] = { 0 };
    for (int i = 0; i < n; i++)
        count[lens[i]]++;
    count[0] = 0;
    for (int len = 1; len <= 33; len++)
        next_code[len] = (next_code[len - 1] + count[len - 1]) << 1;
    for (int i = 0; i < n; i++) {
        if (!lens[i])
            continue;
        uint32_t code = (uint32_t)next_code[lens[i]]++;
        if (le) {
            uint32_t r = 0;
            for (int b = 0; b < lens[i]; b++)
                r |= ((code >> b) & 1) << (lens[i] - 1 - b);
            code = r;
        }
        codes[i] = code;
    }
}

static void run(int count, int max_len, int nb_bits, int le, uint32_t seed, int drop, int variant)
{
    printf("V %d %d %d %d %u %d %d\n", count, max_len, nb_bits, le, seed, drop, variant);
    uint8_t lens[MAX_CODES];
    uint32_t codes[MAX_CODES];
    int16_t symbols[MAX_CODES];
    rng = seed;
    int n = make_lengths(lens, count, max_len);
    make_codes(lens, codes, n, le);
    for (int i = 0; i < n; i++)
        symbols[i] = (int16_t)(i * 3 - 50);
    if (drop)
        for (int i = drop - 1; i < n; i += drop)
            lens[i] = 0;
    if (variant == 2 && n > 2) {
        lens[1] = lens[0];
        codes[1] = codes[0];
    }
    if (variant == 3 && lens[0] < 32)
        codes[0] |= 1u << lens[0];
    VLC vlc = { 0 };
    int ret = ff_vlc_init_sparse(&vlc, nb_bits, n, lens, 1, 1, codes, 4, 4, variant == 1 ? symbols : NULL,
                                 2, 2, le ? VLC_INIT_LE : 0);
    printf("R ");
    if (ret == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (ret == AVERROR(EINVAL))
        printf("EINVAL");
    else
        printf("%d", ret);
    uint8_t digest[16];
    int size = ret < 0 ? 0 : vlc.table_size;
    uint8_t *bytes = av_malloc(size * 4 + 1);
    for (int i = 0; i < size; i++) {
        bytes[4 * i + 0] = (uint8_t)vlc.table[i].sym;
        bytes[4 * i + 1] = (uint8_t)((uint16_t)vlc.table[i].sym >> 8);
        bytes[4 * i + 2] = (uint8_t)vlc.table[i].len;
        bytes[4 * i + 3] = (uint8_t)((uint16_t)vlc.table[i].len >> 8);
    }
    av_md5_sum(digest, bytes, size * 4);
    printf(" %d ", size);
    for (int i = 0; i < 16; i++)
        printf("%02x", digest[i]);
    printf("\n");
    av_free(bytes);
    av_freep(&vlc.table);
}

int main(void)
{
    av_log_set_level(AV_LOG_QUIET);
    const int counts[] = { 2, 3, 8, 17, 64, 255, 1000 };
    const int max_lens[] = { 1, 4, 9, 15, 24, 32 };
    const int nb_bits_list[] = { 1, 5, 8, 11 };
    uint32_t seed = 1;
    for (size_t c = 0; c < sizeof(counts) / sizeof(counts[0]); c++)
        for (size_t m = 0; m < sizeof(max_lens) / sizeof(max_lens[0]); m++)
            for (size_t b = 0; b < sizeof(nb_bits_list) / sizeof(nb_bits_list[0]); b++)
                for (int le = 0; le < 2; le++) {
                    run(counts[c], max_lens[m], nb_bits_list[b], le, seed, 0, 0);
                    run(counts[c], max_lens[m], nb_bits_list[b], le, seed + 1, 3, 0);
                    seed += 2;
                }
    for (int le = 0; le < 2; le++)
        for (int variant = 1; variant <= 3; variant++)
            run(64, 12, 6, le, 77 + variant, 0, variant);
    return 0;
}
