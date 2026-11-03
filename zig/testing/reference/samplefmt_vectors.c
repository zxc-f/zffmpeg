// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T20a oracle (zig/testing/vectors/samplefmt.txt) by calling the
// pinned FFmpeg's libavutil: each sample format's properties, then
// av_samples_get_buffer_size and av_samples_fill_arrays for every format over
// a grid of channel counts, sample counts and alignments, plus edge cases at
// the INT_MAX bound. The Zig implementation is written from the format rules,
// not from this program; the vectors only check it.
//
//   clang -I<prefix>/include samplefmt_vectors.c <prefix>/lib/libavutil.a -lm
//
// See zig/testing/reference/README.md for the exact commands.

#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "libavutil/samplefmt.h"

static const enum AVSampleFormat formats[] = {
    AV_SAMPLE_FMT_U8,  AV_SAMPLE_FMT_S16,  AV_SAMPLE_FMT_S32,  AV_SAMPLE_FMT_S64,
    AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_DBL,  AV_SAMPLE_FMT_U8P,  AV_SAMPLE_FMT_S16P,
    AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S64P, AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_DBLP,
};
#define FORMAT_COUNT (int)(sizeof(formats) / sizeof(formats[0]))

static void buffer_case(enum AVSampleFormat fmt, int channels, int samples, int align)
{
    uint8_t *planes[2048] = { 0 };
    int linesize = -1;
    int size = av_samples_get_buffer_size(&linesize, channels, samples, fmt, align);
    printf("B %s %d %d %d ", av_get_sample_fmt_name(fmt), channels, samples, align);
    if (size < 0) {
        printf("E\n");
        return;
    }
    // Plane math: where the last plane starts in a buffer at address 0x1000.
    // fill_arrays writes one pointer per planar channel; skip it ("-") when
    // `planes` could not hold them.
    if (channels > (int)(sizeof(planes) / sizeof(planes[0]))) {
        printf("%d %d -\n", size, linesize);
        return;
    }
    int filled = av_samples_fill_arrays(planes, NULL, (const uint8_t *)0x1000, channels, samples, fmt, align);
    int last = av_sample_fmt_is_planar(fmt) ? channels - 1 : 0;
    printf("%d %d %ld\n", size, linesize, filled < 0 ? -1L : (long)(planes[last] - planes[0]));
}

int main(void)
{
    static const int channel_grid[] = { 1, 2, 3, 6, 8 };
    static const int sample_grid[] = { 1, 7, 31, 32, 33, 1000, 1024, 65536 };
    static const int align_grid[] = { 0, 1, 2, 4, 16, 32, 64 };

    printf("# T20a vectors from the pinned FFmpeg's libavutil (samplefmt_vectors.c); do not edit.\n");
    printf("# F name bytes_per_sample planar packed_form planar_form silence_byte\n");
    printf("# B name channels samples align size linesize last_plane_offset (E: error)\n");
    for (int f = 0; f < FORMAT_COUNT; f++) {
        enum AVSampleFormat fmt = formats[f];
        // One sample of silence; every byte of it is the same fill byte.
        uint8_t silence[8] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
        uint8_t *silence_planes[1] = { silence };
        av_samples_set_silence(silence_planes, 0, 1, 1, fmt);
        printf("F %s %d %d %s %s %d\n", av_get_sample_fmt_name(fmt), av_get_bytes_per_sample(fmt),
               av_sample_fmt_is_planar(fmt), av_get_sample_fmt_name(av_get_packed_sample_fmt(fmt)),
               av_get_sample_fmt_name(av_get_planar_sample_fmt(fmt)), silence[0]);
    }
    for (int f = 0; f < FORMAT_COUNT; f++)
        for (int c = 0; c < (int)(sizeof(channel_grid) / sizeof(channel_grid[0])); c++)
            for (int s = 0; s < (int)(sizeof(sample_grid) / sizeof(sample_grid[0])); s++)
                for (int a = 0; a < (int)(sizeof(align_grid) / sizeof(align_grid[0])); a++)
                    buffer_case(formats[f], channel_grid[c], sample_grid[s], align_grid[a]);

    // Edges: zero counts, and the INT_MAX bound on every path to it.
    for (int f = 0; f < FORMAT_COUNT; f++) {
        enum AVSampleFormat fmt = formats[f];
        buffer_case(fmt, 0, 1024, 1);
        buffer_case(fmt, 2, 0, 1);
        buffer_case(fmt, 1, INT_MAX - 31, 0);
        buffer_case(fmt, 1, INT_MAX - 30, 0);
        buffer_case(fmt, 1, INT_MAX / av_get_bytes_per_sample(fmt) - 1, 1);
        buffer_case(fmt, 1, INT_MAX / av_get_bytes_per_sample(fmt), 1);
        buffer_case(fmt, 2, INT_MAX / av_get_bytes_per_sample(fmt) / 2 - 2, 2);
        buffer_case(fmt, 2, INT_MAX / av_get_bytes_per_sample(fmt) / 2, 2);
        buffer_case(fmt, 2047, 1, 64);
        buffer_case(fmt, INT_MAX / 64, 1, 64);
        buffer_case(fmt, INT_MAX / 64 + 1, 1, 64);
        buffer_case(fmt, 1024, 65536, 32);
        buffer_case(fmt, 8, 1 << 24, 64);
    }
    return 0;
}
