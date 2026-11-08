---
name: ffmpeg-c-semantics
description: Preserve the pinned FFmpeg C implementation's observable behavior when porting or reviewing an algorithm in Zig. Use for C integer promotions and narrowing, shifts, float rounding and conversions, macro expressions, libc parsing/formatting, or error handling whose direct Zig translation can change results. Use zig-0-17 for language APIs and ffmpeg-oracle for reference generators and comparisons.
---

# Preserve C behavior in native Zig

Port the capability's behavior with concrete Zig types and control flow.
The implementation remains native Zig; C generators are test oracles only.
Read [the procedure](references/behavior.md) for the expression, error path
or libc behavior being changed. The installed Zig 0.17.0 std and the pinned
FFmpeg sources settle API facts; the contracts settle supported behavior.

## Workflow

1. Identify the FFmpeg operation, its callers and helpers. Read the relevant
   headers and Makefile/configure selections; a macro or DSP dispatch may
   select a different implementation than the source file suggests. Search
   for the existing Zig port before creating another copy.
2. Work out the behavior at the boundary: operand/result widths, signedness,
   promotions, narrowing, rounding, sentinels, state changes and error
   treatment. Check receiving function parameters as well as local variables.
3. Classify uncertain behavior as defined by C, dependent on the reference
   build, or an unsafe memory/error case governed by the contract. Read the
   applicable notes.md row. Do not generalize an observed machine result to
   all C compilers or reproduce an out-of-bounds access in Zig.
4. Reuse the project's established helpers (`cconv`, `rational`, `time`,
   `libm`, number parsing) where their contracts match. Use
   [ffmpeg-oracle](../ffmpeg-oracle/SKILL.md) to establish independent edge
   vectors before changing the implementation.
5. Write Zig with `zig-0-17`, then inspect every changed expression and
   error path against the C behavior. Keep reference-dependent conversions
   explicit; retain a range proof beside a primitive cast on input.
6. Validate the affected path in the required build modes. A new difference
   or deliberate preservation of a non-obvious FFmpeg quirk gets the
   notes.md row required by CLAUDE.md, with the source and evidence named.

## Questions before accepting a port

- Does the Zig expression compute in the same width and precision before
  storing? A wider accumulator or later clip can change output.
- Is a wrapping operation codec arithmetic or an allocation/offset count?
  The latter needs checked math, not wrapping copied from C.
- Did an apparently convenient Zig helper change NaN handling, rounding,
  integer division, parse termination or error precedence?
- Does `try` propagate an error FFmpeg actually propagates? If FFmpeg stops
  read-ahead, ignores an optional field, retries, or keeps prior state, model
  that specific behavior and the contract's recorded exceptions.
- Does the evidence call the pinned C implementation, with the relevant
  build configuration, rather than compare two versions of the Zig formula?

Media buffering, ownership transitions and time-base changes also use
[media-pipeline](../media-pipeline/SKILL.md). File adapter mode and buffer
choices stay in `zig-io`; this skill supplies no new threading or dependency
permission.
