"""Pure-contract tests for the VibeVoice benchmark bridge."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
import wave
from pathlib import Path


BRIDGE_PATH = Path(__file__).parents[1] / "vibevoice_benchmark.py"
SPEC = importlib.util.spec_from_file_location("vibevoice_benchmark", BRIDGE_PATH)
assert SPEC is not None and SPEC.loader is not None
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)


def write_wav(path: Path, frames: int = 16_000, sample_rate: int = 16_000) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"\0\0" * frames)


class VibeVoiceBenchmarkTests(unittest.TestCase):
    def test_parse_glossary_normalizes_and_stably_deduplicates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            glossary_path = Path(temporary_directory) / "terms.txt"
            raw = "\ufeff  # people\nCafe\u0301\nCafé\n  Qwen3-ASR  \n\n# terms\n"
            glossary_path.write_text(raw, encoding="utf-8")

            glossary = bridge.parse_glossary(glossary_path)

            self.assertEqual(glossary.terms, ("Café", "Qwen3-ASR"))
            self.assertEqual(glossary.raw_sha256, bridge.sha256_file(glossary_path))

    def test_parse_glossary_rejects_controls_and_empty_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            controls = root / "controls.txt"
            controls.write_bytes(b"valid\tterm\n")
            with self.assertRaisesRegex(bridge.BridgeError, "control character"):
                bridge.parse_glossary(controls)

            comments = root / "comments.txt"
            comments.write_text("# only a comment\n\n", encoding="utf-8")
            with self.assertRaisesRegex(bridge.BridgeError, "no usable terms"):
                bridge.parse_glossary(comments)

    def test_context_is_exact(self) -> None:
        self.assertEqual(
            bridge.make_context(("김마케로니", "Qwen3-ASR")),
            "Preserve these spellings only when supported by the audio. Candidate glossary terms:\n"
            "김마케로니\nQwen3-ASR",
        )

    def test_resolve_model_uses_only_pinned_variants(self) -> None:
        eight_bit = bridge.resolve_model("8bit")
        bf16 = bridge.resolve_model("bf16")
        self.assertEqual(
            (eight_bit.model_id, eight_bit.revision, eight_bit.quantization),
            ("mlx-community/VibeVoice-ASR-8bit", "725c72e54d6ef875472c27fbc50fab470a960940", "int8"),
        )
        self.assertEqual(
            (bf16.model_id, bf16.revision, bf16.quantization),
            ("mlx-community/VibeVoice-ASR-bf16", "12076ff8cb141fcb672abc9f8957b08aab5ecf94", "bf16"),
        )
        with self.assertRaises(bridge.BridgeError):
            bridge.resolve_model("main")

    def test_existing_output_is_rejected_before_generation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            audio = root / "input.wav"
            write_wav(audio)
            prefix = root / "raw"
            existing_raw = Path(f"{prefix}.json")
            existing_raw.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(bridge.BridgeError, "refusing to overwrite"):
                bridge.assert_output_paths_are_new(audio, None, prefix, root / "metadata.json")

    def test_snapshot_tree_hash_includes_linked_blob_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory) / "models--mlx-community--VibeVoice-ASR-8bit"
            blob = root / "blobs" / "blob-one"
            snapshot = root / "snapshots" / "revision"
            blob.parent.mkdir(parents=True)
            snapshot.mkdir(parents=True)
            blob.write_bytes(b"first blob contents")
            (snapshot / "config.json").symlink_to(Path("../../blobs/blob-one"))

            before = bridge.snapshot_tree_hash(snapshot)
            blob.write_bytes(b"mutated blob contents")
            after = bridge.snapshot_tree_hash(snapshot)

            self.assertNotEqual(before, after)

    def test_validate_raw_json_accepts_segments_within_synthetic_wav_duration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            audio = root / "input.wav"
            write_wav(audio)
            raw_json = root / "raw.json"
            raw_json.write_text(
                json.dumps(
                    {
                        "text": "ignored by validator",
                        "segments": [
                            {"text": "hello", "start": 0.0, "end": 0.4},
                            {"text": "world", "start": 0.4, "end": 1.0},
                        ],
                    }
                ),
                encoding="utf-8",
            )

            _, transcript = bridge.validate_raw_json(raw_json, bridge.inspect_wav(audio).duration_seconds)

            self.assertEqual(transcript, "hello\nworld")

    def test_validate_raw_json_rejects_out_of_order_or_empty_segments(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            raw_json = Path(temporary_directory) / "raw.json"
            raw_json.write_text(
                json.dumps(
                    {
                        "segments": [
                            {"text": "later", "start": 0.5, "end": 0.9},
                            {"text": "", "start": 0.1, "end": 0.4},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(bridge.BridgeError, "empty text"):
                bridge.validate_raw_json(raw_json, 1.0)


if __name__ == "__main__":
    unittest.main()
