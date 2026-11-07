// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T31a ADPCM oracle (zig/testing/vectors/adpcm.txt): what the
// pinned FFmpeg's adpcm_ima_wav and adpcm_ms encoders make of deterministic
// 16-bit signals through the public API (avcodec_open2 with the case's
// block_size and trellis, frames of frame_size samples, the last one short,
// which libavcodec pads with silence), each packet decoded back by the
// matching decoder; then what the decoders make of pseudo-random blocks,
// whole, cut short and of every bit depth and channel count they take.
// The lines:
//
//   E <name> <encoder> <signal> <channels> <block_size> <trellis> <samples>
//                                an encoder case
//   O <result>                   avcodec_open2: ok or the error
//   I <frame_size> <block_align> <extradata hex or ->
//   P <size> <md5>               each packet and the MD5 of its bytes
//   H <size> <defined> <md5>     a packet of which FFmpeg writes only the
//                                first `defined` bytes (MS mono with
//                                trellis, which codes half the block's
//                                nibbles): their MD5; the rest is memory it
//                                never wrote, so the packet is not decoded
//   D <result> <nb_samples> <md5>
//                                that packet decoded: the result
//                                (avcodec_send_packet's, then
//                                avcodec_receive_frame's), the samples and
//                                the MD5 of the channels' planes in order,
//                                little-endian
//   R <decoder> <channels> <block_align> <bits> <seed> <size>
//                                a decoder case: a block of `size` bytes
//                                from the seed, decoded alone by a fresh
//                                decoder
//   D ...                        as above
//
// The signals and blocks come from integer arithmetic only, so the Zig test
// makes the same ones. See zig/testing/reference/README.md for the build
// commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/channel_layout.h"
#include "libavutil/error.h"
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

// Sample `i` of channel `c`: a tone, smoothed noise, noise, silence or
// full-scale extremes, every channel drawing from the one generator.
static int sample(const char *signal, int c, int i, int *state)
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
    return v;
}

static void print_result(int ret)
{
    if (ret == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else if (ret == AVERROR(EINVAL))
        printf("EINVAL");
    else
        printf("%d", ret);
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
        const int channels = dec->ch_layout.nb_channels;
        for (int c = 0; c < channels; c++) {
            for (int i = 0; i < frame->nb_samples; i++) {
                int16_t v = av_sample_fmt_is_planar(frame->format) ? ((int16_t *)frame->extended_data[c])[i]
                                                                    : ((int16_t *)frame->data[0])[i * channels + c];
                uint8_t le[2] = { (uint8_t)v, (uint8_t)(v >> 8) };
                av_md5_update(md5, le, 2);
            }
        }
        uint8_t digest[16];
        av_md5_final(md5, digest);
        av_free(md5);
        printf("0 %d ", frame->nb_samples);
        for (int i = 0; i < 16; i++)
            printf("%02x", digest[i]);
        printf("\n");
        // A packet holding more than one block gives more frames; the
        // cases here hold one.
        while (avcodec_receive_frame(dec, frame) >= 0)
            ;
    }
    av_frame_free(&frame);
    av_packet_free(&pkt);
}

static AVCodecContext *open_decoder(const char *name, int channels, int block_align, int bits,
                                    const uint8_t *extradata, int extradata_size, int *result)
{
    const AVCodec *codec = avcodec_find_decoder_by_name(name);
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    av_channel_layout_default(&dec->ch_layout, channels);
    if (channels > 2)
        av_channel_layout_from_mask(&dec->ch_layout, 0);
    dec->ch_layout.order = AV_CHANNEL_ORDER_UNSPEC;
    dec->ch_layout.nb_channels = channels;
    dec->sample_rate = 44100;
    dec->block_align = block_align;
    dec->bits_per_coded_sample = bits;
    if (extradata_size) {
        dec->extradata = av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(dec->extradata, extradata, extradata_size);
        dec->extradata_size = extradata_size;
    }
    *result = avcodec_open2(dec, codec, NULL);
    return dec;
}

struct Enc {
    const char *name;
    const char *encoder;
    const char *signal;
    int channels;
    int block_size;
    int trellis;
    int samples;
};

static void run_encoder(const struct Enc *t)
{
    printf("E %s %s %s %d %d %d %d\n", t->name, t->encoder, t->signal, t->channels, t->block_size, t->trellis,
           t->samples);
    const AVCodec *codec = avcodec_find_encoder_by_name(t->encoder);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    const int planar = !strcmp(t->encoder, "adpcm_ima_wav");
    ctx->sample_fmt = planar ? AV_SAMPLE_FMT_S16P : AV_SAMPLE_FMT_S16;
    ctx->sample_rate = 22050;
    av_channel_layout_default(&ctx->ch_layout, t->channels);
    ctx->time_base = (AVRational){ 1, 22050 };
    ctx->trellis = t->trellis;
    av_opt_set_int(ctx->priv_data, "block_size", t->block_size, 0);
    int ret = avcodec_open2(ctx, codec, NULL);
    printf("O ");
    if (ret < 0) {
        print_result(ret);
        printf("\n");
        avcodec_free_context(&ctx);
        return;
    }
    printf("ok\nI %d %d ", ctx->frame_size, ctx->block_align);
    for (int i = 0; i < ctx->extradata_size; i++)
        printf("%02x", ctx->extradata[i]);
    printf("%s\n", ctx->extradata_size ? "" : "-");

    int dec_result;
    AVCodecContext *dec = open_decoder(t->encoder, t->channels, ctx->block_align, 4, ctx->extradata,
                                       ctx->extradata_size, &dec_result);

    rng_state = 0x9E3779B9u ^ (uint32_t)(t->channels * 1000003 + t->samples + t->block_size);
    int state[2] = { 0, 0 };
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    for (int start = 0;; start += ctx->frame_size) {
        if (start < t->samples) {
            const int n = t->samples - start < ctx->frame_size ? t->samples - start : ctx->frame_size;
            frame->nb_samples = n;
            frame->format = ctx->sample_fmt;
            av_channel_layout_copy(&frame->ch_layout, &ctx->ch_layout);
            frame->pts = start;
            if (av_frame_get_buffer(frame, 0) < 0)
                exit(1);
            for (int i = 0; i < n; i++)
                for (int c = 0; c < t->channels; c++) {
                    const int16_t v = (int16_t)sample(t->signal, c, start + i, state);
                    if (planar)
                        ((int16_t *)frame->extended_data[c])[i] = v;
                    else
                        ((int16_t *)frame->data[0])[i * t->channels + c] = v;
                }
            ret = avcodec_send_frame(ctx, frame);
            av_frame_unref(frame);
        } else {
            ret = avcodec_send_frame(ctx, NULL);
        }
        while (avcodec_receive_packet(ctx, pkt) >= 0) {
            uint8_t digest[16];
            const int half = t->trellis && t->channels == 1 && !strcmp(t->encoder, "adpcm_ms");
            const int defined = half ? 7 + (pkt->size - 7) / 2 : pkt->size;
            av_md5_sum(digest, pkt->data, defined);
            if (half)
                printf("H %d %d ", pkt->size, defined);
            else
                printf("P %d ", pkt->size);
            for (int i = 0; i < 16; i++)
                printf("%02x", digest[i]);
            printf("\n");
            if (!half)
                decode_line(dec, pkt->data, pkt->size);
            av_packet_unref(pkt);
        }
        if (start >= t->samples)
            break;
    }
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&dec);
    avcodec_free_context(&ctx);
}

static void run_decoder(const char *name, int channels, int block_align, int bits, uint32_t seed, int size)
{
    printf("R %s %d %d %d %u %d\n", name, channels, block_align, bits, seed, size);
    int result;
    AVCodecContext *dec = open_decoder(name, channels, block_align, bits, NULL, 0, &result);
    if (result < 0) {
        printf("D ");
        print_result(result);
        printf(" 0 -\n");
    } else {
        uint8_t *data = malloc(size + 1);
        rng_state = seed;
        for (int i = 0; i < size; i++)
            data[i] = (uint8_t)rng();
        // Valid step indexes and predictors in most blocks.
        if (!strcmp(name, "adpcm_ima_wav")) {
            for (int c = 0; c < channels && 4 * c + 2 < size; c++)
                if (seed & 1)
                    data[4 * c + 2] %= 89;
        } else {
            for (int c = 0; c < channels && c < size; c++)
                if (seed & 1)
                    data[c] %= 7;
        }
        decode_line(dec, data, size);
        free(data);
    }
    avcodec_free_context(&dec);
}

int main(void)
{
    static const struct Enc encoders[] = {
        { "ima_mono", "adpcm_ima_wav", "tone", 1, 1024, 0, 5000 },
        { "ima_stereo", "adpcm_ima_wav", "smooth", 2, 1024, 0, 4000 },
        { "ima_small", "adpcm_ima_wav", "noise", 2, 256, 0, 1000 },
        { "ima_trellis", "adpcm_ima_wav", "tone", 1, 512, 4, 2500 },
        { "ima_trellis_stereo", "adpcm_ima_wav", "smooth", 2, 256, 8, 1500 },
        { "ima_extremes", "adpcm_ima_wav", "extremes", 2, 512, 0, 1500 },
        { "ima_short", "adpcm_ima_wav", "tone", 1, 1024, 0, 50 },
        { "ms_mono", "adpcm_ms", "tone", 1, 1024, 0, 5000 },
        { "ms_stereo", "adpcm_ms", "smooth", 2, 1024, 0, 4000 },
        { "ms_small", "adpcm_ms", "noise", 2, 256, 0, 1000 },
        { "ms_trellis_stereo", "adpcm_ms", "tone", 2, 512, 4, 2500 },
        { "ms_trellis_mono", "adpcm_ms", "smooth", 1, 256, 6, 1500 },
        { "ms_extremes", "adpcm_ms", "extremes", 1, 512, 0, 1500 },
        { "ms_silence", "adpcm_ms", "silence", 2, 256, 0, 600 },
        { "bad_block_size", "adpcm_ms", "tone", 1, 1000, 0, 500 },
        { "bad_trellis", "adpcm_ima_wav", "tone", 1, 1024, 17, 500 },
    };
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(encoders) / sizeof(encoders[0]); i++)
        run_encoder(&encoders[i]);
    // Decoders: every IMA WAV bit depth and both channel counts, MS up to
    // 6 channels, whole and short blocks, and refused parameters.
    uint32_t seed = 12345;
    for (int bits = 1; bits <= 6; bits++)
        for (int channels = 1; channels <= 3; channels++)
            for (int k = 0; k < 4; k++) {
                const int block_align = 64 << (k & 1);
                const int size = k < 2 ? block_align : 4 * channels + 7 * k;
                run_decoder("adpcm_ima_wav", channels, block_align, bits, seed, size);
                seed = seed * 1103515245u + 12345u;
            }
    for (int channels = 1; channels <= 7; channels++)
        for (int k = 0; k < 4; k++) {
            const int block_align = 128 << (k & 1);
            const int size = k < 2 ? block_align : 7 * channels + 3 * k - 4;
            run_decoder("adpcm_ms", channels, block_align, 4, seed, size);
            seed = seed * 1103515245u + 12345u;
        }
    return 0;
}
