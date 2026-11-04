// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T28a CELT oracle (zig/testing/vectors/celt.txt): what the
// pinned FFmpeg's CELT decoder (libavcodec/opus/dec_celt.c,
// ff_celt_decode_frame, with celt.c, pvq.c and dsp.c) makes of generated
// frame sequences. Each run is one decoder (ff_celt_init) with its output
// channels and phase inversion option; each frame has its coded channels,
// size, band range and random bytes, sometimes after ff_celt_flush, and is
// set up as dec.c sets up a CELT frame (the range decoder over the bytes,
// raw bits from their end). Any byte string is a CELT frame, so random
// bytes reach every path: silence, the post-filter, transients, intensity
// and dual stereo, anti-collapse, folding and noise. The inputs come from
// integer arithmetic only (see next), so the Zig test (codec/celt.zig)
// repeats them. rc.h and celt.h are not installed, so the range decoder's
// struct and the prototypes are restated here, as at the pinned revision.
// The lines:
//
//   C <run> <frame> <flush> <channels> <output_channels> <phase_inv>
//     <frame_size> <bytes> <start> <end> <result> <range> <value>
//     <total_bits> <md5>
//                          a frame: whether it was flushed first, its
//                          parameters, ff_celt_decode_frame's result (0 or
//                          -1), the range decoder after it and the MD5 of
//                          the output (each output channel's frame_size
//                          samples, float32 little-endian, in turn)
//
// See zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/avcodec.h"
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

typedef struct CeltFrame CeltFrame;

int ff_opus_rc_dec_init(OpusRangeCoder *rc, const uint8_t *data, int size);
void ff_opus_rc_dec_raw_init(OpusRangeCoder *rc, const uint8_t *rightend, uint32_t bytes);
int ff_celt_init(AVCodecContext *avctx, CeltFrame **f, int output_channels, int apply_phase_inv);
void ff_celt_free(CeltFrame **f);
void ff_celt_flush(CeltFrame *f);
int ff_celt_decode_frame(CeltFrame *f, OpusRangeCoder *rc, float **output, int coded_channels, int frame_size,
                         int startband, int endband);

static const uint8_t band_end[5] = { 13, 17, 17, 19, 21 };

static uint32_t state;

static uint32_t next(void)
{
    state = state * 1103515245u + 12345u;
    return state >> 16;
}

int main(void)
{
    AVCodecContext *avctx = avcodec_alloc_context3(NULL);
    static uint8_t frame[1275 + 64];
    static float out[2][960];
    struct AVMD5 *md5 = av_md5_alloc();

    for (uint32_t run = 1; run <= 48; run++) {
        state = run;
        int output_channels = next() % 2 + 1;
        int phase_inv = next() % 4 != 0;
        int hybrid = next() % 4 == 0;
        CeltFrame *celt = NULL;
        if (ff_celt_init(avctx, &celt, output_channels, phase_inv) < 0)
            return 1;
        for (int f = 0; f < 20; f++) {
            int flush = next() % 16 == 0;
            int channels = next() % 3 == 0 ? 1 : 2;
            int frame_size = 120 << (next() % 4);
            int start = hybrid ? 17 : 0;
            int end = hybrid ? band_end[next() % 2 + 3] : band_end[next() % 5];
            int bytes = next() % 8 == 0 ? (int)(next() % 4) : (int)(next() % 400 + 1);
            for (int i = 0; i < bytes; i++)
                frame[i] = (uint8_t)next();
            memset(frame + bytes, 0, 64); /* FFmpeg's input padding */

            if (flush)
                ff_celt_flush(celt);
            OpusRangeCoder rc;
            memset(&rc, 0, sizeof(rc));
            ff_opus_rc_dec_init(&rc, frame, bytes);
            ff_opus_rc_dec_raw_init(&rc, frame + bytes, bytes);
            float *output[2] = { out[0], out[1] };
            memset(out, 0, sizeof(out));
            int ret = ff_celt_decode_frame(celt, &rc, output, channels, frame_size, start, end);

            uint8_t digest[16];
            av_md5_init(md5);
            for (int c = 0; c < output_channels; c++)
                for (int i = 0; i < frame_size; i++) {
                    uint32_t u;
                    memcpy(&u, &out[c][i], 4);
                    uint8_t b[4] = { u, u >> 8, u >> 16, u >> 24 };
                    av_md5_update(md5, b, 4);
                }
            av_md5_final(md5, digest);
            printf("C %u %d %d %d %d %d %d %d %d %d %d %u %u %u ", run, f, flush, channels, output_channels, phase_inv,
                   frame_size, bytes, start, end, ret < 0 ? -1 : 0, rc.range, rc.value, rc.total_bits);
            for (int i = 0; i < 16; i++)
                printf("%02x", digest[i]);
            printf("\n");
        }
        ff_celt_free(&celt);
    }
    av_freep(&md5);
    avcodec_free_context(&avctx);
    return 0;
}
