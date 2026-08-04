"""Pin the abort/continue meaning of the MOSS long-audio runner gate.

The runner is immutable evidence-producing code, so this test never edits it:
it extracts the gate clause verbatim from the script, wraps it in a `run_case`
stub under the same `set -euo pipefail` shell, and drives it with the four
inputs the gate reads. A restructured gate makes the extraction assertions fail
instead of silently making this test vacuous.
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


RUNNERS = Path(__file__).resolve().parents[1]
SCRIPT = RUNNERS / "run_moss_long_audio_eval.sh"
GATE_FIRST_LINE = "if [[ ${input_sha_before} != ${input_sha_after} ]]; then"
HARNESS = """#!/bin/zsh
set -euo pipefail

evaluation_root=$1

run_case() {{
  local identifier=$1
  local command_status=$2
  local input_sha_before=$3
  local input_sha_after=$4
{gate}
}}

run_case "$2" "$3" "$4" "$5"
print "CONTINUED"
"""


class MOSSLongAudioEvalGateTests(unittest.TestCase):
    def setUp(self) -> None:
        lines = SCRIPT.read_text(encoding="utf-8").splitlines()
        starts = [
            index for index, line in enumerate(lines) if line.strip() == GATE_FIRST_LINE
        ]
        self.assertEqual(len(starts), 1, "the runner gate no longer starts uniquely")
        start = starts[0]
        ends = [index for index in range(start, len(lines)) if lines[index] == "}"]
        self.assertTrue(ends, "the run_case body is not closed after the gate")
        self.gate = "\n".join(lines[start : ends[0]])

    def run_gate(
        self,
        identifier: str,
        command_status: int,
        *,
        before: str = "a" * 64,
        after: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            harness = Path(temporary) / "gate.zsh"
            harness.write_text(HARNESS.format(gate=self.gate), encoding="utf-8")
            return subprocess.run(
                [
                    "/bin/zsh",
                    str(harness),
                    temporary,
                    identifier,
                    str(command_status),
                    before,
                    before if after is None else after,
                ],
                capture_output=True,
                text=True,
            )

    def test_extracted_gate_still_carries_its_two_decisions(self) -> None:
        self.assertIn("warmup", self.gate)
        self.assertIn("forced-recovery-240-1024", self.gate)
        self.assertIn("command_status != 0", self.gate)
        self.assertIn("return ${command_status}", self.gate)
        self.assertIn("return 1", self.gate)

    def test_a_failed_warmup_stops_the_matrix_immediately(self) -> None:
        result = self.run_gate("warmup", 3)
        self.assertEqual(result.returncode, 3)
        self.assertNotIn("CONTINUED", result.stdout)
        self.assertIn("warmup exited 3", result.stderr)

    def test_a_failed_candidate_is_preserved_and_the_matrix_continues(self) -> None:
        for identifier in ("candidate-120", "candidate-240", "candidate-300"):
            with self.subTest(identifier=identifier):
                result = self.run_gate(identifier, 1)
                self.assertEqual(result.returncode, 0)
                self.assertIn("CONTINUED", result.stdout)
                self.assertEqual(result.stderr, "")

    def test_a_failed_forced_recovery_stops_the_matrix(self) -> None:
        result = self.run_gate("forced-recovery-240-1024", 1)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("CONTINUED", result.stdout)
        self.assertIn("forced-recovery-240-1024 exited 1", result.stderr)

    def test_successful_cases_always_continue(self) -> None:
        for identifier in ("warmup", "candidate-120", "forced-recovery-240-1024"):
            with self.subTest(identifier=identifier):
                result = self.run_gate(identifier, 0)
                self.assertEqual(result.returncode, 0)
                self.assertIn("CONTINUED", result.stdout)

    def test_a_changed_input_stops_every_case_before_the_exit_code_rule(self) -> None:
        for identifier in ("warmup", "candidate-240", "forced-recovery-240-1024"):
            with self.subTest(identifier=identifier):
                result = self.run_gate(identifier, 0, after="b" * 64)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("CONTINUED", result.stdout)
                self.assertIn(f"{identifier} changed its input", result.stderr)


if __name__ == "__main__":
    unittest.main()
