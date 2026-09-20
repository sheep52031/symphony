from __future__ import annotations

import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SPIKE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SPIKE))
from capture_runner import (
    CaptureError,
    _summary,
    capture_exit_code,
    fake_prompts,
    APPROVED_WRAPPER_SOURCE_SHA256,
    TRUSTED_SYSTEM_PATH,
    minimal_environment,
    redact_text,
    run_capture,
)
from probe import RunResult

FAKE = SPIKE / "fixtures" / "fake_agy.py"


class CaptureRunnerTest(unittest.TestCase):
    def make_clean_repo(self, root: Path) -> Path:
        root.mkdir()
        (root / "tracked.txt").write_text("tracked\n")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "JARVIS-901 tests"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "jarvis-901-tests@example.invalid"], cwd=root, check=True)
        subprocess.run(["git", "add", "tracked.txt"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture repository"], cwd=root, check=True)
        return root

    def run_fake_capture(self, root: Path, prompts: list[bytes] | tuple[bytes, ...] = ()) -> dict:
        repository = self.make_clean_repo(root / "repo")
        run = root / "capture"
        return run_capture(
            [sys.executable, str(FAKE), "interactive-multi-turn"],
            mode="fake",
            capture_dir=run,
            workspace=run / "workspace",
            prompts=prompts,
            repository_root=repository,
        )

    def test_shared_probe_capture_preserves_exact_raw_bytes_and_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "capture"
            prompts = fake_prompts()
            repository = self.make_clean_repo(Path(temporary) / "repo")
            summary = run_capture([sys.executable, str(FAKE), "interactive-multi-turn"], mode="fake", capture_dir=run, workspace=run / "workspace", prompts=prompts, repository_root=repository)
            self.assertEqual((run / "raw-stdin.bin").read_bytes(), b"".join(prompts))
            self.assertEqual(summary["session"]["init_events"], 1)
            self.assertTrue(summary["session"]["stable_identity"])
            self.assertTrue(summary["containment"]["cwd_match"])
            self.assertEqual(summary["provenance"]["code_before"], summary["provenance"]["code_after"])
            self.assertEqual(summary["provenance"]["git_head"], summary["provenance"]["git_before"]["head"])
            self.assertEqual(summary["provenance"]["trusted_path_policy"]["value"], TRUSTED_SYSTEM_PATH)
            self.assertEqual(summary["raw"]["stdin"]["sha256"], hashlib.sha256(b"".join(prompts)).hexdigest())
            self.assertEqual(json.loads((run / "raw-manifest.json").read_text())["raw"]["stdin"]["bytes"], len(b"".join(prompts)))

    def test_exited_parent_pipe_holder_is_reaped_by_shared_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "capture"
            repository = self.make_clean_repo(Path(temporary) / "repo")
            summary = run_capture([sys.executable, str(FAKE), "exited-parent-pipe-holder"], mode="fake", capture_dir=run, workspace=run / "workspace", prompts=(), repository_root=repository)
            self.assertEqual(summary["lifecycle"]["exit_outcome"], "post-result-exit")
            if os.name != "nt":
                self.assertTrue(summary["lifecycle"]["process_group_empty"])

    def test_committed_wrapper_fixture_has_approved_bytes_and_mode(self):
        fixture = SPIKE / "fixtures" / "agy-profile"
        self.assertEqual(hashlib.sha256(fixture.read_bytes()).hexdigest(), APPROVED_WRAPPER_SOURCE_SHA256)
        self.assertTrue(os.stat(fixture).st_mode & 0o111)

    def test_workspace_and_prompt_bounds_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "capture"; run.mkdir(); (run / "workspace").mkdir()
            repository = self.make_clean_repo(Path(temporary) / "repo")
            with self.assertRaises(CaptureError):
                run_capture([sys.executable, str(FAKE), "cwd"], mode="fake", capture_dir=run, workspace=run / "workspace", prompts=(), repository_root=repository)

    def test_documented_live_recipe_uses_new_run_dir_without_workspace_flag(self):
        readme = (SPIKE / "README.md").read_text(encoding="utf-8")
        live_recipe = readme.split("### Future live command", 1)[1].split("Live mode invokes", 1)[0]
        self.assertIn("mkdir -p .agy-captures", live_recipe)
        self.assertIn('--capture-dir "$run_dir"', live_recipe)
        self.assertNotIn("--workspace", live_recipe)

    def test_cli_offline_command_works_from_a_clean_checkout_shape(self):
        capture_root = SPIKE.parents[2] / ".agy-captures"
        capture_root.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=capture_root) as temporary:
            checkout = Path(temporary) / "checkout"
            (checkout / "docs" / "spikes").mkdir(parents=True)
            shutil.copy2(SPIKE.parents[2] / ".gitignore", checkout / ".gitignore")
            shutil.copy2(SPIKE.parents[2] / ".gitattributes", checkout / ".gitattributes")
            shutil.copytree(SPIKE, checkout / "docs" / "spikes" / SPIKE.name)
            subprocess.run(["git", "init", "-q"], cwd=checkout, check=True)
            subprocess.run(["git", "config", "user.name", "JARVIS-901 tests"], cwd=checkout, check=True)
            subprocess.run(["git", "config", "user.email", "jarvis-901-tests@example.invalid"], cwd=checkout, check=True)
            subprocess.run(["git", "add", "."], cwd=checkout, check=True)
            subprocess.run(["git", "commit", "-qm", "clean checkout"], cwd=checkout, check=True)
            recipe = (checkout / "docs" / "spikes" / SPIKE.name / "README.md").read_text(encoding="utf-8")
            commands = recipe.split("## Run the offline capture only", 1)[1].split("### Future live command", 1)[0]
            commands = commands.split("```bash", 1)[1].split("```", 1)[0]
            completed = subprocess.run(
                ["bash", "-lc", commands],
                cwd=checkout,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn('"complete": true', completed.stdout)

    def test_minimal_environment_copies_only_allowlisted_names(self):
        source = {
            "PATH": "/bin",
            "HOME": "/home/operator",
            "OPENAI_API_KEY": "token",
            "HTTP_PROXY": "proxy",
            "CLOUDSDK_AUTH_TOKEN": "cloud",
            "LINEAR_API_KEY": "linear",
            "GITHUB_TOKEN": "github",
        }
        environment, names = minimal_environment(source)
        self.assertEqual(names, ["HOME", "PATH"])
        self.assertEqual(environment, {"HOME": "/home/operator", "PATH": TRUSTED_SYSTEM_PATH})

    def test_terminal_summary_omits_adversarial_provider_strings_and_nested_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            workspace.mkdir()
            (workspace / ".jarvis-901-sentinel").write_bytes(b"JARVIS-901 fixture sentinel\n")
            raw = {}
            for name in ("stdin", "stdout", "stderr"):
                raw[name] = root / f"raw-{name}.bin"
                raw[name].write_bytes(b"raw")
            manifest = root / "manifest.json"
            manifest.write_text("{}\n")
            result = RunResult(
                events=[
                    {"event": "init", "conversation_id": "C:\\Users\\owner\\secret", "init": {"cwd": "C:\\Users\\owner\\secret"}},
                    {"event": "step_update", "conversation_id": "prompt=TOP_SECRET"},
                    {"event": "result", "result": {"status": "SUCCESS", "num_turns": 1, "response": "token=TOP_SECRET", "error": "C:\\Users\\owner\\secret", "usage": {"input_tokens": "credential=bad", "total_tokens": 4, "nested": {"secret": "bad"}}, "duration_seconds": "not numeric"}},
                ],
            )
            summary = _summary(result, workspace, raw, manifest, "fake", {"passed_environment_names": []}, "2026-01-01T00:00:00Z")
            rendered = json.dumps(summary, sort_keys=True)

        self.assertNotIn("TOP_SECRET", rendered)
        self.assertNotIn("C:\\Users\\owner\\secret", rendered)
        self.assertEqual(summary["session"]["terminal_observations"], [{"status": "SUCCESS", "num_turns": 1, "usage": {"total_tokens": 4}}])
        self.assertGreater(summary["session"]["invalid_terminal_fields"], 0)

    def test_exit_code_is_nonzero_for_each_required_failure_class(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary) / "capture"
            repository = self.make_clean_repo(Path(temporary) / "repo")
            baseline = run_capture([sys.executable, str(FAKE), "interactive-multi-turn"], mode="fake", capture_dir=run, workspace=run / "workspace", prompts=fake_prompts(), repository_root=repository)
        self.assertEqual(capture_exit_code(baseline), 0)
        for field, value in ((
            ("returncode", 9),
            ("timed_out", "turn"),
            ("process_loss", True),
            ("process_group_empty", False),
            ("cleanup_failed", True),
            ("expected_turns", 3),
            ("stable_identity", False),
            ("invalid_terminal_fields", 1),
            ("malformed_stdout_count", 1),
        )):
            candidate = copy.deepcopy(baseline)
            target = candidate["lifecycle"] if field in candidate["lifecycle"] else candidate["session"]
            target[field] = value
            self.assertNotEqual(capture_exit_code(candidate), 0, field)

    def test_redaction_is_deterministic(self):
        value = "token=" + "unit /" + "home" + "/owner/x"
        self.assertEqual(redact_text(value), "token=<REDACTED> <REDACTED_PATH>")

if __name__ == "__main__": unittest.main()
