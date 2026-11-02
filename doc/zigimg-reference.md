# zigimg reference analysis

## Snapshot and role

- Requested repository: [zigimg/zigimg](https://github.com/zigimg/zigimg.git).
- Inspected commit: [`083d0304840a3f5fd547c2e2005148a18886c401`](https://github.com/zigimg/zigimg/tree/083d0304840a3f5fd547c2e2005148a18886c401), dated 2026-10-20.
- Local shallow clone: `.references/zigimg`, excluded by the project's explicit
  `/.references/` ignore rule. It is research material, not a package dependency
  or submodule, and its files must not be committed to this repository.
- Toolchain: the manifest and CI specify Zig 0.17.0, matching this project's
  tested compiler. The repository declares MIT licensing; preserve applicable
  notices if code is copied. This change adds an original example, not copied
  zigimg implementation code.

FFmpeg remains the behavior/reference source. zigimg supplies concrete examples
of Zig library organization, I/O and ownership. Its image-oriented API does not
define our multimedia timing, streaming or compatibility contract.

Both reference repositories belong inside this project's ignored `.references/`
directory; [README.md](../README.md#clone-the-reference-repositories) has the
pinned clone commands. Check the clone's revision before refreshing this
analysis; the links below pin the inspected source.

## Findings and decisions

| Observed source | Application to this port |
| --- | --- |
| [build.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/build.zig) exposes one module, adds generated format options, installs a test executable and separates running tests from building them. | Keep one `av` module and an executable test step. Our default artifact remains the planned native library; installing zigimg's test executable is not a template for our release packaging. |
| [build.zig.zon](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/build.zig.zon) explicitly lists package contents and a minimum compiler version. | Maintain our own allowlist and package identity. Minimum-version metadata does not replace our tested-version check. |
| [src/io.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/src/io.zig) wraps memory/file readers and writers, exposing `*std.Io.Reader` / `*std.Io.Writer`. | Reuse those standard interfaces directly for WAV. Add transport or seek wrappers only when they supply required capabilities. |
| [src/Image.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/src/Image.zig) separates path, file and memory entry points. Path helpers open/close files; file helpers use caller-provided handles and scratch buffers. | Separate owning convenience functions from borrowed-handle operations. Pass `std.Io` only where OS operations need it; pure parsing and memory-backed calls do not require an I/O context. |
| [src/PixelFormatConverter.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/src/PixelFormatConverter.zig) places `errdefer` next to destination allocation. | Establish cleanup before the next fallible operation; transfer ownership only on success. Keep initial PCM kernels allocation-free. |
| [src/color.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/src/color.zig) models pixel storage as a tagged union of concrete storage types. | Use typed sample/pixel views as supported formats grow. A tagged union can express a real format choice; a universal untyped context is unnecessary. |
| [zigimg.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/zigimg.zig) explicitly imports test files from a root test block. | Explicitly include every implemented test file. Keep example tests runnable now and aggregate them in T01. Referencing declarations does not instantiate every generic specialization. |
| [tests/io_test.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/tests/io_test.zig) exercises memory, unbuffered files and several buffer sizes using `std.testing.io` and temporary directories. | Add real file-adapter tests alongside fixed-memory and artificially fragmented readers; file buffering and source fragmentation are different concerns. |

## Concrete I/O rules

1. **Construct the adapter, then borrow its interface.** A file reader/writer
   contains `.interface`. Keep the enclosing adapter and its scratch buffer
   alive and at a stable address while the pointer is in use. Never return a
   pointer into a local adapter or move the adapter while its interface is held.
2. **Keep one adapter for the stream lifetime.** Reconstructing a reader over
   the same file can discard unread read-ahead bytes. Its logical consumed
   position can differ from the OS file position; use `logicalPos()` or explicit
   parser byte accounting, not the adapter's raw backing position.
3. **Read required fields exactly.** Use `readSliceAll` into small local arrays
   followed by endian decoding. This avoids imposing contiguous-buffer sizes
   on arbitrary readers. A tiny source buffer is not a reason to reject valid
   input. Map EOF while reading a required field to truncation. A failed exact
   read may have consumed part of the field, so the failure is terminal.
4. **Preserve transport diagnostics at the outer boundary.** Generic readers
   report `ReadFailed`; a file adapter retains more detail in `.err`, including
   cancellation. Translate to the domain's I/O failure while retaining/reporting
   the cause. Do not turn every failure into invalid media.
5. **Make output completion explicit.** Encode fields into a local array and
   call `writeAll`, so writers work with any buffer size. Generic field writers
   need not flush after every field. The owning file/CLI operation or encoder `finish` flushes
   and checks failure before success. Closing a handle is not a replacement
   for checking buffered output errors.
6. **Separate parsing from resource acquisition.** The format parser accepts
   a Reader; a path helper owns opening/closing; a borrowed-file helper leaves
   closing to the caller. Memory adapters borrow their backing slices. State
   these ownership rules in public API comments.

The original [standalone example](../zig/examples/io_patterns.zig) demonstrates
exact field reads, fixed memory writers, file `.interface` access, adapter
lifetime, retained read errors, explicit flushing and buffer-size-independent
behavior. It intentionally stops at individual fields and is not a WAV parser.
Run it with the commands in [README.md](../README.md#run-the-current-examples).

## Patterns to adapt selectively

- **Seeking and probing:** zigimg's stream abstraction supplies seeking/size,
  and some detection paths such as [TGA](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/src/formats/tga.zig) seek or rewind.
  Our first WAV path stays sequential. A later multi-format probe must preserve
  a bounded prefix for the selected parser, rather than consume input and
  assume it can rewind a pipe. Seekability is a capability, not a requirement
  of every reader.
- **Struct serialization:** some zigimg formats use `takeStruct`/`writeStruct`.
  Keep explicit RIFF fields and checked chunk extents here. The reference is
  useful for I/O plumbing without importing its format-specific assumptions.
- **Feature dispatch:** zigimg combines build booleans, compile-time declaration
  inspection, typed function pointers and a tagged `EncoderOptions` union.
  Use the simplest descriptor/switch when T12 needs selection. Test format
  identity and lookup with individual features disabled; a default build alone
  does not validate every option combination.
- **Managed wrappers:** [Image/Managed.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/src/Image/Managed.zig) duplicates layout and uses pointer casts.
  Prefer composition if an allocator-owning convenience wrapper is needed;
  do not require matching internal layouts. Keep ownership transfers explicit.
- **Time and scope:** image animation uses floating-point duration in this
  snapshot. Multimedia time bases here remain integer/rational. The reference's
  image allocation and conversion choices do not establish a streaming frame API.
- **Bit I/O:** the source identifies its bit reader/writer as adapted from Zig
  0.14.1. Review bit order, bounds and EOF behavior against our first compressed
  format before adopting any part; PCM/WAV needs no general bitstream framework.

## Source and testing caveats

The pinned README has stale call examples: it passes a file pointer where
`Image.fromFile` accepts a file value, and passes an I/O context to `fromMemory`
although its implementation takes only allocator and bytes. Follow the actual
declarations, then compile the usage. A recent repository is still evidence to
check, not an automatically correct API guide.

[tests/helpers.zig](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/tests/helpers.zig) skips missing external fixture files.
Its [CI](https://github.com/zigimg/zigimg/blob/083d0304840a3f5fd547c2e2005148a18886c401/.github/workflows/main.yml) checks out a separate `zigimg/test-suite` repository and
runs on native Ubuntu, macOS and Windows. Our required tiny fixtures should live
with the project and missing required fixtures must fail. Optional external
corpora may skip only with an explicit summary. Do not interpret skips as
coverage or copy the separate corpus layout without provisioning it in CI.

## Validation

With the pinned clone and local Zig 0.17.0, from `.references/zigimg`:

```text
zig build test '-Dtest-filter=io.' --summary all
```

Result: **15/15 tests passed**. The quoted argument is safe in PowerShell.
This is focused I/O validation; the full external image fixture suite was not
run. The standalone example passed formatting and **6/6 tests in each of Debug,
ReleaseSafe and ReleaseFast** on native Windows with Zig 0.17.0. These exercise
exact bytes, every short field length, one-byte source fragments, read failure,
insufficient writer capacity and file readers with 0-, 1- and 64-byte buffers.
A later seventh test checks that a file read failure returns the adapter's
retained `.err`; it runs in the Linux CI workflow, not in the Windows run above.
Neither reference tests nor examples complete the native library tasks in
[TODO.md](../TODO.md).
