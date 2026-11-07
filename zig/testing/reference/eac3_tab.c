// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a table printer, not part of the port.
//
// Prints zig/codec/eac3_data.zig's tables (T32b) from FFmpeg's
// libavcodec/eac3_data.c, compiled from the pinned reference tree, so the
// float table keeps the reference compiler's rounding of its literals:
//
//   clang -I.references/ffmpeg -I.references/ffmpeg-build zig/testing/reference/eac3_tab.c -o eac3-tab
//   ./eac3-tab   (the body of zig/codec/eac3_data.zig after its header)
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "libavcodec/eac3_data.c" // the pinned reference tree
static const int vq_sizes[8] = { 0, 4, 8, 16, 32, 128, 256, 512 };
int main(void) {
    printf("pub const bits_vs_hebap = [20]u8{");
    for (int i = 0; i < 20; i++) printf("%s%d", i ? ", " : " ", ff_eac3_bits_vs_hebap[i]);
    printf(" };\npub const gaq_remap_1 = [12]i32{");
    for (int i = 0; i < 12; i++) printf("%s%d", i ? ", " : " ", ff_eac3_gaq_remap_1[i]);
    printf(" };\npub const gaq_remap_2_4_a = [9][2]i32{");
    for (int i = 0; i < 9; i++) printf("%s.{ %d, %d }", i ? ", " : " ", ff_eac3_gaq_remap_2_4_a[i][0], ff_eac3_gaq_remap_2_4_a[i][1]);
    printf(" };\npub const gaq_remap_2_4_b = [9][2]i32{");
    for (int i = 0; i < 9; i++) printf("%s.{ %d, %d }", i ? ", " : " ", ff_eac3_gaq_remap_2_4_b[i][0], ff_eac3_gaq_remap_2_4_b[i][1]);
    printf(" };\npub const frm_expstr = [32][6]u8{\n");
    for (int i = 0; i < 32; i++) {
        printf("    .{");
        for (int j = 0; j < 6; j++) printf("%s%d", j ? ", " : " ", ff_eac3_frm_expstr[i][j]);
        printf(" },\n");
    }
    printf("};\n/// The float table's bit patterns, as the reference compiler rounds its literals.\npub const spx_atten_tab_bits = [32][3]u32{\n");
    for (int i = 0; i < 32; i++) {
        uint32_t b[3];
        memcpy(b, ff_eac3_spx_atten_tab[i], 12);
        printf("    .{ 0x%08x, 0x%08x, 0x%08x },\n", b[0], b[1], b[2]);
    }
    printf("};\n");
    for (int h = 1; h < 8; h++) {
        printf("const vq_hebap%d = [%d][6]i16{\n", h, vq_sizes[h]);
        for (int i = 0; i < vq_sizes[h]; i++) {
            printf("    .{");
            for (int j = 0; j < 6; j++) printf("%s%d", j ? ", " : " ", ff_eac3_mantissa_vq[h][i][j]);
            printf(" },\n");
        }
        printf("};\n");
    }
    printf("/// ff_eac3_mantissa_vq, by hebap 1 to 7 (none for 0).\npub const mantissa_vq = [8][]const [6]i16{ &.{}, &vq_hebap1, &vq_hebap2, &vq_hebap3, &vq_hebap4, &vq_hebap5, &vq_hebap6, &vq_hebap7 };\n");
    return 0;
}
