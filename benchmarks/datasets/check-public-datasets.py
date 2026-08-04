#!/usr/bin/env python3
"""Read-only integrity and reference-format check for T1 public artifacts."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pyarrow.parquet as pq


FLEURS = {
    "ko_kr": (382, 48, "Korean"),
    "it_it": (865, 39, "Italian"),
    "en_us": (647, 19, "English"),
}


def require_columns(name: str, table: pq.ParquetFile, expected: set[str]) -> None:
    actual = set(table.schema_arrow.names)
    missing = sorted(expected - actual)
    if missing:
        raise ValueError(f"{name}: missing required columns: {', '.join(missing)}")


def check_fleurs(root: Path) -> None:
    for language, (expected_rows, expected_lang_id, expected_name) in FLEURS.items():
        path = root / "fleurs" / "parquet-data" / language / "test-00000-of-00001.parquet"
        parquet = pq.ParquetFile(path)
        require_columns(
            language,
            parquet,
            {"id", "audio", "transcription", "raw_transcription", "lang_id", "language"},
        )
        if parquet.metadata.num_rows != expected_rows:
            raise ValueError(f"{language}: expected {expected_rows} rows, got {parquet.metadata.num_rows}")
        metadata = pq.read_table(path, columns=["lang_id", "language"])
        language_ids = set(metadata["lang_id"].to_pylist())
        language_names = set(metadata["language"].to_pylist())
        if language_ids != {expected_lang_id} or language_names != {expected_name}:
            raise ValueError(
                f"{language}: unexpected labels: lang_id={language_ids}, language={language_names}"
            )
        print(f"FLEURS {language}: {parquet.metadata.num_rows} rows; ASR references present")


def check_hike(root: Path) -> None:
    path = root / "hike" / "data" / "test-00000-of-00001.parquet"
    parquet = pq.ParquetFile(path)
    require_columns(
        "HiKE",
        parquet,
        {
            "audio",
            "text",
            "text_normalized",
            "text_pier_labeled",
            "cs_level",
            "cs_levels_all",
            "category",
            "loanwords",
            "sample_id",
        },
    )
    if parquet.metadata.num_rows != 1121:
        raise ValueError(f"HiKE: expected 1121 rows, got {parquet.metadata.num_rows}")
    levels = set(pq.read_table(path, columns=["cs_level"])["cs_level"].to_pylist())
    if levels != {"word", "phrase", "sentence"}:
        raise ValueError(f"HiKE: unexpected code-switch levels: {levels}")
    print(f"HiKE: {parquet.metadata.num_rows} rows; ASR and code-switch references present")


def check_voxconverse(root: Path) -> None:
    path = root / "voxconverse" / "data" / "dev-00000-of-00005.parquet"
    parquet = pq.ParquetFile(path)
    require_columns("VoxConverse", parquet, {"audio", "timestamps_start", "timestamps_end", "speakers"})
    if parquet.metadata.num_rows != 44:
        raise ValueError(f"VoxConverse: expected 44 rows, got {parquet.metadata.num_rows}")
    timeline = pq.read_table(path, columns=["audio", "timestamps_start", "timestamps_end", "speakers"])
    segment_count = 0
    recording_ids: set[str] = set()
    for audio, starts, ends, speakers in zip(
        timeline["audio"].to_pylist(),
        timeline["timestamps_start"].to_pylist(),
        timeline["timestamps_end"].to_pylist(),
        timeline["speakers"].to_pylist(),
        strict=True,
    ):
        if not audio or not starts or len(starts) != len(ends) or len(starts) != len(speakers):
            raise ValueError("VoxConverse: invalid timestamp/speaker parallel arrays")
        recording_id = Path(audio["path"]).stem
        if recording_id in recording_ids:
            raise ValueError(f"VoxConverse: duplicate recording ID: {recording_id}")
        recording_ids.add(recording_id)
        rttm_path = root / "voxconverse" / "rttm" / f"{recording_id}.rttm"
        if not rttm_path.is_file():
            raise ValueError(f"VoxConverse: missing or invalid RTTM reference: {rttm_path}")
        rttm_lines = rttm_path.read_text(encoding="utf-8").splitlines()
        if len(rttm_lines) != len(speakers) or not all(
            line.startswith(f"SPEAKER {recording_id} ") for line in rttm_lines
        ):
            raise ValueError(f"VoxConverse: missing or invalid RTTM reference: {rttm_path}")
        segment_count += len(speakers)
    print(f"VoxConverse dev shard 0: {parquet.metadata.num_rows} clips; {segment_count} RTTM segments")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("benchmarks/samples/public"))
    args = parser.parse_args()
    try:
        check_fleurs(args.root)
        check_hike(args.root)
        check_voxconverse(args.root)
    except (FileNotFoundError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: all T1 public artifacts and reference formats are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
