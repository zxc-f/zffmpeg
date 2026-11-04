// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T28a Opus packet oracle (zig/testing/vectors/opus_parse.txt):
// what the pinned FFmpeg's ff_opus_parse_packet (libavcodec/opus/parse.c)
// makes of generated packets of every code, plain and self-delimited. The
// packets come from integer arithmetic only (see make_packet), so the Zig
// test makes the same ones. parse.h is not installed, so OpusPacket and the
// prototype are restated here, as at the pinned revision. The lines:
//
//   K <seed> <size> <self_delimited> <result> <code> <stereo> <vbr>
//     <config> <frames> <packet_size> <data_size> <duration> <mode>
//     <bandwidth> <layout>
//                          a packet: its generator seed and size, the
//                          parse's result (0 or -1, all fields 0 after a
//                          failure), the fields, and the frames' offsets
//                          and sizes as offset:size pairs joined by ','
//
// See zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct OpusPacket {
    int packet_size;
    int data_size;
    int code;
    int stereo;
    int vbr;
    int config;
    int frame_count;
    int frame_offset[48];
    int frame_size[48];
    int frame_duration;
    int mode;
    int bandwidth;
} OpusPacket;

int ff_opus_parse_packet(OpusPacket *pkt, const uint8_t *buf, int buf_size, int self_delimited);

static uint32_t state;

static uint32_t next(void)
{
    state = state * 1103515245u + 12345u;
    return state >> 16;
}

/* A packet: a random TOC byte, for code 3 a frame count byte of 1 to 6
 * frames with random padding and VBR flags, a small padding length and
 * small frame sizes when those are set, then random bytes. */
static int make_packet(uint8_t *buf)
{
    int size = next() % 300;
    for (int i = 0; i < size + 8; i++)
        buf[i] = (uint8_t)next();
    if (size >= 2 && (buf[0] & 3) == 3) {
        buf[1] = (uint8_t)((next() % 6 + 1) | (next() % 2) << 6 | (next() % 2) << 7);
        int at = 2;
        if (buf[1] & 0x40 && at < size)
            buf[at++] = (uint8_t)(next() % 20);
        if (buf[1] & 0x80)
            for (int i = 0; i < (buf[1] & 0x3f) - 1 && at < size; i++)
                buf[at++] = (uint8_t)(next() % 60);
    }
    return size;
}

int main(void)
{
    uint8_t buf[320];
    for (uint32_t seed = 1; seed <= 2000; seed++) {
        state = seed;
        int size = make_packet(buf);
        int sd = (int)(next() % 2);
        OpusPacket pkt;
        memset(&pkt, 0, sizeof(pkt));
        int ret = ff_opus_parse_packet(&pkt, buf, size, sd);
        printf("K %u %d %d %d %d %d %d %d %d %d %d %d %d %d ", seed, size, sd, ret < 0 ? -1 : 0, pkt.code, pkt.stereo,
               pkt.vbr, pkt.config, pkt.frame_count, pkt.packet_size, pkt.data_size, pkt.frame_duration, pkt.mode,
               pkt.bandwidth);
        if (pkt.frame_count == 0)
            printf("-");
        for (int i = 0; i < pkt.frame_count; i++)
            printf("%s%d:%d", i ? "," : "", pkt.frame_offset[i], pkt.frame_size[i]);
        printf("\n");
    }
    return 0;
}
