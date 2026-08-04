#!/usr/bin/env python3
"""Run one immutable, exact-revision VibeVoice benchmark transcription.

This bridge deliberately keeps all model imports inside ``run_benchmark`` so
``--help`` remains usable outside the mlx-audio virtual environment.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import stat
import sys
import time
import unicodedata
import wave
from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any, Mapping, Sequence


CONTEXT_HEADER = "Preserve these spellings only when supported by the audio. Candidate glossary terms:\n"
EXPECTED_MLX_AUDIO_VERSION = "0.4.6"
# mlx-audio's VibeVoice path has a 59-minute ceiling.  Refuse a longer file
# before loading the model so the backend cannot silently truncate it.
MAX_VIBEVOICE_DURATION_SECONDS = 59 * 60


@dataclass(frozen=True)
class ModelSpec:
    """The only model variants this bridge is permitted to execute."""

    model_id: str
    revision: str
    quantization: str


MODEL_SPECS: dict[str, ModelSpec] = {
    "8bit": ModelSpec(
        model_id="mlx-community/VibeVoice-ASR-8bit",
        revision="725c72e54d6ef875472c27fbc50fab470a960940",
        quantization="int8",
    ),
    "bf16": ModelSpec(
        model_id="mlx-community/VibeVoice-ASR-bf16",
        revision="12076ff8cb141fcb672abc9f8957b08aab5ecf94",
        quantization="bf16",
    ),
}


class BridgeError(RuntimeError):
    """An input or generated artifact violated the benchmark contract."""


@dataclass(frozen=True)
class AudioInfo:
    path: Path
    sha256: str
    size_bytes: int
    duration_seconds: float


@dataclass(frozen=True)
class GlossaryInfo:
    raw_sha256: str
    terms: tuple[str, ...]


def sha256_file(path: Path) -> str:
    """Return a file's SHA-256 without retaining its contents in memory."""

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve_model(model_variant: str) -> ModelSpec:
    """Resolve a command-line variant to its fixed HF identity."""

    try:
        return MODEL_SPECS[model_variant]
    except KeyError as error:
        raise BridgeError(f"unsupported model variant: {model_variant}") from error


def inspect_wav(path: Path) -> AudioInfo:
    """Reject missing, empty, and invalid WAV inputs before model loading."""

    try:
        file_status = path.stat()
    except OSError as error:
        raise BridgeError(f"audio input is missing or unreadable: {path}") from error
    if not stat.S_ISREG(file_status.st_mode) or file_status.st_size == 0:
        raise BridgeError(f"audio input must be a nonempty regular WAV file: {path}")

    try:
        with wave.open(str(path), "rb") as audio:
            frames = audio.getnframes()
            sample_rate = audio.getframerate()
            if frames <= 0 or sample_rate <= 0 or audio.getnchannels() <= 0 or audio.getsampwidth() <= 0:
                raise BridgeError(f"audio input has no playable WAV frames: {path}")
            duration = frames / sample_rate
    except BridgeError:
        raise
    except (OSError, EOFError, wave.Error) as error:
        raise BridgeError(f"audio input is not a valid WAV file: {path}") from error
    if duration > MAX_VIBEVOICE_DURATION_SECONDS:
        raise BridgeError(
            "audio input exceeds VibeVoice's 59-minute limit; split it before benchmarking"
        )

    return AudioInfo(
        path=path,
        sha256=sha256_file(path),
        size_bytes=file_status.st_size,
        duration_seconds=duration,
    )


def parse_glossary(path: Path) -> GlossaryInfo:
    """Parse the canonical glossary format without silently dropping entries."""

    try:
        raw = path.read_bytes()
    except OSError as error:
        raise BridgeError(f"glossary is missing or unreadable: {path}") from error
    if not raw:
        raise BridgeError(f"glossary is empty: {path}")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise BridgeError(f"glossary is not valid UTF-8: {path}") from error
    if text.startswith("\ufeff"):
        text = text[1:]

    terms: list[str] = []
    seen: set[str] = set()
    for line_number, line in enumerate(text.split("\n"), start=1):
        if line.endswith("\r"):
            line = line[:-1]
        if any(unicodedata.category(character) == "Cc" for character in line):
            raise BridgeError(f"glossary line {line_number} contains a control character")
        candidate = unicodedata.normalize("NFC", line.strip())
        if not candidate or candidate.startswith("#"):
            continue
        if not (1 <= len(candidate) <= 256):
            raise BridgeError(
                f"glossary line {line_number} must contain 1 through 256 Unicode scalars"
            )
        if any(unicodedata.category(character) == "Cc" for character in candidate):
            raise BridgeError(f"glossary line {line_number} contains a control character")
        if candidate not in seen:
            seen.add(candidate)
            terms.append(candidate)

    if not terms:
        raise BridgeError(f"glossary has no usable terms: {path}")
    return GlossaryInfo(raw_sha256=hashlib.sha256(raw).hexdigest(), terms=tuple(terms))


def make_context(terms: Sequence[str]) -> str:
    """Construct the exact VibeVoice decode-time context payload."""

    return CONTEXT_HEADER + "\n".join(terms)


def path_exists_or_symlink(path: Path) -> bool:
    """Treat a broken symlink as an existing output that must be preserved."""

    return path.exists() or path.is_symlink()


def assert_output_paths_are_new(
    audio_path: Path,
    glossary_path: Path | None,
    raw_output_prefix: Path,
    metadata_output: Path,
) -> tuple[Path, Path]:
    """Ensure this run cannot overwrite or alias any existing input/output."""

    if str(raw_output_prefix) in {"", ".", "-"}:
        raise BridgeError("raw output prefix must name a new filesystem path")
    raw_json = Path(f"{raw_output_prefix}.json")
    raw_txt = Path(f"{raw_output_prefix}.txt")
    for output in (metadata_output, raw_json, raw_txt):
        if path_exists_or_symlink(output):
            raise BridgeError(f"refusing to overwrite existing output: {output}")

    input_paths = [audio_path.resolve()]
    if glossary_path is not None:
        input_paths.append(glossary_path.resolve())
    for output in (raw_output_prefix, raw_json, raw_txt, metadata_output):
        resolved_output = output.resolve()
        if any(resolved_output == input_path for input_path in input_paths):
            raise BridgeError(f"output path aliases an input: {output}")
    return raw_json, raw_txt


def snapshot_directory(model: ModelSpec) -> Path:
    """Return the exact Hugging Face snapshot this run is allowed to use."""

    hf_home = Path(os.environ.get("HF_HOME", str(Path.home() / ".cache" / "huggingface")))
    repository_leaf = "models--" + model.model_id.replace("/", "--")
    return hf_home / "hub" / repository_leaf / "snapshots" / model.revision


def snapshot_tree_hash(snapshot: Path) -> str:
    """Hash an exact HF snapshot, including its linked blob-file contents."""

    if not snapshot.is_dir() or snapshot.is_symlink():
        raise BridgeError(f"required HF snapshot is missing: {snapshot}")
    repository_root = snapshot.parent.parent.resolve()
    if not repository_root.is_dir():
        raise BridgeError(f"required HF repository cache is missing: {repository_root}")
    digest = hashlib.sha256()

    def add_record(kind: bytes, relative_path: Path, payload: bytes = b"") -> None:
        digest.update(kind)
        digest.update(relative_path.as_posix().encode("utf-8", "surrogateescape"))
        digest.update(b"\0")
        digest.update(payload)
        digest.update(b"\0")

    def visit(directory: Path) -> None:
        try:
            entries = sorted(directory.iterdir(), key=lambda entry: entry.name)
        except OSError as error:
            raise BridgeError(f"cannot read required HF snapshot: {snapshot}") from error
        for entry in entries:
            relative = entry.relative_to(snapshot)
            try:
                entry_status = entry.lstat()
            except OSError as error:
                raise BridgeError(f"cannot inspect required HF snapshot entry: {entry}") from error
            if stat.S_ISLNK(entry_status.st_mode):
                try:
                    link_target = os.readlink(entry)
                    resolved_target = entry.resolve(strict=True)
                    resolved_target.relative_to(repository_root)
                    target_status = resolved_target.stat()
                except (OSError, RuntimeError, ValueError) as error:
                    raise BridgeError(f"invalid required HF snapshot link: {entry}") from error
                if not stat.S_ISREG(target_status.st_mode):
                    raise BridgeError(
                        f"HF snapshot link must resolve to a regular file: {entry}"
                    )
                link_payload = (
                    link_target.encode("utf-8", "surrogateescape")
                    + b"\0"
                    + bytes.fromhex(sha256_file(resolved_target))
                )
                add_record(b"L", relative, link_payload)
            elif stat.S_ISDIR(entry_status.st_mode):
                add_record(b"D", relative)
                visit(entry)
            elif stat.S_ISREG(entry_status.st_mode):
                add_record(b"F", relative, bytes.fromhex(sha256_file(entry)))
            else:
                raise BridgeError(f"unsupported entry in required HF snapshot: {entry}")

    add_record(b"D", Path("."))
    visit(snapshot)
    return digest.hexdigest()


def validate_raw_json(raw_json: Path, duration_seconds: float) -> tuple[Mapping[str, Any], str]:
    """Validate the raw VibeVoice JSON and return it with its transcript."""

    if not path_exists_or_symlink(raw_json):
        raise BridgeError(f"VibeVoice did not create required raw JSON: {raw_json}")
    try:
        with raw_json.open("r", encoding="utf-8") as stream:
            payload = json.load(stream)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BridgeError(f"VibeVoice raw JSON is invalid: {raw_json}") from error
    if not isinstance(payload, dict):
        raise BridgeError("VibeVoice raw JSON must have an object at top level")
    segments = payload.get("segments")
    if not isinstance(segments, list) or not segments:
        raise BridgeError("VibeVoice raw JSON must contain nonempty segments")

    previous: tuple[float, float] | None = None
    transcript_parts: list[str] = []
    for index, segment in enumerate(segments):
        if not isinstance(segment, dict):
            raise BridgeError(f"raw JSON segment {index} is not an object")
        text = segment.get("text")
        start = segment.get("start")
        end = segment.get("end")
        if not isinstance(text, str) or not text.strip():
            raise BridgeError(f"raw JSON segment {index} has empty text")
        if isinstance(start, bool) or isinstance(end, bool) or not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
            raise BridgeError(f"raw JSON segment {index} has nonnumeric bounds")
        start_float, end_float = float(start), float(end)
        if not math.isfinite(start_float) or not math.isfinite(end_float):
            raise BridgeError(f"raw JSON segment {index} has nonfinite bounds")
        if not 0 <= start_float < end_float <= duration_seconds + 0.01:
            raise BridgeError(f"raw JSON segment {index} falls outside the input duration")
        current = (start_float, end_float)
        if previous is not None and current < previous:
            raise BridgeError(f"raw JSON segments are not ordered at segment {index}")
        previous = current
        transcript_parts.append(text)

    transcript = "\n".join(transcript_parts).strip()
    if not transcript:
        raise BridgeError("VibeVoice raw JSON aggregate transcript is empty")
    return payload, transcript


def metadata_raw_path(raw_json: Path, metadata_output: Path) -> str:
    """Use a relative artifact path when it remains under the metadata parent."""

    resolved_raw = raw_json.resolve()
    parent = metadata_output.parent.resolve()
    try:
        return str(resolved_raw.relative_to(parent))
    except ValueError:
        return str(resolved_raw)


def run_benchmark(args: argparse.Namespace) -> None:
    """Perform one protected VibeVoice invocation and write validated metadata."""

    model = resolve_model(args.model)
    audio_path = Path(args.audio)
    glossary_path = Path(args.glossary) if args.glossary is not None else None
    raw_prefix = Path(args.raw_output_prefix)
    metadata_output = Path(args.metadata_output)
    raw_json, raw_txt = assert_output_paths_are_new(
        audio_path, glossary_path, raw_prefix, metadata_output
    )
    audio_before = inspect_wav(audio_path)
    glossary = parse_glossary(glossary_path) if glossary_path is not None else None
    context = make_context(glossary.terms) if glossary is not None else None
    context_sha256 = hashlib.sha256(context.encode("utf-8")).hexdigest() if context else None
    snapshot = snapshot_directory(model)
    snapshot_before = snapshot_tree_hash(snapshot)

    try:
        mlx_audio_version = version("mlx-audio")
    except PackageNotFoundError as error:
        raise BridgeError("mlx-audio is not installed; use the pinned benchmark venv") from error
    if mlx_audio_version != EXPECTED_MLX_AUDIO_VERSION:
        raise BridgeError(
            f"requires mlx-audio {EXPECTED_MLX_AUDIO_VERSION}, found {mlx_audio_version}"
        )

    # Imports stay here so argparse's --help never needs the MLX environment.
    from mlx_audio.stt.generate import generate_transcription
    from mlx_audio.stt.utils import load_model

    started = time.monotonic()
    loaded_model = load_model(model.model_id, revision=model.revision)
    generate_transcription(
        model=loaded_model,
        audio=str(audio_before.path),
        output_path=str(raw_prefix),
        format="json",
        max_tokens=8192,
        prefill_step_size=2048,
        verbose=True,
        context=context,
    )
    elapsed_seconds = time.monotonic() - started

    if path_exists_or_symlink(raw_txt):
        raise BridgeError(f"VibeVoice created forbidden text fallback: {raw_txt}")
    _, transcript = validate_raw_json(raw_json, audio_before.duration_seconds)
    audio_after_hash = sha256_file(audio_before.path)
    if audio_after_hash != audio_before.sha256:
        raise BridgeError("audio input changed during VibeVoice inference")
    snapshot_after = snapshot_tree_hash(snapshot)
    if snapshot_after != snapshot_before:
        raise BridgeError("exact HF snapshot changed during VibeVoice inference")

    raw_json_hash = sha256_file(raw_json)
    metadata = {
        "audio": {
            "basename": audio_before.path.name,
            "duration_seconds": audio_before.duration_seconds,
            "sha256_after": audio_after_hash,
            "sha256_before": audio_before.sha256,
            "size_bytes": audio_before.size_bytes,
        },
        "elapsed_wall_seconds": elapsed_seconds,
        "glossary": {
            "applied": glossary is not None,
            "count": len(glossary.terms) if glossary is not None else 0,
            "injection_mode": "decode_time_context" if glossary is not None else "none",
            "raw_sha256": glossary.raw_sha256 if glossary is not None else None,
        },
        "mlx_audio_version": mlx_audio_version,
        "model": {
            "id": model.model_id,
            "quantization": model.quantization,
            "revision": model.revision,
        },
        "raw_json": {
            "path": metadata_raw_path(raw_json, metadata_output),
            "sha256": raw_json_hash,
        },
        "snapshot": {
            "tree_sha256_after": snapshot_after,
            "tree_sha256_before": snapshot_before,
        },
        "success": True,
        "transcript_sha256": hashlib.sha256(transcript.encode("utf-8")).hexdigest(),
        "context_sha256": context_sha256,
    }
    metadata_output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with metadata_output.open("x", encoding="utf-8") as stream:
            json.dump(metadata, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
    except FileExistsError as error:
        raise BridgeError(f"refusing to overwrite existing output: {metadata_output}") from error


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the intentionally narrow CLI surface."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, choices=tuple(MODEL_SPECS))
    parser.add_argument("--audio", required=True, help="nonempty WAV input")
    parser.add_argument("--glossary", help="canonical UTF-8 glossary file")
    parser.add_argument("--raw-output-prefix", required=True, help="new raw output path prefix")
    parser.add_argument("--metadata-output", required=True, help="new metadata JSON path")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the bridge, reporting expected contract failures without a traceback."""

    try:
        run_benchmark(parse_args(argv))
    except BridgeError as error:
        print(f"vibevoice benchmark: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
