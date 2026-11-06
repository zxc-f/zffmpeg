// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T26a FLAC oracle (zig/testing/vectors/flac.txt): what the pinned
// FFmpeg's libavformat and libavcodec make of each FLAC fixture named on the
// command line, opened as the ffmpeg program opens an input
// (avformat_open_input with content probing, then
// avformat_find_stream_info), read with av_read_frame, and decoded by the
// FLAC decoder with its default options (no CRC checks, s16 output for
// 16-bit streams). The lines:
//
//   F <name>                 a fixture, by file name without .flac
//   O <result>               opening it: ok, or the error (INVALIDDATA, EOF,
//                            or the number)
//   S <format> <rate> <channels> <layout> <bits> <tb> <duration> <start> <fmt>
//                            the stream after avformat_find_stream_info: the
//                            demuxer, the sample rate, the channel count,
//                            av_channel_layout_describe's text, the bits per
//                            raw sample, the time base num/den, the duration,
//                            the start time (N when unset) and the decoder's
//                            sample format
//   M <key>=<value>          each format tag, in order
//   C <start> <end> <tb> <title>
//                            each chapter (T26b's CUESHEET)
//   A <stream> <codec> <size> <adler>
//                            each attached picture (T26b's PICTURE)
//   P <size> <pts> <dts> <duration> <flags> <adler>
//                            each packet av_read_frame returns: pts and dts N
//                            when unset, the flags in hex, and the Adler-32
//                            of its bytes from 0, as framecrc computes it
//   X <error>                decoding the packet above failed (the error
//                            avcodec_send_packet or avcodec_receive_frame
//                            returns)
//   D <samples> <pts> <adler>
//                            each frame the decoder gives, packed (s16, or
//                            s32 above 16 bits):
//                            the samples per channel, the pts (N when unset)
//                            and the Adler-32 from 0 of the samples' bytes
//   E <error>                the decoder refuses the stream's parameters
//   R <result>               how reading ended: EOF, or the error
//
// After the last packet the decoder is drained, which gives no frames for
// FLAC. See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/adler32.h"
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/frame.h"
#include "libavutil/log.h"
#include "libavutil/samplefmt.h"

static void fail(const char *what, const char *name)
{
    fprintf(stderr, "flac_vectors: %s failed for %s\n", what, name);
    exit(1);
}

static void print_error(int err)
{
    if (err == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (err == AVERROR_EOF)
        printf("EOF");
    else if (err == AVERROR_PATCHWELCOME)
        printf("PATCHWELCOME");
    else
        printf("%d", err);
}

static void print_ts(int64_t ts)
{
    if (ts == AV_NOPTS_VALUE)
        printf(" N");
    else
        printf(" %" PRId64, ts);
}

static void print_frames(AVCodecContext *dec, AVFrame *frame, const char *name)
{
    for (;;) {
        int ret = avcodec_receive_frame(dec, frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            return;
        if (ret < 0) {
            printf("X ");
            print_error(ret);
            printf("\n");
            continue;
        }
        if (frame->format != AV_SAMPLE_FMT_S16 && frame->format != AV_SAMPLE_FMT_S32)
            fail("packed output", name);
        int bytes = frame->nb_samples * frame->ch_layout.nb_channels * av_get_bytes_per_sample(frame->format);
        printf("D %d", frame->nb_samples);
        print_ts(frame->pts);
        printf(" 0x%08" PRIx32 "\n", (uint32_t)av_adler32_update(0, frame->data[0], bytes));
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
    int ret = avformat_open_input(&fmt, path, NULL, NULL);
    if (ret >= 0) {
        ret = avformat_find_stream_info(fmt, NULL);
        if (ret < 0)
            avformat_close_input(&fmt);
    }
    printf("O ");
    if (ret < 0) {
        print_error(ret);
        printf("\n");
        return;
    }
    printf("ok\n");

    AVStream *st = fmt->streams[0];
    AVCodecParameters *par = st->codecpar;
    char layout[128];
    if (av_channel_layout_describe(&par->ch_layout, layout, sizeof(layout)) < 0)
        fail("av_channel_layout_describe", name);
    printf("S %s %d %d %s %d %d/%d", fmt->iformat->name, par->sample_rate, par->ch_layout.nb_channels,
           layout, par->bits_per_raw_sample, st->time_base.num, st->time_base.den);
    print_ts(st->duration);
    print_ts(st->start_time);
    const char *sample_fmt = av_get_sample_fmt_name(par->format);
    printf(" %s\n", sample_fmt ? sample_fmt : "none");
    const AVDictionaryEntry *tag = NULL;
    while ((tag = av_dict_iterate(fmt->metadata, tag)))
        printf("M %s=%s\n", tag->key, tag->value);
    for (unsigned i = 0; i < fmt->nb_chapters; i++) {
        const AVChapter *c = fmt->chapters[i];
        const AVDictionaryEntry *title = av_dict_get(c->metadata, "title", NULL, 0);
        printf("C %" PRId64 " %" PRId64 " %d/%d %s\n", c->start, c->end, c->time_base.num, c->time_base.den,
               title ? title->value : "-");
    }
    for (unsigned i = 1; i < fmt->nb_streams; i++) {
        const AVStream *pic = fmt->streams[i];
        if (pic->disposition & AV_DISPOSITION_ATTACHED_PIC)
            printf("A %u %s %d 0x%08" PRIx32 "\n", i, avcodec_get_name(pic->codecpar->codec_id),
                   pic->attached_pic.size, (uint32_t)av_adler32_update(0, pic->attached_pic.data, pic->attached_pic.size));
    }

    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec)
        fail("avcodec_find_decoder", name);
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    if (!dec || avcodec_parameters_to_context(dec, par) < 0)
        fail("the decoder context", name);
    dec->pkt_timebase = st->time_base;
    int opened = avcodec_open2(dec, codec, NULL);
    if (opened < 0) {
        // The decoder refuses the stream's parameters, as the ffmpeg
        // program's input then fails.
        printf("E ");
        print_error(opened);
        printf("\n");
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        return;
    }

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if (!pkt || !frame)
        fail("allocation", name);
    for (;;) {
        ret = av_read_frame(fmt, pkt);
        if (ret < 0)
            break;
        // An attached picture's packet belongs to its own stream.
        if (pkt->stream_index != 0) {
            av_packet_unref(pkt);
            continue;
        }
        printf("P %d", pkt->size);
        print_ts(pkt->pts);
        print_ts(pkt->dts);
        printf(" %" PRId64 " 0x%x 0x%08" PRIx32 "\n", pkt->duration, pkt->flags,
               (uint32_t)av_adler32_update(0, pkt->data, pkt->size));
        int sent = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (sent < 0) {
            printf("X ");
            print_error(sent);
            printf("\n");
            continue;
        }
        print_frames(dec, frame, name);
    }
    printf("R ");
    print_error(ret);
    printf("\n");
    if (avcodec_send_packet(dec, NULL) < 0)
        fail("draining", name);
    print_frames(dec, frame, name);

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
