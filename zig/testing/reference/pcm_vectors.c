// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T20b oracle (zig/testing/vectors/pcm.txt) by running the pinned
// FFmpeg's PCM decoders and encoders through libavcodec's send/receive API:
// for each codec, the SHA-256 of what it decodes from an input pattern (the
// decoded samples serialized little-endian) and of what it encodes from a
// sample pattern. The patterns are defined below and in zig/codec/pcm.zig's
// tests, which regenerate them; the Zig code is not derived from this file.
//
//   all8   bytes 0..255, or u8 samples 0..255
//   all16  every 16-bit value k in order, as little-endian bytes of k
//   lcg    65536 samples of bytes from x = x * 6364136223846793005 +
//          1442695040888963407 (mod 2^64, x0 = 1), byte = x >> 56
//
// See zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavcodec/avcodec.h"
#include "libavutil/channel_layout.h"
#include "libavutil/frame.h"
#include "libavutil/mem.h"
#include "libavutil/samplefmt.h"
#include "libavutil/sha.h"

#define LCG_SAMPLES 65536

static void fail(const char *what, const char *codec)
{
    fprintf(stderr, "pcm_vectors: %s failed for %s\n", what, codec);
    exit(1);
}

static void lcg_bytes(uint8_t *out, size_t n)
{
    uint64_t x = 1;
    for (size_t i = 0; i < n; i++) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        out[i] = (uint8_t)(x >> 56);
    }
}

/* Fills `out` with a pattern of `samples` values of `width` bytes each. */
static size_t pattern(const char *name, int width, uint8_t *out, int *samples)
{
    if (!strcmp(name, "all8")) {
        for (int i = 0; i < 256; i++)
            out[i] = (uint8_t)i;
        *samples = 256 / width;
        return 256;
    }
    if (!strcmp(name, "all16")) {
        for (int k = 0; k < 65536; k++) {
            out[2 * k] = (uint8_t)k;
            out[2 * k + 1] = (uint8_t)(k >> 8);
        }
        *samples = 131072 / width;
        return 131072;
    }
    lcg_bytes(out, (size_t)LCG_SAMPLES * width);
    *samples = LCG_SAMPLES;
    return (size_t)LCG_SAMPLES * width;
}

static int host_is_big_endian(void)
{
    const uint16_t one = 1;
    return *(const uint8_t *)&one == 0;
}

/* Copies samples of `size` bytes between native and little-endian order. */
static void swap_to_or_from_le(uint8_t *data, size_t bytes, int size)
{
    if (!host_is_big_endian() || size == 1)
        return;
    for (size_t i = 0; i < bytes; i += size)
        for (int a = 0, b = size - 1; a < b; a++, b--) {
            uint8_t t = data[i + a];
            data[i + a] = data[i + b];
            data[i + b] = t;
        }
}

static void print_sha(const uint8_t *data, size_t n)
{
    struct AVSHA *sha = av_sha_alloc();
    uint8_t digest[32];
    av_sha_init(sha, 256);
    av_sha_update(sha, data, n);
    av_sha_final(sha, digest);
    av_free(sha);
    for (int i = 0; i < 32; i++)
        printf("%02x", digest[i]);
    printf("\n");
}

static AVCodecContext *open_codec(const AVCodec *codec, enum AVSampleFormat fmt)
{
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx)
        fail("context", codec->name);
    ctx->sample_rate = 8000;
    if (fmt != AV_SAMPLE_FMT_NONE)
        ctx->sample_fmt = fmt;
    av_channel_layout_default(&ctx->ch_layout, 1);
    if (avcodec_open2(ctx, codec, NULL) < 0)
        fail("open", codec->name);
    return ctx;
}

static void decode_case(enum AVCodecID id, const char *pattern_name)
{
    const AVCodec *codec = avcodec_find_decoder(id);
    if (!codec)
        fail("find decoder", avcodec_get_name(id));
    AVCodecContext *ctx = open_codec(codec, AV_SAMPLE_FMT_NONE);
    int width = av_get_bits_per_sample(id) / 8;
    int samples;
    AVPacket *pkt = av_packet_alloc();
    if (av_new_packet(pkt, (int)((size_t)LCG_SAMPLES * 8 + 131072)) < 0)
        fail("packet", codec->name);
    pkt->size = (int)pattern(pattern_name, width, pkt->data, &samples);
    AVFrame *frame = av_frame_alloc();
    if (avcodec_send_packet(ctx, pkt) < 0 || avcodec_receive_frame(ctx, frame) < 0)
        fail("decode", codec->name);
    int size = av_get_bytes_per_sample(frame->format);
    size_t bytes = (size_t)frame->nb_samples * size;
    uint8_t *copy = malloc(bytes);
    memcpy(copy, frame->data[0], bytes);
    swap_to_or_from_le(copy, bytes, size);
    printf("D %s %s %d %s ", codec->name, pattern_name, frame->nb_samples, av_get_sample_fmt_name(frame->format));
    print_sha(copy, bytes);
    free(copy);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
}

static void encode_case(enum AVCodecID id, enum AVSampleFormat fmt, const char *pattern_name)
{
    const AVCodec *codec = avcodec_find_encoder(id);
    if (!codec)
        fail("find encoder", avcodec_get_name(id));
    AVCodecContext *ctx = open_codec(codec, fmt);
    int size = av_get_bytes_per_sample(fmt);
    int samples;
    uint8_t *storage = malloc((size_t)LCG_SAMPLES * 8 + 131072);
    size_t bytes = pattern(pattern_name, size, storage, &samples);
    swap_to_or_from_le(storage, bytes, size);
    AVFrame *frame = av_frame_alloc();
    frame->nb_samples = samples;
    frame->format = fmt;
    av_channel_layout_default(&frame->ch_layout, 1);
    if (av_frame_get_buffer(frame, 0) < 0)
        fail("frame", codec->name);
    memcpy(frame->data[0], storage, bytes);
    AVPacket *pkt = av_packet_alloc();
    if (avcodec_send_frame(ctx, frame) < 0 || avcodec_receive_packet(ctx, pkt) < 0)
        fail("encode", codec->name);
    printf("E %s %s %d %s ", codec->name, pattern_name, samples, av_get_sample_fmt_name(fmt));
    print_sha(pkt->data, pkt->size);
    free(storage);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
}

int main(void)
{
    static const struct {
        enum AVCodecID id;
        enum AVSampleFormat storage;
        const char *decode_pattern;
        const char *encode_pattern;
    } cases[] = {
        { AV_CODEC_ID_PCM_U8,    AV_SAMPLE_FMT_U8,  "all8",  "all8"  },
        { AV_CODEC_ID_PCM_S8,    AV_SAMPLE_FMT_U8,  "all8",  "all8"  },
        { AV_CODEC_ID_PCM_S16LE, AV_SAMPLE_FMT_S16, "all16", "all16" },
        { AV_CODEC_ID_PCM_S16BE, AV_SAMPLE_FMT_S16, "all16", "all16" },
        { AV_CODEC_ID_PCM_S24LE, AV_SAMPLE_FMT_S32, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_S24BE, AV_SAMPLE_FMT_S32, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_S32LE, AV_SAMPLE_FMT_S32, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_S32BE, AV_SAMPLE_FMT_S32, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_S64LE, AV_SAMPLE_FMT_S64, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_S64BE, AV_SAMPLE_FMT_S64, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_F32LE, AV_SAMPLE_FMT_FLT, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_F32BE, AV_SAMPLE_FMT_FLT, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_F64LE, AV_SAMPLE_FMT_DBL, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_F64BE, AV_SAMPLE_FMT_DBL, "lcg",   "lcg"   },
        { AV_CODEC_ID_PCM_ALAW,  AV_SAMPLE_FMT_S16, "all8",  "all16" },
        { AV_CODEC_ID_PCM_MULAW, AV_SAMPLE_FMT_S16, "all8",  "all16" },
    };
    printf("# T20b vectors from the pinned FFmpeg's libavcodec (pcm_vectors.c); do not edit.\n");
    printf("# D codec input_pattern decoded_samples storage sha256(decoded samples, little-endian)\n");
    printf("# E codec storage_pattern samples storage sha256(encoded bytes)\n");
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        decode_case(cases[i].id, cases[i].decode_pattern);
        encode_case(cases[i].id, cases[i].storage, cases[i].encode_pattern);
    }
    return 0;
}
