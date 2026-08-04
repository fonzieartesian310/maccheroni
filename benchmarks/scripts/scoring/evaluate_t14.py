#!/usr/bin/env python3
"""Create immutable T14 evaluation artifacts beside immutable CLI runs."""

from __future__ import annotations

import argparse
from collections import Counter
from collections.abc import Callable, Sequence
from datetime import datetime, timezone
from hashlib import sha256
import json
import math
from pathlib import Path
import re
import secrets
import subprocess
import sys
import wave


REPOSITORY = Path(__file__).resolve().parents[3]
SCORING = REPOSITORY / "benchmarks" / "scripts" / "scoring"
sys.path.insert(0, str(SCORING))

from metrics import term_recall, text_error_rate, utterance_omissions  # noqa: E402
from rttm import diarization_error_rate, read_rttm  # noqa: E402


COMMAND = "python3 benchmarks/scripts/scoring/evaluate_t14.py"
OWNER_RUN_ID = "20260803T170339Z-dd6e3c"
ITALIAN_RUN_ID = "20260803T172306Z-39d9cb"
CASE_NAMES = ("hike-tech", "italian-dialogue", "voxconverse-ppgjx-78m")
EVALUATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
LONG_SOURCE_DURATION_S = 522.768
LONG_REPEAT_OFFSETS = tuple(index * 523.268 for index in range(9))
BACKCHANNELS = (
    ("Sì", 1),
    ("Capisco", 2),
    ("Certo", 3),
    ("Perfetto", 4),
    ("Prego", 5),
    ("Ah", 5),
    ("Va bene", 6),
)


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json_create(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2, sort_keys=True)
        output.write("\n")


def write_text_create(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        output.write(value)


def file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_evaluation_id(value: str) -> str:
    if value in {"", ".", ".."} or not EVALUATION_ID_PATTERN.fullmatch(value):
        raise ValueError("evaluation ID must use 1-128 safe filename characters")
    return value


def generate_evaluation_id(
    git_head: str,
    *,
    now: datetime | None = None,
    suffix: str | None = None,
) -> str:
    instant = now or datetime.now(timezone.utc)
    if instant.tzinfo is None:
        raise ValueError("evaluation ID timestamp must be timezone-aware")
    timestamp = instant.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    nonce = suffix or secrets.token_hex(4)
    return validate_evaluation_id(f"t14-{timestamp}-{git_head[:8]}-{nonce}")


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create immutable T14 evaluation artifacts from preserved runs."
    )
    parser.add_argument(
        "--evaluation-id",
        type=validate_evaluation_id,
        help="Explicit create-only ID for deterministic test or audit runs.",
    )
    return parser.parse_args(argv)


def evaluation_output_paths(
    e2e: Path, evaluation_id: str
) -> tuple[dict[str, Path], Path]:
    case_outputs = {
        name: e2e / name / "evaluation" / evaluation_id for name in CASE_NAMES
    }
    return case_outputs, e2e / f"evaluation-summary-{evaluation_id}.json"


def preflight_create_only(paths: Sequence[Path]) -> None:
    conflicts = [path for path in paths if path.exists() or path.is_symlink()]
    if conflicts:
        relative = ", ".join(str(path) for path in conflicts)
        raise FileExistsError(f"create-only evaluation output exists: {relative}")


def public_cases_pass(cases: dict[str, dict]) -> bool:
    return set(cases) == set(CASE_NAMES) and all(
        bool(cases[name]["passed"]) for name in CASE_NAMES
    )


def public_strict_no_regression(cases: dict[str, dict]) -> bool:
    if set(cases) != set(CASE_NAMES):
        return False
    for name in CASE_NAMES:
        comparisons = cases[name].get("comparison", [])
        if not comparisons or not all(bool(item.get("passed")) for item in comparisons):
            return False
    return True


def public_evaluation_passed(cases: dict[str, dict]) -> bool:
    return public_cases_pass(cases) and public_strict_no_regression(cases)


def joined_text(document: dict) -> str:
    segments = sorted(
        document["segments"],
        key=lambda segment: (float(segment["start_s"]), float(segment["end_s"])),
    )
    return " ".join(str(segment["text"]) for segment in segments)


def score_text(reference_path: Path, hypothesis_path: Path, terms_path: Path) -> dict:
    reference = load_json(reference_path)
    hypothesis = load_json(hypothesis_path)
    reference_text = joined_text(reference)
    hypothesis_text = joined_text(hypothesis)
    return {
        "cer": text_error_rate(reference_text, hypothesis_text, unit="character").as_dict(),
        "omissions": utterance_omissions(reference["segments"], hypothesis["segments"]),
        "terms": term_recall(load_json(terms_path), hypothesis_text),
        "wer": text_error_rate(reference_text, hypothesis_text, unit="word").as_dict(),
    }


def timeline_to_rttm(timeline_path: Path, output_path: Path, file_id: str) -> None:
    timeline = load_json(timeline_path)
    lines = []
    for segment in timeline:
        start = float(segment["start_s"])
        duration = float(segment["end_s"]) - start
        if start < 0 or duration <= 0 or not math.isfinite(duration):
            raise ValueError(f"invalid timeline interval: {segment}")
        lines.append(
            f"SPEAKER {file_id} 1 {start:.6f} {duration:.6f} "
            f"<NA> <NA> {segment['speaker']} <NA> <NA>\n"
        )
    write_text_create(output_path, "".join(lines))


def normalize_text(value: str) -> str:
    import unicodedata

    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = "".join(
        " " if unicodedata.category(character).startswith("P") else character
        for character in normalized
    )
    return " ".join(normalized.split())


def phrase_preserved(phrase: str, hypothesis: str) -> tuple[bool, str, str]:
    expected = normalize_text(phrase)
    actual = normalize_text(hypothesis)
    expected_words = expected.split()
    actual_words = actual.split()
    width = len(expected_words)
    preserved = any(
        actual_words[index : index + width] == expected_words
        for index in range(max(0, len(actual_words) - width + 1))
    )
    return preserved, expected, actual


def backchannel_analysis(fixture: Path, hypothesis_path: Path, run_id: str) -> dict:
    hypothesis = load_json(hypothesis_path)["segments"]
    reference = load_json(fixture / "reference.segments.json")["segments"]
    selection = load_json(fixture / "selection.json")["items"]
    items = {int(item["order"]): item for item in selection}
    evidence = []
    for phrase, order in BACKCHANNELS:
        item = items[order]
        start = float(item["reel_start_s"])
        end = float(item["reel_end_s"])
        overlapping = sorted(
            (
                segment
                for segment in hypothesis
                if float(segment["end_s"]) > start and float(segment["start_s"]) < end
            ),
            key=lambda segment: (float(segment["start_s"]), float(segment["end_s"])),
        )
        collected = " ".join(str(segment["text"]) for segment in overlapping)
        preserved, normalized_phrase, normalized_hypothesis = phrase_preserved(phrase, collected)
        evidence.append(
            {
                "collected_hypothesis_text": collected,
                "item_order": order,
                "item_span": {"end_s": end, "start_s": start},
                "normalized_hypothesis": normalized_hypothesis,
                "normalized_phrase": normalized_phrase,
                "phrase": phrase,
                "preserved": preserved,
                "reference_text": str(reference[order]["text"]),
            }
        )
    preserved_count = sum(bool(item["preserved"]) for item in evidence)
    return {
        "evidence": evidence,
        "fixture_id": "italian-dialogue",
        "preservation_rate": preserved_count / len(BACKCHANNELS),
        "preserved_count": preserved_count,
        "reference_occurrences": len(BACKCHANNELS),
        "run_id": run_id,
    }


def change_points(turns, mapping: dict[str, str] | None = None, require_mapped: bool = False):
    ordered = sorted(turns, key=lambda turn: (turn.start_s, turn.end_s, turn.speaker))
    points = []
    for previous, current in zip(ordered, ordered[1:]):
        previous_mapped = mapping.get(previous.speaker, previous.speaker) if mapping else previous.speaker
        current_mapped = mapping.get(current.speaker, current.speaker) if mapping else current.speaker
        if require_mapped and mapping and (
            previous.speaker not in mapping or current.speaker not in mapping
        ):
            continue
        if previous_mapped == current_mapped or previous.end_s > current.start_s:
            continue
        points.append((current.start_s, previous.speaker, current.speaker))
    return points


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    index = max(0, min(len(values) - 1, math.ceil(fraction * len(values)) - 1))
    return values[index]


def boundary_analysis(reference_rttm: Path, hypothesis_rttm: Path, mapping: dict, run_id: str) -> dict:
    reference_points = change_points(read_rttm(reference_rttm))
    hypothesis_points = change_points(read_rttm(hypothesis_rttm), mapping, True)
    hypothesis_times = [point[0] for point in hypothesis_points]
    boundaries = []
    errors = []
    for reference_time, previous_speaker, next_speaker in reference_points:
        nearest = min(hypothesis_times, key=lambda value: (abs(value - reference_time), value))
        error = abs(nearest - reference_time)
        errors.append(error)
        boundaries.append(
            {
                "absolute_error_s": error,
                "matched": True,
                "nearest_hypothesis_time_s": nearest,
                "next_reference_speaker": next_speaker,
                "previous_reference_speaker": previous_speaker,
                "reference_time_s": reference_time,
            }
        )
    ordered = sorted(errors)
    return {
        "algorithm": "nearest_speaker_change_point",
        "boundaries": boundaries,
        "fixture_id": "voxconverse-ppgjx-78m",
        "hypothesis_change_point_count": len(hypothesis_points),
        "mapping": mapping,
        "matched_count": len(errors),
        "mean_absolute_error_s": sum(errors) / len(errors),
        "median_absolute_error_s": (
            ordered[len(ordered) // 2]
            if len(ordered) % 2
            else (ordered[len(ordered) // 2 - 1] + ordered[len(ordered) // 2]) / 2
        ),
        "p95_absolute_error_s": percentile(ordered, 0.95),
        "reference_boundary_count": len(reference_points),
        "run_id": run_id,
        "within_0_25_s_count": sum(error <= 0.25 for error in errors),
        "within_0_25_s_fraction": sum(error <= 0.25 for error in errors) / len(errors),
    }


def overlap(start_a: float, end_a: float, start_b: float, end_b: float) -> float:
    return max(0.0, min(end_a, end_b) - max(start_a, start_b))


def repeat_consistency(reference_rttm: Path, hypothesis_rttm: Path, run_id: str) -> dict:
    reference = read_rttm(reference_rttm)
    hypothesis = read_rttm(hypothesis_rttm)
    speakers = {}
    for reference_speaker in sorted({turn.speaker for turn in reference}):
        repeats = []
        for repeat_index, offset in enumerate(LONG_REPEAT_OFFSETS):
            window_end = offset + LONG_SOURCE_DURATION_S
            references = [
                turn
                for turn in reference
                if turn.speaker == reference_speaker
                and overlap(turn.start_s, turn.end_s, offset, window_end) > 0
            ]
            label_overlap: dict[str, float] = {}
            for hypothesis_turn in hypothesis:
                total = sum(
                    overlap(
                        reference_turn.start_s,
                        reference_turn.end_s,
                        hypothesis_turn.start_s,
                        hypothesis_turn.end_s,
                    )
                    for reference_turn in references
                )
                if total > 0:
                    label_overlap[hypothesis_turn.speaker] = label_overlap.get(hypothesis_turn.speaker, 0) + total
            dominant = min(label_overlap, key=lambda label: (-label_overlap[label], label))
            repeats.append(
                {
                    "dominant_raw_label": dominant,
                    "offset_s": offset,
                    "overlap_s": label_overlap[dominant],
                    "repeat_index": repeat_index,
                }
            )
        counts = Counter(item["dominant_raw_label"] for item in repeats)
        dominant, count = min(counts.items(), key=lambda item: (-item[1], item[0]))
        speakers[reference_speaker] = {
            "count_out_of_9": count,
            "most_common_dominant_raw_label": dominant,
            "repeats": repeats,
            "stability": count / 9,
        }
    return {
        "fixture_id": "voxconverse-ppgjx-78m",
        "repeat_offsets_s": list(LONG_REPEAT_OFFSETS),
        "repetition_count": 9,
        "run_id": run_id,
        "source_clip_duration_s": LONG_SOURCE_DURATION_S,
        "speakers": speakers,
    }


def nearest_turns(reference_rttm: Path, boundary: float):
    turns = read_rttm(reference_rttm)
    left = max((turn for turn in turns if turn.end_s <= boundary), key=lambda turn: turn.end_s)
    right = min((turn for turn in turns if turn.start_s >= boundary), key=lambda turn: turn.start_s)
    return left, right


def chunk_boundary_analysis(run: Path, reference_rttm: Path, run_id: str) -> dict:
    manifest = load_json(run / "manifest.json")
    timeline = load_json(run / "diarization" / "timeline.json")
    merged = load_json(run / "merged" / "segments.json")["segments"]
    boundaries = []
    for chunk in manifest["chunk_boundaries"][:-1]:
        boundary = float(chunk["end_s"])
        epsilon = 0.000001
        left_ids = sorted(
            str(turn["speaker"])
            for turn in timeline
            if float(turn["start_s"]) <= boundary - epsilon < float(turn["end_s"])
        )
        right_ids = sorted(
            str(turn["speaker"])
            for turn in timeline
            if float(turn["start_s"]) <= boundary + epsilon < float(turn["end_s"])
        )
        shared_ids = sorted(set(left_ids) & set(right_ids))
        reference_left, reference_right = nearest_turns(reference_rttm, boundary)
        merged_left = max(
            (segment for segment in merged if float(segment["end_s"]) <= boundary + 0.01),
            key=lambda segment: float(segment["end_s"]),
        )
        merged_right = min(
            (segment for segment in merged if float(segment["start_s"]) >= boundary - 0.01),
            key=lambda segment: float(segment["start_s"]),
        )
        merged_labels = [str(merged_left["speaker"]), str(merged_right["speaker"])]
        if merged_labels[0] == merged_labels[1] and merged_labels[0] != "UNKNOWN":
            merged_status = "consistent"
        elif "UNKNOWN" in merged_labels and any(label in shared_ids for label in merged_labels):
            merged_status = "uncertainty_preserved_no_contradiction"
        else:
            merged_status = "contradiction"
        boundaries.append(
            {
                "boundary_s": boundary,
                "global_left_ids": left_ids,
                "global_right_ids": right_ids,
                "global_shared_ids": shared_ids,
                "global_timeline_consistent": bool(shared_ids) and left_ids == right_ids,
                "merged_left_speaker": merged_labels[0],
                "merged_right_speaker": merged_labels[1],
                "merged_status": merged_status,
                "reference_left_gap_s": boundary - reference_left.end_s,
                "reference_left_speaker": reference_left.speaker,
                "reference_right_gap_s": reference_right.start_s - boundary,
                "reference_right_speaker": reference_right.speaker,
                "same_reference_speaker": reference_left.speaker == reference_right.speaker,
            }
        )
    return {
        "all_global_boundaries_consistent": all(
            item["global_timeline_consistent"] for item in boundaries
        ),
        "contradictory_merged_boundaries": sum(
            item["merged_status"] == "contradiction" for item in boundaries
        ),
        "fixture_id": "voxconverse-ppgjx-78m",
        "internal_boundary_count": len(boundaries),
        "run_id": run_id,
        "boundaries": boundaries,
    }


def physical_chunk_audit(run: Path) -> dict:
    manifest = load_json(run / "manifest.json")
    chunks = []
    previous_end = 0.0
    for boundary in manifest["chunk_boundaries"]:
        index = int(boundary["index"])
        audio = run / "primary" / "chunks" / str(index) / "audio.wav"
        with wave.open(str(audio), "rb") as source:
            frames = source.getnframes()
            sample_rate = source.getframerate()
            actual = frames / sample_rate
            format_ok = (
                source.getnchannels() == 1
                and source.getsampwidth() == 2
                and sample_rate == 16_000
                and source.getcomptype() == "NONE"
            )
        start = float(boundary["start_s"])
        end = float(boundary["end_s"])
        planned = end - start
        chunks.append(
            {
                "actual_duration_s": actual,
                "contiguous": abs(start - previous_end) <= 1 / 16_000,
                "duration_matches": abs(actual - planned) <= 1 / 16_000,
                "format": "pcm16-mono-16000" if format_ok else "invalid",
                "index": index,
                "max_1200_s": actual <= 1200,
                "path": str(audio.relative_to(run)),
                "planned_duration_s": planned,
                "sha256": file_sha256(audio),
            }
        )
        previous_end = end
    return {
        "all_contiguous": all(chunk["contiguous"] for chunk in chunks),
        "all_duration_matches": all(chunk["duration_matches"] for chunk in chunks),
        "all_pcm16_mono_16000": all(chunk["format"] == "pcm16-mono-16000" for chunk in chunks),
        "all_under_1200_s": all(chunk["max_1200_s"] for chunk in chunks),
        "chunks": chunks,
        "coverage_end_s": previous_end,
    }


def verify_run(run: Path, input_path: Path, glossary_path: Path | None) -> dict:
    manifest_path = run / "manifest.json"
    manifest = load_json(manifest_path)
    failures = []
    for artifact in manifest["artifacts"]:
        path = run / artifact["path"]
        if not path.is_file() or file_sha256(path) != artifact["sha256"]:
            failures.append(artifact["path"])
    input_hash = file_sha256(input_path)
    input_size = input_path.stat().st_size
    expected_input_hash = str(manifest["input"]["sha256"])
    expected_input_size = int(manifest["input"]["size_bytes"])
    input_unchanged = (
        input_hash == expected_input_hash and input_size == expected_input_size
    )

    glossary = manifest["glossary"]
    glossary_hash = file_sha256(glossary_path) if glossary_path else None
    if glossary_path is None:
        glossary_contract_passed = (
            glossary["provided"] is False
            and glossary["applied"] is False
            and glossary["sha256"] is None
            and int(glossary["item_count"]) == 0
            and glossary["injection_mode"] == "none"
        )
    else:
        glossary_contract_passed = (
            glossary["provided"] is True
            and glossary["applied"] is True
            and glossary["sha256"] == glossary_hash
            and int(glossary["item_count"]) > 0
            and glossary["injection_mode"] != "none"
        )

    coverage = manifest["coverage"]
    coverage_complete = (
        coverage["truncated"] is False
        and coverage["processed_duration_s"] == coverage["input_duration_s"]
    )
    model_provenance_complete = bool(manifest["models"]) and all(
        all(str(model.get(key, "")).strip() for key in ("hf_model_id", "revision", "quantization", "role"))
        for model in manifest["models"]
    )
    passed = (
        manifest["status"] == "succeeded"
        and manifest.get("failure") is None
        and not failures
        and input_unchanged
        and glossary_contract_passed
        and coverage_complete
        and model_provenance_complete
    )
    return {
        "artifact_count": len(manifest["artifacts"]),
        "artifact_failures": failures,
        "coverage_complete": coverage_complete,
        "glossary_applied": glossary["applied"],
        "glossary_contract_passed": glossary_contract_passed,
        "glossary_provided": glossary["provided"],
        "glossary_sha256_after": glossary_hash,
        "glossary_sha256_expected": glossary["sha256"],
        "input_sha256_after": input_hash,
        "input_sha256_expected": expected_input_hash,
        "input_size_bytes_after": input_size,
        "input_size_bytes_expected": expected_input_size,
        "input_unchanged": input_unchanged,
        "manifest_sha256": file_sha256(manifest_path),
        "model_provenance_complete": model_provenance_complete,
        "models": manifest["models"],
        "passed": passed,
        "run_id": manifest["run_id"],
        "status": manifest["status"],
    }


def output_artifact_hashes(output: Path) -> dict[str, str]:
    return {
        str(path.relative_to(output)): file_sha256(path)
        for path in sorted(output.rglob("*"))
        if path.is_file()
    }


def owner_long_audio_analysis(run: Path) -> dict:
    manifest = load_json(run / "manifest.json")
    if not (
        manifest["run_id"] == OWNER_RUN_ID
        and manifest["status"] == "succeeded"
        and manifest["failure"] is None
        and manifest["coverage"]["truncated"] is False
        and manifest["coverage"]["processed_duration_s"]
        == manifest["coverage"]["input_duration_s"]
        and manifest["glossary"]["provided"] is False
        and manifest["glossary"]["applied"] is False
    ):
        raise ValueError("owner manifest is not a complete glossary-absent run")

    expected_model = {
        "hf_model_id": "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8",
        "quantization": "int8-decoder+fp16-audio-vq-kv",
        "revision": "90aa65287111a327db98eb83e325bd5332945edd",
        "role": "asr",
    }
    constraints = load_json(run / "preprocess" / "asr-constraints.json")
    policy = constraints["policy"]
    if constraints["model"] != expected_model:
        raise ValueError("owner run MOSS model tuple changed")
    if not any(model == expected_model for model in manifest["models"]):
        raise ValueError("owner manifest lacks the MOSS model tuple")
    if not (
        policy["source"] == "production-default"
        and policy["minimum_initial_duration_s"] == 60
        and policy["preferred_initial_duration_s"] == 120
        and policy["maximum_initial_duration_s"] == 120
        and policy["maximum_tokens"] == 5120
        and policy["minimum_recovery_duration_s"] == 30
        and policy["maximum_recovery_depth"] == 3
    ):
        raise ValueError("owner run did not use the selected production policy")
    helper_sha256 = str(constraints["helper_fingerprint"]["sha256"])
    if (
        len(helper_sha256) != 64
        or constraints["helper_fingerprint"]["contract_version"]
        != "moss-harness-v2"
    ):
        raise ValueError("owner run helper fingerprint is incomplete")

    attempt_root = run / "primary" / "attempts"
    attempts = []
    for directory in sorted(path for path in attempt_root.iterdir() if path.is_dir()):
        request_path = directory / "request.json"
        outcome_path = directory / "outcome.json"
        request = load_json(request_path)
        outcome = load_json(outcome_path)
        if outcome["request_sha256"] != file_sha256(request_path):
            raise ValueError(f"attempt request hash changed: {directory.name}")
        if request["model"] != expected_model or request["maximum_tokens"] != 5120:
            raise ValueError(f"attempt constraint changed: {directory.name}")
        if request["helper_fingerprint"]["sha256"] != helper_sha256:
            raise ValueError(f"attempt helper changed: {directory.name}")
        if request["glossary"]["provided"] or request["glossary"]["applied"]:
            raise ValueError(f"owner attempt falsely reports a glossary: {directory.name}")
        if not (
            outcome["status"] == "eos_complete"
            and outcome["stop_reason"] == "endOfSequence"
            and not outcome["glossary"]["provided"]
            and outcome.get("glossary_payload_sha256") is None
            and outcome["glossary_payload_entry_count"] == 0
            and outcome["language"]["requested"] == "it"
            and outcome["language"]["promptGuidanceApplied"] is True
            and outcome["helper_fingerprint"]["sha256"] == helper_sha256
            and outcome["metrics"]["maxTokens"] == 5120
            and outcome["metrics"]["contextHardCapTokens"] == 131072
        ):
            raise ValueError(f"owner attempt is not a closed EOS leaf: {directory.name}")
        attempts.append((request, outcome))

    attempts.sort(key=lambda item: int(item[0]["start_sample"]))
    total_samples = int(constraints["total_samples"])
    if not attempts or int(attempts[0][0]["start_sample"]) != 0:
        raise ValueError("owner attempt coverage does not start at sample zero")
    if int(attempts[-1][0]["end_sample"]) != total_samples:
        raise ValueError("owner attempt coverage does not reach the input end")
    if any(
        int(left[0]["end_sample"]) != int(right[0]["start_sample"])
        for left, right in zip(attempts, attempts[1:])
    ):
        raise ValueError("owner attempt coverage is not contiguous")
    maximum_leaf_seconds = max(
        (int(request["end_sample"]) - int(request["start_sample"])) / 16000
        for request, _ in attempts
    )
    if maximum_leaf_seconds > 120:
        raise ValueError("owner attempt exceeded the 120 second hard maximum")

    promotion = load_json(run / "primary" / "promotion.json")
    promoted = promotion["eos_leaf_attempt_ids"]
    if promoted != [str(outcome["attempt_id"]) for _, outcome in attempts]:
        raise ValueError("owner promotion does not match the EOS leaves")
    if len(promotion["eos_leaf_result_sha256"]) != len(promoted):
        raise ValueError("owner promotion result seal count changed")
    if not promotion["canonical_artifact_sha256"]:
        raise ValueError("owner promotion lacks canonical artifact seals")
    if not (
        promotion["input_sha256_before"]
        == promotion["input_sha256_at_promotion"]
        == manifest["input"]["sha256"]
    ):
        raise ValueError("owner promotion input seal changed")

    # The checks above raise on the first violation, so this conjunction is
    # what the reported verdict means: every owner check re-read from the
    # preserved run, never a constant.
    checks = (
        manifest["status"] == "succeeded",
        manifest["failure"] is None,
        manifest["coverage"]["truncated"] is False,
        manifest["coverage"]["processed_duration_s"]
        == manifest["coverage"]["input_duration_s"],
        manifest["glossary"]["provided"] is False,
        manifest["glossary"]["applied"] is False,
        constraints["model"] == expected_model,
        any(model == expected_model for model in manifest["models"]),
        len(helper_sha256) == 64,
        constraints["helper_fingerprint"]["contract_version"] == "moss-harness-v2",
        bool(attempts),
        int(attempts[0][0]["start_sample"]) == 0,
        int(attempts[-1][0]["end_sample"]) == total_samples,
        all(
            int(left[0]["end_sample"]) == int(right[0]["start_sample"])
            for left, right in zip(attempts, attempts[1:])
        ),
        maximum_leaf_seconds <= 120,
        promoted == [str(outcome["attempt_id"]) for _, outcome in attempts],
        len(promotion["eos_leaf_result_sha256"]) == len(promoted),
        bool(promotion["canonical_artifact_sha256"]),
        promotion["input_sha256_before"]
        == promotion["input_sha256_at_promotion"]
        == manifest["input"]["sha256"],
    )
    return {
        "artifact_count": len(manifest["artifacts"]),
        "artifact_content_read": False,
        "attempt_count": len(attempts),
        "chunk_boundary_count": max(len(manifest["chunk_boundaries"]) - 1, 0),
        "glossary_provided": False,
        "helper_fingerprint_sha256": helper_sha256,
        "maximum_leaf_seconds": maximum_leaf_seconds,
        "passed": all(checks),
        "promotion_count": len(promoted),
        "total_samples": total_samples,
    }


def optional_owner_recording(
    run: Path,
    *,
    analyzer: Callable[[Path], dict] = owner_long_audio_analysis,
) -> dict:
    if not run.is_dir():
        return {"required": False, "status": "absent"}
    try:
        evidence = analyzer(run)
    except (OSError, KeyError, TypeError, ValueError):
        return {
            "failure_code": "structural_validation_failed",
            "required": False,
            "status": "provided_failed",
        }
    return {
        "evidence": evidence,
        "required": False,
        "status": "provided",
    }


def strict_comparison(current: dict, baseline: dict, paths: list[tuple[str, str]]) -> list[dict]:
    comparisons = []
    for metric, direction in paths:
        keys = metric.split(".")
        current_value = current
        baseline_value = baseline
        for key in keys:
            current_value = current_value[key]
            baseline_value = baseline_value[key]
        passed = current_value <= baseline_value if direction == "lower" else current_value >= baseline_value
        comparisons.append(
            {
                "baseline": baseline_value,
                "current": current_value,
                "delta": current_value - baseline_value,
                "direction": direction,
                "metric": metric,
                "passed": passed,
            }
        )
    return comparisons


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    git_head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=REPOSITORY, text=True
    ).strip()
    evaluation_id = arguments.evaluation_id or generate_evaluation_id(git_head)
    e2e = REPOSITORY / "benchmarks" / "runs" / "e2e"
    case_outputs, summary_path = evaluation_output_paths(e2e, evaluation_id)
    preflight_create_only([*case_outputs.values(), summary_path])
    cases = {
        "hike-tech": {
            "fixture": REPOSITORY / "benchmarks/runs/ko-asr/fixtures/hike-tech",
            "run": e2e / "hike-tech/runs/20260803T043939Z-5d1f5d",
            "baseline": REPOSITORY / "benchmarks/runs/ko-asr/t4-20260803-hike-tech-vibe8-on-r1/scores.json",
        },
        "italian-dialogue": {
            "fixture": REPOSITORY / "benchmarks/runs/it-asr/fixtures/italian-dialogue",
            "run": e2e / f"italian-dialogue/runs/{ITALIAN_RUN_ID}",
            "baseline": REPOSITORY / "benchmarks/runs/it-asr/t6-20260803-italian-dialogue-moss-on-r2/scores.json",
            "diarization_baseline": REPOSITORY / "benchmarks/runs/diarization/t5-20260803-it-dialogue-community1-r1/scores.json",
        },
        "voxconverse-ppgjx-78m": {
            "fixture": REPOSITORY / "benchmarks/runs/diarization/fixtures/voxconverse-ppgjx-78m",
            "run": e2e / "voxconverse-ppgjx-78m/runs/20260803T044246Z-cebdff",
            "baseline_root": REPOSITORY / "benchmarks/runs/diarization/t5-20260803-voxconverse-ppgjx-78m-community1-r1",
        },
    }
    summary = {
        "command": f"{COMMAND} --evaluation-id {evaluation_id}",
        "evaluation_id": evaluation_id,
        "evaluator_source_sha256": file_sha256(Path(__file__).resolve()),
        "git_head": git_head,
        "owner_recording_required": False,
        "cases": {},
    }

    for name in ("hike-tech", "italian-dialogue"):
        case = cases[name]
        output = case_outputs[name]
        output.mkdir(parents=True)
        scores = score_text(
            case["fixture"] / "reference.segments.json",
            case["run"] / "merged/segments.json",
            case["fixture"] / "terms.json",
        )
        if name == "italian-dialogue":
            hypothesis_rttm = output / "hypothesis.rttm"
            timeline_to_rttm(
                case["run"] / "diarization/timeline.json", hypothesis_rttm, "italian-dialogue"
            )
            scores["diarization"] = diarization_error_rate(
                read_rttm(case["fixture"] / "reference.rttm"),
                read_rttm(hypothesis_rttm),
            )
            backchannels = backchannel_analysis(
                case["fixture"], case["run"] / "primary/segments.json", load_json(case["run"] / "manifest.json")["run_id"]
            )
            write_json_create(output / "backchannel-preservation.json", backchannels)
        write_json_create(output / "scores.json", scores)
        baseline = load_json(case["baseline"])
        comparisons = strict_comparison(
            scores,
            baseline,
            [
                ("cer.error_rate", "lower"),
                ("wer.error_rate", "lower"),
                ("terms.term_recall", "higher"),
                ("omissions.omitted_utterances", "lower"),
            ],
        )
        if name == "italian-dialogue":
            diarization_baseline = load_json(case["diarization_baseline"])
            comparisons.extend(
                strict_comparison(
                    scores,
                    diarization_baseline,
                    [("diarization.der", "lower")],
                )
            )
            comparisons.append(
                {
                    "baseline": 7,
                    "current": backchannels["preserved_count"],
                    "delta": backchannels["preserved_count"] - 7,
                    "direction": "higher",
                    "metric": "backchannels.preserved_count",
                    "passed": backchannels["preserved_count"] >= 7,
                }
            )
        integrity = verify_run(
            case["run"],
            case["fixture"] / "input.wav",
            case["fixture"] / "glossary.txt",
        )
        evaluation = {
            "comparison": comparisons,
            "integrity": integrity,
            "passed": all(item["passed"] for item in comparisons)
            and integrity["passed"],
            "scores_sha256": file_sha256(output / "scores.json"),
        }
        write_json_create(output / "evaluation.json", evaluation)
        evaluation["artifact_sha256"] = output_artifact_hashes(output)
        summary["cases"][name] = evaluation

    name = "voxconverse-ppgjx-78m"
    case = cases[name]
    output = case_outputs[name]
    output.mkdir(parents=True)
    hypothesis_rttm = output / "hypothesis.rttm"
    timeline_to_rttm(case["run"] / "diarization/timeline.json", hypothesis_rttm, "ppgjx")
    scores = {
        "diarization": diarization_error_rate(
            read_rttm(case["fixture"] / "reference.rttm"), read_rttm(hypothesis_rttm)
        )
    }
    write_json_create(output / "scores.json", scores)
    boundary = boundary_analysis(
        case["fixture"] / "reference.rttm",
        hypothesis_rttm,
        scores["diarization"]["mapping"]["ppgjx"],
        load_json(case["run"] / "manifest.json")["run_id"],
    )
    repeat = repeat_consistency(
        case["fixture"] / "reference.rttm",
        hypothesis_rttm,
        load_json(case["run"] / "manifest.json")["run_id"],
    )
    chunk_boundaries = chunk_boundary_analysis(
        case["run"], case["fixture"] / "reference.rttm", load_json(case["run"] / "manifest.json")["run_id"]
    )
    physical_chunks = physical_chunk_audit(case["run"])
    write_json_create(output / "boundary-analysis.json", boundary)
    write_json_create(output / "repeat-consistency.json", repeat)
    write_json_create(output / "chunk-boundary-analysis.json", chunk_boundaries)
    write_json_create(output / "physical-chunks.json", physical_chunks)

    baseline_scores = load_json(case["baseline_root"] / "scores.json")
    baseline_boundary = load_json(case["baseline_root"] / "boundary-analysis.json")
    baseline_repeat = load_json(case["baseline_root"] / "repeat-consistency.json")
    comparisons = strict_comparison(
        scores,
        baseline_scores,
        [("diarization.der", "lower")],
    )
    current_speakers = scores["diarization"]["speaker_counts"]["ppgjx"]["hypothesis"]
    baseline_speakers = baseline_scores["diarization"]["speaker_counts"]["ppgjx"]["hypothesis"]
    comparisons.extend(
        [
            {
                "baseline": baseline_speakers,
                "current": current_speakers,
                "delta": current_speakers - baseline_speakers,
                "direction": "lower",
                "metric": "diarization.hypothesis_speakers",
                "passed": current_speakers <= baseline_speakers,
            },
            {
                "baseline": baseline_boundary["mean_absolute_error_s"],
                "current": boundary["mean_absolute_error_s"],
                "delta": boundary["mean_absolute_error_s"] - baseline_boundary["mean_absolute_error_s"],
                "direction": "lower",
                "metric": "boundary.mean_absolute_error_s",
                "passed": boundary["mean_absolute_error_s"] <= baseline_boundary["mean_absolute_error_s"],
            },
            {
                "baseline": baseline_boundary["p95_absolute_error_s"],
                "current": boundary["p95_absolute_error_s"],
                "delta": boundary["p95_absolute_error_s"] - baseline_boundary["p95_absolute_error_s"],
                "direction": "lower",
                "metric": "boundary.p95_absolute_error_s",
                "passed": boundary["p95_absolute_error_s"] <= baseline_boundary["p95_absolute_error_s"],
            },
            {
                "baseline": baseline_boundary["within_0_25_s_fraction"],
                "current": boundary["within_0_25_s_fraction"],
                "delta": boundary["within_0_25_s_fraction"] - baseline_boundary["within_0_25_s_fraction"],
                "direction": "higher",
                "metric": "boundary.within_0_25_s_fraction",
                "passed": boundary["within_0_25_s_fraction"] >= baseline_boundary["within_0_25_s_fraction"],
            },
        ]
    )
    for speaker in sorted(repeat["speakers"]):
        comparisons.append(
            {
                "baseline": baseline_repeat["speakers"][speaker]["stability"],
                "current": repeat["speakers"][speaker]["stability"],
                "delta": repeat["speakers"][speaker]["stability"] - baseline_repeat["speakers"][speaker]["stability"],
                "direction": "higher",
                "metric": f"repeat.{speaker}.stability",
                "passed": repeat["speakers"][speaker]["stability"] >= baseline_repeat["speakers"][speaker]["stability"],
            }
        )
    integrity = verify_run(case["run"], case["fixture"] / "input.wav", None)
    evaluation = {
        "comparison": comparisons,
        "integrity": integrity,
        "passed": all(item["passed"] for item in comparisons)
        and integrity["passed"]
        and chunk_boundaries["all_global_boundaries_consistent"]
        and chunk_boundaries["contradictory_merged_boundaries"] == 0
        and physical_chunks["all_contiguous"]
        and physical_chunks["all_duration_matches"]
        and physical_chunks["all_pcm16_mono_16000"]
        and physical_chunks["all_under_1200_s"],
        "scores_sha256": file_sha256(output / "scores.json"),
    }
    write_json_create(output / "evaluation.json", evaluation)
    evaluation["artifact_sha256"] = output_artifact_hashes(output)
    summary["cases"][name] = evaluation
    owner_run = e2e.parent / "moss-owner-local" / OWNER_RUN_ID
    summary["owner_recording"] = optional_owner_recording(owner_run)
    summary["strict_no_regression"] = public_strict_no_regression(summary["cases"])
    summary["passed"] = public_evaluation_passed(summary["cases"])
    write_json_create(summary_path, summary)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
