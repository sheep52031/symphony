from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SPIKE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SPIKE))

from capture_runner import TRUSTED_SYSTEM_PATH, minimal_environment
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

    def test_stdin_turns_are_sequential_and_record_process_session_evidence(self):
        if os.name == "nt":
            self.skipTest("POSIX process-group evidence is covered in native WSL")
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "workspace"
            workspace.mkdir()
            prompts = [b'{"event":"user","message":{"content":"one"}}\n', b'{"event":"user","message":{"content":"two"}}\n']
            result = run_fixture(
                [sys.executable, str(FAKE), "interactive-multi-turn"],
                cwd=workspace,
                first_token_timeout=0.2,
                turn_timeout=0.5,
                stdin_lines=prompts,
                env={"PATH": os.environ.get("PATH", "")},
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.expected_turns, 2)
        self.assertEqual(result.completed_turns, 2)
        self.assertEqual(result.signals, [])
        self.assertTrue(result.process_group_empty)
        self.assertEqual(result.observed_bytes["stdin"], sum(map(len, prompts)))

    def test_preinit_step_is_rejected_before_identity_can_be_established(self):
        result = self.run_scenario("preinit-step")

        self.assertEqual(result.init_events, 1)
        self.assertEqual(result.completed_turns, 0)
        self.assertGreater(result.invalid_session_events, 0)

    def test_preinit_result_is_rejected_before_terminal_validation(self):
        result = self.run_scenario("preinit-result")

        self.assertEqual(result.init_events, 1)
        self.assertEqual(result.completed_turns, 0)
        self.assertGreater(result.invalid_session_events, 0)
        self.assertGreater(result.invalid_terminal_results, 0)

    def test_identityless_init_is_rejected(self):
        result = self.run_scenario("identityless-init")

        self.assertEqual(result.init_events, 1)
        self.assertEqual(result.completed_turns, 0)
        self.assertGreater(result.invalid_session_events, 0)

    def test_duplicate_init_is_rejected(self):
        result = self.run_scenario("duplicate-init")

        self.assertEqual(result.init_events, 2)
        self.assertEqual(result.completed_turns, 0)
        self.assertGreater(result.invalid_session_events, 0)

    def test_later_identity_mismatch_is_rejected(self):
        result = self.run_scenario("identity-mismatch")

        self.assertEqual(result.init_events, 1)
        self.assertEqual(result.completed_turns, 0)
        self.assertGreater(result.invalid_session_events, 0)
        self.assertGreater(result.invalid_terminal_results, 0)

    def test_malicious_earlier_user_path_helper_is_not_executed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            workspace.mkdir()
            malicious = root / "malicious"
            malicious.mkdir()
            marker = root / "executed"
            helper = malicious / "jarvis-901-path-helper"
            helper.write_text(f"#!/bin/sh\nprintf executed > {marker}\n")
            helper.chmod(0o700)
            environment, _ = minimal_environment({"PATH": str(malicious) + os.pathsep + TRUSTED_SYSTEM_PATH})
            result = run_fixture(
                [sys.executable, str(FAKE), "path-helper"],
                cwd=workspace,
                first_token_timeout=0.2,
                turn_timeout=0.4,
                env=environment,
            )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.terminal(result)[0]["response"], "trusted-path-not-user-helper")
        self.assertFalse(marker.exists())

    def test_child_receives_only_explicit_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "workspace"
            workspace.mkdir()
            with patch.dict(
                os.environ,
                {
                    "OPENAI_API_KEY": "token",
                    "HTTP_PROXY": "proxy",
                    "CLOUDSDK_AUTH_TOKEN": "cloud",
                    "LINEAR_API_KEY": "linear",
                    "GITHUB_TOKEN": "github",
                },
            ):
                environment, names = minimal_environment()
                result = run_fixture(
                    [sys.executable, str(FAKE), "environment"],
                    cwd=workspace,
                    first_token_timeout=0.2,
                    turn_timeout=0.4,
                    env=environment,
                )

        environment_names = json.loads(self.terminal(result)[0]["response"])
        self.assertTrue(set(environment_names).issubset(set(names) | {"LC_CTYPE"}))
        self.assertIn("PATH", environment_names)
        self.assertNotIn("OPENAI_API_KEY", environment_names)
        self.assertNotIn("HTTP_PROXY", environment_names)
        self.assertNotIn("LINEAR_API_KEY", environment_names)
        self.assertNotIn("GITHUB_TOKEN", environment_names)

    def test_parent_exit_with_term_ignoring_same_group_descendant_is_killed(self):
        if os.name == "nt":
            self.skipTest("POSIX process-group evidence is covered in native WSL")
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "workspace"
            workspace.mkdir()
            result = run_fixture(
                [sys.executable, str(FAKE), "parent-exits-term-ignoring-descendant"],
                cwd=workspace,
                first_token_timeout=0.2,
                turn_timeout=0.4,
                post_result_exit_grace=0.05,
                cleanup_grace=0.03,
            )
            descendant_pid = int((workspace / ".descendant.pid").read_text())
            self.assertEqual(result.signals, ["SIGTERM", "SIGKILL"])
            self.assertTrue(result.process_group_empty)
            with self.assertRaises(ProcessLookupError):
                os.kill(descendant_pid, 0)

    def test_cleanup_deadline_returns_on_group_never_empty_and_kill_failure(self):
        if os.name == "nt":
            self.skipTest("POSIX process-group deadline is covered in native WSL")
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "workspace"
            workspace.mkdir()
            started = time.monotonic()
            with patch("probe._TreeLifetime.process_group_empty", return_value=False), patch(
                "probe._TreeLifetime.send", side_effect=ProbeError("synthetic kill failure")
            ):
                result = run_fixture(
                    [sys.executable, str(FAKE), "result-then-hang"],
                    cwd=workspace,
                    first_token_timeout=0.2,
                    turn_timeout=0.4,
                    post_result_exit_grace=0.01,
                    cleanup_grace=0.03,
                )
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 1.0)
            self.assertFalse(result.process_group_empty)
            self.assertTrue(result.cleanup_failed)
            self.assertIsNotNone(result.pid)
            with self.assertRaises(ProcessLookupError):
                os.kill(result.pid, 0)

    def test_ignored_signal_path_escalates_and_empties_process_group(self):
        if os.name == "nt":
            self.skipTest("POSIX signal escalation is covered in native WSL")
        result = self.run_scenario(
            "ignore-signals",
            first_token_timeout=2.0,
            turn_timeout=2.5,
            cleanup_grace=0.03,
        )

        self.assertEqual(result.timed_out, "first-token")
        self.assertEqual(result.signals, ["SIGTERM", "SIGKILL"])
        self.assertTrue(result.process_group_empty)
        self.assertFalse(result.cleanup_failed)

    def test_two_result_transcript_keeps_opaque_identity_and_cumulative_usage(self):
        result = self.run_scenario("two-result-transcript")
        terminals = self.terminal(result)

        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.session_ids(result), {"fixture-conversation-001"})
        self.assertEqual([event["num_turns"] for event in terminals], [1, 2])
        self.assertEqual(terminals[-1]["usage"]["total_tokens"], 13)

    def test_duplicate_result_is_rejected(self):
        result = self.run_scenario("duplicate-result")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.completed_turns, 1)
        self.assertGreater(result.invalid_terminal_results, 0)

    def test_out_of_order_result_is_rejected(self):
        result = self.run_scenario("out-of-order-result")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.completed_turns, 0)
        self.assertGreater(result.invalid_terminal_results, 0)

    def test_non_cumulative_usage_is_rejected(self):
        result = self.run_scenario("noncumulative-usage")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.completed_turns, 1)
        self.assertGreater(result.invalid_terminal_results, 0)

    def test_malformed_usage_is_rejected(self):
        result = self.run_scenario("malformed-usage")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.completed_turns, 0)
        self.assertGreater(result.invalid_terminal_results, 0)

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
        result = self.run_scenario("cancel-race", cancel_after=1.0, turn_timeout=2.0)

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
