# Run Artifact Contract

This document defines the v1 contract for Maccheroni run directories. Every
path is relative to the run root. The original audio is neither moved into nor
overwritten by the run directory. The input SHA-256 in `manifest.json` confirms
that the source file remains the same.

## Directory Structure

```text
<run-id>/
├── manifest.json
├── primary/
│   ├── raw.txt
│   └── segments.json
├── diarization/
│   └── timeline.json
├── merged/
│   ├── segments.json
│   └── conflicts.json
└── postprocess/
    ├── segments.json
    ├── conflicts.json
    └── translation.json
```

Create `postprocess/` only when post-processing runs. A correction run creates
`segments.json` and `conflicts.json`; a translation run creates only
`translation.json`. Do not mix the two forms in one run. All other paths are
required for a successful complete run. An intermediate failure still leaves
`manifest.json`. Do not include artifacts that could not be created in the
manifest's `artifacts` field.

## Meaning of Each File

- `manifest.json`: the run record that conforms to `manifest.schema.json`.
  Atomically replace its temporary file when the run ends. It must record input
  duration, processed duration, truncation status, chunk results, the model's
  HF ID and pinned revision, and quantization. When post-processing runs, the
  optional `postprocess` field records the mode, backend, model ID, published
  revision and quantization, glossary hash, `text-only` input mode, and bounded
  batch ledger. The meaning of `model_id` differs by lane. The local lane pins
  execution to a revision, so the value identifies the model that actually ran.
  In the hosted-service lane, it is the requested model string passed with
  `--model`. Because the CLI does not expose the service's actual serving model,
  this value is unverified. Translation also records the target language and
  the SHA-256 of the canonical merged segment artifact. Leave the revision,
  quantization, and hard output-token limit as `null` when the hosted backend
  does not publish them, and record their status as
  `service-managed-unavailable`.
- `primary/raw.txt`: the backend's unmodified source output. This file is for
  human inspection and is never overwritten by post-processing.
- `primary/segments.json`: the backend output normalized into the common
  segment structure. If no speaker has been assigned yet, `speaker` is
  `UNASSIGNED`.
- `diarization/timeline.json`: the speaker timeline derived from the complete
  original audio. Each entry has `speaker`, `start_s`, `end_s`, and optional
  `confidence`.
- `merged/segments.json`: the canonical result of merging the global timeline
  with chunked ASR. It must pass `segments.schema.json`.
- `merged/conflicts.json`: preserves ambiguous speaker assignments and ASR
  discrepancies. Each conflict contains the target segment's array index,
  `kind`, `candidates`, and `reason`. It never substitutes a correction into the
  source text.
- `postprocess/segments.json`: a separate corrected version proposed by the
  selected post-processing backend. Its speakers and time ranges must match
  `merged/segments.json`.
- `postprocess/conflicts.json`: correction proposals with insufficient
  confidence. It contains both the unchanged source text and the candidates.
- `postprocess/translation.json`: a translation-only artifact conforming to
  `translation.schema.json`. It contains only the canonical segment indexes and
  translations, plus the per-batch prompt, source text, decoded text, and raw
  schema-response byte-budget evidence for batches divided at complete segment
  boundaries. It cannot represent speaker and timestamp fields, so model output
  cannot change the acoustic structure.

## Writing and Invariants

1. Read the input file's SHA-256 and byte count before starting the run.
2. Write every generated file to a temporary file in the same directory, then
   rename it atomically.
3. Do not modify `primary/raw.txt` or `primary/segments.json` after creating
   them. A retry uses a new `run-id`.
4. Write merge and post-processing output only to new subdirectories. No stage
   opens the original audio path or raw result in write mode.
5. Recalculate the input SHA-256 after the run ends. If it differs from the
   initial value, mark the run failed and preserve the artifacts.
6. If a backend limit prevents processing the entire input, record `status` as
   `partial` or `failed`. Do not hide `coverage.truncated`,
   `processed_duration_s`, or the error message. The application's normal path
   must process chunks before reaching the limit or explicitly reject the
   input.
7. Post-processing forms contiguous batches at complete segment boundaries and
   includes each canonical index exactly once. If one segment exceeds the
   prompt or output planning budget, terminate with a typed failure before
   calling the backend.
8. Exclusively create the translation artifact as a separate file. Before and
   after translation, `primary/raw.txt`, `primary/segments.json`,
   `merged/segments.json`, and the original input SHA-256 must remain unchanged.

## Identifiers and Time

- Recommended `run-id`: UTC time plus a random suffix in the format
  `20260803T041530Z-7f3a9c`.
- Time ranges are floating-point seconds from 0 at the start of the original
  file and are interpreted as half-open intervals `[start_s, end_s)`.
- Sort segments and chunks by `start_s`, then `end_s`. When start points are
  equal, place the item with the earlier end point first.
- Paths must not contain absolute paths or `..`. The manifest preserves only
  filenames and relative artifact paths, never personal paths.

## Semantic Validation

The following conditions, which JSON Schema cannot express, must also be
checked.

- Every range satisfies `end_s > start_s` and does not exceed the original
  duration. The floating-point tolerance is 10ms.
- For a successful run, `processed_duration_s` equals `input_duration_s` within
  10ms and `truncated` is false.
- `chunks_completed <= chunks_planned`, and chunk indexes increase from 0
  without duplicates.
- `num_speakers` equals the number of unique speakers excluding `UNASSIGNED`
  and `UNKNOWN`.
- The speakers and times in post-processing segments exactly match those in the
  merged version.
- Translation `source_segments_sha256` must equal the
  `merged/segments.json` artifact hash. Translation indexes and batch coverage
  must extend from 0 through one less than the canonical segment count without
  duplication or omission.
- The manifest's batch policy, observed maxima, and the translation's per-batch
  byte/token ledger must be reproducible from the same calculation and the
  actual artifact values. Calculate the accepted output bound from the raw
  schema-response bytes, including the JSON envelope and escaping, rather than
  counting only the decoded translations.

`benchmarks/scripts/scoring/check_contracts.py` validates schema examples and
the applicable conditions above against run manifests.
