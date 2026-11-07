// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T31b ALAC oracle (zig/testing/vectors/alac.txt): what the
// pinned FFmpeg's ALAC encoder makes of deterministic signals through the
// public API (avcodec_open2 with the case's compression level and
// prediction orders, frames of 4096 samples, the last one short), each
// packet decoded back by the decoder; then what the decoder makes of those
// packets with bits flipped or cut short, under the encoder's magic cookie
// or one changed to another sample size, and with extra_bits_bug.
// The lines:
//
//   E <name> <signal> <channels> <bits> <level> <min> <max> <samples>
//                                an encoder case (bits 16: s16p; 24: s32p)
//   O <result>                   avcodec_open2: ok or the error
//   I <cookie hex>               the encoder's extradata
//   P <size> <md5>               each packet and the MD5 of its bytes
//   D <result> <nb_samples> <md5>
//                                a packet decoded: the result (the send's,
//                                then the receive's; EAGAIN for no frame),
//                                the samples and the MD5 of the planes in
//                                order, little-endian, as stored (16 bits
//                                for s16p, 32 for s32p)
//   M <case> <cookie> <bug> <packet> <seed> <flips> <cut>
//                                a decoder case: the case's packet with
//                                `flips` bits flipped (positions from the
//                                seed) and cut to `cut` bytes (-1: whole),
//                                decoded by a fresh decoder under the
//                                case's cookie with sample size `cookie`
//                                (0: as encoded), extra_bits_bug `bug`
//   D ...                        as above
//
// The signals and mutations come from integer arithmetic only, so the Zig
// test makes the same ones. See zig/testing/reference/README.md for the
// build commands.

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

// ff_alac_ch_layouts' masks, by channel count.
static const uint64_t alac_masks[8] = { 0x4, 0x3, 0x7, 0x107, 0x37, 0x3f, 0x13f, 0xff };

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

// Sample `i` of channel `c` at 16 bits: a tone, smoothed noise, noise,
// silence or full-scale extremes, every channel drawing from the one
// generator; at 24 bits, the 16-bit value and 8 more noise bits.
static int sample(const char *signal, int c, int i, int *state, int bits)
{
    const int noise = (int)(rng() & 0xffff) - 0x8000;
    int v;
    if (!strcmp(signal, "tone")) {
        const int period = 64 + 24 * c;
        const int phase = i % period;
        const int tri = phase < period / 2 ? phase : period - phase;
        v = (tri * 2 - period / 2) * 16384 / (period / 2) + noise / 8;
    } else if (!strcmp(signal, "smooth")) {
        state[c] += (noise - state[c]) / 8;
        v = state[c] * 2;
    } else if (!strcmp(signal, "noise")) {
        v = noise;
    } else if (!strcmp(signal, "silence")) {
        v = 0;
    } else {
        v = ((i + c) & 1) ? 32767 : -32768;
        if (rng() & 1)
            v = -32768;
    }
    if (v < -32768)
        v = -32768;
    if (v > 32767)
        v = 32767;
    if (bits == 24 && strcmp(signal, "silence"))
        v = v * 256 + (int)(rng() & 0xff);
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
    else if (ret == AVERROR_PATCHWELCOME)
        printf("PATCHWELCOME");
    else if (ret == AVERROR(ENOSYS))
        printf("ENOSYS");
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

static AVCodecContext *open_decoder(const uint8_t *cookie, int channels, int bug, int *ret)
{
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_ALAC);
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    dec->extradata = av_mallocz(36 + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(dec->extradata, cookie, 36);
    dec->extradata_size = 36;
    av_channel_layout_from_mask(&dec->ch_layout, alac_masks[channels - 1]);
    if (bug)
        av_opt_set_int(dec->priv_data, "extra_bits_bug", 1, 0);
    *ret = avcodec_open2(dec, codec, NULL);
    return dec;
}

// Decodes one packet with `dec` and prints its D line.
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
        struct AVMD5 *md5 = av_md5_alloc();
        av_md5_init(md5);
        const int width = av_get_bytes_per_sample(frame->format);
        for (int c = 0; c < frame->ch_layout.nb_channels; c++)
            av_md5_update(md5, frame->extended_data[c], frame->nb_samples * width);
        uint8_t digest[16];
        av_md5_final(md5, digest);
        av_free(md5);
        printf("0 %d ", frame->nb_samples);
        for (int i = 0; i < 16; i++)
            printf("%02x", digest[i]);
        printf("\n");
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
}

struct Case {
    const char *name, *signal;
    int channels, bits, level, min_order, max_order, samples;
};

static const struct Case cases[] = {
    { "mono_tone", "tone", 1, 16, -1, 4, 6, 10000 },
    { "stereo_smooth", "smooth", 2, 16, -1, 4, 6, 9000 },
    { "stereo_noise", "noise", 2, 16, -1, 4, 6, 5000 },
    { "stereo_silence", "silence", 2, 16, -1, 4, 6, 4100 },
    { "stereo_extremes", "extremes", 2, 16, -1, 4, 6, 3000 },
    { "mono_level0", "tone", 1, 16, 0, 4, 6, 5000 },
    { "stereo_level1", "smooth", 2, 16, 1, 4, 6, 5000 },
    { "stereo_level9", "tone", 2, 16, 9, 4, 6, 3000 },
    { "stereo24_smooth", "smooth", 2, 24, -1, 4, 6, 9000 },
    { "mono24_tone", "tone", 1, 24, -1, 4, 6, 5000 },
    { "stereo24_level1", "tone", 2, 24, 1, 4, 6, 4500 },
    { "stereo24_level0", "smooth", 2, 24, 0, 4, 6, 3000 },
    { "ch3", "smooth", 3, 16, -1, 4, 6, 4200 },
    { "ch4", "tone", 4, 16, -1, 4, 6, 3000 },
    { "ch5", "smooth", 5, 16, -1, 4, 6, 3000 },
    { "ch6", "tone", 6, 16, -1, 4, 6, 3000 },
    { "ch7", "smooth", 7, 16, -1, 4, 6, 2000 },
    { "ch8", "tone", 8, 16, -1, 4, 6, 2000 },
    { "ch6_24", "smooth", 6, 24, -1, 4, 6, 2000 },
    { "orders_1_1", "smooth", 2, 16, -1, 1, 1, 5000 },
    { "orders_1_30", "tone", 2, 16, -1, 1, 30, 5000 },
    { "orders_8_12", "smooth", 1, 16, -1, 8, 12, 5000 },
    { "orders_30_30", "tone", 1, 24, -1, 30, 30, 5000 },
    { "orders_bad", "tone", 1, 16, -1, 7, 5, 100 },
    { "one_sample", "tone", 2, 16, -1, 4, 6, 1 },
    { "two_samples", "smooth", 1, 16, -1, 4, 6, 2 },
    { "five_samples", "tone", 2, 24, -1, 4, 6, 5 },
    { "short_last", "smooth", 2, 16, -1, 1, 30, 4096 + 17 },
};

#define NCASES (sizeof(cases) / sizeof(cases[0]))

// Each case's cookie and packets, for the decoder cases.
static uint8_t cookies[NCASES][36];
static uint8_t *packets[NCASES][8];
static int packet_sizes[NCASES][8];
static int packet_counts[NCASES];

static void encode_case(int k)
{
    const struct Case *t = &cases[k];
    printf("E %s %s %d %d %d %d %d %d\n", t->name, t->signal, t->channels, t->bits, t->level,
           t->min_order, t->max_order, t->samples);
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_ALAC);
    AVCodecContext *enc = avcodec_alloc_context3(codec);
    enc->sample_rate = 44100;
    av_channel_layout_from_mask(&enc->ch_layout, alac_masks[t->channels - 1]);
    enc->sample_fmt = t->bits == 16 ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S32P;
    enc->bits_per_raw_sample = t->bits;
    enc->compression_level = t->level;
    av_opt_set_int(enc->priv_data, "min_prediction_order", t->min_order, 0);
    av_opt_set_int(enc->priv_data, "max_prediction_order", t->max_order, 0);
    int ret = avcodec_open2(enc, codec, NULL);
    printf("O ");
    if (ret < 0) {
        print_result(ret);
        printf("\n");
        avcodec_free_context(&enc);
        return;
    }
    printf("ok\nI ");
    for (int i = 0; i < enc->extradata_size; i++)
        printf("%02x", enc->extradata[i]);
    printf("\n");
    memcpy(cookies[k], enc->extradata, 36);
    int dec_ret;
    AVCodecContext *dec = open_decoder(enc->extradata, t->channels, 0, &dec_ret);

    rng_state = 0x9E3779B9u ^ (uint32_t)(t->channels * 1000003 + t->samples + t->bits * 7 + k);
    int state[8] = { 0 };
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    for (int at = 0; at < t->samples; at += enc->frame_size) {
        const int n = t->samples - at < enc->frame_size ? t->samples - at : enc->frame_size;
        frame->nb_samples = n;
        frame->format = enc->sample_fmt;
        av_channel_layout_copy(&frame->ch_layout, &enc->ch_layout);
        av_frame_get_buffer(frame, 0);
        for (int i = 0; i < n; i++) {
            for (int c = 0; c < t->channels; c++) {
                const int v = sample(t->signal, c, at + i, state, t->bits);
                if (t->bits == 16)
                    ((int16_t *)frame->extended_data[c])[i] = v;
                else
                    ((int32_t *)frame->extended_data[c])[i] = (int32_t)((uint32_t)v << 8);
            }
        }
        avcodec_send_frame(enc, frame);
        av_frame_unref(frame);
        while (avcodec_receive_packet(enc, pkt) == 0) {
            printf("P %d ", pkt->size);
            print_md5(pkt->data, pkt->size);
            printf("\n");
            decode_line(dec, pkt->data, pkt->size);
            if (packet_counts[k] < 8) {
                packets[k][packet_counts[k]] = av_memdup(pkt->data, pkt->size);
                packet_sizes[k][packet_counts[k]] = pkt->size;
                packet_counts[k]++;
            }
            av_packet_unref(pkt);
        }
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avcodec_free_context(&enc);
}

// A mutated packet of case `k` decoded under a cookie changed to sample
// size `size` (0: unchanged).
static void mutate_case(int k, int size, int bug, int index, uint32_t seed, int flips, int cut)
{
    if (index >= packet_counts[k])
        return;
    printf("M %s %d %d %d %u %d %d\n", cases[k].name, size, bug, index, seed, flips, cut);
    uint8_t cookie[36];
    memcpy(cookie, cookies[k], 36);
    if (size)
        cookie[17] = size;
    int len = packet_sizes[k][index];
    uint8_t *data = av_memdup(packets[k][index], len);
    rng_state = seed;
    for (int f = 0; f < flips; f++) {
        const uint32_t bit = rng() % (uint32_t)(len * 8);
        data[bit / 8] ^= 0x80 >> (bit % 8);
    }
    if (cut >= 0 && cut < len)
        len = cut;
    int ret;
    AVCodecContext *dec = open_decoder(cookie, cases[k].channels, bug, &ret);
    if (ret < 0) {
        printf("D ");
        print_result(ret);
        printf(" 0 -\n");
    } else {
        decode_line(dec, data, len);
    }
    avcodec_free_context(&dec);
    av_free(data);
}

int main(void)
{
    av_log_set_level(AV_LOG_QUIET);
    for (int k = 0; k < (int)NCASES; k++)
        encode_case(k);
    // Bit flips, cuts, other sample sizes and the extra bits option, each
    // on the cases with the paths they reach.
    static const int targets[] = { 0, 1, 2, 4, 5, 6, 8, 10, 12, 17, 19, 27 };
    for (int t = 0; t < (int)(sizeof(targets) / sizeof(targets[0])); t++) {
        const int k = targets[t];
        for (uint32_t s = 1; s <= 12; s++)
            mutate_case(k, 0, 0, 0, s * 2654435761u, 1 + (int)(s % 4), -1);
        for (int cut = 1; cut < 40; cut += 6)
            mutate_case(k, 0, 0, 0, 7, 0, cut);
        mutate_case(k, 0, 0, packet_counts[k] - 1, 99, 0, packet_sizes[k][packet_counts[k] - 1] - 1);
        mutate_case(k, 20, 0, 0, 1, 0, -1);
        mutate_case(k, 32, 0, 0, 1, 0, -1);
        mutate_case(k, 8, 0, 0, 1, 0, -1);
        mutate_case(k, 0, 1, 0, 1, 0, -1);
    }
    return 0;
}
