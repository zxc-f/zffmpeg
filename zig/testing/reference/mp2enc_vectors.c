// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T29d MP2 encoder oracle (zig/testing/vectors/mp2enc.txt): what
// the pinned FFmpeg's libavcodec MP2 encoders (mp2, the float quantizer, and
// mp2fixed) make of deterministic 16-bit signals, through the public API
// (avcodec_open2 with the case's bit rate, avcodec_send_frame of frames of
// 1152 samples, the last one short, which libavcodec pads with silence,
// avcodec_receive_packet, then the flush). The signals come from integer
// arithmetic only, so the Zig test makes the same samples from the
// parameters printed here. The lines:
//
//   C <name> <encoder> <signal> <channels> <rate> <bit_rate> <samples>
//                                a case: the encoder, the signal kind, the
//                                channel count, the sample rate, the bit
//                                rate asked for (0: the encoder's default)
//                                and the stream's sample count
//   O <result>                   avcodec_open2: ok or the error
//   I <bit_rate> <frame_size> <initial_padding>
//                                after opening
//   P <pts> <duration> <size> <md5>
//                                each packet: its timestamp, duration,
//                                size and the MD5 of its bytes
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/channel_layout.h"
#include "libavutil/error.h"
#include "libavutil/md5.h"

struct Case {
    const char *name;
    const char *encoder;
    const char *signal;
    int channels;
    int rate;
    int bit_rate;
    int samples;
};

// The signal generator; zig/codec/mp2enc.zig's test has the same one:
// xorshift32 seeded with the case's channel count and sample count.
static uint32_t rng_state;

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

// Sample `i` of channel `c`, in [-32768, 32767]. Every channel draws from
// the one generator, in channel order within each sample frame; `state`
// holds per-channel filter memory.
static int sample(const char *signal, int c, int i, int *state)
{
    const int noise = (int)(rng() & 0xffff) - 0x8000;
    int v;
    if (!strcmp(signal, "tone")) {
        // A triangle of period 64 + 24 * c with a little noise.
        const int period = 64 + 24 * c;
        const int phase = i % period;
        const int tri = phase < period / 2 ? phase : period - phase;
        v = (tri * 2 - period / 2) * 16384 / (period / 2) + noise / 8;
    } else if (!strcmp(signal, "noise")) {
        v = noise;
    } else if (!strcmp(signal, "smooth")) {
        // Noise through a one-pole low-pass filter.
        state[c] += (noise - state[c]) / 8;
        v = state[c] * 2;
    } else if (!strcmp(signal, "silence")) {
        v = 0;
    } else if (!strcmp(signal, "extremes")) {
        // Full-scale alternation, the loudest a 16-bit input gets.
        v = ((i + c) & 1) ? 32767 : -32768;
        if (rng() & 1)
            v = -32768;
    } else {
        fprintf(stderr, "unknown signal %s\n", signal);
        exit(1);
    }
    if (v < -32768)
        v = -32768;
    if (v > 32767)
        v = 32767;
    return v;
}

static void print_error(int err)
{
    if (err == AVERROR(EINVAL))
        printf("EINVAL");
    else
        printf("%d", err);
}

static int drain(AVCodecContext *ctx, AVPacket *pkt)
{
    int ret;
    while ((ret = avcodec_receive_packet(ctx, pkt)) >= 0) {
        uint8_t digest[16];
        av_md5_sum(digest, pkt->data, pkt->size);
        printf("P %" PRId64 " %" PRId64 " %d ", pkt->pts, pkt->duration, pkt->size);
        for (int i = 0; i < 16; i++)
            printf("%02x", digest[i]);
        printf("\n");
        av_packet_unref(pkt);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static void run(const struct Case *t)
{
    printf("C %s %s %s %d %d %d %d\n", t->name, t->encoder, t->signal, t->channels, t->rate, t->bit_rate, t->samples);
    const AVCodec *codec = avcodec_find_encoder_by_name(t->encoder);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    ctx->sample_fmt = AV_SAMPLE_FMT_S16;
    ctx->sample_rate = t->rate;
    av_channel_layout_default(&ctx->ch_layout, t->channels);
    ctx->bit_rate = t->bit_rate;
    ctx->time_base = (AVRational){ 1, t->rate };
    int ret = avcodec_open2(ctx, codec, NULL);
    printf("O ");
    if (ret < 0) {
        print_error(ret);
        printf("\n");
        avcodec_free_context(&ctx);
        return;
    }
    printf("ok\nI %" PRId64 " %d %d\n", ctx->bit_rate, ctx->frame_size, ctx->initial_padding);

    rng_state = 0x9E3779B9u ^ (uint32_t)(t->channels * 1000003 + t->samples);
    int state[2] = { 0, 0 };
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    for (int start = 0; start < t->samples; start += ctx->frame_size) {
        const int n = t->samples - start < ctx->frame_size ? t->samples - start : ctx->frame_size;
        frame->nb_samples = n;
        frame->format = AV_SAMPLE_FMT_S16;
        av_channel_layout_copy(&frame->ch_layout, &ctx->ch_layout);
        frame->pts = start;
        if (av_frame_get_buffer(frame, 0) < 0)
            exit(1);
        int16_t *data = (int16_t *)frame->data[0];
        for (int i = 0; i < n; i++)
            for (int c = 0; c < t->channels; c++)
                data[i * t->channels + c] = (int16_t)sample(t->signal, c, start + i, state);
        ret = avcodec_send_frame(ctx, frame);
        av_frame_unref(frame);
        if (ret < 0 || drain(ctx, pkt) < 0) {
            printf("E ");
            print_error(ret);
            printf("\n");
            break;
        }
    }
    avcodec_send_frame(ctx, NULL);
    drain(ctx, pkt);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
}

int main(void)
{
    static const struct Case cases[] = {
        { "default_stereo_44k", "mp2", "tone", 2, 44100, 0, 5000 },
        { "stereo_48k_192k", "mp2", "smooth", 2, 48000, 192000, 4608 },
        { "mono_48k_64k", "mp2", "tone", 1, 48000, 64000, 3500 },
        { "stereo_32k_128k", "mp2", "noise", 2, 32000, 128000, 3456 },
        { "mono_44k_48k", "mp2", "smooth", 1, 44100, 48000, 3000 },
        { "mono_32k_32k", "mp2", "tone", 1, 32000, 32000, 2400 },
        { "lsf_default_stereo_24k", "mp2", "tone", 2, 24000, 0, 4000 },
        { "lsf_mono_22k_64k", "mp2", "smooth", 1, 22050, 64000, 2304 },
        { "lsf_stereo_16k_32k", "mp2", "noise", 2, 16000, 32000, 2000 },
        { "silence", "mp2", "silence", 2, 44100, 128000, 2304 },
        { "extremes", "mp2", "extremes", 2, 48000, 384000, 2304 },
        { "short", "mp2", "tone", 1, 44100, 0, 100 },
        { "fixed_stereo_44k", "mp2fixed", "tone", 2, 44100, 0, 5000 },
        { "fixed_mono_22k", "mp2fixed", "smooth", 1, 22050, 48000, 3000 },
        { "fixed_extremes", "mp2fixed", "extremes", 2, 48000, 256000, 2304 },
        { "fixed_noise_32k", "mp2fixed", "noise", 2, 32000, 160000, 2304 },
        { "bad_bit_rate", "mp2", "tone", 2, 44100, 100000, 1152 },
        { "bad_rate", "mp2", "tone", 2, 8000, 0, 1152 },
    };
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run(&cases[i]);
    return 0;
}
