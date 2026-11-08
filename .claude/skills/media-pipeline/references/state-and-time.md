# State and timing across media boundaries

The governing contracts are
[core API/resource rules](../../../../port.md#core-api-and-resource-rules),
[streaming state/ownership/time](../../../../port.md#streaming-state-ownership-and-time),
[packets/frames/stages](../../../../port.md#packets-frames-and-stages), and
the format's own contract. Use TODO.md T14/T15, the active container/codec
task, T52 for seeking and T53d for scheduling as applicable. Task status
stays in TODO.md.

## Input and output ownership

`core/packet.zig` and `core/frame.zig` expose borrowed views. Their `clone`
methods return an `Owned` copy that must be released once. A plain struct
assignment copies pointers; it transfers or duplicates ownership only if
the caller explicitly implements such a contract.

Before retaining a view, find its producer's invalidation point: the next
read/decode/send/receive, a growing combine buffer, reset, or destruction.
Pass through borrowed data only while that lifetime holds. A queue that
outlives it must use the supported owning representation. Do not introduce
a parallel reference-counted buffer system; T14b governs shared storage and
pools when a real consumer or measured cost requires them.

For each transition, account for the owner on success and on failure:

| Event | Question to resolve in the existing contract and tests |
| --- | --- |
| Accepted input | Copied, borrowed until which call, or transferred? Can the caller reuse its bytes now? |
| Full/rejected input | Is it unchanged and still owned by the caller? Does receiving then retrying avoid a duplicate? |
| Failed send/allocation | Was anything consumed? Which queued owners remain? Is reset/reuse valid? |
| Output delivery | Who releases it, and which next operation invalidates its views? |
| Drain completion | Are all delayed results emitted and retained allocations eventually released? |
| Reset, seek or destroy | Which queued data, parser configuration, skip/discard state and time counters are dropped or preserved? |

Build replacement state in a successful local before publishing it. A
reconfiguration that changes plane count or capacity must update every
dependent view; retaining a slice into freed scratch storage is not made
safe by its old length. If reconfiguration is outside the supported subset,
use the contract's refusal rather than silently labeling new samples with
the old rate or layout.

## Backpressure and lifecycle

Read `core/stage.zig` and FFmpeg's send/receive contract in
`libavcodec/avcodec.h`, plus the specific codec implementation. A stage can
consume several inputs before producing output or produce several outputs
from one input. FFmpeg forbids simultaneous EAGAIN on both ends: waiting
for wall time alone does not resolve a media-state transition.

In this API, `.full` leaves input with the caller and requires an output to
be received before retrying. `.need_input` requests another input.
`finishInput` starts draining; the project's contract makes it idempotent.
It does not require every FFmpeg codec's second null-send error to appear
unchanged through this API. `.drained` remains stable until reset. `reset`
drops the specified buffered state and accepts a new stream segment.

For a loop over stages, identify its progress measure: input consumed,
output emitted or state advanced. If none applies, return the defined
wait/backpressure result or failure instead of spinning. Count retained
bytes and frames as well as queue entries; a bounded entry count alone
does not bound arbitrarily large packets.

`zig/testing/delay_stage.zig` provides delayed/split output, copied inputs,
bounded storage and a progress test. Reuse its patterns for the changed
contract rather than inventing a scheduler just to test a decoder.

## Timestamp units and arithmetic

For each timestamp field, identify its origin and unit. Keep packet PTS,
DTS and duration distinct, and make rescaling boundaries explicit.

| Choice | Contract |
| --- | --- |
| `core/time.zig` | Positive time bases, checked rescaling and optional missing timestamps; overflow is an error |
| `core/rational.zig` | FFmpeg's signed rationals, rounding flags, `nopts` sentinel and reference-compatible rescale/wrap behavior |
| Media duration | Integer sample/frame/container ticks under a supported timing rule |
| Missing timing | Preserve `null` in the view API; translate the C sentinel deliberately at the corresponding boundary |

Do not perform arithmetic on a missing value before testing it. Zero is a
valid timestamp. Preserve valid negative timestamps; `pts == dts` is not a
general video invariant. Rescale from the known source time base with the
specified rounding and checked/wider arithmetic or the established FFmpeg
helper. Repeatedly converting through floating-point seconds or rounding
at extra intermediate steps can change results.

The helper's output sentinel is not interchangeable with a checked error.
Choose based on the existing boundary contract. The C semantics skill
covers exceptional arithmetic; it does not authorize using wrapping math
for allocation sizes or file offsets.

## Seek, delay and reconfiguration sequences

A useful sequence for a stateful regression is: open, read enough to retain
or delay output, seek/reset or attempt reconfiguration, then read and drain
again. Assert content, timestamps and release behavior at each relevant
step. Include failure during the transition and follow the contract for
what subsequent calls may do. Do not assume a failed seek rolled back state
unless the API promises and tests that behavior.

Inspect the full path: the container cursor/index, parser combine buffer,
demux read-ahead/parse queues, decoder priming state, filter/resampler delay
and pending output. Some state survives a reset by design; Vorbis' one-shot
first-frame skip and the decoded inputs' skip/discard handling show why
clearing every field indiscriminately is also wrong.

For MP4 T33a3, start with the `stts`/`ctts` tables, signed offsets,
`dts_shift` and `mov_finalize_packet`, then the generic layer's timestamps.
Use packet/configuration oracles without requiring a video decoder. Edit
lists and fragmented MP4 retain their separate T33b/T33c gates. Later TS
work needs wrap/discontinuity cases; video decoders need delayed output and
reference-frame retention. Do not widen those subsets incidentally.

## Source map

C paths are relative to `.references/ffmpeg/` at
`5d5a38a7e46be296eab75982c0986054f731e19e`.

| C contract/implementation | Current Zig consumer and evidence |
| --- | --- |
| `libavcodec/avcodec.h`, `decode.c`, `encode.c` | `core/stage.zig`, `codec/pcm.zig`, `testing/delay_stage.zig` |
| `libavcodec/packet.c`, `libavutil/frame.c`, `buffer.c` | `core/packet.zig`, `core/frame.zig`, `core/samples.zig`; clone/failure tests |
| `libavutil/mathematics.c`, `rational.c` | `core/rational.zig`, `core/time.zig`; `rational_vectors.c` |
| `libavformat/demux.c`, `seek.c` | `format/demux.zig`, `format/seek.zig`; format-specific seek vectors |
| `libavformat/mov.c` sample tables/index/finalization | `format/mov.zig`; `mov_vectors.c` with file/pipe fixtures |
| `libavcodec/decode.c` skip samples; `fftools/ffmpeg_dec.c` error policy | `format/decoded.zig` and decoded format adapters |
| `libavfilter/avfilter.c`, `framesync.c`, `af_amix.c` | `filter/graph.zig`, `filter/multi.zig`; graph/multigraph vectors |

The state/timestamp vectors must check more than payload hashes. Preserve
stream identity, timing and side data in the comparison, using
[ffmpeg-oracle](../../ffmpeg-oracle/SKILL.md) for the actual harness and
evidence rules.
