# Clean Zig 0.17

How to write Zig for this repository. The pinned compiler is **0.17.0**.
Examples below match that compiler's standard library (its installed
`lib/std`) and the versioned docs:

- [0.15.1 release notes](https://ziglang.org/download/0.15.1/release-notes.html) — Writergate, unmanaged containers, `usingnamespace` and `async`/`await` removed
- [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html) — `Io` as an interface, juicy `main`, `@Type` removed
- [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html) — language cleanup, `std.lang`, allocator printing, `@backingInt`
- [0.17.0 language reference](https://ziglang.org/documentation/0.17.0/)
- [0.17.0 build system guide](https://ziglang.org/learn/build-system/)

0.15.2 exists as a patch release. The Writergate notes live in the 0.15.1
page. Do not mix 0.13–0.14 blog posts, 0.15 migration gists, or the build
guide's stale unit-test sample into new code. That sample still calls
`ArrayList.init` and does not compile on 0.17.0. When a webpage and the
installed std disagree, the installed std wins.

This is the reference half of the project's `zig-0-17` skill. The workflow and
the checklist to run before sending Zig are in [SKILL.md](../SKILL.md). Where
this guide and [CLAUDE.md](../../../../CLAUDE.md) differ, CLAUDE.md wins.

## Contents

- [What "modern" means here](#what-modern-means-here): the 0.15, 0.16 and 0.17 breaks
- [The `@as` placebo](#the-as-placebo): casts, coercion and where `@as` still belongs
- [I/O is two breaks, not a rename](#io-is-two-breaks-not-a-rename): Writergate, `Io`, readers, writers, imports, processes, time and cancellation
- [Allocators and containers](#allocators-and-containers)
- [Builtins agents still copy](#builtins-agents-still-copy): type construction, reflection, integers, errors and control flow, other deletions
- [Formatting](#formatting)
- [Types, literals, and declarations](#types-literals-and-declarations)
- [Tests](#tests)
- [Build graph](#build-graph)
- [A file that already looks like 0.17](#a-file-that-already-looks-like-017)

## What "modern" means here

Three releases stacked. Code that looks fluent in 0.13 is not close.

| Release | The break that still shows up in generated code |
| --- | --- |
| 0.15 | `std.io` readers and writers are dead. `std.Io.Reader` / `std.Io.Writer` are concrete, buffered in the interface, and not generic. `ArrayList` no longer stores an allocator. `usingnamespace` and the `async` / `await` keywords are gone. `{f}` is required to call a `format` method. |
| 0.16 | Anything that can block or observe the outside world takes an `Io` value, the same way allocation takes an `Allocator`. `main` receives `std.process.Init`. `@cImport` is deprecated. `@Type` is gone. `indexOf` is renamed `find`. |
| 0.17 | `@cImport` is removed. `@enumFromInt` / `@intFromEnum` are deprecated. `std.builtin` is deprecated in favor of `std.lang`. `std.fmt.allocPrint` is deprecated in favor of `allocator.print`. `**` array repetition is gone. `errdefer` can no longer capture the error. `void{}` is gone. |

A snippet is not 0.17 because it uses `try` and slices. It is 0.17 when it
type-checks against this std without a compatibility shim.

## The `@as` placebo

`@as(T, value)` is a checked coercion into a result type. It does not cast,
truncate, or make code safer. Old Zig needed it often because many expressions
had no result type. Current Zig forwards the destination type through
assignment, `return`, calls, builtins, and many operators
([result location semantics](https://ziglang.org/documentation/0.17.0/#Result-Location-Semantics),
[type coercion](https://ziglang.org/documentation/0.17.0/#Type-Coercion)).
Wrapping every literal and every argument in `@as` is a habit copied from
0.9-era snippets. It adds noise and hides the places where a real cast is
required.

### Do not write this

```zig
const count = @as(usize, 0);
const rate: u32 = @as(u32, 44100);
const sample = @as(i16, bytes[0]); // not a conversion; i16 is not a u8
try decode(output, @as(usize, 0));

fn decode(out: []i16, start: usize) void {
    _ = out;
    _ = start;
}
```

`decode`'s parameter already has a type. `rate` already has a type. The
`@as` does nothing the compiler was not going to do.

### Write this

```zig
const count: usize = 0;
const rate: u32 = 44100;
try decode(output, 0);
```

Integer literals are `comptime_int`. They coerce to any integer type that can
hold them when a result type exists. Float literals coerce the same way.
`true`, `false`, `null`, and enum literals (`.little`, `.empty`) also coerce
into a known destination.

```zig
const endian: std.lang.Endian = .little;
var list: std.ArrayList(u8) = .empty;
const n: i16 = -1;
const hz: f64 = 44100; // comptime_int to float, exact
```

Prefer a type on the name over a cast on the value. The type is then visible
at the declaration, which is where a reader looks.

### `@as` is not a cast

These are different operations. Using the wrong one is a bug, not a style nit.

| Intent | 0.17 |
| --- | --- |
| Coerce a literal or a value that already fits | Destination type. No builtin. |
| Narrow an integer that might not fit | `const y: u8 = @intCast(x);` |
| Truncate bits on purpose | `const y: u8 = @truncate(x);` |
| Signed/unsigned reinterpret of the same width | `@bitCast`, and only when that is the operation |
| Float to integer, toward zero | `const y: i32 = @trunc(x);` |
| Float to integer, other rounding | `@floor`, `@ceil`, `@round` with an integer result type |
| Integer to float when the integer may not be exact | `@floatFromInt` |
| Pointer type change | `@ptrCast`, plus `@alignCast` when alignment changes |
| Enum from its integer | `@fromBackingInt` into a typed result |

`@intFromFloat` has been deprecated since 0.16.0. It is `@trunc`.
`@enumFromInt` and `@intFromEnum` have been deprecated since 0.17.0. `zig fmt`
rewrites them to `@fromBackingInt` and `@backingInt`.

Do not stack builtins to look careful:

```zig
// Placebo. @intCast already has a result type.
const y = @as(u8, @intCast(x));

// The cast is the whole operation.
const y: u8 = @intCast(x);
```

`@as(u8, some_u32)` does not compile for a runtime `u32`. A `u32` does not
coerce to `u8`. If an agent wrote `@as` there, they wanted `@intCast` or
`@truncate` and papered over not knowing which.

Widening is a coercion. `const x: u32 = small_u8;` needs no builtin. Since
0.16.0, an integer also coerces to a float when every value of that integer
is exactly representable (`u24` to `f32` yes, `u25` to `f32` no). Lossy
comptime int-to-float is a compile error since 0.15; write `123_456_789.0`
if rounding is intended.

### Where `@as` is still the right tool

Use it when there is no result type to forward, or when peer types would
pick the wrong type.

1. **Address of an untyped literal** stored as a default value. A bare `&123`
   is a pointer to `comptime_int`. The 0.16 notes still use this form, and it
   remains valid:

   ```zig
   .default_value_ptr = &@as(u32, 123),
   ```

2. **`anytype` has no destination.** If a function is generic, the caller
   must sometimes name the type. That is a reason to avoid `anytype` for
   ordinary parameters, not a reason to sprinkle `@as` at typed call sites.

3. **Peer type resolution is ambiguous or surprising.** A `switch` or `if`
   whose prongs are untyped literals usually does not need help. It needs
   `@as` when one prong would otherwise drag the result to `comptime_int` or
   to a wider type than the API allows. Prefer giving the result a type:

   ```zig
   const tag: u16 = switch (kind) {
       .pcm => 1,
       else => 0,
   };
   ```

4. **`std.testing.expectEqual` does not need it.** In the 0.17.0 std, both
   arguments are coerced to a common type with peer type resolution, so
   `expectEqual(123, actual)` compares as `i16` when `actual` is an `i16`.
   Old std versions typed the comparison from `expected`, which is why old
   snippets wrap it in `@as`. Do not copy that wrapper:

   ```zig
   try std.testing.expectEqual(123, actual);
   ```

If a line's `@as` can be deleted and the file still type-checks with the same
types, delete it.

## I/O is two breaks, not a rename

Agents keep "updating" `std.io` to `std.Io` and leaving the old shape. That
is not the migration. There were two separate changes.

### 0.15: Writergate

[Writergate](https://ziglang.org/download/0.15.1/release-notes.html#Writergate)
replaced generic `std.io.Reader` / `std.io.Writer` with concrete
`std.Io.Reader` and `std.Io.Writer`.

- The types are not generic. Store `*std.Io.Reader`. Do not take `anytype`
  just to accept a reader.
- The buffer lives in the interface, above the vtable. The hot path is a
  normal copy into that buffer. The vtable runs when the buffer is empty or
  full.
- The caller owns the buffer. There is no `bufferedReader` / `bufferedWriter`
  wrapper. Those types were deleted.
- Errors are small and shared: `error.ReadFailed`, `error.EndOfStream`,
  `error.WriteFailed`, `error.StreamTooLong`. They do not pass the underlying
  file error through. That is intentional. Map them at the boundary.
- `write` may be short. `writeAll` is the call that finishes a slice.
  `flush` is required. A print that was not flushed did not happen.
- `adaptToNewApi` was a 0.15 bridge for old streams. New code does not use it.

The 0.15 upgrade snippet is already stale. It constructed a writer as
`std.fs.File.stdout().writer(&buffer)` with no `Io` argument. Do not copy it.

### 0.16: `Io` is a capability, like `Allocator`

[I/O as an interface](https://ziglang.org/download/0.16.0/release-notes.html#IO-as-an-Interface)
threads an `Io` value through every operation that can block, wait, or observe
the system: files, directories, clocks, randomness, processes, cancellation.
`Io.Threaded` is the implementation selected for a normal program. Evented
and io_uring backends exist so library code does not bake in one concurrency
model. This port does not need those backends. It does need the parameter.

Deleted in 0.16, still common in old answers:

- `std.io.GenericReader`, `AnyReader`, `FixedBufferStream`
- `std.fs.cwd()` as the way to open files
- global `std.process.argsAlloc` as the primary argument API
- `std.Thread.Pool`
- `std.heap.ThreadSafeAllocator` (the arena allocator is thread-safe)

### 0.17 shape

`std.process.Init` is the first parameter of `main` when the program touches
the system. The language reference hello world is the pattern, not a special
case:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n");
}
```

`init` carries:

| Field | Use |
| --- | --- |
| `init.io` | Pass to every file, directory, clock, and process call. |
| `init.gpa` | General allocator. Debug builds check leaks. Thread-safe. |
| `init.arena` | Process-lifetime arena. `init.arena.allocator()` for scratch that dies with the process. |
| `init.minimal.args` | Arguments. `try init.minimal.args.toSlice(init.arena.allocator())`. |
| `init.environ_map` | Environment. Not thread-safe. Most tools do not need it. |

A parameterless `pub fn main() void` is legal for a program that only calls
`std.debug.print`. That print goes to stderr and is for diagnostics. A tool
that reads files or writes a report uses `Init`.

Library functions do not reach for `init`. They take `std.Io` and
`std.mem.Allocator` the same way they take slices. The CLI passes
`init.io` and `init.gpa` in.

```zig
pub fn readHeader(io: std.Io, path: []const u8) !Header {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var file_reader = file.readerStreaming(io, &buf);
    return parseHeader(&file_reader.interface);
}
```

`std.fs.cwd().openFile(path)` is gone. `openFile` is on `std.Io.Dir` and the
`Io` argument is required. `defer file.close(io)` matches it.

### Readers

Memory and streams share one parser type.

```zig
var reader: std.Io.Reader = .fixed(bytes);
const value = try reader.takeInt(u32, .little);
```

`Reader.fixed` ends after those bytes. `takeInt` reads exactly the width of
`T` and returns `error.EndOfStream` if the slice is short. It also **asserts
that the reader buffer is at least the encoded width (`@bitSizeOf(T) / 8`)**.
A zero-length buffer (`&.{}`) trips that assert in safe builds. Give file
readers a real buffer. Four bytes covers a RIFF size field. Use more if one
call consumes a whole chunk.

This repository's parsers read required fields with `readSliceAll` into a
small local array, then `std.mem.readInt`
([CLAUDE.md](../../../../CLAUDE.md), [io_patterns.zig](../../../../zig/examples/io_patterns.zig)).
That works with any reader buffer, including zero bytes. Use `takeInt` only
where the buffer capacity is known to cover the field.

`File.reader(file, io, buffer)` prefers positional reads and falls back to
streaming. Positional reads return `error.Unseekable` on a pipe. A path that
must work without seeking uses `readerStreaming`. Do not retry positional
reads and call that a streaming implementation.

Short reads are normal. One `read` is not a frame. Required bytes use
`takeInt`, `readSliceAll`, or `streamExact`.

`EndOfStream` means "the producer has no more bytes". It does not mean "the
WAV file ended cleanly" and it does not mean "the header was truncated".
Those are different domain errors. Map at the parser boundary. Do not put
`Reader.Error` in the public error set. An inferred `!` will leak it if the
parser `try`s straight through.

`StreamTooLong` is the limit error from a limited read. Surface it as a
resource-limit failure, not as a malformed header.

`takeStruct`, `peekStruct`, `writeStruct`, and `takeStructPointer` accept only
`extern` or `packed` layouts, then optionally byte-swap. `takeStructPointer`
returns a pointer into the reader buffer, invalidated when the buffer is
rebased. They are the convenient way to parse a file wrong. Read fields with
`readSliceAll` (as above) or `takeInt` / `takeArray`. A `packed struct` is not
a WAV header.

`std.mem.readInt` is the right call inside a slice kernel that has already
checked the length. It cannot fail. It is not a stream API. Streaming code
calls `reader.takeInt`, which uses `readInt` after it has the bytes.

### Writers

```zig
var out_buf: [1024]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(init.io, &out_buf);
const stdout = &stdout_writer.interface;
try stdout.print("rate={d}\n", .{rate});
try stdout.flush();
```

`print` without `flush` is a bug. `writeStreamingAll` is the one-shot form
when a buffer would only exist to be flushed immediately, which is what the
language reference uses for hello world.

In-memory output:

```zig
var storage: [64]u8 = undefined;
var w: std.Io.Writer = .fixed(&storage);
try w.writeInt(u16, 1, .little);
const written = w.buffered();
```

`writeInt` has the same buffer-capacity assert as `takeInt`. `Writer.fixed`
on a zero-length slice is not a way to count bytes. Use
`std.Io.Writer.Discarding` when the bytes are thrown away, or
`Writer.Allocating` when they must grow:

```zig
var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
try aw.writer.print("{d}", .{n});
const owned = try aw.toOwnedSlice();
defer gpa.free(owned);
```

The parent writer object must stay put. `&file_reader.interface` points into
`file_reader`. Moving or returning `file_reader` by value dangles that
pointer. Keep the file reader in a stable local and pass the interface
pointer down.

`std.debug.print` is stderr diagnostics. It is not probe output, and it is
not available as a stand-in for a writer in library code.

### What not to import

Do not write any of these in new code:

- `std.io.getStdOut`, `getStdErr`, `getStdIn`, `std.io.bufferedWriter`
- `std.io.GenericReader`, `GenericWriter`, `AnyReader`, `AnyWriter`
- `std.io.FixedBufferStream`
- `std.fs.File.stdout().writer(&buf)` without an `Io`
- `std.fs.cwd().openFile`
- a custom "just a slice and a cursor" type when `Reader.fixed` is the cursor

`std.fs` still exists for path helpers (`std.fs.path`). Opening and reading
go through `std.Io.Dir` and `std.Io.File`.

### Processes, time, cancellation

Spawn with `std.process.spawn(io, options)`. There is no `Child.init` on this
std. `std.process.exit(status)` and `std.process.cleanExit(io)` are how a CLI
ends. Returning an error from `main` is not a documented exit code.

`std.time.timestamp()` and `std.time.Timer` are not media clocks. PCM duration
is an integer sample count and a sample rate. `Io` has clocks for timeouts.
This port does not need them for WAV.

File errors include `Io.Cancelable`. The first tools do not implement
cancellation. Map that error or exclude it. Do not build an `io.async` task
graph to read a WAV file. `Io` makes that possible later. Synchronous code
that takes `Io` is the 0.17 design, not a leftover.

## Allocators and containers

0.15 made unmanaged the default for `ArrayList` and said the managed wrapper
would go away. 0.17 finished that for arrays. The language reference leak
example is the current API:

```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(gpa);
try list.append(gpa, byte);
const owned = try list.toOwnedSlice(gpa);
```

`std.ArrayList(T)` is `array_list.Aligned(T, null)`. It does not contain an
allocator. Every allocating method takes one. `.init(gpa)` does not exist.
`ArrayListUnmanaged` is a deprecated alias of `ArrayList`. Writing the longer
name is the old style, not the careful style.

Pointers into `list.items` die on growth. The 0.17 notes call this out. Do
not hold an element pointer across `append`.

Hash maps have not collapsed the same way. `StringHashMap` and `AutoHashMap`
still have `init(allocator)` and store the allocator. `StringHashMapUnmanaged`
and `AutoHashMapUnmanaged` use `.empty` and take the allocator per call, which
is the direction 0.16 documented. New code uses the unmanaged map unless a
local managed map is obviously simpler and never escapes. Do not invent a
third container.

Other container renames, from the 0.15–0.17 notes:

| Old | 0.17 |
| --- | --- |
| `std.BoundedArray` | A caller-provided slice, or `ArrayList` over a fixed buffer. Do not guess a limit inside the library. |
| `std.fifo.LinearFifo`, `std.RingBuffer` | Usually `std.Io.Reader` / `Writer`. They are the ring buffers. |
| `std.DoublyLinkedList(T).Node` | Intrusive `std.DoublyLinkedList.Node` plus `@fieldParentPtr`. `pop` is `popLast`. |
| `std.heap.stackFallback` | `std.heap.BufferFirstAllocator`. Pass the stack buffer in. |
| `std.heap.DebugAllocator` | Deprecated. `std.heap.SafeAllocator` replaced it. Application code uses `init.gpa`. Tests use `std.testing.allocator`. |
| `std.heap.ThreadSafeAllocator` | Removed in 0.16. Do not reintroduce it. |
| `std.Thread.Pool` | Removed in 0.16. |

`std.testing.allocator` reports leaks through `SafeAllocator`. A test that
allocates must `defer` the matching `deinit` / `free`. That is the test, not
an optional cleanup.

Formatted allocation moved in 0.17:

```zig
// Deprecated wrapper. It still compiles and calls the line below.
const s = try std.fmt.allocPrint(gpa, "{d}", .{n});

// Current.
const s = try gpa.print("{d}", .{n});
defer gpa.free(s);
```

`std.fmt.allocPrint` is marked deprecated in this std, in favor of
`Allocator.print`.

## Builtins agents still copy

### Type construction

`@Type` was removed in 0.16.0. The replacements are `@Struct`, `@Union`,
`@Enum`, `@Int`, `@Tuple`, `@Pointer`, `@Fn`, `@EnumLiteral`. Most code in
this port should not call any of them. A `struct` written in source is the
0.17 way to declare a struct. Generate a type only when the field list is
data.

There is no `@Float`, `@Array`, `@Optional`, `@ErrorUnion`, or `@ErrorSet`.
Write `f32`, `[n]T`, `?T`, `E!T`, and `error{...}`.

`@Struct` takes names, types, and attributes as parallel arrays
(struct-of-arrays), not one array of field structs. `@splat` fills a repeated
attribute. That is also why `**` is gone:

```zig
// 0.16 and earlier
var zeros = [1]u8{0} ** 16;

// 0.17
var zeros: [16]u8 = @splat(0);
```

`void{}` is a compile error. The empty value is `{}`.

### Reflection

0.17 stores struct, union, and enum metadata as parallel arrays. This is the
part of `@typeInfo` that old snippets get wrong:

```zig
// Removed. Do not write this.
inline for (@typeInfo(Options).@"struct".fields) |field| {
    _ = field.name;
}

// 0.17
inline for (@typeInfo(Options).@"struct".field_names, @typeInfo(Options).@"struct".field_types) |name, Field| {
    _ = name;
    _ = Field;
}
```

`std.meta.fieldNames`, `fieldTypes`, and `fieldInfo` are deprecated. Use
`@typeInfo`. `@FieldType(T, name)` and `@field` are the access builtins.

Tag names are lowercase and keywords are escaped: `.@"struct"`, `.@"enum"`,
`.@"union"`, `.optional`, `.pointer`, `.array`. `.Struct` is several years
out of date.

`std.meta.fieldNames` being deprecated does not mean reflection is the way to
implement options. A normal struct with typed fields is the API. Reflect only
when a CLI must walk those fields. `@hasDecl` is true only for `pub`
declarations since 0.17. A private helper is invisible to it, including from
the same file. Do not use `@hasDecl` as a feature probe for private code.

`std.builtin` is deprecated in favor of `std.lang`, and the installed
`std.zig` says the alias is removed after 0.17.0. Write `std.lang.Endian`,
`std.lang.Optimize`, `std.lang.Type`. `@import("builtin")` is a different
module: target, OS, and `is_test`. Do not replace that import with
`std.lang`. Do not write new `std.builtin.Foo` either.

`OptimizeMode` is an alias of `Optimize`. New code uses `std.lang.Optimize`.
The build-system flags are still `Debug`, `ReleaseSafe`, `ReleaseFast`, and
`ReleaseSmall`. `ReleaseSafe` keeps overflow checks. `ReleaseFast` and
`ReleaseSmall` do not. A safety-off test is `ReleaseFast`, not `ReleaseSafe`.

### Integers

Overflow on `+`, `-`, and `*` is illegal behavior. Debug and ReleaseSafe catch
it. ReleaseFast does not, so a wrapping size becomes memory corruption.
`+%` wraps on purpose. It is the wrong operator for a chunk size.

```zig
const bytes = try std.math.mul(u32, rate, block_align);
```

`std.math.add`, `mul`, and `sub` return `error.Overflow`. Map that at the
boundary. `@addWithOverflow` is the lower-level form.

Division truncates toward zero. Timestamp code that wants floor, ceil, or
exact division says so: `@divFloor`, `@divCeil`, `@divTrunc`, `@divExact`.
`@divCeil` is new in 0.17. Do not write `std.math.divCeil(...) catch unreachable`.

`@bitCast` reinterprets logical bits. Since 0.17 it is endian-agnostic and
**refuses `extern` structs**. Casting an `extern` header with `@bitCast` does
not compile. Reinterpreting memory is `@ptrCast` to `*align(1)`, and it is
still the wrong WAV parser. `@bitCast` between arrays or vectors can change
meaning without a compile error. Do not use it to shuffle sample bytes.

`i0` is gone. A zero-width unsigned value is `u0`, and almost nothing in this
port needs one.

### Errors and control flow

`errdefer |err|` was removed in 0.17. `errdefer` no longer names the error.
If the cleanup must log it, split the function and `catch` outside, which is
the upgrade in the release notes.

`try` and `catch` are the error path. Do not `catch unreachable` on input that
came from a file. `unreachable` is for a condition the type system cannot see
and the surrounding code has already proved. A short read is not that
condition.

Inferred error sets (`!`) are fine inside a function. At a module boundary,
name the set: `error{Truncated, Unsupported, Malformed, LimitExceeded}`.
Otherwise `EndOfStream` and `OutOfMemory` become part of the public API by
accident.

`error.SkipZigTest` is how a test skips itself. Do not `return` from a test
to mean "not applicable".

### Other deletions that still appear in snippets

| Do not write | Write |
| --- | --- |
| `usingnamespace` | A named field, or a normal declaration. Removed in 0.15. |
| `async` / `await` keywords, `@frameSize` | Not coming back as keywords. Concurrency, if ever needed, is `Io`. |
| `@cImport` / `@cInclude` | Removed in 0.17. C translation is the external `translate-c` package, and this port does not translate FFmpeg headers as its implementation. |
| `b.addTranslateC` | Still present and not marked deprecated in the 0.17.0 std. This port does not use it either. |
| `std.mem.indexOf` | Still an alias. New code calls `find`, `findScalar`, `findPos`. |
| `trimLeft` / `trimRight` | `trimStart` / `trimEnd`. The old names are not in this std. |
| `containsAtLeastScalar(T, haystack, count, element)` | `containsAtLeastScalar(T, haystack, element, count)`. The 0.17 notes swapped the last two arguments. Old call sites can still compile and be wrong. |
| `readPackedIntNative` / `Foreign` | `readPackedInt` / `writePackedInt`. |
| `[1]T{x} ** n` | `@splat` |
| `std.enums.EnumSet.initEmpty` | `.empty` / `.full` |
| `std.ascii.indexOfIgnoreCase` | `findIgnoreCase` |

`@cImport` moving "to the build system" in 0.16 is not permission to parse C
with `zig translate-c` and call that a port. The project rule is native Zig.

## Formatting

0.15 changed format strings so that adding a `format` method cannot silently
change existing `{}` sites.

- `{}` prints the value. It does not call `format`.
- `{f}` calls `format`. Omitting it is a compile error once the method exists.
- `{s}` is a string, `{d}` is an integer, `{t}` is `@tagName` / `@errorName`,
  `{any}` is a debug dump.
- A `format` method is `pub fn format(self: T, writer: *std.Io.Writer) std.Io.Writer.Error!void`.
  No format string, no `anytype` writer, no options struct.

Alignment is byte alignment, not Unicode grapheme width. Do not depend on `{s}`
padding to line up non-ASCII text.

## Types, literals, and declarations

Decl literals are the normal constructor when the type is already known:

```zig
const header: Header = .{ .channels = 2, .rate = 44100 };
var reader: std.Io.Reader = .fixed(bytes);
var list: std.ArrayList(u8) = .empty;
```

`Header{ .channels = 2 }` still works. Repeating the type at the value is
noise when the destination has it. Repeating it is useful when the
destination is `anytype` or the literal would be ambiguous.

Enum literals do not need the type at the use site when the parameter has it:
`takeInt(u16, .little)`, not `takeInt(u16, std.lang.Endian.little)`, and not
`takeInt(u16, @as(std.lang.Endian, .little))`.

`const` is the default. `var` is a promise that the binding changes. A local
`var` that is never mutated is a compile error ("local variable is never
mutated"), not a warning.

Variables do not shadow. The language reference forbids it. Do not reuse `i`,
`n`, or `buf` in an inner block under the same name.

Declarations behave alike across nested containers. A namespace struct may
declare `Fixture` when the file around it declares `Fixture` too, but an
unqualified `Fixture` inside it is then a compile error ("ambiguous
reference"). Qualify it through the inner container:

```zig
pub const au = struct {
    const Au = @This();
    pub const Fixture = struct { name: []const u8 };
    pub const all: []const Au.Fixture = &.{};
};
```

Do not return the address of a local. Since 0.16 that is a compile error for
the trivial case, and it is still a bug when hidden behind a field.

Slices of comptime-known length can coerce to arrays. 0.17 allows
`const array: [3]u16 = slice.*;` when the slice length is comptime. That does
not make a runtime file slice an array. A WAV `data` chunk has a runtime
length. Keep it a slice.

`packed struct` and `packed union` cannot contain pointers (0.16). A packed
union's fields must share one width, and an exported packed or enum type needs
an explicit backing integer. None of that makes packed layouts a parser.

Zero-bit fields are a legitimate way to attach methods without
`usingnamespace`. They are not the first tool to reach for. A function in the
same file is smaller.

## Tests

```zig
test "empty input" {
    const decoded = try decode(&.{}, &out);
    try std.testing.expectEqual(0, decoded.len);
}
```

- `expectEqual(expected, actual)`. Expected is first.
- `expectError(error.Truncated, result)`.
- `expectEqualSlices` and `expectEqualStrings` for bytes.
- Allocator is `std.testing.allocator`. I/O in a test is `std.testing.io`.
- A doctest is `test functionName`, an identifier, not a string. Use it for a
  short example of that function. Use a string name for a behavior case.
- Tests must not write to stdout. `zig build test` uses stdout as the protocol
  between the build runner and the test runner. The 0.17 build guide states
  this. Probe output is checked by running the executable and capturing its
  stdout, not by printing inside `test`.
- `std.testing.Reader` plus `artificial_limit` is how a test feeds one byte at
  a time. Do not require the operating system to return one-byte reads.
- Fuzzing is `std.testing.fuzz(context, testOne, .{ .corpus = &.{...} })` and
  `zig build --fuzz`. `testOne` receives `*std.testing.Smith`. Fill a bounded
  buffer with `smith.bytes` / `smith.slice`, then parse `Reader.fixed` of that
  buffer. Do not start with a libFuzzer harness.

`builtin.is_test` comes from `@import("builtin")`.

## Build graph

The 0.17 guide's executable is:

```zig
const target = b.standardTargetOptions(.{});
const optimize = b.standardOptimizeOption(.{});

const exe = b.addExecutable(.{
    .name = "zffprobe",
    .root_module = b.createModule(.{
        .root_source_file = b.path("zig/cli/probe.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
b.installArtifact(exe);
```

`root_source_file` belongs on the module, not on `addExecutable` as a sibling
of `.name` the way 0.11 examples wrote it. `createModule` creates a module
private to this build script. `addModule` publishes a module to dependents.
`addImport` wires one module to another.

Tests do not run unless a run step depends on them:

```zig
const tests = b.addTest(.{ .root_module = module });
const run_tests = b.addRunArtifact(tests);
const test_step = b.step("test", "Run unit tests");
test_step.dependOn(&run_tests.step);
```

The default `zig build` runs the install step. An install step with no
artifacts succeeds and compiles nothing. A green empty build is not a build.

`build.zig.zon` `.name` is an enum literal, at most 32 bytes. `.fingerprint`
is generated by the toolchain and then never edited. `.minimum_zig_version`
is a floor. The 0.17 zon docs still describe it as advisory, and this tree's
`std.Build` does not reject an older compiler because of that field.
`.zig-version` is a version-manager file. The compiler does not read it.
`.paths = .{""}` includes the entire directory. In this repository that
would pull in the ignored `.references/` clones, including the FFmpeg C tree.
List the Zig package files.

Do not override the build runner. 0.17 removed that. Do not add foreign
targets to the default test step. They fail on a Windows host unless
`skip_foreign_checks` is set, and skipping the run is not a Linux test.

`std.Build.Step.TranslateC` and `@cImport` are not how this project gains
codecs.

## A file that already looks like 0.17

```zig
const std = @import("std");

pub const Header = struct {
    channels: u16,
    rate: u32,
};

pub fn readRate(bytes: []const u8) error{ Truncated, BadTag }!Header {
    var reader: std.Io.Reader = .fixed(bytes);
    const tag = reader.takeInt(u32, .little) catch return error.Truncated;
    if (tag != 0x46464952) return error.BadTag; // "RIFF" little-endian
    const channels = reader.takeInt(u16, .little) catch return error.Truncated;
    const rate = reader.takeInt(u32, .little) catch return error.Truncated;
    return .{ .channels = channels, .rate = rate };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: tool <file>\n");
        std.process.exit(1); // usage status; see port.md "Initial probe output"
    }

    const file = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer file.close(init.io);

    var buf: [64]u8 = undefined;
    var file_reader = file.readerStreaming(init.io, &buf);
    const header = try readRate(try file_reader.interface.peek(10));

    var out_buf: [128]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &out_buf);
    const stdout = &stdout_file.interface;
    try stdout.print("rate={d}\n", .{header.rate});
    try stdout.flush();
}

test readRate {
    const bytes = [_]u8{
        'R', 'I', 'F', 'F',
        1, 0,
        0x44, 0xAC, 0, 0,
    };
    const header = try readRate(&bytes);
    const expected_channels: u16 = 1;
    const expected_rate: u32 = 44100;
    try std.testing.expectEqual(expected_channels, header.channels);
    try std.testing.expectEqual(expected_rate, header.rate);
}
```

`readRate` takes a complete slice, so the stream adapter has to obtain those
bytes first. `peek(10)` fills the reader buffer until ten bytes are available
or returns `error.EndOfStream`; it requires a buffer of at least ten bytes.
`buffered()` alone returns only bytes already read ahead, which is nothing
before the first read. A real parser takes `*std.Io.Reader` and reads fields
from the stream. The slice function stays the kernel. Do not paper over that
by casting the file to a slice.

## Checklist before sending Zig

The checklist lives in [SKILL.md](../SKILL.md#checklist-before-sending-zig), so
there is one copy to keep current.
