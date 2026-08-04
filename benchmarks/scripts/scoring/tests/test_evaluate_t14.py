from __future__ import annotations

from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import sys
import tempfile
import unittest


SCORING = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCORING))

from evaluate_t14 import (  # noqa: E402
    CASE_NAMES,
    ITALIAN_RUN_ID,
    evaluation_output_paths,
    generate_evaluation_id,
    optional_owner_recording,
    output_artifact_hashes,
    preflight_create_only,
    public_cases_pass,
    public_evaluation_passed,
    public_strict_no_regression,
    validate_evaluation_id,
    verify_run,
)


def digest(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def write_manifest(
    run: Path,
    input_path: Path,
    glossary_path: Path | None,
    *,
    glossary_applied: bool | None = None,
) -> None:
    artifact = run / "artifact.txt"
    artifact.write_text("sealed", encoding="utf-8")
    has_glossary = glossary_path is not None
    manifest = {
        "artifacts": [{"path": "artifact.txt", "sha256": digest(artifact)}],
        "coverage": {
            "input_duration_s": 1.0,
            "processed_duration_s": 1.0,
            "truncated": False,
        },
        "failure": None,
        "glossary": {
            "applied": has_glossary if glossary_applied is None else glossary_applied,
            "injection_mode": "hotword_instruction" if has_glossary else "none",
            "item_count": 1 if has_glossary else 0,
            "provided": has_glossary,
            "sha256": digest(glossary_path) if glossary_path else None,
        },
        "input": {
            "file_name": input_path.name,
            "sha256": digest(input_path),
            "size_bytes": input_path.stat().st_size,
        },
        "models": [
            {
                "hf_model_id": "example/model",
                "quantization": "int8",
                "revision": "0123456789abcdef",
                "role": "asr",
            }
        ],
        "run_id": "fixture-run",
        "status": "succeeded",
    }
    (run / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True), encoding="utf-8"
    )


class EvaluateT14LifecycleTests(unittest.TestCase):
    def test_explicit_evaluation_id_accepts_only_safe_filename_characters(self) -> None:
        self.assertEqual(validate_evaluation_id("t14-20260804T040000Z-ab12.cd_3"), "t14-20260804T040000Z-ab12.cd_3")
        for value in ("", ".", "..", "with space", "../escape", "slash/name", "back\\name", "a" * 129):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    validate_evaluation_id(value)

    def test_generated_id_records_utc_git_head_and_collision_suffix(self) -> None:
        instant = datetime(2026, 8, 4, 4, 5, 6, 123456, tzinfo=timezone.utc)
        identifier = generate_evaluation_id(
            "abcdef1234567890",
            now=instant,
            suffix="cafebabe",
        )
        self.assertEqual(identifier, "t14-20260804T040506123456Z-abcdef12-cafebabe")
        self.assertNotEqual(
            identifier,
            generate_evaluation_id(
                "abcdef1234567890",
                now=instant,
                suffix="deadbeef",
            ),
        )

    def test_create_only_preflight_checks_every_case_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            e2e = Path(directory)
            outputs, summary = evaluation_output_paths(e2e, "fixed-id")
            conflict = outputs["italian-dialogue"]
            conflict.mkdir(parents=True)

            with self.assertRaises(FileExistsError):
                preflight_create_only([*outputs.values(), summary])

            self.assertFalse(summary.exists())
            self.assertFalse(outputs["hike-tech"].exists())
            self.assertFalse(outputs["voxconverse-ppgjx-78m"].exists())

    def test_create_only_preflight_rejects_a_dangling_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            conflict = Path(directory) / "dangling"
            conflict.symlink_to(Path(directory) / "missing-target")

            with self.assertRaises(FileExistsError):
                preflight_create_only([conflict])

    def test_verify_run_gates_artifacts_original_glossary_and_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            input_path = root / "input.wav"
            input_path.write_bytes(b"fixture audio")
            glossary_path = root / "glossary.txt"
            glossary_path.write_text("Maccheroni\n", encoding="utf-8")
            write_manifest(run, input_path, glossary_path)

            integrity = verify_run(run, input_path, glossary_path)
            self.assertTrue(integrity["passed"])
            self.assertTrue(integrity["input_unchanged"])
            self.assertTrue(integrity["glossary_contract_passed"])
            self.assertTrue(integrity["coverage_complete"])
            self.assertTrue(integrity["model_provenance_complete"])

            input_path.write_bytes(b"mutated audio")
            integrity = verify_run(run, input_path, glossary_path)
            self.assertFalse(integrity["passed"])
            self.assertFalse(integrity["input_unchanged"])

    def test_verify_run_rejects_unapplied_or_changed_glossary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            input_path = root / "input.wav"
            input_path.write_bytes(b"fixture audio")
            glossary_path = root / "glossary.txt"
            glossary_path.write_text("Maccheroni\n", encoding="utf-8")
            write_manifest(run, input_path, glossary_path, glossary_applied=False)

            self.assertFalse(verify_run(run, input_path, glossary_path)["passed"])

            write_manifest(run, input_path, glossary_path)
            glossary_path.write_text("changed\n", encoding="utf-8")
            self.assertFalse(verify_run(run, input_path, glossary_path)["passed"])

    def test_verify_run_accepts_explicit_glossary_absence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            input_path = root / "input.wav"
            input_path.write_bytes(b"fixture audio")
            write_manifest(run, input_path, None)

            integrity = verify_run(run, input_path, None)
            self.assertTrue(integrity["passed"])
            self.assertTrue(integrity["glossary_contract_passed"])

    def test_output_artifact_hashes_seals_every_generated_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "scores.json").write_text("{}", encoding="utf-8")
            nested = output / "nested"
            nested.mkdir()
            (nested / "analysis.json").write_text("[]", encoding="utf-8")

            self.assertEqual(
                output_artifact_hashes(output),
                {
                    "nested/analysis.json": digest(nested / "analysis.json"),
                    "scores.json": digest(output / "scores.json"),
                },
            )

    def test_absent_owner_recording_is_supplemental(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing-owner-run"

            def must_not_run(_: Path) -> dict:
                raise AssertionError("absent owner analyzer was invoked")

            self.assertEqual(
                optional_owner_recording(missing, analyzer=must_not_run),
                {"required": False, "status": "absent"},
            )

    def test_owner_structural_failure_is_recorded_without_becoming_a_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            owner = Path(directory) / "owner-run"
            owner.mkdir()

            def fail(_: Path) -> dict:
                raise ValueError("private detail must not be copied")

            self.assertEqual(
                optional_owner_recording(owner, analyzer=fail),
                {
                    "failure_code": "structural_validation_failed",
                    "required": False,
                    "status": "provided_failed",
                },
            )
            cases = {name: {"passed": True} for name in CASE_NAMES}
            self.assertTrue(public_cases_pass(cases))

    def test_owner_structural_success_is_supplemental_and_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            owner = Path(directory) / "owner-run"
            owner.mkdir()
            evidence = {
                "artifact_content_read": False,
                "attempt_count": 10,
                "passed": True,
            }

            self.assertEqual(
                optional_owner_recording(owner, analyzer=lambda _: evidence),
                {
                    "evidence": evidence,
                    "required": False,
                    "status": "provided",
                },
            )

    def test_public_gate_requires_exactly_all_three_cases(self) -> None:
        cases = {name: {"passed": True} for name in CASE_NAMES}
        self.assertTrue(public_cases_pass(cases))
        cases["italian-dialogue"]["passed"] = False
        self.assertFalse(public_cases_pass(cases))
        cases.pop("italian-dialogue")
        self.assertFalse(public_cases_pass(cases))

    def test_strict_public_gate_rejects_failed_missing_and_empty_comparisons(self) -> None:
        cases = {
            name: {"comparison": [{"passed": True}], "passed": True}
            for name in CASE_NAMES
        }
        self.assertTrue(public_strict_no_regression(cases))
        self.assertTrue(public_evaluation_passed(cases))

        cases["italian-dialogue"]["comparison"][0]["passed"] = False
        self.assertFalse(public_strict_no_regression(cases))
        self.assertFalse(public_evaluation_passed(cases))

        cases["italian-dialogue"]["comparison"] = []
        self.assertFalse(public_strict_no_regression(cases))
        self.assertFalse(public_evaluation_passed(cases))

        del cases["italian-dialogue"]["comparison"]
        self.assertFalse(public_strict_no_regression(cases))
        self.assertFalse(public_evaluation_passed(cases))

        cases.pop("italian-dialogue")
        self.assertFalse(public_strict_no_regression(cases))
        self.assertFalse(public_evaluation_passed(cases))

    def test_canonical_italian_winner_is_the_t3_selected_run(self) -> None:
        self.assertEqual(ITALIAN_RUN_ID, "20260803T172306Z-39d9cb")


if __name__ == "__main__":
    unittest.main()
