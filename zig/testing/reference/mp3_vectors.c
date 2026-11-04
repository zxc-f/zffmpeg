// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T29a MP3 oracle (zig/testing/vectors/mp3.txt): what the pinned
// FFmpeg's libavformat makes of each MPEG audio file named on the command
// line, opened as the ffmpeg program opens an input (avformat_open_input
// with content probing, then avformat_find_stream_info) and read with
// av_read_frame, without decoding. The lines are ogg_vectors.c's (T27a),
// with these changes and additions:
//
//   F <name>                 a fixture, by file name without its extension
//   S <index> <type> <codec> <rate> <channels> <tb> <duration> <start>
//     <padding> <bit rate> <disposition>
//                            each stream after avformat_find_stream_info:
//                            its media type (a, v or o), the codec name
//                            (none when unknown), the sample rate, the
//                            channel count, the time base num/den, the
//                            duration and start time (N when unset),
//                            initial_padding, the bit rate and the
//                            disposition flags in hex
//   Y <index> <track gain> <track peak> <album gain> <album peak>
//                            its ReplayGain side data, when there is one
//   B <start> <duration> <bit rate>
//                            the format's start time and duration
//                            (AV_TIME_BASE units, N when unset) and bit rate
//   H <id> <tb> <start> <end> the chapters, each with its tags as G lines
//   K <skip> <discard>       a packet's skip-samples side data: the
//                            samples skipped at its start and discarded at
//                            its end
//
// M, G, P, Q, T and R are ogg_vectors.c's. See
// zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/adler32.h"
#include "libavutil/dict.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/log.h"
#include "libavutil/replaygain.h"

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

static char media_type(enum AVMediaType type)
{
    return type == AVMEDIA_TYPE_AUDIO ? 'a' : type == AVMEDIA_TYPE_VIDEO ? 'v' : 'o';
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
        printf("S %u %c %s %d %d %d/%d", i, media_type(par->codec_type), codec, par->sample_rate,
               par->ch_layout.nb_channels, st->time_base.num, st->time_base.den);
        print_ts(st->duration);
        print_ts(st->start_time);
        printf(" %d %" PRId64 " %x\n", par->initial_padding, par->bit_rate, (unsigned)st->disposition);
        const AVPacketSideData *sd =
            av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_REPLAYGAIN);
        if (sd && sd->size >= sizeof(AVReplayGain)) {
            const AVReplayGain *rg = (const AVReplayGain *)sd->data;
            printf("Y %u %d %u %d %u\n", i, rg->track_gain, rg->track_peak, rg->album_gain, rg->album_peak);
        }
        const AVDictionaryEntry *tag = NULL;
        while ((tag = av_dict_iterate(st->metadata, tag)))
            printf("M %u %s=%s\n", i, tag->key, tag->value);
    }
    printf("B");
    print_ts(fmt->start_time);
    print_ts(fmt->duration);
    printf(" %" PRId64 "\n", fmt->bit_rate);
    const AVDictionaryEntry *tag = NULL;
    while ((tag = av_dict_iterate(fmt->metadata, tag)))
        printf("G %s=%s\n", tag->key, tag->value);
    for (unsigned i = 0; i < fmt->nb_chapters; i++) {
        const AVChapter *ch = fmt->chapters[i];
        printf("H %" PRId64 " %d/%d %" PRId64 " %" PRId64 "\n", ch->id, ch->time_base.num, ch->time_base.den,
               ch->start, ch->end);
        tag = NULL;
        while ((tag = av_dict_iterate(ch->metadata, tag)))
            printf("G %s=%s\n", tag->key, tag->value);
    }

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

int main(int argc, char **argv)
{
    av_log_set_level(AV_LOG_QUIET);
    for (int i = 1; i < argc; i++)
        run(argv[i]);
    return 0;
}
