#!/usr/bin/env python3
"""Create deterministic RTTM ground truth from the VoxConverse Parquet labels.

The input Parquet remains untouched. Existing derived RTTM files are accepted
only when byte-identical to this export; a mismatching file is an error.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import pyarrow.parquet as pq


def rttm_text(recording_id: str, starts: list[float], ends: list[float], speakers: list[str]) -> str:
    if not starts or len(starts) != len(ends) or len(starts) != len(speakers):
        raise ValueError(f"{recording_id}: invalid timestamp/speaker parallel arrays")
    lines = []
    for start, end, speaker in zip(starts, ends, speakers, strict=True):
        if end <= start:
            raise ValueError(f"{recording_id}: non-positive duration {start}..{end}")
        lines.append(
            f"SPEAKER {recording_id} 1 {start:.3f} {end - start:.3f} <NA> <NA> {speaker} <NA> <NA>"
        )
    return "\n".join(lines) + "\n"


def write_if_identical_or_absent(path: Path, content: bytes) -> None:
    if path.exists():
        if path.read_bytes() != content:
            raise FileExistsError(f"refusing to overwrite non-identical derived RTTM: {path}")
        return
    path.write_bytes(content)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    table = pq.read_table(args.source, columns=["audio", "timestamps_start", "timestamps_end", "speakers"])
    args.output_dir.mkdir(parents=True, exist_ok=True)
    created_or_verified = 0
    recording_ids: set[str] = set()
    for audio, starts, ends, speakers in zip(
        table["audio"].to_pylist(),
        table["timestamps_start"].to_pylist(),
        table["timestamps_end"].to_pylist(),
        table["speakers"].to_pylist(),
        strict=True,
    ):
        recording_id = Path(audio["path"]).stem
        if recording_id in recording_ids:
            raise ValueError(f"duplicate recording ID: {recording_id}")
        recording_ids.add(recording_id)
        content = rttm_text(recording_id, starts, ends, speakers).encode("utf-8")
        write_if_identical_or_absent(args.output_dir / f"{recording_id}.rttm", content)
        created_or_verified += 1
    print(f"RTTM ready: {created_or_verified} files in {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
