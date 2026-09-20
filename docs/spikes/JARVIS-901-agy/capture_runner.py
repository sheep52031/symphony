#!/usr/bin/env python3
"""Offline-by-default, bounded native-Linux `agy` evidence capture helper.

Raw captures are deliberately kept in an ignored local directory. This script is a feasibility
artifact, not a Symphony backend or provider integration.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import queue
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

SPIKE_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = SPIKE_ROOT.parents[3]
LIVE_AUTHORIZATION = "JARVIS-901-OWNER-AUTHORIZED"
SUMMARY_SCHEMA = "jarvis-901-agy-capture-summary-v1"
SECRET_ENVIRONMENT_NAMES = (
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_GEMINI_BASE_URL",
    "ANTHROPIC_API_KEY",
)
OWNER_PATH = re.compile(r"(?:[A-Za-z]:[\\/](?:Users|home)(?:[\\/][^\s]+)+|/(?:home|Users|mnt/c/Users)/[^\s]+)")


class CaptureError(RuntimeError):
    """Raised for a capture invariant or authorization failure."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def redact_text(value: str) -> str:
    """Deterministically remove owner paths and credential-looking values."""
    value = OWNER_PATH.sub("<REDACTED_PATH>", value)
    return re.sub(
        r"(?i)\b(token|secret|password|credential|cookie|api[_-]?key|authorization)\s*[:=]\s*[^\s,;]+",
        r"\1=<REDACTED>",
        value,
    )


def redacted_identity(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()[:16]


def validate_capture_dir(capture_dir: Path, repository_root: Path) -> Path:
    capture_dir = capture_dir.resolve()
    repository_root = repository_root.resolve()
    try:
        relative = capture_dir.relative_to(repository_root)
    except ValueError:
        return capture_dir
    if not relative.parts or relative.parts[0] != ".agy-captures":
        raise CaptureError("capture directory inside the repository must be under .agy-captures/")
    return capture_dir


def safe_argv(command: Sequence[str], workspace: Path) -> list[str]:
    """Keep the executable and argument names while removing local path prefixes."""
    result: list[str] = []
    for argument in command:
        if Path(argument) == workspace:
            result.append("<WORKSPACE>")
        elif os.path.isabs(argument):
            result.append(Path(argument).name)
        else:
            result.append(redact_text(argument))
    return result


def empty_child_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for name in SECRET_ENVIRONMENT_NAMES:
        environment.pop(name, None)
    return environment


def fake_prompts() -> list[bytes]:
    return [
        b'{"event":"user","message":{"content":"fixture alpha"}}\n',
        b'{"event":"user","message":{"content":"fixture recall"}}\n',
    ]


def parse_prompt_file(path: Path) -> list[bytes]:
    prompts: list[bytes] = []
    for line in path.read_bytes().splitlines():
        if not line:
            continue
        try:
            envelope = json.loads(line)
        except json.JSONDecodeError as error:
            raise CaptureError("prompts file must contain NDJSON user envelopes") from error
        if envelope.get("event") != "user":
            raise CaptureError("prompts file may contain only user envelopes")
        prompts.append(line + b"\n")
    if not prompts:
        raise CaptureError("prompts file must contain at least one user envelope")
    return prompts


def _write_raw(handle: Any, stream: str, data: bytes, byte_state: dict[str, int], limit: int) -> bool:
    if byte_state[stream] + len(data) > limit:
        byte_state[stream] += len(data)
        return False
    byte_state[stream] += len(data)
    handle.write(json.dumps({"captured_at": utc_now(), "stream": stream, "bytes_b64": base64.b64encode(data).decode("ascii")}) + "\n")
    handle.flush()
    return True


def _event_identity(event: dict[str, Any]) -> str | None:
    for payload in (event, event.get("step_update"), event.get("result")):
        if isinstance(payload, dict) and isinstance(payload.get("conversation_id"), str):
            return payload["conversation_id"]
    return None


def _run_version(command: Sequence[str]) -> str:
    if command[0] != "agy-profile":
        return "fixture-offline"
    completed = subprocess.run(["agy", "--version"], capture_output=True, check=False, timeout=5)
    if completed.returncode != 0:
        raise CaptureError("static agy --version check failed")
    version = completed.stdout.decode("utf-8", errors="replace").strip()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise CaptureError("static agy --version output was not a version")
    return version


def _wait_for_exit(process: subprocess.Popen[bytes], seconds: float) -> bool:
    try:
        process.wait(timeout=seconds)
        return True
    except subprocess.TimeoutExpired:
        return False


def _stop_process_group(process: subprocess.Popen[bytes], grace: float) -> tuple[list[str], bool]:
    signals: list[str] = []
    for name, number in (("SIGINT", signal.SIGINT), ("SIGTERM", signal.SIGTERM), ("SIGKILL", signal.SIGKILL)):
        if process.poll() is not None:
            break
        try:
            os.killpg(process.pid, number)
            signals.append(name)
        except ProcessLookupError:
            break
        if _wait_for_exit(process, grace):
            break
    return signals, process.poll() is not None


def _process_group_empty(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def validate_summary(summary: dict[str, Any]) -> None:
    required = {"schema", "mode", "command", "version", "timestamps", "raw_capture", "session", "lifecycle", "containment"}
    if set(summary) != required or summary["schema"] != SUMMARY_SCHEMA:
        raise CaptureError("summary schema mismatch")
    if summary["mode"] not in {"fake", "live"} or not isinstance(summary["command"], list):
        raise CaptureError("summary mode or command invariant failed")
    if not isinstance(summary["raw_capture"].get("stdin"), dict):
        raise CaptureError("raw capture invariant failed")
    rendered = json.dumps(summary, sort_keys=True)
    if OWNER_PATH.search(rendered) or re.search(r"fixture (?:alpha|recall)", rendered):
        raise CaptureError("summary contains a prohibited owner path or prompt")


def run_capture(
    command: Sequence[str],
    *,
    mode: str,
    workspace: Path,
    capture_dir: Path,
    prompts: Iterable[bytes],
    turn_timeout: float = 1.0,
    close_grace: float = 0.15,
    signal_grace: float = 0.05,
    max_raw_bytes: int = 1_000_000,
    repository_root: Path = REPOSITORY_ROOT,
) -> dict[str, Any]:
    """Run one fake or explicitly-authorized live session and retain bounded raw envelopes."""
    if mode not in {"fake", "live"}:
        raise CaptureError("mode must be fake or live")
    if min(turn_timeout, close_grace, signal_grace) <= 0 or max_raw_bytes < 1:
        raise CaptureError("capture limits must be positive")
    capture_dir = validate_capture_dir(capture_dir, repository_root)
    capture_dir.mkdir(parents=True, exist_ok=False)
    workspace.mkdir(parents=True, exist_ok=True)
    sentinel = workspace / ".jarvis-901-sentinel"
    sentinel.write_text("JARVIS-901 fixture sentinel\n", encoding="utf-8")
    sentinel_before = sentinel.read_bytes()
    version = _run_version(command)
    started_at = utc_now()
    process = subprocess.Popen(
        list(command), cwd=workspace, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, start_new_session=True, env=empty_child_environment(),
    )
    assert process.stdin is not None and process.stdout is not None and process.stderr is not None
    received: queue.Queue[tuple[str, bytes | None]] = queue.Queue()

    def read_stream(name: str, stream: Any) -> None:
        try:
            while chunk := stream.read1(256):
                received.put((name, chunk))
        finally:
            received.put((name, None))

    readers = [threading.Thread(target=read_stream, args=(name, stream), daemon=True) for name, stream in (("stdout", process.stdout), ("stderr", process.stderr))]
    for reader in readers:
        reader.start()
    raw_paths = {name: capture_dir / f"raw-{name}.jsonl" for name in ("stdin", "stdout", "stderr")}
    raw_manifest = capture_dir / "raw-manifest.json"
    raw_handles = {name: path.open("w", encoding="utf-8") for name, path in raw_paths.items()}
    bytes_seen = {name: 0 for name in raw_paths}
    raw_retained = {name: 0 for name in raw_paths}
    events: list[dict[str, Any]] = []
    malformed_stdout = 0
    stderr_lines = 0
    identities: list[str] = []
    statuses: list[str] = []
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    closed: set[str] = set()
    signals: list[str] = []

    def consume_line(stream: str, line: bytes) -> None:
        nonlocal malformed_stdout, stderr_lines
        if _write_raw(raw_handles[stream], stream, line, bytes_seen, max_raw_bytes):
            raw_retained[stream] += len(line)
        if stream == "stderr":
            stderr_lines += 1
            return
        try:
            event = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            malformed_stdout += 1
            return
        if not isinstance(event, dict):
            malformed_stdout += 1
            return
        events.append(event)
        identity = _event_identity(event)
        if identity:
            identities.append(identity)
        result = event.get("result")
        if isinstance(result, dict) and isinstance(result.get("status"), str):
            statuses.append(result["status"])

    def drain_until_result(expected: int) -> None:
        deadline = time.monotonic() + turn_timeout
        while len(statuses) < expected:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CaptureError(f"turn {expected} did not produce a terminal result before deadline")
            try:
                stream, chunk = received.get(timeout=min(remaining, 0.05))
            except queue.Empty:
                if process.poll() is not None:
                    raise CaptureError(f"process exited before terminal result {expected}")
                continue
            if chunk is None:
                closed.add(stream)
                if buffers[stream]:
                    consume_line(stream, bytes(buffers[stream]))
                    buffers[stream].clear()
                continue
            buffers[stream].extend(chunk)
            while b"\n" in buffers[stream]:
                line, _, remainder = buffers[stream].partition(b"\n")
                buffers[stream] = bytearray(remainder)
                consume_line(stream, bytes(line.rstrip(b"\r")))

    error: str | None = None
    try:
        for expected, prompt in enumerate(prompts, start=1):
            if not prompt.endswith(b"\n"):
                raise CaptureError("prompt envelope must be LF-terminated")
            stdin_line = prompt.rstrip(b"\n")
            if _write_raw(raw_handles["stdin"], "stdin", stdin_line, bytes_seen, max_raw_bytes):
                raw_retained["stdin"] += len(stdin_line)
            process.stdin.write(prompt)
            process.stdin.flush()
            drain_until_result(expected)
    except CaptureError as exception:
        error = str(exception)
    finally:
        try:
            process.stdin.close()
        except OSError:
            pass
        if not _wait_for_exit(process, close_grace):
            signals, _ = _stop_process_group(process, signal_grace)
        for stream in ("stdout", "stderr"):
            while stream not in closed:
                try:
                    name, chunk = received.get(timeout=0.05)
                except queue.Empty:
                    break
                if chunk is None:
                    closed.add(name)
                else:
                    buffers[name].extend(chunk)
                    while b"\n" in buffers[name]:
                        line, _, remainder = buffers[name].partition(b"\n")
                        buffers[name] = bytearray(remainder)
                        consume_line(name, bytes(line.rstrip(b"\r")))
            if buffers[stream]:
                consume_line(stream, bytes(buffers[stream]))
        if process.poll() is None:
            more_signals, _ = _stop_process_group(process, signal_grace)
            signals.extend(more_signals)
        returncode = process.wait(timeout=0.2)
        for handle in raw_handles.values():
            handle.close()
        for reader in readers:
            reader.join(timeout=0.1)
        for stream in (process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass
        process_group_empty = _process_group_empty(process.pid)
        raw_manifest.write_text(
            json.dumps(
                {
                    "started_at": started_at,
                    "finished_at": utc_now(),
                    "command": list(command),
                    "version": version,
                    "cwd": str(workspace),
                    "pid": process.pid,
                    "process_group": process.pid,
                    "returncode": returncode,
                    "signals_sent": signals,
                    "process_group_empty": process_group_empty,
                },
                indent=2,
                sort_keys=True,
            ) + "\n",
            encoding="utf-8",
        )

    unique_identities = list(dict.fromkeys(identities))
    summary = {
        "schema": SUMMARY_SCHEMA,
        "mode": mode,
        "command": safe_argv(command, workspace),
        "version": version,
        "timestamps": {"started_at": started_at, "finished_at": utc_now()},
        "raw_capture": {
            **{name: {"file": raw_paths[name].name, "bytes_seen": bytes_seen[name], "bytes_retained": raw_retained[name], "truncated": bytes_seen[name] > raw_retained[name]} for name in raw_paths},
            "manifest": {"file": raw_manifest.name},
        },
        "session": {
            "init_events": sum(event.get("event") == "init" for event in events),
            "terminal_statuses": statuses,
            "distinct_identities": len(unique_identities),
            "stable_identity": len(unique_identities) == 1 and bool(unique_identities),
            "redacted_identities": [redacted_identity(identity) for identity in unique_identities],
            "malformed_stdout_lines": malformed_stdout,
            "stderr_lines": stderr_lines,
        },
        "lifecycle": {
            "pid": process.pid,
            "process_group": process.pid,
            "returncode": returncode,
            "signals_sent": signals,
            "process_group_empty": process_group_empty,
            "error": redact_text(error) if error else None,
        },
        "containment": {
            "cwd": "<WORKSPACE>",
            "sentinel": sentinel.name,
            "sentinel_unchanged": sentinel.exists() and sentinel.read_bytes() == sentinel_before,
            "native_cwd_exposed": any(isinstance(event.get("init"), dict) and "cwd" in event["init"] for event in events),
        },
    }
    validate_summary(summary)
    (capture_dir / "redacted-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return summary


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("fake", "live"), default="fake")
    parser.add_argument("--live-authorization")
    parser.add_argument("--profile", default="acc1")
    parser.add_argument("--prompts-file", type=Path)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--scenario", default="interactive-multi-turn")
    arguments = parser.parse_args(argv)
    if arguments.mode == "live" and arguments.live_authorization != LIVE_AUTHORIZATION:
        parser.error("live mode requires a fresh --live-authorization JARVIS-901-OWNER-AUTHORIZED")
    if arguments.mode == "live" and arguments.prompts_file is None:
        parser.error("live mode requires an owner-reviewed --prompts-file")
    capture_dir = arguments.capture_dir or Path(tempfile.mkdtemp(prefix="jarvis-901-agy-")) / "capture"
    workspace = arguments.workspace or capture_dir / "workspace"
    if arguments.mode == "fake":
        command = [sys.executable, str(SPIKE_ROOT / "fixtures" / "fake_agy.py"), arguments.scenario]
        prompts = fake_prompts() if arguments.scenario == "interactive-multi-turn" else []
    else:
        command = ["agy-profile", arguments.profile, "--mode", "plan", "--input-format", "stream-json", "--output-format", "stream-json", "--print-timeout", "60s"]
        prompts = parse_prompt_file(arguments.prompts_file)
    summary = run_capture(command, mode=arguments.mode, workspace=workspace, capture_dir=capture_dir, prompts=prompts)
    print(json.dumps({"capture_dir": str(capture_dir), "mode": summary["mode"], "terminal_statuses": summary["session"]["terminal_statuses"]}, sort_keys=True))
    return 1 if summary["lifecycle"]["error"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
