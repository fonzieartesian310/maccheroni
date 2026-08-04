#!/usr/bin/env python3
"""Create an exact ten-second PCM WAV without retaining any source audio."""

import pathlib
import sys
import wave

if len(sys.argv) != 3:
    raise SystemExit(f"usage: {sys.argv[0]} <input-wav> <output-wav>")

source_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
target_rate = 16_000
target_frames = target_rate * 10

with wave.open(str(source_path), "rb") as source:
    if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, target_rate):
        raise SystemExit("expected afconvert output to be mono, 16-bit PCM, 16 kHz")
    frames = source.readframes(target_frames)

frames += b"\0" * (target_frames * 2 - len(frames))
with wave.open(str(output_path), "wb") as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(target_rate)
    output.writeframes(frames)

print(f"wrote {output_path}: {target_frames} frames at {target_rate} Hz (10.000 s)")
