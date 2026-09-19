from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

SPIKE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SPIKE))

from probe import ProbeError, require_contained_workspace, require_same_host, run_fixture


FAKE = SPIKE / "fixtures" / "fake_agy.py"


class AgyHeadlessProbeTest(unittest.TestCase):
    def run_scenario(self, scenario: str, **limits: float):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "root" / "issue"
            workspace.mkdir(parents=True)
            return run_fixture(
                [sys.executable, str(FAKE), scenario],
                cwd=workspace,
                first_token_timeout=limits.pop("first_token_timeout", 0.2),
                turn_timeout=limits.pop("turn_timeout", 0.4),
                **limits,
            )

    def terminal(self, result):
        return [event["result"] for event in result.events if event.get("event") == "result"]

    def session_ids(self, result):
        return {
            event.get("conversation_id")
            or event.get("step_update", {}).get("conversation_id")
            or event.get("result", {}).get("conversation_id")
            for event in result.events
        }

    def test_partial_crlf_malformed_stdout_and_stderr_are_separated(self):
        result = self.run_scenario("partial-crlf")

        self.assertEqual(result.returncode, 0)
        self.assertIsNone(result.timed_out)
        self.assertIsNone(result.exit_outcome)
        self.assertEqual([event["event"] for event in result.events], ["init", "step_update", "result"])
        self.assertEqual(result.events[1]["step_update"]["text_delta"], "hel")
        self.assertEqual(result.malformed_stdout, ['{"event":'])
        self.assertEqual(result.stderr_lines, ["fixture diagnostic"])

    def test_nonzero_error_keeps_terminal_envelope_and_diagnostics(self):
        result = self.run_scenario("nonzero-error")

        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.terminal(result)[0]["status"], "ERROR")
        self.assertEqual(result.stderr_lines, ["fixture error diagnostic"])

    def test_two_result_transcript_keeps_opaque_identity_and_cumulative_usage(self):
        result = self.run_scenario("two-result-transcript")
        terminals = self.terminal(result)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.session_ids(result), {"fixture-conversation-001"})
        self.assertEqual([event["num_turns"] for event in terminals], [1, 2])
        self.assertEqual(terminals[-1]["usage"]["total_tokens"], 13)

    def test_waiting_result_is_a_visible_input_or_permission_outcome(self):
        result = self.run_scenario("permission-waiting")

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.terminal(result)[0]["status"], "WAITING")
        self.assertEqual(result.stderr_lines, ["permission notice: request review"])

    def test_stdout_chatter_cannot_extend_the_absolute_first_token_deadline(self):
        result = self.run_scenario("chatter", first_token_timeout=0.12, turn_timeout=0.3)

        self.assertEqual(result.timed_out, "first-token")
        self.assertEqual(self.terminal(result), [])
        self.assertGreater(len(result.malformed_stdout), 1)

    def test_first_token_without_completion_hits_the_absolute_turn_deadline(self):
        result = self.run_scenario("first-token-stall", first_token_timeout=0.12, turn_timeout=0.2)

        self.assertEqual(result.timed_out, "turn")
        self.assertEqual(self.terminal(result), [])

    def test_result_then_hang_hits_bounded_post_result_exit_grace(self):
        result = self.run_scenario("result-then-hang", post_result_exit_grace=0.08)

        self.assertEqual(self.terminal(result)[0]["status"], "SUCCESS")
        self.assertEqual(result.exit_outcome, "post-result-exit")
        self.assertIsNone(result.timed_out)
        self.assertIsNotNone(result.returncode)

    def test_exited_parent_with_inherited_pipe_is_reaped_by_retained_tree_lifetime(self):
        result = self.run_scenario("exited-parent-pipe-holder", post_result_exit_grace=0.08)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.terminal(result)[0]["response"], "parent exited")
        self.assertEqual(result.exit_outcome, "post-result-exit")

    def test_interrupt_race_retains_canceled_terminal_event_without_post_result_classification(self):
        result = self.run_scenario("cancel-race", cancel_after=0.08, turn_timeout=0.5)

        self.assertTrue(result.interrupted)
        self.assertIsNone(result.timed_out)
        self.assertIsNone(result.exit_outcome)
        self.assertEqual(self.terminal(result)[0]["status"], "CANCELED")

    def test_process_loss_is_classifiable_when_no_terminal_event_arrives(self):
        result = self.run_scenario("process-loss")

        self.assertEqual(result.returncode, 17)
        self.assertEqual(self.terminal(result), [])

    def test_high_volume_output_is_backpressured_and_retained_evidence_is_capped(self):
        result = self.run_scenario(
            "high-volume",
            read_chunk_bytes=16,
            max_queue_chunks=2,
            max_events=4,
            max_malformed_stdout=3,
            max_stderr_lines=3,
        )

        self.assertEqual(result.returncode, 0)
        self.assertLessEqual(len(result.events), 4)
        self.assertEqual(self.terminal(result)[0]["status"], "SUCCESS")
        self.assertLessEqual(len(result.malformed_stdout), 3)
        self.assertLessEqual(len(result.stderr_lines), 3)
        self.assertGreater(result.dropped_events, 0)
        self.assertGreater(result.dropped_malformed_stdout, 0)
        self.assertGreater(result.dropped_stderr_lines, 0)

    def test_oversized_frames_are_discarded_to_lf_and_later_result_resynchronizes(self):
        result = self.run_scenario("oversized-output", read_chunk_bytes=31, max_frame_bytes=512)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.truncated_stdout_frames, 1)
        self.assertEqual(result.truncated_stderr_frames, 1)
        self.assertEqual(self.terminal(result)[0]["response"], "after oversized frames")
        self.assertEqual(result.malformed_stdout, [])
        self.assertEqual(result.stderr_lines, [])

    def test_workspace_is_contained_and_child_observes_that_cwd(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            workspace = root / "issue"
            workspace.mkdir(parents=True)
            self.assertEqual(require_contained_workspace(root, workspace), workspace.resolve())
            with self.assertRaisesRegex(ProbeError, "escapes"):
                require_contained_workspace(root, root.parent / "outside")

            result = run_fixture(
                [sys.executable, str(FAKE), "cwd"],
                cwd=workspace,
                first_token_timeout=0.2,
                turn_timeout=0.4,
            )
            self.assertEqual(Path(result.events[0]["init"]["cwd"]).resolve(), workspace.resolve())

    def test_cross_host_launcher_is_rejected_before_launch(self):
        require_same_host("windows", "windows")
        with self.assertRaisesRegex(ProbeError, "cannot launch"):
            require_same_host("wsl", "windows")


if __name__ == "__main__":
    unittest.main()
