// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T32d AAC encoder oracle (zig/testing/vectors/aacenc.txt): what
// the pinned FFmpeg's AAC encoder (`aac`, with the `twoloop` and `fast`
// coders) makes of deterministic planar float signals, through the public
// API with AV_CODEC_FLAG_BITEXACT, as the ffmpeg program's -bitexact sets
// it (avcodec_open2 with the case's layout, rate, bit rate and options,
// avcodec_send_frame of frames of 1024 samples, the last one short,
// avcodec_receive_packet, then the flush). The samples are
// alac_vectors.c's 16-bit signals divided by 32768 (exact in a float),
// times the case's gain; "bursts" is the noise signal at 1/128 except
// every fourth stretch of 700 samples (transients for block switching);
// NaN and infinities sit at fixed places when the case asks for them. The
// lines:
//
//   C <name> <layout mask> <rate> <bit_rate> <samples> <signal> <gain> <specials> <options>
//                                a case; options are `name=value` pairs
//                                joined by `:`, `-` for none
//   O <result>                   avcodec_open2: ok or the error
//   I <bit_rate> <frame_size> <initial_padding> <extradata hex>
//                                after opening
//   P <pts> <duration> <size> <md5>
//                                each packet: its timestamp, duration,
//                                size and the MD5 of its bytes
//   E <result>                   a frame the encoder refused
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/md5.h"

struct Case {
    const char *name;
    uint64_t layout;
    int rate;
    int bit_rate;
    int samples;
    const char *signal;
    int gain;
    int specials;
    const char *options;
};

static uint32_t rng_state;

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

// alac_vectors.c's 16-bit `sample`.
static int sample(const char *signal_in, int c, int i, int *state)
{
    const char *signal = strcmp(signal_in, "bursts") ? signal_in : "noise";
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

// The float sample: the 16-bit one scaled, or a special value.
static float fsample(const struct Case *t, int c, int i, int *state)
{
    const int v = sample(t->signal, c, i, state);
    if (!strcmp(t->signal, "bursts") && (i / 700) % 4 != 0)
        return (float)v * ((float)t->gain / 32768.0f / 128.0f);
    if (t->specials) {
        if (i % 397 == 11)
            return NAN;
        if (i % 401 == 23)
            return c & 1 ? -INFINITY : INFINITY;
        if (i % 409 == 37)
            return 1e30f;
    }
    return (float)v * ((float)t->gain / 32768.0f);
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
    printf("C %s 0x%" PRIx64 " %d %d %d %s %d %d %s\n", t->name, t->layout, t->rate, t->bit_rate, t->samples,
           t->signal, t->gain, t->specials, t->options);
    const AVCodec *codec = avcodec_find_encoder_by_name("aac");
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    ctx->sample_fmt = AV_SAMPLE_FMT_FLTP;
    ctx->sample_rate = t->rate;
    av_channel_layout_from_mask(&ctx->ch_layout, t->layout);
    ctx->bit_rate = t->bit_rate;
    ctx->time_base = (AVRational){ 1, t->rate };
    ctx->flags |= AV_CODEC_FLAG_BITEXACT;
    AVDictionary *opts = NULL;
    if (strcmp(t->options, "-"))
        av_dict_parse_string(&opts, t->options, "=", ":", 0);
    int ret = avcodec_open2(ctx, codec, &opts);
    av_dict_free(&opts);
    printf("O ");
    if (ret < 0) {
        print_error(ret);
        printf("\n");
        avcodec_free_context(&ctx);
        return;
    }
    printf("ok\nI %" PRId64 " %d %d ", ctx->bit_rate, ctx->frame_size, ctx->initial_padding);
    for (int i = 0; i < ctx->extradata_size; i++)
        printf("%02x", ctx->extradata[i]);
    printf("\n");

    const int channels = ctx->ch_layout.nb_channels;
    rng_state = 0x9E3779B9u ^ (uint32_t)(channels * 1000003 + t->samples);
    int state[16] = { 0 };
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    int failed = 0;
    for (int start = 0; start < t->samples; start += ctx->frame_size) {
        const int n = t->samples - start < ctx->frame_size ? t->samples - start : ctx->frame_size;
        frame->nb_samples = n;
        frame->format = AV_SAMPLE_FMT_FLTP;
        av_channel_layout_copy(&frame->ch_layout, &ctx->ch_layout);
        frame->pts = start;
        if (av_frame_get_buffer(frame, 0) < 0)
            exit(1);
        for (int i = 0; i < n; i++)
            for (int c = 0; c < channels; c++)
                ((float *)frame->extended_data[c])[i] = fsample(t, c, start + i, state);
        ret = avcodec_send_frame(ctx, frame);
        av_frame_unref(frame);
        if (ret < 0 || drain(ctx, pkt) < 0) {
            printf("E ");
            print_error(ret);
            printf("\n");
            failed = 1;
            break;
        }
    }
    if (!failed) {
        avcodec_send_frame(ctx, NULL);
        drain(ctx, pkt);
    }
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
}

int main(void)
{
    // FL FR FC LFE BL BR FLC FRC BC SL SR TFL TFR
    enum { FL = 0x1, FR = 0x2, FC = 0x4, LFE = 0x8, BL = 0x10, BR = 0x20, FLC = 0x40, FRC = 0x80, BC = 0x100,
           SL = 0x200, SR = 0x400, TFL = 0x1000, TFR = 0x4000 };
    static const struct Case cases[] = {
        { "twoloop_stereo_44k", FL | FR, 44100, 0, 5000, "smooth", 1, 0, "aac_coder=twoloop" },
        { "twoloop_mono_48k_64k", FC, 48000, 64000, 4096, "tone", 1, 0, "aac_coder=twoloop" },
        { "twoloop_stereo_32k_96k", FL | FR, 32000, 96000, 6000, "noise", 1, 0, "aac_coder=twoloop" },
        { "twoloop_bursts", FL | FR, 44100, 128000, 12000, "bursts", 1, 0, "aac_coder=twoloop" },
        { "twoloop_stereo_low", FL | FR, 22050, 32000, 6000, "smooth", 1, 0, "aac_coder=twoloop" },
        { "twoloop_surround", FL | FR | FC, 48000, 0, 4000, "tone", 1, 0, "aac_coder=twoloop" },
        { "twoloop_51", FL | FR | FC | LFE | BL | BR, 48000, 0, 4000, "smooth", 1, 0, "aac_coder=twoloop" },
        { "twoloop_40", FL | FR | FC | BC, 44100, 0, 3000, "noise", 1, 0, "aac_coder=twoloop" },
        { "twoloop_50back", FL | FR | FC | BL | BR, 32000, 0, 3000, "tone", 1, 0, "aac_coder=twoloop" },
        { "twoloop_61back", FL | FR | FC | LFE | BL | BR | BC, 48000, 0, 3000, "smooth", 1, 0, "aac_coder=twoloop" },
        { "twoloop_71", FL | FR | FC | LFE | BL | BR | SL | SR, 48000, 0, 3000, "noise", 1, 0, "aac_coder=twoloop" },
        { "twoloop_512back", FL | FR | FC | LFE | BL | BR | TFL | TFR, 48000, 0, 2500, "tone", 1, 0, "aac_coder=twoloop" },
        { "twoloop_no_ms", FL | FR, 44100, 128000, 4000, "smooth", 1, 0, "aac_coder=twoloop:aac_ms=0" },
        { "twoloop_forced_ms", FL | FR, 44100, 128000, 4000, "smooth", 1, 0, "aac_coder=twoloop:aac_ms=1" },
        { "twoloop_no_is_pns", FL | FR, 44100, 96000, 4000, "noise", 1, 0, "aac_coder=twoloop:aac_is=0:aac_pns=0" },
        { "twoloop_no_tns", FL | FR, 48000, 128000, 8000, "bursts", 1, 0, "aac_coder=twoloop:aac_tns=0" },
        { "twoloop_cutoff", FC, 44100, 0, 4000, "noise", 1, 0, "aac_coder=twoloop:cutoff=12000" },
        { "twoloop_mpeg2", FL | FR, 44100, 0, 4000, "noise", 1, 0, "aac_coder=twoloop:profile=128" },
        { "twoloop_qscale", FL | FR, 44100, 0, 5000, "smooth", 1, 0, "aac_coder=twoloop:flags=+qscale+bitexact:global_quality=236" },
        { "twoloop_high_rate", FL | FR, 48000, 320000, 4000, "noise", 1, 0, "aac_coder=twoloop" },
        { "twoloop_8k", FC, 8000, 16000, 3000, "tone", 1, 0, "aac_coder=twoloop" },
        { "twoloop_96k", FL | FR, 96000, 0, 4000, "smooth", 1, 0, "aac_coder=twoloop" },
        { "twoloop_silence", FL | FR, 44100, 0, 3000, "silence", 1, 0, "aac_coder=twoloop" },
        { "twoloop_extremes", FL | FR, 44100, 0, 3000, "extremes", 1, 0, "aac_coder=twoloop" },
        { "twoloop_hot", FL | FR, 44100, 0, 3000, "noise", 4, 0, "aac_coder=twoloop" },
        { "twoloop_specials", FL | FR, 44100, 0, 3000, "smooth", 1, 1, "aac_coder=twoloop" },
        { "twoloop_short", FL | FR, 44100, 0, 100, "tone", 1, 0, "aac_coder=twoloop" },
        { "twoloop_frame", FC, 44100, 0, 1024, "tone", 1, 0, "aac_coder=twoloop" },
        { "twoloop_empty", FL | FR, 44100, 0, 0, "tone", 1, 0, "aac_coder=twoloop" },
        { "fast_stereo_44k", FL | FR, 44100, 0, 5000, "smooth", 1, 0, "aac_coder=fast" },
        { "fast_mono_32k", FC, 32000, 48000, 4000, "tone", 1, 0, "aac_coder=fast" },
        { "fast_bursts", FL | FR, 48000, 128000, 12000, "bursts", 1, 0, "aac_coder=fast" },
        { "fast_51", FL | FR | FC | LFE | BL | BR, 44100, 0, 3000, "noise", 1, 0, "aac_coder=fast" },
        { "fast_qscale", FC, 48000, 0, 4000, "noise", 1, 0, "aac_coder=fast:flags=+qscale+bitexact:global_quality=118" },
        { "bad_rate", FL | FR, 44000, 0, 1024, "tone", 1, 0, "aac_coder=twoloop" },
        { "bad_profile", FL | FR, 44100, 0, 1024, "tone", 1, 0, "aac_coder=twoloop:profile=2" },
        { "pce_layout", FL | FR | LFE, 44100, 0, 1024, "tone", 1, 0, "aac_coder=twoloop" },
        { "pce_51side", FL | FR | FC | LFE | SL | SR, 48000, 0, 3000, "smooth", 1, 0, "aac_coder=twoloop" },
        { "pce_71wide", FL | FR | FC | LFE | BL | BR | FLC | FRC, 48000, 0, 2500, "noise", 1, 0, "aac_coder=twoloop" },
        { "wide_allowed", FL | FR | FC | LFE | BL | BR | FLC | FRC, 48000, 0, 2500, "noise", 1, 0, "aac_coder=twoloop:aac_allow_71wide=1" },
        { "pce_forced", FL | FR, 44100, 0, 3000, "tone", 1, 0, "aac_coder=twoloop:aac_pce=1" },
        { "pce_height", FL | FR | FC | LFE | SL | SR | TFL | TFR, 48000, 0, 2500, "tone", 1, 0, "aac_coder=twoloop" },
        { "pce_61side_fast", FL | FR | FC | LFE | BC | SL | SR, 44100, 0, 3000, "smooth", 1, 0, "aac_coder=fast" },
        { "bad_layout", FL | BC, 44100, 0, 1024, "tone", 1, 0, "aac_coder=twoloop" },
    };
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run(&cases[i]);
    return 0;
}
