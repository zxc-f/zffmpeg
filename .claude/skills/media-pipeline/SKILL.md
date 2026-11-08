---
name: media-pipeline
description: Design and verify zffmpeg's media state, ownership and timing contracts. Use when changing packet/frame retention, send/receive backpressure, delayed output, draining, reset, seek recovery, timestamp rescaling, encoder delay or stream reconfiguration. Applies to synchronous pipelines as well as future workers. File I/O mechanics belong to zig-io; task spawning and cancellation belong to zig-async.
---

# Media state, ownership and time

Read [state and timing](references/state-and-time.md) for the operation being
changed, then the corresponding contract in port.md and active TODO.md task.
Preserve the supported API; this skill does not add reference counting,
video storage or worker threads before their existing task gates.

## Describe the boundary before changing it

Use the existing task card, code documentation or tests to make these facts
explicit where they are not already documented:

- Who owns each input, queued item and output, and which next operation
  invalidates a borrowed view.
- Whether a rejected/failed send consumes input and whether the instance
  stays usable, must reset, or must be destroyed.
- Which calls can emit delayed output, start drain, finish drain, reset or
  seek; which saved state survives each operation.
- The unit and time base of each PTS, DTS and duration, plus the handling
  of missing/negative values, rounding, wrap and discontinuities.

Then follow the changed state through the actual demuxer/parser, decoder,
converter/filter, encoder and muxer boundaries it reaches. One packet does
not imply one frame or one output packet.

## Decision table

| Change | Check |
| --- | --- |
| Retain a packet/frame beyond the producer's next call | Use the supported clone/ownership mechanism; copying an owning struct does not clone its allocation |
| Send returns full | Caller keeps the input and receives output before retrying; full and need-input cannot persist together |
| End of input | Enter drain once, emit delayed output, then stable drained behavior |
| Reset or successful seek | Discard the contract's queued data and restart parser/decoder/filter timing state; this is not drain |
| Failed seek or reconfiguration | Check which old state remains valid and what the next call is allowed to do |
| Convert a timestamp | Select checked `time` or FFmpeg-compatible `rational` semantics deliberately; identify the source/target time bases and rounding |
| Change channels, rate, storage or codec configuration | Revalidate dependent buffers and views; rebuild or refuse as the active contract specifies |
| Add a queue | Bound retained bytes/frames and ensure each iteration progresses or returns a defined wait/failure |

Use `zig-0-17` for implementation, `ffmpeg-c-semantics` for numeric/error
translation, and `ffmpeg-oracle` for independent packet/frame traces and
failure harnesses. A thread, concurrent queue wait or task cancellation also
requires `zig-async`; synchronous media state is not a reason to spawn.

## Validate behavior, not only signatures

- Test accepted and rejected sends, retry, zero/multiple/delayed outputs,
  repeated drain/receive, reset, and failure at relevant transitions.
- Test view retention explicitly: reuse the producer's buffer after cloning
  and confirm the retained result; do not dereference an expired view.
- Test a complete sequence through seeking or reconfiguration, including
  prior queued output, missing/negative timestamps and unequal time bases.
- Compare packet/frame content and timing together. Equal hashes with wrong
  PTS or duration are a failure.
- Reuse `zig/testing/delay_stage.zig` for a controlled buffering consumer and
  its progress tests. `stage.check` validates signatures, not those laws.
- Apply the task's allocation-failure, I/O, cancellation and build-mode
  requirements; report limitations in the existing contract and evidence.
