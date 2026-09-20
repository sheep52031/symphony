from __future__ import annotations

from contextlib import redirect_stderr
from io import StringIO
import json
import sys
import tempfile
import unittest
from pathlib import Path

SPIKE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SPIKE))

from capture_runner import (
    CaptureError,
    fake_prompts,
    main,
    redact_text,
    run_capture,
    validate_capture_dir,
    validate_summary,
)


FAKE = SPIKE / "fixtures" / "fake_agy.py"


class CaptureRunnerTest(unittest.TestCase):
    def command(self, scenario: str) -> list[str]:
        return [sys.executable, str(FAKE), scenario]

    def test_offline_multiturn_capture_records_raw_envelopes_and_redacted_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = run_capture(
                self.command("interactive-multi-turn"),
                mode="fake",
                workspace=root / "workspace",
                capture_dir=root / "capture",
                prompts=fake_prompts(),
                repository_root=root / "repository",
            )
            self.assertEqual(summary["version"], "fixture-offline")
            self.assertEqual(summary["session"]["init_events"], 1)
            self.assertEqual(summary["session"]["terminal_statuses"], ["SUCCESS", "SUCCESS"])
            self.assertTrue(summary["session"]["stable_identity"])
            self.assertEqual(summary["session"]["distinct_identities"], 1)
            self.assertRegex(summary["session"]["redacted_identities"][0], r"^sha256:[0-9a-f]{16}$")
            self.assertTrue(summary["containment"]["sentinel_unchanged"])
            self.assertTrue(summary["containment"]["native_cwd_exposed"])
            self.assertTrue(summary["lifecycle"]["process_group_empty"])
            rendered = json.dumps(summary)
            self.assertNotIn("fixture alpha", rendered)
            self.assertNotIn(str(root), rendered)
            for name in ("raw-stdin.jsonl", "raw-stdout.jsonl", "raw-stderr.jsonl", "raw-manifest.json", "redacted-summary.json"):
                self.assertTrue((root / "capture" / name).is_file())
            manifest = json.loads((root / "capture" / "raw-manifest.json").read_text())
            self.assertEqual(manifest["command"], self.command("interactive-multi-turn"))
            self.assertEqual(manifest["version"], "fixture-offline")
            self.assertEqual(manifest["cwd"], str(root / "workspace"))

    def test_bounded_sigint_term_kill_escalation_reaps_ignoring_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = run_capture(
                self.command("ignore-signals"),
                mode="fake",
                workspace=root / "workspace",
                capture_dir=root / "capture",
                prompts=fake_prompts()[:1],
                turn_timeout=0.05,
                close_grace=0.02,
                signal_grace=0.02,
                repository_root=root / "repository",
            )
            self.assertEqual(summary["lifecycle"]["signals_sent"], ["SIGINT", "SIGTERM", "SIGKILL"])
            self.assertTrue(summary["lifecycle"]["process_group_empty"])
            self.assertNotEqual(summary["lifecycle"]["returncode"], 0)

    def test_redaction_is_deterministic_for_paths_and_credential_values(self):
        source = "token=" + "unit-only /" + "home" + "/owner/.agy-profiles/acc1 C:" + "\\" + "Users" + "\\owner\\key"
        expected = "token=<REDACTED> <REDACTED_PATH> <REDACTED_PATH>"
        self.assertEqual(redact_text(source), expected)
        self.assertEqual(redact_text(source), expected)

    def test_live_mode_requires_a_separate_owner_authorization_before_launch(self):
        stderr = StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as exited:
            main(["--mode", "live"])
        self.assertEqual(exited.exception.code, 2)
        self.assertIn("live-authorization", stderr.getvalue())

    def test_capture_directory_must_be_ignored_subtree_when_inside_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(validate_capture_dir(root / ".agy-captures" / "one", root), (root / ".agy-captures" / "one").resolve())
            with self.assertRaisesRegex(CaptureError, "must be under"):
                validate_capture_dir(root / "evidence", root)

    def test_summary_schema_rejects_missing_or_leaking_invariants(self):
        with self.assertRaisesRegex(CaptureError, "schema"):
            validate_summary({})


if __name__ == "__main__":
    unittest.main()
