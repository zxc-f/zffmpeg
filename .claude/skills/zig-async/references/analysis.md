# Async and threads on Zig 0.17.0

This is the evidence behind [the zig-async skill](../SKILL.md), not
permission to add threads to zffmpeg. T53d is a synchronous scheduler. T59
is the first task that may spawn work, and only after a measurement of the
kind `zig-io` already records (Q1, E2E-C). CLAUDE.md wins over all three
skills.

The shape matches `zig-io`: a which-tool table, the contract from the
installed standard library, the projects that have actually used it, and a
checklist. The numbers below that are not from the zig-io analysis were not
measured here. Do not invent a speedup.

## When to read this analysis

Load it when the change spawns a task, waits, cancels, shares a queue or a
mutex, or ports `ffmpeg_sched.c`, `pthread_frame.c`, or `pthread_slice.c`.
Do not load it for a parser, a demuxer, or a file read. Those stay
synchronous `*std.Io.Reader` calls. `Io` in a function signature is not
async. It is the capability, the same way `Allocator` is not a heap strategy.

## Sources

Read the installed 0.17.0 `lib/std` first (`zig env` prints `lib_dir`). For
the std's own tests and the history, read `.references/zig` at tag `0.17.0`
(`git -C .references/zig show 0.17.0:lib/std/Io.zig`). Never `master`: the
zig-io analysis counted 223 `lib/std` files changed after the tag.

| Source | What it is good for | Where it is wrong for this pin |
| --- | --- | --- |
| `lib/std/Io.zig`, `Io/Threaded.zig`, `Io/File.zig` of Zig 0.17.0 | The contract below. Line numbers are from that tree. | The comments describe every backend, including ones that do not compile. |
| [0.16.0 release notes, I/O as an Interface](https://ziglang.org/download/0.16.0/release-notes.html#IO-as-an-Interface) and [Thread.Pool removed](https://ziglang.org/download/0.16.0/release-notes.html#ThreadPool-Removed) | Why `Io` is passed like `Allocator`, and why `Thread.Pool` / `Thread.Mutex` moved. | `Group.wait` in early notes is `Group.await` on 0.17.0. |
| [Andrew Kelley, Zig's New Async I/O (text), 2025-10-29](https://andrewkelley.me/post/zig-new-async-io-text-version.html) | Examples 0–10: asynchrony is not concurrency; `cancel` makes `defer` correct; a queue needs `concurrent`. The talk is [this recording](https://www.youtube.com/watch?v=mdOxIc0HM04). | Setup code. See "Call shapes that have moved" below. |
| [Loris Cro, asynchrony is not concurrency](https://kristoff.it/blog/asynchrony-is-not-concurrency/) | The distinction the API is named after. `io.async` is allowed to run the function inline. `io.concurrent` is the one that promises overlap. | Not a 0.17 tutorial. |
| [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html) | No I/O redesign. `std.Io.Semaphore.waitTimeout` was added. `DebugAllocator` was replaced by `SafeAllocator`. | Do not look here for an async chapter and then fill the gap from `master`. |
| [Ziggit, std.Io overview](https://ziggit.dev/t/std-io-overview/14994) (2026-04-17) and the threads it spawned: [groupAsync vs Group.async](https://ziggit.dev/t/groupasync-vs-group-async/15313), [fire-and-forget futures](https://ziggit.dev/t/fire-and-forgotten-std-io-future/15376), [cancel is not kill](https://ziggit.dev/t/canceling-awaited-group-causes-panic/17117), [stdout from an async function](https://ziggit.dev/t/writing-to-stdout-from-async-function/15623) | The footguns people hit after 0.16 shipped: tasks that never start, futures that leak, cancel from the wrong task, `error.Canceled` discarded. Andrew's reply on the fire-and-forget thread (2026-05-07) is the rule for a long-lived group. | Several snippets are 0.16-dev (`group.wait`, `Threaded.init(gpa)` with one argument). |
| [learningzig.org, Async I/O](https://learningzig.org/lessons/11-async-io) | A clear statement that the keywords are gone and `Io.Evented` is not for application code. | 0.16 call shapes. |
| zig-cookbook after [PR 122](https://github.com/zigcc/zig-cookbook/pull/122) (`assets/src/07-03.zig`, `io-tasks.zig`, `io-sync.zig`) | `Thread.Pool` replaced by `Io.Group`; `Thread.Mutex` replaced by `Io.Mutex`. | 0.16. Check every call against this file before copying. |
| ZLS, the revision pinned in the zig-io analysis (`c275dd2`) | A long-running tool that starts `Io.Group` tasks and cancels them at shutdown. Their 0.15→0.16 migration returned `error.Canceled` instead of ignoring it, and passed `argv0` into `Threaded.init`. | ZLS `master` tracks 0.17-dev, not 0.17.0. Do not copy it. |
| zio (`.references/zio`, revision pinned in the zig-io analysis) | Contract tests for `std.Io`: a cancel of a group task that ran inline still reaches the caller. Read those tests when a rule here is unclear. | Not a dependency. Its native API is not `std.Io`. notes.md already declined it: it links libc and it targets many network streams, which this port does not have. |
| libxev | A callback loop over `std.posix`. | Not `std.Io`. Declined in notes.md. |
| TigerBeetle, and the Zedis write-up that cites it | Single-threaded io_uring, outside `std.Io`. | Not a pattern for this port. Do not import an event loop to look like a database. |
| FFmpeg `fftools/ffmpeg_sched.c`, `libavcodec/pthread_frame.c`, `pthread_slice.c` at the pinned revision | The *behavior* T59 may have to match: a thread per component, queues, frame threads on the FLAC and ALAC decoders among the codecs this port has. | The mechanism. `pthread_create` and a queue of 2 are not the Zig API. |
| This repo's zig-io analysis, Q1 and E2E-C | The only measurements of a queue and of FFmpeg's threads against this code. | A decision to add threads without repeating the measurement on the real codec. |

## The model

Zig has no `async` / `await` keywords. They were removed because they were
tied to one coroutine implementation and split the library world into two
colors of function. 0.16 put the choice in a value, `std.Io`, passed like an
`Allocator`. The same function runs on `Io.Threaded` today. An evented
backend would be a different value, not a different function. That backend
does not compile in 0.17.0. Write code that *could* run on it; do not pretend
it does.

Two words the API keeps apart, from Andrew's post and from Loris Cro:

- **Asynchrony** is "the caller may continue without this function having
  returned." `io.async` expresses that. An implementation may run the
  function immediately, on the caller, before `async` returns. That is still
  asynchrony. It is not a bug in the backend.
- **Concurrency** is "this function makes progress while the caller makes
  progress." `io.concurrent` expresses that. It can fail with
  `error.ConcurrencyUnavailable`. On `Io.Threaded` that means the pool cannot
  take another task (`-fsingle-threaded`, or `concurrent_limit` exhausted).

`std.process.Init` hands the program an `Io.Threaded`. Library code takes
`std.Io` and does not construct a second backend. Tests use `std.testing.io`,
which the test runner initializes with `Io.Threaded.init` and the default
limits (`lib/compiler/test_runner.zig`). A test that leaks a `Future` fails
the allocator check. A test that needs overlap must call `concurrent` and
handle `ConcurrencyUnavailable`, or it deadlocks the moment the pool runs
the callee inline.

`Io.Evented` (`Io.Uring` on Linux) is a proof of concept in the 0.16 notes
and a compile error on this pin. Do not spend a change making it compile.
Third-party runtimes (zio, libxev) are references, not dependencies.

## Which tool

| Situation | Use | Why, from the 0.17.0 std |
| --- | --- | --- |
| A call that may overlap the caller, and is correct if it does not | `io.async(function, .{args})` | `Io.zig:2514`. Infallible. The function may run before `async` returns. When `async` returns, the function has been called or a unit of concurrency has been assigned. |
| A producer and a consumer, or anything that blocks on another task | `try io.concurrent(...)` | `Io.zig:2558`. Andrew's examples 8–10: `async` plus an unbuffered queue deadlocks when the pool has no spare worker, because the consumer runs and waits before the producer is started. `concurrent` oversubscribes or returns `ConcurrencyUnavailable`. |
| Many independent tasks, no per-task result | `var group: std.Io.Group = .init;` then `group.concurrent` | `Io.zig:1328`. Resources of a finished task are released when that task returns, so a long-lived group is not a leak by itself. `group.await` returns only `Cancelable!void`. |
| Fire-and-forget until process shutdown | `Group.concurrent` on a group stored for the life of `main`, `defer group.cancel(io)` | Andrew, Ziggit 2026-05-07. `Group.async` is the wrong call: the function is not guaranteed to run until `await` or `cancel` (`Io.zig:1361`). |
| A result the caller needs | `io.async` / `io.concurrent` returning a `Future(Result)`, then `await` | `Group.async` erases the result. Its wrapper is `catch {}` (`Io.zig:1368`). A decode error written only as the task's return value is discarded. |
| Handoff of frames or packets | `Io.Queue(T).init(caller_buffer)` , `put` / `get` with a minimum count | `Io.zig:2381`. Bounded, many-producer, many-consumer. Close the queue to unblock waiters (`error.Closed`). Batches, not one small packet: zig-io Q1, a handoff of microseconds, 4 KiB packets lost to serial. |
| Timeout against a task that has no timeout argument | `concurrent` of the work and `concurrent` of `io.sleep`, then `Select`; or `Io.Semaphore.waitTimeout` where a semaphore is the real wait | Most file operations have no timeout parameter. `Select.async` has `Group.async`'s weak start guarantee, so a select that only `async`s can fail to start the side it is waiting on. 0.17 added `Semaphore.waitTimeout`. |
| Mutual exclusion that must be cancelable | `Io.Mutex`, `Io.Condition`, `Io.Event`, `Io.RwLock`, `Io.Semaphore` | 0.16 notes: a `Thread.Mutex` held around an `Io` task does not observe cancellation and will not move to an evented backend. Lock-free atomics do not need `Io`. |
| A task that must run beside the caller, and the pool cannot take it | Handle `error.ConcurrencyUnavailable` | Fail the operation, or close queues and cancel/join any started tasks before switching the whole operation to its synchronous pipeline at a safe restart point. Calling a queue waiter inline can deadlock. A single-threaded build hits this on every `concurrent`. |
| The backend | `init.io` from `std.process.Init` | `Io.Threaded`. Do not construct another one in library code. `init_single_threaded` makes `concurrent` fail and makes cancel a no-op (`Threaded.zig:1672`). |
| Evented / io_uring / kqueue | Nothing in this release | Does not compile. See zig-io. |

`Io.Threaded` limits (`Threaded.zig:1577`):

- `async_limit` defaults to one less than the logical CPU count. Past that,
  `Io.async` runs the task on the caller. That is the inline deadlock, on
  purpose.
- `concurrent_limit` defaults to unlimited. Past it, `concurrent` returns
  `error.ConcurrencyUnavailable`. This is how a queue pair stays correct
  when `async_limit` is already full: `concurrent` may spawn past the
  async pool.
- `stack_size` defaults to `std.Thread.SpawnConfig.default_stack_size`,
  16 MiB per worker (`Thread.zig:307`). Five workers are 80 MiB of stacks
  before any frame buffer. Do not spawn a thread per packet. Do not put a
  multi-megabyte scratch array on a worker stack without counting it.
  FFmpeg's frame threads use smaller stacks; copying 16 MiB blindly is the
  other mistake. Measure RSS (zig-io's `bench/rss.py`) if T59 changes this.

There is no `cpu_count` field to assign. Andrew's `threaded.cpu_count = 1`
does not compile. To force the one-worker deadlock on 0.17.0, set
`async_limit = .nothing` and use `async`, or build `-fsingle-threaded` and
watch `concurrent` fail.

## Cancellation

`Future.cancel` is `await` plus a request that the task's next *cancellation
point* return `error.Canceled` (`Io.zig:1301`). A cancellation point is a
call into `Io` whose error set includes `error.Canceled`. One shot: later
points do not see it again unless the task calls `Io.recancel`. Ignoring
`error.Canceled` makes the task uncancellable. ZLS's migration fixed exactly
that.

`cancel` blocks. It is not a signal. It waits until the task returns, so the
task can free what it owns. Forcible kill is not the default and should not
be added. `await` and `cancel` are idempotent with each other, and not
threadsafe (`Io.zig:1310`, `1318`). The task that created the future is the
one that awaits or cancels it. A worker that cancels the group it is running
in deadlocks or panics (Ziggit, 2026-08). Register cleanup on the owner
before the next fallible operation. Its shape depends on the task's result:
`Future.cancel` returns `Result`, just like `Future.await`. A `void` task
uses `defer future.cancel(io)`; an `E!void` task can use
`defer future.cancel(io) catch {}`. An `E!T` task must handle its payload
as well as its error, as [the skill's scalar example](../SKILL.md#cancellation)
does. `catch {}` alone cannot turn a non-`void` payload into `void`.

### Result ownership

Both waits are idempotent: after `await` returns a slice, `cancel` returns
that same slice, not a second allocation. Once a successful result has
been taken, its new owner frees it. If an early error occurs before the
result is taken, cancellation cleanup must wait and free any successful
result the worker produced, even if it finished before cancellation.
For a worker `load` returning an owned `E![]u8`:

```zig
fn loadOwned(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var future = io.async(load, .{gpa});
    var result_taken = false;
    defer {
        if (!result_taken) {
            if (future.cancel(io)) |bytes| {
                gpa.free(bytes);
            } else |_| {}
        }
    }
    const bytes = try future.await(io);
    result_taken = true;
    return bytes;
}
```

The caller owns the returned slice. Any later fallible step in this function
needs a separate `errdefer gpa.free(bytes)` after taking ownership. The
cancellation cleanup must remain disarmed once ownership has transferred.
An unowned scalar result may simply be discarded in the successful capture;
there is nothing to free.

Andrew's example 4 is the leak: `try a.await` returns, `defer` of the
allocator runs, `b` was never awaited, the implementation's closure is still
allocated. Example 6 is the fix. In this repo that leak fails
`std.testing.allocator`, because `std.testing.io` allocates futures from it.

`Group.cancel` requests cancellation of every member and waits
(`Io.zig:1414`). Same rule: only the owner calls it. `defer group.cancel(io)`
is how a server loop shuts down. Do not `await` the group from inside one of
its tasks.

`error.Canceled` on a file read is not a short read. It arrives as
`error.ReadFailed` on the `*std.Io.Reader`, with the cause in the adapter's
`.err`. `withReadCause` already maps it. A new worker must do the same, and
must propagate `Canceled` rather than retry.

A CPU-bound decoder does not see cancellation until its next `Io` call.
FFmpeg polls `ff_check_interrupt` before every transfer. Do not add a poll
to a per-sample loop to imitate that. T59 decides the points: between frames
is the likely one, and it has to be measured, not assumed. `CancelProtection`
exists for a region that must finish (`Io.zig:1443`). It is rare. A header
rewrite that has already seeked is the kind of region that might need it; a
whole decode is not.

`Threaded.init` installs a do-nothing `SIGPIPE` handler so a write to a
closed pipe returns `error.BrokenPipe` instead of killing the process. A
worker inherits that. Do not install another handler. The guide already
records this for the CLI child; it applies to pool threads too.

## Deadlocks

These are the ones the std documents or that people have hit. The skill's
checklist applies to each of these patterns.

1. **Producer and consumer both `async`.** The consumer runs inline, blocks
   on an empty queue, and the producer never starts. Andrew's examples 8–10.
   Both sides `concurrent`, or the consumer `concurrent` and started first.
   zig-io Q1 is this shape with a measured cost even when it does not deadlock.
2. **`Group.async` and no `await` / `cancel`.** The std does not promise the
   task runs. A scheduler loop that only adds tasks leaks the group's
   resources and may never decode anything. `Group.concurrent`, and cancel
   at shutdown.
3. **`Select` on tasks started with `async`.** `Select.await` waits on its
   queue; it does not call `Group.await`. If the implementation has not
   started the tasks, the select waits for work that was never queued
   (Ziggit, `Io.Select.async` semantics). Start the arms with `concurrent`.
4. **`await` or `cancel` from inside the group.** The owner is blocked in
   the group, and the group cannot finish because the owner is one of its
   tasks. Synchronize with `Io.Event`, `Io.Condition`, or `Io.Queue` instead.
5. **`Thread.Mutex` around a queue wait.** The mutex is not a cancellation
   point. A cancel during the wait does not land until the lock is released,
   and on a future evented backend the wait does not yield. Use `Io.Queue`,
   which already blocks in `Io`.
6. **Shared `File.Reader` across tasks.** The reader is a cursor plus a
   buffer. Two tasks calling `read` on it is a data race, positional mode
   or not. Positional reads are threadsafe at the *descriptor* (the std
   comment on `File.reader`: the global seek offset is not used). The
   `Reader` object is still one cursor. One owner task per reader. Hand
   bytes across a queue, not the reader.
7. **Stdout from several tasks through one `File.Writer`.** Same race, plus
   interleaved halves of a line. ZLS and the Ziggit stdout thread both hit
   this. Lock with `io.lockStderr` for diagnostics, or give each worker its
   own buffer and write whole messages. Probe output stays on the owner
   task. Tests still must not print to stdout (`zig build test` uses it as
   its protocol).
8. **Synchronous fallback for a queue waiter.** If starting the consumer
   returns `ConcurrencyUnavailable`, calling it inline blocks on an empty
   queue before the producer can start. Propagate the error, or close queues
   and cancel/join any tasks already started before entering the complete
   synchronous pipeline at a safe restart point. Do not rerun pipeline work
   that already wrote output or consumed input unless it can be restarted.

## Call shapes that have moved

Andrew's post is the design. These are the 0.17.0 shapes. Copying the post
into `zig/` does not compile.

| October 2025 post | Zig 0.17.0 |
| --- | --- |
| `var debug_allocator: std.heap.DebugAllocator(.{}) = .init` | Deprecated. A program uses `init.gpa`. Tests use `std.testing.allocator`. `SafeAllocator` is the replacement if a tool must build its own. |
| `var threaded: std.Io.Threaded = .init(gpa)` | `var threaded: std.Io.Threaded = .init(gpa, .{})`. Library code does not do this; it takes `std.Io`. |
| `threaded.cpu_count = 1` | No such field. `async_limit` / `concurrent_limit` on `InitOptions`, or `setAsyncLimit` once the instance is in use. |
| `io.sleep(.fromSeconds(1), .awake)` | Still the method shape: `try io.sleep(.fromSeconds(1), .awake)`. `Duration.fromSeconds` and `Clock.awake` exist (`Io.zig:1105`, `871`). Media clocks are still not this. PCM duration is a sample count and a rate. |
| `group.wait(io)` in early 0.16-dev issues | `group.await(io)` or `group.cancel(io)`. |
| `std.Thread.Pool` | Removed. The migration in the 0.16 notes is `Io.Group`, and only when the tasks do not need to rendezvous with the caller. If they do, `async` is the wrong tool; read `concurrent`. |
| A future dropped on the floor | Leak. The implementation allocates the closure. `defer cancel`. |

`init` of `Threaded` also wants `argv0` and `environ` if the process will
spawn children or resolve its own executable. `std.process.Init` already
filled those in. A second `Threaded` in a test that does not spawn can use
`.{}`.

## What FFmpeg does, and what this port should do

FFmpeg's program runs every demuxer, decoder, filtergraph, encoder and muxer
on its own thread (`fftools/ffmpeg_sched.c`), joined by queues of 2 packets
or 2 frames, and pauses a demuxer that runs more than 100 ms ahead. Among
the codecs zffmpeg has ported, the FLAC and ALAC decoders declare frame
threads (`libavcodec/flacdec.c:829`, `libavcodec/alac.c:629` at
`5d5a38a7e46be296eab75982c0986054f731e19e`). Vorbis, Opus, MPEG audio,
PCM and the FLAC encoder do not. zig-io E2E-C: those threads turn about the
same CPU time into 2–5×
less wall time on 16 threads, and they lose on one core. Q1: a queue of
small packets loses to the serial code, because the handoff is microseconds.

So the mapping is not "one `pthread_create` becomes one `io.async`".

| FFmpeg | Here, when T59 is allowed to start | Not before |
| --- | --- | --- |
| Thread per component | `io.concurrent` per stage that is heavier than a handoff, joined by `Io.Queue` of *batches* of frames. The consumer is started with `concurrent` before it can block the producer. | T53d's scheduler is bounded queues and cancellation with synchronous calls. zig-io already says this. A queue does not require a thread. |
| Queue depth 2 | A starting point to measure, not a constant to copy. Q1 says depth does not save a 4 KiB packet. Measure wall time and CPU time, on one core and on all, with the real decoder in place of Q1's hash. | |
| `ff_check_interrupt` before every `avio` transfer | Cancellation points inside `std.Io`. Map `error.Canceled` from the adapter's `.err`. Between frames, one explicit check if a frame is long enough that a user would notice. | A per-sample poll. |
| `pthread_frame` / `pthread_slice` | Only a codec that has the slice or frame structure, and only after T57 says the scalar code is the thing to parallelize. FFmpeg declares frame threading for both FLAC and ALAC decode among current ports. | Threading a codec whose hot path is still a parser (zig-io: FLAC decode spends about half its instructions in the parser). |
| 9 threads and ~250k `futex` calls on a PCM copy | The thing E2E measured as pure overhead. PCM stays one thread. | |

Output must stay byte-identical for 1 to N workers (TODO.md T59). A race that
depends on queue order will fail that, so the queue carries ordered batches
and the muxer still writes in timestamp order. Cancellation stress is part
of T59's done condition, in ReleaseSafe, where the overflow and the race
are still checked.

## What not to import

- The keywords `async` and `await`, `@frame`, `@frameSize`. They are not
  coming back as syntax.
- `std.Thread.Pool`, `std.Thread.spawn` for pipeline stages, `std.Thread.Mutex`
  / `Condition` / `ResetEvent` / `WaitGroup` next to an `Io` task.
- `std.Io.Evented`, `Io.Uring`, a hand-rolled `io_uring` loop, zio, libxev.
- `std.heap.DebugAllocator` and `Threaded.init(gpa)` from the 2025 post.
- A global `Io`. The value comes from `main`'s `init` and is passed down.
  `init.environ_map` is not threadsafe; workers do not read it.
- `threadlocal` for anything a future evented backend would have to preserve.
  A worker on `Io.Threaded` is an OS thread today. That is not the contract.
- Fire-and-forget via a discarded `Future`. The leak checker will catch it
  in tests and leak in the tool.

## Projects, what to copy

- **The std, at 0.17.0.** The tables above. When a comment and this file
  disagree, the comment wins and this file is fixed.
- **Andrew's examples 4–10**, rewritten with `init.io` or
  `Threaded.init(gpa, .{})`, as the pictures of cancel and of
  `concurrent`. Not as code to paste into a demuxer.
- **ZLS at the pinned revision.** A group that outlives a request and is
  canceled at shutdown. Propagate `Canceled`. Pass `argv0` if constructing
  a `Threaded` (the CLI does not; `process.Init` did).
- **zio's contract tests**, if a cancel-during-inline-task question comes up
  in T59. Do not link the library.
- **zig-cookbook's 0.16 group example**, only after checking it against the
  table above. It is the right *migration story* (pool → group) and the wrong
  vintage.
- **zigimg**, not for async. It is in this file only so a reader does not
  treat "a Zig project that uses `std.Io`" as a concurrency reference. It is
  a synchronous reader that correctly borrows `&interface`.

## Checklist before any concurrent change

- The change is T59, or it is T53d and the queues are synchronous. A thread
  in an earlier task is a no.
- The synchronous version exists and is what one core runs. `concurrent`
  failure fails the operation, or closes queues and cancels/joins any started
  tasks before switching the whole pipeline to that version at a safe restart
  point. A queue waiter is never called inline as a per-task fallback.
- Producer and consumer use `concurrent`, consumer started so it cannot
  block the producer, queue holds batches, queue is closed on every exit
  path including cancel.
- Every `Future` and every `Group` is `await`ed or `cancel`ed by its owner.
  Cleanup is registered before the next fallible operation and handles the
  task's exact result type. Free an owned result there only if it has not
  already been taken; after a successful `await`, its new owner handles cleanup.
- A task's error is stored where the owner can see it. It is not the return
  value of a `Group` task.
- `error.Canceled` is propagated. The file adapter's `.err` is what a read
  failure is. `BrokenPipe` on a worker is an I/O error, not a signal.
- No `Thread.Mutex`, no shared `Reader` or `Writer`, no `threadlocal`.
- No second `Io` implementation. `init.io` only.
- Wall time and CPU time, one core and all cores, against the pinned FFmpeg
  and the assembly build, recorded in the zig-io analysis the same way Q1
  and E2E-C were. A gain in wall time that costs more CPU than it saves is
  not a win on a busy machine (E2E-C already showed that direction).
- Output is identical for 1 and N workers. A test cancels mid-stream in
  ReleaseSafe and checks that files this run created are removed and that
  no future is leaked.
- Stack size and worker count are written down. The default is 16 MiB times
  the pool, which is enough to hide a leak of address space.

## Open

- Q1's work is a byte hash. T59's first measurement replaces that with the
  real decoder and the real packet sizes, on one core and on all. Until
  that number exists, the pipeline stays synchronous. zig-io conclusion 7
  already says this; this file does not weaken it.
- `Io.Evented` on a later toolchain. The zig-io reproduce notes say how to
  try it (`--zig-lib-dir` of a clone at a tag, an `evented` bench command).
  Not a dependency, and not a reason to write a second code path.
- Worker stack size for a codec with large scratch arrays. Unknown until
  T59 profiles it. Do not guess 16 MiB is either necessary or cheap.
- Whether a cancel check between frames is enough for a multi-second FLAC
  frame. Unknown until someone times a frame. The default is the next `Io`
  call, which is the packet read.
