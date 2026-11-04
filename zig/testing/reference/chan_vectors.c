// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T23b `chan` oracle (zig/testing/vectors/chan.txt) from the
// pinned FFmpeg's libavformat: what ff_mov_read_chan, the reader AIFF's
// `CHAN` and CAF's `chan` share, makes of a chunk body, and what
// ff_mov_write_chan, the AIFF muxer's writer, emits. Both are internal
// functions of the static library, declared here. The lines:
//
//   R <before> <size> <body> E
//   R <before> <size> <body> <order> <channels> <mask> <map> <consumed>
//       ff_mov_read_chan on a stream of <before> channels, unspecified,
//       given a declared chunk size of <size> and the bytes <body> (hex; it
//       may be shorter than <size>, to reach the end of the input): E when
//       it fails, else the layout after it (order U, N or C, the channel
//       count, the mask in hex, 0 unless native, and the map: "-" when
//       unspecified, else each index's channel id, comma separated) and the
//       bytes it consumed.
//   W <mask> <bytes>
//       ff_mov_write_chan for a native layout's mask (hex): the 12 bytes.
//
// See zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavutil/channel_layout.h"
#include "libavutil/mem.h"

int ff_mov_read_chan(AVFormatContext *s, AVIOContext *pb, AVStream *st, int64_t size);
void ff_mov_write_chan(AVIOContext *pb, int64_t channel_layout);

struct Source {
    const uint8_t *data;
    int len;
    int pos;
};

static int read_source(void *opaque, uint8_t *buf, int size)
{
    struct Source *src = opaque;
    int left = src->len - src->pos;
    if (left <= 0)
        return AVERROR_EOF;
    if (size > left)
        size = left;
    memcpy(buf, src->data + src->pos, size);
    src->pos += size;
    return size;
}

static void print_layout(const AVChannelLayout *layout)
{
    char order = layout->order == AV_CHANNEL_ORDER_NATIVE ? 'N' : layout->order == AV_CHANNEL_ORDER_CUSTOM ? 'C' : 'U';
    if (layout->order == AV_CHANNEL_ORDER_AMBISONIC)
        order = 'A';
    printf("%c %d %llx ", order, layout->nb_channels,
           layout->order == AV_CHANNEL_ORDER_NATIVE ? (unsigned long long)layout->u.mask : 0ULL);
    if (layout->order == AV_CHANNEL_ORDER_UNSPEC) {
        printf("-");
        return;
    }
    for (int i = 0; i < layout->nb_channels; i++)
        printf("%s%d", i ? "," : "", av_channel_layout_channel_from_index(layout, i));
}

static void read_case(int before, int64_t size, const uint8_t *body, int len)
{
    AVFormatContext *s = avformat_alloc_context();
    AVStream *st = avformat_new_stream(s, NULL);
    struct Source src = { body, len, 0 };
    uint8_t *buffer = av_malloc(4096);
    AVIOContext *pb = avio_alloc_context(buffer, 4096, 0, &src, read_source, NULL, NULL);
    st->codecpar->ch_layout.nb_channels = before;

    printf("R %d %lld ", before, (long long)size);
    if (len == 0)
        printf("-");
    for (int i = 0; i < len; i++)
        printf("%02x", body[i]);
    if (ff_mov_read_chan(s, pb, st, size) < 0) {
        printf(" E\n");
    } else {
        printf(" ");
        print_layout(&st->codecpar->ch_layout);
        printf(" %lld\n", (long long)avio_tell(pb));
    }
    av_freep(&pb->buffer);
    avio_context_free(&pb);
    avformat_free_context(s);
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24;
    p[1] = v >> 16;
    p[2] = v >> 8;
    p[3] = v;
}

/* A body: the layout tag, the bitmap, the description count, then one
 * 20-byte description per label (the label, flags and coordinates zero). */
static int body(uint8_t *out, uint32_t tag, uint32_t bitmap, uint32_t count, const uint32_t *labels, int nb_labels)
{
    put32(out, tag);
    put32(out + 4, bitmap);
    put32(out + 8, count);
    memset(out + 12, 0, 20 * nb_labels);
    for (int i = 0; i < nb_labels; i++)
        put32(out + 12 + 20 * i, labels[i]);
    return 12 + 20 * nb_labels;
}

static void tag_case(int before, uint32_t tag)
{
    uint8_t b[12];
    int len = body(b, tag, 0, 0, NULL, 0);
    read_case(before, len, b, len);
}

/* Whether the table has `tag`: it gives a layout on a stream of no count. */
static int known_tag(uint32_t tag)
{
    AVFormatContext *s = avformat_alloc_context();
    AVStream *st = avformat_new_stream(s, NULL);
    uint8_t b[12];
    int len = body(b, tag, 0, 0, NULL, 0);
    struct Source src = { b, len, 0 };
    uint8_t *buffer = av_malloc(4096);
    AVIOContext *pb = avio_alloc_context(buffer, 4096, 0, &src, read_source, NULL, NULL);
    int known = ff_mov_read_chan(s, pb, st, len) >= 0 && st->codecpar->ch_layout.order != AV_CHANNEL_ORDER_UNSPEC;
    av_freep(&pb->buffer);
    avio_context_free(&pb);
    avformat_free_context(s);
    return known;
}

static void write_case(uint64_t mask)
{
    AVIOContext *pb;
    uint8_t *bytes;
    int len;
    if (avio_open_dyn_buf(&pb) < 0)
        return;
    ff_mov_write_chan(pb, (int64_t)mask);
    len = avio_close_dyn_buf(pb, &bytes);
    printf("W %llx ", (unsigned long long)mask);
    for (int i = 0; i < len; i++)
        printf("%02x", bytes[i]);
    printf("\n");
    av_free(bytes);
}

int main(void)
{
    uint8_t b[4096];
    int len;

    av_log_set_level(AV_LOG_QUIET);

    /* Every layout tag number around the table's (100 to 182) with every
     * count up to 24, on a stream whose count is not yet known: a tag in the
     * table gives its layout, any other the count alone. The table's tags
     * also on a stream of the same count and of one more. */
    for (uint32_t number = 98; number <= 185; number++) {
        for (uint32_t count = 1; count <= 24; count++) {
            uint32_t tag = number << 16 | count;
            tag_case(0, tag);
            if (known_tag(tag)) {
                tag_case(count, tag);
                tag_case(count + 1, tag);
            }
        }
    }
    /* Tags with no count, and the special ones. */
    tag_case(0, 0);
    tag_case(2, 147 << 16);
    tag_case(2, 0xFFFF0000);
    tag_case(2, 0xFFFF0002);

    /* Bitmaps, on a stream of no count, the bitmap's count and another. */
    {
        const uint32_t bitmaps[] = { 0, 1, 2, 3, 4, 7, 0xF, 0x3F, 0x60F, 0x107, 0x30, 0x3FFFF, 0x20000,
                                     0x40000, 0x40003, 0x80000000, 0x80000003, 0xFFFFFFFF };
        for (int i = 0; i < (int)(sizeof(bitmaps) / sizeof(*bitmaps)); i++) {
            int bits = av_popcount(bitmaps[i]);
            int befores[] = { 0, bits, bits + 1 };
            for (int j = 0; j < 3; j++) {
                len = body(b, 1 << 16, bitmaps[i], 0, NULL, 0);
                read_case(befores[j], len, b, len);
            }
        }
    }

    /* Descriptions: label lists on streams of fewer, as many and more
     * channels, with as many descriptions as labels. */
    {
        static const uint32_t lists[][8] = {
            { 1, 2 }, { 2, 1 }, { 3 }, { 1, 2, 3 }, { 3, 2, 1 }, { 1, 1 }, { 0, 1 }, { 1, 0 }, { 0 },
            { 100 }, { 100, 100 }, { 1, 100 }, { 19 }, { 18 }, { 17, 18 }, { 35, 36 }, { 37 }, { 38, 39 },
            { 40 }, { 34 }, { 33 }, { 0x10000 }, { 0xFFFFFFFF }, { 1, 2, 3, 4, 5, 6 }, { 1, 2, 4, 3, 5, 6 },
            { 1, 2, 3, 4, 5, 6, 7, 8 }, { 10, 11, 1, 2 }, { 12, 13, 14, 15 }, { 16, 17, 18, 38 },
        };
        static const int sizes[] = { 2, 2, 1, 3, 3, 2, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 1, 2, 1, 1, 1, 1, 1, 6, 6,
                                     8, 4, 4, 4 };
        for (int i = 0; i < (int)(sizeof(sizes) / sizeof(*sizes)); i++) {
            int n = sizes[i];
            int befores[] = { 0, n - 1, n, n + 1 };
            for (int j = 0; j < 4; j++) {
                if (befores[j] < 0)
                    continue;
                len = body(b, 0, 0, n, lists[i], n);
                read_case(befores[j], len, b, len);
            }
        }
    }

    /* Description counts against the stream's: none, fewer, more (capped:
     * the rest is skipped), and a body too short for them, which FFmpeg
     * leaves after its first 12 bytes. */
    {
        const uint32_t labels[] = { 1, 2, 3, 4 };
        len = body(b, 0, 0, 0, NULL, 0);
        read_case(2, len, b, len);
        len = body(b, 0, 0, 1, labels, 1);
        read_case(2, len, b, len);
        len = body(b, 0, 0, 4, labels, 4);
        read_case(2, len, b, len);
        len = body(b, 0, 0, 3, labels, 2);
        read_case(2, len, b, len);
        read_case(2, len + 8, b, len);
        len = body(b, 0, 0, 2, labels, 2);
        read_case(2, len - 1, b, len);
    }

    /* Bodies longer than their fields, and shorter than 12 bytes. */
    {
        len = body(b, 101 << 16 | 2, 0, 0, NULL, 0);
        memset(b + len, 0xAB, 9);
        read_case(2, len + 9, b, len + 9);
        len = body(b, 1 << 16, 3, 0, NULL, 0);
        memset(b + len, 0, 20);
        read_case(2, len + 20, b, len + 20);
        len = body(b, 101 << 16 | 2, 0, 0, NULL, 0);
        read_case(2, 11, b, 11);
        read_case(2, 0, b, 0);
    }

    /* The end of the input inside the descriptions. */
    {
        const uint32_t labels[] = { 1, 2, 3 };
        len = body(b, 0, 0, 3, labels, 3);
        read_case(3, len, b, 12);
        read_case(3, len, b, 32);
        read_case(3, len, b, 6);
    }

    /* Writing: every named layout, then other masks. */
    {
        const AVChannelLayout *layout;
        void *opaque = NULL;
        const uint64_t others[] = { 0x1, 0x2, 0x3, 0x7, 0x103, 0x3FFFF, 0x40000, 0x100000003ULL,
                                    0x8000000000000000ULL, 0x60000000ULL, 0x60F | 0x60000000ULL };
        while ((layout = av_channel_layout_standard(&opaque)))
            write_case(layout->u.mask);
        for (int i = 0; i < (int)(sizeof(others) / sizeof(*others)); i++)
            write_case(others[i]);
    }
    return 0;
}
