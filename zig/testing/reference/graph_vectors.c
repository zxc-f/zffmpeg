// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T25a filter graph oracle (zig/testing/vectors/graph.txt): what
// the pinned FFmpeg's libavfilter does with a linear chain of audio
// filters between a buffer source and a buffer sink. Each case builds the
// graph through the public API (avfilter_graph_alloc_filter,
// avfilter_init_dict, avfilter_link, avfilter_graph_config), the source
// first, then the chain's filters in order, then the sink; feeds it
// generated frames; and drains it. The lines of a case:
//
//   G <name>
//       a case begins
//   S <fmt> <rate> <layout> <tb num> <tb den>
//       the source: sample format name, rate, layout text (hex), time base
//   P <frames>:<pts> ...
//       the input frames: sample frames and pts ("-" when unset)
//   K <formats> <rates> <layouts>
//       the sink's lists, comma-separated as abuffersink takes them, in
//       hex, "-" when unset
//   V <options>
//       the graph's aresample_swr_opts, for the converters it inserts
//       (hex, "-" when unset)
//   F <filter> <key>=<value> ...
//       a filter of the chain, its options as avfilter_init_dict sets
//       them, the values in hex
//   X
//       a value FFmpeg reads as an expression (TODO.md T25b): the port
//       refuses it when the filter is created; nothing else follows
//   E init | E config
//       the filter's creation, or the graph's configuration, failed
//   L <filter> <fmt> <rate> <layout> <tb num> <tb den>
//       the graph after configuration, from the source to the sink: each
//       filter (instance name; converters are FFmpeg's auto_aresample_<n>)
//       and the link that leaves it, the layout described (hex)
//   O <frames> <pts> <bytes>
//       an output frame: its sample frames, pts ("-" when unset) and
//       samples in hex, plane after plane
//   D
//       the stream ended (AVERROR_EOF) and the case is done
//
// The input samples come from resample_vectors.c's smoothed generator,
// restarted for each case, one channel after another within a sample
// frame. The chain's filters are named f0, f1, ... in order.
// See zig/testing/reference/README.md for the build commands.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavfilter/avfilter.h"
#include "libavfilter/buffersink.h"
#include "libavfilter/buffersrc.h"
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/frame.h"
#include "libavutil/mem.h"
#include "libavutil/samplefmt.h"

static uint64_t state;

/* A smoothed pseudo-random signal in [-1, 1), as resample_vectors.c's. */
static double next_sample(double *memory)
{
    state = state * 6364136223846793005ULL + 1442695040888963407ULL;
    double white = (double)(int32_t)(state >> 32) / 2147483648.0 * 0.25;
    *memory = *memory * 0.9 + white * 0.1;
    return *memory * 4;
}

static void store(uint8_t *p, enum AVSampleFormat fmt, double v)
{
    switch (av_get_packed_sample_fmt(fmt)) {
    case AV_SAMPLE_FMT_U8:  *p = (uint8_t)lrint(v * 127 + 128); break;
    case AV_SAMPLE_FMT_S16: { int16_t s = (int16_t)lrint(v * 32767); memcpy(p, &s, 2); break; }
    case AV_SAMPLE_FMT_S32: { int32_t s = (int32_t)lrint(v * 2147483647.0); memcpy(p, &s, 4); break; }
    case AV_SAMPLE_FMT_S64: { int64_t s = llrint(v * 4611686018427387904.0); memcpy(p, &s, 8); break; }
    case AV_SAMPLE_FMT_FLT: { float s = (float)v; memcpy(p, &s, 4); break; }
    case AV_SAMPLE_FMT_DBL: memcpy(p, &v, 8); break;
    default: break;
    }
}

static void hex(const char *text)
{
    if (!text || !*text) {
        printf("-");
        return;
    }
    for (const unsigned char *p = (const unsigned char *)text; *p; p++)
        printf("%02x", *p);
}

#define NOPTS INT64_MIN
#define MAX_OPTS 6
#define MAX_CHAIN 6
#define MAX_FRAMES 8

struct opt { const char *key, *value; };
struct filt { const char *name; struct opt opts[MAX_OPTS]; };

struct graph_case {
    const char *name;
    enum AVSampleFormat fmt;
    int rate;
    const char *layout;
    int tb_num, tb_den;      /* 0/0: 1/rate */
    int sizes[MAX_FRAMES];   /* 0 ends the list */
    int64_t first_pts;       /* NOPTS: every frame unset */
    const char *sink_fmts, *sink_rates, *sink_layouts;
    const char *conv;        /* aresample_swr_opts */
    int expression;          /* a value is an expression (T25b) */
    struct filt chain[MAX_CHAIN];
};

static void print_link(const char *name, const AVFilterLink *link)
{
    char desc[256];
    av_channel_layout_describe(&link->ch_layout, desc, sizeof(desc));
    printf("L %s %s %d ", name, av_get_sample_fmt_name(link->format), link->sample_rate);
    hex(desc);
    printf(" %d %d\n", link->time_base.num, link->time_base.den);
}

static void print_frame(const AVFrame *frame)
{
    int planar = av_sample_fmt_is_planar(frame->format);
    int channels = frame->ch_layout.nb_channels;
    int bps = av_get_bytes_per_sample(frame->format);
    int planes = planar ? channels : 1;
    size_t plane_bytes = (size_t)frame->nb_samples * bps * (planar ? 1 : channels);

    printf("O %d ", frame->nb_samples);
    if (frame->pts == AV_NOPTS_VALUE)
        printf("-");
    else
        printf("%lld", (long long)frame->pts);
    printf(" ");
    if (!plane_bytes)
        printf("-");
    for (int p = 0; p < planes; p++)
        for (size_t i = 0; i < plane_bytes; i++)
            printf("%02x", frame->extended_data[p][i]);
    printf("\n");
}

static int drain(AVFilterContext *sink, AVFrame *out)
{
    int ret;
    while ((ret = av_buffersink_get_frame(sink, out)) >= 0) {
        print_frame(out);
        av_frame_unref(out);
    }
    return ret;
}

static void run_case(const struct graph_case *c)
{
    AVFilterGraph *graph = avfilter_graph_alloc();
    AVFilterContext *src = NULL, *sink = NULL, *chain[MAX_CHAIN];
    AVDictionary *dict = NULL;
    AVFrame *frame = av_frame_alloc(), *out = av_frame_alloc();
    AVChannelLayout layout = { 0 };
    char text[512];
    int tb_num = c->tb_num ? c->tb_num : 1, tb_den = c->tb_den ? c->tb_den : c->rate;
    int n = 0, ret;
    double memory[64] = { 0 };

    printf("G %s\n", c->name);
    printf("S %s %d ", av_get_sample_fmt_name(c->fmt), c->rate);
    hex(c->layout);
    printf(" %d %d\n", tb_num, tb_den);
    printf("P");
    {
        int64_t at = 0;
        for (int i = 0; i < MAX_FRAMES && c->sizes[i]; i++) {
            printf(" %d:", c->sizes[i]);
            if (c->first_pts == NOPTS)
                printf("-");
            else
                printf("%lld", (long long)(c->first_pts +
                       av_rescale_q(at, (AVRational){ 1, c->rate }, (AVRational){ tb_num, tb_den })));
            at += c->sizes[i];
        }
    }
    printf("\nK ");
    hex(c->sink_fmts);
    printf(" ");
    hex(c->sink_rates);
    printf(" ");
    hex(c->sink_layouts);
    printf("\nV ");
    hex(c->conv);
    printf("\n");
    for (n = 0; n < MAX_CHAIN && c->chain[n].name; n++) {
        printf("F %s", c->chain[n].name);
        for (int o = 0; o < MAX_OPTS && c->chain[n].opts[o].key; o++) {
            printf(" %s=", c->chain[n].opts[o].key);
            hex(c->chain[n].opts[o].value);
        }
        printf("\n");
    }
    if (c->expression) {
        printf("X\n");
        goto done;
    }

    /* The source. */
    src = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("abuffer"), "in");
    av_dict_set(&dict, "sample_fmt", av_get_sample_fmt_name(c->fmt), 0);
    av_dict_set_int(&dict, "sample_rate", c->rate, 0);
    av_dict_set(&dict, "channel_layout", c->layout, 0);
    snprintf(text, sizeof(text), "%d/%d", tb_num, tb_den);
    av_dict_set(&dict, "time_base", text, 0);
    ret = avfilter_init_dict(src, &dict);
    av_dict_free(&dict);
    if (ret < 0) {
        printf("E init\n");
        goto done;
    }

    /* The chain. */
    for (int i = 0; i < n; i++) {
        snprintf(text, sizeof(text), "f%d", i);
        chain[i] = avfilter_graph_alloc_filter(graph, avfilter_get_by_name(c->chain[i].name), text);
        for (int o = 0; o < MAX_OPTS && c->chain[i].opts[o].key; o++)
            av_dict_set(&dict, c->chain[i].opts[o].key, c->chain[i].opts[o].value, 0);
        ret = avfilter_init_dict(chain[i], &dict);
        if (ret >= 0 && av_dict_count(dict))
            ret = -1; /* an option no filter took */
        av_dict_free(&dict);
        if (ret < 0) {
            printf("E init\n");
            goto done;
        }
    }

    /* The sink. */
    sink = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("abuffersink"), "out");
    if (c->sink_fmts)
        av_dict_set(&dict, "sample_formats", c->sink_fmts, 0);
    if (c->sink_rates)
        av_dict_set(&dict, "samplerates", c->sink_rates, 0);
    if (c->sink_layouts)
        av_dict_set(&dict, "channel_layouts", c->sink_layouts, 0);
    ret = avfilter_init_dict(sink, &dict);
    av_dict_free(&dict);
    if (ret < 0) {
        printf("E init\n");
        goto done;
    }

    if (c->conv)
        graph->aresample_swr_opts = av_strdup(c->conv);
    {
        AVFilterContext *prev = src;
        for (int i = 0; i < n; i++) {
            avfilter_link(prev, 0, chain[i], 0);
            prev = chain[i];
        }
        avfilter_link(prev, 0, sink, 0);
    }
    if (avfilter_graph_config(graph, NULL) < 0) {
        printf("E config\n");
        goto done;
    }
    for (AVFilterContext *f = src; f != sink; f = f->outputs[0]->dst)
        print_link(f->name, f->outputs[0]);

    /* The frames. */
    av_channel_layout_from_string(&layout, c->layout);
    state = 1;
    {
        int64_t at = 0;
        for (int i = 0; i < MAX_FRAMES && c->sizes[i]; i++) {
            int channels = layout.nb_channels, bps = av_get_bytes_per_sample(c->fmt);
            int planar = av_sample_fmt_is_planar(c->fmt);
            frame->format = c->fmt;
            frame->sample_rate = c->rate;
            frame->nb_samples = c->sizes[i];
            av_channel_layout_copy(&frame->ch_layout, &layout);
            av_frame_get_buffer(frame, 0);
            for (int s = 0; s < c->sizes[i]; s++)
                for (int ch = 0; ch < channels; ch++) {
                    uint8_t *p = planar ? frame->extended_data[ch] + (size_t)s * bps
                                        : frame->extended_data[0] + ((size_t)s * channels + ch) * bps;
                    store(p, c->fmt, next_sample(&memory[ch]));
                }
            frame->pts = c->first_pts == NOPTS ? AV_NOPTS_VALUE :
                         c->first_pts + av_rescale_q(at, (AVRational){ 1, c->rate }, (AVRational){ tb_num, tb_den });
            at += c->sizes[i];
            if (av_buffersrc_add_frame(src, frame) < 0) {
                printf("E frame\n");
                goto done;
            }
            av_frame_unref(frame);
            ret = drain(sink, out);
            if (ret != AVERROR(EAGAIN)) {
                printf("E run\n");
                goto done;
            }
        }
    }
    if (av_buffersrc_add_frame(src, NULL) < 0) {
        printf("E frame\n");
        goto done;
    }
    ret = drain(sink, out);
    if (ret != AVERROR_EOF) {
        printf("E run\n");
        goto done;
    }
    printf("D\n");
done:
    av_channel_layout_uninit(&layout);
    av_frame_free(&frame);
    av_frame_free(&out);
    avfilter_graph_free(&graph);
}

#define F(...) { __VA_ARGS__ }
#define SIZES(...) { __VA_ARGS__ }

static const struct graph_case cases[] = {
    /* The source straight into the sink, and anull, in every format. */
    { "direct_s16", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0 },
    { "anull_u8", AV_SAMPLE_FMT_U8, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_s16", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_s32", AV_SAMPLE_FMT_S32, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_s64", AV_SAMPLE_FMT_S64, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_flt", AV_SAMPLE_FMT_FLT, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_dbl", AV_SAMPLE_FMT_DBL, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_u8p", AV_SAMPLE_FMT_U8P, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_s16p", AV_SAMPLE_FMT_S16P, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_s32p", AV_SAMPLE_FMT_S32P, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_s64p", AV_SAMPLE_FMT_S64P, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_fltp", AV_SAMPLE_FMT_FLTP, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_dblp", AV_SAMPLE_FMT_DBLP, 44100, "stereo", 0, 0, SIZES(64, 1, 100), 0, .chain = { F("anull") } },
    { "anull_twice_5.1", AV_SAMPLE_FMT_S16, 48000, "5.1", 0, 0, SIZES(32, 32), 0,
      .chain = { F("anull"), F("anull") } },
    { "anull_unspecified", AV_SAMPLE_FMT_S16, 8000, "3C", 0, 0, SIZES(20, 7), 0, .chain = { F("anull") } },
    { "anull_custom", AV_SAMPLE_FMT_S16, 8000, "FR+FL", 0, 0, SIZES(20), 0, .chain = { F("anull") } },
    { "anull_nopts", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(10, 10), NOPTS, .chain = { F("anull") } },
    { "anull_ms", AV_SAMPLE_FMT_FLT, 44100, "mono", 1, 1000, SIZES(441, 441, 100), -250, .chain = { F("anull") } },

    /* aformat: formats, rates and layouts chosen as the graph chooses. */
    { "aformat_empty", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0, .chain = { F("aformat") } },
    { "aformat_same", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "sample_fmts", "s16" } }) } },
    { "aformat_planar", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64, 3), 0,
      .chain = { F("aformat", { { "sample_fmts", "flt|s16p" } }) } },
    { "aformat_s32_to_double", AV_SAMPLE_FMT_S32, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "f", "u8|dbl|s16" } }) } },
    { "aformat_flt_to_s32", AV_SAMPLE_FMT_FLT, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "f", "s16|s32" } }) } },
    { "aformat_u8_to_s16", AV_SAMPLE_FMT_U8, 44100, "mono", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "f", "dblp|s16p|s32" } }) } },
    { "aformat_number", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "f", "3" } }) } },
    { "aformat_rates", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(300, 300), 0,
      .chain = { F("aformat", { { "sample_rates", "22050|48000" } }) } },
    { "aformat_rates_below", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(300), 0,
      .chain = { F("aformat", { { "r", "8000|32000" } }) } },
    { "aformat_rate_same", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(30), 0,
      .chain = { F("aformat", { { "r", "8000|44100" } }) } },
    { "aformat_stereo_to_mono", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "channel_layouts", "5.1|mono" } }) } },
    { "aformat_5.1_down", AV_SAMPLE_FMT_FLT, 48000, "5.1", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "cl", "stereo|quad|7.1" } }) } },
    { "aformat_5.1_side", AV_SAMPLE_FMT_FLT, 48000, "5.1(side)", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "cl", "5.1|stereo" } }) } },
    { "aformat_mono_up", AV_SAMPLE_FMT_S16, 48000, "mono", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "cl", "stereo|2.1|3.0" } }) } },
    { "aformat_count", AV_SAMPLE_FMT_S16, 48000, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "cl", "3C|mono" } }) } },
    { "aformat_unspecified_in", AV_SAMPLE_FMT_S16, 48000, "2C", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "cl", "stereo" } }) } },
    { "aformat_all", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(200, 50), 0,
      .chain = { F("aformat", { { "f", "fltp" }, { "r", "32000" }, { "cl", "mono" } }) } },
    { "aformat_bad_format", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "f", "s16|s17" } }) } },
    { "aformat_bad_rate", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "r", "0" } }) } },
    { "aformat_bad_layout", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aformat", { { "cl", "stereo|nonsense" } }) } },
    { "aformat_twice", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(100), 0,
      .chain = { F("aformat", { { "f", "flt|s32" } }), F("aformat", { { "f", "s32|dbl" } }) } },

    /* volume. */
    { "volume_float", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64, 100), 0,
      .chain = { F("volume", { { "volume", "0.5" } }) } },
    { "volume_float_to_s16", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64, 100), 0,
      .sink_fmts = "s16", .chain = { F("volume", { { "volume", "0.5" } }) } },
    { "volume_float_planar", AV_SAMPLE_FMT_FLTP, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "1.75" } }) } },
    { "volume_float_db", AV_SAMPLE_FMT_FLT, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "-6dB" } }) } },
    { "volume_float_space", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "volume", " 2 " } }) } },
    { "volume_float_one", AV_SAMPLE_FMT_FLT, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "1" } }) } },
    { "volume_float_negative_zero", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "volume", "-0" } }) } },
    { "volume_float_eval_frame", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16, 16), 0,
      .chain = { F("volume", { { "volume", "0.25" }, { "eval", "frame" } }) } },
    { "volume_double", AV_SAMPLE_FMT_DBL, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "0.3" }, { "precision", "double" } }) } },
    { "volume_double_from_s32", AV_SAMPLE_FMT_S32, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "3" }, { "precision", "double" } }) } },
    { "volume_fixed_s16", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "0.5" }, { "precision", "fixed" } }) } },
    { "volume_fixed_s16_loud", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "3.3" }, { "precision", "fixed" } }) } },
    { "volume_fixed_s16_wide", AV_SAMPLE_FMT_S16P, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "300" }, { "precision", "fixed" } }) } },
    { "volume_fixed_u8", AV_SAMPLE_FMT_U8, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "1.5" }, { "precision", "0" } }) } },
    { "volume_fixed_u8p_wide", AV_SAMPLE_FMT_U8P, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "70000" }, { "precision", "fixed" } }) } },
    { "volume_fixed_s32", AV_SAMPLE_FMT_S32, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "0.8" }, { "precision", "fixed" } }) } },
    { "volume_fixed_s32p_loud", AV_SAMPLE_FMT_S32P, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "4" }, { "precision", "fixed" } }) } },
    { "volume_fixed_tiny", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "volume", "0.001" }, { "precision", "fixed" } }) } },
    { "volume_fixed_negative_u8", AV_SAMPLE_FMT_U8, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "volume", "-0.5" }, { "precision", "fixed" } }) } },
    { "volume_fixed_one", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "volume", "1.001" }, { "precision", "fixed" } }) } },
    { "volume_fixed_from_flt", AV_SAMPLE_FMT_FLT, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("volume", { { "volume", "0.5" }, { "precision", "fixed" } }) } },
    { "volume_replaygain", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "volume", "0.5" }, { "replaygain", "track" }, { "replaygain_preamp", "3" },
                               { "replaygain_noclip", "0" } }) } },
    { "volume_nan", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "volume", "nan" } }) } },
    { "volume_bad_precision", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "precision", "half" } }) } },
    { "volume_expression", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16), 0, .expression = 1,
      .chain = { F("volume", { { "volume", "1/2" } }) } },
    { "volume_unknown_option", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("volume", { { "gain", "2" } }) } },

    /* aresample. */
    { "aresample_none", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64, 100), 0, .chain = { F("aresample") } },
    { "aresample_48000", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(300, 300, 7), 0,
      .chain = { F("aresample", { { "sample_rate", "48000" } }) } },
    { "aresample_osr", AV_SAMPLE_FMT_FLTP, 48000, "stereo", 0, 0, SIZES(400, 400), 0,
      .chain = { F("aresample", { { "osr", "22.05k" } }) } },
    { "aresample_osf", AV_SAMPLE_FMT_FLT, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aresample", { { "osf", "s16p" } }) } },
    { "aresample_ochl", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0,
      .chain = { F("aresample", { { "ochl", "mono" } }) } },
    { "aresample_dither", AV_SAMPLE_FMT_S32, 44100, "stereo", 0, 0, SIZES(64, 64), 0,
      .chain = { F("aresample", { { "osf", "s16" }, { "dither_method", "triangular" } }) } },
    { "aresample_resampler_options", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(500), 0,
      .chain = { F("aresample", { { "sample_rate", "32000" }, { "filter_size", "32" }, { "phase_shift", "8" },
                                  { "cutoff", "0.9" }, { "filter_type", "kaiser" }, { "kaiser_beta", "12" } }) } },
    { "aresample_linear", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(500), 0,
      .chain = { F("aresample", { { "sample_rate", "48000" }, { "linear_interp", "1" }, { "exact_rational", "0" } }) } },
    { "aresample_mix_and_rate", AV_SAMPLE_FMT_S16, 48000, "5.1", 0, 0, SIZES(256, 256), 0,
      .chain = { F("aresample", { { "sample_rate", "44100" }, { "ochl", "stereo" }, { "osf", "flt" } }) } },
    { "aresample_ms_pts", AV_SAMPLE_FMT_S16, 44100, "mono", 1, 1000, SIZES(441, 441, 441), 500,
      .chain = { F("aresample", { { "sample_rate", "48000" } }) } },
    { "aresample_negative_pts", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(300, 300), -100,
      .chain = { F("aresample", { { "sample_rate", "8000" } }) } },
    { "aresample_nopts", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(300, 300), NOPTS,
      .chain = { F("aresample", { { "sample_rate", "48000" } }) } },
    { "aresample_tiny_frames", AV_SAMPLE_FMT_FLT, 8000, "mono", 0, 0, SIZES(1, 1, 1, 2, 3, 5, 8), 0,
      .chain = { F("aresample", { { "sample_rate", "48000" } }) } },
    { "aresample_unknown_option", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(16), 0,
      .chain = { F("aresample", { { "speed", "2" } }) } },

    /* The sink's lists, and the converters' options. */
    { "sink_format", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0, .sink_fmts = "flt" },
    { "sink_formats", AV_SAMPLE_FMT_S32, 44100, "stereo", 0, 0, SIZES(64), 0, .sink_fmts = "u8,dbl,s16" },
    { "sink_rate", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(300, 300), 0, .sink_rates = "8000" },
    { "sink_rates", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(300), 0, .sink_rates = "96000,48000" },
    { "sink_layout", AV_SAMPLE_FMT_S16, 44100, "5.1", 0, 0, SIZES(64), 0, .sink_layouts = "stereo" },
    { "sink_layouts", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(64), 0, .sink_layouts = "5.1,stereo" },
    { "sink_all", AV_SAMPLE_FMT_U8, 22050, "stereo", 0, 0, SIZES(300, 100), 0,
      .sink_fmts = "s16p", .sink_rates = "11025", .sink_layouts = "mono" },
    { "sink_after_chain", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64), 0, .sink_fmts = "s16",
      .chain = { F("anull"), F("volume", { { "volume", "0.5" } }), F("anull") } },
    { "converter_dither", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(64, 64), 0, .sink_fmts = "s16",
      .conv = "dither_method=triangular_hp", .chain = { F("volume", { { "volume", "0.7" } }) } },
    { "converter_resampler", AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, SIZES(300), 0, .sink_rates = "48000",
      .conv = "filter_size=16:phase_shift=6" },

    /* Chains. */
    { "chain_mixed", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(256, 256, 17), 0, .sink_fmts = "s16",
      .chain = { F("aformat", { { "f", "fltp" } }), F("volume", { { "volume", "0.5" } }),
                 F("aresample", { { "sample_rate", "22050" } }), F("aformat", { { "cl", "mono" } }), F("anull") } },
    { "chain_fixed_after_float", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(100), 0,
      .chain = { F("volume", { { "volume", "0.5" } }), F("volume", { { "volume", "2" }, { "precision", "fixed" } }) } },
    { "chain_layout_unselectable", AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, SIZES(200), 0, .sink_fmts = "s16",
      .chain = { F("aformat", { { "cl", "mono|5.1" } }), F("volume", { { "volume", "0.5" } }),
                 F("aresample", { { "sample_rate", "48000" } }) } },
    { "chain_double_rates", AV_SAMPLE_FMT_S16, 44100, "mono", 0, 0, SIZES(300), 0,
      .chain = { F("aresample", { { "sample_rate", "48000" } }), F("aresample", { { "sample_rate", "44100" } }) } },
};

int main(void)
{
    av_log_set_level(AV_LOG_QUIET);
    for (int i = 0; i < (int)(sizeof(cases) / sizeof(*cases)); i++)
        run_case(&cases[i]);
    return 0;
}
