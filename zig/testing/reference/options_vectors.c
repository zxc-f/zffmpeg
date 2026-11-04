// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T17a option oracle (zig/testing/vectors/options.txt): what the
// pinned FFmpeg's av_opt_set does with a text for each of libswresample's
// resampler options, on a fresh SwrContext. The lines:
//
//   O <name> <text> E
//   O <name> <text> <value>
//       the option name, the text in hex ("-" when empty), then E when
//       av_opt_set fails, else the stored value: a decimal for int and bool
//       options, a C99 hex float for double ones
//   X <name> <text> <value>
//       the same for a text only FFmpeg's expression evaluator reads
//       (TODO.md T25b), which the port refuses until then
//
// See zig/testing/reference/README.md for the build commands.

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/log.h"
#include "libavutil/opt.h"
#include "libswresample/swresample.h"

static void hex(const char *text)
{
    if (!*text) {
        printf("-");
        return;
    }
    for (const unsigned char *p = (const unsigned char *)text; *p; p++)
        printf("%02x", *p);
}

static void option_case(const char *kind, const char *name, const char *text, int is_double)
{
    SwrContext *swr = swr_alloc();
    printf("%s %s ", kind, name);
    hex(text);
    if (av_opt_set(swr, name, text, 0) < 0) {
        printf(" E\n");
    } else if (is_double) {
        double d;
        av_opt_get_double(swr, name, 0, &d);
        printf(" %a\n", d);
    } else {
        int64_t i;
        av_opt_get_int(swr, name, 0, &i);
        printf(" %lld\n", (long long)i);
    }
    swr_free(&swr);
}

int main(void)
{
    static const char *ints[] = {
        "64", "44.1k", "1e3", "default", "max", "min", "  48 ", "32.6", "32.5", "33.5", "0x10", "-1",
        "2147483647", "2147483648", "abc", "", "nan", "1k5", "0", "1Ki", "none", "all", "-0", "+8",
    };
    static const char *shifts[] = { "12", "24", "25", "0", "-1", "default", "max", "min", "10.4", "1e1" };
    static const char *bools[] = {
        "0", "1", "true", "yes", "on", "off", "no", "false", "2", "-1", "auto", "1.0", " 1", "enable",
        "disabled", "y", "n", "Enable", "TRUE", "", "01", "1 ",
    };
    static const char *cutoffs[] = {
        "0.5", "1", "1.1", "0", "-0.1", "default", "max", "min", "9e-1", "0.97", " 0.8 ", "500m", "1/2x",
    };
    static const char *types[] = {
        "cubic", "kaiser", "blackman_nuttall", "0", "1", "2", "3", "-1", "Kaiser", "default", "max", "min",
        " kaiser", "kaiser ", "1.4", "1.6",
    };
    static const char *betas[] = { "9", "2", "16", "1", "17", "7.5", "default", "min", "max", "1e1", "nan" };
    static const char *expressions[][2] = {
        { "filter_size", "16*2" }, { "filter_size", "1+1" }, { "cutoff", "1/2" }, { "kaiser_beta", "PI" },
        { "phase_shift", "max-1" },
    };

    av_log_set_level(AV_LOG_QUIET);

    for (int i = 0; i < (int)(sizeof(ints) / sizeof(*ints)); i++)
        option_case("O", "filter_size", ints[i], 0);
    for (int i = 0; i < (int)(sizeof(shifts) / sizeof(*shifts)); i++)
        option_case("O", "phase_shift", shifts[i], 0);
    for (int i = 0; i < (int)(sizeof(bools) / sizeof(*bools)); i++) {
        option_case("O", "linear_interp", bools[i], 0);
        option_case("O", "exact_rational", bools[i], 0);
    }
    for (int i = 0; i < (int)(sizeof(cutoffs) / sizeof(*cutoffs)); i++) {
        option_case("O", "cutoff", cutoffs[i], 1);
        option_case("O", "resample_cutoff", cutoffs[i], 1);
    }
    for (int i = 0; i < (int)(sizeof(types) / sizeof(*types)); i++)
        option_case("O", "filter_type", types[i], 0);
    for (int i = 0; i < (int)(sizeof(betas) / sizeof(*betas)); i++)
        option_case("O", "kaiser_beta", betas[i], 1);
    for (int i = 0; i < (int)(sizeof(expressions) / sizeof(*expressions)); i++)
        option_case("X", expressions[i][0], expressions[i][1],
                    !strcmp(expressions[i][0], "cutoff") || !strcmp(expressions[i][0], "kaiser_beta"));
    return 0;
}
