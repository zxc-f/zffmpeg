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
