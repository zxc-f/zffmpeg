# Codex review: pass 1 — complete current branch

Review date: 2026-11-08.

| Item | Reviewed value |
| --- | --- |
| Branch | `claude/sharp-gates-hj8vww` |
| Snapshot | `9c1e05e1457c69fc437a838295df0db6b247f405` |
| Review pass | First pass complete; second pass must use this same code snapshot |
| Starting working tree | `?? codex-review.md`; the existing review was untracked; no implementation changes |
| Scope | Current checkout as a standalone codebase, including code, tests, build/CI, reference tooling, skills and documentation; no commit-range restriction |
| Inventory | 1,137 tracked files: 164 Zig, 49 C oracle sources, 5 Python, 20 shell and 43 Markdown files, plus fixtures, vectors and other project files |
| Compiler / host | Zig `0.17.0`, Linux x86-64, glibc `2.44` |
| FFmpeg source and installed reference | `5d5a38a7e46be296eab75982c0986054f731e19e`, Clang `23.1.4`, assembly disabled |
| Repository edits | This report only; no implementation, fixture, contract or test changes and no commit |

This first-pass report replaces the previous commit-range review. R1–R3 remain confirmed;
R4 now covers the older decoded readers too. R5–R8 are additional findings
from the whole-branch review. D1 identifies current documentation conflicts.
No finding depends on when the defect was introduced.

**Next reviewer:** follow the [second-pass handoff](#second-pass-review-handoff).
Reuse the [completed validation ledger](#validation-completed-in-pass-1): the
full suites and reference matrix have already run on this snapshot. A second
review pass should investigate the remaining coverage gaps and new hypotheses,
without automatically repeating those baseline checks. No second-pass work or
verification is claimed in this document yet.

**Assessment:** fix R1's invalid memory read first, then the configuration,
frame-boundary and buffer-contract defects. Strengthen the oracle before
using its green results as acceptance evidence. The code has useful Zig
abstractions and strong reference coverage, but duplicated decoded-reader
logic and independently reconstructed stream parameters still allow defects
at subsystem boundaries.

The full existing differential matrix passed **13,102 required and 66 optional
cases**, with zero failed, missing or skipped. The focused checks below still
reproduce the findings. Passing that matrix is evidence for its selected
inputs and option combinations, not a proof of the supported input space.

This is a whole-codebase, risk-directed review. All tracked files were
inventoried and all subsystem families were included in the review plan;
inspection depth is stated in the coverage table. It is not a claim that
every codec equation, generated constant or line was independently proved.
Ignored build products, reference clones and separate `.claude/worktrees/`
checkouts are not branch source. The pinned reference clone was used as an
oracle, not as implementation code under review.

## First-pass findings

| ID | Priority | Finding | Evidence |
| --- | --- | --- | --- |
| R1 | P1 | Metadata self-append reads freed storage after a moving realloc | Failing-allocator reproduction |
| R2 | P2 | CAF publishes zero ALAC channels despite the decoder's fallback | Pinned-reference probe and conversion |
| R3 | P2 | CAF loses the ALAC cookie's decoded sample rate | Pinned-reference probe and output headers |
| R4 | P2 | Decoded readers assert on a caller's undersized output | Four executed Debug panics; analogous AC-3 source |
| R5 | P2 | HE-AAC's frame-size bound splits frames before resampling | Different FLAC blocks and file sizes; identical decoded PCM |
| R6 | P2 | Ogg-output oracle accepts failed pipe commands | 288 injected nonzero exits; still 145/145 passes |
| R7 | P2 | Encoder options reject superseded values before the last value wins | FLAC, AAC and ADPCM CLI comparisons |
| R8 | P2 | A pipe's known length is mistaken for seekability | Same Ogg pipe succeeds without length, fails with it |
| D1 | P3 | Support descriptions and command help contradict current capabilities | Documentation/source audit |

### R1 — [P1] Preserve aliased metadata values before a moving reallocation

**Location:** [zig/core/metadata.zig:129](zig/core/metadata.zig#L129), through
the copy at line 134; `Dictionary.appendTo`.

**Trigger:** Obtain a value with `Dictionary.get`, then append that borrowed
value, or a slice of it, to the same entry using `put(..., .append)`. The
combined value must outgrow the current allocation, and `realloc` must move it.

`value` still points into the old allocation when `gpa.realloc(storage, grown)`
returns a different allocation. Reallocation has freed the old one before
`@memcpy(..., value)` reads it. Copying the key first does not protect the
value. The operation therefore reads freed memory and can corrupt the stored
tag or fault depending on the allocator and reuse of that memory.

The public `put` contract says it adds copies of its inputs and does not
exclude values borrowed from the dictionary. The existing replacement path
copies its value before releasing the entry. FFmpeg's `libavutil/dict.c`,
`av_dict_set`, also makes `copy_value` before reallocating the old value for
`AV_DICT_APPEND`. This is a defect in the append path.

**Reproduced:** A moving realloc forced with
`std.testing.FailingAllocator` produced the original 32 bytes followed by 32
bytes of freed-allocation poison (`0x55`), instead of the original value twice.
The standalone test failed with `TestExpectedEqual`; this is direct evidence
of the invalid read, not only a theoretical ownership concern.

```zig
// SPDX-License-Identifier: LGPL-2.1-or-later
// Original diagnostic for this review.
//! Dictionary append must preserve a borrowed source across reallocation.
const std = @import("std");
const av = @import("av");

test "append a borrowed value from the same dictionary" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .resize_fail_index = 0 },
    );
    const gpa = failing.allocator();
    var d: av.metadata.Dictionary = .empty;
    defer d.deinit(gpa);
    try d.put(gpa, "x", "0123456789abcdef0123456789abcdef", .replace);
    const previous = d.get("x").?;
    try d.put(gpa, "x", previous, .append);
    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        d.get("x").?,
    );
}
```

Save this as `/tmp/zffmpeg-branch-review-20261108/alias.zig`, then run from the repository
root:

```sh
zig test --dep av -Mroot=/tmp/zffmpeg-branch-review-20261108/alias.zig -Mav=zig/root.zig
```

**Recommended correction:** Preserve an aliased source before reallocation,
either by copying it or by recording a checked offset and rebasing it into
the new allocation. Preserve the current transactional behavior on allocation
failure and the linear cost of repeated appends. Do not retain an old pointer
after a successful moving realloc.

**Regression coverage:** Self-append, a borrowed substring, moving realloc,
in-place growth, growth into existing spare capacity, and allocation failures.
The memory-safety impact is confirmed at the library API; a CLI path that
supplies this alias has not been established by this review.

### R2 — [P2] Apply the container channel fallback to CAF's reported ALAC format

**Location:** [zig/format/caf.zig:340](zig/format/caf.zig#L340), especially the
cookie channel selection and layout construction at lines 340–343.
[zig/format/cafalac.zig:100](zig/format/cafalac.zig#L100) carries that format
into the conversion header.

**Trigger:** An ALAC CAF has a valid channel count in its `desc` chunk and a
zero channel count in its magic cookie. This is a supported FFmpeg fallback,
not a reason to publish a zero-channel decoded stream.

`alac.Config.parse` already implements the correct fallback at
[zig/codec/alac.zig:110](zig/codec/alac.zig#L110): when the cookie count is zero,
it takes the container count. However, the CAF parser independently selects
`c[21]` merely because a cookie exists. It constructs an unspecified layout
with zero channels. The decoder and the published stream format consequently
disagree. `cafalac.readHeader` only changes the sample format and preserves
the zero-channel layout.

**Reproduced:** Starting from `alac_new_kuki.caf`, change only the cookie
channel byte to zero; retain the stereo container descriptor and the audio.

| Operation | Pinned FFmpeg | Current Zig |
| --- | --- | --- |
| Probe channels | `2` | `0` |
| Probe sample rate | `44100` | `44100` |
| Decode to WAV | Succeeds, stereo | Exit 2, `InvalidFormat` |

FFmpeg's `libavcodec/alac.c`, `alac_decode_init`, explicitly takes the container
channel count when the cookie count is less than one. The Zig decoder has
that behavior; the container/conversion integration loses it.

**Recommended correction:** Derive the effective ALAC channel count and layout
from the same validated configuration used by the decoder, including the
container fallback, and publish it consistently through probe and conversion.
Retain ALAC's channel ordering; copying only a count into an unrelated layout
would leave a second mismatch.

**Regression coverage:** Modern and legacy cookies with a zero count and a
valid container count; matching nonzero counts; invalid counts in both places;
file and pipe probe/conversion paths. See the shared reproducer below.

### R3 — [P2] Propagate the ALAC cookie sample rate into decoded output

**Location:** [zig/format/caf.zig:345](zig/format/caf.zig#L345) publishes the
container rate, and [zig/format/cafalac.zig:100](zig/format/cafalac.zig#L100)
copies it without applying `r.decoder.config.sample_rate`.

**Trigger:** The CAF descriptor's sample rate differs from the ALAC magic
cookie's sample rate. Both fields are present and otherwise usable.

`alac.Config.parse` reads the cookie rate at bytes 32–35, but that rate does
not reach the exposed decoded format. The parser publishes `rate` from
`desc`; the decoded reader only updates `sample_format`. FFmpeg instead sets
`avctx->sample_rate = alac->sample_rate` during decoder initialization.

**Reproduced:** Leave the fixture descriptor at 44,100 Hz and change only the
cookie's rate to 48,000 Hz.

| Operation | Pinned FFmpeg | Current Zig |
| --- | --- | --- |
| Probe sample rate | `48000` | `44100` |
| Decode to WAV | Succeeds; WAV is `48000` Hz | Succeeds; WAV is `44100` Hz |
| Channels | `2` | `2` |

This silently writes audio with the wrong playback rate. The finding concerns
the decoded sample rate and output WAV header; it does not assume that every
CAF container timestamp or time base must be replaced with the cookie rate.

**Recommended correction:** Propagate the effective decoder sample rate into
the probe/decoded stream format and hence the converter's output format.
Keep container timing and decoded sample timing explicit where FFmpeg keeps
them separate. R2 and R3 share configuration plumbing but have distinct
triggers and failures; cover both when consolidating that plumbing.

**Regression coverage:** Mismatches in both directions, matching rates, and
zero/invalid-rate handling checked against the pinned reference. Verify actual
output headers as well as probe text and sample content.

#### Shared CAF reproducer for R2 and R3

Run from the repository root after building the tools. This changes scratch
copies of the existing modern-cookie fixture; repository fixtures stay intact.
The 24-byte cookie body is represented internally after a 12-byte atom prefix.

```python
from pathlib import Path

scratch = Path("/tmp/zffmpeg-branch-review-20261108")
scratch.mkdir(parents=True, exist_ok=True)
source = Path("zig/testing/fixtures/alac/alac_new_kuki.caf").read_bytes()
chunk = source.index(b"kuki")
body = chunk + 12  # FourCC and big-endian 64-bit chunk size
assert int.from_bytes(source[chunk + 4:body], "big") == 24

channels = bytearray(source)
channels[body + 9] = 0
(scratch / "zero-channels.caf").write_bytes(channels)

rate = bytearray(source)
rate[body + 20:body + 24] = (48000).to_bytes(4, "big")
(scratch / "cookie-rate.caf").write_bytes(rate)
```

For each scratch input, compare these tools:

```sh
.references/ffmpeg-install/bin/ffprobe -v error \
  -show_entries stream=sample_rate,channels -of default=nw=1 \
  /tmp/zffmpeg-branch-review-20261108/zero-channels.caf
zig-out/bin/zffprobe /tmp/zffmpeg-branch-review-20261108/zero-channels.caf

.references/ffmpeg-install/bin/ffmpeg -v error -y \
  -i /tmp/zffmpeg-branch-review-20261108/zero-channels.caf \
  /tmp/zffmpeg-branch-review-20261108/zero-channels-reference.wav
zig-out/bin/zffmpeg -y -i /tmp/zffmpeg-branch-review-20261108/zero-channels.caf \
  /tmp/zffmpeg-branch-review-20261108/zero-channels.wav
```

Repeat with `cookie-rate` in place of `zero-channels`. Probe the generated
reference and Zig WAV files with the same reference `ffprobe` command to
verify their sample rates independently. The zero-channel Zig conversion is
expected to fail on the reviewed revision.

### R4 — [P2] Return a defined error for undersized decoded-audio output

**Locations:** `readData` in
[zig/format/aacdecode.zig:190](zig/format/aacdecode.zig#L190),
[zig/format/ac3decode.zig:189](zig/format/ac3decode.zig#L189),
[zig/format/mp3decode.zig:191](zig/format/mp3decode.zig#L191),
[zig/format/oggdecode.zig:256](zig/format/oggdecode.zig#L256) and
[zig/format/flac.zig:1127](zig/format/flac.zig#L1127).

**Trigger:** After opening a valid stream, call `readData` with less space
than one complete interleaved sample frame while samples remain pending.
Each reader computes zero frames and asserts `frames > 0`. Caller-controlled
capacity should have a recoverable error. In ReleaseFast, the unreachable
assertion supplies no defined error contract; an empty result would also
incorrectly signal EOF without consuming the pending samples.

**Reproduced:** one-byte destinations abort in Debug for all four exported
readers below. The AAC ReleaseFast test failed with `FrameCountMismatch`,
which is not a stable or suitable capacity-error contract. AC-3/E-AC-3's
identical guard was checked by source inspection; its wrapper is not exported
as `av.ac3decode`, and no direct runtime result is claimed for it.

| Reader | Valid fixture used |
| --- | --- |
| AAC | `aac/aac_ffmpeg_short.aac` |
| MPEG audio | `mp3/mp3_l3_short_ms.mp3` |
| Ogg Vorbis | `ogg/ogg_vorbis_ffmpeg_22k_short.ogg` |
| Native FLAC | `flac/flac_verbatim_stereo_44k1.flac` |

The reproductions are in `/tmp/zffmpeg-branch-review-20261108/short-*.zig`.
The AAC example is:

```zig
// SPDX-License-Identifier: LGPL-2.1-or-later
// Original review diagnostic.
const std = @import("std");
const av = @import("av");
test "short aac output" {
    var input: std.Io.Reader = .fixed(@embedFile("short.aac"));
    var r = av.aacdecode.DecodedReader.init(
        std.testing.allocator, &input, null, null,
    );
    defer r.deinit();
    r.count_ahead = false;
    _ = try r.readHeader();
    var out: [1]u8 = undefined;
    _ = try r.readData(&out);
}
```

Copy the fixture beside it as `short.aac`, then run:

```sh
zig test --dep av -Mroot=/tmp/zffmpeg-branch-review-20261108/short-aac.zig -Mav=zig/root.zig
zig test -OReleaseFast --dep av -Mroot=/tmp/zffmpeg-branch-review-20261108/short-aac.zig -Mav=zig/root.zig
```

**Correction and regression coverage:** Return `OutputTooSmall` while keeping
the pending range intact, as `pcmdata`, `wavadpcm`, `cafalac` and `aug72x`
already do. Test zero bytes, one byte, frame size minus one, exact capacity,
and retry with sufficient capacity in all three modes. Small shared capacity
checking would prevent this fix drifting across five wrappers. No CLI panic
is demonstrated: its conversion buffers are larger.

### R5 — [P2] Size the AAC resampling input for SBR's 2,048-sample frames

**Locations:** the fixed `max_frame = 1024` in
[zig/format/aacdecode.zig:94](zig/format/aacdecode.zig#L94), consumed by
[zig/format/convert.zig:651](zig/format/convert.zig#L651) and the frame buffer
in `Conversion.resampleFrames` at line 1094.

**Trigger:** Resample a supported HE-AAC or HE-AACv2 ADTS stream and encode
it to FLAC. SBR can double a frame to 2,048 decoded samples; the decoder
itself implements this at `aacdec.zig:889`. The conversion buffer holds only
1,024 frames, so `readData` cuts a decoded frame into two separate resampler
calls. This contradicts `resampleFrames`' invariant that each call receives
a whole decoder frame.

The first resampler output sets the FLAC encoder's block size. Splitting
that input therefore changes the encoded stream and compression, even when
the final PCM is identical. The FLAC contract promises the pinned encoder's
bytes and frame-size selection; this is not an excluded HE-AAC feature.

**Reproduced:**

```sh
.references/ffmpeg-install/bin/ffmpeg -v error -y \
  -i zig/testing/fixtures/aac/aac_fdk_hev2_44k.aac -bitexact -ar 32000 \
  /tmp/zffmpeg-branch-review-20261108/he-resample-ref.flac
zig-out/bin/zffmpeg -y -i zig/testing/fixtures/aac/aac_fdk_hev2_44k.aac \
  -ar 32000 /tmp/zffmpeg-branch-review-20261108/he-resample-zig.flac
```

| Result | Pinned FFmpeg | Zig |
| --- | --- | --- |
| Exit status | 0 | 0 |
| FLAC block size | 1,470 | 727 |
| File size | 83,845 bytes | 112,832 bytes |
| Reference-decoded s32le | 225,888 bytes | 225,888 bytes |

Both decoded outputs have SHA-256
`d5e7502bf59c77fb3666f5b332402f2f90cb699e2681c7b5479b6553f54de759`.
The Zig file is about 35% larger. The same encoded-size mismatch occurs
on stdout. The AAC-LC control `aac_ffmpeg_48k_64k.aac` produces identical
FLAC output with these options.

**Correction and regression coverage:** Obtain the effective decoder frame
size, or provide a storage bound that includes 2,048 samples, while preserving
actual decoder frame boundaries. Keep a capacity bound distinct from dither
call grouping so an AAC-LC stream's existing grouping is preserved. Compare
HE-AAC/HE-AACv2 plus `-ar` plus FLAC/Ogg together, from files and pipes. The
current matrix tests resampled WAV and unresampled FLAC separately, which
misses this combination. Check encoded blocks as well as decoded samples.

### R6 — [P2] Check process status in the remaining Ogg-output oracle paths

**Location:** [zig/testing/reference/compare.py:2898](zig/testing/reference/compare.py#L2898),
`compare_ogg_output`, especially the stdout-only check at line 2900 and the
three subsequent commands whose statuses are discarded at lines 2903–2907.

**Trigger:** A pipe conversion fails after producing bytes equal to the
expected file. The comparator checks only stdout equality, so a failed
conversion is counted as passing. The reference decode, Zig FLAC generation
and comparison decode also lose their process statuses. Equal nonempty
partial decoded data can be accepted despite a decode failure.

**Reproduced by fault injection:** Run the real Ogg-output comparisons,
retaining their real stdout but changing both tools' successful Ogg/OGA
stdout conversions to status 1 with a late-error diagnostic. The section
still reports **145/145**, with no failures, after **288 failed pipe
commands**. Its existing `check_oracle_predicates()` also passes.

This is a test-oracle defect, not a claim that those 288 real commands fail
without injection. It means the advertised pipe/late-failure validation
cannot detect that regression.

Minimal fault-injection driver, run from the repository root:

```python
import runpy
import subprocess
from types import SimpleNamespace

m = runpy.run_path("zig/testing/reference/compare.py", run_name="review")
g = m["compare_ogg_output"].__globals__
real_run = g["run"]
injected = 0

def run(*command):
    global injected
    result = real_run(*command)
    args = list(map(str, command))
    if args[-1] == "-" and any(
        args[i:i + 2] in (["-f", "ogg"], ["-f", "oga"])
        for i in range(len(args) - 1)
    ):
        assert result.returncode == 0
        injected += 1
        return subprocess.CompletedProcess(
            result.args, 1, result.stdout, b"injected late output failure\n"
        )
    return result

g["run"] = run
lines, failures = [], []
m["compare_ogg_output"](SimpleNamespace(
    ffmpeg=".references/ffmpeg-install/bin/ffmpeg",
    zffmpeg="zig-out/bin/zffmpeg",
), lines, failures)
print(injected, failures)  # Current result: 288 []
m["check_oracle_predicates"]()
```

**Correction and regression coverage:** Require success from every producer
and decoder before comparing their artifacts. Extend the fault-injection
checks to the actual acceptance predicates used here. Audit the same pattern
in FATE Vorbis at `compare.py:3275`: it checks Zig's success and equal bytes,
but omits the reference's success. That second instance is source-inspected;
the executed reproduction above targets Ogg output.

### R7 — [P2] Apply the last encoder-option value before validating it

**Locations:** immediate `av.options.set` calls in
[zig/cli/ffmpeg.zig:410](zig/cli/ffmpeg.zig#L410), and the corresponding
ADPCM, G.726, AAC and AC-3 branches at lines 419, 427, 436 and 445.

**Trigger:** Supply an invalid encoder-option value followed by a valid
replacement for the same option. Encoder options are validated during the
argument walk, before a replacement can overwrite them. The command exits
with usage status 1 despite the final option set being valid.

This disagrees with the CLI's stated last-value-wins contract and FFmpeg's
`cmdutils.c` option dictionary, which retains the final value before setting
encoder options. The delayed handling already used for `-c`, `-ar`, bitrate
and dither options does not extend to these encoder-specific branches.

**Reproduced:** On a scratch WAV containing 2,000 mono s16 samples at
44,100 Hz, the pinned FFmpeg succeeds with each option sequence below;
Zig exits 1 at the first `bad` and creates no output.

| Encoder | Option sequence |
| --- | --- |
| FLAC | `-compression_level bad -compression_level 5` |
| AAC | `-aac_coder bad -aac_coder fast` |
| IMA WAV ADPCM | `-block_size bad -block_size 1024` |

For example:

```sh
zig-out/bin/zffmpeg -y \
  -i /tmp/zffmpeg-branch-review-20261108/repeated-input.wav -c:a aac \
  -aac_coder bad -aac_coder fast /tmp/zffmpeg-branch-review-20261108/repeated.aac
```

The scratch input was generated with Python's `wave` module using one
channel, a two-byte sample width, a 44,100 Hz rate and `bytes(4000)` as data.
Using a sufficient sample count avoids FLAC's separate minimum-block refusal.

**Correction and regression coverage:** Retain the final raw values, resolve
aliases with the appropriate option semantics, then validate the effective
encoder options during preflight. Keep a final invalid value a failure before
output creation. Cover invalid-then-valid, valid-then-invalid, aliases and
the interaction with a later codec selection for every affected option family.

### R8 — [P2] Determine file seekability independently of a supplied length

**Location:** [zig/io/file.zig:49](zig/io/file.zig#L49), particularly
`const regular = with_length.source.length != null` at line 52 and the
synthesized seeker at line 54.

**Trigger:** Call `av.file.probeFile` on a pipe with `Options.source.length`
set to its known byte count. A known length is metadata; it does not make a
handle seekable. The function skips the actual file-kind check when a length
is supplied, chooses positional I/O and creates a file seeker. For Ogg,
`detect.probeOgg` then calls `seekTo(0)` and fails on the pipe.

**Reproduced:** Feed `ogg/ogg_opus_ffmpeg_mono.ogg` through a real subprocess
stdin pipe to a scratch Zig test. Both `Options.gpa` and `Source.gpa` are
`std.testing.allocator`; the buffer is 64 KiB.

| Only changed option | Result |
| --- | --- |
| `.source.length = null` | Success; Ogg recognized |
| `.source.length = 2097` (the exact input size) | `IoFailure`, traced to `error.Unseekable` in `File.Reader.seekTo` |

Both executables receive the same 2,097 bytes. A regular-file stdin control
and the ordinary CLI pipe path succeed. This is a library adapter defect;
the CLI normally obtains length from `regularLength` and does not expose
this particular combination.

The diagnostic's operation is:

```zig
const got = try av.file.probeFile(
    std.testing.io, std.Io.File.stdin(), &buffer, .{},
    .{
        .gpa = std.testing.allocator,
        .source = .{ .length = 2097, .gpa = std.testing.allocator },
    },
);
```

Compile it as a test executable with `zig test --test-no-exec`, then use
Python `subprocess.run([executable], input=fixture_bytes, capture_output=True)`.
A shell input redirection from a regular file does **not** reproduce the
pipe condition. Tests and logs are retained as `pipe-known-ogg*` in the
scratch directory.

**Correction and regression coverage:** Determine positional I/O and the
availability of an automatically created seeker from the actual handle's
kind. Preserve an independently supplied length for formats that can use
it. Test known/unknown lengths on regular files and pipes, with a format
that seeks and raw PCM, whose frame count uses the length.

### D1 — [P3] Reconcile current support descriptions and command help

Several live descriptions still present completed capabilities as absent.
These are documentation corrections; they do not require widening support.

| Location | Conflict / recommended correction |
| --- | --- |
| [CLAUDE.md:96](CLAUDE.md#L96) and [port.md:1669](port.md#L1669) | The current summaries say CAF is input-only or has no muxer/packet tables/compressed formats, although T31b and `cafmux` implement PCM/ALAC output and ALAC packet tables. State the current supported matrix and retain historical T22d evidence as historical. |
| [zig/cli/ffmpeg.zig:64](zig/cli/ffmpeg.zig#L64) | `--help` describes ADTS AAC as input only, omits AAC output formats/extensions and the AAC encoder's options. Add the supported AAC/ADTS output path and its options. |
| [zig/format/convert.zig:49](zig/format/convert.zig#L49) and line 728 | Public module/lifecycle docs say nothing allocates and only FLAC input needs deinit. Multiple compressed inputs, encoders and resampling now own allocations. Document the allocation-free PCM subset and the actual lifetime rules. |
| [TODO.md:81](TODO.md#L81) | The current introduction still names the initial MP4 box/sample-table task as next, while T33a1 and T33a2 are checked and the other current-state documents name T33a3. Update the summary without rewriting old evidence. |
| [zig/testing/reference/README.md:707](zig/testing/reference/README.md#L707) | The configuration narrative says the CAF muxer stays off; its own current configure block enables it. Update the narrative. |
| [TODO.md:821](TODO.md#L821) | Its link to the removed `zig/format/prefix.zig` is broken; point readers to `replay.zig` with a historical note. |

A Markdown local-path scan covered all 43 tracked Markdown files and found
that one missing target. It does not validate external URLs or all anchors.
The fixture generator's `--check` confirms all 776 current fixture files,
manifests and generated README tables are current; those tables are not the
source of these prose conflicts.

## Zig design and maintainability assessment

The native port has several sound structural choices: explicit allocator and
I/O dependencies, concrete `Reader`/`Writer` boundaries, borrowed and owned
packet/frame types, typed sample formats and channel layouts, checked wire
parsing, native algorithms without a C runtime dependency, and a small
single-module build. `options.check` validates descriptors using current
reflection; registry checks enforce ordering, names and coverage at compile
time. PCM/endian kernels and `pcmdata` already share real data paths. These
are useful abstractions rather than blanket metaprogramming.

The remaining design work should concentrate on invariants that are currently
stored or reconstructed in several places:

| Area | Concrete improvement | Benefit / constraint |
| --- | --- | --- |
| Effective codec configuration | Have CAF, its probe result and its decoded reader use one validated ALAC configuration, including channel fallback, layout and sample rate | Directly addresses R2/R3; distinguish container timing from decoder timing |
| Decoded sample delivery | Share the small capacity/pending-range operation across decoded readers; expose actual frame size separately from maximum storage capacity | Addresses R4/R5 without merging codec-specific decode/error/skip policies |
| Generic demux layer | Continue T65a: `format/flac.zig` still duplicates timestamp/read-ahead/seek logic beside `demux.Layer`; it also drains arrays using `orderedRemove(0)` | A real second implementation can drift and incur repeated shifts; no new measured runtime regression is asserted here |
| Filter registration | The filter tagged union, `Kind`, option dispatch, init/deinit and shorthand switches repeat the same cases | Derive uniform operations from payload metadata with compile-time signature checks; retain explicit arms where behavior differs (T65d) |
| C numeric semantics | Consolidate duplicate `av_reduce` in `resample.zig`/`rational.zig` and compatible scanner/conversion helpers in `eval.zig`, MP3 and MOV | T65e/T65g already track this; preserve the demonstrated C widths, rounding and parse termination instead of replacing them with superficially similar std helpers |
| Stateful owners | Continue typed Ogg/decoder state work from the state-machine map, preserving borrowed lifetimes and failure cleanup | Replace only mutually exclusive state/payload combinations; counters, codec history and independent facts remain numeric/independent |
| Option parsing and help | Keep typed specs, but collect effective CLI values before setting them; derive supported-option lists/help where practical | R7 and D1 show the cost of separate parsing and documentation lists; keep expected test output independent |

The C algorithm's operation order is necessary for exact DSP results and is
not itself a design defect. The opportunities above concern duplicate state,
configuration, registration and ownership mechanics. They do not justify
translating every switch into a universal codec framework, changing public
parser fields incidentally, introducing threads before T59, or claiming
public API stability before T54.

## Whole-branch coverage and confidence boundaries

The inventory includes 53 codec files (44,825 lines), 41 format files
(33,823), 39 core/math files (10,543), six filter files (5,369), five resampling
files (4,266), the CLI/I/O/build roots, testing tools, fixture generators,
reference C/shell/Python tooling, skills and documentation. Generated tables,
media fixtures and numerical vectors were checked through their existing
integrity/reference paths rather than manually rederived entry by entry.

| Subsystem | Inspection / validation | Remaining uncertainty |
| --- | --- | --- |
| MP3 and shared parsing/probing | Read MP3 header/resync/VBR/gapless/replaygain logic and MPEG header/parser functions; inspected ID3/demux interfaces, buffered ownership, timestamp and seek paths; full existing differential and mutation checks | No new confirmed MP3 demux defect; not every ID3 encoding/tag combination independently generated |
| Core types and metadata | Sample layouts, packets/frames/stages, dictionary ownership, numeric options/expressions, rational/timestamp helpers and their callers; R1 and R4 diagnostics | Not a formal arithmetic or public-API proof; assert-only lower-level preconditions still need the planned API work |
| PCM containers and file/pipe adapters | Shared data reader, bounded skips, writer checks, cleanup/header rewrites, detection/replay, known-length versus seekability; existing process/file/pipe matrix | R8 confirmed; no fresh exhaustive OS error/cancellation or racing-path sweep |
| FLAC, Ogg, Vorbis and Opus | Selected parser/decoder initialization, replacement/cleanup, packet retention, pending samples, skip/discard/counting and seek boundaries; reference/FATE/RFC cases and malformed-input smoke | R4 confirmed; duplicated FLAC generic layer and Ogg state work remain; no proof of every entropy/DSP path |
| AAC/SBR/PS and AC-3/E-AC-3 | Decoder/stream-wrapper boundaries, configuration changes, frame delivery and encoder/muxer staging, selected arithmetic/size/error paths; reference matrix plus HE-AAC combination test | R4/R5 confirmed; no independent derivation of every psychoacoustic, quantizer or DSP formula |
| ADPCM, ALAC and G.72x | Container configuration, packet/block staging, output/counting/cleanup and selected codec boundary checks; reference matrix and CAF mutations | R2/R3 confirmed; no exhaustive predictor/trellis proof |
| MP4/MOV | Selected atom/table/index bounds, metadata ownership, chapter and audio-description paths, packet interleaving, configured refusal policies; 234 existing file/pipe reference cells and mutations | Excluded video, edit-list, fragment and seeking capabilities remain excluded; not all nested-box interactions exhausted |
| Conversion, filters and resampling | Dispatch/init/deinit, transfer/resample frame boundaries, pending output, graph configuration/queues and option negotiation; full existing conversion matrix | R5 confirmed; filter cycles, every allocator failure during graph mutation and all rate/layout combinations were not newly swept |
| CLI | Request validation, delayed versus immediate option parsing, output creation/overwrite/cleanup, error attribution and help; existing process suite and repeated-option comparisons | R7 confirmed; no new concurrent filesystem adversary test |
| Build, CI and oracle | Exact Zig pin, module/test imports, package allowlist, CI mode/cross/reference setup, fixture checks, comparison acceptance/error paths; complete comparison plus fault injection | R6 confirmed; not every C generator was rebuilt, no CI run inspected, no new cross-platform runtime or cross-build claim |
| Docs and skills | Document authority, roadmap/state/fixture contracts, current support and source/provenance navigation, skill workflows, all Markdown target paths | D1; external links, every anchor, historical benchmark result and every recorded evidence link were not revalidated |

Existing intentional differences in `notes.md` were checked before treating a
mismatch as a defect. In particular, MP4 conversion, video/fragments/edit
lists, unsupported codec profiles, reference-dependent C behavior and the
recorded stricter malformed-input policies are not missing-feature findings.
The inventory and coverage table are not claims of independent security
certification or exhaustive numerical equivalence.

## Validation completed in pass 1

Commands ran from the repository root with the pinned local toolchain.
Scratch sources, media, logs and injection scripts are under
`/tmp/zffmpeg-branch-review-20261108/`. The full comparison report is
`/tmp/zffmpeg-branch-comparison.md`.

**Reuse these results for the unchanged snapshot.** The table includes every
completed suite and distinct focused check from pass 1. Rows marked cached
are cache observations; the separate scratch-cache runs below actually
executed all three optimization modes. Known-defect diagnostics intentionally
fail or panic and are not failures of the passing baseline suite. Repeated
invocations of the same diagnostic are not additional coverage.

| Check | Observed result |
| --- | --- |
| `zig build install test-tools -Doptimize=ReleaseSafe --summary failures` | Passed |
| `zig build -p /tmp/zffmpeg-branch-debug --summary failures` | Passed; supplied Debug tools for the focused CLI checks and mutation smoke |
| `zig build test --summary all` | 416/416 steps passed; cached results |
| `zig build test -Doptimize=ReleaseSafe --summary failures` | Passed; existing cache |
| `zig build test -Doptimize=ReleaseFast --summary failures` | Passed; existing cache |
| `zig build test --cache-dir /tmp/zffmpeg-branch-review-cache --summary failures` | Passed using a new local cache, executing the Debug suite |
| `zig build test -Doptimize=ReleaseSafe --cache-dir /tmp/zffmpeg-branch-review-cache --summary failures` | Passed, executing the ReleaseSafe suite |
| `zig build test -Doptimize=ReleaseFast --cache-dir /tmp/zffmpeg-branch-review-cache --summary all` | Passed: 416/416 steps; 676/676 tests executed and passed |
| `zig fmt --check build.zig build.zig.zon zig/` | Passed |
| `python3 zig/testing/fixtures/generate.py --check` | Passed: all 776 fixtures, manifests and generated tables current |
| Full `compare.py` run, command below | Passed: 13,102 required; 66 optional; 0 failed/missing/skipped |
| `check_oracle_predicates()` | Passed; R6 demonstrates an acceptance path outside those checks |
| Metadata self-append / forced moving realloc | Expected diagnostic failure: 32 bytes of freed-memory poison copied |
| CAF zero-cookie-channel and cookie-rate comparisons | R2/R3 confirmed against pinned FFmpeg and generated WAV headers |
| AAC/MP3/Ogg/FLAC one-byte `readData`, Debug | Each aborted at its positive-frame-count assertion |
| AAC one-byte `readData`, ReleaseFast | `FrameCountMismatch`; no defined capacity error |
| HE-AACv2 → 32 kHz FLAC, file and stdout; AAC-LC control | R5 confirmed; reference-decoded sample bytes equal |
| Ogg-output fault injection | R6 confirmed: 288 nonzero pipe exits still accepted as 145/145 |
| Superseded encoder-option values | R7 confirmed for FLAC, AAC and IMA WAV ADPCM |
| Exact known length on an Ogg stdin pipe; null-length and regular-file controls | R8 confirmed |
| Deterministic mutation smoke, seed `11082026` | 4,200 inputs sampled from 751 bounded fixtures across 14 container/codec groups; 0 abnormal exits and 0 timeouts |
| Markdown local-target scan | All 43 tracked Markdown files scanned; one missing target (`prefix.zig`) |
| Python compilation and `bash -n` | Passed for all 5 Python files and 20 shell scripts |
| `git diff --check` and final status | Checked when finalizing this report; only `codex-review.md` intentionally changed |

The fresh ReleaseFast summary splits the 676 tests into **668 `av` tests,
7 `io_patterns` tests and 1 `opus-compare` test**. The 416 successful build
steps also include the CLI process checks and prepared-file cases. Those
steps are not 416 additional unit tests. `fast-suite.log` records the process
case names and results; the runner reports the `av` tests in aggregate, so
individual names for all 668 were not captured. Debug and ReleaseSafe used
`--summary failures`; their successful logs are empty, and their zero exit
statuses were observed in the first-pass tool results.

Full comparison command:

```sh
python3 zig/testing/reference/compare.py \
  --ffmpeg .references/ffmpeg-install/bin/ffmpeg \
  --ffprobe .references/ffmpeg-install/bin/ffprobe \
  --zffprobe zig-out/bin/zffprobe --writer zig-out/bin/write-driver \
  --zffmpeg zig-out/bin/zffmpeg --registry zig-out/bin/registry-dump \
  --hasher zig-out/bin/hash-driver \
  --opus-vector-driver zig-out/bin/opus-vector-driver \
  --report /tmp/zffmpeg-branch-comparison.md
```

The mutation smoke used Debug tools, a 512 MiB address-space limit and a
two-second timeout per child. It varied bounded byte overwrites and
truncation, probing MP4 and converting other groups to raw s16le. This was
not coverage-guided fuzzing, an allocation-failure proof or a differential
mutation campaign. Existing allocation-failure and fuzz-seed tests ran as
part of the suites; no new exhaustive failure sweep, sustained fuzzer,
benchmark campaign or Windows/ARM/macOS execution was performed. Initial
compiler-cache writes blocked by the sandbox were rerun with granted cache
access; they were not counted as implementation failures.

### Complete reference-comparison coverage already executed

The following is the complete section ledger from the first-pass
`compare.py` run. Counts include the narrowly documented differences that
its predicates accepted; they do not all mean byte-identical outputs. R6
qualifies the strength of some acceptance predicates even though the
unmodified matrix passed.

<details>
<summary>All reference sections: 13,102 required and 66 optional cases</summary>

| Section | Kind | Passed | Failed | Missing or skipped | Notes |
| --- | --- | --- | --- | --- | --- |
| WAV fixtures (T02, T21) | required | 129 | 0 | 0 missing | 0 understood |
| Unknown length (T21b) | required | 13 | 0 | 0 missing | 0 understood |
| Registries (T16) | required | 112 | 0 | 0 missing | 0 understood |
| Content detection (T16) | required | 309 | 0 | 0 missing | 0 understood |
| AU fixtures | required | 40 | 0 | 0 missing | 0 understood |
| AIFF fixtures | required | 57 | 0 | 0 missing | 0 understood |
| CAF fixtures | required | 58 | 0 | 0 missing | 0 understood |
| Raw PCM fixtures (T22c) | required | 55 | 0 | 0 missing | 0 understood |
| Zig-written files read by FFmpeg | required | 71 | 0 | 0 missing | 0 understood |
| zffmpeg outputs (T13b, T23a) | required | 2326 | 0 | 0 missing | 2 understood |
| Dither (T23a) | required | 416 | 0 | 0 missing | 0 understood |
| Rematrixing (T23c) | required | 924 | 0 | 0 missing | 0 understood |
| Resampling (T24) | required | 56 | 0 | 0 missing | 0 understood |
| FFmpeg-written Wave64 (T21b) | required | 15 | 0 | 0 missing | 0 understood |
| FFmpeg's AU muxer | required | 12 | 0 | 0 missing | 0 understood |
| FFmpeg's AIFF muxer | required | 16 | 0 | 0 missing | 0 understood |
| zffprobe through a pipe | required | 309 | 0 | 0 missing | 0 understood |
| FLAC fixtures (T26a, T26b) | required | 57 | 0 | 0 missing | 8 understood |
| FLAC output (T26c) | required | 304 | 0 | 0 missing | 0 understood |
| Ogg output (T27b) | required | 145 | 0 | 0 missing | 0 understood |
| Ogg fixtures (T27a) | required | 37 | 0 | 0 missing | 2 understood |
| MP3 fixtures (T29a) | required | 71 | 0 | 0 missing | 1 understood |
| Ogg decoding (T27d, T28a) | required | 372 | 0 | 0 missing | 14 understood |
| MPEG audio decoding (T29b, T29c) | required | 852 | 0 | 0 missing | 11 understood |
| Leading ID3v2 tags (T30a) | required | 28 | 0 | 0 missing | 2 understood |
| ADTS fixtures (T30a, T30b) | required | 46 | 0 | 0 missing | 25 understood |
| AAC decoding (T30b to T30d) | required | 552 | 0 | 0 missing | 3 understood |
| ADPCM in WAV (T31a) | required | 661 | 0 | 0 missing | 63 understood |
| ALAC in CAF (T31b) | required | 429 | 0 | 0 missing | 51 understood |
| CAF output (T31b) | required | 358 | 0 | 0 missing | 3 understood |
| G.722 and G.726 in AU (T31c) | required | 251 | 0 | 0 missing | 4 understood |
| AC-3 and E-AC-3 (T32a, T32b) | required | 522 | 0 | 0 missing | 13 understood |
| MP4 fixtures (T33a1, T33a2) | required | 234 | 0 | 0 missing | 19 understood |
| G.722 and G.726 output (T31c) | required | 182 | 0 | 0 missing | 19 understood |
| MP2 output (T29d) | required | 324 | 0 | 0 missing | 20 understood |
| AC-3 output (T32c) | required | 691 | 0 | 0 missing | 62 understood |
| AAC output (T32d) | required | 1488 | 0 | 0 missing | 25 understood |
| Frame and stream hashes (T19b) | required | 580 | 0 | 0 missing | 26 understood |
| FATE Vorbis (T27d) | optional | 20 | 0 | 0 skipped | - |
| FATE E-AC-3 (T32b) | optional | 5 | 0 | 0 skipped | - |
| RFC 8251 Opus test vectors (T28) | optional | 24 | 0 | 0 skipped | - |
| FATE FLAC (T26b, T26c) | optional | 17 | 0 | 0 skipped | - |

</details>

### Complete focused-check ledger already executed

The commands and source snippets for R1–R8 above remain the reproduction
instructions. This ledger states which variants actually ran, so recommended
future regression coverage is not mistaken for completed validation.

| Check / variants executed | Observed result | Retained evidence |
| --- | --- | --- |
| R1: metadata self-append with `resize_fail_index = 0`, Debug | `TestExpectedEqual`; appended bytes are freed-memory poison | `alias.zig`, `alias.log` |
| R2: zero cookie channels with stereo CAF descriptor; reference and Zig probe, then WAV conversion, from files | Reference reports stereo and converts; Zig reports zero channels and exits 2, `InvalidFormat` | `zero-channels.caf`, `zero-channels-reference.wav`; result in R2 |
| R3: 48 kHz cookie with 44.1 kHz CAF descriptor; both probes and WAV conversions; reference ffprobe of both WAV headers | Both conversions succeed; reference WAV 48,000 Hz, Zig WAV 44,100 Hz | `cookie-rate.caf`, `cookie-rate-reference.wav`, `cookie-rate-zig.wav`; result in R3 |
| R4: AAC, MP3, native FLAC and Ogg Vorbis, one-byte destinations, Debug | All four abort at `frames > 0` | `short-aac.zig`, `short-mp3.zig`, `short-flac.zig`, `short-ogg.zig`, matching `.log` files and `short.*` fixture copies |
| R4: AAC one-byte destination, ReleaseFast | `FrameCountMismatch` | `short-aac-fast.log` |
| R5: HE-AACv2 and AAC-LC controls, each through the four stdout option combinations in the next table, with both tools | Only HE-AACv2 resampling to FLAC differs; the other seven combinations match | `aac_fdk_hev2_44k-{0,1,2,3}-{ref,zig}.bin`, `aac_ffmpeg_48k_64k-{0,1,2,3}-{ref,zig}.bin` |
| R5: HE-AACv2 → 32 kHz FLAC into regular files; reference inspection of block sizes and reference decoding of both files | 1,470 versus 727 samples/block; 83,845 versus 112,832 bytes; decoded PCM hashes equal | `he-resample-ref.flac`, `he-resample-zig.flac`; SHA-256 and sizes in R5 |
| R6: real Ogg-output comparisons with successful stdout conversions fault-injected to exit 1; existing predicate checks | Comparator still reports 145/145; 288 injected failures accepted; existing predicate checks pass | `oracle-faults.py`, `oracle-faults.md`; driver and outcome in R6 |
| R7: final 2,000-sample mono WAV, FLAC `bad`→`5`, AAC `bad`→`fast`, IMA WAV ADPCM `bad`→`1024`, both tools | All three reference commands succeed; all three Zig commands exit 1 before output creation | `repeated-input.wav`, `repeated-*-ref.*`; commands/results in R7 |
| R8: WAV with a supplied length, stdin from a regular file and a real pipe | Both controls succeed | `pipe-known.zig`, `pipe-known-test`, `pipe-known.log`; regular-file result observed in tool output |
| R8: same valid Ogg bytes on a real pipe, exact length 2,097 versus no supplied length | Exact length: `IoFailure`/`Unseekable`; no length: succeeds | `pipe-known-ogg.zig`, `pipe-known-ogg-control.zig`, matching test binaries and `*-test.log` files |
| R8: Ogg exact-length test with regular-file stdin, and ordinary zffprobe stdin pipe | Both controls succeed | Result observed in tool output; ordinary pipe report matches R8 |
| Mutation smoke: seed `11082026`, 4,200 mutated inputs, 751 eligible seed fixtures, 14 groups | 4,200 normal exits, zero abnormal exits and zero timeouts | `mutate.py`, `mutations.log`, `mutation-summary.json` |
| Documentation: tracked file inventory and local Markdown targets | 43 Markdown files; one missing path, `prefix.zig` | `inventory.txt`, `doc-audit.py`, `doc-audit.json` |
| Python syntax, shell syntax and report hygiene | Five Python files compile in memory; 20 scripts pass `bash -n`; report local links, pending-marker and whitespace checks pass | Results observed in tool output; no application test rerun needed for report edits |

The R5 stdout combinations, in scratch filename index order, were:

| Index | Output options after `-i` | HE-AACv2 `aac_fdk_hev2_44k.aac` | AAC-LC `aac_ffmpeg_48k_64k.aac` |
| --- | --- | --- | --- |
| 0 | `-ar 32000 -f flac -` | Both succeed; encoded bytes differ (R5) | Both succeed; equal bytes |
| 1 | `-dither_method triangular -f s16le -` | Both succeed; equal bytes | Both succeed; equal bytes |
| 2 | `-ar 32000 -dither_method triangular -f s16le -` | Both succeed; equal bytes | Both succeed; equal bytes |
| 3 | `-ar 32000 -f f32le -` | Both succeed; equal bytes | Both succeed; equal bytes |

The reference commands also used `-v error -bitexact`. These were two
fixtures × four option combinations × two tools, not a wider AAC profile,
rate or dither sweep. R2/R3's newly crafted CAF variants were tested from
files, not pipes. AC-3's R4 guard was inspected but not independently
executed. The capacity-boundary retry tests recommended in R4 were not run.

Exploratory setup failures are not passing tests or extra findings: the
initial eight-sample WAV made the reference FLAC encoder refuse its block
size (exit 234); R7 was then established using the 2,000-sample input. An
initial Ogg adapter diagnostic omitted `Options.gpa` and returned
`UnsupportedFormat`; the corrected R8 test supplied both allocators and
isolated length/seekability. A mistyped HE-AAC fixture name was missing and
was not tested. Compiler-cache permission failures were setup failures; the
corresponding checks were rerun successfully with cache access.

### Evidence locations and identity

All short filenames in the focused ledger are relative to
`/tmp/zffmpeg-branch-review-20261108/`. The full baseline comparison is at
`/tmp/zffmpeg-branch-comparison.md` (its captured output is
`/tmp/zffmpeg-branch-comparison.log`). The scratch build cache is
`/tmp/zffmpeg-branch-review-cache/`; Debug CLI binaries are under
`/tmp/zffmpeg-branch-debug/bin/`; the full matrix used the ReleaseSafe tools
installed in `zig-out/bin/`.

These `/tmp` artifacts were present when the handoff was written. They are
local, temporary evidence, not committed portable artifacts. Their absence
in another environment does not turn recorded executed checks into unrun
checks or require an automatic whole-suite rerun. Use the self-contained
commands/results here, and reproduce only the affected case when additional
verification is necessary. `extra-checks.py` ends by running the **whole
ReleaseFast suite**; do not execute it merely to inspect one reproducer.
`write-review.py` and `add-handoff.py` are report-writing helpers, not tests;
do not rerun them, as they can overwrite later review annotations.

Recorded SHA-256 values, for identifying reused evidence/binaries without
rerunning tests:

| Artifact | SHA-256 |
| --- | --- |
| `.references/ffmpeg-install/bin/ffmpeg` | `d807c19e518ffe8c420425743738abb9e96b70a1ce3a3422037f965319678cd4` |
| `.references/ffmpeg-install/bin/ffprobe` | `5cd95106f48d7ac66ae6285f60a990d18382eaa2a788565ebc79e80a01a99bcc` |
| `zig-out/bin/zffmpeg` (ReleaseSafe) | `495bdc3166c0657bd790d4335236ca28e6c738ccee7055919df493b9bb8ec458` |
| `zig-out/bin/zffprobe` (ReleaseSafe) | `03277591b480ca5788eba7247d1185d4f3b520f515970df2e51d0bae4cbcbe4c` |
| `fast-suite.log` | `4fb7911340e05bb0937e8f6d6c3e3bafbf2b931842f97954a40602f05468b534` |
| `/tmp/zffmpeg-branch-comparison.md` | `ff13b3b0cffed2066e6e5e319d049c9c2d1421850456b57781969f98d8965001` |
| `mutation-summary.json` | `75d3c192fe65315b4d4c137947c1011760659ddc530e8c4774606c199816b18e` |

## Recommended fix order

1. Fix R1 and retain the forced-moving-reallocation regression.
2. Fix R6's status checks and fault-inject all affected acceptance paths so
   subsequent green comparisons cover successful operations.
3. Share validated CAF/ALAC configuration for R2/R3; test the published
   format, resampling and independently probed output headers.
4. Fix R4 across every decoded reader and R5 at the decoded-frame boundary;
   test retry behavior and HE-AAC resampling combined with compressed output.
5. Fix R7's effective-option handling and R8's handle capability check; add
   process/pipe regressions for the demonstrated sequences.
6. Reconcile D1's current-state/help/lifetime statements, then take the
   focused T65 consolidation work with behavioral oracles retained.

Implementation changes and new regression fixtures are intentionally left
for the fixes; this review changes only this report.


## Second-pass review handoff

### Assignment and immutable target

Perform an independent **second review pass**, in English, over the current
code and docs of `claude/sharp-gates-hj8vww` at exactly:

```text
9c1e05e1457c69fc437a838295df0db6b247f405
```

This is a continuation of the whole-codebase review, not a review of a new
commit, the last commit's diff, or fixes for R1–R8. The code was not changed
by pass 1 or by this handoff. Work only on this snapshot; do not fetch,
switch branches, reset files, inspect repository history or compare against
another branch. Do not implement fixes, change tests/contracts, regenerate
fixtures/vectors, rebuild the FFmpeg reference, upgrade tools or commit.
Only `codex-review.md` may be intentionally edited; put new diagnostics in
a separate temporary directory and preserve the first-pass artifacts.

Start with read-only identity checks:

```sh
git branch --show-current
git rev-parse HEAD
git status --short
git diff --exit-code
zig version
```

Expected branch/HEAD are above, Zig is `0.17.0`, and the only expected local
change is this report (currently untracked as `?? codex-review.md`). A report
edit alone does not invalidate the code test results. If HEAD differs or
implementation/test/fixture/build inputs have changed, report the mismatch
and do not silently review another revision or restore this one. An
untracked implementation file is also a snapshot change; a clean tracked
diff alone does not establish identity.

Read `AGENTS.md`/`CLAUDE.md`, this report's findings and coverage limits,
`port.md`'s document authority, the affected fixture contracts, `notes.md`
and `doc/state-machines.md`. Load the applicable project skills, including
`zig-0-17` and its guide before writing any temporary Zig diagnostic;
`ffmpeg-oracle`, `ffmpeg-c-semantics`, `media-pipeline` and `zig-io` apply
where their respective boundaries are investigated.

### Reuse pass-1 validation

**Do not rerun the complete build/test suites, the 13,168-case reference
matrix, the same mutation smoke, fixture generation checks or formatting
checks simply because this is a new agent or review pass.** The execution
ledger above supplies the baseline evidence for this unchanged snapshot.
Do not describe inherited results as tests you personally reran in pass 2.

Use new targeted checks when they can establish a new hypothesis, resolve a
specific evidence uncertainty, exercise a previously untested call sequence,
or investigate suspected stale/corrupt artifacts. Missing temporary logs
alone are not a reason to start every suite again. If toolchain/reference
identity differs, do not transfer numerical conclusions to it silently;
identify the limitation and validate only what the new investigation needs.
If a focused result contradicts a first-pass baseline, investigate and state
that contradiction. A broad rerun needs a concrete unresolved reason and
should name that reason and scope in the pass-2 report.

No production Zig changes are authorized by this review assignment. If a
later user authorizes fixes, those changes create a new validation scope;
this reuse instruction is not an exemption from the repository's checks
for changed implementation code.

### Where the second pass should add coverage

Use the first-pass coverage table to choose concrete gaps. Prioritize:

1. **Ownership and failure transitions:** partial initialization,
   replacement/reconfiguration, read-ahead queues, allocation/remap failure,
   seek/reset recovery and retained borrowed views across demux/decoder/filter
   boundaries. Read complete affected functions and their callers.
2. **ReleaseFast input bounds and work limits:** externally supplied counts,
   offsets, timestamps, channel/rate changes, oversized claims in short files,
   and progress in parser/decoder/graph loops. Distinguish valid public calls
   from documented API precondition violations.
3. **Untested combinations:** actual decoder frame boundaries combined with
   resampling, channel mixing, dithering, compressed output and file/pipe
   capability differences. R5 shows why separately passing feature tests do
   not cover their combinations.
4. **Independent-oracle blind spots:** the unexecuted reference-status check
   in FATE Vorbis noted under R6, other normalization/refusal predicates,
   coverage selection, and fixture/vector expectations that could hide a
   failure. Use focused fault injection rather than rerunning the whole matrix.
5. **Architecture and documentation:** substantiate additional shared-state,
   typed-API or compile-time invariant opportunities with real duplicate
   consumers; check live contracts against implementation. Keep existing
   T54/T65 work, intentional differences and historical evidence distinct
   from newly demonstrated defects.

R1–R8 and D1 are already reported; do not count them again as new findings.
Reassess their claims if source or focused evidence warrants it, explicitly
recording any correction. AC-3's R4 instance remains source-inspected, not
runtime-confirmed; new targeted validation there can strengthen an existing
finding. The full C-generator rebuilds, sustained coverage-guided fuzzing,
new exhaustive failure sweeps, speed studies and cross-platform execution
were not performed in pass 1; they are not implied second-pass assignments.
Select a bounded new check only when it serves the review question.

### Required second-pass output

Append `## Pass 2 — independent review of the same snapshot` to this file.
Keep the first-pass findings, evidence and executed-test ledger identifiable;
do not replace them with second-pass claims or change their counts. Include:

- Verified branch/HEAD and relevant working-tree/environment observations.
- The additional files/functions and risk paths actually inspected.
- New confirmed findings starting at **R9** (new documentation items at
  **D2**), with priority, precise location, trigger, expected/actual behavior,
  governing contract/reference, correction and focused regression coverage.
- Corrections to or stronger evidence for existing findings under their
  original IDs, without counting them as new defects.
- A **pass-2-only** check ledger: exact commands, build modes, inputs, actual
  outcomes, expected diagnostic failures and retained artifact paths. Mark
  reused pass-1 checks as inherited, not rerun.
- Remaining untested hypotheses and coverage limits, separate from confirmed
  findings. If no additional actionable defect is established, say so.

Before finishing, check the report's links/formatting and verify that only
`codex-review.md` was intentionally changed. A documentation-only handoff or
second-pass report edit does not require another application test run.
