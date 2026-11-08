# Failure testing with the existing harnesses

The coding invariants remain in the Zig guide's
[Hostile input section](../../zig-0-17/references/guide.md#hostile-input)
and [CLAUDE.md](../../../../CLAUDE.md#malformed-input-cleanup-and-the-cli).
This procedure selects tests and operates the existing helpers.

## Choose inputs that reach the state being changed

| Changed behavior | Useful input or sequence |
| --- | --- |
| A size/count/table allocation | Zero, boundary, one past the boundary, and a large declared count in a short input |
| Replacement of metadata or codec configuration | Two instances, with failure during the second; destroy the object afterward |
| A borrowed buffer or plane view | Read again, grow storage, reconfigure smaller then larger, reset, and seek |
| Incremental parsing | Prefix truncations and one-byte fragmentation of the same valid input |
| Optional parsing or raised limits | Both default and non-default options; seeking and nonseekable input separately |
| Buffered output | Failure during transfer, final flush and header rewrite, including partial output |
| A public buffer-capacity check | Empty, one element short and exact capacity, in the applicable build modes |

Match the asserted error and precedence to the format contract. A refusal
can be correct while the wrong error or a leaked allocation is still a bug.
For every parser/decoder change, follow the project's required Debug
regression and G3 checks; ReleaseFast checks establish that explicit bounds
work when runtime safety is disabled.

## Allocation and remap failures

Read [hostile.zig](../../../../zig/testing/hostile.zig) before choosing a
helper. Its callbacks must create, exercise and destroy the object for each
allocator attempt, without shared mutable state between attempts.

- `checkAll(test_fn, extra_args)` calls `test_fn(gpa, extra_args...)` with
  allocation failures and remaps/resizes forced to fail. The callback must
  release any result it creates before returning.
- `checkAllocationFailures(backing, context, run)` sweeps with working and
  failing remaps. `checkAllocationFailuresWith(..., .fail, ...)` selects
  failing remaps only. That path also exercises the allocation/copy fallback
  in `ArrayList.toOwnedSlice`.
- Propagate injected `OutOfMemory`. Swallowing it to continue as if a
  successful parse occurred defeats the sweep. Other malformed-input errors
  may be tolerated by a fuzz driver, but should be asserted in the dedicated
  regression test.
- Exercise replacement and reconfiguration, not just construction. A leak
  checker cannot find a double free on a path the callback never reaches.

The guide records a possible `NondeterministicMemoryUsage` with working
remaps: whether growth succeeds in place can depend on heap state. Diagnose
the failure and confirm the `.fail` sweep is deterministic before selecting
that mode for the case. Do not catch the harness error and report a pass.

## Fuzz seeds that actually reach the parser

`std.testing.fuzz` executes corpus seeds during ordinary tests. It does not
start a sustained fuzz campaign there. `hostile.mutationSmoke` supplies a
bounded deterministic mutation run; `zig build --fuzz` is the separate
fuzzer entry point when supported by the pinned host/toolchain.

1. Bound input storage, packet/frame iterations and allocations. Read
   `hostile.TestPlan`, `drawTestPlan` and `runTestPlan` for demuxers that use
   the generic layer.
2. Encode corpus entries in the same order the callback reads them.
   `smith.slice` consumes a little-endian `u32` length before the bytes;
   `hostile.fuzzSeed(bytes, values)` supplies that prefix and the subsequent
   little-endian `u64` values. Raw media bytes alone are not that encoding.
3. Vary relevant options as well as bytes: seekability, raised or tightened
   limits, tag collection, seek target and flags. Keep the seed's values in
   the callback's read order.
4. Add a directly runnable seed-reachability assertion. For a valid seed,
   require a stream opened, packet returned, or frame decoded as appropriate.
   Malformed seeds instead assert reaching the intended error/state. A
   callback that returns normally before parsing proves nothing.
5. Use `mutationSmoke(context, callback, seeds, rounds, prng_seed)` for a
   deterministic smoke run. Record both the rounds and seed. The MOV tests
   show allocation sweeps, option-aware seeds, a reachability check and a
   mutation smoke together.

When a harness frees storage, invalidate its views too. The historical
Vorbis harness retained plane slices across a shrink/grow and crashed in
the harness itself. Preserve a minimized failure as an ordinary crafted
regression, including its options and call sequence, as well as a seed.

## Process behavior and evidence

Use `probe_cases`/`convert_cases` in `build.zig` for tool stdout, stderr and
status. Prepared-file behavior belongs in `zig/testing/zffmpeg_cases.zig`.
zffprobe does not construct a decoder, so a decoder failure needs a zffmpeg
process path. Test real files and pipes when the path supports both.

Request-only refusal occurs before output creation. Test late failure after
partial output too: cleanup may remove only a regular file created by this
run; output-side errors name the output. A unit test with `Reader.fixed`
does not exercise a failing file adapter or final flush.

Use the authoritative commands in CLAUDE.md and the reference README. A
`-Dtest-filter` run is useful for diagnosis; it does not replace the full
checks required by the active task. Record fuzz seeds/budget/results apart
from unit tests and required/optional differential coverage. Do not mark G5
from a smoke run or a compile-only cross build.
