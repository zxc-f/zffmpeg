// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T17a number oracle (zig/testing/vectors/number.txt): what the
// pinned FFmpeg's av_strtod (libavutil/eval.c) makes of a text, and what
// fftools' parse_number (cmdutils.c, restated below as it is not in a
// library) decides for an int option such as -ar. The lines:
//
//   N <text> <value> <end>
//       the text in hex ("-" when empty), av_strtod's value as a C99 hex
//       float (or inf, -inf, nan) and the byte offset where it stopped
//   I <text> <verdict>
//       parse_number(OPT_TYPE_INT, INT_MIN, INT_MAX): "number", "range",
//       "integer" for its three errors, else the value as a decimal
//
// See zig/testing/reference/README.md for the build commands.

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "libavutil/eval.h"

static void hex(const char *text)
{
    if (!*text) {
        printf("-");
        return;
    }
    for (const unsigned char *p = (const unsigned char *)text; *p; p++)
        printf("%02x", *p);
}

static void value(double d)
{
    if (isnan(d))
        printf("nan");
    else if (isinf(d))
        printf(d < 0 ? "-inf" : "inf");
    else
        printf("%a", d);
}

int main(void)
{
    static const char *texts[] = {
        "44100", "44.1k", "44.1K", "48k", "1Ki", "1k5", "0x10", "0X1f", "0x", "0xg", "0x1p3", "0x1.8p1",
        "1e3", "1E3", "1E", "1e+", "1e-", " 12", "\t-3", "\n+5", "-0", "inf", "INF", "Infinity", "infinit",
        "nan", "NaN(123)", "nan(", "nanx", "1.5", ".5", "5.", ".", "", "abc", "-", "+", "1dB", "-6dB", "0dB",
        "1B", "1kB", "1KiB", "1MiB", "2M", "1G", "1T", "1P", "1Z", "1Y", "1y", "1z", "1a", "1f", "1p", "1n",
        "1u", "1m", "1c", "1d", "1h", "3h", "1e400", "1e-400", "2147483647", "2147483648", "-2147483648",
        "-2147483649", "1.0", "2.5", "1e9999k", "100000000000000000000", "0xffffffffffffffffff",
        "0x7fffffff", "1i", "1ki", "1mi", "1Gi", "1GiB", "8000 ", "8000x", "4.41e4", "44100.000",
        "0.5", "1e-3k", "  0x10", "-0x10", "+0x1p4", "1_000", "1,5", "1kk", "1Mi5", "0.97", "96000",
        "1e10", "2e9", "-2e9", "22050.5", "0b101", "017", "08", "1.e2", "1.e", "e5", "1e5.5", "1d", "1dBB",
    };
    for (int i = 0; i < (int)(sizeof(texts) / sizeof(*texts)); i++) {
        char *tail;
        double d = av_strtod(texts[i], &tail);
        printf("N ");
        hex(texts[i]);
        printf(" ");
        value(d);
        printf(" %d\n", (int)(tail - texts[i]));

        /* parse_number(context, numstr, OPT_TYPE_INT, INT_MIN, INT_MAX, &dst) */
        printf("I ");
        hex(texts[i]);
        if (*tail)
            printf(" number\n");
        else if (d < INT_MIN || d > INT_MAX)
            printf(" range\n");
        else if ((int)d != d)
            printf(" integer\n");
        else
            printf(" %d\n", (int)d);
    }
    return 0;
}
