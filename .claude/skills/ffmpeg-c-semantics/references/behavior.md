# Reading the behavior before choosing Zig operations

FFmpeg is pinned at `5d5a38a7e46be296eab75982c0986054f731e19e`.
[notes.md: Undefined C behavior](../../../../notes.md#undefined-c-behavior)
defines the reference-build policy and its exceptions. Consult that policy
for each uncertain case; it is not a blanket permission to wrap arithmetic
or to reproduce memory unsafety.

## Trace the actual operation

Read the implementation with its callers, parameter declarations, macros
and selected helpers. Inspect the relevant library Makefile and `configure`
when a component or specialization is conditional. Generated codec lists
describe a configured build, not the whole upstream capability set.

At each operation that could change meaning, write down these facts in the
working analysis or a code comment where needed:

| Fact | Why it changes a direct port |
| --- | --- |
| Operand type after C promotions | `uint8_t` operands can compute as `int`; an unsigned literal can change the whole expression |
| Width of each intermediate | An `int` accumulator can wrap before assignment to a wider destination |
| Function parameter conversion | `av_clip_int16(int)` receives a narrowed value even if its argument expression returns `long` |
| Store conversion | A C narrowing store may retain low bits; Zig `@intCast` instead requires a fitting value |
| Division and remainder | Rounding of negative values is visible in timestamps and fixed-point arithmetic |
| Shift width and count | Negative/oversized shifts are not portable C; the project's model needs source and reference-build evidence |
| Float precision and evaluation order | A multiply in f32 followed by conversion is not necessarily an f64 multiply rounded at the end |
| Sentinel and error treatment | `INT64_MIN`, EOF, backpressure and malformed input can take different branches |

Preserve the C expression's grouping before simplifying it. For example,
the FLAC probe's `FLAC_MAX_CHANNELS + FLAC_CHMODE_MID_SIDE << 4` means
`(8 + 3) << 4`. Derive a constant from the same named values; an unexplained
recomputed literal loses the relationship that makes it reviewable.

## C constructs and the Zig operation that keeps their result

Each row was run on the pinned 0.17.0. The trap column is what a direct
transcription does instead. Where a row says a cast is required, it is not a
placebo: the `zig-0-17` guide's "Delete the cast and compile" test covers
only the outermost conversion, never an operand widening.

| C | Zig | Trap in the direct transcription |
| --- | --- | --- |
| `uint8_t a, b; int d = a - b;` (operands promoted to `int`) | `const d = @as(i32, a) - b;` | `const d: i32 = a - b;` computes in `u8` and overflows: the destination type does not widen the operands. The same holds for `u16 * u16`. |
| `float x; x * 2.0` (the literal is a `double`, so the product is too) | `@as(f64, x) * 2.0`, then `@floatCast` where C stores to `float` | `x * 2.0` stays `f32` in Zig. `2.0f` in C is the `f32` product. Read the literal's suffix. |
| `int a; unsigned b; if (a < b)` (`a` is converted to unsigned) | Write C's result out. A negative `a` becomes a huge unsigned value, so C's `a < b` is `a >= 0 and a < b`, and C's `a > b` is `a < 0 or a > b`. The `(unsigned)x < n` range idiom is `x >= 0 and x < n`. | Zig compares mathematically, so `-3 < 5` is true where C says false. Check which operand C converted. |
| `a / b`, `a % b` on signed values | `@divTrunc(a, b)`, `@rem(a, b)` | `/` on runtime signed integers does not compile. `@divFloor`/`@mod` compile and differ for negatives (`-7 / 2` is -3 in C, `@divFloor` gives -4). |
| `x >> n` on a signed value (arithmetic on the reference build) | `x >> n` | None for the value. The count must be the shift type (`u5` for 32 bits): prove its range, or use `std.math.shl`, which gives 0 for a count past the width. A C shift by the width or more is undefined, so follow notes.md. |
| `(uint8_t)x`, `int16_t y = wide;` (keeps the low bits) | `@truncate(x)`; for a signed result `@bitCast(@as(u16, @truncate(x)))` | `@intCast` panics or is undefined where C wraps. |
| `(int8_t)byte` then used as `int` (sign extension) | `@as(i32, @as(i8, @bitCast(byte)))` | Widening the `u8` zero-extends. |
| `FFABS(x)`, `abs(x)` | `@abs(x)`, whose type is unsigned (`u32` for `i32`) | The type change spreads into later arithmetic. `@abs(minInt)` is 2147483648 where C's `abs(INT_MIN)` is undefined; follow notes.md for which value the build gives. |
| `FFMIN`/`FFMAX`/`av_clip` on integers | `@min`/`@max`/`std.math.clamp` | `@min`/`@max` narrow the result type (`@min(i32, u32)` is `i32`); `clamp` keeps the operand type. On floats see the NaN rule below. |
| `!!x`, `x != 0` used as a number | `@intFromBool(x != 0)`, a `u1` | `u1 + u1` overflows; widen before arithmetic. |
| Unsigned wraparound (`uint32_t` sums, hashes, CRCs) | `+%`, `-%`, `*%` | `+` panics in safe builds and is undefined in ReleaseFast. |
| `memcpy` | `@memcpy(dst, src)` with equal lengths | Aliasing arguments panic ("@memcpy arguments alias"). |
| `memmove` | `std.mem.copyForwards` (destination below source) or `copyBackwards` | `@memcpy` is not a `memmove`. |
| `memset(p, 0, n)`, `= {0}` | `@memset(slice, 0)`, `@splat(0)`, `std.mem.zeroes` for plain data | A struct with defaults is `.{}`, not zeroed bytes. |
| `AV_RB32`, `AV_WL16`, `bytestream2_get_*` | `std.mem.readInt(u32, p[0..4], .big)` on a checked slice | `@ptrCast` of bytes to an integer pointer reads native-endian and unaligned. |
| Pointer walks (`*dst++ = *src++`, `p < end`) | A slice cut once before the loop, then `for (dst, src) \|*d, s\|` | An index checked on every access; pointer arithmetic past a slice. |
| `goto fail;` with frees at the label | `errdefer` at each acquisition; `defer` for unconditional cleanup | One owner freed by both an `errdefer` and the caller. |
| `int ret; if ((ret = f()) < 0) return ret;` | An error union and `try`, after reading what the caller does with the error | `try` on an error FFmpeg ignores ("Errors and state commits"). |
| Out-parameters, `-1` sentinels, `got_frame` flags | A returned struct, an optional, a tagged union | A sentinel that is also a valid value. |
| Function-like macros, templated `.c` files (`#include "x_template.c"`) | One `fn` with `comptime T: type` or a `comptime` parameter | A copy per type. |
| `static const` tables, tables filled by `ff_init_*` at first use | `const table = blk: { ... };` at comptime, with `@setEvalBranchQuota` where needed | Runtime init with a once-flag. |
| Function pointers chosen at init (`dsp->func`) | A comptime-specialized call, or a `switch` at the stream boundary | A pointer call inside the sample loop. |
| `av_fast_malloc`, a buffer regrown and reused per packet | A retained `ArrayList` with `ensureTotalCapacity` and `clearRetainingCapacity` | An allocation per packet or per frame. |

## Choose a numeric helper by its contract

| Behavior to model | Existing implementation / decision |
| --- | --- |
| C `lrintf`, `lrint`, `rint`, including exceptional input | [core/cconv.zig](../../../../zig/core/cconv.zig); nearest ties-to-even and the pinned build's conversion result |
| `int = lrintf(double)` | `cconv.lrintfInt`; rounding to float, conversion to long, then narrowing to int |
| C double store into int32/int16 in existing ported paths | `cconv.cvttsd2si32`, followed by the documented store narrowing |
| FFmpeg rescaling, rounding flags and timestamp sentinels | [core/rational.zig](../../../../zig/core/rational.zig) |
| Checked rescaling for the API that promises errors | [core/time.zig](../../../../zig/core/time.zig); overflow is an error, not FFmpeg's sentinel result |
| Established scalar math algorithms | [core/libm.zig](../../../../zig/core/libm.zig), with its source provenance and precision contracts |
| FFmpeg numeric text syntax | [core/number.zig](../../../../zig/core/number.zig), [core/options.zig](../../../../zig/core/options.zig), and the relevant notes.md decisions |

Do not replace one row by another merely because their common inputs agree.
Extend a shared helper with a demonstrated second case instead of adding a
local near-copy. The language guide retains its
[numeric checks](../../zig-0-17/references/guide.md#cs-numeric-conversions-model-the-reference-build).

### Examples worth checking at the receiving boundary

`libswresample/audioconvert.c` passes `lrintf`'s result to
`av_clip_int16(int)`. The intermediate `long` narrows before clipping. The
existing float-to-s16 edge case maps 65536.0 to -32768 on the reference
build; clipping the wide result first changes it. Compare the C parameter
in `libavutil/common.h` with the conversion table and
`resample/audioconvert.zig`.

C's `FFMIN`/`FFMAX` are comparisons. Zig's `@min`/`@max` choose the non-NaN
operand; exchanging these can change an exceptional-input result. `@round`
also rounds halfway cases away from zero, unlike C's default `rint`/`lrint`
ties-to-even. Use the established helper and its strict float mode where
required; an optimized float mode can remove a rounding step.

Test boundaries on both sides of a narrowing or clip, positive and negative
halfway values, zero and signed zero, subnormals, NaNs/infinities and values
outside the receiving range. Select cases relevant to the actual operation;
an unrelated codec's vector set is not evidence for this expression.

## Distinguish C rules from build observations

For defined arithmetic, derive the types and compare against independent
vectors. For implementation-dependent or undefined arithmetic, inspect the
reference build's flags and generated operation, then model only the
behavior the project's notes and contract select. Do not rely on Zig's
illegal behavior in ReleaseFast to happen to produce the reference result.

`cconv.zig` records the reference compiler, platform and conversion
instructions. A small C expression test must use the relevant library's
compilation conditions, including math options and macro definitions; an
unrelated executable compiled with different flags may give a different
answer. `zig/testing/reference/README.md` and CI document generator builds.
Keep a primitive-level edge test and an affected media-path regression where
the bug is observable. Report checks actually run, without inventing results
for another compiler or platform.

## Errors and state commits

Read what the C caller does with a failed operation before adding `try`.
`libavformat/demux.c`'s `avformat_find_stream_info` ends read-ahead on an
error and can still open the file. Its counterpart in
[format/demux.zig](../../../../zig/format/demux.zig) models that behavior with
explicit allocation/I/O error handling. Applying the same policy to every
parser read would be wrong: required fields have their own error contract.

### Where FFmpeg refuses, in call order

"FFmpeg refuses this" is a claim about one line. Read the call sequence and
find it before writing the check or the comment:

- `avcodec_open2` (`libavcodec/avcodec.c`) validates `sample_rate`,
  `block_align` and the layout **before** `codec->init`. A value the
  decoder's init stores from extradata afterwards is not checked: the ALAC
  cookie's rate can be negative in `avctx` and the decoder still opens.
  After init only the channel layout and `bits_per_coded_sample` are
  checked.
- A decoder that opened can still deliver nothing: `decode.c`'s
  `frame_validate` fails each frame whose rate is not positive
  (AVERROR_BUG). So "ffprobe reports the stream" and "ffmpeg decodes it"
  are separate observable results, and a port's check belongs at the level
  where FFmpeg fails: probing keeps what ffprobe shows, decoding refuses.
- A comment that says what FFmpeg does names the function, and the author
  read that function at the pin. A plausible claim that was not read is how
  a wrong refusal lands in a shared parser.

A check added to a shared parser or helper changes every caller. Search for
the callers first (`alac.Config.parse` serves CAF decoding and MP4 probing):
if they need different results, the check belongs to the caller, as a named
predicate on the parsed value.

Likewise, inspect when the C changes counters, replaces metadata, saves a
packet or publishes new codec parameters. Use a local successful Zig
initializer before assigning an owning field, so failure cannot leave a
live tag pointing to an uninitialized or freed owner. Keep error precedence
and the documented state after failure observable in tests.

Libc routines are also behavior: `sscanf` matching failure, integer parsing
termination and `printf` rounding can differ from a convenient Zig parser or
formatter. The MOV metadata tests exercise `loci` and HandBrake version
handling against recorded libc results. Consult the reference README's C
library baseline before updating such vectors.

## Source map for recurring cases

Paths in the C column are relative to `.references/ffmpeg/` at the pin.

| C sources | Zig sources / independent evidence |
| --- | --- |
| `libswresample/audioconvert.c`, `dither.c`, `rematrix.c`; `libavutil/common.h` | `core/cconv.zig`, `resample/`; `sampleconv_vectors.c`, `dither_vectors.c`, `remix_vectors.c` |
| `libavutil/rational.c`, `mathematics.c` | `core/rational.zig`, `core/time.zig`; `rational_vectors.c`, `seek_vectors.c` |
| `libavformat/demux.c`, `seek.c` | `format/demux.zig`, `format/seek.zig`; format-specific packet/seek vectors |
| `libavformat/mov.c` metadata readers | `format/mov.zig`; `mov_vectors.c`, metadata fixtures and crafted tests |

Find these generators under `zig/testing/reference/`. This is a map to
existing examples, not a promise that those components cover every future
expression. Update the active task's own source and evidence map.
