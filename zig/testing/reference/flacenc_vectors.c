// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T26c FLAC encoder oracle (zig/testing/vectors/flacenc.txt):
// what the pinned FFmpeg's libavcodec FLAC encoder makes of deterministic
// integer signals, through the public API (avcodec_open2 with the case's
// options, avcodec_send_frame, avcodec_receive_packet, then the flush).
// The signals come from integer arithmetic only, so the Zig test makes the
// same samples from the parameters printed here. The lines:
//
//   C <name> <signal> <channels> <rate> <format> <bits> <samples>
//     <frame_size> <options>     a case: the signal kind, the channel
//                                count, the sample rate, s16 or s32, the
//                                bits_per_raw_sample asked for (0 for
//                                none), the stream's sample count, the
//                                encoder's frame_size (0: the encoder
//                                chooses) and its options (key=value
//                                pairs joined by ':', or '-')
//   O <result>                   avcodec_open2: ok or the error
//   I <bits> <frame_size> <hex>  after opening: bits_per_raw_sample,
//                                frame_size and the 34-byte STREAMINFO
//                                extradata
//   P <pts> <duration> <size> <md5>
//                                each packet: its timestamp, duration,
//                                size and the MD5 of its bytes
//   F <pts> <hex>                the flush packet: its timestamp and the
//                                new STREAMINFO side data
//
// See zig/testing/reference/README.md for the build commands.

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/error.h"
#include "libavutil/log.h"
#include "libavutil/md5.h"

struct Case {
    const char *name;
    const char *signal;
    int channels;
    int rate;
    int s32; // 0: s16, 1: s32
    int bits;
    int samples;
    int frame_size;
    const char *options;
};

// The signal generator; zig/codec/flacenc.zig's test has the same one.
// xorshift32 from a seed of the case's channel count and sample count, so
// each case starts the same everywhere.
static uint32_t rng_state;

static uint32_t rng(void)
{
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

// Sample `i` of channel `c` of a `bits`-bit signal, in [-(1 << (bits-1)),
// (1 << (bits-1)) - 1]. Every channel draws from the one generator, in
// channel order within each sample frame. `state` holds per-channel
// filter memory.
static int64_t sample(const char *signal, int bits, int c, int i, int64_t *state)
{
    const int64_t top = (int64_t)1 << (bits - 1);
    const int64_t noise = (int64_t)(rng() & 0xffff) - 0x8000; // [-32768, 32767]
    int64_t v;
    if (!strcmp(signal, "tone")) {
        // A triangle of period 64 + 24 * c with a little noise.
        const int period = 64 + 24 * c;
        const int phase = i % period;
        const int64_t tri = phase < period / 2 ? phase : period - phase; // [0, period/2]
        v = (tri * 2 - period / 2) * (top / 2) / (period / 2) + noise * top / (8 * 32768);
    } else if (!strcmp(signal, "noise")) {
        // Full-range noise: the high word drawn first.
        const uint64_t high = rng();
        const uint64_t low = rng();
        v = (int64_t)(high << 32 | low) >> (64 - bits);
    } else if (!strcmp(signal, "smooth")) {
        // Noise through a one-pole low-pass filter.
        const int64_t x = noise * top / 32768;
        state[c] += (x - state[c]) / 8;
        v = state[c] * 2;
    } else if (!strcmp(signal, "stereo")) {
        // The first channel smooth, the others close to it.
        const int64_t x = noise * top / 32768;
        if (c == 0) {
            state[0] += (x - state[0]) / 8;
            v = state[0] * 2;
        } else {
            v = state[0] * 2 + noise / 64 * (top >> 15);
        }
    } else if (!strcmp(signal, "steps")) {
        // Constant runs of 300 samples, with a step between them.
        v = ((i / 300) % 5 - 2) * (top / 3) + c;
    } else if (!strcmp(signal, "wasted")) {
        // Smooth, with the low 3 bits zero.
        const int64_t x = noise * top / 32768;
        state[c] += (x - state[c]) / 8;
        v = state[c] * 2;
        v = v / 8 * 8;
    } else if (!strcmp(signal, "ramp")) {
        // Slow ramps, which the LPC analysis fits almost exactly: the last
        // bits of FFmpeg's autocorrelation decide the coefficients.
        v = ((int64_t)i * (c ? -987654321LL : 1234567890123LL)) >> (64 - bits);
    } else if (!strcmp(signal, "extremes")) {
        // Alternating extremes, which no predictor keeps within 32 bits.
        v = ((i + c) & 1) ? top - 1 : -top;
        if (rng() & 1)
            v = -top;
    } else {
        fprintf(stderr, "unknown signal %s\n", signal);
        exit(1);
    }
    if (v < -top)
        v = -top;
    if (v > top - 1)
        v = top - 1;
    return v;
}

static void print_hex(const uint8_t *data, int size)
{
    for (int i = 0; i < size; i++)
        printf("%02x", data[i]);
}

static void print_error(int err)
{
    if (err == AVERROR(EINVAL))
        printf("EINVAL");
    else if (err == AVERROR_INVALIDDATA)
        printf("INVALIDDATA");
    else
        printf("%d", err);
}

static void print_packet(const AVPacket *pkt)
{
    uint8_t digest[16];
    av_md5_sum(digest, pkt->data, pkt->size);
    printf("P %" PRId64 " %" PRId64 " %d ", pkt->pts, pkt->duration, pkt->size);
    print_hex(digest, 16);
    printf("\n");
}

static int drain(AVCodecContext *ctx, AVPacket *pkt)
{
    int ret;
    while ((ret = avcodec_receive_packet(ctx, pkt)) >= 0) {
        size_t side_size;
        const uint8_t *side = av_packet_get_side_data(pkt, AV_PKT_DATA_NEW_EXTRADATA, &side_size);
        if (side) {
            printf("F %" PRId64 " ", pkt->pts);
            print_hex(side, (int)side_size);
            printf("\n");
        }
        if (pkt->size)
            print_packet(pkt);
        av_packet_unref(pkt);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static void run(const struct Case *t)
{
    printf("C %s %s %d %d %s %d %d %d %s\n", t->name, t->signal, t->channels, t->rate, t->s32 ? "s32" : "s16", t->bits,
           t->samples, t->frame_size, t->options);
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_FLAC);
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    ctx->sample_fmt = t->s32 ? AV_SAMPLE_FMT_S32 : AV_SAMPLE_FMT_S16;
    ctx->sample_rate = t->rate;
    av_channel_layout_default(&ctx->ch_layout, t->channels);
    ctx->bits_per_raw_sample = t->bits;
    ctx->frame_size = t->frame_size;
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
    printf("ok\n");
    printf("I %d %d ", ctx->bits_per_raw_sample, ctx->frame_size);
    print_hex(ctx->extradata, ctx->extradata_size);
    printf("\n");

    // The stored samples: the case's bits in the high bits of s32 (a
    // decoder's s32 layout), or s16 as they are. Bits 0 means the
    // format's width.
    const int bits = t->bits ? t->bits : (t->s32 ? 32 : 16);
    const int storage = t->s32 ? 32 : 16;
    rng_state = 0x9e3779b9u ^ (uint32_t)(t->channels * 7919 + t->samples);
    int64_t state[8] = { 0 };
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    for (int start = 0; start < t->samples; start += ctx->frame_size) {
        const int n = t->samples - start < ctx->frame_size ? t->samples - start : ctx->frame_size;
        frame->nb_samples = n;
        frame->format = ctx->sample_fmt;
        frame->sample_rate = ctx->sample_rate;
        av_channel_layout_copy(&frame->ch_layout, &ctx->ch_layout);
        frame->pts = start;
        if (av_frame_get_buffer(frame, 0) < 0)
            exit(1);
        for (int i = 0; i < n; i++)
            for (int c = 0; c < t->channels; c++) {
                const int64_t v = sample(t->signal, bits, c, start + i, state);
                if (t->s32)
                    ((int32_t *)frame->data[0])[i * t->channels + c] = (int32_t)((uint32_t)v << (storage - bits));
                else
                    ((int16_t *)frame->data[0])[i * t->channels + c] = (int16_t)v;
            }
        ret = avcodec_send_frame(ctx, frame);
        av_frame_unref(frame);
        if (ret < 0 || drain(ctx, pkt) < 0) {
            printf("E send\n");
            break;
        }
    }
    avcodec_send_frame(ctx, NULL);
    drain(ctx, pkt);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
}

static const struct Case cases[] = {
    // Every compression level on stereo 16-bit, the encoder's block size.
    { "level0", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=0" },
    { "level1", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=1" },
    { "level2", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=2" },
    { "level3", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=3" },
    { "level4", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=4" },
    { "level5", "stereo", 2, 44100, 0, 0, 10000, 0, "-" },
    { "level6", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=6" },
    { "level7", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=7" },
    { "level8", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=8" },
    { "level9", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=9" },
    { "level10", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=10" },
    { "level11", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=11" },
    { "level12", "stereo", 2, 44100, 0, 0, 10000, 0, "compression_level=12" },
    { "level13", "stereo", 2, 44100, 0, 0, 1000, 0, "compression_level=13" },
    // The ffmpeg program's block size: the first frame's.
    { "frames1152", "tone", 2, 44100, 0, 0, 5000, 1152, "-" },
    { "frames4096_mono", "smooth", 1, 48000, 0, 0, 9000, 4096, "compression_level=8" },
    { "frames16", "tone", 1, 8000, 0, 0, 100, 16, "-" },
    { "frames15", "tone", 1, 8000, 0, 0, 100, 15, "-" },
    { "frames65535", "smooth", 1, 8000, 0, 0, 70000, 65535, "compression_level=2" },
    { "frames65536", "smooth", 1, 8000, 0, 0, 100, 65536, "-" },
    { "frames_short_last", "tone", 2, 44100, 0, 0, 1157, 1152, "-" },
    { "frames_last4", "tone", 2, 44100, 0, 0, 1156, 1152, "compression_level=8" },
    { "frames_odd", "smooth", 2, 44100, 0, 0, 3001, 1000, "-" },
    // Signals that pick other subframe types.
    { "noise", "noise", 2, 44100, 0, 0, 5000, 1152, "-" },
    { "steps", "steps", 2, 44100, 0, 0, 5000, 1152, "-" },
    { "wasted", "wasted", 2, 44100, 0, 0, 5000, 1152, "-" },
    { "smooth_mono", "smooth", 1, 44100, 0, 0, 5000, 1152, "-" },
    { "tone6", "tone", 6, 48000, 0, 0, 5000, 1024, "-" },
    { "tone8", "tone", 8, 48000, 0, 0, 3000, 1024, "compression_level=0" },
    { "channels9", "tone", 9, 48000, 0, 0, 100, 0, "-" },
    // Stereo decorrelation modes.
    { "ch_indep", "stereo", 2, 44100, 0, 0, 5000, 1152, "ch_mode=indep" },
    { "ch_left_side", "stereo", 2, 44100, 0, 0, 5000, 1152, "ch_mode=left_side" },
    { "ch_right_side", "stereo", 2, 44100, 0, 0, 5000, 1152, "ch_mode=right_side" },
    { "ch_mid_side", "stereo", 2, 44100, 0, 0, 5000, 1152, "ch_mode=mid_side" },
    // LPC types, passes, precision, orders and order methods.
    { "lpc_none", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_type=none" },
    { "lpc_fixed", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_type=fixed" },
    { "lpc_fixed_orders", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_type=fixed:min_prediction_order=0:max_prediction_order=4" },
    { "lpc_levinson", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_type=levinson" },
    { "lpc_cholesky", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_type=cholesky" },
    { "lpc_cholesky1", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_type=cholesky:lpc_passes=1" },
    { "lpc_cholesky3", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_type=cholesky:lpc_passes=3" },
    { "lpc_precision5", "smooth", 2, 44100, 0, 0, 5000, 1152, "lpc_coeff_precision=5" },
    { "lpc_precision15", "smooth", 1, 44100, 0, 24, 5000, 1152, "lpc_coeff_precision=15" },
    { "order_2level", "smooth", 2, 44100, 0, 0, 5000, 1152, "prediction_order_method=2level:max_prediction_order=12" },
    { "order_4level", "smooth", 2, 44100, 0, 0, 5000, 1152, "prediction_order_method=4level" },
    { "order_8level", "smooth", 2, 44100, 0, 0, 5000, 1152, "prediction_order_method=8level:max_prediction_order=32" },
    { "order_search", "smooth", 2, 44100, 0, 0, 5000, 1152, "prediction_order_method=search:max_prediction_order=16" },
    { "order_log", "smooth", 2, 44100, 0, 0, 5000, 1152, "prediction_order_method=log:max_prediction_order=32" },
    { "order_est", "tone", 2, 44100, 0, 0, 5000, 1152, "prediction_order_method=estimation:min_prediction_order=4" },
    { "order_bad", "smooth", 2, 44100, 0, 0, 100, 0, "min_prediction_order=9:max_prediction_order=8" },
    { "order_fixed_clamp", "smooth", 1, 44100, 0, 0, 3000, 1152, "lpc_type=fixed:min_prediction_order=6:max_prediction_order=8" },
    { "partitions", "smooth", 2, 44100, 0, 0, 5000, 1152, "min_partition_order=0:max_partition_order=0" },
    { "partitions_bad", "smooth", 2, 44100, 0, 0, 100, 0, "min_partition_order=5:max_partition_order=3" },
    { "exact_rice", "smooth", 2, 44100, 0, 0, 5000, 1152, "exact_rice_parameters=1" },
    { "exact_rice24", "smooth", 2, 96000, 1, 24, 5000, 1152, "exact_rice_parameters=1" },
    { "multi_dim_quant", "smooth", 1, 44100, 0, 0, 3000, 1152, "multi_dim_quant=1:max_prediction_order=4" },
    // 24- and 32-bit samples.
    { "bits24", "stereo", 2, 96000, 1, 24, 5000, 0, "-" },
    { "bits24_level8", "smooth", 2, 96000, 1, 24, 5000, 1152, "compression_level=8" },
    { "bits24_wasted", "wasted", 2, 96000, 1, 24, 5000, 1152, "-" },
    { "bits20", "smooth", 2, 48000, 1, 20, 3000, 1152, "-" },
    { "bits0_s32", "smooth", 2, 48000, 1, 0, 3000, 1152, "-" },
    { "bits32_not_experimental", "smooth", 2, 48000, 1, 32, 3000, 1152, "-" },
    { "bits32", "stereo", 2, 48000, 1, 32, 5000, 1152, "strict=experimental" },
    { "bits32_mid_side", "stereo", 2, 48000, 1, 32, 5000, 1152, "strict=experimental:ch_mode=mid_side" },
    { "bits32_left_side", "smooth", 2, 48000, 1, 32, 3000, 1152, "strict=experimental:ch_mode=left_side" },
    { "bits32_right_side", "smooth", 2, 48000, 1, 32, 3000, 1152, "strict=experimental:ch_mode=right_side" },
    { "bits32_fixed", "stereo", 2, 48000, 1, 32, 3000, 1152, "strict=experimental:compression_level=1" },
    { "bits32_extremes", "extremes", 2, 48000, 1, 32, 3000, 1152, "strict=experimental:ch_mode=left_side" },
    { "bits32_extremes_fixed", "extremes", 2, 48000, 1, 32, 3000, 1152, "strict=experimental:compression_level=0" },
    { "bits32_extremes_mono", "extremes", 1, 48000, 1, 32, 3000, 1152, "strict=experimental" },
    { "bits32_wasted", "wasted", 2, 48000, 1, 32, 3000, 1152, "strict=experimental:ch_mode=mid_side" },
    { "bits32_search", "smooth", 2, 48000, 1, 32, 3000, 1152, "strict=experimental:compression_level=12" },
    { "bits16_extremes", "extremes", 2, 44100, 0, 0, 3000, 1152, "-" },
    { "ramp32", "ramp", 2, 48000, 1, 32, 5000, 4096, "strict=experimental" },
    { "ramp32_odd", "ramp", 2, 48000, 1, 32, 4999, 4095, "strict=experimental:compression_level=8" },
    { "ramp32_cholesky", "ramp", 1, 48000, 1, 32, 3000, 1152, "strict=experimental:lpc_type=cholesky" },
    { "ramp24", "ramp", 2, 48000, 1, 24, 5000, 4096, "-" },
    // Sample rates: the table, kHz, tens of Hz, Hz, STREAMINFO only, too high.
    { "rate8000", "tone", 1, 8000, 0, 0, 1000, 0, "-" },
    { "rate192000", "tone", 1, 192000, 0, 0, 1000, 0, "-" },
    { "rate_khz", "tone", 1, 11000, 0, 0, 1000, 0, "-" },
    { "rate_tens", "tone", 1, 44110, 0, 0, 1000, 0, "-" },
    { "rate_hz", "tone", 1, 11025, 0, 0, 1000, 0, "-" },
    { "rate_streaminfo", "tone", 1, 100001, 0, 0, 1000, 0, "-" },
    { "rate_too_high", "tone", 1, 1048576, 0, 0, 100, 0, "-" },
};

int main(void)
{
    av_log_set_level(AV_LOG_QUIET);
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run(&cases[i]);
    return 0;
}
