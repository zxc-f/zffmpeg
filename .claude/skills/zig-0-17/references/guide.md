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
- [Model values, state and boundaries](#model-values-state-and-boundaries): typed statuses, error domains, state payloads, empty results, reuse, error assertions, captures
- [Hostile input](#hostile-input): initialization order, buffer sizing, ReleaseFast checks, input-derived integers, C's numeric conversions, errors the C ignores, std pitfalls, work bounds, cleanup, tests
- [Shape the port as Zig, not as C](#shape-the-port-as-zig-not-as-c): one implementation per FFmpeg function, shared data paths, typed state, derived dispatch
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
const sample = @as(i16, bytes[0]); // valid widening, but the type belongs on the name
try decode(output, @as(usize, 0));

fn decode(out: []i16, start: usize) void {
    _ = out;
    _ = start;
}
```

`decode`'s parameter already has a type. `rate` already has a type. The
`@as` does nothing the compiler was not going to do. For a `[]const u8`,
`@as(i16, bytes[0])` compiles: every `u8` fits in an `i16`. It is noise, not
an error, but simply deleting it changes the inferred type to `u8`, so move
the type to the declaration.

### Write this

```zig
const count: usize = 0;
const rate: u32 = 44100;
const sample: i16 = bytes[0];
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
std. A CLI with documented statuses returns them from a `u8` `main`, so every
`defer` runs first; `std.process.exit(status)` and `std.process.cleanExit(io)`
end a process without unwinding. Returning an error from `main` is not a
documented exit code: `std/start.zig` logs it and exits with status 1. See
"Typed outcomes, numeric encoding at the boundary" below.

A child's `cwd` changes how relative paths in its `argv` resolve, including
`argv[0]`: resolve the executable first (`Dir.realPathFileAlloc`). Passing
`.{ .file = f }` as a stdio stream differs by platform: POSIX duplicates the
descriptor with its access mode, while Windows reopens the file with the
access that stream needs. A write-only file as stdin therefore fails to read
only on POSIX. A pipe whose read end the parent closes makes the child's
writes fail on every platform. A Zig 0.17 child that runs on
`std.Io.Threaded` (the `Io` in `std.process.Init`) installs a do-nothing
SIGPIPE handler, so its write returns `error.BrokenPipe` instead of the
signal ending it; zffmpeg reports that as status 4. A non-Zig child keeps
the default and is ended by SIGPIPE.

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

## Model values, state and boundaries

Most code that type-checks against 0.17 can still pick a C-shaped
representation: integer constants for a closed set, `anyerror` at a boundary,
a state enum beside nullable payloads. These are design tools, not
requirements. Not every number becomes an enum and not every struct becomes
a union; small direct code is often the right result. The rules against
premature registries and universal contexts still apply.

### Typed outcomes, numeric encoding at the boundary

A closed set of process statuses is an enum. Helpers return tags; `main`
converts once:

```zig
const ExitStatus = enum(u8) { ok = 0, usage = 1, invalid = 2, io = 4, limit = 5 };

pub fn main(init: std.process.Init) u8 {
    return @backingInt(run(init));
}

fn run(init: std.process.Init) ExitStatus {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return .limit;
    if (args.len != 2) return .usage;
    probePath(init.io, args[1]) catch |err| return exitStatus(err);
    return .ok;
}
```

`main` returns normally, so `defer` cleanup runs. Operations still return
their Zig errors; only the classifier turns them into statuses. Do not use
error numbers as exit codes. `zig/cli/probe.zig` is the project's instance.
A tool with its own status contract gets its own small enum
(`zig/testing/write_driver.zig`) instead of borrowing another's meanings.
Process tests in `build.zig` keep expected statuses as literals: an
independent oracle catches an accidental renumbering that an expectation
derived from the enum would hide.

`!void` remains right for a tool that promises no distinct failure codes, as
in the complete example at the end of this guide.

### Name the error domain at a boundary

```zig
const ParseError = error{ Truncated, InvalidHeader, IoFailure };
const ProbeError = ParseError || std.Io.File.OpenError || std.Io.File.Reader.Error;

fn exitStatus(err: ProbeError) ExitStatus {
    return switch (err) {
        error.Truncated, error.InvalidHeader => .invalid,
        error.SystemResources => .limit,
        else => .io, // the remaining platform I/O errors, by policy
    };
}
```

With `anyerror`, an unrelated error added later is classified silently. With
a named set, a new error source must be added to the set on purpose, and a
prong naming an error outside it is a compile error. zffprobe's classifier
found a dead `error.OutOfMemory` prong that way. A finite parameter type does
not require listing every OS error; an `else` fallback can be the policy.

`anyerror` and `anytype` keep specific uses: `std.testing.fuzz` callbacks
have the `anyerror!void` signature; formatting takes heterogeneous argument
tuples; `withReadCause` / `withWriteCause` in `zig/io/file.zig` preserve each
caller's own error set.

### State owns the payload it guarantees

A state enum beside nullable fields stores an invariant in two places:

```zig
state: enum { header, data, done } = .header,
format: ?Format = null, // non-null exactly when state == .data
data_left: u32 = 0,
// ...
const format = p.format.?;
```

A tagged union puts the payload in the state that guarantees it:

```zig
const State = union(enum) {
    header,
    data: struct { format: Format, data_left: u32 },
    done,
};

const data = switch (p.state) {
    .data => |*data| data,
    .header, .done => unreachable, // caller precondition
};
```

This removes invalid field combinations; it does not make fields private or
forbid bad call sequences, so keep the precondition policy explicit and do
not invent media errors for API misuse. Different formats need different
header payloads (WAV must remember a `fmt ` seen before `data`); do not merge
them into one shared state machine. The WAV and AU parsers still use the
separate-field form, which is part of their public API: changing it is a
contract change (port.md, notes.md, TODO.md and tests together).

### Empty, unavailable and insufficient are different results

An empty slice should mean one thing. If a read returns no samples both at
the end of data and when `output` cannot hold one frame, a caller looping
until `len == 0` must separately guarantee capacity. The small synchronous
fix is an error such as `error.OutputTooSmall` while unread data remains.
Do not build a resumable backpressure result before a consumer needs it.
The current parsers document the ambiguity (TODO.md T13a); changing it is a
contract change.

### Reuse follows working callers

The PCM kernels are already shared. When a second format repeats the same
transfer loop around them, extract a small helper that takes explicit slices,
a `*std.Io.Writer` and a `comptime` byte order. Keep header parsing, limits,
error precedence and finalization local to each format. Do not add a
registry, a heap-backed frame object or a universal codec context to remove a
few loops, and keep the path allocation-free.

### Test values, not their spelling

```zig
const Failure = enum { Truncated, InvalidHeader };

fn expectedError(failure: Failure) ParseError {
    return switch (failure) {
        .Truncated => error.Truncated,
        .InvalidHeader => error.InvalidHeader,
    };
}

try std.testing.expectError(expectedError(fixture.failure), parse(bytes));
```

The fixture enum stays independent of the parser, and the exhaustive switch
makes a missing mapping a compile error. Comparing `@tagName(failure)` with
`@errorName(err)` tests a spelling instead. Spelling is the contract only for
external output such as CLI diagnostics, which process runs check.

### Capture validated values

```zig
// Validity lives in an earlier branch the reader must find.
const container = if (args.len == 6) std.meta.stringToEnum(Container, args[1]) else null;
if (container == null) return usageError(io);
try write(container.?);

// The validated value has type Container.
if (args.len != 6) return usageError(io);
const container = std.meta.stringToEnum(Container, args[1]) orelse return usageError(io);
try write(container);
```

`.?` is not banned; it needs a documented invariant next to it.

### Patterns that stay

- Explicit `readInt` / `writeInt` over local arrays for wire layouts. A
  numeric wire constant does not need an enum.
- Counters and `while` loops in PCM kernels, extent accounting and bounded
  streaming loops.
- `inline for` over fixture tables and byte-order specializations: real
  compile-time work.
- `catch unreachable` beside a stated capacity proof; external input is still
  rejected explicitly, because ReleaseFast has no safety checks.

## Hostile input

Every rule here comes from a defect that passed all three test modes and the
FFmpeg comparison, and was found only by crafted input (the review of
2026-11-04). The green suites exercise valid streams; these rules are about
the bytes nobody wrote on purpose.

### Initialize into a local, then publish

A union field assignment sets the tag **before** the payload's initializer
runs. If the initializer fails, the union already claims a payload it never
got, and its `deinit` frees undefined memory:

```zig
// Do not write: on failure r.decoder is tagged .vorbis with garbage inside,
// and the deferred r.deinit() frees it.
r.decoder = .{ .vorbis = vorbis.Decoder.init(gpa, extradata) catch |err| return mapError(err) };

// Write: the long-lived state changes only after init succeeded.
const dec = vorbis.Decoder.init(gpa, extradata) catch |err| return mapError(err);
r.decoder = .{ .vorbis = dec };
```

The same holds for any owner stored in a field whose cleanup runs later. Do
not store a resource in `self` while its own `errdefer` is still armed: when
a later step fails, the `errdefer` frees it and `self.deinit` frees it again.
Finish every fallible step, then assign the fields, or clear the field in the
`errdefer`. Commit derived state (a channel count, a buffer length) only after
the allocation that backs it succeeded; otherwise the next call trusts a
count whose buffers do not exist.

### Size buffers for what writes them

A buffer sized exactly to a header value is only safe if nothing writes before
the check that bounds the write. FFmpeg often survives a late check because
`av_samples_get_buffer_size`, `AV_INPUT_BUFFER_PADDING_SIZE` or an aligned
allocation leaves room; the port must not assume it does. When porting a
function that writes and then validates (FLAC's warm-up samples are read
before `pred_order > samples` is refused), either allocate as FFmpeg does
(the same rounding) or move the check before the write, keeping FFmpeg's
error order observable.

Derive a write's element width from the value actually being written (the
active tag of a sample union), never from a second copy of the format kept
elsewhere. Two sources of truth for one format will disagree on damaged input.

### ReleaseFast removes every safety net

- `std.debug.assert` is a no-op in ReleaseFast. A contract a caller of a
  public function can break (a plane length, an output capacity) is checked
  with an error; asserts stay for invariants the module itself guarantees.
- `catch unreachable` and `else => unreachable` are undefined behavior when
  reached. Never put them on an error that input can cause, and never end a
  switch over `anyerror` with `else => unreachable`: a new error in a callee
  then compiles silently. Name the error set and switch exhaustively.
- `@intCast` of a value derived from input is a panic in safe builds and
  undefined behavior in ReleaseFast. Decide what the C does: if it truncates
  (`int x = int64_value`, `put_be24`), write `@truncate` with a comment; if it
  is a size, check it and return an error.
- Signed arithmetic that C performs on input (timestamps, interpolation,
  counters such as `header_count`) overflows on crafted streams. notes.md
  "Follow the reference build" says it wraps on the reference platform: write
  `+%` / `-%` / `*%` with the comment that rule asks for. This is not a size:
  sizes, offsets and allocation counts still use `std.math.add`/`mul`.

### C's numeric conversions: model the reference build

FFmpeg's C has no case for NaN, infinity or overflow in its float-to-integer
conversions; its output is whatever instruction the reference build
(Clang, Linux x86-64) emits. Zig's `@trunc`/`@intFromFloat` into an
integer is illegal behavior there (a panic in Debug, an arbitrary,
compiler-dependent value in ReleaseFast), so it is never a port of a C
conversion of an unproven value:

- `lrint`/`lrintf`/`llrint`, `int x = double`, `int16_t x = double` and
  `rint` go through `core/cconv.zig` (`lrintf`, `lrint`, `lrintfInt`,
  `cvttsd2si32`, `rint`), which checks NaN and the range and returns the
  reference build's value. Add a function there, with its instruction named,
  rather than a local copy.
- Read the parameter types of the C function that receives the result.
  `av_clip_int16(int)` and `av_clip_uint8(int)` take an `int`, so
  `av_clip_int16(lrintf(x))` narrows the 64-bit `long` to its low 32 bits
  before clipping: 65536.0 to s16 is -32768, not 32767. Clipping the wide
  value is a different function. An `int` accumulator (`int sum`) wraps
  where an `i64` would not; keep C's width.
- `@round` rounds ties away from zero and, without SSE4.1, is a
  compiler-rt call per value; C's `rint`/`lrint` round ties to even. Use
  `cconv`, never `@round` plus a fix-up.
- `std.math.clamp` (`@min`/`@max`) returns the non-NaN operand; C's
  `FFMIN`/`FFMAX` are comparisons, and `FFMAX(FFMIN(NaN, hi), lo)` is `lo`.
  Port the comparison, not the helper's name.
- Constants follow the C expression and its precedence:
  `FLAC_MAX_CHANNELS + FLAC_CHMODE_MID_SIDE << 4` is `(8 + 3) << 4`. Derive
  them from the same named enums, not a recomputed literal.
- Prove a property against the C, not against a second Zig model: compile
  the C expression with FFmpeg's flags (`config.mak`) and compare over every
  input when the domain allows it (all 2^32 floats take seconds), or over
  vectors the pinned library prints.

### Errors the C ignores

`try` propagates; the C often does not. Before `try`ing a call in a ported
loop, read what FFmpeg does with that return value: `avformat_find_stream_info`
ends its read-ahead on a read error (`eof_reached = 1`, break) and still opens
the file, so a `try` there refuses input FFmpeg accepts. Only `OutOfMemory`
and the errors FFmpeg itself propagates leave such a loop.

### std pitfalls verified on 0.17.0

| API | Pitfall | Use |
| --- | --- | --- |
| `std.Io.Reader.discardShort` / `discardAll` | `r.seek + n` is unchecked (`lib/std/Io/Reader.zig`): a skip near `maxInt(usize)` panics in safe builds and wraps backward in ReleaseFast. | `zig/io/skip.zig`'s `discardShort` / `discardAll` (`u64` lengths, steps of at most 1 GiB) for every untrusted length. |
| `std.math.ldexp` | Wrong for a zero mantissa (`ldexp(0, n)` returns a large value or inf once `n` exceeds the mantissa width) and rounds some subnormal ties up, in f32 and f64 (`ldexp(2.0, -1076)` is 2^-1074, not 0). | `libm.ldexp` (`zig/core/libm/ldexp.zig`, glibc's `__scalbn`); compute in f64 and `@floatCast` once where the C rounds once. |
| `std.fs.path.extension(".ogg")` | Returns `""` for a name that is only an extension; FFmpeg's `av_match_ext` uses `strrchr('.')`. | Match FFmpeg's rule explicitly where extensions decide behavior. |
| `Run.expectStdOutMatch("")` | Matches every output: `find(stdout, "")` is never null. | Assert real content, a size or a hash. |
| `ArrayList.toOwnedSlice`, `shrinkAndFree` | Can fail or allocate: `toOwnedSlice` allocates and copies when `remap` fails. A free-then-`try toOwnedSlice` replacement leaves a dangling owner. | Bind the result first; test with `FailingAllocator`'s `resize_fail_index`. |
| `std.math.clamp`, `@min`, `@max` | Return the non-NaN operand. | C's `FFMIN`/`FFMAX` as comparisons where NaN can reach them. |

When a std function's behavior matters to bit-exactness or safety, read its
source in `lib/std` before using it on input.

### Work proportional to the input, not to its claims

- A loop that steps once per unit of a header-declared count (frames, bytes,
  output samples) lets a 100-byte file claim hours of work. Compute counts in
  closed form, or cap them by the length actually available.
- `orderedRemove(0)` in a drain loop is quadratic. Use a head index or
  `std.Deque`.
- Re-copying a growing value on every append (joining repeated tag keys) is
  quadratic. Grow in place, or collect and join once.
- FFmpeg is the benchmark: when it is linear and the port is not, that is a
  defect even if both finish on the fixtures. Measure with a generated
  adversarial input in ReleaseFast.

### Cleanup on every path

- Replacing an owned field: build the replacement in a local, then free the
  old value and assign. A second SEEKTABLE block must not leak the first,
  but freeing first and then assigning `try make()` leaves a freed owner in
  the field when `make` fails, which `deinit` frees again (Ogg's metadata
  update did this: `toOwnedSlice` allocates after a failed remap).
- Freeing a buffer invalidates every slice into it, not only the ones about
  to be rebuilt. Reset the whole array of views (`planes = @splat(&.{})`)
  when its storage goes: a view left for a channel the stream dropped can
  "fit" again when a later header restores the channel, and is then written
  after its memory was freed (the Vorbis fuzz harness did this). Tests and
  fuzz callbacks follow this too; a harness bug makes a fuzz finding
  unattributable.
- One owner, one cleanup per path: never both an `errdefer` and a `defer`
  (or a `deinit` in the caller) for the same value. A branch that takes
  ownership of a parsed packet must not leave the outer `errdefer` armed.
- Save/restore pairs give each buffer one owner. If `restore` frees a
  snapshot, the caller's `errdefer` must not free it again.
- Test failure cleanup with `std.testing.allocator` and a writer or seeker
  that fails: a 16-byte fixed writer makes a header write fail.

### Tests that reach these paths

- A fuzz entry covers non-default limits too (unknown length, tag collection,
  seeking), not only `.{}`; the defaults hide the paths that opt in.
- Every parser, demuxer or decoder of untrusted bytes lands with a bounded
  `std.testing.fuzz` entry and a `std.testing.checkAllAllocationFailures`
  sweep in the same change (TODO.md G3), with remap failures enabled
  (`resize_fail_index`), destroying the object after every failure. Feed
  inputs that reach the replacement paths: two comment packets, a second
  metadata block, a seek, a reconfiguring header. Valid fixtures alone
  never free an owner twice. `hostile.checkAllocationFailuresWith(.both)`
  can fail with `NondeterministicMemoryUsage` on a long input in one mode
  only: whether a growing buffer's remap succeeds in place depends on the
  testing allocator's heap after the earlier runs, so the run that fails
  the last allocation may not make it. That is the harness, not the code
  under test (confirm that `.fail`, every remap failing, is deterministic);
  run that input with `.fail`.
- A path that only one tool reaches needs that tool's process case:
  zffprobe never builds a decoder, so a decoder refusal needs a
  `convert_cases` entry, not only a `probe_cases` one.
- `zig build test` in Debug is the run that turns most of these defects into
  panics; a ReleaseSafe-only check can pass by luck of the stack contents.
- A recorded difference in compare.py asserts the specific difference it
  records (an error name, a shifted timestamp with everything else equal); a
  table keyed only by fixture name counts any failure, including a crash of
  our own tool, as understood.
- In compare.py, compare two commands' outputs only after both succeeded
  (status 0) and produced the expected kind of output: two failures with
  empty stdout compare equal. A recorded refusal checks the exact status
  and the exact diagnostic together; a helper that accepts "any failure
  status" with the right spelling weakens the contract it checks.
  `check_oracle_predicates` fault-injects these predicates; extend it with
  each new one.
- An oracle vector set covers the inputs C leaves unspecified when the port
  picks the reference build's value: NaN, ±inf, products past 2^31 and 2^63,
  ties, options at their extremes (`dither_scale` 1000, a pan gain of 1e5).
  A conversion that only ever sees in-range samples cannot catch a wrong
  narrowing.

## Shape the port as Zig, not as C

FFmpeg is the behavioral reference, not the structural one. Its macros,
parallel tables, sentinels and copy-pasted variants exist for C's reasons.
The port keeps FFmpeg's observable behavior and should be smaller and harder
to misuse. Prefer a few understandable abstractions; do not add a
metaprogramming framework or optimize for line count alone.

### One implementation per FFmpeg function

When FFmpeg calls one shared function from several places, the port calls
one Zig implementation. A second copy drifts: FLAC kept its own Vorbis comment
parser beside `format/vorbiscomment.zig` (FFmpeg's `ff_vorbis_comment`) and it
diverged in three observable ways. Before writing a parser, decoder helper or
timing rule, search for an existing port of the same FFmpeg function. A
deliberate second copy needs a notes.md row with its retirement condition.

`format/flac.zig` still carries its own copy of libavformat's generic layer
(timestamps, read-ahead, seeking) beside `format/demux.zig`, which now serves
Ogg and MP3. New parsed formats go through `demux.Layer`; selecting a parser
is one enum in `demux.Setup`, not a new boolean per format.

### Share the data path, keep the headers local

The PCM containers (wav, au, aiff, caf, raw) each repeat the same data
reader (`readSamples`, `mapRead`, the `decodeToRaw` loop) and the same
frame-counting writer (`writeFrames`/`writeData`/`finish`). A defect in that
shape (a missing channel-count check, an unbounded skip) then appears five
times. Factor such a path into one struct that owns its validated invariants
(frame size, channels, bytes left) with `comptime` parameters for real static
variation (byte order, sample type), and keep header parsing, limits, error
precedence and finalization in each format ("Reuse follows working callers").

### State types that match the stream

- Per-stream codec state is one `union(enum)` keyed by the codec, not every
  codec's state side by side with the codec stored twice.
- Replace numeric sentinels and tri-state integers (`-1`/`-2` from a check
  function, `sid: *i32` with `-1`, `header: i32` with three meanings) with
  enums, optionals and tagged unions, and out-pointers with return values.
- A decoder either owns its output buffer or checks the caller's buffer with
  an error at its public boundary; a reconfiguring packet (a new identification
  header) must not silently outgrow a buffer sized at open.
- Split state that is saved and restored (Ogg's page state) from state that
  is not, so the snapshot is a copy plus one owned buffer.

### Derive dispatch from the type that already lists the cases

- A tagged union of filters, codecs or formats already enumerates the cases.
  Generate the per-case dispatch with `inline else`, `@unionInit` and
  `@typeInfo(T).@"union".field_names` / `field_types`, and have each payload
  declare its metadata, instead of maintaining parallel lists that must stay
  in step. Avoid `@hasDecl` probing: a missing declaration should be a
  compile error.
- Give each header type a method (`stream()`) instead of dispatching on
  `@TypeOf` over `anytype`.
- One function maps `audio.SampleFormat` to its Zig element type; kernels
  call it instead of carrying their own switch.
- Repetitive build data (process-case reports) can be generated with
  `std.fmt.comptimePrint` while the expected values stay hand-written.

Do not fold switches whose arms genuinely differ (the per-format arms in
`detect.zig` and `convert.zig`) into a descriptor table: the exhaustive
switch is the documented design and the clearest code there.

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

A decl literal needs the result type to reach it. `try` forwards it, so
`var c: Conversion = try .init(...)` compiles; `catch` does not, so
`var c: Conversion = .init(...) catch |err| ...` fails with "type
'@EnumLiteral()' not a function". Name the type there:
`var c = Conversion.init(...) catch |err| ...`.

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
- A corpus seed is read the way `testOne` reads the `Smith`: `smith.slice`
  takes a 4-byte little-endian length first, then `smith.value` calls take
  their bytes. Raw fixture bytes as a seed run as a garbage length and almost
  no input, and the entry silently tests nothing. Build seeds with
  `zig/testing/hostile.zig`'s `fuzzSeed(bytes, values)`, and keep a test that
  each seed reaches the parser (packets read, a stream opened).

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

A source file belongs to exactly one module. A test tool rooted in
`zig/testing/` cannot also `@import("fixtures.zig")` when the `av` module
already imports that file ("file exists in modules 'root' and 'av'"). Use
what `av` exports, or pass a directory with `addDirectoryArg` and read the
files at run time, as `zig/testing/zffmpeg_cases.zig` does.

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

This tool promises no distinct failure codes, so `!void` and an immediate
`std.process.exit(1)` for usage are enough. A product CLI with documented
statuses follows "Typed outcomes, numeric encoding at the boundary" instead.

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
