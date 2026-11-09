# Codex review: pass 1 — complete current branch

Review date: 2026-11-08.

| Item | Reviewed value |
| --- | --- |
| Branch | `claude/sharp-gates-hj8vww` |
| Snapshot | `355ed43be6369d8b6cb3cf440468e6756f7193fc` |
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
without automatically repeating those baseline checks. Pass 2 is appended at
[the end](#pass-2--independent-review-of-the-same-snapshot): it records the
HEAD change since this handoff, adds D2, and reports no new functional defect.

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
355ed43be6369d8b6cb3cf440468e6756f7193fc
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

## Pass 2 — independent review of the same snapshot

Review date: 2026-11-08.

### Identity, inheritance and one snapshot correction

| Item | Pass-2 value |
| --- | --- |
| Branch | `claude/sharp-gates-hj8vww` |
| HEAD | `355ed43be6369d8b6cb3cf440468e6756f7193fc` (`355ed43 z`) |
| Pass-1 snapshot named by the handoff | `355ed43be6369d8b6cb3cf440468e6756f7193fc` |
| Difference from the pass-1 tree | `to-review.md` only (43 insertions, 23 deletions); no Zig, test, fixture, build or CI input changed |
| Starting working tree | `?? codex-review.md`; `?? review-skill.md`; `to-review.md` is tracked and committed at this HEAD |
| Compiler / host | Zig `0.17.0`, Linux x86-64 |
| Pass-1 results | Inherited for every unchanged source, test and fixture path; no baseline suite or reference matrix was rerun |
| Repository edits | This report only; `review-skill.md` was not modified |

The `review-skill.md` untracked file is another review artifact. It is not implementation,
test, fixture or build input and does not change the snapshot's code identity.

### What pass 2 actually inspected

Pass 2 concentrated on the handoff's remaining gaps:

- Ownership and failure transitions around `caf.Parser`'s ALAC header path, `cafmux`,
  `flacmux`, `oggmux`, `graph`/`negotiate`, `metadata`, `id3v2`, `apetag`,
  `vorbiscomment`, `chapters`, `seek` and `wav`'s seek position.
- ReleaseFast and capacity behavior of the decoded readers, including Ogg Opus, which
  pass 1 had exercised for Vorbis only.
- Untested combinations of decoded frame boundaries with resampling, channel rematrixing,
  dithering and compressed output. This is the gap R5 identified.
- The public `av` facade, module headers and README current-state prose, which the pass-1
  documentation sweep did not cover beyond Markdown link targets.

No production code, test, fixture, contract or build file was changed.

### Findings

No new functional correctness or ownership defect (R9) was established. The pass-2
differential sweeps below agree with the pinned reference except where R2 and R5 already
record the difference, and the one additional FLAC refusal is the documented
`FrameCountMismatch` policy rather than a new root cause.

One new documentation finding remains. It is a reportable defect under the same Low
severity as D1, but it is not a code defect.

#### D2 — [Low] The public facade and module headers describe superseded subsets

**Locations:** [zig/root.zig:8](zig/root.zig#L8),
[zig/root.zig:39](zig/root.zig#L39),
[zig/root.zig:45](zig/root.zig#L45),
[zig/root.zig:47](zig/root.zig#L47),
[zig/root.zig:111](zig/root.zig#L111),
[zig/root.zig:113](zig/root.zig#L113),
[zig/root.zig:118](zig/root.zig#L118);
[zig/format/caf.zig:15](zig/format/caf.zig#L15);
[zig/format/convert.zig:4](zig/format/convert.zig#L4);
[zig/io/file.zig:3](zig/io/file.zig#L3);
[README.md:12](README.md#L12), [README.md:39](README.md#L39) and
[README.md:173](README.md#L173);
[notes.md:227](notes.md#L227) and [notes.md:228](notes.md#L228).

**Trigger:** read the exported `av` facade or the module's first documentation block, which
is what a user or a new agent sees first.

**Expected versus actual:**

| Location | Current statement | Current implementation |
| --- | --- | --- |
| `root.zig:8` | `pcm` is "signed 16-bit PCM sample conversion" | [zig/codec/pcm.zig:5](zig/codec/pcm.zig#L5) covers u8, s8, s16/s24/s32/s64, f32/f64 in both byte orders, A-law and µ-law, plus the stage wrappers |
| `root.zig:39` | `au` is "signed 16-bit big-endian PCM" | [zig/format/au.zig:5](zig/format/au.zig#L5) covers µ-law, s8, s16/s24/s32, f32/f64 and A-law |
| `root.zig:45` | `caf` is "linear PCM, A-law and µ-law" | The same module reads ALAC ([zig/format/caf.zig:286](zig/format/caf.zig#L286)), and `cafmux` writes CAF |
| `root.zig:47` | `flac` is "native FLAC with 16-bit samples" | The decoder handles 4 to 32 bits per sample; the contract and fixtures include 20-, 24- and 32-bit streams |
| `root.zig:111` | `convert` covers "WAV/Wave64/AU/AIFF" | The operation matrix includes FLAC, Ogg, CAF, MP2, AC-3, ADTS AAC, ADPCM, G.72x and ALAC output |
| `root.zig:113` | the filter graph is a "linear chain of anull, aformat, volume and aresample" | [zig/filter/filters.zig:50](zig/filter/filters.zig#L50) has eleven filters, including `atrim`, `asetpts`, `asplit`, `channelsplit`, `channelmap`, `pan` and `amix`; `initGraph` has several sources and sinks |
| `root.zig:118`, `io/file.zig:3` | adapters are "for the WAV and AU paths" | `probeFile` and `decodeFile` are the adapter path for every supported container, including Ogg and FLAC |
| `caf.zig:15` | "The parser is sequential and never seeks" | The ALAC path seeks past `data` to a `pakt` after it and back ([zig/format/caf.zig:308](zig/format/caf.zig#L308)); the seeker requirement is the reason a pipe refuses that layout |
| `convert.zig:4` | "CAF as input only" | `Conversion.init` has a `.caf` output branch and `cafmux` writes PCM and ALAC |
| `notes.md:227` | CAF is "Read only (T22d)"; "the registry has no CAF muxer" | `cafmux` exists, `registry.zig` has a CAF muxer, and the T31b contract and CAF output section exercise it |
| `notes.md:228` | "never seeking" | The ALAC path seeks past `data` to a `pakt` and back, as the CAF contract's ALAC row says |
| `README.md:12`, `README.md:39`, `README.md:173` | CAF is PCM/A-law/µ-law only, FLAC is 16-bit only, and `pcm.zig` is signed-16-bit only | Same implementation facts as above; the later README sections already describe the wider FLAC and filter support, so the opening summary contradicts the rest of the file |

**User impact:** the facade is the first thing an API user reads, and the module headers are
the first thing a maintainer reads. These statements make ALAC-in-CAF, CAF output, 20- to
32-bit FLAC, multi-input filter graphs, and non-WAV/AU file adapters look absent. The CAF
"never seeks" sentence is stronger than a missing capability: it is a false I/O contract.
An ALAC `pakt` after `data` is reachable only through a seeker; code written on the belief
that the CAF parser never seeks would break that path or mis-handle a pipe.

**Root cause:** each task updated its contract, TODO row and detailed module comments, but
not the short facade entries or the README opening summary. The pass-1 D1 sweep checked
Markdown link targets and a named set of support statements; it did not compare these
shorter prose summaries with the implementations.

**Correction:** update the facade entries to the current supported subsets; state that CAF
is PCM plus ALAC and that ALAC may seek; remove "input only" from `convert.zig`; describe
the file adapters by their role rather than by the first two containers; align the README
opening with its own later sections. No behavior change is implied.

**Regression coverage:** documentation only. A cheap guard is to extend the existing local
documentation audit to the facade's capability sentences, but that risks encoding prose.
At minimum, add a review checklist item that a widened format or filter also updates
`zig/root.zig` and the README opening. No runtime test can catch this class.

This is adjacent to D1 but covers different files and a different artifact (source and
facade documentation rather than support/help text). It is not a split of a code defect.

### Corrections and stronger evidence for pass-1 findings

- **R2:** the pass-1 trigger and result stand. The pass-2 CAF cookie sweep set the cookie
  channel byte to 1, 3, 4, 8 and 9 and the sample-size byte to 0, 17, 20, 24, 32 and 48 on
  `alac_new_kuki.caf`. The invalid cookie values are refused by both tools at probe or
  conversion (the 1- and 3-channel probes open on both sides, then both conversions fail);
  only zero channels reproduces R2's probe/conversion mismatch. A `chan` chunk whose count
  differs from `desc` is ignored by the reference's `ff_mov_read_chan` because the count
  already differs, so the effective fallback is the decoder context's layout, not
  `caf.zig`'s `desc` count alone. The recommended correction should pass that effective
  layout through, not reconstruct a count from `desc`.
- **R4:** the Ogg Opus reader has the same capacity defect, not only Ogg Vorbis. A
  one-byte destination after `oggdecode.DecodedReader.readHeader()` aborts at
  [zig/format/oggdecode.zig:256](zig/format/oggdecode.zig#L256) with
  `std.debug.assert(frames > 0)`. This is an additional instance of the existing finding,
  not a new one. AC-3 remains source-inspected: `av.ac3decode` is still not exported from
  `zig/root.zig`, so the pass-2 diagnostic could not be compiled through the public module.
- **R5:** the pass-2 combination sweep reproduces the AAC/SBR splitting and confirms it is
  not a general decoded-reader problem. Opus, Vorbis, native FLAC, MP3, AAC-LC and AC-3
  inputs with `-ar 32000` into FLAC were byte-identical to the reference. HE-AACv2
  resampled to 32 kHz remains the only resampled compressed-output mismatch found.
- **D1:** the pass-1 locations remain correct. D2 adds the untracked facade/module/README
  surface; the two findings should be fixed together but are listed separately because D1
  already had an executed audit trail and D2 did not.

### Pass-2-only check ledger

Pass-1 checks remain inherited. Everything below was newly executed in pass 2 from the
repository root; scratch files are under `/tmp/opencode/` and `/tmp/zffmpeg-branch-review-20261108/`.
The reference binaries and `zig-out/bin` tools are the pass-1 artifacts whose recorded
SHA-256 values are in the pass-1 ledger.

| Check | Inputs and options | Observed result |
| --- | --- | --- |
| Identity | `git branch --show-current`, `git rev-parse HEAD`, `git status --short`, `zig version` | Branch and HEAD above; `?? codex-review.md`, `?? review-skill.md`; Zig `0.17.0` |
| Tool identity | `sha256sum` of the reference `ffmpeg`/`ffprobe` and `zig-out/bin/zffmpeg`/`zffprobe` | All four hashes equal the pass-1 ledger; the focused comparisons used the same binaries |
| Decoded input → FLAC, rate change | 8 inputs (Ogg Opus ×2, Ogg Vorbis, Ogg FLAC, native FLAC, MP3, AAC-LC, AC-3 5.1) with `-ar 32000`; reference `-bitexact` | All 8 byte-identical |
| Decoded input → s16le/FLAC, resample + dither | 5 inputs (Ogg Opus, Ogg Vorbis, MP3, AAC-LC, native FLAC) × 4 option sets (`-ar 32000`/`11025`/`48000`, triangular dither, `s16le`/FLAC) | All 20 byte-identical |
| Rematrix + resample + compressed output | 3 inputs (AC-3 5.1, Ogg Opus multistream, HE-AACv2) × 4 option sets (`-ac 2`/`1`, `-ar 32000`, FLAC/s16le, dither) | 10 identical; 2 HE-AACv2 → FLAC cells differ as R5; remaining 0 failures |
| FLAC input → ALAC CAF | `flac_bps20_lpc`, `flac_bps24`, `flac_bps32_left_side_fixed` | 20- and 32-bit byte-identical; `flac_bps24` fails with the recorded empty-stream `FrameCountMismatch`, the same policy as its FLAC→WAV difference |
| Decoded input → ALAC CAF | IMA ADPCM, Microsoft ADPCM and G.722 inputs × 3 option sets | All 9 byte-identical |
| G.726 input → ALAC CAF | G.726 2- and 5-bit inputs × 2 option sets | All 6 byte-identical |
| CAF ALAC cookie variants | `kuki` channel bytes 0/1/3/4/8/9; sample-size bytes 0/17/20/24/32/48; probe and WAV conversion | Zero channels reproduces R2; the other invalid sizes/counts are refused by both tools, and 4/8-channel probes agree |
| CAF ALAC `chan` probe | 5.1 `chan` inserted before `kuki`, cookie channels 0 | Reference reports the `desc` count (2); Zig reports 0/`unknown`; this is R2, with the fallback correction noted above |
| Ogg Opus one-byte `readData`, Debug | `ogg_opus_stereo.ogg`, after `readHeader` | Aborts at `oggdecode.zig:256` (`frames > 0`), confirming R4's Ogg Opus instance |
| Facade/module documentation audit | `rg` over `zig/root.zig`, `zig/format/caf.zig`, `zig/format/convert.zig`, `zig/io/file.zig`, `README.md`; source comparison | D2's table; no runtime check |
| Report hygiene | `git diff --check`, Markdown target scan for the edit, final `git status --short` | `git diff --check` reports no whitespace error; final status is ` M codex-review.md` and `?? review-skill.md`. `codex-review.md` is staged in the index at its pass-1 version (a pre-existing index state not created by this pass); this pass's appended section and its one-sentence top pointer are the unstaged difference. Only `codex-review.md` was intentionally changed. |

The focused diagnostics are `/tmp/opencode/short-opus.zig`, `/tmp/opencode/short.ac3`,
`/tmp/opencode/short.ogg` and the generated CAF variants `/tmp/opencode/caf-*.caf`. The
`short-opus` test is expected to abort in Debug; it is evidence, not a passing suite.

### Remaining hypotheses and limits

- The CAF ALAC fallback is still only source-traced for a `chan` layout whose count differs
  from `desc`: the reference's `ff_mov_read_chan` keeps the existing count on a mismatch,
  so the effective value depends on the order and validity of `desc`/`chan`. A future
  fixture should pin the interaction before R2's correction is called complete.
- AC-3/E-AC-3's R4 instance was not executed because `ac3decode` is not in the public
  `av` module. The release-fast behavior is inferred from the identical source guard.
- The pass-2 differential sweep covered the listed fixtures and options, not every codec
  profile, rate, layout or allocator-failure path. It did not rerun the 13,168-case matrix,
  the mutation smoke, the full suites or the fixture generator.
- D2 is prose-only. No check yet prevents the facade or README from drifting again.
- No performance measurement was repeated; no cross-platform runtime or CI run was
  performed. No other branches or historical repository versions were accessed.

### Pass-2 assessment

Pass 2 adds no new blocker. The pass-1 assessment still governs: R1 is the first fix, then
R2/R3 configuration, R4/R5 capacity boundaries, R6 oracle statuses, R7/R8 CLI behavior and
D1/D2 documentation. D2 is a Low documentation defect, not a reason to reopen the code
findings. The absence of a new functional finding in the sampled combinations is evidence
for those combinations only, not proof that the remaining unswept input space is clean.

## Pass 3 — whole-codebase review of the selected snapshot

The current codebase has a substantial native Zig implementation and unusually broad executable comparisons with FFmpeg; the ownership boundaries and several shared algorithms are thoughtfully designed. This pass covered the whole source tree by subsystem, with deeper tracing of shared demuxing, metadata ownership, MP3, conversion, filter scheduling, and the current MOV work, and sampled the larger codec kernels. Three actionable defects remain: an aliased metadata append can read freed storage, continuously nonempty filter queues retain consumed storage, and FLAC header parsing loses a packet's discard flag. Unit tests pass in all three requested modes, but the local differential run is not a clean reference-platform certification because its Clang and glibc differ from the documented oracle.

Review date: **2026-11-09**. Snapshot: **`3f74b4f27c6d1c21585a6b3d52c7ddd32472aac1`**. The working tree was clean when this review began. This third pass is appended to `codex-review.md`; the first two passes above are preserved unchanged.

### Relationship to the earlier passes

Passes 1 and 2 record snapshot `355ed43be6369d8b6cb3cf440468e6756f7193fc`; this pass reviews the later selected `3f74b4f` snapshot. No comparison of implementation history was performed. The validation below was executed for this pass and is not inherited from either earlier ledger; its compiler/libc environment also differs, so the results must remain identifiable by pass.

- **R1** is independently reconfirmed by a source trace. It retains its original ID and is not counted as a new defect. The earlier runtime reproduction remains part of the earlier pass's evidence, not a check rerun here.
- **R9** and **R10** are the two additional findings from this pass: retained filter FIFO storage and lost FLAC discard flags.
- **R2–R8 and D1–D2** remain recorded above. This pass did not individually revalidate their earlier triggers against this snapshot and does not close or reclassify them. The assessment below covers this pass's findings and limits; it does not replace the earlier assessments.


### 1. Confirmed findings: R1 reconfirmed, R9–R10 added

These findings are confirmed by tracing the current implementation and its contracts. Their triggering API sequences were **not executed in separate probe programs**; no observed crash, memory measurement, or runtime flag result is claimed. This follows `to-review.md`'s requirement to give a precise, explicitly untested source argument when demonstrating the issue would require a separate probe program.

| ID | Severity | Defect | Reachability |
| --- | --- | --- | --- |
| R1 | High | Self-appending a borrowed metadata value can read its old, freed allocation | Public dictionary API, with an ordinary short value and moving reallocation |
| R9 | Medium | Filter FIFOs keep consumed prefixes while a small live backlog remains | Normal repeated sends and receives; also an `amix` input with a constant lead |
| R10 | Low | The FLAC header parser clears `DISCARD` | Public generic demux layer supplied a discard-marked FLAC packet |

No Critical finding was established.

#### R1 — High: metadata append invalidates an aliased source before copying it

**Location:** `zig/core/metadata.zig:122–138`, particularly the reallocation at line 132 and the copy at line 134. Public entry points and borrowing contract: lines 30–31 and 85–96.

**Trigger and expected behavior.** Start with an empty `metadata.Dictionary`, put `"title" = "AB"` using `.replace`, obtain `value = dictionary.get("title").?`, and pass that value to `put(gpa, "title", value, .append)`. The expected value is `"ABAB"`. This uses two ordinary bytes, a valid borrowed value at call entry, and the documented operation that adds copies of its key and value. There is no disjoint-input precondition on `put`.

**Actual behavior and source trace — untested at runtime.**

1. The first `put` duplicates the two-byte value. Its recorded capacity is zero, meaning the allocation is the value slice itself.
2. `appendTo` saves the old entry and duplicates the new key. The `value` argument still points into the old value allocation.
3. The requested length is four; the old allocation holds two. The growth policy requests at least sixteen bytes.
4. If the allocator cannot grow that allocation in place, `gpa.realloc` allocates another region, preserves the old bytes there, and frees the original region.
5. The subsequent `@memcpy` uses the original `value` slice. It therefore reads the freed allocation instead of the preserved bytes in `storage`.

A conforming allocator may move this allocation during normal growth. The result can be incorrect metadata or an invalid-memory failure; the ownership defect exists independently of whether a particular allocator happens to leave the old bytes readable. Debug, ReleaseSafe, and ReleaseFast all use the same erroneous source slice. The same issue applies to a nonempty subslice of the old value when growth moves it.

**Contract and FFmpeg evidence.** The module promises owned copies and failure atomicity at lines 16–19; `put` explicitly promises copies at lines 91–92. `notes.md`, “Metadata dictionary and WAV tags,” specifies `AV_DICT_APPEND` behavior. In pinned FFmpeg's `libavutil/dict.c:av_dict_set`, `copy_value = av_strdup(value)` happens before the append branch's `av_realloc(tag->value, len)` and `memcpy`. The reference protects an aliased source before invalidating the stored value. The ordinary `.replace` path in the Zig implementation also duplicates the value before freeing the old entry.

**Impact and scope.** This is a public-library ownership defect, not a demonstrated malformed-file problem. The MOV vectors exercise normal metadata appends, but their independently supplied fragments do not establish safety for this API sequence. Existing dictionary append tests likewise use independent fragments. It is High because valid API arguments can become a freed-memory read inside an operation that promises to copy them.

**Focused correction.** Preserve an aliased source before reallocating. A narrow implementation can recognize a source wholly inside the old value, retain its offset, and rebase it onto the new allocation after successful growth; alternatively, copy the aliased fragment before growing. Preserve key/value alias handling, entry ordering, failure atomicity, and amortized linear behavior for repeated independent appends.

**Regression needed.** Append a complete borrowed value and a borrowed subslice using an allocator that forces the growth to move. Cover sufficient existing capacity, moving growth, and allocation failure; assert exact value/order and leak-free cleanup in all three modes. Include a key borrowed from the dictionary so that a fix does not regress the already protected key path. No implementation or test change was made in this review.

#### R9 — Medium: filter queues retain consumed storage for the lifetime of a nonempty stream

**Locations:**

- `zig/filter/graph.zig:744–760`: append to the link's `ArrayList`, advance `head`, and reclaim logical space only when completely empty. Storage is declared at lines 181–183.
- `zig/filter/multi.zig:742–746` and `847–851`: append input samples to each plane, advance `start`, and reset only after consuming the entire plane. FIFO representation is at lines 647–654.

These are two instances of the same storage-management defect: consumed prefixes are not reused while any unread suffix remains.

**Trigger A: a graph link — untested at runtime.** Configure a graph with no filters between a source and sink and `max_queued_frames = 2`. Send two small frames and receive one; thereafter repeatedly send one frame and receive one. This is legal under the limit: the live queue alternates between one and two frames.

`sendTo` copies and queues the frame without running the scheduler. `receiveFrom` consumes one queued frame and returns it. Each cycle therefore increments both `fifo.items.len` and `head`, preserving a difference of one after the receive. The `head == items.len` branch is never taken. After N such cycles, the backing array contains O(N) descriptors despite only one unread frame. The queue-limit counter decrements correctly, so the configured limit does not prevent this storage growth.

**Trigger B: an `amix` input — untested at runtime.** Use two ordinary float inputs. Give input 1 three equal-sized blocks, then repeatedly supply one block to input 0, take one mixed output, and replenish input 1 by one block. Input 1 remains only two to three blocks ahead. Its `Fifo.start` advances with every output, but every new block is appended after all historical bytes; the FIFO never becomes empty and no consumed prefix is reclaimed.

**Expected versus actual.** Storage should be proportional to peak live backlog, apart from normal allocation slack. Instead, the link keeps historical descriptors and `amix` keeps historical PCM bytes until the queue finally empties or the graph is destroyed. For a continuously ahead 48 kHz stereo f32 input, the latter retains another `48000 × 2 × 4 = 384000` sample bytes per second processed, before allocation slack. This is a source-derived cost, not a measured memory benchmark.

The graph's consumed frame payloads are released through the ordinary ownership path; this is not a claim that every consumed frame payload leaks. `deinit` also releases the arrays. The defect is growing memory demand during a long-lived, otherwise bounded stream, eventually allowing allocation failure unrelated to the live backlog.

**Contract and FFmpeg evidence.** `port.md`, “Filter graph,” specifies FFmpeg's queuing/scheduling and `amix` behavior. `Graph.Options.max_queued_frames` documents the graph queue limit. FFmpeg's `libavfilter/framequeue.c:ff_framequeue_add/ff_framequeue_take` reuse circular slots; `libavutil/audio_fifo.c:av_audio_fifo_write/av_audio_fifo_read` use the reusable `AVFifo` storage. Neither requires a completely empty queue before consumed space becomes reusable. The current Zig `MixRun.frames` already uses `std.Deque`; that separate frame-information queue is not the problem.

**Focused correction.** Use a deque/ring for the link descriptors. For sample planes, use a sample FIFO with reusable front space, or compact a consumed prefix at a growth/threshold boundary. Keep planes synchronized and preserve timestamps, frame grouping, queue counts, and cleanup. Moving the entire unread suffix on every sample consumption would introduce avoidable repeated copying; amortize the compaction.

**Regression needed.** Hold a constant one-frame link backlog and a constant two-block secondary mix backlog across many small, normal blocks. Assert exact samples/PTS/order and a plateau in backing capacity after warm-up. Exercise packed and planar stereo, close/drain, queue limits, and allocation failure. A short test that drains every queue completely between writes will miss this defect.

#### R10 — Low: FLAC header parsing drops the discard flag

**Location:** `zig/format/demux.zig:1452` in `Layer.parseFlac`; related named flags at lines 333–335 and the correct mask in `parseRaw` at line 1325.

**Trigger and expected behavior.** A source using the public `Layer(Source)` supplies a valid complete FLAC frame with `Setup.parser = .flac_headers` and `Packet.flags` containing `discard_flag` (`4`). Such a packet can be decoded for state while its output is not presented. The generic parsing layer should preserve discard and corrupt, and independently compute key status.

**Actual behavior and source trace — untested at runtime.** `parseFlac` executes `h.flags &= 2`. That keeps only `corrupt_flag`; it clears `discard_flag`, despite the accompanying comment saying both pass. `computePktFields` can then add `key_flag` for a known intra-only stream, but never restores discard. A known intra-only FLAC packet starting with flags `4` consequently leaves with `1` instead of `5`; flags `6` leave with `3` instead of `7`.

**Contract and FFmpeg evidence.** `ParserKind.flac_headers` explicitly models `AVSTREAM_PARSE_HEADERS`. Pinned `libavformat/demux.c:parse_packet` preserves `AV_PKT_FLAG_DISCARD | AV_PKT_FLAG_CORRUPT` at line 1315. The neighboring Zig full-parser path uses exactly that named mask. Losing discard changes the output-inclusion instruction seen by a library consumer.

**Reachability limit.** This is a generic demux API defect. The built-in Ogg FLAC source uses this parser mode, but this pass did not establish a current built-in fixture that supplies the discard bit there. MOV's current FLAC setup does not establish that trigger either. No existing CLI output failure is attributed to this finding; its narrow present reachability is why it is Low.

**Focused correction and regression.** Replace the numeric mask with `discard_flag | corrupt_flag`. Feed an existing valid FLAC frame through a small test source with flags `0`, `2`, `4`, and `6`; check both preserved bits and computed key status after parsing, including queued/read-ahead delivery. This needs no new large or malformed media input.

### 2. Ranked Zig modernization opportunities

These are architectural improvements, separate from the defects above. Savings below are estimates, not measured reductions or performance claims. The appropriate direction is small shared mechanisms around clear contracts; codec arithmetic, format-specific error precedence, and independent reference tests should remain explicit.

| Rank | Opportunity | Expected benefit | Implementation risk |
| --- | --- | --- | --- |
| 1 | Share the pending decoded-sample cursor and emission bookkeeping | High across several readers | Medium: partial reads and end conditions are observable |
| 2 | Consolidate registry/tag coverage and filter construction metadata | Moderate; fewer parallel declarations per added component | Low to medium |
| 3 | Route codec options through typed groups using existing specifications | Moderate; removes repetitive parsing/error paths | Medium: shared option precedence matters |
| 4 | Centralize sample element types while keeping arithmetic types local | Modest, broadly useful | Low |
| 5 | Encapsulate metadata value ownership and capacity | Moderate ownership clarity | Medium if the public entry layout changes |
| 6 | Give demux packet flags a typed operation boundary | Modest, directly prevents mask mistakes | Low if kept internal |

#### 2.1 Share decoded-output bookkeeping, without merging decoder state machines

**Repeated code:** `zig/format/mp3decode.zig:179–201`, `aacdecode.zig:178–197`, and `ac3decode.zig:177–196` have nearly identical pending-range subtraction, output-frame capacity calculation, expected-count validation, float interleaving, and cursor/delivered updates. Related readers in `oggdecode.zig` and `cafalac.zig` have similar storage bookkeeping with additional format-specific behavior. `zig/format/decoded.zig` already supplies `Header`, `Discard`, `ErrorRate`, and `interleave`, so there is a natural existing home for the genuinely common part.

**Proposed design:** A small `PendingSamples` or `DecodedCursor` value holds the pending range, delivered count, and optional expected count. An emission helper takes caller storage, channel count, and the actual decoded planes. Keep `nextFrame`, packet ownership, skip-sample application, stream reconfiguration, decoder errors, and codec-specific draining in each reader. The first extraction can remain f32-specific because the three identical paths already are; introduce a compile-time sample type only when a second real packing type needs the same algorithm.

This would remove roughly dozens of lines per reader and, more usefully, provide one place to reason about advancing the cursor after a successful copy. It should not claim that all `readData` APIs have identical undersized-buffer semantics: the compressed readers currently document/assert a minimum output frame, while the shared PCM path explicitly returns `OutputTooSmall`. Preserve or deliberately reconcile that contract before expanding the helper's reach.

**Validation/tradeoffs:** Compare complete and irregular partial reads, small output chunks satisfying each API's contract, gapless trimming, an empty stream, a final short frame, count mismatches, refusal recovery, and format changes. Keep the per-codec FFmpeg comparisons and allocation-failure tests. Avoid a generic object carrying function pointers to every decoder operation; that adds indirection and obscures error sets for little reduction in duplication.

#### 2.2 Let tags and descriptors establish exhaustive registry coverage

**Repeated declarations:** `zig/filter/filters.zig:50–117` lists filter identities in `Kind`, descriptors, union fields, and the default-construction switch. Its existing compile-time check correctly rejects duplicate names and name/tag disagreement, but does not itself establish one descriptor for every kind. `zig/codec/registry.zig:65–84` repeats the same non-PCM tag list in three methods; its `compressed` list and implementation tables are further places to keep synchronized.

**Proposed design:** Derive the filter kind from a tagged `Filter` union, or retain the public kind and add exhaustive descriptor-coverage validation. Generate only uniform default construction through a compile-time tag switch, with `anull` explicit. A descriptor can name its configuration type and constructor when default construction is not uniform. Keep runtime name lookup simple; there are eleven filters, so a more elaborate lookup structure has no demonstrated need.

For codecs, use a small typed descriptor list for metadata and compile-time checks that every codec has exactly the intended descriptor/implementations. Simplify methods whose only distinction is the PCM payload, while ensuring a future payload-bearing codec forces a deliberate update. Preserve ordering, decoder/encoder availability, aliases, and external names; those are observable registry data, not incidental formatting.

**What disappears:** Repeated tag enumerations and one default initializer per uniform filter; manual coverage bookkeeping can become compile-time validation. Savings are on the order of tens of lines, with the greater benefit in safe component additions. Keep algorithm-specific `queryFormats`, `init`, `deinit`, pads, and runtime activation separate where their contracts differ.

**Validation/tradeoffs:** Compile-time missing/duplicate descriptor checks, every filter's creation/error path, graph and multigraph vectors, and registry comparison against the independent C reference. Use the project's current Zig 0.17 reflection conventions. Do not silently skip a missing declaration with `@hasDecl`; a missing lifecycle method should be an explicit exception or a diagnostic.

#### 2.3 Reuse typed option metadata for the CLI routing layer

**Repeated code:** `zig/cli/ffmpeg.zig:404–447` repeats consume-next-argument, missing-value handling, typed `av.options.set`, invalid-value handling, and continuation for FLAC, ADPCM, G.726, AAC, and AC-3. Lines 532–580 repeat searches over each type's `option_specs`. The option declarations themselves already have a good shared implementation in `zig/core/options.zig`; this opportunity concerns the remaining routing duplication.

**Proposed design:** A small compile-time tuple of option groups names the target options type, its field in a typed CLI-options aggregate, and its explicitly excluded/shared names. One helper recognizes a group-owned option and sets the correctly typed target. Perform the common argument-consumption/error path once. Validate unexpected name collisions at compile time; represent intentionally shared codec-context options separately.

**Preserve:** Input/output option phases, the present missing/invalid diagnostics, aliases, repeated-option behavior, unused options for another encoder, and shared `b`, `cutoff`, quality and profile handling. In particular, AAC intentionally excludes several names from its direct option list. A generated first-match search without that policy would change behavior.

**What disappears and tradeoffs:** Several near-identical branches and lookup helpers, perhaps 40–80 lines net. Keep the typed group list visible and small; generating the entire CLI parser from a schema would make positional rules and useful diagnostics harder to inspect. Validate every current codec option group, shared names, aliases, repeated values, and failures before output creation, then run the affected encode comparisons. No runtime speedup is assumed.

#### 2.4 Make the sample element type a property of the sample format

**Repeated mappings:** `zig/resample/resample.zig:132`, `dither.zig:496`, and `rematrix.zig:755` independently map `.s16p/.s32p/.fltp/.dblp` to `i16/i32/f32/f64`. `resample/audioconvert.zig` has its own private `Kind.Type`. `zig/core/audio.zig:SampleFormat` already owns byte size and packed/planar relationships.

**Proposed design:** Add a compile-time `SampleFormat.Element` function returning the underlying Zig storage type, shared by packed and planar forms. The contract is simply `@sizeOf(Element(format)) == format.bytesPerSample()`. Keep an explicit internal-format restriction at each DSP entry point: accepting a type mapping does not mean that every algorithm supports every sample format.

This removes repeated type switches, probably a few tens of lines. Keep rematrix accumulator widths (`Inter`), fixed-point filter shifts, clipping order, signedness, and float precision local to the algorithms; these are different arithmetic contracts. This is a small use of compile-time specialization, not a reason to fuse resampling, rematrixing, and dithering into one template.

**Validation/tradeoffs:** Instantiate every supported storage format, check size mappings, and retain sample-conversion, dither, rematrix, and resampler vectors in all modes. Do not add channel-count specialization without a measured benefit; multiplying format-pair/channel/rate specializations can inflate compile time and machine code.

#### 2.5 Separate the dictionary's owned representation from borrowed entry views

**Weak invariant:** `zig/core/metadata.zig:30–38` exposes `value` and a separate capacity sentinel, with `storageOf` reconstructing the allocation behind the public slice. R1 is one consequence of needing to track both a borrowed source and an allocation owner through mutation.

**Proposed design:** Internally use an `OwnedEntry` whose value is an owned growable byte buffer, and expose a borrowed entry view containing only key/value slices. Put append/clone/free and alias handling next to the owning buffer. A zero-capacity sentinel and public allocation bookkeeping can disappear. Merely changing the container type does not fix R1: append still needs an explicit alias policy.

**Risk and validation:** `Dictionary.entries` is currently exposed, so privatizing or changing it may affect callers. Prefer the narrow R1 fix first; consider the representation change alongside a deliberate API migration. Preserve order, case-insensitive lookup, duplicate policies, exact allocation sizes, clone independence, and failure atomicity, including the alias regressions above. This may save little source code; its value is making invalid ownership combinations harder to construct.

#### 2.6 Use named flag operations at the demux boundary

**Weak invariant:** `zig/format/demux.zig` carries raw `u32` packet flags through `Packet`, `Held`, and parser transitions, although `zig/core/packet.zig:32` already has named packet flag fields. R10 is a concrete wrong-mask example.

**Proposed design:** First use the existing named constants everywhere. If the raw representation continues to spread, add a small internal flag wrapper with `key`, `corrupt`, `discard`, and a named operation for the flags a parser preserves. Explicit conversion at the FFmpeg-compatible integer boundary should retain any bits the public contract requires; avoid assuming that all future packet flags are exhausted by these three.

**Benefit/tradeoffs:** The direct fix is one line and should not wait for a representation change. A wrapper has modest source savings and introduces conversion points, but makes preservation policy reviewable in one place. Validate flags through direct packets, header parsing, full parsing, buffering, seeking, and framecrc/vector output. This does not justify replacing every timestamp sentinel or wire integer with a large new abstraction.

### 3. Open questions and optional suggestions

#### 3.1 Re-run the live oracle on its documented compiler and libc

The local reference uses the correct FFmpeg revision and component configuration but **Clang 19.1.7 and glibc 2.41**. `notes.md`, “Sample format conversion / Undefined C cases,” records Clang **23.1.4** behavior, and `zig/testing/reference/README.md` requires glibc **2.44 or newer**. This is an observed prerequisite mismatch, not a reason to change expected samples or widen tolerances.

The conversion differences below have a concrete explanation: local reference disassembly uses a 32-bit `cvtss2si` destination where the documented build uses a 64-bit destination. The MP3 tag difference is the documented `sscanf` change. Nevertheless, a clean end-to-end run on the intended platform is still needed; this review did not build that complete environment and cannot certify it from the older host's results.

An optional improvement is to have the local reference workflow check and record the compiler, libc, and a few established behavior cases before running the full comparison. CI already checks the libc requirement and records a compiler cache identity. The local build accepts whichever `clang` is on PATH, while the documented undefined-C results depend on its code generation. A behavior check would make a mismatch explicit without altering the port's intended output.

#### 3.2 Decide whether decoded-reader buffer preconditions should converge

`format/pcmdata.zig` deliberately returns `OutputTooSmall` if data remains and the output cannot hold a frame. Several compressed readers instead document the minimum size and assert that at least one frame fits. Neither policy should be silently changed during refactoring, and the existing precondition means a below-minimum call is not established here as a library defect.

A future public-API cleanup could choose consistent checked errors, or make the minimum capacity more visible through a shared query/helper. Resolve this against callers and `port.md` before adopting the cursor abstraction proposed above. Valid small-buffer, EOF, and zero-length-output tests would then pin the chosen policy.

#### 3.3 Runtime portability and larger codec corpora remain open

The Windows GNU, Linux AArch64 musl, and macOS AArch64 builds succeed, but no executable was run on those targets. This matters especially for intentionally emulated x86 C-conversion results, floating-point operation ordering, byte order, unaligned accesses, filesystem identity, and pipe behavior. Native runs using the documented policy are the evidence needed; compile success alone cannot settle those questions.

The optional FATE Vorbis/E-AC-3/FLAC and RFC Opus corpora were absent. They remain useful follow-up coverage for decoder modes and combinations beyond the small committed fixtures. Their absence is reported separately from required-case failures.

#### 3.4 Keep documented exclusions out of the defect list

No defect is claimed merely because MOV currently exposes the documented audio demux/probe/metadata/chapter subset rather than full MOV conversion, or because a container rejects one of its explicitly unsupported variants. Likewise, the filter contract explicitly excludes EOF timestamps; the source's EOF timestamp handling is therefore not reported as an unimplemented promised behavior. The separately documented Ogg granule/timestamp differences and safe refusals remain subject to their narrow comparison checks, not blanket exceptions.

### 4. Pass-3 validation and coverage

#### 4.1 Snapshot and scope controls

| Item | Observed value |
| --- | --- |
| Requested target | `claude/sharp-gates-hj8vww` only |
| Actual checkout state | Detached HEAD at the previously selected `3f7` snapshot; `git branch --show-current` is empty |
| Snapshot identifier | `3f74b4f27c6d1c21585a6b3d52c7ddd32472aac1` |
| Initial `git status --short` | Empty |
| Local implementation changes included | None |
| Intentional repository edit | This `codex-review.md` report only |
| Native validation platform | Linux x86-64 |
| Zig | `0.17.0` |
| Local C reference toolchain | Debian Clang `19.1.7`, glibc `2.41` |
| FFmpeg reference source | `5d5a38a7e46be296eab75982c0986054f731e19e` |

This review used only the selected checkout's code. **No other branch contents or historical versions of this repository were accessed.** There was no fetch, checkout, merge-base computation, branch diff, commit, or publication. An initial identity check displayed the current commit subject and refs containing the selected commit; it did not read another version of the code. The detached state is stated explicitly rather than presenting it as an attached local branch.

The governing sources were `to-review.md`, `AGENTS.md`/`CLAUDE.md`, `port.md`, current `TODO.md` evidence, `notes.md`, `zig/README.md`, fixture contracts, and `zig/testing/reference/README.md`. The Zig 0.17 skill/guide and applicable C-semantics, media-pipeline, and FFmpeg-oracle guidance were consulted. Existing review conclusions were not used as evidence for the findings in this pass.

No implementation, tests, contracts, manifests, or expected vectors were changed. No process limits, core-dump settings, or signal handling were changed. Temporary commands and results are under `/tmp/zff-validation`; normal ignored build/reference artifacts were produced. The first two passes are preserved byte for byte; only this third-pass section is appended. A copy of the earlier text remains at `/tmp/zff-validation/codex-review-before.md`.

#### 4.2 Builds and repository tests

Commands were run from `/workspace/zffmpeg` with the pinned compiler on PATH:

```sh
export PATH=/workspace/.zffmpeg-tools/bin:$PATH
export ZIG_GLOBAL_CACHE_DIR=/workspace/.cache/zig

zig version
zig fmt --check build.zig build.zig.zon zig/
zig build --summary all
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build -Doptimize=ReleaseSafe install test-tools --summary all
python3 zig/testing/fixtures/generate.py --check
```

| Check | Outcome |
| --- | --- |
| Compiler version | `0.17.0`, exit 0 |
| Formatting | Pass, exit 0 |
| Debug build | Pass, exit 0 |
| Debug tests | **676/676 tests**, 416/416 build steps, exit 0 |
| ReleaseSafe tests | **676/676 tests**, 416/416 build steps, exit 0 |
| ReleaseFast tests | **676/676 tests**, 416/416 build steps, exit 0 |
| ReleaseSafe install and test tools | Pass, exit 0 |
| Fixture regeneration check | Pass, exit 0; manifests and README tables current |

The fixture check covers **776** primary fixtures: 129 WAV, 40 AU, 57 AIFF, 25 raw PCM, 58 CAF, 57 FLAC, 37 Ogg, 71 MP3, 46 ADTS, 41 ADPCM, 33 ALAC, 23 G.72x, 24 AC-3, 18 E-AC-3, and 117 MP4.

The CI-equivalent compile-only checks were also run, with separate installation prefixes and limited build concurrency:

```sh
for target in x86_64-windows-gnu aarch64-linux-musl aarch64-macos; do
    zig build -j2 -Dtarget="$target" -Doptimize=ReleaseSafe \
        -p "/tmp/zff-validation/cross-$target" --summary all
done
```

All three returned **exit 0, 7/7 steps succeeded**. These are compile-only results.

`build.zig`, the root imports, and CI wiring were inspected. A static literal-import reachability check found no orphan among the checked library files with test declarations, and a direct check of `zig/examples/*.zig` found every example registered in `build.zig`. These structural checks do not prove branch coverage inside a test or that every algorithm has an independent oracle.

Logs: `results.jsonl`, `test-debug.log`, `test-safe.log`, `test-fast.log`, `build-tools.log`, `fixtures.log`, `cross-results.txt`, and `cross-*.log` under `/tmp/zff-validation`.

#### 4.3 Pinned-source FFmpeg comparison: completed, failed on this host

The existing local reference source's revision was verified. The repository build script successfully built and installed the configured reference:

```sh
bash zig/testing/reference/build-ffmpeg.sh /tmp/zff-validation/ffmpeg-install

python3 zig/testing/reference/compare.py \
    --ffmpeg /tmp/zff-validation/ffmpeg-install/bin/ffmpeg \
    --ffprobe /tmp/zff-validation/ffmpeg-install/bin/ffprobe \
    --zffprobe zig-out/bin/zffprobe \
    --writer zig-out/bin/write-driver \
    --zffmpeg zig-out/bin/zffmpeg \
    --registry zig-out/bin/registry-dump \
    --hasher zig-out/bin/hash-driver \
    --opus-vector-driver zig-out/bin/opus-vector-driver \
    --report /tmp/zff-validation/reference-report.md
```

The build returned **0**. The comparison returned **1**:

- Required cases: **12,909 passed, 193 failed, 0 missing**.
- Optional cases: **0 passed, 0 failed, 66 skipped**.
- Failure messages: **194**, because one failed MP3 case reports both duration and framecrc differences.

“Passed” is the harness's count, which includes its explicitly checked, documented differences and refusals; it does not mean every accepted case has identical whole-file bytes.

| Failing required group | Cases | Investigation |
| --- | ---: | --- |
| General zffmpeg conversions | 90 | Float-input conversions affected by the local reference's integer-conversion behavior |
| Rematrixing | 75 | Float-input output conversions affected by the same behavior |
| MPEG audio decoding/conversion | 16 | Two fixtures, eight output paths each; their direct decoded f32 samples match exactly, while conversion to s16 differs |
| Frame/stream hashes | 11 | Decoded float-input streamhash cases, which hash the converted integer samples |
| MP3 demux/probe | 1 | `mp3_itunsmpb_bare_0x`, the documented glibc `sscanf` difference |

The first four groups total **192** cases. They are recorded as failed checks, with the toolchain-dependent explanation below; they are not silently removed from the result or relabeled as passes.

**Direct conversion evidence.** The following commands were run on the existing eight-sample WAV fixture:

```sh
zig-out/bin/zffmpeg -y \
    -i zig/testing/fixtures/wav/f32_mono_8k.wav \
    -f s16le /tmp/zff-validation/f32-ours.s16

/tmp/zff-validation/ffmpeg-install/bin/ffmpeg -v error -nostdin -y \
    -i zig/testing/fixtures/wav/f32_mono_8k.wav -bitexact \
    -f s16le /tmp/zff-validation/f32-ffmpeg.s16
```

Both succeed and produce 16 bytes. For fixture samples `(0, -0, 1, -1, 0.5, +inf, smallest f32 subnormal, NaN)`, the results are:

```text
Zig:        0, 0, 32767, -32768, 16384,      0, 0,      0
Local C:    0, 0, 32767, -32768, 16384, -32768, 0, -32768
```

Zig's result is the rule explicitly documented in `notes.md` and `resample/audioconvert.zig`: a 64-bit `lrint` result narrowed to its low 32 bits before clipping. The local reference object's disassembly was inspected with:

```sh
objdump -d --disassemble=conv_AV_SAMPLE_FMT_FLT_to_AV_SAMPLE_FMT_S16 \
    .references/ffmpeg-build/libswresample/audioconvert.o
```

It contains `cvtss2si %xmm1,%r11d`, a **32-bit** destination, explaining the disagreement with the documented Clang 23 reference. No new media or extreme-value probe was introduced; these values are already in the committed fixture.

For each of `mp3_mpeg25_l3_8k` and `mp3_mpeg2_l3_16k_mono`, direct file conversions were also run with both tools using `-f s16le` and `-f f32le` (the C reference additionally used `-v error -nostdin -bitexact`). Every command returned 0. Raw f32 outputs were byte-identical: **39,168** and **32,256** bytes respectively. Raw s16 outputs differed at **8** and **51** sample positions, respectively, consistent with the downstream conversion behavior. This evidence does not support filing an MPEG decoder arithmetic bug from those sixteen comparison failures.

**MP3 metadata evidence.** Re-running the existing MP3 C vector generator differed only in `mp3_itunsmpb_bare_0x`. Its local duration numerator is `9135360` versus the committed/Zig `9202788`, with corresponding duration/bitrate and final skip-sample changes. The README explicitly records that glibc 2.44 changes a bare `0x` field from the older `sscanf` behavior to a matching failure. This host is 2.41, so the live oracle is outside that prerequisite.

**Successful required groups.** All remaining required groups in the report pass. Selected substantial checks include:

| Group | Passed/total |
| --- | ---: |
| Content detection | 309/309 |
| Probe file/pipe equivalence | 309/309 |
| Dither | 416/416 |
| Resampling | 56/56 |
| FLAC fixtures | 57/57 |
| FLAC output | 304/304 |
| Ogg fixtures | 37/37 |
| Ogg decoding | 372/372 |
| AAC decoding | 552/552 |
| ADPCM paths | 661/661 |
| ALAC decoding | 429/429 |
| CAF output | 358/358 |
| G.722/G.726 decoding | 251/251 |
| AC-3/E-AC-3 decoding | 522/522 |
| MOV/MP4 probing, files and pipes | 234/234 |
| G.722/G.726 output | 182/182 |
| MP2 output | 324/324 |
| AC-3 output | 691/691 |
| AAC output | 1,488/1,488 |

Optional skips are **20 Vorbis FATE**, **5 E-AC-3 FATE**, **17 FLAC FATE**, and **24 RFC 8251 Opus cases**. Their samples were unavailable locally; they were not downloaded during this review. Detailed failure text and tables remain in `/tmp/zff-validation/compare.log` and `reference-report.md`.

#### 4.4 Independent refresh of selected existing C vectors

Selected existing generators were compiled against the freshly built static libraries, run into temporary files, and compared byte for byte with the committed vectors. No expected file was regenerated in the repository.

The temporary orchestration command was `python3 /tmp/zff-validation/check-vectors.py`. It used this command structure for the first eight rows below:

```sh
clang -O1 -I/tmp/zff-validation/ffmpeg-install/include \
    zig/testing/reference/GENERATOR_vectors.c \
    /tmp/zff-validation/ffmpeg-install/lib/libavfilter.a \
    /tmp/zff-validation/ffmpeg-install/lib/libavformat.a \
    /tmp/zff-validation/ffmpeg-install/lib/libavcodec.a \
    /tmp/zff-validation/ffmpeg-install/lib/libswscale.a \
    /tmp/zff-validation/ffmpeg-install/lib/libswresample.a \
    /tmp/zff-validation/ffmpeg-install/lib/libavutil.a \
    -lm -pthread -o /tmp/zff-validation/GENERATOR-vectors
```

`GENERATOR` is `samplefmt`, `pcm`, `layout`, `graph`, `multigraph`, `mp3`, or `mov`. The first five take no arguments. MP3 takes all sorted `zig/testing/fixtures/mp3/*.mp3` paths; MOV takes all sorted `.mp4/.m4a/.mov/.3gp/.3g2` fixture paths. The MOV pipe run adds `-pipe` before those paths. The commands are compiled C oracle generators already supplied by the project, not newly written reproduction programs.

| Vector set | Build/run result | Comparison with committed expectations |
| --- | --- | --- |
| `samplefmt.txt` | Exit 0 / 0 | Exact |
| `pcm.txt` | Exit 0 / 0 | Exact |
| `layout.txt` | Exit 0 / 0 | Exact |
| `graph.txt` | Exit 0 / 0 | Exact, including the 93 graph cases |
| `multigraph.txt` | Exit 0 / 0 | Exact, including the 48 graph cases |
| `mp3.txt` | Exit 0 / 0 | Only `mp3_itunsmpb_bare_0x` differs; 21 diff lines |
| `mov.txt` | Exit 0 / 0 | Exact across the 117 fixtures |
| `mov_pipe.txt` | Exit 0 / 0 | Exact across the same fixtures in pipe mode |
| `sampleconv.txt` | Exit 0 / 0 | 264/280 lines exact; 16 float/double-to-u8/s16 `edge` lines differ |

The sample conversion generator was run separately to investigate the compiler difference:

```sh
clang -O1 -I/tmp/zff-validation/ffmpeg-install/include \
    zig/testing/reference/sampleconv_vectors.c \
    /tmp/zff-validation/ffmpeg-install/lib/libswresample.a \
    /tmp/zff-validation/ffmpeg-install/lib/libavutil.a \
    -lm -pthread -o /tmp/zff-validation/sampleconv-vectors
/tmp/zff-validation/sampleconv-vectors > /tmp/zff-validation/sampleconv-vectors.txt
```

Only the established `edge` cases converting packed/planar float or double into packed/planar u8 or s16 differ; all other vector lines match. This corroborates the conversion explanation while preserving the recorded failure. Outputs, stderr, and diffs are retained in `/tmp/zff-validation/*-vectors.*`.

#### 4.5 Source coverage and its limits

This is a whole-codebase, risk-based review, not a claim that every line of the codec/DSP implementations received an independent mathematical audit. Complete affected functions and their relevant callers were traced for the findings. The following distinguishes deeper review from sampling:

| Subsystem | Source work and evidence | Remaining limits |
| --- | --- | --- |
| MP3/MPEG demuxing | Header/VBR paths, Xing/LAME/iTunSMPB, setup, duration/skip metadata, seeking integration, MPEG header/parser behavior and ID3 boundaries; 71 fixtures and refreshed packet vectors | Not a new exhaustive proof of every ID3 frame combination or MPEG resynchronization sequence |
| Shared demux/probe/seek | Parser selection, packet queues, flag propagation, duration/PTS computation, skip injection, reset/seek relationships and format detection | Full timestamp search space and every source-adapter combination not exhaustively exercised |
| Core ownership and APIs | Dictionary mutation/clone/free, packet/frame ownership, sample storage sizing/copying, send/receive contracts, option metadata and relevant arithmetic helpers | The entire expression evaluator, every rational edge, and every libm routine were not independently re-derived |
| PCM containers | Shared `pcmdata` read/skip/decode flow; representative WAV/RF64/Wave64, AU, AIFF, CAF and raw header/data/limit paths, metadata and cleanup | Many individual chunk/tag variants were covered by fixtures and source sampling rather than full manual traversal |
| FLAC/Ogg | Shared parser interaction, selected packet/header/seek logic, Ogg saved-state and metadata replacement ownership, conversion integration | Not every page reconstruction, seek rollback, or FLAC predictor combination independently audited |
| MOV/MP4 | Input buffering/history, sample selection/finalization, stream setup, metadata/chapter lifetime and end-time handling; refreshed file/pipe vectors | Large box/sample-table/tag parsers were sampled; external real-world MOV corpus and unsupported track types not audited |
| Lossy decoders | MPEG/AAC/Vorbis/Opus/AC-3 entry points, selected initialization/deinitialization, reconfiguration, output bounds, error paths and decoded-reader integration | Bulk AAC SBR/PS, SILK/CELT, Vorbis and AC-3/E-AC-3 DSP bodies and generated tables received sampling plus existing tests, not a line-by-line algorithm proof |
| ADPCM/ALAC/G.72x | Container/decoder ownership transfers and selected initialization/data paths, current fixture/oracle comparisons | Entire prediction and trellis implementations not manually re-derived |
| Encoders and muxers | Public setup, integration/refusal/flush boundaries and selected cleanup; current FLAC, MP2, AAC, AC-3, ADPCM, ALAC, CAF and G.72x comparisons | Rate-control, psychoacoustic and quantizer internals mainly sampled; no independent quality benchmark |
| Conversion/CLI/I/O | `Conversion` setup and owned-parser cleanup, output preflight, sample counting, option routing, file identity/output acquisition and cleanup, file/pipe behavior | Existing tests establish many late-error paths; no new OS-specific fault-injection campaign or native non-Linux execution |
| Filters/resampling | Graph send/receive/scheduler/queue paths, `MixRun`, selected split/map/PTS behavior, shared conversion/rematrix/resample structure and lifecycle | No measured steady-backlog memory test; no new combinatorial graph or every resampler coefficient audit |
| Build/CI/test oracle | Compiler pin, test/example wiring, mode/target checks, fixture generation, selected comparison acceptance/refusal logic and known-difference checks | Sustained fuzzing, full vector regeneration, optional external corpora, and the documented compiler/libc platform were not completed |

**Oracle quality observations.** The comparison harness checks successful output content, statuses and named refusals; it does not treat any two failures as sufficient agreement in the sampled paths. Several known-difference checks constrain the allowed change to timestamps/granules or compare against a precisely adjusted input, and stale exceptions can fail the run. These are useful safeguards. They do not cover the three ordinary API sequences in the findings, and fixture agreement does not establish steady-state memory bounds.

**Checks deliberately not claimed:** No new Zig probe programs, no runtime reproduction of R1, R9, and R10, no sustained fuzz campaign, no native Windows/ARM/macOS execution, no independent regeneration of every codec/libm vector, and no clean full comparison on Clang 23/glibc 2.44. These limits constrain confidence particularly in unexamined DSP combinations and platform behavior. They do not remove the concrete source-level ownership and state defects above.

### 5. Concrete strengths

- **Native implementation with a separate oracle.** The library and tools implement the algorithms in Zig; the pinned C libraries are used for test evidence. Independent C generators and end-to-end programs expose more than self-consistent Zig round trips.
- **Purposeful existing abstractions.** `format/pcmdata.zig` already centralizes PCM data handling across containers; `format/decoded.zig` shares discard/error/interleave mechanisms. The resampler's `EngineIn(comptime format, comptime counting)` and the PCM/sample-conversion kernels use static specialization for real algorithm variation. Recommending another general PCM framework would duplicate work already done.
- **Explicit ownership and failure cleanup in many high-risk paths.** Allocators and readers are passed explicitly; owned packet/frame operations are distinguishable from borrowed views. The inspected Ogg metadata replacement stages the new allocation before freeing the old one, and dictionary clone/ordinary replacement have careful cleanup. R1 is a specific gap within that otherwise useful discipline.
- **Typed option specifications.** `core/options.zig` validates option metadata against fields/defaults at compile time and shares parsing/range behavior. The remaining CLI repetition can build on that foundation.
- **Meaningful validation breadth.** All 676 tests pass in Debug, ReleaseSafe, and ReleaseFast; fixtures are current; graph and MOV vectors independently refresh exactly on this host. The reference report separates required failures, documented differences, and absent optional corpora.
- **Scope and arithmetic policies are documented.** Container limits, intentional FFmpeg differences, unsupported subsets, and C floating/integer quirks are described concretely enough to distinguish a defect from an unsupported operation or an unsuitable oracle build. The observed float-conversion discrepancy demonstrates why that documentation matters.

### 6. Pass-3 assessment

**Blocking fixes required.** R1 is the principal blocker: an ordinary public metadata operation can read freed storage. R9 should be fixed before relying on continuously buffered, long-lived filter graphs; its storage demand grows with total processed input rather than live backlog. R10 is a small, focused packet-flag correction.

The source does not call for wholesale redesign. Small ownership/queue fixes and targeted typed abstractions offer a better maintainability return than unifying distinct codec algorithms. The passing unit suites and substantial successful reference groups provide useful evidence, but approval should also include the new regression sequences and a clean differential run on the documented compiler/libc platform. This assessment concerns the selected snapshot on its own merits and makes no claim about merge compatibility or unreviewed platform behavior.


## Implementation follow-up — 2026-11-09

The branch fixes R1–R10 and reconciles D1–D2. The earlier review passes
remain the record of their inspected snapshots.

| Finding | Correction and regression evidence |
| --- | --- |
| R1 | `metadata.Dictionary.appendTo` saves an aliased source offset and rebases after realloc. Tests cover borrowed keys, self-append, substrings, spare capacity, forced moving growth and allocation/remap failures. |
| R2/R3 | CAF, probing and ALAC decoding derive effective channels, layout, storage and rate from `alac.Config`. Zero cookie channels use `desc`; the cookie rate reaches output headers while duration keeps the descriptor clock. Both cookie styles, matching and differing rates, a conflicting `chan` count, zero/invalid rates, file/pipe paths and allocation failures are covered. |
| R4 | Shared capacity/count validation and float delivery replace assertions across AAC, MPEG audio, AC-3/E-AC-3, Ogg and native FLAC. `OutputTooSmall` preserves samples for retry. Eight reader paths compare zero/short/exact and irregular deliveries with an uninterrupted decode, then drain to stable EOF. |
| R5 | AAC's storage bound includes SBR's 2048 samples; conversion keeps the established 1024-sample dither grouping separately. HE-AAC/HE-AACv2 and LC controls resampled into FLAC/Ogg match the reference with rematrixing, file/pipe inputs and file/pipe outputs. |
| R6 | Ogg-output pipe commands, FLAC comparison generation and both reference decodes must succeed before comparison. The FATE Vorbis comparison also checks reference success. Shared predicates reject failed commands with complete stdout and missing/wrong artifacts. Live fault injection of 288 late command failures rejects all 144 affected Ogg cells. |
| R7 | Typed encoder groups collect the final raw value per spelling before validation and apply effective values in argument order, with explicit shared-name exclusions and compile-time collision checks. All five option families have process and reference checks for replacement, later codec selection and final-invalid preflight. |
| R8 | `probeFile` selects positional I/O and its automatic seeker from the actual handle kind, independently of supplied length. Process cases exercise Ogg and raw PCM through real pipes and redirected regular files with known/unknown lengths. |
| R9 | Link descriptors and synchronized amix planes reuse consumed prefixes at amortized growth boundaries. amix reserves all planes before publishing samples/frame information. Constant-backlog tests assert capacity plateaus, samples/order/PTS, drain and allocation-failure cleanup for packed and planar storage. |
| R10 | FLAC header parsing preserves `discard_flag | corrupt_flag`. Tests check all four combinations through parser queues and read-ahead, including allocation/remap failures; the generic-layer fuzz corpus now includes Ogg FLAC. |
| D1/D2 | Updated facade/module summaries, allocation and lifecycle contracts, CAF scope and seeking, AAC/ADTS help, current task introductions, reference configuration narrative and the historical replay link. Changed documentation has no broken local-path targets. |

The focused Zig improvements also centralize sample element types in
`SampleFormat.Element`, derive compressed codec coverage from the codec
union, check exhaustive filter descriptor coverage and generate uniform
filter construction from tags. The existing public dictionary representation
is retained; its ownership/API migration and the larger FLAC/Ogg/filter
redesigns continue under T54/T65.

The speed checker additionally uses a real pipe instead of regular-file
redirection, pins both producer and consumer to the measured CPU, and
propagates producer failures with `pipefail`.

### Validation of the fixes

Host: Linux x86-64, Zig 0.17.0, glibc 2.44. The reference source and installed
build are revision `5d5a38a7e46be296eab75982c0986054f731e19e`, Clang 23.1.4,
assembly disabled.

| Check | Result |
| --- | --- |
| `zig build test -j4 --summary all` | 416/416 steps; 675/675 library tests passed; unchanged example/metric runs retained cached passes. |
| `zig build test -j3 -Doptimize=ReleaseSafe --summary all` | 416/416 steps; 675/675 library tests passed. |
| `zig build test -j3 -Doptimize=ReleaseFast --summary all` | 416/416 steps; 675/675 library tests passed. |
| Final CAF test compilation/execution in all three modes | Passed after simplifying the test's cookie-offset expression and clarifying parameter docs. |
| Debug, ReleaseSafe and ReleaseFast builds; ReleaseSafe test tools | Passed. |
| Formatting, Python compilation and `git diff --check` | Passed. |
| Fixture `generate.py --check` | All 776 fixtures, manifests and generated README tables current. No committed media/vector expectations changed. |
| Full pinned FFmpeg comparison | **13,216 required passed, 0 failed, 0 missing; 66 optional passed, 0 failed, 0 skipped**. Includes 114 new required combination checks. Existing named differences/refusals retain their predicates. |
| Status/artifact predicate checks and live Ogg fault injection | Passed; all 144 affected cells reject 288 injected late failures. |
| Compile-only cross builds, ReleaseSafe, `-j2` | x86_64-windows-gnu, aarch64-linux-musl and aarch64-macos: each 7/7 steps, exit 0. |
| HE-AACv2 → 32 kHz FLAC reproducer | Both tools produce 83,845 bytes with 1,470-sample blocks, SHA-256 `c7fefbd20770e0475cc6ebea0ab1daf36c0d54e781d5eba8bd22fb8a9ab46e56`. |
| Speed check, repeated HE-AACv2 → 32 kHz FLAC | Five runs on core 2: zffmpeg file 0.507 s, real pipe 0.509 s, pinned reference 0.439 s, native reference 0.295 s. 1.15x/1.16x pinned reference, file/pipe 1.00x; no warning threshold reached. |

Full comparison command:

```sh
python3 zig/testing/reference/compare.py \
  --ffmpeg .references/ffmpeg-install/bin/ffmpeg \
  --ffprobe .references/ffmpeg-install/bin/ffprobe \
  --zffprobe zig-out/bin/zffprobe --writer zig-out/bin/write-driver \
  --zffmpeg zig-out/bin/zffmpeg --registry zig-out/bin/registry-dump \
  --hasher zig-out/bin/hash-driver --opus-vector-driver zig-out/bin/opus-vector-driver \
  --report /tmp/zffmpeg-review-reference.md
```

Local logs and generated reports are `/tmp/zffmpeg-review-{debug,safe,fast,install,fixtures,cross,faults,combinations,final-caf,speed}.log`,
`/tmp/zffmpeg-review-reference.{log,md}`, the per-target cross logs, and
`/tmp/zffmpeg-review-speed/speed.json`. Existing corpus seeds, mutation smoke
and allocation sweeps ran in the suites; this follow-up does not claim a
new sustained fuzz campaign, native non-Linux execution or a new CI run.
