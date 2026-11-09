# Review: skill changes since `0c27ba76077998b99ba45c4b6047593cc3c40530`

Commits: `d0d862d` skill, `db01df3` skill2, `5fb81ac` skill3, `9c1e05e` x, `355ed43` z.

Files: new `ffmpeg-c-semantics`, `ffmpeg-oracle`, `media-pipeline`, and `zig-async`; edits to `zig-0-17` and `zig-io`.

The split is sound, and most of the new line citations match Zig 0.17.0 and this tree. The three domain skills are in good shape. `zig-async` has a few claims that will not compile or that mis-state how a failure actually happens.

## What holds up

The boundaries are explicit and mostly non-overlapping: language in `zig-0-17`, adapter choice in `zig-io`, spawn/wait/cancel in `zig-async`, C results in `ffmpeg-c-semantics`, evidence in `ffmpeg-oracle`, ownership and time in `media-pipeline`. Each one says what it does not authorize.

Checked against the installed Zig 0.17.0 std and this tree:

- `Io.async` / `Io.concurrent`, `Group.async` / `Group.concurrent` / `Group.await`, `Future.cancel` / `Future.await`, `CancelProtection`, `Queue`, and `Threaded.InitOptions` are at the cited lines. `async_limit` defaults to one less than the CPU count, `concurrent_limit` is unlimited, `stack_size` is 16 MiB, and there is no `cpu_count` field.
- `-fsingle-threaded` makes `concurrent` return `error.ConcurrencyUnavailable`. `Threaded.init` installs a do-nothing `SIGPIPE` handler. `Writer.end` calls `setLength` only in positional mode. `file.reader` on an unseekable file returns 0 from `readVecPositional` and then switches to streaming. `discardShort` really is `seek + n` with no overflow check.
- `cconv.lrintfInt`, `cconv.cvttsd2si32`, `stage.check`, `delay_stage.zig`, `hostile.checkAll` / `fuzzSeed` / `mutationSmoke`, and `compare.py`'s `refusal_name`, `tool_error`, `same_decode_refusal`, and `check_oracle_predicates` all exist and match the procedures.
- FLAC and ALAC both declare `AV_CODEC_CAP_FRAME_THREADS`, at `flacdec.c:829` and `alac.c:629`. The old "FLAC only" sentence was wrong; this correction is right.
- The guide no longer teaches `peek` into a slice parser. `zig/examples/io_patterns.zig` is registered in `build.zig` and matches the replacement claims.
- Gate names, the FFmpeg pin, and the port.md / notes.md / TODO.md anchors used by the new skills resolve.

`ffmpeg-c-semantics`, `ffmpeg-oracle`, and `media-pipeline` are the right shape: a short entry point, one reference for the operation being changed, and an explicit refusal to widen support or mark a task verified.

## Fix these

### 1. A `Group` task does not silently drop a decode error

`Group.async` and `Group.concurrent` both require a return type that coerces to `Cancelable!void`, which is only `error.Canceled`. The `catch {}` at `Io.zig:1368` and `Io.zig:1389` discards that cancellation, which the comment calls a propagation boundary. `error.DecodeFailed` or `!void` does not compile.

The skill and the analysis say the wrapper discards the task error, and that a decode error returned from the task is discarded. The advice to store the error where the owner can see it is right. The mechanism is not: the agent will get a compile error, and the "why" column currently blames only `Group.async`, so `Group.concurrent` looks like the call that preserves a result. It does not. `Group.await` is still `Cancelable!void`.

### 2. `io.lockStderr` is not a zero-argument call

The signature at `Io.zig:2639` is `lockStderr(io, buffer, terminal_mode)`. Both the deadlock list and the analysis tell the agent to call `io.lockStderr`. That does not compile. This skill exists to stop that class of copy.

### 3. The `zig-async` workflow points at analysis sections the table does not name

Step 3 says to read the analysis section the row names. The rows cite `Io.zig` lines, not headings. `references/analysis.md` then repeats the same table, deadlock list, and checklist. Either name a heading per row, as `zig-io` does, or stop telling the agent to read the analysis before deviating.

### 4. The `Select` deadlock is the portable comment, not this backend

`Select.async`'s own comment promises the `Io.async` guarantee: the function has run, or a unit of concurrency has been assigned, before return. On `Io.Threaded`, `groupAsync` queues and signals, or runs inline, before it returns. `Select.await` does not call `Group.await`, but on this pin the task has already been started.

Telling an agent that `Select` on `async` arms deadlocks here will send them after a failure that does not reproduce. Preferring `concurrent` is still the safe rule. The footgun this std actually documents is `Select.cancel`: if the queue buffer cannot hold every remaining result, it deadlocks. That is absent from the skill.

### 5. The failure catalog, which is now read on every Zig change, is one type off

`*std.Io.Reader` has no `.err`. `io_patterns.zig` recovers `error.Canceled` on `*std.Io.File.Reader` in `readFileU32Le`. The longer snippet later in the guide is right; the catalog row is the one that will be copied.

The pipe warning is also slightly strong: `readSliceShort` loops on a 0-byte read, so after the mode switch the next iteration reads the bytes. A caller that treats 0 as EOF drops the stream. `readSliceAll` does not.

## Smaller nits

- `Io.Queue` is the doc comment at `Io.zig:2381` in the new analysis and `pub fn Queue` at `Io.zig:2384` in the `zig-io` analysis updated in the same series. Pick one.
- `zig-0-17`'s "no `std.Thread.spawn` … those are `zig-async`, and not before T59" can be read as `Thread.spawn` becoming legal at T59. `zig-async` forbids it for a pipeline stage even then.
- The fire-and-forget row shows `group.concurrent` and `defer group.cancel` without the `try`. `Group.concurrent` returns `ConcurrentError!void`. The later row covers `ConcurrencyUnavailable`, but the row an agent will copy does not.
- `.references/zio` is not checked out in this tree. The new analysis still cites `.references/zio/src/io.zig:5118` as evidence. The pin is in `README.md`; the file is not here.

`doc/state-machines.md` was not reviewed beyond the authority split `media-pipeline` states. That split is consistent with the map's own header: the map is navigation, and port.md and the source remain the contract.
