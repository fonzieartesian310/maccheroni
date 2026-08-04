from __future__ import annotations

import unittest

from rttm import Turn, diarization_error_rate


class DiarizationMetricTests(unittest.TestCase):
    def test_global_permutation_gives_zero_error(self) -> None:
        reference = [
            Turn("sample", 0.0, 2.0, "A"),
            Turn("sample", 2.0, 4.0, "B"),
        ]
        hypothesis = [
            Turn("sample", 0.0, 2.0, "speaker-9"),
            Turn("sample", 2.0, 4.0, "speaker-3"),
        ]
        result = diarization_error_rate(reference, hypothesis, collar_s=0.0)
        self.assertEqual(result["der"], 0.0)
        self.assertTrue(result["speaker_count_exact"])

    def test_single_hypothesis_speaker_causes_half_confusion(self) -> None:
        reference = [
            Turn("sample", 0.0, 2.0, "A"),
            Turn("sample", 2.0, 4.0, "B"),
        ]
        hypothesis = [Turn("sample", 0.0, 4.0, "speaker-1")]
        result = diarization_error_rate(reference, hypothesis, collar_s=0.0)
        self.assertAlmostEqual(result["confusion_s"], 2.0)
        self.assertAlmostEqual(result["der"], 0.5)
        self.assertFalse(result["speaker_count_exact"])

    def test_reference_overlap_is_skipped(self) -> None:
        reference = [
            Turn("sample", 0.0, 3.0, "A"),
            Turn("sample", 1.0, 2.0, "B"),
        ]
        hypothesis = [Turn("sample", 0.0, 3.0, "speaker-1")]
        result = diarization_error_rate(
            reference,
            hypothesis,
            collar_s=0.0,
            skip_overlap=True,
        )
        self.assertEqual(result["der"], 0.0)


if __name__ == "__main__":
    unittest.main()
