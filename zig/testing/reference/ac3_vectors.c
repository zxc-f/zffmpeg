// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T32a AC-3 and T32b E-AC-3 decoder oracles
// (zig/testing/vectors/ac3_decode.txt, eac3_decode.txt):
// what the pinned FFmpeg's decoder makes of each packet the raw AC-3 or
// E-AC-3 demuxer and the parser give for every file named on the command line, and of
// those packets with bits flipped or cut short, decoded in turn by one
// decoder as decode.c feeds a packet until it is consumed. The lines:
//
//   F <name>                 a file, by file name without its extension
//   P <pos> <size>           a packet: its position in the file and size
//   M <seed> <flips> <cut>   the next packet mutated: `flips` bits flipped
//                            (positions from the seed's xorshift) and cut
//                            to `cut` bytes (-1: whole)
//   D 0 <samples> <channels> <mask> <rate> <flags> <md5>
//                            each frame the packet gives (samples a
//                            channel, channels, the layout's mask in hex,
//                            the rate, decode_error_flags and the MD5 of the
//                            planes in order, little-endian floats)
//   D <error>                the error that ends the packet's decoding
//   O error                  a file FFmpeg does not open
//
// avcodec_send_packet and avcodec_receive_frame drive decode.c, which
// calls the decoder on what remains of a packet until it is used up. The
// decoders are opened with the stream's parameters, as the ffmpeg program
// opens them. See zig/testing/reference/README.md for the commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/md5.h"

static uint32_t rng_state;

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

static void print_result(int ret)
{
    if (ret == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (ret == AVERROR(EAGAIN))
        printf("EAGAIN");
    else if (ret == AVERROR(ENOSYS))
        printf("ENOSYS");
    else if (ret == AVERROR_PATCHWELCOME)
        printf("PATCHWELCOME");
    else
        printf("%d", ret);
}

// One packet sent; every frame received printed.
static void decode_packet(AVCodecContext *dec, const uint8_t *data, int size)
{
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    av_new_packet(pkt, size);
    memcpy(pkt->data, data, size);
    int ret = avcodec_send_packet(dec, pkt);
    if (ret < 0) {
        printf("D ");
        print_result(ret);
        printf("\n");
    }
    while (ret >= 0) {
        ret = avcodec_receive_frame(dec, frame);
        if (ret < 0) {
            if (ret != AVERROR(EAGAIN)) {
                printf("D ");
                print_result(ret);
                printf("\n");
            }
            break;
        }
        struct AVMD5 *md5 = av_md5_alloc();
        av_md5_init(md5);
        for (int c = 0; c < frame->ch_layout.nb_channels; c++)
            av_md5_update(md5, frame->extended_data[c], frame->nb_samples * 4);
        uint8_t digest[16];
        av_md5_final(md5, digest);
        av_free(md5);
        printf("D 0 %d %d %" PRIx64 " %d %d ", frame->nb_samples, frame->ch_layout.nb_channels,
               frame->ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? frame->ch_layout.u.mask : 0,
               frame->sample_rate, frame->decode_error_flags);
        for (int i = 0; i < 16; i++)
            printf("%02x", digest[i]);
        printf("\n");
        av_frame_unref(frame);
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
}

int main(int argc, char **argv)
{
    av_log_set_level(AV_LOG_QUIET);
    for (int a = 1; a < argc; a++) {
        const char *name = strrchr(argv[a], '/');
        name = name ? name + 1 : argv[a];
        printf("F %.*s\n", (int)(strrchr(name, '.') ? strrchr(name, '.') - name : (long)strlen(name)), name);
        AVFormatContext *fmt = NULL;
        if (avformat_open_input(&fmt, argv[a], NULL, NULL) < 0 || avformat_find_stream_info(fmt, NULL) < 0) {
            printf("O error\n");
            avformat_close_input(&fmt);
            continue;
        }
        // The stream's decoder: ac3, or eac3 once the parser named it.
        const AVCodec *codec = avcodec_find_decoder(fmt->streams[0]->codecpar->codec_id);
        AVCodecContext *dec = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(dec, fmt->streams[0]->codecpar);
        avcodec_open2(dec, codec, NULL);
        // The second decoder takes the mutated packets.
        AVCodecContext *mut = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(mut, fmt->streams[0]->codecpar);
        avcodec_open2(mut, codec, NULL);
        AVPacket *pkt = av_packet_alloc();
        int n = 0;
        while (av_read_frame(fmt, pkt) >= 0) {
            printf("P %" PRId64 " %d\n", pkt->pos, pkt->size);
            decode_packet(dec, pkt->data, pkt->size);
            // Every third packet mutated for the second decoder.
            uint32_t seed = 2654435761u * (uint32_t)(n + a);
            int flips = n % 3 == 0 ? 1 + (int)(seed % 4) : 0;
            int cut = n % 7 == 3 ? pkt->size * 2 / 3 : -1;
            printf("M %u %d %d\n", seed, flips, cut);
            uint8_t *data = av_memdup(pkt->data, pkt->size);
            rng_state = seed;
            for (int f = 0; f < flips; f++) {
                uint32_t bit = rng() % (uint32_t)(pkt->size * 8);
                data[bit / 8] ^= 0x80 >> (bit % 8);
            }
            decode_packet(mut, data, cut >= 0 ? cut : pkt->size);
            av_free(data);
            av_packet_unref(pkt);
            n++;
        }
        av_packet_free(&pkt);
        avcodec_free_context(&dec);
        avcodec_free_context(&mut);
        avformat_close_input(&fmt);
    }
    return 0;
}
