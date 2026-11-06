---
name: zig-0-17
description: How to write and change Zig 0.17.0 code in the zffmpeg repository. Use it every time you create or edit a .zig file (anything under zig/, or build.zig) or build.zig.zon, including one-line fixes, tests and examples, and when reviewing Zig or answering how to write something in Zig here. The pinned 0.17.0 standard library moved I/O, containers, builtins, reflection and the build API since 0.13–0.15, so Zig written from memory or from older web examples usually fails to compile or is subtly wrong.
---

# Zig 0.17 in zffmpeg

The compiler is exactly **0.17.0**; `build.zig` rejects any other. Three
releases of breaking changes (0.15's Writergate, 0.16's `Io` capability, 0.17's
language cleanup) separate it from most Zig in training data and on the web.
Code that looks fluent from memory is often 0.13 code. This skill exists so
every Zig change starts from the pinned toolchain's rules instead.

## Workflow

1. **Read before writing.** For a new file, or the first Zig change in a
   session, read [references/guide.md](references/guide.md) in full (about 1000
   lines). For a later small edit in the same session, re-read the sections the
   change touches, using the map below.
2. **Apply the project rules.** [CLAUDE.md](../../../CLAUDE.md) wins where it
   differs from the guide. Its sections "Portable Zig code", "Zig 0.17 I/O and
   test patterns", "Modern Zig metaprogramming" and "When adding code" apply to
   every change. port.md's "Verified Zig 0.17 I/O choices" and "C-to-Zig
   decisions that affect correctness" record facts already checked against the
   pinned std; consult them before re-deriving one.
3. **Trust the installed std over memory.** When the guide, port.md and memory
   do not settle an API, read Zig 0.17.0's installed `lib/std` (`zig env`
   prints `lib_dir`) or compile a minimal check with the pinned compiler. If
   the std contradicts the guide, fix `references/guide.md` in the same change.
4. **Design before syntax.** Identify closed value sets, operation errors,
   state-specific payloads, ownership and external numeric or string
   boundaries. Prefer a normal enum, error union, optional or tagged union
   when it expresses those facts directly. Keep concrete loops and explicit
   wire parsing when they are the clearest implementation. A generic helper
   must remove real duplication or enforce an invariant for current callers.
   The guide's "Model values, state and boundaries" has the patterns.
5. **Write the code**, then go through the checklist below against every
   changed hunk, not only the parts you remember writing.
6. **Verify.** Run `zig fmt --check build.zig build.zig.zon zig/` and
   `zig build test` in Debug, ReleaseSafe and ReleaseFast (CLAUDE.md
   "Commands"). Without a local Zig 0.17.0, the pull request's CI run is the
   verification: say so, and never report results that were not run.

## Section map

| The change involves | Read in [references/guide.md](references/guide.md) |
| --- | --- |
| Casts, `@as`, integer conversions | "The `@as` placebo", "Integers" |
| Readers, writers, files, stdio, `main` | "I/O is two breaks, not a rename" with "Readers", "Writers", "What not to import", "Processes, time, cancellation" |
| `ArrayList`, maps, allocators | "Allocators and containers" |
| Reflection, generated types, comptime tables | "Type construction", "Reflection" |
| CLI statuses, parser APIs and state, error domains, test helpers, shared helpers | "Model values, state and boundaries" |
| Error sets, `errdefer`, control flow | "Errors and control flow", "Other deletions that still appear in snippets" |
| Tests | "Tests" |
| `build.zig`, `build.zig.zon` | "Build graph" |
| Formatting, literals, declarations | "Formatting", "Types, literals, and declarations" |
| Parsers, decoders, demuxers, anything that reads untrusted bytes; cleanup and error paths; adversarial tests | "Hostile input" |
| A C float-to-integer conversion, `lrint`/`rint`, a clip, C's integer widths; errors the C ignores | "C's numeric conversions: model the reference build", "Errors the C ignores" |
| A new parser, helper, codec state, dispatch switch or registry entry; a second copy of existing logic | "Shape the port as Zig, not as C" |
| A whole new file | "A file that already looks like 0.17", then everything above it touches |

## Checklist before sending Zig

- No `@as` unless the line stops compiling, or changes type, without it.
- No `@as(T, @intCast(x))`. The result type is enough: `const y: T = @intCast(x);`.
- No `std.io`. No `getStdOut`. No reader or writer without a caller-owned buffer and, for files, an `Io`.
- No `anytype` reader or writer. The type is `*std.Io.Reader` or `*std.Io.Writer`.
- No `takeStruct` on a file header.
- `EndOfStream` is mapped before it leaves the parser.
- `main` that does I/O takes `std.process.Init` and passes `init.io` and `init.gpa` down.
- `ArrayList` is `.empty`, and `append` / `deinit` take the allocator. No `.init(allocator)`.
- No `@Type`, `@cImport`, `usingnamespace`, `async`/`await`, `void{}`, or `**`.
- `@typeInfo(...).@"struct".field_names` and `field_types`, not `.fields`.
- `std.lang` for language types. `@import("builtin")` only for target facts.
- `find` / `trimStart` / `allocator.print` / `@fromBackingInt` / `@trunc`.
- Overflowing size math uses `std.math.mul` / `add`, not `+%` and not a bare `+` that is only safe in Debug.
- No union or owner field assigned from a fallible initializer in one expression: bind the result to a local, then assign. No owner stored in `self` while its `errdefer` is armed.
- Input-derived values: `@intCast` only after a check; `@truncate` with a comment where the C truncates; `+%`/`-%` with the notes.md comment where the C's signed arithmetic wraps on the reference build.
- No `@trunc`/`@intFromFloat` into an integer, and no `@round`, on a float not proven in range: C's `lrint`/`lrintf`/`rint` and float-to-int stores go through `core/cconv.zig`. Check the receiving C function's parameter width (`av_clip_int16(int)` narrows a `long` first) and keep C's accumulator widths.
- Replacing an owned field builds the new value in a local before freeing the old one; one cleanup per owner per path (no `errdefer` plus `defer` on the same value). Freeing a buffer resets every view into it, tests and fuzz callbacks included.
- A ported `try` matches what the C does with that error: a loop FFmpeg ends on error (the stream-info read-ahead) ends, it does not fail.
- A constant copied from C keeps its expression and precedence, derived from the same named values (`(8 + 3) << 4`, not `8 + 2`).
- No `std.debug.assert` as the only guard of a public contract, no `catch unreachable` / `else => unreachable` on an error input can cause, no `else => unreachable` over `anyerror`.
- No `discardShort`/`discardAll` with an untrusted length (use `zig/io/skip.zig`), no `std.math.ldexp` (use `libm.ldexp`). See the guide's "std pitfalls".
- Work stays proportional to bytes present: no per-unit loop over a header-declared count, no `orderedRemove(0)` drain, no re-copy of a growing value per append.
- A buffer that is written before its bound is checked is sized as FFmpeg sizes it; widths come from the value being written, not a second copy of the format.
- Tests do not print to stdout. `expectEqual` needs no `@as`; peer type resolution types both arguments.
- No OS-specific code: no `std.os.linux`, direct `std.posix` calls or libc; no hard-coded `/` paths; explicit byte order; fixed-width integers for sizes and counts. See CLAUDE.md "Portable Zig code".
- If a snippet's first line is `const std = @import("std");` and its second line could have been written in 0.13, it is not done.

Design questions, from the guide's "Model values, state and boundaries":

- A closed outcome set has a named type when that improves the API; stable
  numeric encodings appear only at the external boundary, converted with
  `@backingInt` / `@fromBackingInt`.
- A state tag and a nullable payload do not duplicate an invariant without a
  documented reason; otherwise the state carries its payload.
- An empty slice or numeric sentinel does not ambiguously stand for EOF,
  missing data and insufficient capacity. Contract changes stay explicit.
- A boundary's error domain is named where practical. `anyerror` and `anytype`
  have a specific callback or generic-use justification.
- Tests compare errors as values (`expectError`, `expectEqual`) unless the
  external spelling is what is tested. Fixture and process expectations stay
  independent of the implementation under test.
- An unwrap (`.?`) follows a clear invariant; prefer capture or `orelse` when
  that expresses validation locally. A proven `unreachable` sits next to its proof.
- Before duplicating an operation, check whether the second working caller
  calls for a small shared helper. Do not add a framework to satisfy this.
- Before porting an FFmpeg function, search for an existing port of it: one
  implementation per FFmpeg function (a second Vorbis comment parser drifted).
  New parsed formats use `demux.Layer`.
- Per-stream codec state is one `union(enum)`; sentinels, tri-state integers
  and out-pointers become enums, optionals, tagged unions and return values.
- Dispatch over a union's cases is derived from the union (`inline else`,
  `field_names`/`field_types`), not kept in parallel lists; arms that
  genuinely differ stay an explicit exhaustive switch.
- A guide example or [io_patterns.zig](../../../zig/examples/io_patterns.zig)
  is copied only if it follows this checklist; the guide, this checklist and
  that executable example must agree, so fix whichever one drifts. Compile-only
  checks are not native execution or multimedia verification.

Repository checks, from CLAUDE.md:

- A comment that says the port departs from FFmpeg, does not model or port
  its behavior, reproduces an FFmpeg quirk, picks a value where FFmpeg's C is
  undefined, or defers to a task has its notes.md row (CLAUDE.md "Recording
  differences from FFmpeg in notes.md"); a comment made stale is fixed.
- A new `.zig` file starts with an `SPDX-License-Identifier` line and a
  provenance comment, then `//!` module docs.
- A new `av` file with tests is referenced from a `test` block in
  `zig/root.zig`, because Zig analyzes lazily and unreferenced tests never run.
  A new example is registered in the `examples` list in `build.zig`.
- CLI behavior is tested with a `probe_cases` process run, never by printing
  from a unit test. Parsing stays in `av`; `zig/cli/` only handles arguments,
  files and output.
- Parsers check lengths and arithmetic before reading or allocating, so they
  stay safe in ReleaseFast, where runtime safety is off.
- A malformed-input path has a regression test that runs in Debug: a unit
  test with crafted bytes, and a process case for the tool that reaches it
  (zffprobe never builds decoders; decoder refusals need `convert_cases`).
  Fuzz entries vary the limits, not only the defaults.
- A new or changed parser, demuxer or decoder has its fuzz entry and an
  allocation-failure sweep with remap failures (TODO.md G3) in the same
  change, not at a later gate. Its corpus uses `hostile.fuzzSeed`, so the
  seeds reach the parser; raw bytes are read as a length prefix.
- Nothing breaks the compile-only cross build for x86_64-windows-gnu,
  aarch64-linux-musl and aarch64-macos.
