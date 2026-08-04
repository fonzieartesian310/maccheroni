from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import wave

from check_run import validate_run


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


class CheckRunTests(unittest.TestCase):
    def make_asr_run(self, root: Path) -> tuple[Path, Path]:
        input_path = root / "fixture" / "input.wav"
        input_path.parent.mkdir(parents=True)
        with wave.open(str(input_path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16_000)
            output.writeframes(b"\0\0" * 16_000)

        input_hash = sha256_file(input_path)
        segments = {
            "schema_version": "1.0.0",
            "segments": [
                {
                    "speaker": "UNASSIGNED",
                    "start_s": 0.0,
                    "end_s": 1.0,
                    "text": "hello",
                    "language": "en",
                }
            ],
            "num_speakers": 0,
            "source": {
                "file_name": "input.wav",
                "sha256": input_hash,
                "duration_s": 1.0,
            },
        }
        scores = {
            "wer": {"error_rate": 0.0},
            "cer": {"error_rate": 0.0},
            "omissions": {"omission_rate": 0.0},
        }
        run_root = root / "run"
        (run_root / "primary").mkdir(parents=True)
        (run_root / "primary/raw.txt").write_text("hello\n", encoding="utf-8")
        write_json(run_root / "primary/segments.json", segments)
        write_json(run_root / "diarization/timeline.json", [])
        write_json(run_root / "merged/segments.json", segments)
        write_json(run_root / "merged/conflicts.json", [])
        write_json(run_root / "scores.json", scores)

        artifact_paths = (
            "primary/raw.txt",
            "primary/segments.json",
            "diarization/timeline.json",
            "merged/segments.json",
            "merged/conflicts.json",
            "scores.json",
        )
        manifest = {
            "schema_version": "1.0.0",
            "run_id": "test-asr-run",
            "status": "succeeded",
            "input": {
                "file_name": input_path.name,
                "sha256": input_hash,
                "size_bytes": input_path.stat().st_size,
            },
            "backend": {"name": "test", "version": "1.0.0"},
            "models": [
                {
                    "role": "asr",
                    "hf_model_id": "owner/model",
                    "revision": "a" * 40,
                    "quantization": "bf16",
                }
            ],
            "glossary": {
                "provided": False,
                "sha256": None,
                "item_count": 0,
                "injection_mode": "none",
                "applied": False,
            },
            "preprocessing": {
                "sample_rate_hz": 16_000,
                "channels": 1,
                "peak_normalization": False,
                "vad": {"enabled": False, "backend": None},
                "enhancement": {"enabled": False, "backend": None},
            },
            "coverage": {
                "input_duration_s": 1.0,
                "processed_duration_s": 1.0,
                "truncated": False,
                "strategy": "full",
                "chunks_planned": 1,
                "chunks_completed": 1,
            },
            "chunk_boundaries": [
                {"index": 0, "start_s": 0.0, "end_s": 1.0, "status": "succeeded"}
            ],
            "timing": {
                "started_at": "2026-08-03T00:00:00Z",
                "finished_at": "2026-08-03T00:00:01Z",
                "wall_time_s": 1.0,
            },
            "peak_memory_bytes": 1,
            "artifacts": [
                {"kind": path.replace("/", "_"), "path": path, "sha256": sha256_file(run_root / path)}
                for path in artifact_paths
            ],
            "failure": None,
        }
        write_json(run_root / "manifest.json", manifest)
        return run_root, input_path

    def test_valid_asr_run_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, input_path = self.make_asr_run(Path(temporary_directory))
            manifest = validate_run(run_root, input_path, "asr")
            self.assertEqual(manifest["run_id"], "test-asr-run")

    def test_mutated_artifact_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root, input_path = self.make_asr_run(Path(temporary_directory))
            (run_root / "primary/raw.txt").write_text("changed\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "artifact hash mismatch"):
                validate_run(run_root, input_path, "asr")


if __name__ == "__main__":
    unittest.main()
