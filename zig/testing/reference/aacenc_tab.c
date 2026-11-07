// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a table printer, not part of the port.
//
// Prints zig/codec/aacenc_tab.zig's tables (T32d) from FFmpeg's
// libavcodec/aactab.c and aacenctab.c, linked from the pinned build, so the
// float tables keep the reference build's values bit for bit:
//
//   clang -O1 -I.references/ffmpeg-install/include -I.references/ffmpeg \
//     -I.references/ffmpeg-build zig/testing/reference/aacenc_tab.c \
//     .references/ffmpeg-install/lib/libavcodec.a \
//     .references/ffmpeg-install/lib/libavutil.a -lm -pthread -o aacenc-tab
//   ./aacenc-tab | zig fmt --stdin > zig/codec/aacenc_tab.zig

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "libavcodec/aactab.h"
#include "libavcodec/aacenctab.h"

static void print_floats(const char *name, const float *v, int n, const char *doc)
{
    printf("\n/// %s\npub const %s = [%d]u32{", doc, name, n);
    for (int i = 0; i < n; i++) {
        uint32_t bits;
        memcpy(&bits, &v[i], 4);
        printf("%s0x%08" PRIx32 ",", i % 8 ? " " : "\n    ", bits);
    }
    printf("\n};\n");
}

static void print_bytes(const char *name, const uint8_t *v, int n)
{
    printf("const %s = [%d]u8{", name, n);
    for (int i = 0; i < n; i++)
        printf("%s%d,", i % 16 ? " " : "\n    ", v[i]);
    printf("\n};\n");
}

int main(void)
{
    static const int vector_sizes[11] = { 81 * 4, 81 * 4, 81 * 4, 81 * 4, 81 * 2, 81 * 2, 64 * 2, 64 * 2, 169 * 2, 169 * 2, 289 * 2 };
    char name[64];

    ff_aac_float_common_init();
    printf("// SPDX-License-Identifier: LGPL-2.1-or-later\n"
           "// Derived from FFmpeg's libavcodec/aactab.c (ff_aac_codebook_vectors,\n"
           "// aac_tableinit's ff_aac_pow34sf_tab) and aacenctab.c (ff_aac_swb_size_1024,\n"
           "// ff_aac_swb_size_128) at the pinned reference revision, printed by\n"
           "// zig/testing/reference/aacenc_tab.c (do not edit by hand: rerun it).\n"
           "// Copyright (c) 2005-2006 Oded Shimon ( ods15 ods15 dyndns org )\n"
           "// Copyright (c) 2006-2007 Maxim Gavrilov ( maxim.gavrilov gmail com )\n"
           "// FFmpeg is free software; you can redistribute it and/or modify it under\n"
           "// the terms of the GNU Lesser General Public License as published by the\n"
           "// Free Software Foundation; either version 2.1 of the License, or (at your\n"
           "// option) any later version.\n"
           "//! The AAC encoder's tables (TODO.md T32d): each spectral codebook's\n"
           "//! dequantized vectors, 2^(3(i - 200)/16) as FFmpeg builds it, and the\n"
           "//! scalefactor band sizes by sampling index. Floats are their bits.\n");

    for (int cb = 0; cb < 11; cb++) {
        snprintf(name, sizeof(name), "codebook_vector%d", cb);
        print_floats(name, ff_aac_codebook_vectors[cb], vector_sizes[cb],
                     "A codebook's dequantized vectors (`ff_aac_codebook_vectors`).");
    }
    printf("\npub const codebook_vectors = [11][]const u32{\n");
    for (int cb = 0; cb < 11; cb++)
        printf("    &codebook_vector%d,\n", cb);
    printf("};\n");

    print_floats("pow34sf_tab", ff_aac_pow34sf_tab, 428, "`ff_aac_pow34sf_tab`.");

    printf("\n");
    for (int i = 0; i < 13; i++) {
        snprintf(name, sizeof(name), "swb_size_1024_%d", i);
        print_bytes(name, ff_aac_swb_size_1024[i], ff_aac_num_swb_1024[i]);
        snprintf(name, sizeof(name), "swb_size_128_%d", i);
        print_bytes(name, ff_aac_swb_size_128[i], ff_aac_num_swb_128[i]);
    }
    printf("\n/// `ff_aac_swb_size_1024`, by sampling index.\npub const swb_size_1024 = [13][]const u8{\n");
    for (int i = 0; i < 13; i++)
        printf("    &swb_size_1024_%d,\n", i);
    printf("};\n\n/// `ff_aac_swb_size_128`, by sampling index.\npub const swb_size_128 = [13][]const u8{\n");
    for (int i = 0; i < 13; i++)
        printf("    &swb_size_128_%d,\n", i);
    printf("};\n");
    return 0;
}
