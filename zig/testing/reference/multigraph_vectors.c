// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T25c filter graph oracle (zig/testing/vectors/multigraph.txt):
// what the pinned FFmpeg's libavfilter does with graphs of several inputs
// and outputs. Each case creates its buffer sources (in0, in1, ...) and
// buffer sinks (out0, out1, ...), parses its filtergraph text with
// avfilter_graph_parse_ptr, the sources' and sinks' labels being their
// names, configures the graph, and runs a script of steps:
//
//   s<i>:<n>   add a frame of n generated sample frames to source i
//   c<i>       close source i (av_buffersrc_add_frame(NULL))
//   r<j>       read sink j until it has no frame (EAGAIN) or ends (EOF)
//
// then reads every sink, in order, until it ends. The lines of a case:
//
//   G <name>
//   I <i> <fmt> <rate> <layout> <tb num> <tb den> <first pts>
//       a source; the layout in hex; "-" for frames without pts
//   K <j> <formats> <rates> <layouts>
//       a sink's lists, comma-separated, in hex, "-" when unset
//   B <frames>
//       the graph's frame queue limit (avfilter_graph_set_max_buffered_frames,
//       0 for none)
//   T <text>
//       the filtergraph text (hex)
//   C <script>
//   X
//       the port refuses the graph (TODO.md T25c); nothing else follows
//   E parse / M <message>
//       avfilter_graph_parse_ptr refused the text, FFmpeg's first error
//       message (hex)
//   E config
//       avfilter_graph_config failed
//   L <filter> <pad> <dst> <dst pad> <fmt> <rate> <layout> <tb num> <tb den>
//       each filter in graph order, each of its outputs: the link, the
//       layout described (hex)
//   O <j> <frames> <pts> <bytes>
//       a frame out of sink j: its sample frames, pts ("-" when unset),
//       samples in hex, plane after plane
//   W <j>
//       sink j had no frame (EAGAIN)
//   D <j>
//       sink j ended (EOF)
//   F <step>
//       the step (0-based; the final reads are past the script) failed
//   Z
//       the case is done
//
// The samples come from resample_vectors.c's smoothed generator, one per
// source, its state starting at 1 + the source's index.
// See zig/testing/reference/README.md for the build commands.

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavfilter/avfilter.h"
#include "libavfilter/buffersink.h"
#include "libavfilter/buffersrc.h"
#include "libavutil/avstring.h"
#include "libavutil/channel_layout.h"
#include "libavutil/dict.h"
#include "libavutil/frame.h"
#include "libavutil/mem.h"
#include "libavutil/samplefmt.h"

static char first_error[1024];

static void capture_log(void *avcl, int level, const char *fmt, va_list vl)
{
    (void)avcl;
    if (level > AV_LOG_ERROR || first_error[0])
        return;
    vsnprintf(first_error, sizeof(first_error), fmt, vl);
    size_t n = strlen(first_error);
    while (n && first_error[n - 1] == '\n')
        first_error[--n] = 0;
}

struct generator {
    uint64_t state;
    double memory[64];
};

static double next_sample(struct generator *g, int channel)
{
    g->state = g->state * 6364136223846793005ULL + 1442695040888963407ULL;
    double white = (double)(int32_t)(g->state >> 32) / 2147483648.0 * 0.25;
    g->memory[channel] = g->memory[channel] * 0.9 + white * 0.1;
    return g->memory[channel] * 4;
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
#define MAX_IO 4

struct source { enum AVSampleFormat fmt; int rate; const char *layout; int tb_num, tb_den; int64_t first_pts; };
struct sink { const char *fmts, *rates, *layouts; };

struct multi_case {
    const char *name;
    struct source in[MAX_IO];
    int nb_in;
    struct sink out[MAX_IO];
    int nb_out;
    const char *text;
    const char *script;
    unsigned max_buffered;
    int refused;
};

static void print_frame(int j, const AVFrame *frame)
{
    int planar = av_sample_fmt_is_planar(frame->format);
    int channels = frame->ch_layout.nb_channels;
    int bps = av_get_bytes_per_sample(frame->format);
    int planes = planar ? channels : 1;
    size_t plane_bytes = (size_t)frame->nb_samples * bps * (planar ? 1 : channels);

    printf("O %d %d ", j, frame->nb_samples);
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

/* Reads sink j until EAGAIN (0), EOF (1) or an error (-1). */
static int read_sink(AVFilterContext *sink, int j, AVFrame *out)
{
    int ret;
    while ((ret = av_buffersink_get_frame(sink, out)) >= 0) {
        print_frame(j, out);
        av_frame_unref(out);
    }
    if (ret == AVERROR(EAGAIN)) {
        printf("W %d\n", j);
        return 0;
    }
    if (ret == AVERROR_EOF) {
        printf("D %d\n", j);
        return 1;
    }
    return -1;
}

static void run_case(const struct multi_case *c)
{
    AVFilterGraph *graph = avfilter_graph_alloc();
    AVFilterContext *src[MAX_IO], *sink[MAX_IO];
    AVFilterInOut *outputs = NULL, *inputs = NULL;
    AVFrame *frame = av_frame_alloc(), *out = av_frame_alloc();
    struct generator gen[MAX_IO];
    int64_t at[MAX_IO] = { 0 };
    int ended[MAX_IO] = { 0 };
    char text[512];
    int step = 0;

    printf("G %s\n", c->name);
    for (int i = 0; i < c->nb_in; i++) {
        const struct source *s = &c->in[i];
        printf("I %d %s %d ", i, av_get_sample_fmt_name(s->fmt), s->rate);
        hex(s->layout);
        printf(" %d %d ", s->tb_num ? s->tb_num : 1, s->tb_den ? s->tb_den : s->rate);
        if (s->first_pts == NOPTS)
            printf("-\n");
        else
            printf("%lld\n", (long long)s->first_pts);
    }
    for (int j = 0; j < c->nb_out; j++) {
        printf("K %d ", j);
        hex(c->out[j].fmts);
        printf(" ");
        hex(c->out[j].rates);
        printf(" ");
        hex(c->out[j].layouts);
        printf("\n");
    }
    printf("B %u\nT ", c->max_buffered);
    hex(c->text);
    printf("\nC %s\n", c->script);
    if (c->refused) {
        printf("X\n");
        goto done;
    }

    for (int i = 0; i < c->nb_in; i++) {
        const struct source *s = &c->in[i];
        AVDictionary *dict = NULL;
        AVFilterInOut *io = avfilter_inout_alloc();
        snprintf(text, sizeof(text), "in%d", i);
        src[i] = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("abuffer"), text);
        av_dict_set(&dict, "sample_fmt", av_get_sample_fmt_name(s->fmt), 0);
        av_dict_set_int(&dict, "sample_rate", s->rate, 0);
        av_dict_set(&dict, "channel_layout", s->layout, 0);
        snprintf(text, sizeof(text), "%d/%d", s->tb_num ? s->tb_num : 1, s->tb_den ? s->tb_den : s->rate);
        av_dict_set(&dict, "time_base", text, 0);
        avfilter_init_dict(src[i], &dict);
        av_dict_free(&dict);
        io->name = av_asprintf("in%d", i);
        io->filter_ctx = src[i];
        io->next = outputs;
        outputs = io;
        gen[i].state = 1 + i;
        memset(gen[i].memory, 0, sizeof(gen[i].memory));
    }
    for (int j = 0; j < c->nb_out; j++) {
        AVDictionary *dict = NULL;
        AVFilterInOut *io = avfilter_inout_alloc();
        snprintf(text, sizeof(text), "out%d", j);
        sink[j] = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("abuffersink"), text);
        if (c->out[j].fmts)
            av_dict_set(&dict, "sample_formats", c->out[j].fmts, 0);
        if (c->out[j].rates)
            av_dict_set(&dict, "samplerates", c->out[j].rates, 0);
        if (c->out[j].layouts)
            av_dict_set(&dict, "channel_layouts", c->out[j].layouts, 0);
        avfilter_init_dict(sink[j], &dict);
        av_dict_free(&dict);
        io->name = av_asprintf("out%d", j);
        io->filter_ctx = sink[j];
        io->next = inputs;
        inputs = io;
    }
    if (c->max_buffered)
        avfilter_graph_set_max_buffered_frames(graph, AVMEDIA_TYPE_AUDIO, c->max_buffered);
    first_error[0] = 0;
    if (avfilter_graph_parse_ptr(graph, c->text, &inputs, &outputs, NULL) < 0) {
        printf("E parse\nM ");
        hex(first_error);
        printf("\n");
        goto done;
    }
    if (avfilter_graph_config(graph, NULL) < 0) {
        printf("E config\n");
        goto done;
    }
    for (unsigned f = 0; f < graph->nb_filters; f++) {
        AVFilterContext *fc = graph->filters[f];
        for (unsigned p = 0; p < fc->nb_outputs; p++) {
            AVFilterLink *l = fc->outputs[p];
            char desc[256];
            unsigned dst_pad = 0;
            while (l->dst->inputs[dst_pad] != l)
                dst_pad++;
            av_channel_layout_describe(&l->ch_layout, desc, sizeof(desc));
            printf("L %s %u %s %u %s %d ", fc->name, p, l->dst->name, dst_pad,
                   av_get_sample_fmt_name(l->format), l->sample_rate);
            hex(desc);
            printf(" %d %d\n", l->time_base.num, l->time_base.den);
        }
    }

    /* The script. */
    {
        char script[1024];
        char *save = NULL;
        snprintf(script, sizeof(script), "%s", c->script);
        for (char *tok = strtok_r(script, ",", &save); tok; tok = strtok_r(NULL, ",", &save), step++) {
            int i = atoi(tok + 1), ret = 0;
            if (tok[0] == 's') {
                const struct source *s = &c->in[i];
                AVChannelLayout layout = { 0 };
                int n = atoi(strchr(tok, ':') + 1);
                int tb_num = s->tb_num ? s->tb_num : 1, tb_den = s->tb_den ? s->tb_den : s->rate;
                int planar = av_sample_fmt_is_planar(s->fmt), bps = av_get_bytes_per_sample(s->fmt);
                av_channel_layout_from_string(&layout, s->layout);
                frame->format = s->fmt;
                frame->sample_rate = s->rate;
                frame->nb_samples = n;
                av_channel_layout_copy(&frame->ch_layout, &layout);
                av_frame_get_buffer(frame, 0);
                for (int k = 0; k < n; k++)
                    for (int ch = 0; ch < layout.nb_channels; ch++) {
                        uint8_t *p = planar ? frame->extended_data[ch] + (size_t)k * bps
                                            : frame->extended_data[0] + ((size_t)k * layout.nb_channels + ch) * bps;
                        store(p, s->fmt, next_sample(&gen[i], ch));
                    }
                frame->pts = s->first_pts == NOPTS ? AV_NOPTS_VALUE :
                             s->first_pts + av_rescale_q(at[i], (AVRational){ 1, s->rate }, (AVRational){ tb_num, tb_den });
                at[i] += n;
                ret = av_buffersrc_add_frame(src[i], frame);
                av_frame_unref(frame);
                av_channel_layout_uninit(&layout);
            } else if (tok[0] == 'c') {
                ret = av_buffersrc_add_frame(src[i], NULL);
            } else if (tok[0] == 'r') {
                if (!ended[i]) {
                    int r = read_sink(sink[i], i, out);
                    if (r < 0)
                        ret = -1;
                    else
                        ended[i] = r;
                }
            }
            if (ret < 0) {
                printf("F %d\n", step);
                goto done;
            }
        }
    }
    for (int j = 0; j < c->nb_out; j++, step++) {
        while (!ended[j]) {
            int r = read_sink(sink[j], j, out);
            if (r < 0) {
                printf("F %d\n", step);
                goto done;
            }
            if (r == 0)
                break;
            ended[j] = 1;
        }
    }
    printf("Z\n");
done:
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    av_frame_free(&frame);
    av_frame_free(&out);
    avfilter_graph_free(&graph);
}

#define S16_STEREO(pts) { AV_SAMPLE_FMT_S16, 44100, "stereo", 0, 0, pts }
#define FLT_MONO(pts) { AV_SAMPLE_FMT_FLT, 44100, "mono", 0, 0, pts }

static const struct multi_case cases[] = {
    /* asplit. */
    { "asplit", { S16_STEREO(0) }, 1, { { 0 }, { 0 } }, 2, "[in0]asplit[out0][out1]",
      "s0:64,r0,r1,s0:32,r1,r0,c0" },
    { "asplit_three_branches", { S16_STEREO(0) }, 1, { { 0 }, { 0 }, { 0 } }, 3,
      "[in0]asplit=3[a][b][c];[a]volume=0.5[out0];[b]anull[out1];[c]aresample=48000[out2]",
      "s0:300,r0,s0:300,r2,r1,c0" },
    { "asplit_unread_branch", { S16_STEREO(0) }, 1, { { 0 }, { 0 } }, 2, "[in0]asplit[out0][out1]",
      "s0:64,s0:64,s0:64,r0,c0" },
    { "asplit_outputs_text", { FLT_MONO(5) }, 1, { { 0 }, { 0 } }, 2, "[in0] asplit = outputs=2 [out1] [out0]",
      "s0:16,r1,s0:16,c0" },
    { "two_chains", { S16_STEREO(0), FLT_MONO(100) }, 2, { { 0 }, { 0 } }, 2,
      "[in0]volume=0.5[out0];[in1]anull[out1]", "s0:64,s1:32,r1,r0,c1,c0" },
    { "crossed_chains", { S16_STEREO(0), FLT_MONO(0) }, 2, { { 0 }, { 0 } }, 2,
      "[in1]aresample=8000[out0];[in0]volume=2[out1]", "s1:300,s0:64,c0,c1" },
    { "sink_formats_branches", { S16_STEREO(0) }, 1, { { "flt", 0, 0 }, { 0, "8000", "mono" } }, 2,
      "[in0]asplit[out0][out1]", "s0:300,c0" },
    /* Backpressure: the graph's frame queue limit. */
    { "limit_unread_branch", { S16_STEREO(0) }, 1, { { 0 }, { 0 } }, 2, "[in0]asplit[out0][out1]",
      "s0:16,r0,s0:16,r0,s0:16,r0,s0:16,r0,s0:16,r0,c0", 4 },
    { "limit_read_branches", { S16_STEREO(0) }, 1, { { 0 }, { 0 } }, 2, "[in0]asplit[out0][out1]",
      "s0:16,r0,r1,s0:16,r0,r1,s0:16,r0,r1,s0:16,r0,r1,s0:16,r0,r1,c0", 4 },
    { "limit_chain", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]volume=0.5,anull[out0]",
      "s0:16,s0:16,s0:16,r0,c0", 2 },
    /* channelsplit. */
    { "channelsplit", { S16_STEREO(0) }, 1, { { 0 }, { 0 } }, 2, "[in0]channelsplit[out0][out1]", "s0:64,s0:32,c0" },
    { "channelsplit_some", { { AV_SAMPLE_FMT_FLTP, 48000, "5.1", 0, 0, 0 } }, 1, { { 0 }, { 0 } }, 2,
      "[in0]channelsplit=channel_layout=5.1:channels=LFE+FC[out0][out1]", "s0:48,r1,s0:48,c0" },
    { "channelsplit_converted", { { AV_SAMPLE_FMT_S16, 48000, "5.1(side)", 0, 0, 0 } }, 1, { { 0 }, { 0 }, { 0 } }, 3,
      "[in0]channelsplit=5.1:FL+SL+SR[out0][out1][out2]", "s0:48,c0" },
    { "channelsplit_bad", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]channelsplit=channels=FC[out0]", "c0" },
    /* channelmap. */
    { "channelmap_swap", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]channelmap=1|0[out0]", "s0:64,c0" },
    { "channelmap_names", { { AV_SAMPLE_FMT_FLTP, 48000, "5.1", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]channelmap=map=FL-FR|FR-FL|FC-FC:channel_layout=3.0[out0]", "s0:48,c0" },
    { "channelmap_duplicate", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]channelmap=0|0|1[out0]", "s0:32,c0" },
    { "channelmap_index_pairs", { { AV_SAMPLE_FMT_S32P, 8000, "quad", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]channelmap=3-0|2-1:channel_layout=stereo[out0]", "s0:32,c0" },
    { "channelmap_one_name", { { AV_SAMPLE_FMT_DBLP, 8000, "5.1", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]channelmap=FC|LFE[out0]", "s0:32,c0" },
    { "channelmap_layout_only", { { AV_SAMPLE_FMT_U8P, 8000, "stereo", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]channelmap=channel_layout=stereo[out0]", "s0:32,c0" },
    { "channelmap_missing_input", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]channelmap=FC[out0]", "s0:32,c0" },
    { "channelmap_count_mismatch", { S16_STEREO(0) }, 1, { { 0 } }, 1,
      "[in0]channelmap=0|1:channel_layout=mono[out0]", "c0" },
    { "channelmap_twice", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]channelmap=0-0|1-0[out0]", "c0" },
    /* pan. */
    { "pan_downmix", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]pan=mono|c0=0.5*c0+0.5*c1[out0]", "s0:64,c0" },
    { "pan_names_renorm", { { AV_SAMPLE_FMT_FLT, 48000, "5.1", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]pan=stereo|FL<FL+0.5*FC+0.6*BL+0.6*SL|FR<FR+0.5*FC+0.6*BR+0.6*SR[out0]", "s0:48,c0" },
    { "pan_pure_mapping", { { AV_SAMPLE_FMT_S16P, 48000, "5.1", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]pan=stereo|c0=c2|c1=c3[out0]", "s0:48,c0" },
    { "pan_missing_output", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]pan=stereo|c1=c0[out0]", "s0:32,c0" },
    { "pan_negative", { { AV_SAMPLE_FMT_DBL, 8000, "stereo", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]pan=stereo|c0=c0-c1|c1=-0.5*c1+0.25*c0[out0]", "s0:32,c0" },
    { "pan_s32", { { AV_SAMPLE_FMT_S32, 8000, "stereo", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]pan=1c|c0=0.9*c0+0.9*c1[out0]", "s0:32,c0" },
    { "pan_u8_up", { { AV_SAMPLE_FMT_U8, 8000, "mono", 0, 0, 0 } }, 1, { { 0 } }, 1,
      "[in0]pan=stereo|FL=FC|FR=0.5*FC[out0]", "s0:32,c0" },
    { "pan_bad_syntax", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]pan=mono|c0=c0*c1[out0]", "c0" },
    { "pan_mixed_names", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]pan=mono|c0=FL+c1[out0]", "c0" },
    { "pan_no_layout", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]pan[out0]", "c0" },
    /* amix. */
    { "amix", { FLT_MONO(0), FLT_MONO(0) }, 2, { { 0 } }, 1, "[in0][in1]amix[out0]",
      "s0:64,s1:64,r0,s0:64,s1:32,r0,s1:32,r0,c0,c1" },
    { "amix_uneven_arrival", { FLT_MONO(0), FLT_MONO(0) }, 2, { { 0 } }, 1, "[in0][in1]amix[out0]",
      "s1:100,s1:100,s0:30,r0,s0:200,r0,s1:50,c1,r0,s0:40,c0" },
    { "amix_first_ends", { FLT_MONO(0), FLT_MONO(0) }, 2, { { 0 } }, 1, "[in0][in1]amix[out0]",
      "s0:64,s1:64,s1:64,c0,r0,s1:500,r0,c1" },
    { "amix_shortest", { FLT_MONO(0), FLT_MONO(0) }, 2, { { 0 } }, 1, "[in0][in1]amix=duration=shortest[out0]",
      "s0:64,s1:64,s1:64,c0,r0,s1:64,c1" },
    { "amix_first", { FLT_MONO(0), FLT_MONO(0) }, 2, { { 0 } }, 1, "[in0][in1]amix=duration=first[out0]",
      "s0:64,s1:32,s1:64,c1,r0,s0:64,s0:64,c0" },
    { "amix_three_weights", { FLT_MONO(0), FLT_MONO(10), FLT_MONO(0) }, 3, { { 0 } }, 1,
      "[in0][in1][in2]amix=inputs=3:weights=1 2 -0.5:dropout_transition=0.001[out0]",
      "s0:64,s1:64,s2:64,r0,s1:64,s2:64,s0:64,c2,r0,s0:64,s1:64,c0,c1" },
    { "amix_no_normalize", { S16_STEREO(0), S16_STEREO(0) }, 2, { { 0 } }, 1,
      "[in0][in1]amix=normalize=0[out0]", "s0:64,s1:64,c0,c1" },
    { "amix_double", { { AV_SAMPLE_FMT_DBLP, 8000, "stereo", 0, 0, 0 }, { AV_SAMPLE_FMT_DBLP, 8000, "stereo", 0, 0, 0 } }, 2,
      { { 0 } }, 1, "[in0][in1]amix=weights=0.25 0.75[out0]", "s0:40,s1:40,s0:40,c0,s1:40,c1" },
    { "amix_rates", { FLT_MONO(0), { AV_SAMPLE_FMT_FLT, 22050, "mono", 0, 0, 0 } }, 2, { { 0 } }, 1,
      "[in0][in1]amix[out0]", "s0:200,s1:100,r0,s0:200,s1:100,c0,c1" },
    { "amix_nopts", { FLT_MONO(NOPTS), FLT_MONO(NOPTS) }, 2, { { 0 } }, 1, "[in0][in1]amix[out0]",
      "s0:30,s1:30,c0,c1" },
    { "amix_split_back", { FLT_MONO(0) }, 1, { { 0 } }, 1, "[in0]asplit[a][b];[b]volume=0.5[c];[a][c]amix[out0]",
      "s0:64,r0,s0:64,c0" },
    { "amix_one_input", { FLT_MONO(0) }, 1, { { 0 } }, 1, "[in0]amix=inputs=1[out0]", "s0:16,c0" },
    /* Errors. */
    { "unconnected_output", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[in0]asplit[out0]", "c0" },
    { "unknown_label", { S16_STEREO(0) }, 1, { { 0 } }, 1, "[x]anull[out0]", "c0" },
    { "missing_input", { S16_STEREO(0), FLT_MONO(0) }, 2, { { 0 } }, 1, "[in0]anull[out0]", "c0,c1" },
};

int main(void)
{
    av_log_set_level(AV_LOG_QUIET);
    av_log_set_callback(capture_log);
    for (int i = 0; i < (int)(sizeof(cases) / sizeof(*cases)); i++)
        run_case(&cases[i]);
    return 0;
}
