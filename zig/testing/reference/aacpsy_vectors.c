// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T32d AAC psychoacoustic model oracle
// (zig/testing/vectors/aacpsy.txt): what the pinned FFmpeg's psy model
// (libavcodec/psymodel.c, aacpsy.c, reached through the static
// libavcodec's internal ff_psy_init and ff_aac_psy_model) makes of
// deterministic input, driven as aacenc.c drives it. Each case opens the
// model with aacenc.c's band tables for its rate and its element map, then
// runs frames: the samples are shifted through per-channel buffers of
// 3 * 1024 floats as copy_input_samples does, the window decision reads
// the lookahead at buffer + 1536 (window_pair for a CPE, window for an
// SCE; an LFE gets aacenc.c's fixed long window), and analyze gets
// deterministic spectra, with the rate loop's re-runs of a frame under
// the same frame_num on some frames. The samples are alac_vectors.c's
// 16-bit signals (plus three of this file's) over 32768, times the case's
// gain, with NaN and infinities at fixed places when the case asks for
// them, so the Zig test makes the same input. Floats are printed as
// their IEEE bits in hex. The lines:
//
//   C <name> <rate> <elements> <bit_rate> <qscale> <global_quality>
//     <unbounded_pe> <cutoff> <avctx_cutoff> <frames> <signal> <gain>
//     <specials> <decoupled>
//                                a case; elements: S (SCE), P (CPE) and
//                                L (LFE), in order; cutoff is ff_psy_init's
//                                argument, avctx_cutoff the codec
//                                context's
//   O <result>                   ff_psy_init: ok or the error
//   B <bitres.size>              after opening
//   F <frame>                    a frame begins (frame_num is frame + 1)
//   W <ch> <type0> <type1> <type2> <shape> <num_windows> <grouping x8>
//     <clipping x8>              the channel's window information
//   A <pass> <first_ch> <bitres.bits> <bitres.alloc>
//                                an element analyzed
//   N <ch> <entropy> {<bits>,<energy>,<threshold>,<spread>}
//                                the channel's entropy and each band the
//                                analysis wrote (window w, band g at
//                                w * 16 + g), in order
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
#include "libavutil/error.h"

// The internal declarations this file uses, copied from the pinned
// revision's libavcodec/psymodel.h, aac.h, aactab.h and aacenctab.h, so it
// builds against the installed public headers alone (CI keeps only the
// install tree). The layouts must stay those of psymodel.h.

#define PSY_MAX_BANDS 128
#define PSY_MAX_CHANS 20

enum WindowSequence {
    ONLY_LONG_SEQUENCE,
    LONG_START_SEQUENCE,
    EIGHT_SHORT_SEQUENCE,
    LONG_STOP_SEQUENCE,
};

typedef struct FFPsyBand {
    int bits;
    float energy;
    float threshold;
    float spread;
} FFPsyBand;

typedef struct FFPsyChannel {
    FFPsyBand psy_bands[PSY_MAX_BANDS];
    float entropy;
} FFPsyChannel;

typedef struct FFPsyChannelGroup {
    FFPsyChannel *ch[PSY_MAX_CHANS];
    uint8_t num_ch;
    uint8_t coupling[PSY_MAX_BANDS];
} FFPsyChannelGroup;

typedef struct FFPsyWindowInfo {
    int window_type[3];
    int window_shape;
    int num_windows;
    int grouping[8];
    float clipping[8];
    int *window_sizes;
} FFPsyWindowInfo;

typedef struct FFPsyContext {
    AVCodecContext *avctx;
    const struct FFPsyModel *model;
    FFPsyChannel *ch;
    FFPsyChannelGroup *group;
    int num_groups;
    int cutoff;
    int unbounded_pe;
    uint8_t **bands;
    int *num_bands;
    int num_lens;
    struct {
        int size;
        int bits;
        int alloc;
    } bitres;
    void *model_priv_data;
    float pair_joint[16];
    uint8_t pair_decoupled[16];
} FFPsyContext;

typedef struct FFPsyModel {
    const char *name;
    int (*init)(FFPsyContext *apc);
    FFPsyWindowInfo (*window)(FFPsyContext *ctx, const float *audio, const float *la, int channel, int prev_type);
    void (*window_pair)(FFPsyContext *ctx, const float *audio0, const float *la0, const float *audio1,
                        const float *la1, int channel0, int channel1, int prev_type0, int prev_type1,
                        FFPsyWindowInfo wi[2]);
    void (*analyze)(FFPsyContext *ctx, int channel, const float **coeffs, const FFPsyWindowInfo *wi);
    void (*end)(FFPsyContext *apc);
} FFPsyModel;

int ff_psy_init(FFPsyContext *ctx, AVCodecContext *avctx, int num_lens, const uint8_t **bands,
                const int *num_bands, int num_groups, const uint8_t *group_map, int cutoff);
void ff_psy_end(FFPsyContext *ctx);

extern const uint8_t *const ff_aac_swb_size_1024[];
extern const uint8_t *const ff_aac_swb_size_128[];
extern const uint8_t ff_aac_num_swb_1024[];
extern const uint8_t ff_aac_num_swb_128[];

struct Case {
    const char *name;
    int rate;
    const char *elements;
    int64_t bit_rate;
    int qscale;
    int global_quality;
    int unbounded;
    int cutoff;
    int avctx_cutoff;
    int frames;
    const char *signal;
    int gain;
    int specials;
    int decoupled;
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

// alac_vectors.c's 16-bit `sample`, plus `gap` (quiet noise with a loud
// burst every 16384 samples), `click` (an impulse every 1777 samples over
// quiet noise) and `soft` (a soft noise burst every 1500 samples over a
// floor, an attack without HF novelty).
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
    } else if (!strcmp(signal, "gap")) {
        v = (i + 300 * c) % 16384 >= 14336 ? noise : noise / 512;
    } else if (!strcmp(signal, "click")) {
        v = (i + 97 * c) % 1777 < 8 ? 30000 : noise / 64;
    } else if (!strcmp(signal, "soft")) {
        v = (i + 211 * c) % 1500 < 100 ? noise / 64 : noise / 384;
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

// A deterministic spectrum of one of five kinds: zeros, falling noise,
// tonal lines over a floor, loud noise, and low-band noise; NaN and
// infinities at fixed lines when the case asks for them.
static void spectrum(const struct Case *t, float *out, int kind)
{
    for (int k = 0; k < 1024; k++) {
        const int n = (int)(rng() & 0xffff) - 0x8000;
        float v;
        switch (kind) {
        case 0: v = 0.0f; break;
        case 1: v = (float)n * ((float)t->gain / (float)(k + 8)); break;
        case 2: v = k % 37 == 5 ? (float)n * 4.0f : (float)n * (1.0f / 65536.0f); break;
        case 3: v = (float)n * 1000.0f; break;
        default: v = k < 64 ? (float)n * 0.25f : 0.0f; break;
        }
        if (t->specials && kind != 0) {
            if (k % 211 == 7)
                v = NAN;
            else if (k % 223 == 9)
                v = INFINITY;
        }
        out[k] = v;
    }
}

static int sampling_index(int rate)
{
    static const int rates[] = { 96000, 88200, 64000, 48000, 44100, 32000, 24000,
                                 22050, 16000, 12000, 11025, 8000, 7350 };
    for (int i = 0; i < 13; i++)
        if (rates[i] == rate)
            return i;
    abort();
}

static unsigned bits(float f)
{
    unsigned u;
    memcpy(&u, &f, 4);
    return u;
}

static void print_window(int ch, const FFPsyWindowInfo *wi)
{
    printf("W %d %d %d %d %d %d", ch, wi->window_type[0], wi->window_type[1], wi->window_type[2],
           wi->window_shape, wi->num_windows);
    for (int i = 0; i < 8; i++)
        printf(" %d", wi->grouping[i]);
    for (int i = 0; i < 8; i++)
        printf(" %08x", bits(wi->clipping[i]));
    printf("\n");
}

static void run(const struct Case *t)
{
    printf("C %s %d %s %" PRId64 " %d %d %d %d %d %d %s %d %d %d\n", t->name, t->rate, t->elements, t->bit_rate,
           t->qscale, t->global_quality, t->unbounded, t->cutoff, t->avctx_cutoff, t->frames, t->signal, t->gain,
           t->specials, t->decoupled);
    const int nelem = (int)strlen(t->elements);
    int channels = 0;
    uint8_t grouping[16];
    for (int i = 0; i < nelem; i++) {
        grouping[i] = t->elements[i] == 'P';
        channels += grouping[i] + 1;
    }
    AVCodecContext *ctx = avcodec_alloc_context3(avcodec_find_encoder_by_name("aac"));
    ctx->sample_rate = t->rate;
    av_channel_layout_default(&ctx->ch_layout, channels);
    ctx->bit_rate = t->bit_rate;
    if (t->qscale)
        ctx->flags |= AV_CODEC_FLAG_QSCALE;
    ctx->global_quality = t->global_quality;
    ctx->cutoff = t->avctx_cutoff;

    const int idx = sampling_index(t->rate);
    const uint8_t *sizes[2] = { ff_aac_swb_size_1024[idx], ff_aac_swb_size_128[idx] };
    const int lengths[2] = { ff_aac_num_swb_1024[idx], ff_aac_num_swb_128[idx] };
    FFPsyContext psy;
    memset(&psy, 0, sizeof(psy));
    psy.unbounded_pe = t->unbounded;
    int ret = ff_psy_init(&psy, ctx, 2, sizes, lengths, nelem, grouping, t->cutoff);
    if (ret < 0) {
        printf("O %s\n", ret == AVERROR(EINVAL) ? "EINVAL" : "error");
        ff_psy_end(&psy);
        avcodec_free_context(&ctx);
        return;
    }
    printf("O ok\nB %d\n", psy.bitres.size);

    float(*buf)[3072] = calloc(channels, sizeof(*buf));
    float(*coef)[1024] = calloc(channels, sizeof(*coef));
    FFPsyWindowInfo wi[16];
    int prev_type[16] = { 0 };
    int state[8] = { 0 };
    rng_state = 0x9E3779B9u ^ (uint32_t)(channels * 1000003 + t->frames);
    for (int f = 0; f < t->frames; f++) {
        // The last frame is the flush: no input, no lookahead.
        const int last = f == t->frames - 1;
        printf("F %d\n", f);
        for (int c = 0; c < channels; c++) {
            memcpy(&buf[c][1024], &buf[c][2048], 1024 * sizeof(float));
            memset(&buf[c][2048], 0, 1024 * sizeof(float));
        }
        if (!last)
            for (int i = 0; i < 1024; i++)
                for (int c = 0; c < channels; c++)
                    buf[c][2048 + i] = fsample(t, c, f * 1024 + i, state);
        ctx->frame_num = f + 1;
        if (t->decoupled)
            for (int i = 0; i < 16; i++)
                psy.pair_decoupled[i] = (f / 2) & 1;

        int start = 0;
        for (int e = 0; e < nelem; e++) {
            const char tag = t->elements[e];
            const int chans = tag == 'P' ? 2 : 1;
            if (tag == 'L') {
                memset(&wi[start], 0, sizeof(wi[start]));
                wi[start].window_type[0] = wi[start].window_type[1] = ONLY_LONG_SEQUENCE;
                wi[start].window_shape = 0;
                wi[start].num_windows = 1;
                wi[start].grouping[0] = 1;
                wi[start].clipping[0] = 0;
            } else if (chans == 2 && !last) {
                psy.model->window_pair(&psy, &buf[start][1024], &buf[start][1536], &buf[start + 1][1024],
                                       &buf[start + 1][1536], start, start + 1, prev_type[start],
                                       prev_type[start + 1], &wi[start]);
            } else {
                for (int c = start; c < start + chans; c++)
                    wi[c] = psy.model->window(&psy, &buf[c][1024], last ? NULL : &buf[c][1536], c, prev_type[c]);
            }
            for (int c = start; c < start + chans; c++) {
                prev_type[c] = wi[c].window_type[0];
                print_window(c, &wi[c]);
            }
            start += chans;
        }

        for (int c = 0; c < channels; c++)
            spectrum(t, coef[c], (f + c) % 5);

        // The rate loop's re-runs: every element again, same frame_num.
        const int passes = f % 3 == 1 ? 2 : f % 5 == 3 ? 3 : 1;
        for (int pass = 0; pass < passes; pass++) {
            start = 0;
            for (int e = 0; e < nelem; e++) {
                const int chans = t->elements[e] == 'P' ? 2 : 1;
                const float *coeffs[2] = { coef[start], chans == 2 ? coef[start + 1] : NULL };
                psy.bitres.alloc = -1;
                psy.bitres.bits = (f * 7919 + start * 1009 + pass * 331) % 4500;
                psy.model->analyze(&psy, start, coeffs, &wi[start]);
                printf("A %d %d %d %d\n", pass, start, psy.bitres.bits, psy.bitres.alloc);
                for (int c = start; c < start + chans; c++) {
                    const int num_bands = lengths[wi[c].num_windows == 8];
                    printf("N %d %08x", c, bits(psy.ch[c].entropy));
                    for (int w = 0; w < wi[c].num_windows; w++)
                        for (int g = 0; g < num_bands; g++) {
                            const FFPsyBand *b = &psy.ch[c].psy_bands[w * 16 + g];
                            printf(" %d,%08x,%08x,%08x", b->bits, bits(b->energy), bits(b->threshold),
                                   bits(b->spread));
                        }
                    printf("\n");
                }
                start += chans;
            }
        }
    }
    free(coef);
    free(buf);
    ff_psy_end(&psy);
    avcodec_free_context(&ctx);
}

int main(void)
{
    static const struct Case cases[] = {
        { "mono_44k_64k_tone", 44100, "S", 64000, 0, 0, 0, 16000, 0, 8, "tone", 1, 0, 0 },
        { "mono_48k_128k_noise", 48000, "S", 128000, 0, 0, 0, 20000, 0, 8, "noise", 1, 0, 0 },
        { "stereo_44k_128k_gap", 44100, "P", 128000, 0, 0, 0, 17000, 0, 36, "gap", 1, 0, 0 },
        { "stereo_48k_96k_click", 48000, "P", 96000, 0, 0, 0, 14000, 0, 12, "click", 1, 0, 0 },
        { "stereo_32k_48k_smooth", 32000, "P", 48000, 0, 0, 0, 9000, 0, 8, "smooth", 1, 0, 0 },
        { "stereo_22k_32k_tone", 22050, "P", 32000, 0, 0, 0, 8000, 0, 8, "tone", 1, 0, 0 },
        { "mono_8k_12k_noise", 8000, "S", 12000, 0, 0, 0, 3500, 0, 8, "noise", 1, 0, 0 },
        { "surround_48k_384k_gap", 48000, "SPPL", 384000, 0, 0, 0, 18000, 0, 20, "gap", 1, 0, 0 },
        { "stereo_qscale_q2_click", 44100, "P", 128000, 1, 236, 0, 16000, 0, 12, "click", 1, 0, 0 },
        { "stereo_qscale_default_gap", 48000, "P", 0, 1, 0, 0, 18000, 0, 20, "gap", 1, 0, 0 },
        { "stereo_unbounded_gap", 44100, "P", 160000, 0, 0, 1, 17000, 0, 20, "gap", 1, 0, 0 },
        { "stereo_decoupled_click", 48000, "P", 128000, 0, 0, 0, 16000, 0, 12, "click", 1, 0, 1 },
        { "mono_avctx_cutoff", 44100, "S", 64000, 0, 0, 0, 0, 5000, 6, "noise", 1, 0, 0 },
        { "mono_derived_cutoff", 44100, "S", 64000, 0, 0, 0, 0, 0, 6, "tone", 1, 0, 0 },
        { "mono_derived_cutoff_qscale", 32000, "S", 0, 1, 590, 0, 0, 0, 6, "click", 1, 0, 0 },
        { "mono_negative_cutoff", 44100, "S", 64000, 0, 0, 0, -1, 0, 4, "tone", 1, 0, 0 },
        { "stereo_specials", 48000, "P", 128000, 0, 0, 0, 16000, 0, 10, "noise", 1, 1, 0 },
        { "stereo_loud_extremes", 44100, "P", 256000, 0, 0, 0, 20000, 0, 8, "extremes", 1000, 0, 0 },
        { "mono_96k_256k_click", 96000, "S", 256000, 0, 0, 0, 30000, 0, 8, "click", 1, 0, 0 },
        { "mono_silence", 44100, "S", 64000, 0, 0, 0, 16000, 0, 6, "silence", 1, 0, 0 },
        { "stereo_44k_24k_gap", 44100, "P", 24000, 0, 0, 0, 5000, 0, 20, "gap", 1, 0, 0 },
        { "mono_16k_24k_tone", 16000, "S", 24000, 0, 0, 0, 6000, 0, 8, "tone", 1, 0, 0 },
        { "mono_7350_8k_click", 7350, "S", 8000, 0, 0, 0, 3000, 0, 8, "click", 1, 0, 0 },
        { "mono_qscale_soft", 44100, "S", 64000, 1, 354, 0, 16000, 0, 16, "soft", 1, 0, 0 },
        { "stereo_qscale_soft", 48000, "P", 128000, 1, 118, 0, 18000, 0, 12, "soft", 1, 0, 0 },
        { "quad_64k_200k_noise", 64000, "PP", 200000, 0, 0, 0, 20000, 0, 6, "noise", 1, 0, 0 },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++)
        run(&cases[i]);
    return 0;
}
