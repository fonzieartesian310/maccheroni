from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Iterable, Sequence


@dataclass(frozen=True)
class Turn:
    file_id: str
    start_s: float
    end_s: float
    speaker: str


@dataclass(frozen=True)
class Region:
    file_id: str
    start_s: float
    end_s: float


def read_rttm(path: str | Path) -> list[Turn]:
    turns: list[Turn] = []
    for line_number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            raise ValueError(f"{path}:{line_number}: expected RTTM SPEAKER row")
        start = float(fields[3])
        duration = float(fields[4])
        if start < 0 or duration <= 0:
            raise ValueError(f"{path}:{line_number}: invalid start or duration")
        turns.append(Turn(fields[1], start, start + duration, fields[7]))
    return turns


def read_uem(path: str | Path) -> list[Region]:
    regions: list[Region] = []
    for line_number, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) != 4:
            raise ValueError(f"{path}:{line_number}: expected four UEM fields")
        start = float(fields[2])
        end = float(fields[3])
        if start < 0 or end <= start:
            raise ValueError(f"{path}:{line_number}: invalid UEM region")
        regions.append(Region(fields[0], start, end))
    return regions


def _active(turns: Sequence[Turn], time_s: float) -> set[str]:
    return {
        turn.speaker
        for turn in turns
        if turn.start_s <= time_s < turn.end_s
    }


def _inside_any(regions: Sequence[Region], time_s: float) -> bool:
    return any(region.start_s <= time_s < region.end_s for region in regions)


def _optimal_mapping(overlap: dict[tuple[str, str], float]) -> dict[str, str]:
    reference_speakers = sorted({pair[0] for pair in overlap})
    hypothesis_speakers = sorted({pair[1] for pair in overlap})
    if len(reference_speakers) > 16:
        raise ValueError("exact DER mapping supports at most 16 reference speakers")

    @lru_cache(maxsize=None)
    def solve(hypothesis_index: int, used_reference_mask: int) -> tuple[float, tuple[int, ...]]:
        if hypothesis_index == len(hypothesis_speakers):
            return 0.0, ()

        best_score, best_assignment = solve(hypothesis_index + 1, used_reference_mask)
        best_assignment = (-1,) + best_assignment
        hypothesis = hypothesis_speakers[hypothesis_index]
        for reference_index, reference in enumerate(reference_speakers):
            bit = 1 << reference_index
            if used_reference_mask & bit:
                continue
            downstream_score, downstream_assignment = solve(
                hypothesis_index + 1,
                used_reference_mask | bit,
            )
            candidate_score = overlap.get((reference, hypothesis), 0.0) + downstream_score
            candidate_assignment = (reference_index,) + downstream_assignment
            if candidate_score > best_score or (
                candidate_score == best_score and candidate_assignment < best_assignment
            ):
                best_score = candidate_score
                best_assignment = candidate_assignment
        return best_score, best_assignment

    _, assignment = solve(0, 0)
    return {
        hypothesis_speakers[index]: reference_speakers[reference_index]
        for index, reference_index in enumerate(assignment)
        if reference_index >= 0
    }


def diarization_error_rate(
    reference_turns: Sequence[Turn],
    hypothesis_turns: Sequence[Turn],
    *,
    uem_regions: Sequence[Region] | None = None,
    collar_s: float = 0.25,
    skip_overlap: bool = True,
) -> dict[str, object]:
    if collar_s < 0:
        raise ValueError("collar_s must be non-negative")
    files = sorted({turn.file_id for turn in reference_turns})
    totals = {
        "miss_s": 0.0,
        "false_alarm_s": 0.0,
        "confusion_s": 0.0,
        "reference_speaker_s": 0.0,
    }
    mappings: dict[str, dict[str, str]] = {}
    speaker_counts: dict[str, dict[str, int | bool]] = {}

    for file_id in files:
        references = [turn for turn in reference_turns if turn.file_id == file_id]
        hypotheses = [turn for turn in hypothesis_turns if turn.file_id == file_id]
        if uem_regions is None:
            domains = [
                Region(
                    file_id,
                    min(turn.start_s for turn in references),
                    max(turn.end_s for turn in references),
                )
            ]
        else:
            domains = [region for region in uem_regions if region.file_id == file_id]
            if not domains:
                continue

        half_collar = collar_s / 2
        exclusions = [
            (max(0.0, boundary - half_collar), boundary + half_collar)
            for turn in references
            for boundary in (turn.start_s, turn.end_s)
            if collar_s > 0
        ]
        points = {
            point
            for region in domains
            for point in (region.start_s, region.end_s)
        }
        points.update(point for turn in references + hypotheses for point in (turn.start_s, turn.end_s))
        points.update(point for exclusion in exclusions for point in exclusion)
        ordered = sorted(points)

        elementary: list[tuple[float, set[str], set[str]]] = []
        overlap: dict[tuple[str, str], float] = {}
        for start, end in zip(ordered, ordered[1:]):
            if end <= start:
                continue
            midpoint = (start + end) / 2
            if not _inside_any(domains, midpoint):
                continue
            if any(exclusion_start <= midpoint < exclusion_end for exclusion_start, exclusion_end in exclusions):
                continue
            active_reference = _active(references, midpoint)
            active_hypothesis = _active(hypotheses, midpoint)
            if skip_overlap and len(active_reference) > 1:
                continue
            duration = end - start
            elementary.append((duration, active_reference, active_hypothesis))
            for reference in active_reference:
                for hypothesis in active_hypothesis:
                    overlap[(reference, hypothesis)] = overlap.get((reference, hypothesis), 0.0) + duration

        mapping = _optimal_mapping(overlap)
        mappings[file_id] = mapping
        reference_speaker_count = len({turn.speaker for turn in references})
        hypothesis_speaker_count = len({turn.speaker for turn in hypotheses})
        speaker_counts[file_id] = {
            "reference": reference_speaker_count,
            "hypothesis": hypothesis_speaker_count,
            "exact": reference_speaker_count == hypothesis_speaker_count,
        }
        for duration, active_reference, active_hypothesis in elementary:
            correct = sum(
                1
                for hypothesis in active_hypothesis
                if mapping.get(hypothesis) in active_reference
            )
            totals["miss_s"] += max(0, len(active_reference) - len(active_hypothesis)) * duration
            totals["false_alarm_s"] += max(0, len(active_hypothesis) - len(active_reference)) * duration
            totals["confusion_s"] += (
                min(len(active_reference), len(active_hypothesis)) - correct
            ) * duration
            totals["reference_speaker_s"] += len(active_reference) * duration

    numerator = totals["miss_s"] + totals["false_alarm_s"] + totals["confusion_s"]
    denominator = totals["reference_speaker_s"]
    return {
        **totals,
        "der": numerator / denominator if denominator else None,
        "collar_s": collar_s,
        "skip_overlap": skip_overlap,
        "speaker_count_exact": all(counts["exact"] for counts in speaker_counts.values()),
        "speaker_counts": speaker_counts,
        "mapping": mappings,
    }
