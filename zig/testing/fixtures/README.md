# WAV fixtures: the first WAV contract

This is the canonical fixture contract for the
[first WAV contract](../../../port.md#first-wav-contract) (TODO.md T02). Every rule
there has at least one named fixture here with its expected result. The WAV
parser (T06), I/O adapters (T07), writer (T08) and end-to-end verification
(T10) test against these files.

## Files and commands

| Path | Role |
| --- | --- |
| [generate.py](generate.py) | Defines every fixture and builds its bytes with the Python standard library, independently of the Zig code. |
| `wav/<name>.wav` | The fixture files. Never edit them by hand. |
| [manifest.zon](manifest.zon) | Expected results and SHA-256 for each file, imported at compile time. |
| [../fixtures.zig](../fixtures.zig) | Loads the manifest, embeds every file, and checks each hash. |

From the repository root:

```bash
python3 zig/testing/fixtures/generate.py           # rewrite the files, manifest and the table below
python3 zig/testing/fixtures/generate.py --check   # fail if any output is missing or stale
zig build test                                     # includes the fixture integrity test
```

CI runs both checks. A missing fixture file fails the build, because
`fixtures.zig` embeds each one with `@embedFile`. A changed file fails its
SHA-256 test. A `.wav` file that `generate.py` does not produce fails
`--check`. To change a fixture, edit `generate.py` and rerun it; never edit the
outputs.

## Expected results

- **accept**: the stream is valid. The manifest gives `channels`,
  `sample_rate` and the interleaved `samples`; the frame count is
  `samples.len / channels`. Every accepted stream is `wav`, `pcm_s16le`, `s16`,
  and `mono` or `stereo`. Duration is `frames / sample_rate`, unreduced (see
  port.md "Initial probe output").
- **reject**: the contract error the parser must return. When the error is
  found after audio has been produced (for example `duplicate_data`), the
  frames before it may already have been delivered; callers must not assume
  atomic output.
- **writer output**: the T08 writer, given the accepted channels, rate and
  samples, must produce these bytes exactly: RIFF header, a 16-byte tag-1
  `fmt ` with `byte_rate = rate * block_align`, and `data`.

## Decisions

T02 had to settle the contract's open boundary cases and some unclear wording.
FFmpeg's behavior is from `libavformat/wavdec.c` and `riffenc.c` at the pinned
revision. That demuxer ignores `riff_size` entirely and stops at end of input,
so most of the bounds rules here are stricter than FFmpeg's on purpose.

| Case | Decision | FFmpeg |
| --- | --- | --- |
| Final odd-sized chunk whose pad byte is missing at EOF | If `riff_size` excludes the pad byte, the pad lies outside the extent and is not read: accept (`odd_final_chunk_pad_outside_extent`). If `riff_size` counts it, the input is short: `Truncated` (`odd_final_chunk_pad_missing`). | Accepts both. |
| A chunk, including `data`, whose declared size runs past the RIFF extent | `InvalidRiff`, found from the chunk header before its body is read (`data_exceeds_riff_extent`, `chunk_exceeds_riff_extent`). | Reads `data` up to its declared end or EOF. |
| `riff_size` disagrees with the input length | Input longer than the extent: the extra bytes are ignored (`trailing_bytes_after_riff`). Input shorter: `Truncated` (`riff_size_exceeds_input`). A known input size may report this before any audio; otherwise it appears while reading. | Ignores `riff_size`. |
| Fewer than 8 bytes of extent left where a chunk header should start | `InvalidRiff` (`partial_chunk_header_in_extent`). | Stops at EOF. |
| `riff_size` sentinels | 0 and 0xFFFFFFFF are unknown sizes: `UnsupportedStreamingSize`. 1 to 3 cannot hold the form type: `InvalidRiff`. | Ignores `riff_size`. |
| `fmt ` declaring fewer than 16 bytes | `InvalidFormat`: a complete but malformed chunk (`fmt_size_14`). Input ending inside `fmt ` is `Truncated` (`fmt_truncated`). This is what the contract's "short fields are truncated" means. | Rejects. |
| `fmt ` sizes other than 16, or 18 with `cbSize == 0` | `UnsupportedFormat`. | Accepts more variants. |
| Sample rate above 192,000 Hz | `LimitExceeded`, a configurable policy limit (`fmt_rate_over_limit`). | No such limit. |
| `data` size not a multiple of `block_align` | `InvalidFormat` (`data_not_block_aligned`). | Drops the partial frame. |
| Second `fmt ` | `InvalidWave` (`duplicate_fmt`). | Ignores it. |
| Inconsistent `byte_rate` | Accepted and ignored (`byte_rate_mismatch`). | Does not check it. |
| Sony Wave64 (`riff` GUID) | `UnsupportedFormat` (`w64`). | A separate demuxer (`w64.c`); `wavdec.c` rejects it. |
| Chunk-count limit | Every chunk header inside the extent counts, `fmt ` and `data` included. 4,096 is accepted (`chunks_at_limit`); the 4,097th header is `LimitExceeded` (`chunks_over_limit`). | No limit. |
| 1 MiB retained non-audio bytes | This parser keeps only the `fmt ` fields (at most 18 bytes), so no committed file can reach the limit. The synthesized `large_skip_2mib` vector shows that skipped bytes do not count. | No limit. |
| High sample rates in the writer | Plain tag 1 up to the 192 kHz limit (`stereo_96k_tag1`, `mono_192k_rate_limit`). Compare decoded samples and metadata with FFmpeg, not header bytes. | Writes WAVE_FORMAT_EXTENSIBLE above 48 kHz. |

## Error precedence

The parser reads sequentially, and the first violation in stream order wins.
Within one structure, checks run in this order:

1. **RIFF header** (12 bytes): the container tag (`RIFF`; `RIFX`, `RF64`,
   `BW64` and the W64 `riff` GUID are `UnsupportedFormat`; anything else is
   `InvalidRiff`), then `riff_size` (sentinels, then the minimum of 4), then the
   form type (`WAVE`, else `InvalidWave`). Input that ends before a check's
   bytes are complete is `Truncated`.
2. **Each chunk header** inside the extent:
   1. fewer than 8 bytes of extent left: `InvalidRiff`; input ends inside the
      header: `Truncated`;
   2. chunk count above 4,096: `LimitExceeded`;
   3. `fmt `: a second one is `InvalidWave`; a declared size below 16 is
      `InvalidFormat`. `data`: no `fmt ` yet or a second `data` is
      `InvalidWave`; size 0xFFFFFFFF is `UnsupportedStreamingSize`; a size that
      is not a multiple of `block_align` is `InvalidFormat`;
   4. the body ends beyond the extent: `InvalidRiff`;
   5. the body, and its pad byte when the pad lies inside the extent: input
      ends early: `Truncated`.
3. **`fmt ` fields**: format tag (not 1: `UnsupportedFormat`), bits per sample
   (not 16: `UnsupportedFormat`), channels (0: `InvalidFormat`; above 2:
   `UnsupportedFormat`), sample rate (0: `InvalidFormat`; above the limit:
   `LimitExceeded`), `block_align` (not `channels * 2`: `InvalidFormat`), then
   the chunk size (16, or 18 with `cbSize == 0`; anything else is
   `UnsupportedFormat`).
4. **End of the extent**: a missing `fmt ` or `data` is `InvalidWave`.

Fixtures that pin precedence: `rifx_truncated` (tag before truncation),
`fmt_unsupported_before_invalid` (tag before channels), `data_size_unknown`
(sentinel before extent), `chunks_over_limit` (count before any other check on
the 4,097th chunk) and `duplicate_data` (an error after audio).

## Hand check: `mono_8k`

The canonical mono file, 60 bytes, checked field by field:

```text
offset  bytes                                    field
0       52 49 46 46                              "RIFF"
4       34 00 00 00                              riff_size 52 = 60 - 8
8       57 41 56 45                              "WAVE"
12      66 6d 74 20                              "fmt "
16      10 00 00 00                              fmt size 16
20      01 00                                    format tag 1 (PCM)
22      01 00                                    channels 1
24      40 1f 00 00                              sample rate 8000
28      80 3e 00 00                              byte_rate 16000 = 8000 * 2
32      02 00                                    block_align 2
34      10 00                                    bits per sample 16
36      64 61 74 61                              "data"
40      10 00 00 00                              data size 16 = 8 samples * 2
44      00 00 01 00 ff ff ff 7f                  0, 1, -1, 32767
52      00 80 39 30 c7 cf 00 01                  -32768, 12345, -12345, 256
```

## Provenance

`generate.py` and `../fixtures.zig` are original project files
(`LGPL-2.1-or-later`). The fixture files and `manifest.zon` are data generated
by `generate.py`; their sample values were chosen by hand. No FFmpeg sample
files or code were used. FFmpeg's `wavdec.c` and `riffenc.c` were read only to
record the behavior differences above.

## Fixtures

<!-- BEGIN GENERATED FIXTURE TABLE: edit generate.py, then run it -->
| Fixture | Group | Bytes | Expected | Rule | SHA-256 |
| --- | --- | ---: | --- | --- | --- |
| `mono_8k` | accepted | 60 | accept: mono, 8000 Hz, 8 frames; writer output | Canonical mono: 16-byte `fmt `, tag 1, 8 kHz. | `c7f5296f101833dffb9e8cb2ddbd144071d532b4a37edebc1b5179f444e92be4` |
| `stereo_44k1` | accepted | 60 | accept: stereo, 44100 Hz, 4 frames; writer output | Canonical stereo at 44.1 kHz; samples interleave left/right. | `c6e43f79515989f847a0b0c71b0d43312c56944272da0acdf82c2992b412c531` |
| `stereo_96k_tag1` | accepted | 60 | accept: stereo, 96000 Hz, 4 frames; writer output | High-rate stereo with a plain tag-1 `fmt `. Intentional difference: FFmpeg's writer emits WAVE_FORMAT_EXTENSIBLE above 48 kHz; ours keeps tag 1. | `6a74d1d4934a89b8402a64b6f66a96d1b1a002ff29242c9922984158ddb99dd6` |
| `mono_192k_rate_limit` | accepted | 52 | accept: mono, 192000 Hz, 4 frames; writer output | Sample rate exactly at the 192,000 Hz limit. | `98fe629f578d2d3793fd0464fb7ba91d3bed349f97cce05f69695994a3d5df75` |
| `empty_data` | accepted | 44 | accept: mono, 8000 Hz, 0 frames; writer output | `data` size 0 is an empty stream, not read-to-EOF. | `4f8734c5e13ac599e168cf247a51c1dd0758537ce00bf16d7fed1a3d14d07041` |
| `fmt18_cbsize0` | accepted | 54 | accept: mono, 8000 Hz, 4 frames | 18-byte `fmt ` with `cbSize == 0`. | `ad6aec9f3e62070477f61fd767a73b3bd9b5d3c5192419a735e8ed82074a6e53` |
| `byte_rate_mismatch` | accepted | 52 | accept: mono, 8000 Hz, 4 frames | Inconsistent `byte_rate` is ignored. | `f0078566dc0aeaaa6df7a9050b562b870faeefb6b0bd07364409fd2269758106` |
| `unknown_chunks` | accepted | 90 | accept: mono, 8000 Hz, 4 frames | Unknown chunks before `fmt `, between `fmt ` and `data`, and after `data` (odd-sized, padded) are skipped. | `3a639faa3763a5428d9e8ab4d5bce77c92961d3d33e39905711c156081cca77d` |
| `odd_chunk_padded` | accepted | 64 | accept: mono, 8000 Hz, 4 frames | An odd-sized chunk before `data` is followed by its pad byte, which is skipped. | `acb12746075573f1b567643270f26b36ce615bb87fc5529473478ab8d11844b9` |
| `odd_final_chunk_pad_outside_extent` | accepted | 63 | accept: mono, 8000 Hz, 4 frames | The final odd-sized chunk ends at the RIFF extent and the file ends there: the pad byte would lie outside the extent, so it is not read. | `22d6e90392dd812ba3d70fa8adaa5616ad5bf64ff4118fd607d18cbb93d5f278` |
| `trailing_bytes_after_riff` | accepted | 60 | accept: mono, 8000 Hz, 4 frames | Bytes after the declared RIFF extent are ignored. | `4b15a44087486e2d17244e08036b35a69b5c8d47e167a58b9fbe2a7c6fdf2272` |
| `chunks_at_limit` | accepted | 32800 | accept: mono, 8000 Hz, 2 frames | Exactly 4096 chunks: `fmt `, 4094 empty `JUNK`, `data`. | `ce09b852cc70d64349dcaee84927ee08c29dca175ffca0b70e297e11a6414b19` |
| `empty_input` | riff header | 0 | reject: `Truncated` | No bytes at all. | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `truncated_riff_header` | riff header | 6 | reject: `Truncated` | Input ends inside the RIFF size field. | `b3c8c531fe520e8a27cc91b078c6dd6334e872e894ecc92700c87f6fc3ad7e62` |
| `not_riff` | riff header | 60 | reject: `InvalidRiff` | Unknown container tag `JUNK`. | `b3124366628d32f43bff7df698a2beadf8a14cbf26cf1255ea8338b48ee962f0` |
| `rifx_big_endian` | riff header | 60 | reject: `UnsupportedFormat` | Big-endian RIFX container. | `5ba707782a9dd8287a62fc2862d9a00c043d03bc80e615dc59c21c5845a91fb7` |
| `rifx_truncated` | riff header | 6 | reject: `UnsupportedFormat` | Precedence: the container tag is checked as soon as it is read, before the input runs out. | `747a7d80b921cad654cf7d736c5eaf96d8e51f4f4aaba69f29ebc7a3f4356e7e` |
| `rf64` | riff header | 88 | reject: `UnsupportedFormat` | RF64 container (64-bit sizes in `ds64`). | `c6c601df92748e7556325628f7434aa9c7b9e18784af693f82ba721d63c0b584` |
| `bw64` | riff header | 88 | reject: `UnsupportedFormat` | BW64 container (64-bit sizes in `ds64`). | `b7ffb31995ecc74af941a95e8333641d73b8d9d993c2e280b39559c0e767dbfa` |
| `w64` | riff header | 40 | reject: `UnsupportedFormat` | Sony Wave64 (starts with the lowercase `riff` GUID). | `c241923d87f74120fe400a96583693c9e1c64984f3dc3d57939b27e3533bdaf2` |
| `riff_size_unknown` | riff header | 52 | reject: `UnsupportedStreamingSize` | `riff_size` is the 0xFFFFFFFF unknown-size sentinel. | `6f4aee6c2e8c23872b15942f3873525270ed8be04fb64aa0907e7f13f86a528a` |
| `riff_size_zero` | riff header | 52 | reject: `UnsupportedStreamingSize` | `riff_size` is 0, the other unknown-size sentinel. | `2efc1f7b368fa82528aaf298aa8a1b0c69c0bae297d8b7c2fb5a0b35a5034c50` |
| `riff_size_too_small` | riff header | 52 | reject: `InvalidRiff` | `riff_size` 2 cannot hold the form type. | `00ef3e3b7d407394188f7d35cb008f353e8866c0f2d8ba1274742d37dc577700` |
| `not_wave_form` | riff header | 52 | reject: `InvalidWave` | RIFF form type `AVI ` instead of `WAVE`. | `c550e46e05c769704d13e5ab988b17cd505983f51cebc712f5f29fad437f2ff1` |
| `no_chunks` | riff header | 12 | reject: `InvalidWave` | A WAVE form with no chunks: `fmt ` and `data` are missing. | `1fe5a351bf0314c8a1840b023fd1e4cab3f0f123468940c241bd7bf20e989ab8` |
| `fmt_size_14` | fmt | 50 | reject: `InvalidFormat` | A complete `fmt ` chunk declaring only 14 bytes. | `a68b82d69f1db19666a330f62a3415a16845a4ae5db85ffb5bbdc7100762649b` |
| `fmt_truncated` | fmt | 30 | reject: `Truncated` | Input ends inside the `fmt ` body. | `e617018ac7052f420c9b95ae6562fbc0c7fab8e30f4ef0df1f0e2018c8dbca78` |
| `fmt20_cbsize2` | fmt | 56 | reject: `UnsupportedFormat` | 20-byte `fmt ` with `cbSize == 2` and two extension bytes. | `2b577347e4fcee5463047a1da4fd3e9e0a624ec2baeb69901dac34754c3c8dcf` |
| `fmt_extensible` | fmt | 76 | reject: `UnsupportedFormat` | WAVE_FORMAT_EXTENSIBLE (tag 0xFFFE, 40 bytes), even with a PCM subformat. | `2ab8c3455ef12b8fd8908ea15fa2ba2a6df86f96abcbe6eb271e788a97ba6668` |
| `fmt_float32` | fmt | 52 | reject: `UnsupportedFormat` | IEEE float (tag 3, 32-bit). | `04650c8621f4e7c37764fb2f3a5c7e1cda719f5d2c5fbe250799599a78b9cf49` |
| `fmt_bits24` | fmt | 50 | reject: `UnsupportedFormat` | Tag 1 with 24-bit samples. | `099d32416235d742870b590106e8b9ef404e1daf1a07d6e108b51a012a7daaac` |
| `fmt_channels3` | fmt | 56 | reject: `UnsupportedFormat` | Three channels. | `5c412517300b1a98125b0a72acdc0fd637003326ef0c2409d5db899855985dd6` |
| `fmt_channels0` | fmt | 44 | reject: `InvalidFormat` | Zero channels. | `4b5033687417507625294bed6a571d8fe3cbf288290b0d22967ee8277520be78` |
| `fmt_rate0` | fmt | 52 | reject: `InvalidFormat` | Zero sample rate. | `1d7080024c4773fdaf47ecc1ff6174a424a6c339f348d3f680fb865d33e0b96b` |
| `fmt_rate_over_limit` | fmt | 52 | reject: `LimitExceeded` | Sample rate 192,001 Hz, above the default limit. | `fb68abcc3c4d8912777b9d78d89cff6a0f7d645e9daca283fc0ecf42f93b780f` |
| `fmt_block_align_mismatch` | fmt | 60 | reject: `InvalidFormat` | Stereo with `block_align` 2 instead of 4. | `7487494878462bb126a2858c54b4164bca7dac59d53a82c0ba68f1aee072f2df` |
| `fmt_unsupported_before_invalid` | fmt | 44 | reject: `UnsupportedFormat` | Precedence: tag 3 with zero channels reports the unsupported tag first. | `d1728c9fe30ee697f985e3bee99a3a4a17a3bf5f2d9aaac673eed282047a9ae8` |
| `data_before_fmt` | order | 52 | reject: `InvalidWave` | `data` appears before any `fmt `. | `6dc6ff3326113206fd7c7766df7fd7bd8ee057a06dec6a6a9d042154c2c6462c` |
| `missing_data` | order | 36 | reject: `InvalidWave` | `fmt ` but no `data` within the RIFF extent. | `96b0b94deea11168966c72d7ec8d7fbff14d4dd6ad06dbbd5089b034e0b4bb70` |
| `duplicate_fmt` | order | 76 | reject: `InvalidWave` | Two `fmt ` chunks (FFmpeg ignores the second). | `c9d98fda8d44b0d655a71cd2858f5a6d905e647386e67bc01c800c703f837efc` |
| `duplicate_data` | order | 60 | reject: `InvalidWave` | A second `data` chunk after the first; reported after the first chunk's 2 frames. | `ee90f0ce3209f1028d1292c906d694927ebcecdef66382edc149dd3c0e8e3868` |
| `data_size_unknown` | data length | 48 | reject: `UnsupportedStreamingSize` | `data` size 0xFFFFFFFF; precedence: the sentinel is reported before the extent check. | `f86e50fa5b8f8a6f20bd2311eabc6f35f966149a900b324540819167e72d7ca4` |
| `data_not_block_aligned` | data length | 50 | reject: `InvalidFormat` | Stereo `data` of 6 bytes (1.5 frames). | `185fc947b7c8f7394eb72d7af262ba0a7a180b37104d8393c642c9d537835e36` |
| `data_exceeds_riff_extent` | bounds | 60 | reject: `InvalidRiff` | `data` declares 64 bytes but the RIFF extent ends after 16. | `6182a7c308a387407f09ad54ab255aadc71e0cd7f6d45aceb5eda0f7eb9fdd5a` |
| `chunk_exceeds_riff_extent` | bounds | 60 | reject: `InvalidRiff` | A chunk after `data` declares more bytes than the RIFF extent has left. | `f993ca1dae9966512e96d45047119325e21dd7051f8ef9d2dffe244ff6a4f7ce` |
| `partial_chunk_header_in_extent` | bounds | 51 | reject: `InvalidRiff` | The RIFF extent leaves 3 bytes after `data`, too few for a chunk header. | `a10405d3b09efd8067b9c6782960997acd2c31f93dfa3c3f818c65e26a4e9cfd` |
| `odd_final_chunk_pad_missing` | bounds | 63 | reject: `Truncated` | `riff_size` counts the final chunk's pad byte, but the input ends before it. | `1f182922bcebe651b9965e80cf479d809a8049027f44191c91463a9868f14486` |
| `riff_size_exceeds_input` | bounds | 52 | reject: `Truncated` | `riff_size` claims 16 more bytes than the input holds after complete chunks. | `42008a2676b5e4eb8ee9fb0774eed07d2ba907e389ee021f7979251a1a540377` |
| `truncated_data` | bounds | 54 | reject: `Truncated` | Input ends after 5 of the 8 declared samples. | `eb611ea86ef9d3c0048eb5228725e981af5c8559fef173d54a407070e78526dc` |
| `truncated_mid_sample` | bounds | 51 | reject: `Truncated` | Input ends inside a sample (7 data bytes). | `2024edadaf0f4134670555d5d44809975816b6f97a31fa4f1cc1c7a0afc879fc` |
| `truncated_chunk_header_after_data` | bounds | 51 | reject: `Truncated` | Input ends inside the chunk header that follows `data`. | `b549b974c2891d4cdc84fcc72c98ca8a19f71f4046c3b0780cc7d3d66038e508` |
| `chunks_over_limit` | limits | 32808 | reject: `LimitExceeded` | 4097 chunks: `fmt `, 4095 empty `JUNK`, `data`. | `8ae35f76b3d001f40386075519f017520958ce6631702f13f20953b16a8f9cb7` |
| `large_skip_2mib` (synthesized, not committed) | accepted | 2097212 | accept: mono, 8000 Hz, 4 frames | A 2 MiB `LIST` chunk before `data` is skipped; skipped bytes do not count toward the 1 MiB retained limit. Build it in the test: `fmt ` as in `mono_8k`, then `LIST` with 2,097,152 zero bytes, then `data` with the first 4 `mono_8k` samples. | `e3edce59e7710b921c2082f76f1b97a299b1a869a8ecf594dcf7099fb7e0414b` |
<!-- END GENERATED FIXTURE TABLE -->
