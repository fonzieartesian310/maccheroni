from __future__ import annotations

from hashlib import sha256
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave


SCORING = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCORING))

from evaluate_moss_long_audio import (  # noqa: E402
    EVALUATOR_SOURCE,
    EvaluationError,
    INPUT_SAMPLES,
    MODEL,
    PROVENANCE_ONLY_FIELDS,
    analyze_attempt_tree,
    choose_default,
    comparable_encoding,
    default_decision,
    derive_verdict,
    evaluate_explicit_failed_case,
    evaluator_provenance,
    file_sha256,
    main,
    parse_time_profile,
    quality_passes,
    resolve_execution_run,
    safe_relative,
    seal_evaluation,
    speaker_repeat_consistency,
    timeline_frame_agreement,
)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def digest(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


class EvaluateMOSSLongAudioTests(unittest.TestCase):
    def explicit_failed_case_fixture(
        self,
        root: Path,
        *,
        identifier: str = "candidate-240",
        failure_code: str = "invalid_eos_output",
        manifest_failure_code: str | None = None,
        attempt_status: str | None = None,
        attempt_error_code: str | None = None,
        helper_failure_code: str | None = None,
        message: str = "wording is not part of classification",
    ) -> tuple[dict, dict, dict, Path, dict, dict]:
        # The four codes below are independent evidence fields written by
        # different producers. They default to one value for the common case,
        # but each can be set alone so a single disagreement is testable.
        manifest_failure_code = manifest_failure_code or failure_code
        attempt_status = attempt_status or failure_code
        attempt_error_code = attempt_error_code or failure_code
        helper_failure_code = helper_failure_code or failure_code
        run = root / "cases" / identifier / "runs" / "failed-run"
        attempt = run / "primary" / "attempts" / "chunk-0000-root"
        helper_directory = attempt / "backend-records" / "asr-test"
        helper_directory.mkdir(parents=True)
        (run / "preprocess").mkdir()
        (run / "diarization").mkdir()

        input_sha256 = "1" * 64
        glossary_sha256 = "2" * 64
        helper_sha256 = "3" * 64
        instruction_sha256 = "4" * 64
        fingerprint = {
            "configuration": "release",
            "contract_version": "moss-harness-v2",
            "executable_sha256": "5" * 64,
            "metallib_sha256": "6" * 64,
            "sha256": helper_sha256,
            "target_architecture": "arm64",
        }
        glossary_not_applied = {
            "applied": False,
            "injection_mode": "hotword_instruction",
            "item_count": 9,
            "provided": True,
            "sha256": glossary_sha256,
        }
        timeline_path = run / "diarization" / "timeline.json"
        write_json(
            timeline_path,
            [{"end_s": 1.0, "speaker": "S00", "start_s": 0.0}],
        )
        manifest_path = run / "manifest.json"
        write_json(
            manifest_path,
            {
                "artifacts": [
                    {
                        "path": "diarization/timeline.json",
                        "sha256": digest(timeline_path),
                    }
                ],
                "coverage": {
                    "chunks_completed": 0,
                    "input_duration_s": 600.0,
                    "processed_duration_s": 0,
                    "truncated": True,
                },
                "failure": {"code": manifest_failure_code, "message": message},
                "glossary": glossary_not_applied,
                "input": {"sha256": input_sha256},
                "models": [MODEL],
                "schema_version": "1.0.0",
                "status": "failed",
                "timing": {"wall_time_s": 12.5},
            },
        )
        write_json(
            run / "preprocess" / "asr-constraints.json",
            {
                "backend": "moss",
                "helper_fingerprint": fingerprint,
                "model": MODEL,
                "moss_context_plan": {
                    "context_hard_cap_tokens": 131072,
                    "glossary_item_count": 9,
                    "glossary_sha256": glossary_sha256,
                    "helper_fingerprint_sha256": helper_sha256,
                    "language": "it",
                    "maximum_tokens": 5120,
                    "model": MODEL,
                    "prompt_tokens": 100,
                },
                "overlap_enabled": False,
                "policy": {
                    "context_hard_cap_tokens": 131072,
                    "maximum_initial_duration_s": 240,
                    "maximum_recovery_depth": 3,
                    "maximum_tokens": 5120,
                    "minimum_initial_duration_s": 120,
                    "minimum_recovery_duration_s": 30,
                    "preferred_initial_duration_s": 240,
                    "source": "benchmark-evaluation",
                },
                "previous_text_context_enabled": False,
                "schema_version": "1.0.0",
                "sequential_concurrency": 1,
                "total_samples": INPUT_SAMPLES,
            },
        )

        audio_path = attempt / "audio.wav"
        with wave.open(str(audio_path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(16_000)
            output.writeframes(b"\0\0")
        request_path = attempt / "request.json"
        write_json(
            request_path,
            {
                "audio_path": str(audio_path.relative_to(run)),
                "audio_sha256": digest(audio_path),
                "backend": "moss",
                "end_sample": 1,
                "glossary": glossary_not_applied,
                "helper_fingerprint": fingerprint,
                "language": "it",
                "maximum_tokens": 5120,
                "model": MODEL,
                "start_sample": 0,
            },
        )
        outcome_path = attempt / "outcome.json"
        write_json(
            outcome_path,
            {
                "canonical_promoted": False,
                "child_attempt_ids": [],
                "error_code": attempt_error_code,
                "error_message": message,
                "request_sha256": digest(request_path),
                "status": attempt_status,
            },
        )
        helper_path = helper_directory / "moss.json"
        write_json(
            helper_path,
            {
                "failure": {"code": helper_failure_code, "message": message},
                "glossary": {
                    "applied": True,
                    "instruction_sha256": instruction_sha256,
                    "item_count": 9,
                },
                "language": {
                    "instruction_sha256": instruction_sha256,
                    "prompt_guidance_applied": True,
                    "requested": "it",
                },
                "metrics": {
                    "context_hard_cap_tokens": 131072,
                    "max_tokens": 5120,
                    "prompt_tokens": 100,
                    "stop_reason": "endOfSequence",
                },
                "model": {
                    "hf_id": MODEL["hf_model_id"],
                    "quantization": MODEL["quantization"],
                    "revision": MODEL["revision"],
                },
                "raw_text": "isolated malformed output",
                "segments": [],
                "status": "failed",
            },
        )

        experiment = {"git_head": "a" * 40}
        case = {
            "forced_recovery": False,
            "id": identifier,
            "leaf_seconds": 240,
            "maximum_tokens": 5120,
        }
        fixture = {
            "glossary_sha256": glossary_sha256,
            "input_sha256": input_sha256,
        }
        execution_path = root / "cases" / identifier / "execution.json"
        execution = {
            "exit_code": 1,
            "run_path": str(run.relative_to(root)),
        }
        time_profile = {
            "external_wall_time_s": 13.0,
            "maximum_resident_set_size_bytes": 1000,
            "peak_memory_footprint_bytes": 900,
        }
        return experiment, case, fixture, execution_path, execution, time_profile

    def test_explicit_failed_case_uses_codes_and_ignores_messages(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = self.explicit_failed_case_fixture(root)
            result = evaluate_explicit_failed_case(root, *arguments)
            self.assertEqual(result["disposition"], "disqualified")
            self.assertEqual(result["explicit_failure"]["code"], "invalid_eos_output")
            self.assertIsNone(result["attempts"]["runner_wall_s"])
            self.assertIsNone(result["attempts"]["process_setup_s"])

            run = root / "cases/candidate-240/runs/failed-run"
            manifest = json.loads((run / "manifest.json").read_text(encoding="utf-8"))
            manifest["failure"]["message"] = "completely different text"
            write_json(run / "manifest.json", manifest)
            outcome = json.loads(
                (run / "primary/attempts/chunk-0000-root/outcome.json").read_text(
                    encoding="utf-8"
                )
            )
            outcome["error_message"] = "another wording"
            write_json(run / "primary/attempts/chunk-0000-root/outcome.json", outcome)
            helper_path = next(
                (run / "primary/attempts/chunk-0000-root/backend-records").glob(
                    "*/moss.json"
                )
            )
            helper = json.loads(helper_path.read_text(encoding="utf-8"))
            helper["failure"]["message"] = "message changed"
            write_json(helper_path, helper)

            repeated = evaluate_explicit_failed_case(root, *arguments)
            self.assertEqual(repeated["explicit_failure"]["code"], "invalid_eos_output")

    def test_explicit_failed_case_rejects_non_typed_failure_code(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = self.explicit_failed_case_fixture(
                root,
                failure_code="model_missing",
            )
            with self.assertRaises(EvaluationError):
                evaluate_explicit_failed_case(root, *arguments)

    def test_explicit_failed_case_rejects_a_lone_manifest_code_divergence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = self.explicit_failed_case_fixture(
                root,
                manifest_failure_code="model_missing",
            )
            with self.assertRaises(EvaluationError):
                evaluate_explicit_failed_case(root, *arguments)

    def test_explicit_failed_case_rejects_a_lone_attempt_status_divergence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = self.explicit_failed_case_fixture(
                root,
                attempt_status="model_missing",
            )
            with self.assertRaises(EvaluationError):
                evaluate_explicit_failed_case(root, *arguments)

    def test_explicit_failed_case_rejects_a_lone_attempt_error_code_divergence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = self.explicit_failed_case_fixture(
                root,
                attempt_error_code="model_missing",
            )
            with self.assertRaises(EvaluationError):
                evaluate_explicit_failed_case(root, *arguments)

    def test_explicit_failed_case_rejects_a_lone_helper_code_divergence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = self.explicit_failed_case_fixture(
                root,
                helper_failure_code="model_missing",
            )
            with self.assertRaises(EvaluationError):
                evaluate_explicit_failed_case(root, *arguments)

    def test_explicit_failed_case_integrity_is_derived_from_its_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = self.explicit_failed_case_fixture(root)
            result = evaluate_explicit_failed_case(root, *arguments)
            self.assertTrue(result["integrity_passed"])

            run = root / "cases/candidate-240/runs/failed-run"
            promoted = run / "primary" / "raw.txt"
            promoted.parent.mkdir(parents=True, exist_ok=True)
            promoted.write_text("promoted after failure\n", encoding="utf-8")
            with self.assertRaises(EvaluationError):
                evaluate_explicit_failed_case(root, *arguments)

    def test_explicit_failed_case_rejects_forced_recovery_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            arguments = list(self.explicit_failed_case_fixture(root))
            arguments[1] = dict(arguments[1], forced_recovery=True)
            with self.assertRaises(EvaluationError):
                evaluate_explicit_failed_case(root, *arguments)

    def test_all_disqualified_candidates_produce_failed_verdict_and_exit(self) -> None:
        cases = [
            {
                "explicit_failure": {
                    "code": "invalid_eos_output",
                    "failure_point": "moss_helper_output",
                },
                "forced_recovery": False,
                "id": f"candidate-{seconds}",
                "integrity_passed": True,
                "quality_pass": False,
            }
            for seconds in (120, 240, 300)
        ]
        cases.append(
            {
                "explicit_failure": None,
                "forced_recovery": True,
                "id": "forced-recovery-240-1024",
                "integrity_passed": True,
                "quality_pass": True,
            }
        )
        verdict = derive_verdict(cases)
        self.assertFalse(verdict["passed"])
        self.assertEqual(len(verdict["anomalies"]), 3)
        self.assertEqual(verdict["quality_comparison_case_ids"], [])
        self.assertEqual(
            len(verdict["anomalies"]),
            sum(1 for case in cases if case["explicit_failure"] is not None),
        )
        self.assertEqual(verdict["unexplained_failure_count"], 0)

        with patch("evaluate_moss_long_audio.evaluate", return_value={
            "evaluation_id": "negative",
            "passed": False,
            "quality_gate_passed": False,
            "suggested_default_leaf_seconds": None,
        }):
            with patch("sys.stdout", new=io.StringIO()):
                self.assertEqual(main(["evaluate_moss_long_audio.py", "/tmp/eval"]), 1)

    def test_main_returns_one_for_a_real_failed_tree_without_mocking_evaluate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "evaluation"
            root.mkdir()
            write_json(root / "experiment.json", {"schema_version": "0.9.0"})
            stderr = io.StringIO()
            with patch("sys.stderr", new=stderr):
                exit_code = main(["evaluate_moss_long_audio.py", str(root)])
            self.assertEqual(exit_code, 1)
            self.assertIn("FAIL:", stderr.getvalue())
            self.assertFalse((root / "evaluation.json").exists())

    def test_main_reports_a_missing_root_and_a_wrong_argument_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "absent"
            with patch("sys.stderr", new=io.StringIO()):
                self.assertEqual(
                    main(["evaluate_moss_long_audio.py", str(missing)]), 1
                )
            with patch("sys.stderr", new=io.StringIO()):
                self.assertEqual(main(["evaluate_moss_long_audio.py"]), 64)

    def test_evaluator_provenance_is_exactly_the_excluded_field_set(self) -> None:
        provenance = evaluator_provenance()
        self.assertEqual(set(provenance), set(PROVENANCE_ONLY_FIELDS))
        self.assertEqual(
            provenance["evaluator_source_sha256"], file_sha256(EVALUATOR_SOURCE)
        )
        head = provenance["evaluator_git_head"]
        self.assertTrue(head is None or len(head) == 40)

    def test_stale_comparison_ignores_provenance_but_not_judgments(self) -> None:
        preserved = {
            "cases": [{"id": "candidate-120", "quality_pass": True}],
            "git_head": "a" * 40,
            "passed": True,
        }
        rebuilt = {**preserved, **evaluator_provenance()}
        self.assertEqual(comparable_encoding(preserved), comparable_encoding(rebuilt))
        changed = {**rebuilt, "passed": False}
        self.assertNotEqual(comparable_encoding(preserved), comparable_encoding(changed))

    def test_seal_accepts_a_preserved_file_that_predates_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evaluation.json"
            preserved = {
                "cases": [{"id": "candidate-120", "quality_pass": True}],
                "git_head": "a" * 40,
                "passed": True,
                "suggested_default_leaf_seconds": 120,
            }
            write_json(output, preserved)
            seal_evaluation(output, {**preserved, **evaluator_provenance()})

            with self.assertRaises(EvaluationError):
                seal_evaluation(
                    output,
                    {
                        **preserved,
                        **evaluator_provenance(),
                        "suggested_default_leaf_seconds": 240,
                    },
                )
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")), preserved
            )

    def test_seal_writes_provenance_into_a_new_evaluation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evaluation.json"
            seal_evaluation(output, {"passed": True, **evaluator_provenance()})
            written = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(
                written["evaluator_source_sha256"], file_sha256(EVALUATOR_SOURCE)
            )
            self.assertIn("evaluator_git_head", written)

    def test_execution_run_resolution_accepts_one_preserved_failed_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            case = root / "cases" / "candidate-240"
            execution = case / "execution.json"
            run = case / "runs" / "failed-run"
            run.mkdir(parents=True)
            self.assertEqual(
                resolve_execution_run(
                    root,
                    execution,
                    {"run_path": None},
                    label="failed run",
                ),
                run,
            )
            (case / "runs" / "second-run").mkdir()
            with self.assertRaises(EvaluationError):
                resolve_execution_run(
                    root,
                    execution,
                    {"run_path": None},
                    label="failed run",
                )

    def test_time_profile_reads_macos_wall_and_memory_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            profile = Path(temporary) / "stderr-time.log"
            profile.write_text(
                "diagnostic\n"
                "        12.34 real         1.00 user         0.50 sys\n"
                "          123456  maximum resident set size\n"
                "          120000  peak memory footprint\n",
                encoding="utf-8",
            )
            self.assertEqual(
                parse_time_profile(profile),
                {
                    "external_wall_time_s": 12.34,
                    "maximum_resident_set_size_bytes": 123456,
                    "peak_memory_footprint_bytes": 120000,
                },
            )

    def test_safe_relative_rejects_absolute_and_parent_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "evidence.json").write_text("{}\n", encoding="utf-8")
            self.assertEqual(
                safe_relative(root, "evidence.json", label="fixture"),
                (root / "evidence.json").resolve(),
            )
            with self.assertRaises(EvaluationError):
                safe_relative(root, "../escape", label="fixture")
            with self.assertRaises(EvaluationError):
                safe_relative(root, "/tmp/escape", label="fixture")

    def test_default_choice_uses_quality_before_runner_and_setup_cost(self) -> None:
        cases = [
            {
                "id": "120",
                "leaf_seconds": 120,
                "quality_pass": True,
                "forced_recovery": False,
                "execution_wall_time_s": 20,
                "attempts": {"runner_wall_s": 18, "process_setup_s": 8},
            },
            {
                "id": "240",
                "leaf_seconds": 240,
                "quality_pass": False,
                "forced_recovery": False,
                "execution_wall_time_s": 10,
                "attempts": {"runner_wall_s": 8, "process_setup_s": 2},
            },
            {
                "id": "300",
                "leaf_seconds": 300,
                "quality_pass": True,
                "forced_recovery": False,
                "execution_wall_time_s": 12,
                "attempts": {"runner_wall_s": 10, "process_setup_s": 3},
            },
            {
                "id": "forced",
                "leaf_seconds": 240,
                "quality_pass": True,
                "forced_recovery": True,
                "execution_wall_time_s": 1,
                "attempts": {"runner_wall_s": 1, "process_setup_s": 0},
            },
        ]
        self.assertEqual(choose_default(cases), 300)
        for case in cases:
            case["quality_pass"] = False
        self.assertIsNone(choose_default(cases))
        decision = default_decision(cases)
        self.assertEqual(decision["status"], "stop_no_quality_candidate")
        self.assertIsNone(decision["suggested_default_leaf_seconds"])
        self.assertEqual(
            set(decision["stop_condition"]["candidate_failures"]),
            {"120", "240", "300"},
        )

    def test_speaker_repeat_consistency_requires_stable_distinct_labels(self) -> None:
        reference = [
            {"start_s": 0.0, "end_s": 5.0, "speaker": "A"},
            {"start_s": 5.0, "end_s": 10.0, "speaker": "B"},
            {"start_s": 30.0, "end_s": 35.0, "speaker": "A"},
            {"start_s": 35.0, "end_s": 40.0, "speaker": "B"},
        ]
        timeline = [
            {"start_s": 0.0, "end_s": 5.0, "speaker": "0"},
            {"start_s": 5.0, "end_s": 10.0, "speaker": "1"},
            {"start_s": 30.0, "end_s": 35.0, "speaker": "0"},
            {"start_s": 35.0, "end_s": 40.0, "speaker": "1"},
        ]
        found = speaker_repeat_consistency(
            reference,
            timeline,
            block_duration_s=30,
            repeat_count=2,
        )
        self.assertEqual(found["speakers"]["A"]["stability"], 1.0)
        self.assertEqual(found["speakers"]["B"]["dominant_label"], "1")

        collapsed = [dict(segment, speaker="0") for segment in timeline]
        with self.assertRaises(EvaluationError):
            speaker_repeat_consistency(
                reference,
                collapsed,
                block_duration_s=30,
                repeat_count=2,
            )

    def test_timeline_agreement_tolerates_only_small_boundary_jitter(self) -> None:
        baseline = [(0.0, 300.0, "S00"), (300.0, 600.0, "S01")]
        jittered = [(0.0, 300.01, "S00"), (300.01, 600.0, "S01")]
        changed = [(0.0, 300.0, "S01"), (300.0, 600.0, "S00")]
        self.assertGreater(timeline_frame_agreement(baseline, jittered)["agreement"], 0.995)
        self.assertLess(timeline_frame_agreement(baseline, changed)["agreement"], 0.995)

    def test_quality_gate_includes_boundary_and_speaker_failures(self) -> None:
        text_scores = {
            "cer": {"error_rate": 0.05},
            "wer": {"error_rate": 0.10},
            "terms": {"term_recall": 0.80},
            "omissions": {"omitted_utterances": 0},
        }
        speakers = {"speakers": {"A": {"stability": 1.0}, "B": {"stability": 1.0}}}
        boundaries = {
            "missing_reference_utterances": 0,
            "reference_speech_cuts": 0,
            "speaker_mismatches": 0,
            "worst_term_recall": 0.1,
            "worst_wer": 0.0,
        }
        self.assertEqual(quality_passes(text_scores, speakers, boundaries), (True, []))
        speakers["speakers"]["B"]["stability"] = 0.5
        passed, failures = quality_passes(text_scores, speakers, boundaries)
        self.assertFalse(passed)
        self.assertTrue(any("speaker B" in failure for failure in failures))

    def test_attempt_tree_accepts_only_contiguous_eos_promotions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary)
            input_sha256 = "c" * 64
            glossary_sha256 = "d" * 64
            helper_sha256 = "a" * 64
            helper = {
                "configuration": "release",
                "contract_version": "moss-harness-v2",
                "executable_sha256": "e" * 64,
                "metallib_sha256": "f" * 64,
                "sha256": helper_sha256,
                "target_architecture": "arm64",
            }
            canonical_paths = (
                "primary/raw.txt",
                "primary/segments.json",
                "merged/segments.json",
                "merged/conflicts.json",
            )
            for relative in canonical_paths:
                path = run / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"{relative}\n", encoding="utf-8")
            promoted: list[str] = []
            promoted_hashes: list[str] = []
            leaf_samples = 120 * 16_000
            for index in range(5):
                attempt_id = f"chunk-{index:04d}-root"
                promoted.append(attempt_id)
                directory = run / "primary" / "attempts" / attempt_id
                directory.mkdir(parents=True, exist_ok=True)
                audio_path = directory / "audio.wav"
                with wave.open(str(audio_path), "wb") as output:
                    output.setnchannels(1)
                    output.setsampwidth(2)
                    output.setframerate(16_000)
                    output.writeframes(b"\0" * (leaf_samples * 2))
                runner_path = directory / "runner-record.json"
                raw_path = directory / "backend.raw"
                write_json(runner_path, {"attempt_id": attempt_id})
                raw_path.write_text(f"raw {attempt_id}\n", encoding="utf-8")
                result_path = directory / "result.json"
                write_json(result_path, {"segments": [{"text": f"leaf {index}"}]})
                promoted_hashes.append(digest(result_path))
                request = {
                    "schema_version": "1.0.0",
                    "attempt_id": attempt_id,
                    "parent_id": None,
                    "root_chunk_index": index,
                    "depth": 0,
                    "sample_rate_hz": 16_000,
                    "boundary_source": "input_end",
                    "audio_path": str(audio_path.relative_to(run)),
                    "audio_sha256": digest(audio_path),
                    "backend": "moss",
                    "model": MODEL,
                    "language": "it",
                    "glossary": {
                        "applied": False,
                        "injection_mode": "hotword_instruction",
                        "item_count": 9,
                        "provided": True,
                        "sha256": glossary_sha256,
                    },
                    "maximum_tokens": 5120,
                    "start_sample": index * leaf_samples,
                    "end_sample": min((index + 1) * leaf_samples, INPUT_SAMPLES),
                    "prompt_tokens": 100,
                    "audio_tokens": 200,
                    "context_upper_bound_tokens": 5220,
                    "helper_fingerprint": helper,
                }
                request_path = directory / "request.json"
                write_json(request_path, request)
                outcome = {
                    "schema_version": "1.0.0",
                    "attempt_id": attempt_id,
                    "request_sha256": digest(request_path),
                    "status": "eos_complete",
                    "stop_reason": "endOfSequence",
                    "canonical_promoted": False,
                    "child_attempt_ids": [],
                    "runner_record_path": str(runner_path.relative_to(run)),
                    "runner_record_sha256": digest(runner_path),
                    "backend_raw_path": str(raw_path.relative_to(run)),
                    "backend_raw_sha256": digest(raw_path),
                    "result_path": str(result_path.relative_to(run)),
                    "result_sha256": digest(result_path),
                    "glossary": {
                        "provided": True,
                        "applied": True,
                        "injection_mode": "hotword_instruction",
                        "item_count": 9,
                        "sha256": glossary_sha256,
                    },
                    "glossary_payload_sha256": "b" * 64,
                    "glossary_payload_entry_count": 9,
                    "language": {
                        "instructionSHA256": "1" * 64,
                        "requested": "it",
                        "promptGuidanceApplied": True,
                    },
                    "helper_fingerprint": helper,
                    "command": ["helper", "--max-tokens", "5120"],
                    "audio_tokens": 200,
                    "context_tokens": 200,
                    "metrics": {
                        "audioDurationS": 120.0,
                        "contextHardCapTokens": 131072,
                        "generatedTokens": 100,
                        "maxTokens": 5120,
                        "promptTokens": 100,
                        "totalS": 1.0,
                        "modelLoadS": 0.5,
                        "runnerWallTimeS": 2.0,
                        "peakRSSBytes": 1000,
                    },
                }
                write_json(directory / "outcome.json", outcome)
            write_json(
                run / "primary" / "promotion.json",
                {
                    "schema_version": "1.0.0",
                    "input_sha256_before": input_sha256,
                    "input_sha256_at_promotion": input_sha256,
                    "eos_leaf_attempt_ids": promoted,
                    "eos_leaf_result_sha256": promoted_hashes,
                    "canonical_artifact_sha256": {
                        relative: digest(run / relative) for relative in canonical_paths
                    },
                },
            )

            summary = analyze_attempt_tree(
                run,
                leaf_seconds=120,
                maximum_tokens=5120,
                forced_recovery=False,
                input_sha256=input_sha256,
                glossary_sha256=glossary_sha256,
                constraint_helper_sha256=helper_sha256,
            )
            self.assertEqual(summary["canonical_eos_leaf_count"], 5)
            self.assertEqual(summary["maximum_root_samples"], leaf_samples)
            self.assertEqual(summary["statuses"], {"eos_complete": 5})

            broken_path = (
                run
                / "primary"
                / "attempts"
                / promoted[0]
                / "outcome.json"
            )
            broken = json.loads(broken_path.read_text(encoding="utf-8"))
            broken["stop_reason"] = "maximumTokens"
            write_json(broken_path, broken)
            with self.assertRaises(EvaluationError):
                analyze_attempt_tree(
                    run,
                    leaf_seconds=120,
                    maximum_tokens=5120,
                    forced_recovery=False,
                    input_sha256=input_sha256,
                    glossary_sha256=glossary_sha256,
                    constraint_helper_sha256=helper_sha256,
                )


if __name__ == "__main__":
    unittest.main()
