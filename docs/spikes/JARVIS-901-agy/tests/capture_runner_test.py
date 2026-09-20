from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

SPIKE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SPIKE))
from capture_runner import CaptureError, fake_prompts, redact_text, run_capture

FAKE = SPIKE / "fixtures" / "fake_agy.py"

class CaptureRunnerTest(unittest.TestCase):
    def test_shared_probe_capture_preserves_exact_raw_bytes_and_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "capture"
            prompts = fake_prompts()
            summary = run_capture([sys.executable, str(FAKE), "interactive-multi-turn"], mode="fake", capture_dir=run, workspace=run / "workspace", prompts=prompts, repository_root=Path(temporary) / "repo")
            self.assertEqual((run / "raw-stdin.bin").read_bytes(), b"".join(prompts))
            self.assertEqual(summary["session"]["init_events"], 1)
            self.assertTrue(summary["session"]["stable_identity"])
            self.assertTrue(summary["containment"]["cwd_match"])
            self.assertEqual(summary["raw"]["stdin"]["sha256"], hashlib.sha256(b"".join(prompts)).hexdigest())
            self.assertEqual(json.loads((run / "raw-manifest.json").read_text())["raw"]["stdin"]["bytes"], len(b"".join(prompts)))

    def test_exited_parent_pipe_holder_is_reaped_by_shared_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "capture"
            summary = run_capture([sys.executable, str(FAKE), "exited-parent-pipe-holder"], mode="fake", capture_dir=run, workspace=run / "workspace", prompts=(), repository_root=Path(temporary) / "repo")
            self.assertEqual(summary["lifecycle"]["exit_outcome"], "post-result-exit")

    def test_workspace_and_prompt_bounds_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "capture"; run.mkdir(); (run / "workspace").mkdir()
            with self.assertRaises(CaptureError):
                run_capture([sys.executable, str(FAKE), "cwd"], mode="fake", capture_dir=run, workspace=run / "workspace", prompts=(), repository_root=Path(temporary) / "repo")

    def test_redaction_is_deterministic(self):
        value = "token=" + "unit /" + "home" + "/owner/x"
        self.assertEqual(redact_text(value), "token=<REDACTED> <REDACTED_PATH>")

if __name__ == "__main__": unittest.main()
