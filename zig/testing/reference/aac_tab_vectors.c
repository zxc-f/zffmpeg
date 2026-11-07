// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T30b AAC table oracle (zig/testing/vectors/aac_tab.txt): the
// pinned FFmpeg's tables of the float AAC-LC decoder, after the static
// initializers its decoder runs (ff_aac_float_common_init, ff_cbrt_tableinit
// and ff_aacdec_common_init_once). One line per table or table row:
//
//   <name> [<index>] <values...>
//                    integers in decimal; floats as the hexadecimal bits of
//                    their IEEE single (cbrt_tab already holds such bits)
//   <name> [<index>] <entries> <sym>,<len>...
//                    a VLC table: its entry count, then every VLCElem
//
// zig/codec/aac_tab.zig renders the same text from its tables. See
// zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Not installed: the declarations of libavcodec/aactab.h, aac/aacdec_tab.h,
// kbdwin.h, sinewin.h, cbrt_data.h and vlc.h this program reads. The static
// library defines the symbols (hidden visibility only limits a shared
// library's exports).
typedef struct VLCElem {
    int16_t sym, len;
} VLCElem;

extern const uint8_t ff_aac_num_swb_1024[];
extern const uint8_t ff_aac_num_swb_128[];
extern const uint8_t ff_aac_pred_sfb_max[];
extern const uint8_t ff_tns_max_bands_1024[];
extern const uint8_t ff_tns_max_bands_128[];
extern const uint16_t *const ff_swb_offset_1024[];
extern const uint16_t *const ff_swb_offset_128[];
extern const float *const ff_tns_tmp2_map[4];
extern const uint32_t ff_aac_scalefactor_code[121];
extern const uint8_t ff_aac_scalefactor_bits[121];
extern const uint16_t *const ff_aac_spectral_codes[11];
extern const uint8_t *const ff_aac_spectral_bits[11];
extern const uint16_t ff_aac_spectral_sizes[11];
extern const float *const ff_aac_codebook_vector_vals[];
extern const uint16_t *const ff_aac_codebook_vector_idx[];

extern float ff_aac_pow2sf_tab[428];
extern float ff_aac_kbd_long_1024[1024];
extern float ff_aac_kbd_short_128[128];
extern float ff_sine_1024[1024];
extern float ff_sine_128[128];

#define LUT_SIZE (1 << 13)
extern union CBRT {
    uint32_t cbrt_tab[LUT_SIZE];
    double tmp[LUT_SIZE / 2];
} ff_cbrt_tab_internal;

extern VLCElem ff_vlc_scalefactors[352];
extern const VLCElem *ff_vlc_spectral[11];

void ff_aac_float_common_init(void);
void ff_cbrt_tableinit(void);
void ff_aacdec_common_init_once(void);

// init_base_tables' vlc_buf: the spectral tables' entries in total.
#define SPECTRAL_VLC_ENTRIES \
    (304 + 270 + 550 + 300 + 328 + 294 + 306 + 268 + 510 + 366 + 462)

// The lengths of codebook_vector{0,10,4}_vals behind
// ff_aac_codebook_vector_vals.
static const int vector_vals_len[11] = { 3, 3, 16, 16, 9, 9, 16, 16, 16, 16, 16 };

static uint32_t bits(float f)
{
    uint32_t u;
    memcpy(&u, &f, sizeof(u));
    return u;
}

static void print_u8(const char *name, int index, const uint8_t *v, int n)
{
    printf("%s", name);
    if (index >= 0)
        printf(" %d", index);
    for (int i = 0; i < n; i++)
        printf(" %u", v[i]);
    printf("\n");
}

static void print_u16(const char *name, int index, const uint16_t *v, int n)
{
    printf("%s", name);
    if (index >= 0)
        printf(" %d", index);
    for (int i = 0; i < n; i++)
        printf(" %u", v[i]);
    printf("\n");
}

static void print_f32(const char *name, int index, const float *v, int n)
{
    printf("%s", name);
    if (index >= 0)
        printf(" %d", index);
    for (int i = 0; i < n; i++)
        printf(" %08x", bits(v[i]));
    printf("\n");
}

static void print_vlc(const char *name, int index, const VLCElem *v, int n)
{
    printf("%s", name);
    if (index >= 0)
        printf(" %d", index);
    printf(" %d", n);
    for (int i = 0; i < n; i++)
        printf(" %d,%d", v[i].sym, v[i].len);
    printf("\n");
}

int main(void)
{
    ff_aac_float_common_init();
    ff_cbrt_tableinit();
    ff_aacdec_common_init_once();

    print_u8("num_swb_1024", -1, ff_aac_num_swb_1024, 13);
    print_u8("num_swb_128", -1, ff_aac_num_swb_128, 13);
    print_u8("pred_sfb_max", -1, ff_aac_pred_sfb_max, 13);
    print_u8("tns_max_bands_1024", -1, ff_tns_max_bands_1024, 13);
    print_u8("tns_max_bands_128", -1, ff_tns_max_bands_128, 13);
    for (int i = 0; i < 13; i++)
        print_u16("swb_offset_1024", i, ff_swb_offset_1024[i], ff_aac_num_swb_1024[i] + 1);
    for (int i = 0; i < 13; i++)
        print_u16("swb_offset_128", i, ff_swb_offset_128[i], ff_aac_num_swb_128[i] + 1);

    // tns_tmp2_map_0_3, _0_4, _1_3, _1_4: 1 << coef_res bits, halved by
    // coef_compress.
    static const int tmp2_len[4] = { 8, 16, 4, 8 };
    for (int i = 0; i < 4; i++)
        print_f32("tns_tmp2_map", i, ff_tns_tmp2_map[i], tmp2_len[i]);

    printf("scalefactor_code");
    for (int i = 0; i < 121; i++)
        printf(" %u", ff_aac_scalefactor_code[i]);
    printf("\n");
    print_u8("scalefactor_bits", -1, ff_aac_scalefactor_bits, 121);
    print_u16("spectral_sizes", -1, ff_aac_spectral_sizes, 11);
    for (int i = 0; i < 11; i++)
        print_u16("spectral_codes", i, ff_aac_spectral_codes[i], ff_aac_spectral_sizes[i]);
    for (int i = 0; i < 11; i++)
        print_u8("spectral_bits", i, ff_aac_spectral_bits[i], ff_aac_spectral_sizes[i]);
    for (int i = 0; i < 11; i++)
        print_f32("codebook_vector_vals", i, ff_aac_codebook_vector_vals[i], vector_vals_len[i]);
    for (int i = 0; i < 11; i++)
        print_u16("codebook_vector_idx", i, ff_aac_codebook_vector_idx[i], ff_aac_spectral_sizes[i]);

    print_f32("pow2sf_tab", -1, ff_aac_pow2sf_tab, 428);
    print_f32("kbd_long_1024", -1, ff_aac_kbd_long_1024, 1024);
    print_f32("kbd_short_128", -1, ff_aac_kbd_short_128, 128);
    print_f32("sine_1024", -1, ff_sine_1024, 1024);
    print_f32("sine_128", -1, ff_sine_128, 128);
    printf("cbrt_tab");
    for (int i = 0; i < LUT_SIZE; i++)
        printf(" %08x", ff_cbrt_tab_internal.cbrt_tab[i]);
    printf("\n");

    // The spectral tables lie one after another in vlc_buf.
    for (int i = 0; i < 11; i++) {
        const VLCElem *end = i < 10 ? ff_vlc_spectral[i + 1] : ff_vlc_spectral[0] + SPECTRAL_VLC_ENTRIES;
        print_vlc("spectral_vlc", i, ff_vlc_spectral[i], (int)(end - ff_vlc_spectral[i]));
    }
    print_vlc("scalefactor_vlc", -1, ff_vlc_scalefactors, 352);
    return 0;
}
