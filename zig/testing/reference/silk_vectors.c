// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T28b SILK oracle (zig/testing/vectors/silk.txt): what the
// pinned FFmpeg's SILK decoder (libavcodec/opus/silk.c,
// ff_silk_decode_superframe) makes of generated frame sequences. Each run
// is one decoder (ff_silk_init) with its output channels; each superframe
// has its coded channels, bandwidth (narrow, medium or wide), duration
// (10, 20, 40 or 60 ms), size and random bytes, sometimes after
// ff_silk_flush, read through the range decoder as dec.c reads a SILK
// frame. Any byte string is a SILK frame, so random bytes reach every
// path: LBRR frames, mid-only stereo, voiced frames with pitch and LTP,
// LSF interpolation and the LPC stabilization. The inputs come from
// integer arithmetic only (see next), so the Zig test (codec/silk.zig)
// repeats them. rc.h and silk.h are not installed, so the range decoder's
// struct and the prototypes are restated here, as at the pinned revision.
// The lines:
//
//   S <run> <frame> <flush> <channels> <output_channels> <bandwidth>
//     <duration_ms> <bytes> <samples> <range> <value> <total_bits> <md5>
//                          a superframe: whether the decoder was flushed
//                          first, its parameters, the samples per channel
//                          ff_silk_decode_superframe returned, the range
//                          decoder after it and the MD5 of the output
//                          (each output channel's samples, float32
//                          little-endian, in turn)
//
// See zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/md5.h"
#include "libavutil/mem.h"

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

typedef struct SilkContext SilkContext;

int ff_opus_rc_dec_init(OpusRangeCoder *rc, const uint8_t *data, int size);
int ff_silk_init(void *logctx, SilkContext **ps, int output_channels);
void ff_silk_free(SilkContext **ps);
void ff_silk_flush(SilkContext *s);
int ff_silk_decode_superframe(SilkContext *s, OpusRangeCoder *rc, float *output[2], int bandwidth,
                              int coded_channels, int duration_ms);

static uint32_t state;

static uint32_t next(void)
{
    state = state * 1103515245u + 12345u;
    return state >> 16;
}

int main(void)
{
    static uint8_t frame[1275 + 64];
    static float out[2][2880];
    static const int durations[4] = { 10, 20, 40, 60 };
    struct AVMD5 *md5 = av_md5_alloc();

    for (uint32_t run = 1; run <= 48; run++) {
        state = run;
        int output_channels = next() % 2 + 1;
        SilkContext *silk = NULL;
        if (ff_silk_init(NULL, &silk, output_channels) < 0)
            return 1;
        for (int f = 0; f < 20; f++) {
            int flush = next() % 16 == 0;
            int channels = next() % 3 == 0 ? 1 : 2;
            int bandwidth = next() % 3;
            int duration = durations[next() % 4];
            int bytes = next() % 8 == 0 ? (int)(next() % 4) : (int)(next() % 200 + 1);
            for (int i = 0; i < bytes; i++)
                frame[i] = (uint8_t)next();
            memset(frame + bytes, 0, 64); /* FFmpeg's input padding */

            if (flush)
                ff_silk_flush(silk);
            OpusRangeCoder rc;
            memset(&rc, 0, sizeof(rc));
            ff_opus_rc_dec_init(&rc, frame, bytes);
            float *output[2] = { out[0], out[1] };
            memset(out, 0, sizeof(out));
            int n = ff_silk_decode_superframe(silk, &rc, output, bandwidth, channels, duration);

            uint8_t digest[16];
            av_md5_init(md5);
            for (int c = 0; c < output_channels; c++)
                for (int i = 0; i < n; i++) {
                    uint32_t u;
                    memcpy(&u, &out[c][i], 4);
                    uint8_t b[4] = { u, u >> 8, u >> 16, u >> 24 };
                    av_md5_update(md5, b, 4);
                }
            av_md5_final(md5, digest);
            printf("S %u %d %d %d %d %d %d %d %d %u %u %u ", run, f, flush, channels, output_channels, bandwidth,
                   duration, bytes, n, rc.range, rc.value, rc.total_bits);
            for (int i = 0; i < 16; i++)
                printf("%02x", digest[i]);
            printf("\n");
        }
        ff_silk_free(&silk);
    }
    av_freep(&md5);
    return 0;
}
