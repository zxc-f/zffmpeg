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
//   D <text> <verdict>
//       av_parse_time(duration = 1), TODO.md T25b: "E" (EINVAL), "R"
//       (ERANGE), else the microseconds as a decimal
//
// See zig/testing/reference/README.md for the build commands.

#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "libavutil/error.h"
#include "libavutil/eval.h"
#include "libavutil/parseutils.h"

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
    static const char *durations[] = {
        "1", "1.5", "-1.5", "0", "-0", "1s", "1ms", "1us", "1.5ms", "1.0005ms", "1.25us", "12:34", "1:02:03",
        "100:00:00", "10000:00:00", "1:60", "1:2", "01:02.5", "00:01:02.123456789", "1.", ".5", "", "-", "s",
        "1x", "1 s", " 1", "+1", "--1", "-+1", "1:2:3:4", "9223372036854775807", "9223372036854775807us",
        "9223372036854775808", "9223372036854775", "-9223372036854775", "1e3", "0x10", "2.000001", "3.9999999",
        "1:00ms", "5mss", "12:3", "abc", "1.5s", "-0.5", "99999:00",
    };
    for (int i = 0; i < (int)(sizeof(durations) / sizeof(*durations)); i++) {
        int64_t t;
        int ret = av_parse_time(&t, durations[i], 1);
        printf("D ");
        hex(durations[i]);
        if (ret == AVERROR(ERANGE))
            printf(" R\n");
        else if (ret < 0)
            printf(" E\n");
        else
            printf(" %lld\n", (long long)t);
    }
    return 0;
}
