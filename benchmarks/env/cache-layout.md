# Benchmark cache layout

The repository stores only configuration, wrappers, and lock files. Models,
virtual environments, generated smoke audio, FluidAudio source, and smoke
outputs are untracked local state.

Set `MACCHERONI_BENCHMARK_CACHE` to relocate the primary cache. The configured
default is:

```text
~/Library/Caches/Maccheroni/benchmarks/
  venvs/mlx-audio/          uv environment (Python 3.12)
  models/huggingface/       HF_HOME for speech-swift and mlx-audio
  smoke/                    generated synthetic 10-second WAV and outputs
  fluid-audio-source/       pinned FluidAudio source and SwiftPM build product
  models/fluid-audio/       exact HF snapshots used by FluidAudio runners
  sources/speech-swift/     speech-swift source at the MOSS harness revision
  swift-scratch/moss-harness/ SwiftPM checkout and build product for MOSS
  swift-scratch/fluid-diarization-harness/ SwiftPM checkout and build product
  swift-scratch/parakeet-benchmark-harness/ exact TDT + CTC benchmark product
```

The FluidAudio wrappers keep each exact revision in its own parent directory,
with the canonical leaf name FluidAudio expects:

```text
models/fluid-audio/
  parakeet-<revision>/parakeet-tdt-0.6b-v3/
  parakeet-benchmark-<revision>/parakeet-tdt-0.6b-v3-coreml/
  ctc-<revision>/parakeet-ctc-110m-coreml/
  diarization-<revision>/speaker-diarization/
```

The smoke ASR wrapper passes the first leaf with `--model-dir`. FluidAudio's
CLI can still purge and resolve from `main` after a non-transient model load
failure, so smoke acceptance compares the exact-download tree before and after.
The Stage 2 Parakeet harness instead sets `ModelHub.offlineMode = true` and
loads both TDT and optional CTC leaves directly. The diarization harness also
sets offline mode and passes the revision-specific parent to
`OfflineDiarizerModels.load(from:)`. Neither exact harness uses FluidAudio's
Application Support cache.

The source fixture is local macOS `say` output, then converted to exactly
16 kHz mono PCM WAV and padded or trimmed to 160,000 frames. It is generated
on demand and is not an original recording.

The MOSS harness copies `mlx.metallib` from the installed `speech` formula
beside its external SwiftPM executable because the pinned source build does
not package that MLX resource. The copy remains external build state.
