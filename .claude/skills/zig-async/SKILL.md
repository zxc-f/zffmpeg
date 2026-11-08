---
name: zig-async
description: How to spawn, wait, cancel, or share a queue or a lock in zffmpeg on Zig 0.17.0's std.Io. Use it whenever a change starts a task, awaits or cancels one, uses Io.Group, Io.Queue, Io.Mutex, or Io.Select, or ports FFmpeg's scheduler or frame threading, including a question about async or await in Zig 0.17. Use it together with zig-0-17 and zig-io. Do not use it for ordinary file I/O, and do not add a thread before T59.
---

# Tasks and cancellation in zffmpeg

Zig has no `async` / `await` keywords. Concurrency is a value, `std.Io`,
passed like an `Allocator`. This skill says which call to use, and which
call deadlocks. Whether a thread is worth the handoff is `zig-io` (Q1,
E2E-C). The language rules are `zig-0-17`. CLAUDE.md wins over all three.

[references/analysis.md](references/analysis.md) has the 0.17.0 contract
(file and line), the sources, the call shapes that moved since Andrew
Kelley's October 2025 post, and the FFmpeg mapping. Do not copy that post's
setup code. Do not copy a 0.16 cookbook.

## Workflow

1. Load `zig-0-17` and `zig-io` too. If the line is a reader, a writer, a
   buffer size, or a skip, stop and use `zig-io`.
2. If the change is not T59, do not spawn. T53d's scheduler is bounded
   queues and cancellation with the synchronous calls that exist today. A
   queue does not require a thread.
3. Read the row below. Read the analysis section it names before deviating.
4. The installed `lib/std` is the 0.17.0 source (`zig env` prints `lib_dir`).
   For the std's tests and history, read `.references/zig` at tag `0.17.0`,
   never `master`.
5. Run the checklist on every changed hunk. A claim that threads are faster
   needs the measurement `zig-io` already requires, recorded in its analysis.

## Which tool

| Situation | Use | Why |
| --- | --- | --- |
| Nothing concurrent yet | The synchronous call | T53d. T59 is the first task that may spawn, and only after a measurement. |
| A call that may overlap the caller, and is correct if it does not | `io.async(function, .{args})` | Infallible. May run before `async` returns (`Io.zig:2514`). When it returns, the function has been called or a unit of concurrency has been assigned. |
| A producer and a consumer, or anything that blocks on another task | `try io.concurrent(...)` | `async` plus a queue deadlocks when the pool runs the waiter inline (Andrew's examples 8–10). `concurrent` overlaps or returns `error.ConcurrencyUnavailable` (`Io.zig:2558`). |
| Many independent tasks, no per-task result | `var group: std.Io.Group = .init` then `group.concurrent` | `Group.await` returns only `Cancelable!void`. `Group.async`'s wrapper discards the task error (`Io.zig:1368`). |
| Fire-and-forget until shutdown | `Group.concurrent` on a group that lives as long as `main`, `defer group.cancel(io)` | Andrew, Ziggit 2026-05-07. `Group.async` is not guaranteed to run until `await` or `cancel` (`Io.zig:1361`). |
| A result the caller needs | `io.concurrent` (or `io.async`) returning a `Future`, then `await` | A `Group` task cannot return the result. Store it where the owner can see it. |
| Handoff of frames or packets | `Io.Queue(T).init(caller_buffer)`, `put` / `get` with a minimum count, `close` on every exit | Bounded. Batches, not one small packet (zig-io Q1). Close unblocks waiters with `error.Closed`. |
| A timeout | `concurrent` of the work and `concurrent` of `io.sleep`, then `Select`; or `Io.Semaphore.waitTimeout` | Most file operations have no timeout. `Select.async` has `Group.async`'s weak start guarantee. |
| A lock that must be cancelable | `Io.Mutex`, `Io.Condition`, `Io.Event`, `Io.RwLock`, `Io.Semaphore` | A `Thread.Mutex` does not observe cancellation. Lock-free atomics do not need `Io`. |
| The pool cannot take the task | Handle `error.ConcurrencyUnavailable` | Fall back to the synchronous call, or fail. Do not spin. `-fsingle-threaded` hits this on every `concurrent`. |
| The backend | `init.io` from `std.process.Init` | `Io.Threaded`. Library code does not construct a second one. `Io.Evented` does not compile (zig-io). |
| Evented / io_uring / zio / libxev | Nothing | References, not dependencies (notes.md). |

`Io.Threaded` limits (`Threaded.zig:1577`): `async_limit` defaults to one
less than the CPU count, and past it `async` runs on the caller.
`concurrent_limit` defaults to unlimited, and past it `concurrent` fails.
`stack_size` defaults to 16 MiB per worker. Five workers are 80 MiB of
stacks before any frame buffer. There is no `cpu_count` field to assign.

## Deadlocks

1. **Producer and consumer both `async`.** The consumer runs inline, blocks
   on an empty queue, and the producer never starts. Both sides
   `concurrent`, consumer started so it cannot block the producer.
2. **`Group.async` and no `await` or `cancel`.** The task may never run, and
   the group's resources leak. `Group.concurrent`, cancel at shutdown.
3. **`Select` on tasks started with `async`.** `Select.await` does not start
   them. Start the arms with `concurrent`.
4. **`await` or `cancel` from inside the group.** The owner is one of the
   tasks it is waiting for. Synchronize with `Io.Event` or `Io.Queue`.
5. **`Thread.Mutex` around a queue wait.** Not a cancellation point. Use
   `Io.Queue`.
6. **Two tasks reading one `File.Reader`, or writing one `File.Writer`.**
   Positional mode is threadsafe at the descriptor, not at the cursor.
   One owner task per reader. Hand bytes across a queue, not the reader.
7. **Several tasks printing through one stdout writer.** Interleaved halves
   of a line, and a data race. Diagnostics use `io.lockStderr`. Probe output
   stays on the owner task. Tests still must not print to stdout.

## Cancellation

`Future.cancel` is `await` plus a request that the next cancellation point
return `error.Canceled` (`Io.zig:1301`). One shot: later points do not see
it unless the task calls `Io.recancel`. Ignoring `error.Canceled` makes the
task uncancellable. `cancel` blocks until the task returns. It is not a
kill, and it is not threadsafe. The task that created the future is the one
that awaits or cancels it.

`defer future.cancel(io) catch {}` on the owner, then `try future.await(io)`,
is what keeps `try` from skipping the second wait. Andrew's example 4 is the
leak: the first `try await` returns, the second future is never awaited, and
the implementation's closure is still allocated. `std.testing.io` allocates
that closure from `std.testing.allocator`, so the leak fails the test.

A file read surfaces cancel as `error.ReadFailed` with the cause in the
adapter's `.err`. Propagate it. Do not retry. A CPU-bound decoder does not
see cancel until its next `Io` call. Do not poll per sample to imitate
`ff_check_interrupt`. Between frames is the point T59 may add, and it has
to be measured.

`Threaded.init` installs a do-nothing `SIGPIPE` handler. A worker write to a
closed pipe returns `error.BrokenPipe`. Do not install another handler.

## Checklist before any concurrent change

- The change is T59, or it is T53d and the queues are synchronous.
- The synchronous version exists and is what one core runs. `concurrent`
  failure falls back to it or fails the operation.
- Producer and consumer use `concurrent`. The queue holds batches and is
  closed on every exit path, including cancel.
- Every `Future` and every `Group` is `await`ed or `cancel`ed by its owner.
  `defer cancel` comes first. A non-`void` result is freed in that `defer`.
- A task's error is stored where the owner can see it. It is not the return
  value of a `Group` task.
- `error.Canceled` is propagated. A read failure is the adapter's `.err`.
- No `Thread.Mutex`, no shared `Reader` or `Writer`, no `threadlocal`, no
  second `Io` implementation.
- Wall time and CPU time, one core and all cores, against the pinned FFmpeg
  and the assembly build, recorded the way zig-io records Q1 and E2E-C.
- Output is identical for 1 and N workers. A ReleaseSafe test cancels
  mid-stream, checks that files this run created are removed, and checks
  that no future is leaked.
- Stack size and worker count are written down. The default is 16 MiB times
  the pool.

## What not to import

- The keywords `async` and `await`, `@frame`, `@frameSize`.
- `std.Thread.Pool`, `std.Thread.spawn` for a pipeline stage, `Thread.Mutex`
  / `Condition` / `ResetEvent` / `WaitGroup` next to an `Io` task.
- `std.Io.Evented`, `Io.Uring`, zio, libxev.
- `DebugAllocator` and `Threaded.init(gpa)` from the October 2025 post.
  `init` takes `(gpa, options)`. A program uses `init.io`. Tests use
  `std.testing.io`.
- A discarded `Future`. The leak checker catches it in tests and the tool
  leaks it.
- `threaded.cpu_count = 1`. That field does not exist. The one-worker
  deadlock on 0.17.0 is `async_limit = .nothing` plus `async`, or
  `-fsingle-threaded` plus `concurrent`.
