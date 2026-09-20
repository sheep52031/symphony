#!/usr/bin/env python3
"""Offline-default provenance wrapper around the bounded JARVIS-901 probe."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

from probe import RunResult, run_fixture

SPIKE_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = SPIKE_ROOT.parents[2]
LIVE_AUTHORIZATION = "JARVIS-901-OWNER-AUTHORIZED"
SUMMARY_SCHEMA = "jarvis-901-agy-capture-summary-v2"
MAX_PROMPTS = 4
MAX_PROMPT_BYTES = 4096
MAX_RAW_BYTES = 1_000_000
OWNER_PATH = re.compile(r"(?:[A-Za-z]:[\\/](?:Users|home)(?:[\\/][^\s]+)+|/(?:home|Users|mnt/c/Users)/[^\s]+)")
ALLOWLIST = ("HOME", "PATH", "LANG", "LC_ALL", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")


class CaptureError(RuntimeError):
    pass


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def redact_text(value: str) -> str:
    value = OWNER_PATH.sub("<REDACTED_PATH>", value)
    return re.sub(r"(?i)\b(token|secret|password|credential|cookie|api[_-]?key|authorization)\s*[:=]\s*[^\s,;]+", r"\1=<REDACTED>", value)


def redacted_identity(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode()).hexdigest()[:16]


def minimal_environment() -> tuple[dict[str, str], list[str]]:
    environment = {name: os.environ[name] for name in ALLOWLIST if name in os.environ}
    return environment, sorted(environment)


def validate_run_directory(directory: Path, repository_root: Path) -> Path:
    directory = directory.resolve()
    root = repository_root.resolve()
    try:
        relative = directory.relative_to(root)
    except ValueError:
        return directory
    if not relative.parts or relative.parts[0] != ".agy-captures":
        raise CaptureError("capture directory inside the repository must be under .agy-captures/")
    return directory


def parse_prompt_file(path: Path) -> list[bytes]:
    data = path.read_bytes()
    if len(data) > MAX_PROMPTS * MAX_PROMPT_BYTES:
        raise CaptureError("prompt file exceeds bounded input limit")
    lines = data.splitlines(keepends=True)
    if not lines or len(lines) > MAX_PROMPTS:
        raise CaptureError("prompt count is outside bounded limit")
    prompts: list[bytes] = []
    for line in lines:
        if not line.endswith(b"\n") or len(line) > MAX_PROMPT_BYTES:
            raise CaptureError("prompt envelope must be bounded LF-delimited NDJSON")
        try:
            envelope = json.loads(line.rstrip(b"\n").rstrip(b"\r"))
        except json.JSONDecodeError as error:
            raise CaptureError("prompt file must contain NDJSON user envelopes") from error
        if not isinstance(envelope, dict) or envelope.get("event") != "user":
            raise CaptureError("prompts file may contain only user envelopes")
        prompts.append(line)
    return prompts


def fake_prompts() -> list[bytes]:
    return [b'{"event":"user","message":{"content":"fixture alpha"}}\r\n', b'{"event":"user","message":{"content":"fixture recall"}}\n']


def launcher_provenance() -> dict[str, str]:
    launcher = Path(shutil.which("agy-profile") or "agy-profile").resolve()
    executable = Path(shutil.which("agy") or "agy").resolve()
    return {"launcher_name": launcher.name, "launcher_sha256": sha256(launcher), "executable_name": executable.name, "executable_sha256": sha256(executable)}


def artifact(path: Path) -> dict[str, Any]:
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}


def _summary(result: RunResult, workspace: Path, raw: dict[str, Path], manifest: Path, mode: str, provenance: dict[str, Any], started: str) -> dict[str, Any]:
    identities: list[str] = []
    observations: list[dict[str, Any]] = []
    cwd: str | None = None
    for event in result.events:
        if event.get("event") == "init" and isinstance(event.get("init"), dict):
            cwd = event["init"].get("cwd")
        for payload in (event, event.get("step_update"), event.get("result")):
            if isinstance(payload, dict) and isinstance(payload.get("conversation_id"), str):
                identities.append(payload["conversation_id"])
        terminal = event.get("result")
        if isinstance(terminal, dict):
            observations.append({key: terminal[key] for key in ("status", "num_turns", "usage") if key in terminal})
    distinct = list(dict.fromkeys(identities))
    observed_cwd = "<WORKSPACE>" if cwd == str(workspace) else redact_text(cwd or "")
    summary = {
        "schema": SUMMARY_SCHEMA,
        "mode": mode,
        "started_at": started,
        "finished_at": now(),
        "provenance": provenance,
        "raw": {name: artifact(path) for name, path in raw.items()},
        "manifest_sha256": sha256(manifest),
        "session": {"init_events": sum(event.get("event") == "init" for event in result.events), "identities": [redacted_identity(value) for value in distinct], "stable_identity": len(distinct) == 1 and bool(distinct), "terminal_observations": observations, "dropped_events": result.dropped_events, "dropped_malformed_stdout": result.dropped_malformed_stdout, "dropped_stderr_lines": result.dropped_stderr_lines, "truncated_stdout_frames": result.truncated_stdout_frames, "truncated_stderr_frames": result.truncated_stderr_frames},
        "containment": {"cwd": observed_cwd, "cwd_match": cwd == str(workspace), "sentinel_unchanged": (workspace / ".jarvis-901-sentinel").read_bytes() == b"JARVIS-901 fixture sentinel\n"},
        "lifecycle": {"returncode": result.returncode, "timed_out": result.timed_out, "exit_outcome": result.exit_outcome, "interrupted": result.interrupted},
    }
    rendered = json.dumps(summary, sort_keys=True)
    if OWNER_PATH.search(rendered) or "fixture alpha" in rendered:
        raise CaptureError("redacted summary invariant failed")
    return summary


def run_capture(command: Sequence[str], *, mode: str, workspace: Path, capture_dir: Path, prompts: Sequence[bytes], repository_root: Path = REPOSITORY_ROOT) -> dict[str, Any]:
    capture_dir = validate_run_directory(capture_dir, repository_root)
    capture_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if capture_dir.is_symlink() or workspace.exists() or workspace.is_symlink():
        raise CaptureError("capture directory and workspace must be new real directories")
    workspace.resolve().relative_to(capture_dir)
    workspace.mkdir(mode=0o700)
    sentinel = workspace / ".jarvis-901-sentinel"
    if sentinel.exists() or sentinel.is_symlink():
        raise CaptureError("sentinel already exists")
    sentinel.write_bytes(b"JARVIS-901 fixture sentinel\n")
    raw = {name: capture_dir / f"raw-{name}.bin" for name in ("stdin", "stdout", "stderr")}
    handles = {name: path.open("xb") for name, path in raw.items()}
    counts = {name: 0 for name in raw}
    def sink(name: str, data: bytes) -> None:
        if counts[name] + len(data) <= MAX_RAW_BYTES:
            handles[name].write(data)
        counts[name] += len(data)
    environment, names = minimal_environment()
    started = now()
    try:
        result = run_fixture(command, cwd=workspace, first_token_timeout=0.5, turn_timeout=1.0, post_result_exit_grace=0.1, read_chunk_bytes=64, max_queue_chunks=4, max_frame_bytes=4096, max_events=32, max_malformed_stdout=16, max_stderr_lines=16, stdin_lines=prompts, raw_sink=sink)
    finally:
        for handle in handles.values():
            handle.close()
    provenance: dict[str, Any] = {"runner_sha256": sha256(Path(__file__)), "git_revision": subprocess.run(["git", "-C", str(repository_root), "rev-parse", "HEAD"], text=True, capture_output=True, check=False).stdout.strip(), "host": {"os": platform.system(), "kernel": platform.release(), "arch": platform.machine()}, "passed_environment_names": names, "raw_observed_bytes": counts}
    if mode == "live":
        provenance["launcher"] = launcher_provenance()
    manifest = capture_dir / "raw-manifest.json"
    manifest.write_text(json.dumps({"started_at": started, "command": list(command), "workspace": str(workspace), "provenance": provenance, "raw": {name: artifact(path) for name, path in raw.items()}}, sort_keys=True, indent=2) + "\n")
    summary = _summary(result, workspace, raw, manifest, mode, provenance, started)
    (capture_dir / "redacted-summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
    return summary


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("fake", "live"), default="fake")
    parser.add_argument("--live-authorization")
    parser.add_argument("--profile", default="acc1")
    parser.add_argument("--prompts-file", type=Path)
    parser.add_argument("--capture-dir", type=Path)
    arguments = parser.parse_args(argv)
    if arguments.mode == "live" and arguments.live_authorization != LIVE_AUTHORIZATION:
        parser.error("live mode requires a fresh --live-authorization JARVIS-901-OWNER-AUTHORIZED")
    root = REPOSITORY_ROOT / ".agy-captures"
    root.mkdir(mode=0o700, exist_ok=True)
    run_dir = arguments.capture_dir or Path(tempfile.mkdtemp(prefix="run-", dir=root))
    prompts = fake_prompts() if arguments.mode == "fake" else parse_prompt_file(arguments.prompts_file) if arguments.prompts_file else parser.error("live mode requires --prompts-file")
    command = [sys.executable, str(SPIKE_ROOT / "fixtures" / "fake_agy.py"), "interactive-multi-turn"] if arguments.mode == "fake" else ["agy-profile", arguments.profile, "--mode", "plan", "--input-format", "stream-json", "--output-format", "stream-json", "--print-timeout", "60s"]
    summary = run_capture(command, mode=arguments.mode, workspace=run_dir / "workspace", capture_dir=run_dir, prompts=prompts)
    print(json.dumps({"mode": summary["mode"], "terminal_observations": summary["session"]["terminal_observations"]}, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
