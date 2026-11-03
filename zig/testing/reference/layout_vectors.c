// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T23b channel layout oracle (zig/testing/vectors/layout.txt)
// from the pinned FFmpeg's libavutil. Every text is printed as lowercase hex
// ("-" when empty), so spaces and escapes survive. The lines:
//
//   C <id> <name> <description>      av_channel_name, av_channel_description
//   S <text> <id>                    av_channel_from_string
//   P <text> E                       av_channel_layout_from_string fails
//   P <text> <order> <channels> <mask> <map> <description>
//                                    it succeeds: the order (U, N or C), the
//                                    channel count, the mask (hex, 0 unless
//                                    native), the map ("-" for unspecified,
//                                    else each index's channel, comma
//                                    separated, with "@<name>" for a custom
//                                    channel's name) and the description
//   D N <mask> <description>         describing a native layout
//   D U <channels> <description>     describing an unspecified one
//   D C <channels> <map> <description>
//                                    describing a custom one, uncanonicalized
//   F <channels> <description>       av_channel_layout_default
//   Q <text> <text> <0|1>            av_channel_layout_compare of two parsed
//                                    layouts
//
// Ids are decimal. Ambisonic layouts and channels are out of scope (TODO.md
// T23b) and not printed. Inputs avoid values past 32 bits, where `long`
// differs between Linux and Windows. See zig/testing/reference/README.md
// for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libavutil/avstring.h"
#include "libavutil/channel_layout.h"
#include "libavutil/mem.h"

static void hex(const char *text)
{
    if (!*text) {
        printf("-");
        return;
    }
    for (const unsigned char *p = (const unsigned char *)text; *p; p++)
        printf("%02x", *p);
}

static void describe(const AVChannelLayout *layout)
{
    char buf[4096];
    if (av_channel_layout_describe(layout, buf, sizeof(buf)) < 0) {
        printf("E");
        return;
    }
    hex(buf);
}

static void print_map(const AVChannelLayout *layout)
{
    if (layout->order == AV_CHANNEL_ORDER_UNSPEC) {
        printf("-");
        return;
    }
    for (int i = 0; i < layout->nb_channels; i++) {
        printf("%s%d", i ? "," : "", av_channel_layout_channel_from_index(layout, i));
        if (layout->order == AV_CHANNEL_ORDER_CUSTOM && layout->u.map[i].name[0]) {
            printf("@");
            hex(layout->u.map[i].name);
        }
    }
}

static char order_letter(enum AVChannelOrder order)
{
    switch (order) {
    case AV_CHANNEL_ORDER_UNSPEC: return 'U';
    case AV_CHANNEL_ORDER_NATIVE: return 'N';
    case AV_CHANNEL_ORDER_CUSTOM: return 'C';
    default: return '?';
    }
}

static void parse(const char *text)
{
    AVChannelLayout layout = {0};
    printf("P ");
    hex(text);
    if (av_channel_layout_from_string(&layout, text) < 0) {
        printf(" E\n");
        return;
    }
    printf(" %c %d %llx ", order_letter(layout.order), layout.nb_channels,
           layout.order == AV_CHANNEL_ORDER_NATIVE ? (unsigned long long)layout.u.mask : 0ULL);
    print_map(&layout);
    printf(" ");
    describe(&layout);
    printf("\n");
    av_channel_layout_uninit(&layout);
}

static void describe_native(uint64_t mask)
{
    AVChannelLayout layout = {0};
    av_channel_layout_from_mask(&layout, mask);
    printf("D N %llx ", (unsigned long long)mask);
    describe(&layout);
    printf("\n");
}

/* A custom map of `n` ids; `names` holds a name or NULL per channel. */
static void describe_custom(int n, const int *ids, const char *const *names)
{
    AVChannelLayout layout = {0};
    if (av_channel_layout_custom_init(&layout, n) < 0)
        exit(1);
    for (int i = 0; i < n; i++) {
        layout.u.map[i].id = ids[i];
        if (names && names[i])
            av_strlcpy(layout.u.map[i].name, names[i], sizeof(layout.u.map[i].name));
    }
    printf("D C %d ", n);
    print_map(&layout);
    printf(" ");
    describe(&layout);
    printf("\n");
    av_channel_layout_uninit(&layout);
}

static void compare(const char *a, const char *b)
{
    AVChannelLayout la = {0}, lb = {0};
    if (av_channel_layout_from_string(&la, a) < 0 || av_channel_layout_from_string(&lb, b) < 0)
        exit(1);
    printf("Q ");
    hex(a);
    printf(" ");
    hex(b);
    printf(" %d\n", av_channel_layout_compare(&la, &lb));
    av_channel_layout_uninit(&la);
    av_channel_layout_uninit(&lb);
}

static const char *const layout_names[] = {
    "mono", "stereo", "2.1", "3.0", "3.0(back)", "4.0", "quad", "quad(side)", "3.1", "5.0", "5.0(side)",
    "4.1", "5.1", "5.1(side)", "6.0", "6.0(front)", "3.1.2", "hexagonal", "6.1", "6.1(back)", "6.1(front)",
    "7.0", "7.0(front)", "7.1", "7.1(wide)", "7.1(wide-side)", "5.1.2", "5.1.2(back)", "octagonal", "cube",
    "5.1.4", "5.1.6", "7.1.2", "7.1.4", "7.1.6", "7.2.3", "9.1.4", "9.1.6", "hexadecagonal", "binaural",
    "downmix", "22.2",
};

static const char *const strings[] = {
    /* names, near misses */
    "", "Stereo", "stereo ", " stereo", "5.1 ", "7.1(top)", "none", "unknown",
    /* masks: decimal, hex, octal, signs, spaces, overflow */
    "3", "0x3", "0X3", "03", "011", "+3", " 3", "3 ", "-3", "0", "0x0", "4", "7", "0x60f", "1551", "0x3f",
    "63", "0x8000000000000000", "0x7fffffffffffffff", "0xffffffffffffffff", "18446744073709551615",
    "18446744073709551616", "0x10000000000000000", "0x", "0x3g", "08", "3.0x", "4294967295",
    /* channel counts */
    "1c", "2c", "3c", "4c", "5c", "6c", "7c", "8c", "9c", "10c", "11c", "12c", "13c", "14c", "15c", "16c",
    "17c", "24c", "25c", "0c", "-1c", "+2c", " 2c", "2c ", "2 c", "2cc", "2C", "0C", "-2C", "64C", "2 channels",
    "2  channels", "2channels", "0 channels", "1 channel", "65535 channels", "2 Channels", "2 channels ",
    /* channel lists */
    "FL+FR", "FR+FL", "FL+FL", "FC", "LFE", "FL+FR+FC+LFE+BL+BR", "FL+FR+FC+LFE+SL+SR", "BIL+BIR", "DL+DR",
    "FL@a+FR@b", "FL@a+FR", "FL@+FR", "FL@abcdefghijklmnopqrstuvwxyz", "FL@abcdefghijklmno", "FL@abcdefghijklmn",
    "UNK", "UNK+UNK", "UNK+FL", "FL+UNK", "UNK@x", "UNSD", "UNSD+FL", "USR63", "USR0", "USR", "USR-1",
    "USR0x10", "USR010", "USR 5", "USR+5", "USR5x", "USR62+USR61", "USR18+USR17", "USR1000", "USR2048",
    "FL + FR", " FL+FR", "FL+FR ", "FL +FR", "'FL'+FR", "F\\L+FR", "FL@'a+b'", "FL@a\\+b", "FL@ a b ",
    "FL@x@y", "FL+", "+FL", "FL++FR", "FL@", "@x", "@", "+", "fl", "FL+fr", "NONE", "FL+NONE",
    "TFL+TFR+TBL+TBR", "SSL+SSR+TTL+TTR", "WL+WR+SDL+SDR+LFE2", "BFC+BFL+BFR+TSL+TSR",
    /* "N channels (list)" */
    "2 channels (FL+FR)", "2 channels (FR+FL)", "3 channels (FL+FR)", "2 channels (FL+FR)x", "2channels(FL+FR)",
    "2 channels(FL+FR)", "2 channels (FL@x+FR)", "1 channels (USR63)", "2 channels ()", "2 channels (",
    "2 channels (FL+FR", "1 channels (FL)", " 2 channels (FL+FR)", "2 channels (FL+FR) ", "0 channels (FL)",
    "2 channels (UNK+UNK)", "3 channels (FL+FR+FC)", "2 channels (FL@a)b)", "x channels (FL)",
};

int main(void)
{
    /* Channel names and descriptions. */
    static const int ids[] = {-2, -1, 0x1ff, 0x200, 0x201, 0x2ff, 0x300, 0x301, 0x3ff, 0x800, 1000000};
    for (int id = 0; id < 70; id++) {
        char name[64], description[64];
        av_channel_name(name, sizeof(name), id);
        av_channel_description(description, sizeof(description), id);
        printf("C %d ", id);
        hex(name);
        printf(" ");
        hex(description);
        printf("\n");
    }
    for (int i = 0; i < (int)(sizeof(ids) / sizeof(ids[0])); i++) {
        char name[64], description[64];
        av_channel_name(name, sizeof(name), ids[i]);
        av_channel_description(description, sizeof(description), ids[i]);
        printf("C %d ", ids[i]);
        hex(name);
        printf(" ");
        hex(description);
        printf("\n");
    }

    /* av_channel_from_string on every name and some near misses. */
    static const char *const channel_strings[] = {
        "FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC", "BC", "SL", "SR", "TC", "TFL", "TFC", "TFR", "TBL",
        "TBC", "TBR", "DL", "DR", "WL", "WR", "SDL", "SDR", "LFE2", "TSL", "TSR", "BFC", "BFL", "BFR", "SSL",
        "SSR", "TTL", "TTR", "BIL", "BIR", "UNK", "UNSD", "NONE", "USR0", "USR63", "USR", "USR-1", "USR0x10",
        "USR010", "USR 5", "USR+5", "USR5x", "USR1000", "fl", "FL ", " FL", "", "F", "FLL", "USR2147483647",
    };
    for (int i = 0; i < (int)(sizeof(channel_strings) / sizeof(channel_strings[0])); i++) {
        printf("S ");
        hex(channel_strings[i]);
        printf(" %d\n", av_channel_from_string(channel_strings[i]));
    }

    /* av_channel_layout_from_string. */
    for (int i = 0; i < (int)(sizeof(layout_names) / sizeof(layout_names[0])); i++)
        parse(layout_names[i]);
    for (int i = 0; i < (int)(sizeof(strings) / sizeof(strings[0])); i++)
        parse(strings[i]);
    {
        /* 64 and 65 named channels (the port keeps up to 64 in a custom map),
         * and 100 unknown ones, which become unspecified. */
        char text[1024] = "";
        for (int i = 0; i < 64; i++)
            strcat(text, i ? "+FR" : "FR");
        parse(text);
        strcat(text, "+FR");
        parse(text);
        text[0] = 0;
        for (int i = 0; i < 100; i++)
            strcat(text, i ? "+UNK" : "UNK");
        parse(text);
        text[0] = 0;
        for (int i = 0; i < 63; i++) {
            char item[16];
            snprintf(item, sizeof(item), "%sUSR%d", i ? "+" : "", i);
            strcat(text, item);
        }
        parse(text);
    }

    /* Describing native masks: each bit, the named ones, and an LCG's. */
    for (int bit = 0; bit < 64; bit++)
        describe_native(1ULL << bit);
    {
        uint64_t x = 1;
        for (int i = 0; i < 200; i++) {
            x = x * 6364136223846793005ULL + 1442695040888963407ULL;
            describe_native(x >> (i % 64));
        }
        describe_native(~0ULL);
    }
    /* Unspecified and custom layouts, as a demuxer may make them. */
    for (int n = 1; n <= 3; n++) {
        AVChannelLayout layout = {.order = AV_CHANNEL_ORDER_UNSPEC, .nb_channels = n};
        printf("D U %d ", n);
        describe(&layout);
        printf("\n");
    }
    {
        static const int stereo[] = {0, 1}, swapped[] = {1, 0}, unknown[] = {0x300, 0x300},
                         mixed[] = {0, 0x300, 1}, usr[] = {63}, unused[] = {0x200, 2}, gap[] = {0, 2, 5},
                         dup[] = {0, 0}, high[] = {61, 62}, big[] = {1000};
        static const char *const named[] = {"left", NULL};
        static const char *const long_name[] = {"abcdefghijklmnopqrstuvwxyz"};
        describe_custom(2, stereo, NULL);
        describe_custom(2, swapped, NULL);
        describe_custom(2, unknown, NULL);
        describe_custom(3, mixed, NULL);
        describe_custom(1, usr, NULL);
        describe_custom(2, unused, NULL);
        describe_custom(3, gap, NULL);
        describe_custom(2, dup, NULL);
        describe_custom(2, high, NULL);
        describe_custom(1, big, NULL);
        describe_custom(2, stereo, named);
        describe_custom(1, stereo, long_name);
    }

    /* Default layouts. */
    for (int n = 0; n <= 30; n++) {
        AVChannelLayout layout = {0};
        av_channel_layout_default(&layout, n);
        printf("F %d ", n);
        describe(&layout);
        printf("\n");
    }

    /* Comparisons. */
    compare("stereo", "FL+FR");
    compare("stereo", "FR+FL");
    compare("stereo", "3");
    compare("stereo", "2C");
    compare("2C", "2 channels");
    compare("2C", "3C");
    compare("FR+FL", "FR+FL");
    compare("FL@a+FR", "stereo");
    compare("FL@a+FR", "FL@b+FR");
    compare("UNK+FL", "UNK+FL");
    compare("UNK+FL", "UNK+FR");
    compare("mono", "FC");
    compare("5.1", "5.1(side)");
    compare("USR63", "USR63");
    compare("2c", "stereo");
    return 0;
}
