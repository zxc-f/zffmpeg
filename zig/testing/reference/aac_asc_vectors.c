// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the AAC extradata oracle (zig/testing/vectors/aac_asc.txt): what
// the pinned FFmpeg's float aac decoder makes of an AudioSpecificConfig
// given as extradata (ff_aac_decode_init's decode_audio_specific_config
// path, T33a), and of the raw_data_block packets decoded after it. Each
// case opens a decoder as libavformat's avformat_find_stream_info does:
// avcodec_parameters_to_context from the demuxer's codecpar, then
// avcodec_open2, without the read-ahead. Its packets go through
// avcodec_send_packet and avcodec_receive_frame, with
// AV_CODEC_FLAG2_SKIP_MANUAL so that no edit list or priming trim changes
// the decoder's frames. The cases:
//
// - every AAC stream of each MP4 or MOV file named after the first
//   argument, its extradata, codecpar and packets as the mov demuxer gives
//   them (av_read_frame, no avformat_find_stream_info);
// - crafted configurations in the table below, with the container
//   parameters the mov demuxer would derive, some with packets: the raw
//   data blocks of an ADTS fixture from the directory named by the first
//   argument (its headers, and CRCs, removed).
//
// The lines:
//
//   F <name>                 a case: asc:<case> or <file>:<stream>
//   X <hex>                  the extradata, - for none
//   C <sample_rate> <channels> <frame_size> <profile> <seek_preroll>
//                            the codec context before avcodec_open2
//   O <result>               avcodec_open2's result: ok or the error
//   S <sample_rate> <channels> <mask> <profile> <frame_size> <seek_preroll>
//                            the codec context after the open and after
//                            each packet; the mask is 0 for a layout that
//                            is not in native order
//   K <hex>                  a packet's bytes
//   P <size> <result>        avcodec_send_packet's result
//   D <nb_samples> <sample_rate> <channels> <md5>
//                            a frame received: the MD5 of its float
//                            planes, one after another, little-endian
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
#include "libavutil/mem.h"

static void print_error(int err)
{
    if (err == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else
        printf("%d", err);
}

static void print_hex(const uint8_t *data, int size)
{
    if (size <= 0) {
        printf("-");
        return;
    }
    for (int i = 0; i < size; i++)
        printf("%02x", data[i]);
}

static void print_state(const AVCodecContext *dec)
{
    uint64_t mask = dec->ch_layout.order == AV_CHANNEL_ORDER_NATIVE ? dec->ch_layout.u.mask : 0;
    printf("S %d %d %" PRIu64 " %d %d %d\n", dec->sample_rate, dec->ch_layout.nb_channels, mask,
           dec->profile, dec->frame_size, dec->seek_preroll);
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
        printf("D %d %d %d ", frame->nb_samples, frame->sample_rate, frame->ch_layout.nb_channels);
        for (int i = 0; i < 16; i++)
            printf("%02x", digest[i]);
        printf("\n");
        av_frame_unref(frame);
    }
}

/* The decoder opened from `par`; NULL after printing the failure. */
static AVCodecContext *open_decoder(const AVCodecParameters *par)
{
    const AVCodec *codec = avcodec_find_decoder_by_name("aac");
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    int ret = avcodec_parameters_to_context(dec, par);
    printf("X ");
    print_hex(par->extradata, par->extradata_size);
    printf("\nC %d %d %d %d %d\n", dec->sample_rate, dec->ch_layout.nb_channels, dec->frame_size,
           dec->profile, dec->seek_preroll);
    if (ret >= 0) {
        dec->flags2 |= AV_CODEC_FLAG2_SKIP_MANUAL;
        ret = avcodec_open2(dec, codec, NULL);
    }
    printf("O ");
    if (ret < 0) {
        print_error(ret);
        printf("\n");
        avcodec_free_context(&dec);
        return NULL;
    }
    printf("ok\n");
    print_state(dec);
    return dec;
}

static void decode_packet(AVCodecContext *dec, AVPacket *pkt, AVFrame *frame)
{
    printf("K ");
    print_hex(pkt->data, pkt->size);
    printf("\n");
    int ret = avcodec_send_packet(dec, pkt);
    printf("P %d ", pkt->size);
    print_error(ret < 0 ? ret : 0);
    printf("\n");
    receive(dec, frame);
    print_state(dec);
}

static void run_file(const char *path)
{
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    char name[256];
    snprintf(name, sizeof(name), "%s", base);
    char *dot = strrchr(name, '.');
    if (dot)
        *dot = 0;

    AVFormatContext *probe = NULL;
    if (avformat_open_input(&probe, path, NULL, NULL) < 0) {
        printf("F %s\nO open failed\n", name);
        return;
    }
    unsigned nb_streams = probe->nb_streams;
    for (unsigned s = 0; s < nb_streams; s++) {
        if (probe->streams[s]->codecpar->codec_id != AV_CODEC_ID_AAC)
            continue;
        // Each stream from a fresh open, its packets in file order.
        AVFormatContext *fmt = NULL;
        if (avformat_open_input(&fmt, path, NULL, NULL) < 0)
            continue;
        printf("F %s:%u\n", name, s);
        AVCodecContext *dec = open_decoder(fmt->streams[s]->codecpar);
        if (dec) {
            AVPacket *pkt = av_packet_alloc();
            AVFrame *frame = av_frame_alloc();
            while (av_read_frame(fmt, pkt) >= 0) {
                if (pkt->stream_index == (int)s)
                    decode_packet(dec, pkt, frame);
                av_packet_unref(pkt);
            }
            av_frame_free(&frame);
            av_packet_free(&pkt);
            avcodec_free_context(&dec);
        }
        avformat_close_input(&fmt);
    }
    avformat_close_input(&probe);
}

struct Case {
    const char *name;
    const char *extradata; /* hex, "" for none */
    int sample_rate;
    int channels;
    int frame_size;
    const char *adts; /* an ADTS fixture whose raw data blocks follow, or NULL */
    int packets;
};

/* The configurations, bit by bit: object type (5, or 31 and 6), sampling
 * index (4, and 24 after 15), channel configuration (4), then the object
 * type's specific config. The container's parameters are those the mov
 * demuxer derives from the configuration (ff_mp4_read_dec_config_descr). */
static const struct Case cases[] = {
    /* No extradata: the ADTS path's init, raw blocks with a configuration
     * from the channel count. */
    { "no_extradata", "", 44100, 2, 0, "aac_ffmpeg_is_ms.aac", 6 },
    /* AAC-LC 44100 Hz stereo, GA: frameLength 0, dependsOnCore 0, ext 0. */
    { "lc_stereo_44k", "1210", 44100, 2, 1024, "aac_ffmpeg_is_ms.aac", 6 },
    /* Mono signalled, a CPE found: FFmpeg's "mono with CPE". */
    { "lc_mono_cpe", "1208", 44100, 1, 1024, "aac_ffmpeg_is_ms.aac", 4 },
    /* Explicit SBR: AOT 5, core 22050, stereo, extension 44100, AOT 2. */
    { "he_aot5_stereo", "2b920800", 44100, 2, 1024, "aac_fdk_he_44k_stereo.aac", 5 },
    /* Explicit PS: AOT 29, core 22050, mono, extension 44100. */
    { "hev2_aot29_mono", "eb8a0800", 44100, 1, 1024, "aac_fdk_hev2_44k.aac", 5 },
    /* AAC-LC 24000 mono, then a sync extension: SBR at 48000, no PS
     * extension (PS -1, made 1 by the GA config for one channel). */
    { "he_sync_ext_mono", "130856e598", 48000, 1, 1024, "aac_fdk_he_48k_mono.aac", 5 },
    /* The same with the PS extension saying no PS. */
    { "he_sync_ext_ps0", "130856e59d4800", 48000, 1, 1024, "aac_fdk_he_48k_mono.aac", 4 },
    /* SBR signalled absent, then found in the stream. */
    { "sbr_off", "139056e500", 22050, 2, 1024, "aac_fdk_he_44k_stereo.aac", 4 },
    /* AAC-LC 24000 mono with HE-AACv1 data: implicit SBR, implicit PS. */
    { "implicit_he_mono", "1308", 24000, 1, 1024, "aac_fdk_he_48k_mono.aac", 6 },
    /* Channel configuration 0, a PCE: front SCE 0 and CPE 0, back CPE 1,
     * LFE 0. */
    { "pce_5point1", "118004c8050001088000", 48000, 0, 1024, "aac_ffmpeg_5point1.aac", 4 },
    /* Explicit SBR 5.1. */
    { "he_5point1", "2b318800", 48000, 6, 1024, "aac_fdk_he_5point1.aac", 4 },
    /* A PCE whose comment holds the height extension: CPE 0 on top. */
    { "pce_height", "118004c400002003ac4000", 48000, 0, 1024, NULL, 0 },
    /* A PCE of 90 channels. */
    { "pce_too_many", "118004fffc0021194e95b5f19d6f9df42329d2b6be33adf3be84653a56d7c675be77c000", 48000, 0, 1024, NULL, 0 },
    /* A PCE of one coupling element: no channels. */
    { "pce_cc_only", "118004c000020000", 48000, 0, 1024, NULL, 0 },
    /* A PCE cut short. */
    { "pce_truncated", "118004ffc0", 48000, 0, 1024, NULL, 0 },
    { "short_one_byte", "12", 44100, 0, 1024, NULL, 0 },
    { "bad_sfi_13", "1690", 0, 2, 1024, NULL, 0 },
    { "escape_rate", "1780562210", 44100, 2, 1024, NULL, 0 },
    /* AOT 31, escaped to 32 (Layer-1). */
    { "aot_escape_layer1", "f80840", 44100, 2, 0, NULL, 0 },
    /* ER AAC ELD: frameLength 0, resilience 0, no LD SBR, ELDEXT_TERM,
     * epConfig 0; with an extension payload; with LD SBR; without a
     * channel configuration. */
    { "eld_stereo", "f8e64000", 48000, 2, 512, NULL, 0 },
    { "eld_ext_payload", "f8e64021ab00", 48000, 2, 512, NULL, 0 },
    { "eld_ldsbr", "f8e641", 48000, 2, 512, NULL, 0 },
    { "eld_chan0", "f8e60000", 48000, 0, 512, NULL, 0 },
    /* ER AAC LD, 48000 stereo, extension flag; at 24000 (index 8). */
    { "ld_stereo", "b99100", 48000, 2, 512, NULL, 0 },
    { "ld_bad_sfi", "bc10", 24000, 2, 512, NULL, 0 },
    /* ER AAC LC: resilience flags, epConfig 1, plain. */
    { "er_lc_resflags", "8a11e0", 44100, 2, 1024, NULL, 0 },
    { "er_lc_epconfig", "8a1040", 44100, 2, 1024, NULL, 0 },
    { "er_lc_stereo", "8a1000", 44100, 2, 1024, NULL, 0 },
    /* frameLengthFlag 1: 960-sample frames, with and without SBR. */
    { "frame_960", "1214", 44100, 2, 960, NULL, 0 },
    { "he_frame_960", "2b118a00", 48000, 2, 960, NULL, 0 },
    { "main_44k", "0a10", 44100, 2, 1024, NULL, 0 },
    { "ssr_44k", "1a10", 44100, 2, 1024, NULL, 0 },
    { "ltp_44k", "2210", 44100, 2, 1024, NULL, 0 },
    { "chan_7", "11b8", 48000, 8, 1024, NULL, 0 },
    { "chan_8", "11c0", 48000, 0, 1024, NULL, 0 },
    { "chan_11", "11d8", 48000, 7, 1024, NULL, 0 },
    { "chan_12", "11e0", 48000, 8, 1024, NULL, 0 },
    { "chan_13", "11e8", 48000, 24, 1024, NULL, 0 },
    { "chan_14", "11f0", 48000, 8, 1024, NULL, 0 },
    { "chan_15", "11f8", 48000, 2, 1024, NULL, 0 },
    /* dependsOnCoreCoder with its 14-bit delay. */
    { "depends_on_core", "121291a0", 44100, 2, 1024, NULL, 0 },
    /* ALS without its configuration. */
    { "als_short", "f88840", 44100, 2, 0, NULL, 0 },
    /* AOT 29 shaped as the MP3onMP4 draft. */
    { "mp3onmp4", "e89300", 44100, 2, 0, NULL, 0 },
    /* Explicit SBR mono: output as stereo. */
    { "he_aot5_mono", "2b098800", 48000, 1, 1024, NULL, 0 },
    /* Explicit SBR at the core's rate. */
    { "he_aot5_same_rate", "2a120800", 44100, 2, 1024, NULL, 0 },
    { "trailing_bytes", "1210ffff", 44100, 2, 1024, NULL, 0 },
    /* The extension flag on AAC-LC: extensionFlag3 read. */
    { "ext_flag_lc", "121100", 44100, 2, 1024, NULL, 0 },
    /* The container's rate past 96000, its channel count past 512, a
     * rate of 0. */
    { "rate_192k", "1210", 192000, 2, 1024, NULL, 0 },
    { "channels_513", "1210", 44100, 513, 1024, NULL, 0 },
    { "rate_0", "1210", 0, 2, 1024, "aac_ffmpeg_is_ms.aac", 2 },
};

static int unhex(const char *hex, uint8_t *out)
{
    int n = 0;
    for (; hex[0] && hex[1]; hex += 2) {
        unsigned v;
        sscanf(hex, "%2x", &v);
        out[n++] = v;
    }
    return n;
}

static void run_case(const char *adts_dir, const struct Case *c)
{
    printf("F asc:%s\n", c->name);
    AVCodecParameters *par = avcodec_parameters_alloc();
    par->codec_type = AVMEDIA_TYPE_AUDIO;
    par->codec_id = AV_CODEC_ID_AAC;
    par->sample_rate = c->sample_rate;
    par->ch_layout.order = AV_CHANNEL_ORDER_UNSPEC;
    par->ch_layout.nb_channels = c->channels;
    par->frame_size = c->frame_size;
    size_t len = strlen(c->extradata) / 2;
    if (len) {
        par->extradata = av_mallocz(len + AV_INPUT_BUFFER_PADDING_SIZE);
        par->extradata_size = unhex(c->extradata, par->extradata);
    }
    AVCodecContext *dec = open_decoder(par);
    avcodec_parameters_free(&par);
    if (!dec)
        return;
    if (c->adts) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/%s", adts_dir, c->adts);
        AVFormatContext *fmt = NULL;
        if (avformat_open_input(&fmt, path, NULL, NULL) < 0) {
            fprintf(stderr, "cannot open %s\n", path);
            exit(1);
        }
        AVPacket *pkt = av_packet_alloc();
        AVPacket *raw = av_packet_alloc();
        AVFrame *frame = av_frame_alloc();
        int sent = 0;
        while (sent < c->packets && av_read_frame(fmt, pkt) >= 0) {
            const uint8_t *h = pkt->data;
            // One raw data block a frame: the header, then the CRC unless
            // protection_absent.
            if (pkt->size > 9 && h[0] == 0xff && (h[1] & 0xf6) == 0xf0 && (h[6] & 3) == 0) {
                int header = (h[1] & 1) ? 7 : 9;
                av_new_packet(raw, pkt->size - header);
                memcpy(raw->data, pkt->data + header, pkt->size - header);
                decode_packet(dec, raw, frame);
                av_packet_unref(raw);
                sent++;
            }
            av_packet_unref(pkt);
        }
        av_frame_free(&frame);
        av_packet_free(&raw);
        av_packet_free(&pkt);
        avformat_close_input(&fmt);
    }
    avcodec_free_context(&dec);
}

/* Files in byte order (strcmp), whatever order the shell expanded a glob
 * in. */
static int by_name(const void *a, const void *b)
{
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int main(int argc, char **argv)
{
    av_log_set_level(AV_LOG_QUIET);
    if (argc < 2) {
        fprintf(stderr, "usage: aac-asc-vectors <adts fixture dir> <mp4 files...>\n");
        return 1;
    }
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run_case(argv[1], &cases[i]);
    qsort(argv + 2, argc - 2, sizeof(*argv), by_name);
    for (int i = 2; i < argc; i++)
        run_file(argv[i]);
    return 0;
}
