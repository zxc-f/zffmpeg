// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T27b Ogg muxer oracle (zig/testing/vectors/oggmux.txt): what
// the pinned FFmpeg's libavformat Ogg muxer writes for one stream of
// generated packets, through the public API as the ffmpeg program drives a
// muxer (avformat_write_header with AVFMT_FLAG_BITEXACT and the case's
// muxer options, av_interleaved_write_frame for each packet,
// av_write_trailer), into a dynamic buffer. The packets, headers and tags
// come from integer arithmetic only, so the Zig test makes the same ones
// from the parameters printed here. The lines:
//
//   C <name> <codec> <rate> <channels> <padding> <page_duration>
//     <serial_offset> <count> <base> <mod> <duration> <start>
//     <extradata> <tags>        a case: the codec (flac, opus, vorbis or
//                               pcm_s16le), the sample rate, the channel
//                               count, initial_padding, the muxer's
//                               page_duration and serial_offset (-1 and
//                               -2: not set), then the packets: their
//                               count, their sizes (base + (i * 37) % mod,
//                               or base when mod is 0), their duration and
//                               the first one's pts; the extradata's size
//                               (0: the codec's whole header) and the tag
//                               set (see make_tags)
//   H <result>                  avformat_write_header: 0 or the error
//   X <index> <result>          a packet the muxer refused; none follow
//   T <result>                  av_write_trailer
//   P <offset> <flags> <granule> <serial> <sequence> <segments> <size>
//                               each page of the output: its byte offset,
//                               header flags, granule position, serial
//                               number, sequence number, segment count and
//                               body size
//   M <size> <md5>              the whole output's size and MD5
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/codec_id.h"
#include "libavformat/avformat.h"
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/log.h"
#include "libavutil/md5.h"
#include "libavutil/mem.h"

struct Case {
    const char *name;
    const char *codec;
    int rate, channels, padding;
    int64_t page_duration; // -1: not set
    int serial_offset;     // -2: not set
    int count, base, mod, duration;
    int64_t start;
    int extradata; // 0: the whole header
    int tags;
};

static const struct Case cases[] = {
    { "flac_basic", "flac", 44100, 2, 0, -1, -2, 20, 100, 400, 4096, 0, 0, 0 },
    { "flac_tags", "flac", 44100, 2, 0, -1, -2, 20, 100, 400, 4096, 0, 0, 1 },
    { "flac_format_tags", "flac", 44100, 2, 0, -1, -2, 20, 100, 400, 4096, 0, 0, 3 },
    { "flac_long_tag", "flac", 44100, 2, 0, -1, -2, 5, 100, 400, 4096, 0, 0, 2 },
    { "flac_serial_zero", "flac", 44100, 2, 0, -1, 0, 20, 100, 400, 4096, 0, 0, 1 },
    { "flac_serial_seven", "flac", 44100, 2, 0, -1, 7, 20, 100, 400, 4096, 0, 0, 1 },
    { "flac_page_duration_zero", "flac", 8000, 1, 0, 0, -2, 400, 50, 0, 576, 0, 0, 1 },
    { "flac_page_duration_short", "flac", 44100, 1, 0, 20000, -2, 100, 20, 30, 441, 0, 0, 1 },
    { "flac_long", "flac", 44100, 2, 0, -1, -2, 400, 300, 50, 4096, 0, 0, 1 },
    { "flac_big_packets", "flac", 44100, 2, 0, -1, -2, 12, 65000, 1000, 4096, 0, 0, 1 },
    { "flac_huge_packets", "flac", 44100, 2, 0, -1, -2, 3, 200000, 0, 4096, 0, 0, 1 },
    { "flac_many_segments", "flac", 44100, 1, 0, -1, -2, 600, 10, 0, 16, 0, 0, 1 },
    { "flac_empty_packets", "flac", 44100, 1, 0, -1, -2, 30, 0, 3, 1152, 0, 0, 1 },
    { "flac_segment_sizes", "flac", 44100, 1, 0, -1, -2, 40, 250, 12, 1152, 0, 0, 1 },
    { "flac_start_pts", "flac", 44100, 2, 0, -1, -2, 20, 100, 400, 4096, 1000, 0, 1 },
    { "flac_negative_pts", "flac", 44100, 2, 0, -1, -2, 20, 100, 400, 4096, -2048, 0, 1 },
    { "flac_no_packets", "flac", 44100, 2, 0, -1, -2, 0, 100, 0, 4096, 0, 0, 1 },
    { "flac_short_extradata", "flac", 44100, 2, 0, -1, -2, 20, 100, 400, 4096, 0, 20, 1 },
    { "opus_basic", "opus", 48000, 2, 312, -1, -2, 50, 60, 140, 960, 0, 0, 1 },
    { "opus_no_tags", "opus", 48000, 2, 312, -1, -2, 50, 60, 140, 960, 0, 0, 0 },
    { "opus_rate_16k", "opus", 16000, 1, 120, -1, -2, 50, 30, 50, 960, -312, 0, 1 },
    { "opus_long", "opus", 48000, 2, 312, -1, -2, 300, 60, 140, 960, 0, 0, 1 },
    { "opus_short_extradata", "opus", 48000, 2, 312, -1, -2, 50, 60, 140, 960, 0, 18, 1 },
    { "vorbis_basic", "vorbis", 44100, 2, 0, -1, -2, 60, 40, 200, 1024, 0, 0, 1 },
    { "vorbis_no_tags", "vorbis", 44100, 2, 0, -1, -2, 60, 40, 200, 1024, 0, 0, 0 },
    { "vorbis_format_tags", "vorbis", 44100, 2, 0, -1, -2, 60, 40, 200, 1024, 0, 0, 3 },
    { "vorbis_bad_extradata", "vorbis", 44100, 2, 0, -1, -2, 60, 40, 200, 1024, 0, 40, 1 },
    { "pcm_refused", "pcm_s16le", 44100, 2, 0, -1, -2, 20, 100, 0, 1024, 0, 0, 1 },
};

static int packet_size(const struct Case *c, int i)
{
    return c->base + (c->mod ? (i * 37) % c->mod : 0);
}

static uint8_t packet_byte(int i, int j)
{
    return (uint8_t)(i * 7 + j * 13 + 1);
}

/* The codec's header as extradata: FLAC's STREAMINFO, an OpusHead, or
 * Vorbis' three headers in Xiph lacing; cut to `c->extradata` bytes when
 * that is set. */
static int make_extradata(const struct Case *c, uint8_t *out)
{
    int n = 0;
    if (!strcmp(c->codec, "flac")) {
        for (n = 0; n < 34; n++)
            out[n] = (uint8_t)(n * 5 + 1);
    } else if (!strcmp(c->codec, "opus")) {
        memcpy(out, "OpusHead", 8);
        out[8] = 1;
        out[9] = (uint8_t)c->channels;
        AV_WL16(out + 10, c->padding);
        AV_WL32(out + 12, c->rate);
        AV_WL16(out + 16, 0);
        out[18] = 0;
        n = 19;
    } else if (!strcmp(c->codec, "vorbis")) {
        out[n++] = 2;
        out[n++] = 30;
        out[n++] = 17;
        memcpy(out + n, "\x01vorbis", 7);
        for (int j = 7; j < 30; j++)
            out[n + j] = (uint8_t)j;
        n += 30;
        memcpy(out + n, "\x03vorbis", 7);
        memset(out + n + 7, 'x', 10);
        n += 17;
        memcpy(out + n, "\x05vorbis", 7);
        for (int j = 7; j < 47; j++)
            out[n + j] = (uint8_t)(j * 3);
        n += 47;
    } else {
        n = 0;
    }
    if (c->extradata && c->extradata < n)
        n = c->extradata;
    return n;
}

/* Tag set 1: names the muxer renames and one it keeps; 2: one value
 * longer than a page; 3: stream tags and format tags, the stream's
 * taking precedence. */
static void make_tags(int set, AVDictionary **stream, AVDictionary **format)
{
    if (set == 1) {
        av_dict_set(stream, "title", "Title", 0);
        av_dict_set(stream, "album_artist", "Band", 0);
        av_dict_set(stream, "track", "3", 0);
        av_dict_set(stream, "comment", "Hello", 0);
        av_dict_set(stream, "encoder", "Lavc flac", 0);
    } else if (set == 2) {
        char *value = av_malloc(70001);
        memset(value, 'v', 70000);
        value[70000] = 0;
        av_dict_set(stream, "long", value, AV_DICT_DONT_STRDUP_VAL);
    } else if (set == 3) {
        av_dict_set(stream, "title", "Stream", 0);
        av_dict_set(format, "title", "Format", 0);
        av_dict_set(format, "album", "Album", 0);
        av_dict_set(format, "DISCNUMBER", "2", 0);
    }
}

static void print_error(int err)
{
    if (err == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (err == AVERROR(EINVAL))
        printf("EINVAL");
    else
        printf("%d", err);
}

static void print_pages(const uint8_t *buf, int size)
{
    int pos = 0;
    while (pos + 27 <= size && !memcmp(buf + pos, "OggS", 4)) {
        int nsegs = buf[pos + 26];
        int body = 0;
        for (int i = 0; i < nsegs; i++)
            body += buf[pos + 27 + i];
        printf("P %d %d %" PRId64 " %u %u %d %d\n", pos, buf[pos + 5], (int64_t)AV_RL64(buf + pos + 6),
               AV_RL32(buf + pos + 14), AV_RL32(buf + pos + 18), nsegs, body);
        pos += 27 + nsegs + body;
    }
}

static void run(const struct Case *c)
{
    printf("C %s %s %d %d %d %" PRId64 " %d %d %d %d %d %" PRId64 " %d %d\n", c->name, c->codec, c->rate, c->channels,
           c->padding, c->page_duration, c->serial_offset, c->count, c->base, c->mod, c->duration, c->start,
           c->extradata, c->tags);
    AVFormatContext *fmt = NULL;
    avformat_alloc_output_context2(&fmt, NULL, "ogg", NULL);
    fmt->flags |= AVFMT_FLAG_BITEXACT;
    avio_open_dyn_buf(&fmt->pb);
    AVStream *st = avformat_new_stream(fmt, NULL);
    AVCodecParameters *par = st->codecpar;
    par->codec_type = AVMEDIA_TYPE_AUDIO;
    par->codec_id = !strcmp(c->codec, "flac")     ? AV_CODEC_ID_FLAC
                    : !strcmp(c->codec, "opus")   ? AV_CODEC_ID_OPUS
                    : !strcmp(c->codec, "vorbis") ? AV_CODEC_ID_VORBIS
                                                  : AV_CODEC_ID_PCM_S16LE;
    par->sample_rate = c->rate;
    av_channel_layout_default(&par->ch_layout, c->channels);
    par->initial_padding = c->padding;
    uint8_t header[128];
    int n = make_extradata(c, header);
    if (n) {
        par->extradata = av_mallocz(n + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(par->extradata, header, n);
        par->extradata_size = n;
    }
    make_tags(c->tags, &st->metadata, &fmt->metadata);
    AVDictionary *opts = NULL;
    if (c->page_duration >= 0)
        av_dict_set_int(&opts, "page_duration", c->page_duration, 0);
    if (c->serial_offset >= -1)
        av_dict_set_int(&opts, "serial_offset", c->serial_offset, 0);
    int ret = avformat_write_header(fmt, &opts);
    av_dict_free(&opts);
    printf("H ");
    print_error(ret < 0 ? ret : 0);
    printf("\n");
    if (ret >= 0) {
        AVPacket *pkt = av_packet_alloc();
        int64_t pts = c->start;
        for (int i = 0; i < c->count; i++) {
            int size = packet_size(c, i);
            av_new_packet(pkt, size);
            for (int j = 0; j < size; j++)
                pkt->data[j] = packet_byte(i, j);
            pkt->stream_index = 0;
            pkt->pts = pkt->dts = pts;
            pkt->duration = c->duration;
            pkt->flags = AV_PKT_FLAG_KEY;
            pts += c->duration;
            ret = av_interleaved_write_frame(fmt, pkt);
            av_packet_unref(pkt);
            if (ret < 0) {
                printf("X %d ", i);
                print_error(ret);
                printf("\n");
                break;
            }
        }
        av_packet_free(&pkt);
        ret = av_write_trailer(fmt);
        printf("T ");
        print_error(ret);
        printf("\n");
    }
    uint8_t *buf = NULL;
    int size = avio_close_dyn_buf(fmt->pb, &buf);
    fmt->pb = NULL;
    if (ret >= 0 || size > 0) {
        print_pages(buf, size);
        uint8_t digest[16];
        av_md5_sum(digest, buf, size);
        printf("M %d ", size);
        for (int i = 0; i < 16; i++)
            printf("%02x", digest[i]);
        printf("\n");
    }
    av_free(buf);
    avformat_free_context(fmt);
}

int main(void)
{
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run(&cases[i]);
    return 0;
}
