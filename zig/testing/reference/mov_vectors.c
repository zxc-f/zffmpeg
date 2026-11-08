// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T33a1 MP4 oracle (zig/testing/vectors/mov.txt): what the
// pinned FFmpeg's libavformat makes of each MP4, MOV, M4A or 3GP file named
// on the command line, opened as the ffmpeg program opens an input
// (avformat_open_input with content probing, then
// avformat_find_stream_info) and read with av_read_frame, without decoding.
// The lines are mp3_vectors.c's (T29a), with these changes and additions:
//
//   I <format>               the demuxer the probe chose (iformat->name)
//   S <index> <type> <codec> <rate> <channels> <tb> <duration> <start>
//     <padding> <bit rate> <disposition>
//                            each stream after avformat_find_stream_info,
//                            as mp3_vectors.c prints it
//   C <index> <id> <tag> <bits per coded sample> <bits per raw sample>
//     <frame size> <block align> <profile> <nb_frames> <seek preroll>
//     <extradata size> <extradata adler>
//                            the rest of its parameters: the stream id, the
//                            codec tag in hex, the sample sizes, the frame
//                            size and block align, the profile (-99 when
//                            unknown), nb_frames, seek_preroll, and the
//                            extradata's size and Adler-32 from 0
//   L <index> <order> <channels> <mask>
//                            its channel layout: the order (0 unspecified,
//                            1 native, 2 custom, 3 ambisonic), the channel
//                            count, and the mask for a native order (each
//                            channel's id, comma-separated, for a custom
//                            one; 0 otherwise)
//
// Y, B, H, M, G, P, K, Q, T and R are mp3_vectors.c's; T33a2 compares the
// tags (M, G), chapters (H with their G lines) and ReplayGain (Y) they
// print. With -pipe as the
// first argument, each file is read through an AVIOContext that cannot
// seek, as from a pipe (zig/testing/vectors/mov_pipe.txt). See
// zig/testing/reference/README.md for the build commands.

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
    else if (err == AVERROR(ENOMEM))
        printf("ENOMEM");
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
    switch (type) {
    case AVMEDIA_TYPE_AUDIO:
        return 'a';
    case AVMEDIA_TYPE_VIDEO:
        return 'v';
    case AVMEDIA_TYPE_SUBTITLE:
        return 's';
    case AVMEDIA_TYPE_DATA:
        return 'd';
    default:
        return 'o';
    }
}

static void print_layout(unsigned i, const AVChannelLayout *layout)
{
    printf("L %u %d %d ", i, (int)layout->order, layout->nb_channels);
    if (layout->order == AV_CHANNEL_ORDER_NATIVE || layout->order == AV_CHANNEL_ORDER_AMBISONIC) {
        printf("%" PRIx64 "\n", layout->u.mask);
    } else if (layout->order == AV_CHANNEL_ORDER_CUSTOM) {
        for (int c = 0; c < layout->nb_channels; c++)
            printf("%s%d", c ? "," : "", (int)layout->u.map[c].id);
        printf("\n");
    } else {
        printf("0\n");
    }
}

static int pipe_mode;

struct pipe_input {
    FILE *file;
};

static int pipe_read(void *opaque, uint8_t *buf, int size)
{
    struct pipe_input *in = opaque;
    size_t n = fread(buf, 1, size, in->file);
    return n ? (int)n : AVERROR_EOF;
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
    struct pipe_input in = { 0 };
    AVIOContext *pb = NULL;
    if (pipe_mode) {
        in.file = fopen(path, "rb");
        unsigned char *buffer = av_malloc(32768);
        pb = avio_alloc_context(buffer, 32768, 0, &in, pipe_read, NULL, NULL);
        fmt = avformat_alloc_context();
        fmt->pb = pb;
    }
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
        if (pb) {
            av_freep(&pb->buffer);
            avio_context_free(&pb);
            fclose(in.file);
        }
        return;
    }
    printf("ok\n");
    printf("I %s\n", fmt->iformat->name);
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        const AVStream *st = fmt->streams[i];
        const AVCodecParameters *par = st->codecpar;
        const char *codec = par->codec_id == AV_CODEC_ID_NONE ? "none" : avcodec_get_name(par->codec_id);
        printf("S %u %c %s %d %d %d/%d", i, media_type(par->codec_type), codec, par->sample_rate,
               par->ch_layout.nb_channels, st->time_base.num, st->time_base.den);
        print_ts(st->duration);
        print_ts(st->start_time);
        printf(" %d %" PRId64 " %x\n", par->initial_padding, par->bit_rate, (unsigned)st->disposition);
        printf("C %u %d %x %d %d %d %d %d %" PRId64 " %d %d %lu\n", i, st->id, par->codec_tag,
               par->bits_per_coded_sample, par->bits_per_raw_sample, par->frame_size, par->block_align,
               par->profile, st->nb_frames, par->seek_preroll, par->extradata_size,
               par->extradata ? adler(par->extradata, par->extradata_size) : 0UL);
        print_layout(i, &par->ch_layout);
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
    if (pb) {
        av_freep(&pb->buffer);
        avio_context_free(&pb);
        fclose(in.file);
    }
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
    int first = 1;
    if (argc > 1 && !strcmp(argv[1], "-pipe")) {
        pipe_mode = 1;
        first = 2;
    }
    qsort(argv + first, argc - first, sizeof(*argv), by_name);
    for (int i = first; i < argc; i++)
        run(argv[i]);
    return 0;
}
