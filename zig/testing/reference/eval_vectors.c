// SPDX-License-Identifier: LGPL-2.1-or-later
// Original file for this project: a vector generator, not part of the port.
//
// Prints the T25b expression oracle (zig/testing/vectors/eval.txt): what the
// pinned FFmpeg's av_expr_parse and av_expr_eval (libavutil/eval.c) make of
// a text, with the constants x = 0.5, y = -3 and n = 7. The lines:
//
//   V <text> E
//       the text in hex; av_expr_parse refuses it
//   V <text> <value> <value> <value>
//       three evaluations of the same parsed expression (its variables and
//       random state carry over), each a C99 hex float, nan, inf or -inf
// Texts whose result C leaves undefined (NaN or an out-of-range double
// converted to an integer) are not listed.
//
//   X <text>
//       an expression with time(), which reads the clock: the port refuses
//       it
//
// See zig/testing/reference/README.md for the build commands.

#include <math.h>
#include <stdio.h>

#include "libavutil/eval.h"
#include "libavutil/log.h"
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

static void value(double d)
{
    if (isnan(d))
        printf(" nan");
    else if (isinf(d))
        printf(d < 0 ? " -inf" : " inf");
    else
        printf(" %a", d);
}

static const char *const names[] = { "x", "y", "n", NULL };
static const double values[] = { 0.5, -3, 7 };

static void eval_case(const char *text)
{
    AVExpr *e = NULL;
    printf("V ");
    hex(text);
    if (av_expr_parse(&e, text, names, NULL, NULL, NULL, NULL, 0, NULL) < 0) {
        printf(" E\n");
        return;
    }
    for (int i = 0; i < 3; i++)
        value(av_expr_eval(e, values, NULL));
    printf("\n");
    av_expr_free(e);
}

int main(void)
{
    static const char *texts[] = {
        /* Numbers, constants and operators. */
        "1", "1+2*3", "2^3^2", "-2^2", "2^-1", "-2^-2", "-3dB", "-(3dB)", "3dB", "1/0", "-1/0", "0/0",
        "1e3k", "0x10", "44.1k", "x*y", "x+y*n", "-x", "--x", "+-x", "-+x", "(x)", "((1))", "x;y", "1;2;3",
        "x y", " 1 + 2 ", "PI", "E", "PHI", "QP2LAMBDA", "-PI", "2*PI", "PIx", "xx", "x2", "n/2", "y%2",
        "1+", "", "(", "1)", ")", "1+2)", "(1", "x(1)", "+", "-", "*2", "1**2", "1^", "1;", ";1", "1,2",
        "2^0.5", "(-8)^(1/3)", "0^0", "-0", "1-1", "x-x", "1--1", "1-+1", "2*-3", "2/-0", "1/(0*-1)",
        /* Functions of one argument. */
        "sin(x)", "cos(y)", "tan(x)", "asin(x)", "acos(x)", "atan(y)", "sinh(x)", "cosh(y)", "tanh(x)",
        "exp(x)", "log(n)", "abs(y)", "-abs(y)", "sqrt(2)", "sqrt(-1)", "floor(-2.5)", "ceil(-2.5)",
        "trunc(-2.5)", "round(2.5)", "round(-2.5)", "round(0.5)", "sgn(y)", "sgn(0)", "sgn(0/0)", "not(0)",
        "not(x)", "isnan(0/0)", "isnan(1)", "isinf(1/0)", "isinf(-1/0)", "isinf(1)", "squish(x)", "gauss(x)",
        "-gauss(0)", "log(0)", "log(-1)", "exp(1000)", "sin(1e300)", "tan(PI/2)", "acos(2)",
        /* Functions of two or three arguments. */
        "max(1,2)", "min(1,2)", "max(0/0,1)", "min(1,0/0)", "eq(1,1)", "eq(0/0,0/0)", "gt(2,1)", "gte(1,1)",
        "lt(1,2)", "lte(2,1)", "mod(7,3)", "mod(-7,3)", "mod(7,-3)", "mod(7,0)", "mod(7.5,2)", "pow(2,0.5)",
        "pow(-8,1/3)", "hypot(3,4)", "atan2(1,y)", "atan2(0,-1)", "bitand(12,10)", "bitor(12,10)",
        "bitand(0/0,1)", "bitor(-1,6)", "bitand(5.9,7)", "gcd(12,18)", "gcd(0,5)", "gcd(5,0)", "gcd(-4,6)",
        "if(x,1,2)", "if(0,1,2)", "if(0,1)", "ifnot(0,5,6)", "ifnot(1,5)",
        "clip(5,0,3)", "clip(-5,0,3)", "clip(1,3,0)", "clip(0/0,0,1)", "between(2,1,3)", "between(4,1,3)",
        "lerp(1,3,0.25)", "lerp(1,3,2)", "-max(1,2)", "max(1,2,3)", "sin(1,2)", "sin()", "max(1)",
        "if(1)", "clip(1,2)", "lerp(1,2)", "between(1)", "sin(1", "sin(1))", "foo(1)", "foo", "sinx(1)",
        "sin (1)", "max(1;2,3)", "max((1,2),3)", "max(1,(2))",
        /* Variables, loops and random numbers. */
        "ld(0)", "st(0,5);ld(0)", "st(0,ld(0)+1)", "st(1,x);st(2,ld(1)*2);ld(2)", "ld(-1)", "ld(10)",
        "ld(9.9)", "st(12,3);ld(9)", "while(lt(ld(0),10),st(0,ld(0)+1))",
        "while(0,1)", "taylor(1,1)", "taylor(1,x)", "taylor(if(mod(ld(1),2),0,1),1,1)", "taylor(ld(0),2)",
        "root(ld(0)*ld(0)-2,5)", "root(ld(0)-3,10)", "root(1,5)", "-root(ld(0)-1,2)", "-while(0,1)",
        "random(0)", "random(1)", "st(1,42);random(1)", "st(3,0/0);random(3)",
        "randomi(0,1,10)", "randomi(4,-5,5)", "random(0)+random(0)", "print(x)", "print(x,24)", "-print(2)",
        /* Nesting deeper than FFmpeg allows. */
        "((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((1)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))",
        "(((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((((1)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))",
        "1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1",
        "1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1",
    };
    static const char *clock_texts[] = { "time(0)", "1+time(0)*0" };

    av_log_set_level(AV_LOG_QUIET);
    for (int i = 0; i < (int)(sizeof(texts) / sizeof(*texts)); i++)
        eval_case(texts[i]);
    for (int i = 0; i < (int)(sizeof(clock_texts) / sizeof(*clock_texts)); i++) {
        printf("X ");
        hex(clock_texts[i]);
        printf("\n");
    }
    return 0;
}
