// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a table printer, not part of the port.
//
// Prints zig/codec/aacenc_pce.zig (T32d) from FFmpeg's libavcodec/aacenc.c
// aac_pce_configs, copied below verbatim by its generator, with the
// layouts' masks resolved by libavutil's macros:
//
//   clang -I.references/ffmpeg-install/include zig/testing/reference/aacenc_pce.c -o aacenc-pce
//   ./aacenc-pce > zig/codec/aacenc_pce.zig

#include <inttypes.h>
#include <stdio.h>
#include "libavutil/channel_layout.h"

enum { TYPE_SCE, TYPE_CPE, TYPE_CCE, TYPE_LFE, TYPE_DSE, TYPE_PCE, TYPE_FIL, TYPE_END };

typedef struct AACPCEInfo {
    AVChannelLayout layout;
    uint8_t num_ele[4];
    uint8_t pairing[3][8];
    uint8_t index[4][8];
    uint8_t height[3][8];
    uint8_t config_map[16];
    uint8_t reorder_map[16];
} AACPCEInfo;

static const AACPCEInfo aac_pce_configs[] = {
    {
        .layout = AV_CHANNEL_LAYOUT_MONO,
        .num_ele = { 1, 0, 0, 0 },
        .pairing = { { 0 }, },
        .index = { { 0 }, },
        .config_map = { 1, TYPE_SCE, },
        .reorder_map = { 0 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_STEREO,
        .num_ele = { 1, 0, 0, 0 },
        .pairing = { { 1 }, },
        .index = { { 0 }, },
        .config_map = { 1, TYPE_CPE, },
        .reorder_map = { 0, 1 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_2POINT1,
        .num_ele = { 1, 0, 0, 1 },
        .pairing = { { 1 }, },
        .index = { { 0 },{ 0 },{ 0 },{ 0 } },
        .config_map = { 2, TYPE_CPE, TYPE_LFE },
        .reorder_map = { 0, 1, 2 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_2_1,
        .num_ele = { 1, 0, 1, 0 },
        .pairing = { { 1 },{ 0 },{ 0 } },
        .index = { { 0 },{ 0 },{ 0 }, },
        .config_map = { 2, TYPE_CPE, TYPE_SCE },
        .reorder_map = { 0, 1, 2 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_SURROUND,
        .num_ele = { 2, 0, 0, 0 },
        .pairing = { { 0, 1 }, },
        .index = { { 0, 0 }, },
        .config_map = { 2, TYPE_SCE, TYPE_CPE },
        .reorder_map = { 2, 0, 1 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_3POINT1,
        .num_ele = { 2, 0, 0, 1 },
        .pairing = { { 0, 1 }, },
        .index = { { 0, 0 }, { 0 }, { 0 }, { 0 }, },
        .config_map = { 3, TYPE_SCE, TYPE_CPE, TYPE_LFE },
        .reorder_map = { 2, 0, 1, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_4POINT0,
        .num_ele = { 2, 0, 1, 0 },
        .pairing = { { 0, 1 }, { 0 }, { 0 }, },
        .index = { { 0, 0 }, { 0 }, { 1 } },
        .config_map = { 3, TYPE_SCE, TYPE_CPE, TYPE_SCE },
        .reorder_map = { 2, 0, 1, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_4POINT1,
        .num_ele = { 2, 0, 1, 1 },
        .pairing = { { 0, 1 }, { 0 }, { 0 }, },
        .index = { { 0, 0 }, { 0 }, { 1 }, { 0 } },
        .config_map = { 4, TYPE_SCE, TYPE_CPE, TYPE_SCE, TYPE_LFE },
        .reorder_map = { 2, 0, 1, 4, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_2_2,
        .num_ele = { 1, 0, 1, 0 },
        .pairing = { { 1 }, { 0 }, { 1 }, },
        .index = { { 0 }, { 0 }, { 1 } },
        .config_map = { 2, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 0, 1, 2, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_QUAD,
        .num_ele = { 1, 0, 1, 0 },
        .pairing = { { 1 }, { 0 }, { 1 }, },
        .index = { { 0 }, { 0 }, { 1 } },
        .config_map = { 2, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 0, 1, 2, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_5POINT0,
        .num_ele = { 2, 0, 1, 0 },
        .pairing = { { 0, 1 }, { 0 }, { 1 } },
        .index = { { 0, 0 }, { 0 }, { 1 } },
        .config_map = { 3, TYPE_SCE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 3, 4 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_5POINT1,
        .num_ele = { 2, 0, 1, 1 },
        .pairing = { { 0, 1 }, { 0 }, { 1 }, },
        .index = { { 0, 0 }, { 0 }, { 1 }, { 0 } },
        .config_map = { 4, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE },
        .reorder_map = { 2, 0, 1, 4, 5, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_5POINT0_BACK,
        .num_ele = { 2, 0, 1, 0 },
        .pairing = { { 0, 1 }, { 0 }, { 1 } },
        .index = { { 0, 0 }, { 0 }, { 1 } },
        .config_map = { 3, TYPE_SCE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 3, 4 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_5POINT1_BACK,
        .num_ele = { 2, 0, 1, 1 },
        .pairing = { { 0, 1 }, { 0 }, { 1 }, },
        .index = { { 0, 0 }, { 0 }, { 1 }, { 0 } },
        .config_map = { 4, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE },
        .reorder_map = { 2, 0, 1, 4, 5, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_6POINT0,
        .num_ele = { 2, 0, 2, 0 },
        .pairing = { { 0, 1 }, { 0 }, { 1, 0 } },
        .index = { { 0, 0 }, { 0 }, { 1, 1 } },
        .config_map = { 4, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_SCE },
        .reorder_map = { 2, 0, 1, 4, 5, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_6POINT0_FRONT,
        .num_ele = { 2, 0, 1, 0 },
        .pairing = { { 1, 1 }, { 0 }, { 1 } },
        .index = { { 0, 1 }, { 0 }, { 2 }, },
        .config_map = { 3, TYPE_CPE, TYPE_CPE, TYPE_CPE, },
        .reorder_map = { 2, 3, 0, 1, 4, 5 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_HEXAGONAL,
        .num_ele = { 2, 0, 2, 0 },
        .pairing = { { 0, 1 }, { 0 }, { 1, 0 } },
        .index = { { 0, 0 }, { 0 }, { 1, 1 } },
        .config_map = { 4, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_SCE },
        .reorder_map = { 2, 0, 1, 3, 4, 5 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_6POINT1,
        .num_ele = { 2, 0, 2, 1 },
        .pairing = { { 0, 1 }, { 0 }, { 1, 0 }, },
        .index = { { 0, 0 }, { 0 }, { 1, 1 }, { 0 } },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_SCE, TYPE_LFE },
        .reorder_map = { 2, 0, 1, 5, 6, 4, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_6POINT1_BACK,
        .num_ele = { 2, 0, 2, 1 },
        .pairing = { { 0, 1 },{ 0 },{ 1, 0 }, },
        .index = { { 0, 0 },{ 0 },{ 1, 1 },{ 0 } },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_SCE, TYPE_LFE },
        .reorder_map = { 2, 0, 1, 4, 5, 6, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_6POINT1_FRONT,
        .num_ele = { 2, 0, 1, 1 },
        .pairing = { { 1, 1 }, { 0 }, { 1 }, },
        .index = { { 0, 1 }, { 0 }, { 2 }, { 0 }, },
        .config_map = { 4, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE, },
        .reorder_map = { 3, 4, 0, 1, 5, 6, 2 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_7POINT0,
        .num_ele = { 2, 0, 2, 0 },
        .pairing = { { 0, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0 }, { 0 }, { 2, 1 }, },
        .config_map = { 4, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 3, 4, 5, 6 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_7POINT0_FRONT,
        .num_ele = { 3, 0, 1, 0 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1 }, },
        .index = { { 0, 0, 1 }, { 0 }, { 2 }, },
        .config_map = { 4, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 3, 4, 0, 1, 5, 6 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_7POINT1,
        .num_ele = { 2, 0, 2, 1 },
        .pairing = { { 0, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0 }, { 0 }, { 2, 1 }, { 0 } },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE },
        .reorder_map = { 2, 0, 1, 4, 5, 6, 7, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_7POINT1_WIDE,
        .num_ele = { 3, 0, 1, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1 }, },
        .index = { { 0, 0, 1 }, { 0 }, { 2 }, { 0 }, },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE },
        .reorder_map = { 2, 4, 5, 0, 1, 6, 7, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_7POINT1_WIDE_BACK,
        .num_ele = { 3, 0, 1, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1 } },
        .index = { { 0, 0, 1 }, { 0 }, { 2 }, { 0 } },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE },
        .reorder_map = { 2, 6, 7, 0, 1, 4, 5, 3 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_OCTAGONAL,
        .num_ele = { 2, 0, 3, 0 },
        .pairing = { { 0, 1 }, { 0 }, { 1, 1, 0 }, },
        .index = { { 0, 0 }, { 0 }, { 1, 2, 1 }, },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_SCE },
        .reorder_map = { 2, 0, 1, 6, 7, 3, 4, 5 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_5POINT1POINT2,
        .num_ele = { 3, 0, 1, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1 }, },
        .index = { { 0, 0, 2 }, { 0 }, { 1 }, { 0 }, },
        .height = { { 0, 0, 1 }, { 0 }, { 0 } },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 3, 6, 7 },
    },
    {
        // ITU-R BS.2051-3 Sound System C
        .layout = AV_CHANNEL_LAYOUT_5POINT1POINT2_BACK,
        .num_ele = { 3, 0, 1, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1 }, },
        .index = { { 0, 0, 2 }, { 0 }, { 1 }, { 0 }, },
        .height = { { 0, 0, 1 }, { 0 }, { 0 } },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 3, 6, 7 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_5POINT1POINT4,
        .num_ele = { 3, 0, 2, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0, 2 }, { 0 }, { 1, 3 }, { 0 }, },
        .height = { { 0, 0, 1 }, { 0 }, { 0, 1 } },
        .config_map = { 6, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 3, 6, 7, 8, 9 },
    },
        // ITU-R BS.2051-3 Sound System D
    {
        .layout = {
            .nb_channels = 10,
            .order       = AV_CHANNEL_ORDER_NATIVE,
            .u.mask      = AV_CH_LAYOUT_5POINT1POINT2_BACK | AV_CH_TOP_BACK_LEFT | AV_CH_TOP_BACK_RIGHT,
        },
        .num_ele = { 3, 0, 2, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0, 2 }, { 0 }, { 1, 3 }, { 0 }, },
        .height = { { 0, 0, 1 }, { 0 }, { 0, 1 } },
        .config_map = { 6, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 3, 6, 7, 8, 9 },
    },
    {
        // ITU-R BS.2051-3 Sound System E
        .layout = {
            .nb_channels = 11,
            .order       = AV_CHANNEL_ORDER_NATIVE,
            .u.mask      = AV_CH_LAYOUT_5POINT1POINT4 | AV_CH_BOTTOM_FRONT_CENTER,
        },
        .num_ele = { 4, 0, 2, 1 },
        .pairing = { { 0, 1, 1, 0 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0, 2, 1 }, { 0 }, { 1, 3 }, { 0 }, },
        .height = { { 0, 0, 1, 2 }, { 0 }, { 0, 1 } },
        .config_map = { 7, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE, TYPE_CPE, TYPE_SCE },
        .reorder_map = { 2, 0, 1, 4, 5, 3, 6, 7, 8, 9, 10 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_5POINT1POINT6,
        .num_ele = { 4, 1, 2, 1 },
        .pairing = { { 0, 1, 0, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0, 1, 2 }, { 2 }, { 1, 3 }, { 0 }, },
        .height = { { 0, 0, 1, 1 }, { 1 }, { 0, 1 } },
        .config_map = { 8, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_SCE, TYPE_CPE, TYPE_SCE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 3, 8, 7, 9, 6, 10, 11 },
    },
    {
        .layout = {
            .nb_channels = 12,
            .order       = AV_CHANNEL_ORDER_NATIVE,
            .u.mask      = AV_CH_LAYOUT_5POINT1POINT2_BACK | AV_CH_TOP_BACK_LEFT | AV_CH_TOP_BACK_RIGHT |
                           AV_CH_TOP_CENTER | AV_CH_TOP_FRONT_CENTER,
        },
        .num_ele = { 4, 1, 2, 1 },
        .pairing = { { 0, 1, 0, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0, 1, 2 }, { 2 }, { 1, 3 }, { 0 }, },
        .height = { { 0, 0, 1, 1 }, { 1 }, { 0, 1 } },
        .config_map = { 8, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_SCE, TYPE_CPE, TYPE_SCE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 3, 8, 7, 9, 6, 10, 11 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_7POINT1POINT2,
        .num_ele = { 3, 0, 2, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0, 3 }, { 0 }, { 2, 1 }, { 0 } },
        .height = { { 0, 0, 1 }, { 0 }, { 0, 0 } },
        .config_map = { 6, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 6, 7, 3, 8, 9 },
    },
    {
        // ITU-R BS.2051-3 Sound System F
        .layout = AV_CHANNEL_LAYOUT_7POINT2POINT3,
        .num_ele = { 3, 0, 3, 2 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1, 1, 0 }, },
        .index = { { 0, 0, 3 }, { 0 }, { 2, 1, 1 }, { 0, 1 } },
        .height = { { 0, 0, 1 }, { 0 }, { 0, 0, 1 } },
        .config_map = { 8, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_LFE, TYPE_CPE, TYPE_SCE },
        .reorder_map = { 2, 0, 1, 4, 5, 6, 7, 3, 11, 8, 9, 10 },
    },
    {
        // ITU-R BS.2051-3 Sound System J
        .layout = AV_CHANNEL_LAYOUT_7POINT1POINT4,
        .num_ele = { 3, 0, 3, 1 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1, 1, 1 }, },
        .index = { { 0, 0, 3 }, { 0 }, { 2, 1, 4 }, { 0 } },
        .height = { { 0, 0, 1 }, { 0 }, { 0, 0, 1 } },
        .config_map = { 7, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 6, 7, 3, 8, 9, 10, 11 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_7POINT1POINT6,
        .num_ele = { 4, 1, 3, 1 },
        .pairing = { { 0, 1, 0, 1 }, { 0 }, { 1, 1, 1 }, },
        .index = { { 0, 0, 1, 3 }, { 2 }, { 2, 1, 4 }, { 0 } },
        .height = { { 0, 0, 1, 1 }, { 1 }, { 0, 0, 1 } },
        .config_map = { 9, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_SCE, TYPE_CPE, TYPE_SCE, TYPE_CPE },
        .reorder_map = { 2, 0, 1, 4, 5, 6, 7, 3, 10, 9, 11, 8, 12, 13 },
    },
    {
        // ITU-R BS.2051-3 Sound System G
        .layout = AV_CHANNEL_LAYOUT_9POINT1POINT4,
        .num_ele = { 4, 0, 3, 1 },
        .pairing = { { 0, 1, 1, 1 }, { 0 }, { 1, 1, 1 }, },
        .index = { { 0, 0, 1, 4 }, { 0 }, { 2, 3, 5 }, { 0 } },
        .height = { { 0, 0, 0, 1 }, { 0 }, { 0, 0, 1 } },
        .config_map = { 8, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 6, 7, 0, 1, 8, 9, 4, 5, 3, 10, 11, 12, 13 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_9POINT1POINT6,
        .num_ele = { 4, 1, 3, 1 },
        .pairing = { { 0, 1, 1, 1 }, { 1 }, { 1, 1, 1 }, },
        .index = { { 0, 0, 1, 4 }, { 5 }, { 2, 3, 6 }, { 0 } },
        .height = { { 0, 0, 0, 1 }, { 1 }, { 0, 0, 1 } },
        .config_map = { 9, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_LFE, TYPE_CPE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 6, 7, 0, 1, 8, 9, 4, 5, 3, 10, 11, 14, 15, 12, 13 },
    },
    {
        .layout = AV_CHANNEL_LAYOUT_AMBISONIC_FIRST_ORDER,
        .num_ele = { 1, 0, 1, 0 },
        .pairing = { { 1 }, { 0 }, { 1 }, },
        .index = { { 0 }, { 0 }, { 1 } },
        .config_map = { 2, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 0, 1, 2, 3 },
    },
    {
        .layout = { .order = AV_CHANNEL_ORDER_AMBISONIC, .nb_channels = 9 },
        .num_ele = { 3, 0, 2, 0 },
        .pairing = { { 0, 1, 1 }, { 0 }, { 1, 1 }, },
        .index = { { 0, 0, 1 }, { 0 }, { 2, 3 }, },
        .config_map = { 5, TYPE_SCE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 2, 5, 6, 0, 1, 7, 8, 3, 4 },
    },
    {
        .layout = { .order = AV_CHANNEL_ORDER_AMBISONIC, .nb_channels = 16 },
        .num_ele = { 4, 0, 4, 0 },
        .pairing = { { 1, 1, 1, 1 }, { 0 }, { 1, 1, 1, 1 }, },
        .index = { { 0, 1, 2, 3 }, { 0 }, { 4, 5, 6, 7 }, },
        .config_map = { 8, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE, TYPE_CPE },
        .reorder_map = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    },
};

// A field (`.name = .{ ... },`) or, with a null name, an array element.
static void row(const char *name, const uint8_t *v, int n)
{
    if (name)
        printf("        .%s = .{", name);
    else
        printf("            .{");
    for (int i = 0; i < n; i++)
        printf("%s%d", i ? ", " : " ", v[i]);
    printf(" },\n");
}

int main(void)
{
    printf("// SPDX-License-Identifier: LGPL-2.1-or-later\n"
           "// Derived from FFmpeg's libavcodec/aacenc.c (aac_pce_configs) at the pinned\n"
           "// reference revision, printed by zig/testing/reference/aacenc_pce.c (do not\n"
           "// edit by hand: rerun it).\n"
           "// Copyright (C) 2008 Konstantin Shishkov\n"
           "// FFmpeg is free software; you can redistribute it and/or modify it under\n"
           "// the terms of the GNU Lesser General Public License as published by the\n"
           "// Free Software Foundation; either version 2.1 of the License, or (at your\n"
           "// option) any later version.\n"
           "//! The layouts FFmpeg's AAC encoder codes with a program configuration\n"
           "//! element (TODO.md T32d): each one's element counts, pairing, indices,\n"
           "//! heights, elements and channel order. Ambisonic layouts are left out.\n\n"
           "pub const Config = struct {\n    mask: u64,\n    num_ele: [4]u8,\n    pairing: [3][8]u8,\n"
           "    index: [4][8]u8,\n    height: [3][8]u8,\n    config_map: [16]u8,\n    reorder_map: [16]u8,\n};\n\n"
           "/// aac_pce_configs, the native-order layouts.\npub const configs = [_]Config{\n");
    for (size_t k = 0; k < sizeof(aac_pce_configs) / sizeof(aac_pce_configs[0]); k++) {
        const AACPCEInfo *p = &aac_pce_configs[k];
        if (p->layout.order != AV_CHANNEL_ORDER_NATIVE)
            continue;
        printf("    .{\n        .mask = 0x%" PRIx64 ",\n", p->layout.u.mask);
        row("num_ele", p->num_ele, 4);
        printf("        .pairing = .{\n");
        for (int a = 0; a < 3; a++) row(NULL, p->pairing[a], 8);
        printf("        },\n");
        printf("        .index = .{\n");
        for (int a = 0; a < 4; a++) row(NULL, p->index[a], 8);
        printf("        },\n");
        printf("        .height = .{\n");
        for (int a = 0; a < 3; a++) row(NULL, p->height[a], 8);
        printf("        },\n");
        row("config_map", p->config_map, 16);
        row("reorder_map", p->reorder_map, 16);
        printf("    },\n");
    }
    printf("};\n");
    return 0;
}
