// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T30a AudioSpecificConfig oracle
// (zig/testing/vectors/mpeg4audio.txt): what the pinned FFmpeg's
// avpriv_mpeg4audio_get_config2 makes of crafted and pseudo-random
// configurations, with and without the sync extension search. The lines:
//
//   A <hex bytes> <sync_extension> <result>
//                    a configuration and the function's result: the bit
//                    index of the AudioSpecificConfig's end, or an error
//   M <object_type> <sampling_index> <sample_rate> <chan_config> <sbr>
//     <ext_object_type> <ext_sampling_index> <ext_sample_rate>
//     <ext_chan_config> <channels> <ps> <frame_length_short> <frame_length>
//                    after a result of 0 or more, the MPEG4AudioConfig
//
// The pseudo-random configurations come from integer arithmetic only, so
// the Zig test reads them from the A lines. See
// zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/error.h"
#include "libavutil/log.h"

// Not installed: libavcodec/mpeg4audio.h's declarations, which the static
// library exports (avpriv_ symbols are part of its ABI).
typedef struct MPEG4AudioConfig {
    int object_type;
    int sampling_index;
    int sample_rate;
    int chan_config;
    int sbr;
    int ext_object_type;
    int ext_sampling_index;
    int ext_sample_rate;
    int ext_chan_config;
    int channels;
    int ps;
    int frame_length_short;
    int frame_length;
} MPEG4AudioConfig;

int avpriv_mpeg4audio_get_config2(MPEG4AudioConfig *c, const uint8_t *buf, int size, int sync_extension,
                                  void *logctx);

static void run(const uint8_t *buf, int size, int sync)
{
    MPEG4AudioConfig c;
    memset(&c, 0, sizeof(c));
    printf("A ");
    for (int i = 0; i < size; i++)
        printf("%02x", buf[i]);
    if (!size)
        printf("-");
    int ret = avpriv_mpeg4audio_get_config2(&c, buf, size, sync, NULL);
    if (ret == AVERROR_INVALIDDATA)
        printf(" %d INVALIDDATA\n", sync);
    else
        printf(" %d %d\n", sync, ret);
    if (ret >= 0)
        printf("M %d %d %d %d %d %d %d %d %d %d %d %d %d\n", c.object_type, c.sampling_index, c.sample_rate,
               c.chan_config, c.sbr, c.ext_object_type, c.ext_sampling_index, c.ext_sample_rate, c.ext_chan_config,
               c.channels, c.ps, c.frame_length_short, c.frame_length);
}

static uint32_t rng_state = 0x6d703461;

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

int main(void)
{
    // LC at several rates and layouts, the 960 frame, the sync extension
    // (SBR, then PS), explicit HE-AAC and HE-AACv2, an AOT 29 config shaped
    // as MP3onMP4, the escape sampling index with and without its rate,
    // channel configurations 0, 12, 14 and 15 (invalid), escaped object
    // types (ALS with and without its config, ELD, USAC), ER LC, LD and
    // BSAC, and empty and one-byte buffers.
    static const struct {
        const char *hex;
    } crafted[] = {
        { "1210" }, { "1190" }, { "1188" }, { "1408" }, { "0a10" }, { "1218" }, { "121056e5" },
        { "121056e598" }, { "1310" }, { "2b920800" }, { "eb092000" }, { "ec092000" }, { "1780" },
        { "17800ac44010" }, { "1278" }, { "1200" }, { "1260" }, { "1270" }, { "f8e010" }, { "f8f220" },
        { "f8f2200041 4c530000ac440000ac44000100" }, { "f8f2200000414c530000ac440000ac44000100" },
        { "b9c010" }, { "f8e60800" }, { "fa8010" }, { "fa8008" }, { "fa80fffffff8" }, { "8988" },
        { "b7c010" }, { "2b92080000" }, { "" }, { "12" }, { "f88840414c53000000bb80000003e80005" },
        { "f88840000000414c53000000bb80000003e80005" }, { "f8884000000041414141000000000000000000000000" },
        { "f88840414c53000000000000000003e80005" }, { "f9464340" }, { "f9465f00ac4460" }, { "f9464380" },
        { "b98c" }, { "2b925840" }, { "eb898800" },
    };
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(crafted) / sizeof(crafted[0]); i++) {
        // Zeroed past the configuration, as extradata's padding is.
        uint8_t buf[64 + 64] = { 0 };
        int n = 0;
        for (const char *p = crafted[i].hex; p[0] && p[1];) {
            if (p[0] == ' ') {
                p++;
                continue;
            }
            unsigned v;
            sscanf(p, "%2x", &v);
            buf[n++] = (uint8_t)v;
            p += 2;
        }
        for (int sync = 0; sync < 2; sync++)
            run(buf, n, sync);
    }
    // Pseudo-random configurations: a plausible first byte pair, then
    // arbitrary bytes, so the sync extension search and the object types'
    // branches meet every shape.
    for (int i = 0; i < 600; i++) {
        uint8_t buf[24 + 64] = { 0 };
        int n = 2 + (int)(rng() % 22);
        for (int j = 0; j < n; j++)
            buf[j] = (uint8_t)rng();
        if (i % 3 == 0) {
            // Object type 1 to 4 or 17 to 23, a valid sampling index.
            static const uint8_t aots[] = { 1, 2, 3, 4, 5, 17, 19, 22, 23, 29, 31 };
            int aot = aots[rng() % sizeof(aots)];
            int sr = (int)(rng() % 13);
            buf[0] = (uint8_t)(aot << 3 | sr >> 1);
            buf[1] = (uint8_t)((sr & 1) << 7 | (buf[1] & 0x7f));
        }
        if (i % 7 == 0 && n >= 6) {
            // The sync extension's 0x2b7 somewhere after the config.
            int at = 2 + (int)(rng() % (n - 4));
            buf[at] = 0x56;
            buf[at + 1] = (uint8_t)(0xe0 | (buf[at + 1] & 0x1f));
        }
        run(buf, n, (int)(rng() & 1));
    }
    return 0;
}
