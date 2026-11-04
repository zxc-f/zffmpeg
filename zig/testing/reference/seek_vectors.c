// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T52a seek oracle (zig/testing/vectors/seek.txt): what the pinned
// FFmpeg's libavformat does when each WAV fixture named on the command line
// is seeked, opened as the ffmpeg program opens an input. For every seek the
// file is opened afresh, one packet is read (as the ffmpeg program's
// avformat_find_stream_info does), the seek is made, and the next packet is
// read and decoded. The lines:
//
//   F <name>                       a fixture
//   O <result>                     opening it: ok or the error
//   I <data offset> <size> <block_align> <bit_rate> <time base>
//                                  the first packet's byte position, the
//                                  file size, and the stream's parameters
//   K <api> <stream> <ts> [<min> <max>] <flags> <ret>
//                                  a seek: api f (av_seek_frame) or s
//                                  (avformat_seek_file), the stream index,
//                                  the timestamp (and bounds), flags in hex
//                                  (1 backward, 2 byte, 4 any), and its
//                                  return value
//   P <pts> <pos> <size>           the next packet after it (pts N when
//                                  unset), or `P EOF`
//   D <nb_samples> <hex>           the decoded frame's first 16 sample
//                                  frames, as stored (packed formats)
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/avutil.h"
#include "libavutil/log.h"
#include "libavutil/samplefmt.h"

struct Opened {
    AVFormatContext *fmt;
    AVCodecContext *dec;
};

static int open_file(const char *path, struct Opened *o)
{
    memset(o, 0, sizeof(*o));
    int ret = avformat_open_input(&o->fmt, path, NULL, NULL);
    if (ret < 0)
        return ret;
    ret = avformat_find_stream_info(o->fmt, NULL);
    if (ret < 0) {
        avformat_close_input(&o->fmt);
        return ret;
    }
    AVCodecParameters *par = o->fmt->streams[0]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec)
        return AVERROR_DECODER_NOT_FOUND;
    o->dec = avcodec_alloc_context3(codec);
    if (!o->dec || avcodec_parameters_to_context(o->dec, par) < 0 || avcodec_open2(o->dec, codec, NULL) < 0)
        return AVERROR(ENOMEM);
    return 0;
}

static void close_file(struct Opened *o)
{
    avcodec_free_context(&o->dec);
    avformat_close_input(&o->fmt);
}

static void print_error(int err)
{
    if (err == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (err == AVERROR_EOF)
        printf("EOF");
    else if (err == AVERROR(EINVAL))
        printf("EINVAL");
    else if (err == AVERROR(ENOSYS))
        printf("ENOSYS");
    else
        printf("%d", err);
}

static void print_next(struct Opened *o)
{
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int ret = av_read_frame(o->fmt, pkt);
    if (ret < 0) {
        printf("P ");
        print_error(ret);
        printf("\n");
    } else {
        printf("P ");
        if (pkt->pts == AV_NOPTS_VALUE)
            printf("N");
        else
            printf("%" PRId64, pkt->pts);
        printf(" %" PRId64 " %d\n", pkt->pos, pkt->size);
        avcodec_flush_buffers(o->dec);
        if (avcodec_send_packet(o->dec, pkt) >= 0 && avcodec_receive_frame(o->dec, frame) >= 0) {
            int bytes = av_get_bytes_per_sample(frame->format) * frame->ch_layout.nb_channels;
            int frames = frame->nb_samples < 16 ? frame->nb_samples : 16;
            printf("D %d ", frame->nb_samples);
            for (int i = 0; i < frames * bytes; i++)
                printf("%02x", frame->data[0][i]);
            printf("\n");
        } else {
            printf("D none\n");
        }
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
}

/* One seek on a freshly opened file: api 'f' or 's'. */
static void run_seek(const char *path, char api, int stream, int64_t ts, int64_t min_ts, int64_t max_ts, int flags)
{
    struct Opened o;
    if (open_file(path, &o) < 0) {
        close_file(&o);
        return;
    }
    AVPacket *pkt = av_packet_alloc();
    av_read_frame(o.fmt, pkt);
    av_packet_free(&pkt);
    int ret;
    if (api == 'f') {
        ret = av_seek_frame(o.fmt, stream, ts, flags);
        printf("K f %d %" PRId64 " %x ", stream, ts, flags);
    } else {
        ret = avformat_seek_file(o.fmt, stream, min_ts, ts, max_ts, flags);
        printf("K s %d %" PRId64 " %" PRId64 " %" PRId64 " %x ", stream, ts, min_ts, max_ts, flags);
    }
    print_error(ret == 0 ? 0 : ret);
    printf("\n");
    if (ret >= 0)
        print_next(&o);
    close_file(&o);
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

    struct Opened o;
    int ret = open_file(path, &o);
    printf("O ");
    if (ret < 0) {
        print_error(ret);
        printf("\n");
        close_file(&o);
        return;
    }
    printf("ok\n");
    AVStream *st = o.fmt->streams[0];
    AVPacket *pkt = av_packet_alloc();
    int64_t data_offset = -1;
    if (av_read_frame(o.fmt, pkt) >= 0)
        data_offset = pkt->pos;
    av_packet_free(&pkt);
    int64_t size = avio_size(o.fmt->pb);
    int block_align = st->codecpar->block_align;
    int64_t frames = st->duration;
    printf("I %" PRId64 " %" PRId64 " %d %" PRId64 " %d/%d\n", data_offset, size, block_align, st->codecpar->bit_rate,
           st->time_base.num, st->time_base.den);
    close_file(&o);
    if (frames < 0 || frames == AV_NOPTS_VALUE)
        frames = 0;

    const int64_t timestamps[] = { 0, 1, 3, frames / 2, frames - 1, frames, frames + 7, -5 };
    const int flag_sets[] = { 0, AVSEEK_FLAG_BACKWARD, AVSEEK_FLAG_ANY };
    for (size_t i = 0; i < sizeof(timestamps) / sizeof(timestamps[0]); i++)
        for (size_t j = 0; j < sizeof(flag_sets) / sizeof(flag_sets[0]); j++)
            run_seek(path, 'f', 0, timestamps[i], 0, 0, flag_sets[j]);
    // AV_TIME_BASE units on the default stream.
    const int64_t micros[] = { 0, 1, 125, 1000, 250000, 1000000 };
    for (size_t i = 0; i < sizeof(micros) / sizeof(micros[0]); i++) {
        run_seek(path, 'f', -1, micros[i], 0, 0, 0);
        run_seek(path, 'f', -1, micros[i], 0, 0, AVSEEK_FLAG_BACKWARD);
        // The ffmpeg program's -ss.
        run_seek(path, 's', -1, micros[i], INT64_MIN, INT64_MAX, 0);
    }
    run_seek(path, 's', 0, frames / 2, INT64_MIN, INT64_MAX, 0);
    run_seek(path, 's', 0, frames / 2, frames / 2, INT64_MAX, 0);
    run_seek(path, 's', 0, 1, 0, 2, 0);
    // A stream the file does not have.
    run_seek(path, 'f', 1, 0, 0, 0, 0);
    if (data_offset >= 0) {
        const int64_t positions[] = {
            0, data_offset - 1, data_offset, data_offset + 1, data_offset + block_align,
            size - 1, size, size + 100,
        };
        for (size_t i = 0; i < sizeof(positions) / sizeof(positions[0]); i++)
            run_seek(path, 'f', 0, positions[i], 0, 0, AVSEEK_FLAG_BYTE);
    }
}

int main(int argc, char **argv)
{
    av_log_set_level(AV_LOG_QUIET);
    for (int i = 1; i < argc; i++)
        run(argv[i]);
    return 0;
}
