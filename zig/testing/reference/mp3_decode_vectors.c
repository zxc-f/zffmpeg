// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T29b MP3 decoding oracle (zig/testing/vectors/mp3_decode.txt):
// what the pinned FFmpeg's mp3float decoder makes of the MP3 stream of each
// file named on the command line, opened as the ffmpeg program opens an
// input, each packet av_read_frame returns sent to the decoder
// (avcodec_send_packet) and every frame received after it, with
// libavcodec's discarding of skipped samples and padding (the gapless trim
// the mp3 demuxer sets). A stream the parser names MP1 or MP2 has no
// decoder in the reference build. The lines:
//
//   F <name>                 a file, by name without .mp3
//   O <result>               opening the input and the decoder: ok or the
//                            error
//   P <size> <result>        a packet sent: its size and the result
//   D <nb_samples> <md5>     a frame received: its sample count and the
//                            MD5 of its float planes, one after another,
//                            little-endian
//   E <result>               a receive that failed other than EAGAIN
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/log.h"
#include "libavutil/md5.h"

static void print_error(int err)
{
    if (err == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (err == AVERROR_DECODER_NOT_FOUND)
        printf("DECODER_NOT_FOUND");
    else if (err == AVERROR_EOF)
        printf("EOF");
    else
        printf("%d", err);
}

static void receive(AVCodecContext *dec, AVFrame *frame)
{
    for (;;) {
        int ret = avcodec_receive_frame(dec, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            return;
        if (ret < 0) {
            printf("E ");
            print_error(ret);
            printf("\n");
            return;
        }
        struct AVMD5 *md5 = av_md5_alloc();
        av_md5_init(md5);
        for (int c = 0; c < frame->ch_layout.nb_channels; c++)
            av_md5_update(md5, frame->extended_data[c], frame->nb_samples * sizeof(float));
        uint8_t digest[16];
        av_md5_final(md5, digest);
        av_free(md5);
        printf("D %d ", frame->nb_samples);
        for (int i = 0; i < 16; i++)
            printf("%02x", digest[i]);
        printf("\n");
        av_frame_unref(frame);
    }
}

static void run(const char *path)
{
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    char name[256];
    snprintf(name, sizeof(name), "%s", base);
    char *dot = strrchr(name, '.');
    if (dot)
        *dot = 0;
    printf("F %s\n", name);

    AVFormatContext *fmt = NULL;
    AVCodecContext *dec = NULL;
    int ret = avformat_open_input(&fmt, path, NULL, NULL);
    if (ret >= 0)
        ret = avformat_find_stream_info(fmt, NULL);
    int index = -1;
    if (ret >= 0) {
        for (unsigned i = 0; i < fmt->nb_streams; i++)
            if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                index = i;
                break;
            }
        if (index < 0 || fmt->streams[index]->codecpar->codec_id != AV_CODEC_ID_MP3)
            ret = AVERROR_DECODER_NOT_FOUND;
    }
    if (ret >= 0) {
        const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_MP3);
        dec = avcodec_alloc_context3(codec);
        ret = avcodec_parameters_to_context(dec, fmt->streams[index]->codecpar);
        if (ret >= 0) {
            dec->pkt_timebase = fmt->streams[index]->time_base;
            ret = avcodec_open2(dec, codec, NULL);
        }
    }
    printf("O ");
    if (ret < 0) {
        print_error(ret);
        printf("\n");
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        return;
    }
    printf("ok\n");
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    while (av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index == index) {
            ret = avcodec_send_packet(dec, pkt);
            printf("P %d ", pkt->size);
            print_error(ret < 0 ? ret : 0);
            printf("\n");
            receive(dec, frame);
        }
        av_packet_unref(pkt);
    }
    avcodec_send_packet(dec, NULL);
    receive(dec, frame);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
}

/* Files in byte order (strcmp), whatever order the shell expanded a glob
 * in: a glob follows the shell's locale, so the committed output would
 * otherwise depend on the machine that generated it. */
static int by_name(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int main(int argc, char **argv)
{
    av_log_set_level(AV_LOG_QUIET);
    qsort(argv + 1, argc - 1, sizeof(*argv), by_name);
    for (int i = 1; i < argc; i++)
        run(argv[i]);
    return 0;
}
