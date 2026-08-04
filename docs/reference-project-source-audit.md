# Open-Source Transcription Project Source Audit

Written: 2026-08-03
Baseline repository: Maccheroni `4d2e97f09521450912205adb7476d642a06d0324`

## Conclusion

Maccheroni's actual failure was not a mistake in a single MOSS constant. The
general chunk policy allowed up to 20 minutes, while the MOSS runner fixed its
output limit at 1,024 tokens. Product tests did not exercise those constraints
together. An input of 19 minutes 8.67 seconds was planned as one chunk, and
transcription failed when MOSS stopped at `maximumTokens`.

Across the audit paths of the 24 reviewed projects, none provided a complete
contract that joined input length, output limits, context, memory, time limits,
partial results, and retries. Useful mechanisms were scattered across projects.
TypeWhisper and Anarlog provide exact boundary tests, Anarlog uses staged
commit, local-whisper keeps append-only recovery records, and speech-swift
exposes explicit stop reasons and token metrics. Maccheroni should combine
those mechanisms. It should not adopt handling that promotes partial results
after a timeout as normal output, skips a failed intermediate chunk and reports
overall success, accepts a glossary that is not actually delivered, or
identifies a model through `resolve/main`.

The strategy of raising the MOSS limit to 16,384 tokens and processing all
19 minutes at once is rejected. A larger limit only delays failure and
increases the latency and memory cost of one long attempt. Maccheroni's initial
policy targets 4 minutes per actual MOSS call and never exceeds 5 minutes. It
uses nearby silence boundaries while preserving every original sample in the
concatenated result. When a call reaches `maximumTokens` or `contextLimit`,
only that range is divided at an interior silence point into two children of
about 2 minutes each. If a 30 to 38 second range still does not finish after
the maximum split depth, the complete run fails explicitly. If there is no
valid silence boundary, the exact sample midpoint guarantees that both children
shrink. Incomplete artifacts remain isolated. The design also includes runner
build fingerprints and exact boundary tests. These requirements are separated
into general rules in the
[Coupled Constraint Design and Verification Policy](engineering-constraint-policy.md).

## Scope and Evidence Grades

The audit covers the 24 projects identified by the underlying research notes,
which live outside this repository. Commercial applications that were mentioned
only by name, or for which no public repository URL was found, were excluded:
OpenMOSS, Spokenly, Superwhisper, MacWhisper, and Whisper Snapper. The scope was
not expanded arbitrarily to all of GitHub.

The audited checkouts are pinned by the commit hashes below and are not part of
this repository. They were obtained as blobless shallow clones; Git LFS objects
and submodules were not fetched. Behavioral claims in this document were
verified by reading source and tests at those commits. This was not a directly
executed comparative benchmark, so the document makes no claim that one project
has better quality or performance. In tables, `not verified` means no evidence
was found within the limited audit scope.

Evidence grades are used as follows.

- Direct: verified in pinned source, tests, a failed run, or a manifest.
- Calculated: derived from direct observations and a published formula; the
  sample scope is stated alongside it.
- Judgment: a design choice for Maccheroni.

## Checkout Inventory

License labels classify only the name of each top-level license file. Before
reusing code, check file-specific exceptions and dependency licenses separately.

| Project | Role | Pinned SHA | Top-level license |
|---|---|---|---|
| Beingpax/VoiceInk | macOS transcription application | `befcad66b183f778902c01c62b325c006087f0b3` | GPL-3.0 |
| Blaizzy/mlx-audio | MLX speech model runtime | `2c9461f5d8315fa8e7013ab2729495b2bb83d384` | MIT |
| FluidInference/FluidAudio | Core ML speech runtime | `5390df9752c8fc583596018360c5fd70d6fa6c75` | Apache-2.0 |
| Muesli-HQ/muesli | macOS meeting transcription application | `1b4baaceec7aede05080498b702248f7e2e074f9` | MIT |
| QwenLM/Qwen3-ASR | ASR model and runtime | `7c6daf77a2421100f5fb066495372c00129d39ff` | Apache-2.0 |
| TypeWhisper/typewhisper-mac | macOS transcription application | `975afe0428f6dc66a339d991c386f13ce4850a18` | GPL-3.0-or-later or commercial |
| Zackriya-Solutions/meetily | Meeting-recording application | `0281737d87d26352fb0adc78c8c0975f691b23d1` | MIT |
| argmaxinc/WhisperKit | Apple-platform Whisper runtime | `97d09fd9790393579d2834e2bc098deb3e26bc06` | MIT |
| chidiwilliams/buzz | Desktop transcription application | `3fa37a9d5238d29fa75a66cdb76555fd2820957e` | MIT |
| fastrepl/anarlog | Local meeting-recording application | `d4617ad76bf90106994f6bcaae7c46c5eb14e9b4` | MIT |
| gabrimatic/local-whisper | Local transcription application | `31b20f02cbcb5c805630e01b2f99937c20675a5f` | PolyForm Noncommercial 1.0.0 |
| homelab-00/TranscriptionSuite | Self-hosted transcription application | `3ac4e07c810ffb348cad2d96e479e9accc759f0a` | GPL-3.0 |
| kaixxx/noScribe | Interview transcription application | `dc4231e168fe5fd1586421924532b8ea8070d2cc` | GPL-3.0 |
| m-bain/whisperX | Alignment and diarization pipeline | `2cfd7b7c5c7bba144954364db747319b50e8232b` | BSD-2-Clause |
| microsoft/VibeVoice | Speech model and ASR examples | `94da20d98b2fa7688e9cbfaf7692ddb4954f7600` | MIT |
| moona3k/mlx-qwen3-asr | Qwen3-ASR MLX runtime | `d1a035514e1d6ac31da7658b273482656eacba61` | Apache-2.0 |
| murtaza-nasir/speakr | Self-hosted transcription application | `2f7d5871b40d0a3ee79bbe7388f2a44cbbee3803` | AGPL-3.0 |
| narcotic-sh/senko | Local transcription application | `ba0e12ed923ff49e8c2d9d9a3e42d7923cb95724` | MIT |
| Local task runner | Local task runner | `79479cdf09b74a5b1be54b636bb7510caa20bbfc` | Apache-2.0 |
| pyannote/pyannote-audio | Diarization runtime | `b749285c5cdd4636b2edc7f766f1352c8dde9369` | MIT |
| rishikanthc/Scriberr | Self-hosted transcription application | `bdb8838b8b9e4a58e74297f6ed2d0acb4c341c4f` | MIT |
| screenpipe/screenpipe | Local screen and audio recording application | `2c8dda1b2ae5e2170c214cdcb3167e7d2cfbff1c` | Screenpipe Commercial License |
| soniqo/speech-swift | Swift speech model runtime | `37c99dd856cfacfe952b2e48ecdb3c9dedc77625` | Apache-2.0 |
| thewh1teagle/vibe | Desktop transcription application | `1c5466b21b2228d708d9140d0f2ec71f69c0bb3e` | MIT |

## Reconstruction of the Real Failure

The evidence comes from a private real recording, validated through structural
metadata only; not part of this repository. Neither the audio nor
transcript content was opened.

| Item | Observed value | Evidence |
|---|---:|---|
| Input length | 1,148.6707 seconds | `coverage.input_duration_s` in `manifest.json` |
| Planned chunks | 1, from 0 seconds to 1,148.6707 seconds | `preprocess/chunks.json` |
| VAD speech | 751.488 seconds, 271 regions | `preprocess/vad.json` |
| Diarization | 373 regions, 5 speakers | structure of `diarization/timeline.json` |
| MOSS output limit | 1,024 tokens | `MaccheroniMossHarness/main.swift:181` |
| Result | `maximumTokens`, 0 completed chunks | `failure` and `coverage` in `manifest.json` |
| Preservation | 7 artifacts besides the manifest, 8 files total | `artifacts` in `manifest.json` and the run file list |
| Model | `aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8` | model ID, revision, and quantization are present in the manifest |

`ChunkPlanningConfiguration` permits a default target of 15 minutes, minimum
of 10 minutes, and maximum of 20 minutes. The planner splits only when the
remaining length exceeds 20 minutes. The product CLI calls this default planner
without regard to profile or backend. The MOSS runner makes one call and has no
path that divides a failed chunk into smaller pieces. The application's Try
Again action repeats the same input and profile, preserving the deterministic
failure condition.

Changing the runner source alone does not guarantee a changed deployment path.
The Python adapter only checks whether the cached executable exists and is
executable. The application build script neither builds the MOSS harness nor
compares it against source, lockfile, and toolchain fingerprints.

## MOSS Token-Budget Calculation

The pinned speech-swift runtime sets the default MLX output limit to 5,120
tokens. Its dense long-file example uses 16,384 tokens. Total context is
131,072 tokens, and audio consumes 12.5 context tokens per second. The runtime
returns `promptTokens`, `generatedTokens`, and `stopReason`; when it does not
reach EOS, it explicitly returns `maximumTokens` or `contextLimit`.

The 10 preserved successful MOSS results range from 28.89 to 99.44 seconds.
Every result ended at EOS. The maximum generation density in this sample was:

```text
225 generated tokens / 28.8898125 audio seconds
= 7.7882 generated tokens / audio second
```

Applying that density with 20% headroom produces the calculated audio lengths
below for each limit. These are observations from a small sample used to create
a conservative planning coefficient, not a support guarantee.

| Output limit | 80% used for planning | Calculated audio length |
|---:|---:|---:|
| 1,024 | 819 | 105.2 seconds |
| 5,120 | 4,096 | 525.9 seconds |
| 16,384 | 13,107 | 1,683.0 seconds |

Applying the same density to 751.488 seconds of VAD speech in the failed file
produces about 5,853 tokens. Even the 5,120 default is insufficient to process
the entire file once. An input containing 20 minutes of continuous speech is
estimated at about 9,346 tokens. In this small sample, 16,384 covers the current
20-minute policy, but it does not guarantee coverage for an input with higher
output density. It also does not justify one long attempt. Planning must create
shorter subchunks with enough headroom under 5,120, with separate recovery from
runtime stop reasons.

The pinned runtime formula for an FP16 KV cache is 114,688 bytes per token.
After adding the observed maximum prompt overhead of 205 tokens, 20 minutes of
audio and the expected 9,346 output tokens require about 2.62 GiB. If 20 minutes
of audio uses the entire 16,384-token output limit, the estimate is about
3.37 GiB. These figures count only the KV cache. Model weights, audio
embeddings, temporary tensors, and allocator overhead require additional
memory.

The following table compares candidate lengths at the same maximum observed
density. Call counts are the ceiling of the failed input's 1,148.67 seconds
divided by each candidate length; actual silence boundaries will change them.

| Candidate | Audio context | Expected output | Share of 5,120 | Calls for 19 minutes | Judgment |
|---:|---:|---:|---:|---:|---|
| 30 seconds | 375 tokens | 234 tokens | 4.6% | 39 | There is no basis for independent MOSS calls, and this creates too many boundaries. |
| 2 minutes | 1,500 tokens | 935 tokens | 18.3% | 10 | Safe recovery unit, but too many boundaries for initial planning. |
| 4 minutes | 3,000 tokens | 1,869 tokens | 36.5% | 5 | [Judgment] Initial candidate based on the calculation. |
| 5 minutes | 3,750 tokens | 2,336 tokens | 45.6% | 4 | Calculated as feasible, but density variation and the failure range increase. |

30 seconds is the internal window used by speech-swift's MOSS audio
encoder. The pinned implementation combines all window embeddings into one
prompt and decodes once. This does not support using 30 seconds as an
independent transcription chunk. 4 minutes is likewise not an upstream
default. It is an initial product choice based on the pinned MOSS constraints,
Maccheroni's successful sample, and call counts together. Validate the 4-minute
choice by running 2-, 4-, and 5-minute public and synthetic samples under the
same conditions.

In two preserved E2E MOSS runs, the differences between runner wall
time and the model's `total_s` were about 1.38 seconds and 1.13 seconds. Each
difference combines process startup, model preparation, and file I/O, so it
does not isolate model load time. The additional cost of five independent calls
must be validated, but it does not justify retaining one 19-minute call.

## Patterns Verified in Application Implementations

### Evidence to Adopt

| Project | Directly verified mechanism | Maccheroni judgment |
|---|---|---|
| TypeWhisper | Exact boundary and `+1` tests for the local API's 256 MiB limit | Test below, at, and above every hard limit. |
| Anarlog | 25-second split boundary and `+1` test; promotion of staged words after completion | Isolate chunk-attempt artifacts and promote them to canonical output only after the full contract passes. |
| local-whisper | Append-only JSONL records for long sessions and restart recovery | Preserve each chunk attempt as create-only data and record resumable lineage. |
| mlx-qwen3-asr | Recursive split at 30-second low-energy points, length-based token budget, and per-chunk finish reason and truncation | Plan length and output budget together and preserve each subchunk's termination reason. |
| Speakr | Typed specification of connector duration and byte limits, recommended length, and internal splitting behavior | Make backend capability an input to the planner and use the smaller of the user and backend limits. |
| speech-swift | Output and context stop reasons; prompt and generated-token metrics | Record typed limit failures and actual-versus-planned usage in the manifest. |
| Muesli | Separate raw and final output; resume test after interruption | Separate raw evidence from derived results. Verify resume behavior with a fixture. |

### Patterns to Reject or Correct

| Project | Directly verified risk | Reason for rejection |
|---|---|---|
| TranscriptionSuite | `max_new_tokens=8192` for 60-second CUDA chunks; can retain only a warning after a 180-second timeout and continue with partial output | Timed-out and truncated results are not successful results. |
| local-whisper | Skips a failed intermediate chunk and returns overall success if at least one chunk succeeds | Missing ranges are hidden without a typed partial state. |
| TypeWhisper | Changes context to an empty string in the Qwen loop fallback | The fallback loses glossary semantics. |
| TranscriptionSuite | Some backends explicitly discard the received `initial_prompt` | The glossary accepted in the UI diverges from evidence of backend application. |
| Muesli | Uses the personal dictionary for Jaro-Winkler post-processing replacement, not an ASR prompt | Does not satisfy Maccheroni P2's decoding-time injection requirement. |
| VoiceInk | Downloads models from `resolve/main` and reports display-name-oriented results | Execution results do not prove the exact revision. |

### Detailed Observations from Six Applications

#### Muesli

- The personal dictionary is not passed to ASR. `TranscriptionRuntime.swift`
  calls `CustomWordMatcher` after transcription, and the matcher replaces words
  by Jaro-Winkler similarity.
- The Qwen path wraps the entire result in one segment at `[0, 0]`. It provides
  no real timing evidence for chunk merging.
- Raw and final output are separate, and resume tests exist. No path that
  records the exact model revision in the result was found within the audit
  scope.

#### TranscriptionSuite

- The MLX VibeVoice function receives `initial_prompt` but does not pass it to
  the actual `transcribe` call. Some diarized and CUDA paths explicitly delete
  that argument.
- The CUDA path separately fixes 60-second chunks and an 8,192 output limit. It
  can treat a 180-second timeout as only a warning and continue writing a
  partial payload.
- Broken-JSON salvage and the failure to reconcile per-chunk speaker labels
  globally do not satisfy Maccheroni's prohibition on silent data loss or its
  global-speaker contract.

#### TypeWhisper

- The default Qwen chunk is 30 seconds with 2,048 tokens. Loop-detection
  fallback reduces these to 15 seconds and 1,536 tokens, but changes context to
  an empty string.
- Direct plugin calls can receive context. The plugin capability declares
  dictionary-term support as `unsupported`, and the host service does not
  return terms through the normal UI path.
- The Hugging Face store resolves `refs/main` to a 40-character commit. No path
  that preserves that revision in the transcript record was found.

#### Anarlog

- The local batch request is rejected above 100 MiB. It divides 16 kHz audio
  into non-overlapping chunks of at most 25 seconds and tests exactly 25 seconds
  and 1 sample above it.
- The UI sends at most 50 keywords, but the local model configuration consumes
  only the language. There is no evidence that a static glossary reaches the
  decoder.
- Chunk results accumulate as staged words and are promoted at once after
  success. Incomplete recordings are preserved regardless of the retention
  setting.

#### local-whisper

- Parakeet uses 120-second chunks with 15 seconds of overlap. Qwen context is
  limited to 4,096 characters. The Qwen long-file setting uses 1,200 seconds
  and an automatic output-token limit.
- Sessions of at least 300 seconds append each chunk to JSONL. A crash can lose
  at most the final chunk.
- An intermediate chunk failure is logged and skipped. If any chunk succeeds,
  the whole run returns success, so a missing range may not appear in the final
  state.
- `snapshot_download` does not pin a revision, and results do not preserve an
  exact revision.

#### VoiceInk

- The file queue checks only the extension, not size or duration limits.
- The prompt is passed only to the Whisper path. Fluid and native paths receive
  nil.
- The original audio is preserved, but raw ASR and post-processed output are
  not maintained as separate canonical forms. Some cancellation services do
  not perform actual cancellation.
- Models are fetched from `resolve/main` without verifying hash, size, or
  revision.

#### mlx-qwen3-asr

- Inputs longer than 30 seconds are recursively divided at the lowest-RMS point
  in the middle 60% region. A degenerate split point is replaced with the
  midpoint so progress is guaranteed.
- The default output budget is `ceil(audio_seconds × 12) + 32`, bounded from
  128 to 512. Tests cover 5-, 30-, and 120-second boundaries.
- Each chunk records `finish_reason`, `truncated`, `generated_tokens`, and
  `max_new_tokens`. The overall result's truncation is true if any child ends
  for length.
- Large MLX tensors are deleted and the cache is cleared after every chunk. A
  source comment records that memory grew to about 90 GiB on long input before
  this handling was added.

Length-based token budgets and typed truncation should be adopted. The
30-second constant is a Qwen-model choice and should not be copied to MOSS.

#### Speakr

- The connector specification expresses maximum duration, maximum bytes,
  recommended chunk length, and backend-internal splitting separately.
- It uses 85% when a hard duration has no recommendation and 80% for hard
  bytes. If the user supplies a smaller limit, it selects the smaller value.
- The default overlap is 3 seconds. Overlapping transcripts are deduplicated by
  finding a common sentence. This approach is sensitive to punctuation and ASR
  wording and should not be copied directly.

The capability structure and conservative headroom should be adopted
separately. If overlap is needed, Maccheroni should detect duplicates through
the original timeline and segment ownership.

#### screenpipe

- The Parakeet path processes hard 30-second chunks without overlap. A backend
  benchmark documented in source compares a 33.9% no-overlap WER with a 34.5%
  WER using 1-second overlap and LCS; it explains that deduplication deleted
  correct words.
- MLX Parakeet clears the cache before and after every 30-second chunk and pads
  the last chunk to the same shape. Even if one chunk fails, it returns partial
  text as a normal result when another chunk succeeds.
- Backend-specific limits, global speaker-ID reconciliation, and
  original-audio-first reprocessing are worth studying. The rule that returns
  partial success as complete is rejected.

30 seconds and no overlap are measured Parakeet choices and should not be
copied to MOSS. Maccheroni likewise should not assume overlap as the default
solution; it should validate non-overlapping splits at silence boundaries
first.

#### Meetily, Buzz, noScribe, Scriberr, Vibe

- Meetily's parallel Whisper path creates default 30-second hard cuts and a
  global start offset. The function provides no basis for overlap, context
  carry, or adaptive splitting.
- Buzz's hosted transcription API path divides files over 25 MiB into equal
  time ranges based on byte ratio, then adds each chunk offset to segment
  timestamps. It does not find speech boundaries.
- noScribe passes the full file path to faster-whisper and leaves VAD and
  hotwords to the backend. This architecture does not establish a long-file
  budget.
- Scriberr's Parakeet helper creates contiguous 300-second chunks and rebases
  word and segment timestamps to the original timeline. The 300-second value is
  specific to that Parakeet helper.
- Vibe downloads to `.part`, renames it, moves an existing file to a backup,
  and restores the prior file if publishing fails. Batch transcription may
  skip work based only on output existence, which is insufficient for
  provenance validation.

The shared lessons from this group are model-specific chunks and rebasing to
original timestamps. Fixed duration values and existence-only resume behavior
should not be adopted.

### Engines and Diarization Runtimes

#### FluidAudio

- Parakeet uses windows of about 14.96 seconds with 2 seconds of overlap. The
  final window is filled from the end of actual audio instead of zero-padded.
  Seams move toward silence, and timestamps are clamped after merging so they do
  not decrease.
- The decoder has a default limit of 150 tokens per chunk. It stops the loop on
  reaching the limit but does not expose a typed cap-hit in the result.
- The downloader supports Range and If-Range resume, size validation, and
  bounded retries. The default model URL uses `resolve/main`, and results do
  not include an exact revision.

Seam movement, unit constants, and download integrity should be adopted. Silent
token truncation and moving revisions should be rejected.

#### WhisperKit

- The input window is 30 seconds. The incremental loader defaults to
  120-second staging and two buffered output chunks. It truncates the prompt and
  prefix to a shared 224-token budget.
- If one parallel VAD chunk fails, only a debug log is left and successful
  results are returned. The decoder also omits the reason it stopped at a
  sample or context limit.
- Cache metadata includes commit, ETag, and hash verification, but transcript
  results do not include model provenance.

Bounded loading and prompt budgets should be adopted. Failed-chunk omission and
untyped limit stops should be rejected.

#### pyannote-audio

- It distinguishes whole and sliding modes and validates duration, step, and
  warm-up in seconds. Only the final incomplete window is zero-padded. The
  result is cropped to actual duration after Hamming overlap-add and exclusion
  of warm-up edges.
- Diarization can return both a regular timeline and an exclusive timeline. It
  validates exact, minimum, and maximum speaker counts and produces a typed
  empty result when there is no speech.
- Telemetry is enabled by default in the audited source snapshot. The
  preparation cache is reused when a file exists and is nonempty, without a
  source or schema fingerprint.

The seconds-based window contract and exclusive timeline are useful references.
Maccheroni's default local path should not include telemetry or use a cache
validated only by existence.

#### speech-swift MOSS

- `docs/inference/moss-transcribe-diarize.md:5-22,110-129` explains that
  30-second encoder windows are concatenated in order into one prompt. The
  default MLX output limit is 5,120; 16,384 is a dense long-file example.
- `Sources/MossTranscribe/MossTypes.swift:62-80,143-181` defines decoding
  defaults and typed `endOfSequence`, `maximumTokens`, and `contextLimit`
  values.
- `Sources/MossTranscribe/MossMLXRuntime.swift:573-636` uses the smaller of the
  output limit and remaining context, then returns raw output, parsed segments,
  prompt and generated-token counts, and stop reason together.
- `Sources/AsrBenchmark/EngineMoss.swift:52-112` prepares the model once in one
  process and reuses it for multiple transcriptions. Maccheroni should first
  measure independent-process isolation and call costs, then consider worker
  reuse only if cold-start cost outweighs the quality and recovery benefits.

#### Qwen3-ASR and WhisperX

- Qwen3-ASR's `qwen_asr/inference/utils.py:246-332` finds low-energy points
  near length boundaries and preserves exact offsets. The 20-minute and
  3-minute limits at `:34-35` of the same file are applied according to
  timestamp selection in `qwen_asr/inference/qwen3_asr.py:366-377`. These
  numbers should not be copied to MOSS.
- WhisperX's `whisperx/vads/vad.py:20-53` splits at the preceding speech
  boundary when adding the next speech region would exceed the limit.
  `whisperx/diarize.py:185-263` assigns segment and word speakers by summing
  overlap durations between the transcript and the full-file speaker timeline.
- Neither project guarantees speaker IDs across independent MOSS calls. There
  is also no evidence that passing generated text from the previous chunk into
  the next prompt is beneficial.

#### senko

- `senko/diarizer.py:296-365` produces full-file VAD, overlapping speaker
  subsegments, embeddings, clustering, centroids, and merged ranges as one
  result.
- `:482-542,764-853` of the same file converts sample-based VAD times to
  seconds, uses overlapping speaker windows of about 1.5 seconds, and normalizes
  speaker IDs after global clustering.

Labels such as `S01` from short MOSS leaves may restart on each call. They
must not be treated as global speakers. Maccheroni should keep the full-file
diarization timeline as canonical and reassign speakers to MOSS segments after
rebasing them to original time.

#### VibeVoice and mlx-audio

- VibeVoice's 60-second internal split in
  `vllm_plugin/model.py:254-260,318-435` is one language-model request that
  carries acoustic and semantic caches forward. It does not support independent
  leaf transcription.
- `vllm_plugin/scripts/gradio_asr_demo_api_video.py:850-916,923-1097` preserves
  streamed raw text, stopped state, parse warnings, and recovered partial
  segments. A structure recovered with `_truncated` should be preserved only
  as diagnostic evidence and not promoted to canonical Maccheroni output.
- mlx-audio's
  `mlx_audio/stt/models/moss_transcribe_diarize/moss_transcribe_diarize.py`
  likewise divides only features internally, concatenates them, and generates
  once. The evidence is at `:117-153,385-426,584-611,652-729`. Its default
  generation limit is 2,048, and its stop-reason contract and tests are weaker
  than speech-swift's.

#### Task Ledger

- `state/memory_migrations/0001_memories.sql:17-35` stores task state, owner
  token, lease, retry budget, errors, and input watermark together.
- `state/src/runtime/memories.rs:642-829` atomically validates an active lease
  and restores an exhausted retry budget only when input changes. Only the
  current owner can record success at `:832-970` or failure at `:994-1037`.

Maccheroni v1 should not add a complete database lease system. It should use
only a small ledger that stores attempt ID, parent ID, input range, failure
reason, and changed condition in create-only files. Because processing is
sequential within one process, stale-owner handling should be revisited when
resume support is added.

#### Strong Foundations Already in Maccheroni

- The failed run recorded the original hash, pinned model ID, revision and
  quantization, split plan, completed range, typed failure, and preserved
  artifacts.
- The MOSS harness did not promote a non-EOS result to a normal transcript.
- Full-file diarization finishes before ASR, so the same global speaker timeline
  can be applied after further splitting.

What is missing is a capability contract that feeds this evidence back into
pre-execution planning and a recovery path that safely splits smaller after a
failure. The Python runner currently does not pass the profile's language pin
to MOSS, and the Swift adapter only populates each result segment's language
label. That is not evidence of actual prompt transport. The glossary and
language pin must be delivered through the same instruction contract and
hashed. Long-file cancellation should also verify that no Python or MOSS child
process remains after the application terminates only the CLI.

## Adoption Decisions

| Decision | Basis | Application |
|---|---|---|
| Represent backend capability as data | The common 20-minute policy and MOSS 1,024-token limit were separate | Put wall duration, speech duration, context rate, output density, output cap, memory mode, and timeout in one structure. |
| Retire one 19-minute MOSS call | The full-file estimate of 5,853 tokens exceeds the upstream 5,120 default | Create backend-specific subchunks inside the 10 to 20-minute parent work range. |
| Plan conservatively within the 5,120 limit | Upstream default and calculations from the current successful sample | Use only part of the output budget for planning and leave the rest for input variation and termination-token headroom. Do not use 16,384 as the default strategy. |
| Split against two budgets before execution | Audio length drives the prompt; speech amount and density drive output | Start MOSS with a 4-minute target and 5-minute maximum. Choose the stricter boundary from the wall-time/context budget and VAD speech/output budget. |
| Treat `maximumTokens` as a recoverable typed failure | The runtime distinguishes partial text from the stop reason | Isolate the partial attempt and split the original chunk in two at a silence boundary. Guarantee termination with a minimum length and maximum depth. |
| Prohibit Try Again under identical conditions | The current retry repeats the same deterministic failure | First show what changed: cap, smaller chunk, or a semantically equivalent backend. |
| Verify fallback semantics | TypeWhisper fallback loses context | Do not fall back automatically unless glossary, language pin, privacy, and provenance are equivalent. |
| Record the runner fingerprint in the manifest | An existence check cannot distinguish a stale cached runner | Determine rebuild need from a digest of the source tree, Package.resolved, Swift toolchain, and build flags. |
| Add combined boundary tests | Short-MOSS and long-file tests for another backend each passed separately | Verify `MOSS × long chunk × glossary × diarization × cache` with a shrinkable fixture. |

Initial implementation values are:

- MOSS preferred leaf: 240 seconds
- MOSS initial maximum: 300 seconds
- limit recovery: bisect the failed range at an interior silence point. The
  first children of a typical 240-second leaf are about 120 seconds each; those
  of a 300-second leaf are about 150 seconds each.
- recovery minimum: 30 seconds
- maximum recovery depth: 3
- generation cap: 5,120 tokens
- promotion: success only when every final leaf returns `endOfSequence`
- overlap and previous-chunk text carry: off by default

A 5-minute chunk is a maximum, not the preferred value. The preferred value may
move to 5 minutes after comparing output density, boundary omissions,
processing time, and peak memory in 4- and 5-minute samples. When no valid
silence point exists, use the exact sample midpoint, and require both children
to be strictly smaller than the parent. The final leaves at depth 3 are about
30 seconds for a 240-second parent and about 37.5 seconds for a 300-second
parent. If one of those leaves reaches the same typed limit, fail the entire
run rather than automatically increasing the cap.

## Remaining Limitations

- The 24 projects are pinned source snapshots from 2026-08-03. Later changes
  are not represented.
- The audit examined code paths and tests, but did not install all 24 projects
  and run them on the same audio. Quality and speed comparisons are outside the
  scope of this document.
- The generation-density calculation uses only 10 successful MOSS results. It
  may increase with language, speaker count, speaking speed, timestamps, and
  speaker-token format.
- A negative finding means the evidence was not found in the stated paths and
  search scope. It is not proof of absence across an entire repository.
