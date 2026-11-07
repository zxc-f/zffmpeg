// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T32c AC-3 encoder oracle (zig/testing/vectors/ac3enc.txt):
// what the pinned FFmpeg's float AC-3 encoder (`ac3`) makes of
// deterministic planar float signals, through the public API
// (avcodec_open2 with the case's layout, rate, bit rate and options,
// avcodec_send_frame of frames of 1536 samples, the last one short,
// avcodec_receive_packet, then the flush). The samples are
// alac_vectors.c's 16-bit signals divided by 32768 (exact in a float),
// times the case's gain, with NaN and infinities at fixed places when the
// case asks for them, so the Zig test makes the same samples. The lines:
//
//   C <name> <layout mask> <rate> <bit_rate> <samples> <signal> <gain> <specials> <options>
//                                a case; options are `name=value` pairs
//                                joined by `:`, `-` for none
//   O <result>                   avcodec_open2: ok or the error
//   I <bit_rate> <frame_size> <initial_padding>
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

// The float sample: the 16-bit one scaled, or a special value.
static float fsample(const struct Case *t, int c, int i, int *state)
{
    const int v = sample(t->signal, c, i, state);
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
    const AVCodec *codec = avcodec_find_encoder_by_name("ac3");
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    ctx->sample_fmt = AV_SAMPLE_FMT_FLTP;
    ctx->sample_rate = t->rate;
    av_channel_layout_from_mask(&ctx->ch_layout, t->layout);
    ctx->bit_rate = t->bit_rate;
    ctx->time_base = (AVRational){ 1, t->rate };
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
    printf("ok\nI %" PRId64 " %d %d\n", ctx->bit_rate, ctx->frame_size, ctx->initial_padding);

    const int channels = ctx->ch_layout.nb_channels;
    rng_state = 0x9E3779B9u ^ (uint32_t)(channels * 1000003 + t->samples);
    int state[8] = { 0 };
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
    // FL FR FC LFE BL BR BC SL SR
    enum { FL = 0x1, FR = 0x2, FC = 0x4, LFE = 0x8, BL = 0x10, BR = 0x20, BC = 0x100, SL = 0x200, SR = 0x400 };
    static const struct Case cases[] = {
        { "default_stereo_48k", FL | FR, 48000, 0, 5000, "smooth", 1, 0, "-" },
        { "mono_48k_96k", FC, 48000, 96000, 4608, "tone", 1, 0, "-" },
        { "stereo_44k_128k", FL | FR, 44100, 128000, 9000, "noise", 1, 0, "-" },
        { "stereo_32k_64k", FL | FR, 32000, 64000, 5000, "tone", 1, 0, "-" },
        { "stereo_48k_96k", FL | FR, 48000, 96000, 6000, "smooth", 1, 0, "-" },
        { "stereo_44k_160k", FL | FR, 44100, 160000, 7000, "tone", 1, 0, "-" },
        { "51side_48k", FL | FR | FC | LFE | SL | SR, 48000, 0, 5000, "smooth", 1, 0, "-" },
        { "51back_44k_384k", FL | FR | FC | LFE | BL | BR, 44100, 384000, 4000, "tone", 1, 0, "-" },
        { "51side_48k_256k", FL | FR | FC | LFE | SL | SR, 48000, 256000, 4000, "noise", 1, 0, "-" },
        { "surround_32k", FL | FR | FC, 32000, 0, 4000, "tone", 1, 0, "-" },
        { "surround_48k_192k", FL | FR | FC, 48000, 192000, 4000, "smooth", 1, 0, "-" },
        { "21_48k", FL | FR | BC, 48000, 0, 3500, "tone", 1, 0, "-" },
        { "21_44k_160k", FL | FR | BC, 44100, 160000, 3500, "smooth", 1, 0, "-" },
        { "quad_48k", FL | FR | BL | BR, 48000, 0, 3500, "smooth", 1, 0, "-" },
        { "22_44k_224k", FL | FR | SL | SR, 44100, 224000, 3500, "tone", 1, 0, "-" },
        { "40_48k", FL | FR | FC | BC, 48000, 0, 3500, "noise", 1, 0, "-" },
        { "40_48k_224k", FL | FR | FC | BC, 48000, 224000, 3500, "smooth", 1, 0, "-" },
        { "50side_48k_256k", FL | FR | FC | SL | SR, 48000, 256000, 3500, "tone", 1, 0, "-" },
        { "50back_32k", FL | FR | FC | BL | BR, 32000, 0, 3500, "smooth", 1, 0, "-" },
        { "mono_lfe_48k", FC | LFE, 48000, 0, 3000, "tone", 1, 0, "-" },
        { "stereo_lfe_44k", FL | FR | LFE, 44100, 0, 3000, "smooth", 1, 0, "-" },
        { "21_lfe_48k", FL | FR | BC | LFE, 48000, 0, 3000, "tone", 1, 0, "-" },
        { "surround_lfe_48k", FL | FR | FC | LFE, 48000, 0, 3000, "noise", 1, 0, "-" },
        { "40_lfe_32k", FL | FR | FC | BC | LFE, 32000, 0, 3000, "smooth", 1, 0, "-" },
        { "coupling_forced", FL | FR, 48000, 320000, 4000, "smooth", 1, 0, "channel_coupling=1" },
        { "coupling_off", FL | FR, 48000, 96000, 4000, "smooth", 1, 0, "channel_coupling=0" },
        { "cpl_start_band", FL | FR | FC | SL | SR, 48000, 192000, 4000, "tone", 1, 0, "channel_coupling=1:cpl_start_band=3" },
        { "no_rematrixing", FL | FR, 44100, 192000, 4000, "noise", 1, 0, "stereo_rematrixing=0" },
        { "cutoff", FL | FR, 48000, 192000, 4000, "noise", 1, 0, "cutoff=10000" },
        { "cutoff_high", FC, 32000, 0, 3000, "noise", 1, 0, "cutoff=30000" },
        { "metadata_stereo", FL | FR, 48000, 0, 3000, "tone", 1, 0,
          "dialnorm=-20:dsur_mode=2:copyright=1:original=0:mixing_level=100:room_type=1:dheadphone_mode=2:ad_conv_type=1" },
        { "metadata_51", FL | FR | FC | LFE | SL | SR, 48000, 0, 3000, "smooth", 1, 0,
          "center_mixlev=0.707:surround_mixlev=0:dmix_mode=1:ltrt_cmixlev=0.5:ltrt_surmixlev=0.5:loro_cmixlev=1.0:loro_surmixlev=0.3:dsurex_mode=2" },
        { "metadata_invalid_levels", FL | FR | FC | BL | BR, 48000, 0, 3000, "tone", 1, 0,
          "center_mixlev=0.9:surround_mixlev=0.8:ltrt_cmixlev=1.7:loro_surmixlev=1.2" },
        { "service_type", FL | FR, 48000, 0, 3000, "tone", 1, 0, "audio_service_type=4" },
        { "karaoke", FL | FR, 48000, 0, 3000, "tone", 1, 0, "audio_service_type=8" },
        { "per_frame_metadata", FL | FR, 48000, 0, 3000, "tone", 1, 0, "per_frame_metadata=1:dialnorm=-5" },
        { "bit_rate_nearest", FL | FR, 48000, 100000, 3000, "smooth", 1, 0, "-" },
        { "bit_rate_huge", FL | FR, 32000, 1000000, 3000, "noise", 1, 0, "-" },
        { "silence", FL | FR, 48000, 0, 4000, "silence", 1, 0, "-" },
        { "extremes", FL | FR, 48000, 0, 4000, "extremes", 1, 0, "-" },
        { "hot", FL | FR | FC, 44100, 0, 4000, "noise", 4, 0, "-" },
        { "hot_tone", FL | FR, 48000, 640000, 4000, "extremes", 4, 0, "-" },
        { "specials", FL | FR, 48000, 0, 4000, "smooth", 1, 1, "-" },
        { "huge", FL | FR, 48000, 0, 4000, "noise", 100000000, 0, "-" },
        { "huge_51", FL | FR | FC | LFE | SL | SR, 44100, 448000, 4000, "smooth", 100000000, 0, "-" },
        { "starved", FL | FR | FC | LFE | SL | SR, 48000, 32000, 3000, "noise", 1, 0, "-" },
        { "short", FL | FR, 48000, 0, 100, "tone", 1, 0, "-" },
        { "frame_and_flush", FC, 44100, 0, 1300, "tone", 1, 0, "-" },
        { "empty", FL | FR, 48000, 0, 0, "tone", 1, 0, "-" },
        { "bad_rate", FL | FR, 22050, 0, 1536, "tone", 1, 0, "-" },
        { "bad_layout", FL | FR | LFE | BL | BR, 48000, 0, 1536, "tone", 1, 0, "-" },
        { "bad_service_type", FC, 48000, 0, 1536, "tone", 1, 0, "audio_service_type=8" },
        { "bad_commentary", FL | FR, 48000, 0, 1536, "tone", 1, 0, "audio_service_type=5" },
        { "bad_room_type", FL | FR, 48000, 0, 1536, "tone", 1, 0, "room_type=1" },
        { "bad_mixing_level", FL | FR, 48000, 0, 1536, "tone", 1, 0, "mixing_level=70" },
        { "bad_cutoff", FL | FR, 48000, 0, 1536, "tone", 1, 0, "cutoff=-1" },
    };
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run(&cases[i]);
    return 0;
}
