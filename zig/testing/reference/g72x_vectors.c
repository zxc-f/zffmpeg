// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T31c G.722 and G.726 oracle (zig/testing/vectors/g72x.txt):
// what the pinned FFmpeg's g722 and g726le encoders make of deterministic
// mono signals through the public API, each packet decoded back by the
// matching decoder; then what the decoders make of pseudo-random bytes.
// The lines:
//
//   E <name> <codec> <option> <signal> <samples> <frame> <bit_rate>
//                                an encoder case: codec g722 (option: the
//                                trellis; frame: the frame size asked for,
//                                0 for the default) or g726le (option: the
//                                code_size option; bit_rate: the bit rate
//                                asked for, 0 for none); frames of the
//                                encoder's frame size, the last one short
//   O <result> <frame_size> <bits_per_coded_sample>
//                                avcodec_open2: ok or the error
//   P <size> <md5>               each packet and the MD5 of its bytes
//   D <result> <nb_samples> <md5>
//                                a packet decoded (one decoder for the
//                                case): the result, the samples and the
//                                MD5 of the s16 samples, little-endian
//   R <codec> <bits> <seed> <size>...
//                                a decoder case: packets of these sizes of
//                                pseudo-random bytes from the seed, decoded
//                                in turn by one decoder (g722: bits per
//                                codeword; g726le: code size)
//   D ...                        as above, one a packet
//
// The signals and bytes come from integer arithmetic only, so the Zig test
// makes the same ones. See zig/testing/reference/README.md for the build
// commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/channel_layout.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/md5.h"
#include "libavutil/opt.h"

static uint32_t rng_state;

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

// Sample `i`: a tone, smoothed noise, noise, silence or full-scale
// extremes (alac_vectors.c's 16-bit signals, one channel).
static int sample(const char *signal, int i, int *state)
{
    const int noise = (int)(rng() & 0xffff) - 0x8000;
    int v;
    if (!strcmp(signal, "tone")) {
        const int period = 64;
        const int phase = i % period;
        const int tri = phase < period / 2 ? phase : period - phase;
        v = (tri * 2 - period / 2) * 16384 / (period / 2) + noise / 8;
    } else if (!strcmp(signal, "smooth")) {
        *state += (noise - *state) / 8;
        v = *state * 2;
    } else if (!strcmp(signal, "noise")) {
        v = noise;
    } else if (!strcmp(signal, "silence")) {
        v = 0;
    } else {
        v = (i & 1) ? 32767 : -32768;
        if (rng() & 1)
            v = -32768;
    }
    if (v < -32768)
        v = -32768;
    if (v > 32767)
        v = 32767;
    return v;
}

static void print_result(int ret)
{
    if (ret == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (ret == AVERROR(EINVAL))
        printf("EINVAL");
    else if (ret == AVERROR(EAGAIN))
        printf("EAGAIN");
    else
        printf("%d", ret);
}

static void print_md5(const uint8_t *data, int size)
{
    uint8_t digest[16];
    av_md5_sum(digest, data, size);
    for (int i = 0; i < 16; i++)
        printf("%02x", digest[i]);
}

static enum AVCodecID codec_id(const char *codec)
{
    return !strcmp(codec, "g722") ? AV_CODEC_ID_ADPCM_G722 : AV_CODEC_ID_ADPCM_G726LE;
}

static AVCodecContext *open_decoder(const char *codec, int bits)
{
    const AVCodec *c = avcodec_find_decoder(codec_id(codec));
    AVCodecContext *dec = avcodec_alloc_context3(c);
    av_channel_layout_default(&dec->ch_layout, 1);
    if (!strcmp(codec, "g722")) {
        dec->sample_rate = 16000;
        av_opt_set_int(dec->priv_data, "bits_per_codeword", bits, 0);
    } else {
        dec->sample_rate = 8000;
        dec->bits_per_coded_sample = bits;
    }
    if (avcodec_open2(dec, c, NULL) < 0) {
        printf("decoder failed to open\n");
        avcodec_free_context(&dec);
    }
    return dec;
}

static void decode_line(AVCodecContext *dec, const uint8_t *data, int size)
{
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    av_new_packet(pkt, size);
    memcpy(pkt->data, data, size);
    int ret = avcodec_send_packet(dec, pkt);
    if (ret >= 0)
        ret = avcodec_receive_frame(dec, frame);
    printf("D ");
    if (ret < 0) {
        print_result(ret);
        printf(" 0 -\n");
    } else {
        printf("0 %d ", frame->nb_samples);
        print_md5(frame->data[0], frame->nb_samples * 2);
        printf("\n");
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
}

struct Case {
    const char *name, *codec;
    int option;
    const char *signal;
    int samples, frame, bit_rate;
};

static const struct Case cases[] = {
    { "g722_tone", "g722", 0, "tone", 5000, 0, 0 },
    { "g722_smooth", "g722", 0, "smooth", 4000, 0, 0 },
    { "g722_noise", "g722", 0, "noise", 3000, 0, 0 },
    { "g722_silence", "g722", 0, "silence", 700, 0, 0 },
    { "g722_extremes", "g722", 0, "extremes", 3000, 0, 0 },
    { "g722_odd_last", "g722", 0, "tone", 1001, 0, 0 },
    { "g722_frame1", "g722", 0, "smooth", 9, 1, 0 },
    { "g722_frame255", "g722", 0, "tone", 1000, 255, 0 },
    { "g722_frame_max", "g722", 0, "smooth", 70001, 40000, 0 },
    { "g722_t1", "g722", 1, "tone", 3000, 0, 0 },
    { "g722_t2", "g722", 2, "smooth", 3000, 0, 0 },
    { "g722_t4", "g722", 4, "noise", 3000, 0, 0 },
    { "g722_t4_extremes", "g722", 4, "extremes", 2000, 0, 0 },
    { "g722_t8", "g722", 8, "tone", 2000, 0, 0 },
    { "g722_t3_long", "g722", 3, "smooth", 2000, 600, 0 },
    { "g722_t3_256", "g722", 3, "tone", 2049, 512, 0 },
    { "g722_t3_258", "g722", 3, "smooth", 1000, 258, 0 },
    { "g722_t2_short", "g722", 2, "tone", 101, 50, 0 },
    { "g722_t2_odd", "g722", 2, "smooth", 333, 0, 0 },
    { "g722_t2_one", "g722", 2, "tone", 1, 0, 0 },
    { "g722_t99", "g722", 99, "tone", 16, 0, 0 },
    { "g722_tneg", "g722", -2, "tone", 700, 0, 0 },
    { "g726_2_tone", "g726le", 2, "tone", 9000, 0, 0 },
    { "g726_3_smooth", "g726le", 3, "smooth", 6000, 0, 0 },
    { "g726_4_tone", "g726le", 4, "tone", 5000, 0, 0 },
    { "g726_5_noise", "g726le", 5, "noise", 4000, 0, 0 },
    { "g726_4_extremes", "g726le", 4, "extremes", 3000, 0, 0 },
    { "g726_2_extremes", "g726le", 2, "extremes", 3000, 0, 0 },
    { "g726_5_extremes", "g726le", 5, "extremes", 3000, 0, 0 },
    { "g726_3_silence", "g726le", 3, "silence", 3000, 0, 0 },
    { "g726_3_noise", "g726le", 3, "noise", 3000, 0, 0 },
    { "g726_2_smooth", "g726le", 2, "smooth", 3000, 0, 0 },
    { "g726_rate_24k", "g726le", 4, "tone", 3000, 0, 24000 },
    { "g726_rate_odd", "g726le", 4, "smooth", 3000, 0, 35999 },
    { "g726_rate_low", "g726le", 4, "tone", 2000, 0, 1000 },
    { "g726_rate_high", "g726le", 4, "tone", 2000, 0, 900000 },
    { "g726_one", "g726le", 3, "tone", 1, 0, 0 },
};

#define NCASES (sizeof(cases) / sizeof(cases[0]))

static void encode_case(int k)
{
    const struct Case *t = &cases[k];
    printf("E %s %s %d %s %d %d %d\n", t->name, t->codec, t->option, t->signal, t->samples,
           t->frame, t->bit_rate);
    const int g722 = !strcmp(t->codec, "g722");
    const AVCodec *codec = avcodec_find_encoder(codec_id(t->codec));
    AVCodecContext *enc = avcodec_alloc_context3(codec);
    enc->sample_rate = g722 ? 16000 : 8000;
    av_channel_layout_default(&enc->ch_layout, 1);
    enc->sample_fmt = AV_SAMPLE_FMT_S16;
    if (g722) {
        enc->trellis = t->option;
        enc->frame_size = t->frame;
    } else {
        av_opt_set_int(enc->priv_data, "code_size", t->option, 0);
        enc->bit_rate = t->bit_rate;
    }
    int ret = avcodec_open2(enc, codec, NULL);
    printf("O ");
    if (ret < 0) {
        print_result(ret);
        printf(" 0 0\n");
        avcodec_free_context(&enc);
        return;
    }
    printf("ok %d %d\n", enc->frame_size, enc->bits_per_coded_sample);
    AVCodecContext *dec = open_decoder(t->codec, g722 ? 8 : enc->bits_per_coded_sample);

    rng_state = 0x9E3779B9u ^ (uint32_t)(t->samples * 7 + k);
    int state = 0;
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    for (int at = 0; at < t->samples; at += enc->frame_size) {
        const int n = t->samples - at < enc->frame_size ? t->samples - at : enc->frame_size;
        frame->nb_samples = n;
        frame->format = enc->sample_fmt;
        av_channel_layout_copy(&frame->ch_layout, &enc->ch_layout);
        av_frame_get_buffer(frame, 0);
        for (int i = 0; i < n; i++)
            ((int16_t *)frame->data[0])[i] = sample(t->signal, at + i, &state);
        avcodec_send_frame(enc, frame);
        av_frame_unref(frame);
        while (avcodec_receive_packet(enc, pkt) == 0) {
            printf("P %d ", pkt->size);
            print_md5(pkt->data, pkt->size);
            printf("\n");
            decode_line(dec, pkt->data, pkt->size);
            av_packet_unref(pkt);
        }
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avcodec_free_context(&enc);
}

static void random_case(const char *codec, int bits, uint32_t seed, const int *sizes, int count)
{
    printf("R %s %d %u", codec, bits, seed);
    for (int i = 0; i < count; i++)
        printf(" %d", sizes[i]);
    printf("\n");
    AVCodecContext *dec = open_decoder(codec, bits);
    rng_state = seed;
    for (int i = 0; i < count; i++) {
        uint8_t data[4096];
        for (int b = 0; b < sizes[i]; b++)
            data[b] = rng() >> 24;
        decode_line(dec, data, sizes[i]);
    }
    avcodec_free_context(&dec);
}

int main(void)
{
    av_log_set_level(AV_LOG_QUIET);
    for (int k = 0; k < (int)NCASES; k++)
        encode_case(k);
    static const int sizes[] = { 1, 7, 160, 1000, 2, 3, 4096 };
    for (int bits = 6; bits <= 8; bits++)
        random_case("g722", bits, 1000u + bits, sizes, 7);
    for (int bits = 2; bits <= 5; bits++)
        random_case("g726le", bits, 2000u + bits, sizes, 7);
    return 0;
}
