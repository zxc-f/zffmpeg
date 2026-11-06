// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T27a Ogg oracle (zig/testing/vectors/ogg.txt): what the pinned
// FFmpeg's libavformat makes of each Ogg fixture named on the command line,
// opened as the ffmpeg program opens an input (avformat_open_input with
// content probing, then avformat_find_stream_info) and read with
// av_read_frame, without decoding. The lines:
//
//   F <name>                 a fixture, by file name without .ogg
//   O <result>               opening it: ok, or the error (INVALIDDATA, EOF,
//                            or the number)
//   S <index> <codec> <rate> <channels> <tb> <duration> <start> <padding>
//     <preroll> <extradata size> <extradata adler>
//                            each stream after avformat_find_stream_info:
//                            the codec name (none when unknown), the sample
//                            rate, the channel count, the time base
//                            num/den, the duration and start time (N when
//                            unset), initial_padding, seek_preroll, and the
//                            extradata's size and Adler-32 from 0
//   M <index> <key>=<value>  each stream tag, in order
//   G <key>=<value>          each format tag, in order
//   P <stream> <size> <pts> <dts> <duration> <flags> <pos> <adler>
//                            each packet av_read_frame returns: pts and dts
//                            N when unset, the flags in hex, the byte
//                            position, and the Adler-32 of its bytes from 0
//   K <start> <end>          the packet's skip-samples side data
//   Q <size> <adler>         its new-extradata side data
//   T <size> <adler>         its strings-metadata side data
//   R <result>               how reading ended: EOF, or the error
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/adler32.h"
#include "libavutil/dict.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/log.h"

static void print_error(int err)
{
    if (err == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (err == AVERROR_EOF)
        printf("EOF");
    else if (err == AVERROR_PATCHWELCOME)
        printf("PATCHWELCOME");
    else if (err == AVERROR_UNKNOWN)
        printf("UNKNOWN");
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

static unsigned long adler(const uint8_t *data, size_t size)
{
    return av_adler32_update(0, data, size);
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
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        const AVStream *st = fmt->streams[i];
        const AVCodecParameters *par = st->codecpar;
        const char *codec = par->codec_id == AV_CODEC_ID_NONE ? "none" : avcodec_get_name(par->codec_id);
        printf("S %u %s %d %d %d/%d", i, codec, par->sample_rate, par->ch_layout.nb_channels, st->time_base.num,
               st->time_base.den);
        print_ts(st->duration);
        print_ts(st->start_time);
        printf(" %d %d %d %lu\n", par->initial_padding, par->seek_preroll, par->extradata_size,
               par->extradata ? adler(par->extradata, par->extradata_size) : 0UL);
        const AVDictionaryEntry *tag = NULL;
        while ((tag = av_dict_iterate(st->metadata, tag)))
            printf("M %u %s=%s\n", i, tag->key, tag->value);
    }
    const AVDictionaryEntry *tag = NULL;
    while ((tag = av_dict_iterate(fmt->metadata, tag)))
        printf("G %s=%s\n", tag->key, tag->value);

    AVPacket *pkt = av_packet_alloc();
    while ((ret = av_read_frame(fmt, pkt)) >= 0) {
        printf("P %d %d", pkt->stream_index, pkt->size);
        print_ts(pkt->pts);
        print_ts(pkt->dts);
        printf(" %" PRId64 " %x %" PRId64 " %lu\n", pkt->duration, pkt->flags, pkt->pos, adler(pkt->data, pkt->size));
        size_t size;
        const uint8_t *side = av_packet_get_side_data(pkt, AV_PKT_DATA_SKIP_SAMPLES, &size);
        if (side && size >= 8)
            printf("K %u %u\n", AV_RL32(side), AV_RL32(side + 4));
        side = av_packet_get_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, &size);
        if (side)
            printf("Q %zu %lu\n", size, adler(side, size));
        side = av_packet_get_side_data(pkt, AV_PKT_DATA_STRINGS_METADATA, &size);
        if (side)
            printf("T %zu %lu\n", size, adler(side, size));
        av_packet_unref(pkt);
    }
    printf("R ");
    print_error(ret);
    printf("\n");
    av_packet_free(&pkt);
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
