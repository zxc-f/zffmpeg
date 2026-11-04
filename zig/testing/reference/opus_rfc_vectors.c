// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the digests of the pinned FFmpeg's decoding of the RFC 8251 Opus
// test vectors (zig/testing/vectors/opus_rfc.txt, T28): each `.bit` file
// named on the command line (opus_demo's packets: a 32-bit big-endian
// length, the encoder's final range, the packet) decoded by FFmpeg's Opus
// decoder at 48 kHz, as stereo and as mono (an OpusHead of mapping family
// 0, no pre-skip, no gain), every packet sent with avcodec_send_packet,
// then a null packet for the samples the decoder still owes. The lines:
//
//   R <name> <channels> <samples> <md5>
//                          a decoding: the file's name without .bit, the
//                          output channels, the samples per channel and
//                          the MD5 of the samples interleaved as float32
//                          little-endian
//
// The vectors are optional coverage (opus_vectors_sync.sh); compare.py
// compares opus-vector-driver's decoding with these lines. See
// zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/log.h"
#include "libavutil/md5.h"
#include "libavutil/mem.h"

static void run(const char *path, int channels)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "%s: cannot open\n", path);
        exit(1);
    }
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_OPUS);
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    const uint8_t head[19] = { 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, channels, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 0 };
    dec->extradata = av_mallocz(sizeof(head) + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(dec->extradata, head, sizeof(head));
    dec->extradata_size = sizeof(head);
    if (avcodec_open2(dec, codec, NULL) < 0)
        exit(1);
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    struct AVMD5 *md5 = av_md5_alloc();
    av_md5_init(md5);
    int64_t samples = 0;
    for (;;) {
        uint8_t hdr[8];
        int end = fread(hdr, 1, 8, f) != 8;
        if (!end) {
            int len = hdr[0] << 24 | hdr[1] << 16 | hdr[2] << 8 | hdr[3];
            if (av_new_packet(pkt, len) < 0 || fread(pkt->data, 1, len, f) != (size_t)len)
                exit(1);
            avcodec_send_packet(dec, pkt);
            av_packet_unref(pkt);
        } else {
            avcodec_send_packet(dec, NULL);
        }
        while (avcodec_receive_frame(dec, frame) >= 0) {
            for (int i = 0; i < frame->nb_samples; i++)
                for (int c = 0; c < channels; c++) {
                    uint32_t u;
                    memcpy(&u, (const float *)frame->extended_data[c] + i, 4);
                    uint8_t b[4] = { u, u >> 8, u >> 16, u >> 24 };
                    av_md5_update(md5, b, 4);
                }
            samples += frame->nb_samples;
            av_frame_unref(frame);
        }
        if (end)
            break;
    }
    uint8_t digest[16];
    av_md5_final(md5, digest);
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    char name[256];
    snprintf(name, sizeof(name), "%s", base);
    char *dot = strrchr(name, '.');
    if (dot)
        *dot = 0;
    printf("R %s %d %lld ", name, channels, (long long)samples);
    for (int i = 0; i < 16; i++)
        printf("%02x", digest[i]);
    printf("\n");
    av_freep(&md5);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    fclose(f);
}

int main(int argc, char **argv)
{
    av_log_set_level(AV_LOG_QUIET);
    for (int i = 1; i < argc; i++) {
        run(argv[i], 2);
        run(argv[i], 1);
    }
    return 0;
}
