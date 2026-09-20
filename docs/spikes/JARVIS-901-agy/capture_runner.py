#!/usr/bin/env python3
"""Offline-default provenance wrapper around the bounded JARVIS-901 probe."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Sequence

from probe import RunResult, TERMINAL_STATUSES, USAGE_FIELDS, run_fixture

SPIKE_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = SPIKE_ROOT.parents[2]
LIVE_AUTHORIZATION = "JARVIS-901-OWNER-AUTHORIZED"
SUMMARY_SCHEMA = "jarvis-901-agy-capture-summary-v4"
RAW_MANIFEST_SCHEMA = "jarvis-901-agy-raw-manifest-v2"
APPROVED_WRAPPER = SPIKE_ROOT / "fixtures" / "agy-profile"
APPROVED_WRAPPER_SOURCE_SHA256 = "6f51a53038fe98f434bb483a6288ac747f8d76b1984fd695910644b3668627bb"
APPROVED_AGY_TARGET = Path.home() / ".local" / "bin" / "agy"
TRUSTED_SYSTEM_PATH = (
    r"C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem"
    if os.name == "nt"
    else "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
)
MAX_PROMPTS = 4
MAX_PROMPT_BYTES = 4096
MAX_RAW_BYTES = 1_000_000
MIN_LIVE_DEADLINE = 1.0
MAX_LIVE_DEADLINE = 3600.0
LIVE_FIRST_TOKEN_DEFAULT = 30.0
LIVE_TURN_DEFAULT = 300.0
LIVE_EXIT_GRACE_DEFAULT = 1.0
OWNER_PATH = re.compile(r"(?:[A-Za-z]:[\\/](?:Users|home)(?:[\\/][^\s]+)+|/(?:home|Users|mnt/c/Users)/[^\s]+)")
SECRET_ASSIGNMENT = re.compile(
    r"(?i)\b(token|secret|password|credential|cookie|api[_-]?key|authorization)\s*[:=]\s*[^\s,;]+"
)
SAFE_ENV_NAMES = (
    "HOME",
    "PATH",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
)
SLOT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
VERSION_RE = re.compile(r"\b\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?\b")
ABSOLUTE_EXEC_RE = re.compile(r"\bexec\s+(?:['\"])?(/[^'\"\s]+agy(?:\.exe)?)(?:['\"])?\s+\"?\$@")


class CaptureError(RuntimeError):
    """A fail-closed capture setup, provenance, or evidence error."""


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
    return SECRET_ASSIGNMENT.sub(r"\1=<REDACTED>", value)


def redacted_identity(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode()).hexdigest()[:16]


def minimal_environment(source: Mapping[str, str] | None = None) -> tuple[dict[str, str], list[str]]:
    """Copy safe process basics and replace operator PATH with the fixed trusted system policy."""
    source = os.environ if source is None else source
    environment = {name: source[name] for name in SAFE_ENV_NAMES if name in source and name != "PATH"}
    environment["PATH"] = TRUSTED_SYSTEM_PATH
    return environment, sorted(environment)


def _git_snapshot(repository_root: Path) -> dict[str, str]:
    status = subprocess.run(
        ["git", "-C", str(repository_root), "status", "--porcelain=v1", "--untracked-files=no"],
        text=True,
        capture_output=True,
        check=False,
    )
    if status.returncode != 0:
        raise CaptureError("repository is not a readable git worktree")
    if status.stdout.strip():
        raise CaptureError("tracked git tree must be clean before and after capture")
    head = subprocess.run(
        ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
        text=True,
        capture_output=True,
        check=False,
    )
    tree = subprocess.run(
        ["git", "-C", str(repository_root), "rev-parse", "HEAD^{tree}"],
        text=True,
        capture_output=True,
        check=False,
    )
    if head.returncode != 0 or tree.returncode != 0:
        raise CaptureError("repository HEAD/tree could not be recorded")
    return {"head": head.stdout.strip(), "tree": tree.stdout.strip()}


def _code_provenance() -> dict[str, str]:
    return {
        "capture_runner_sha256": sha256(Path(__file__)),
        "probe_sha256": sha256(SPIKE_ROOT / "probe.py"),
        "fake_fixture_sha256": sha256(SPIKE_ROOT / "fixtures" / "fake_agy.py"),
        "safe_wrapper_sha256": sha256(APPROVED_WRAPPER),
    }


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
    return [
        b'{"event":"user","message":{"content":"fixture alpha"}}\r\n',
        b'{"event":"user","message":{"content":"fixture recall"}}\n',
    ]


def _regular_executable(path: Path, *, label: str) -> None:
    if path.is_symlink():
        raise CaptureError(f"{label} must not be a symlink")
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError as error:
        raise CaptureError(f"{label} is unavailable") from error
    if not path.is_file() or not (mode & 0o111):
        raise CaptureError(f"{label} is not an executable regular file")


def _static_underlying_path(wrapper: Path, text: str) -> Path:
    if 'exec "$REAL_HOME/.local/bin/agy" "$@"' in text:
        return APPROVED_AGY_TARGET
    match = ABSOLUTE_EXEC_RE.search(text)
    if match:
        return Path(match.group(1))
    raise CaptureError("safe wrapper does not bind an absolute underlying agy executable")


def _validate_profile_contract(text: str) -> None:
    required = (
        'SLOT="$1"',
        'PROFILE="$REAL_HOME/.agy-profiles/$SLOT"',
        'export HOME="$PROFILE"',
        "exec",
    )
    if any(fragment not in text for fragment in required):
        raise CaptureError("safe wrapper profile-root contract is not approved")


def _version(binary: Path, environment: Mapping[str, str], cwd: Path) -> str:
    try:
        completed = subprocess.run(
            [str(binary), "--version"],
            cwd=cwd,
            env=dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5.0,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CaptureError("underlying agy version could not be captured") from error
    if completed.returncode != 0:
        raise CaptureError("underlying agy version command failed")
    output = (completed.stdout + b"\n" + completed.stderr).decode("utf-8", errors="replace")
    match = VERSION_RE.search(output)
    if not match:
        raise CaptureError("underlying agy version was not numeric")
    return match.group(0)


def wrapper_provenance(
    wrapper: Path = APPROVED_WRAPPER,
    *,
    profile: str = "acc1",
    environment: Mapping[str, str] | None = None,
    cwd: Path | None = None,
    expected_wrapper_sha256: str | None = None,
    capture_version: bool = False,
) -> dict[str, Any]:
    """Pin the committed safe wrapper and its absolute external agy target."""
    wrapper = wrapper.expanduser().resolve()
    if wrapper != APPROVED_WRAPPER.resolve():
        raise CaptureError("live mode requires the committed safe wrapper")
    if not SLOT_RE.fullmatch(profile):
        raise CaptureError("profile slot is invalid")
    _regular_executable(wrapper, label="committed safe wrapper")
    mode = stat.S_IMODE(wrapper.stat().st_mode)
    _regular_executable(APPROVED_WRAPPER, label="committed safe wrapper")
    fixture_bytes = APPROVED_WRAPPER.read_bytes()
    fixture_hash = sha256(APPROVED_WRAPPER)
    if fixture_hash != APPROVED_WRAPPER_SOURCE_SHA256:
        raise CaptureError("committed safe wrapper hash changed")
    wrapper_bytes = wrapper.read_bytes()
    wrapper_hash = sha256(wrapper)
    if expected_wrapper_sha256 is None:
        expected_wrapper_sha256 = APPROVED_WRAPPER_SOURCE_SHA256
    if wrapper_bytes != fixture_bytes or wrapper_hash != expected_wrapper_sha256:
        raise CaptureError("committed safe wrapper changed")
    try:
        text = wrapper.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise CaptureError("committed safe wrapper cannot be inspected") from error
    _validate_profile_contract(text)
    binary = _static_underlying_path(wrapper, text).resolve()
    _regular_executable(binary, label="absolute agy target")
    binary_hash = sha256(binary)
    environment = minimal_environment()[0] if environment is None else dict(environment)
    version = _version(binary, environment, cwd or wrapper.parent) if capture_version else None
    if sha256(wrapper) != wrapper_hash or sha256(binary) != binary_hash:
        raise CaptureError("committed safe wrapper or absolute agy target changed")
    result: dict[str, Any] = {
        "wrapper_name": wrapper.name,
        "wrapper_mode": format(mode, "04o"),
        "wrapper_sha256": wrapper_hash,
        "safe_wrapper_source_sha256": fixture_hash,
        "underlying_name": binary.name,
        "underlying_sha256": binary_hash,
        "executable_name": binary.name,
        "executable_sha256": binary_hash,
        "underlying_target_contract": "$REAL_HOME/.local/bin/agy",
        "underlying_target_is_absolute": binary.is_absolute(),
        "profile_root_contract": "REAL_HOME/.agy-profiles/<slot>",
        "profile_slot": profile,
        "profile_and_keyring_external": True,
        "projects_operator_ssh_git_config": False,
    }
    if version is not None:
        result["version"] = version
    return result


def artifact(path: Path) -> dict[str, Any]:
    return {"file": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}


def _numeric(value: object, *, integer: bool = False) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if integer and not isinstance(value, int):
        return None
    if not math.isfinite(float(value)) or value < 0:
        return None
    return value


def _terminal_observation(payload: object) -> tuple[dict[str, Any] | None, int]:
    if not isinstance(payload, dict) or payload.get("status") not in TERMINAL_STATUSES:
        return None, 1
    turns = _numeric(payload.get("num_turns"), integer=True)
    if turns is None:
        return None, 1
    observation: dict[str, Any] = {"status": payload["status"], "num_turns": turns}
    invalid = 0
    if "duration_seconds" in payload:
        duration = _numeric(payload["duration_seconds"])
        if duration is None:
            invalid += 1
        else:
            observation["duration_seconds"] = duration
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        invalid += 1
    else:
        safe_usage: dict[str, int | float] = {}
        for name in USAGE_FIELDS:
            if name not in usage:
                invalid += 1
                continue
            value = _numeric(usage[name], integer=True)
            if value is None:
                invalid += 1
            else:
                safe_usage[name] = value
        if safe_usage:
            observation["usage"] = safe_usage
    return observation, invalid


def _summary(
    result: RunResult,
    workspace: Path,
    raw: dict[str, Path],
    manifest: Path,
    mode: str,
    provenance: dict[str, Any],
    started: str,
) -> dict[str, Any]:
    identities: list[str] = []
    observations: list[dict[str, Any]] = []
    invalid_terminal_fields = result.invalid_terminal_results
    cwd: str | None = None
    for event in result.events:
        if event.get("event") == "init":
            init = event.get("init")
            if isinstance(init, dict) and isinstance(init.get("cwd"), str):
                cwd = init["cwd"]
        for payload in (event, event.get("step_update"), event.get("result")):
            if isinstance(payload, dict) and isinstance(payload.get("conversation_id"), str):
                identities.append(payload["conversation_id"])
        if event.get("event") == "result":
            observation, invalid = _terminal_observation(event.get("result"))
            invalid_terminal_fields += invalid
            if observation is not None:
                observations.append(observation)
    distinct = list(dict.fromkeys(identities))
    sentinel = workspace / ".jarvis-901-sentinel"
    try:
        sentinel_unchanged = sentinel.read_bytes() == b"JARVIS-901 fixture sentinel\n"
    except OSError:
        sentinel_unchanged = False
    observed_cwd = "<WORKSPACE>" if cwd == str(workspace) else "<UNMATCHED>"
    session = {
        "init_events": result.init_events,
        "invalid_session_events": result.invalid_session_events,
        "identities": [redacted_identity(value) for value in distinct],
        "stable_identity": len(distinct) == 1 and bool(distinct),
        "terminal_observations": observations,
        "expected_turns": result.expected_turns,
        "completed_turns": result.completed_turns,
        "invalid_terminal_fields": invalid_terminal_fields,
        "malformed_stdout_count": len(result.malformed_stdout),
        "dropped_events": result.dropped_events,
        "dropped_malformed_stdout": result.dropped_malformed_stdout,
        "dropped_stderr_lines": result.dropped_stderr_lines,
        "truncated_stdout_frames": result.truncated_stdout_frames,
        "truncated_stderr_frames": result.truncated_stderr_frames,
        "observed_bytes": dict(result.observed_bytes),
    }
    summary = {
        "schema": SUMMARY_SCHEMA,
        "protocol_policy": {
            "first_event": "init",
            "init_identity": "nonempty",
            "identity": "stable",
        },
        "cleanup_policy": {
            "absolute_deadline_after_final_escalation": True,
            "bounded_reader_join": True,
            "group_survival_is_failure": True,
        },
        "mode": mode,
        "started_at": started,
        "finished_at": now(),
        "provenance": provenance,
        "raw": {name: artifact(path) for name, path in raw.items()},
        "manifest_sha256": sha256(manifest),
        "session": session,
        "containment": {
            "cwd": observed_cwd,
            "cwd_match": cwd == str(workspace),
            "sentinel_unchanged": sentinel_unchanged,
        },
        "lifecycle": {
            "pid": result.pid,
            "pgid": result.pgid,
            "signals": list(result.signals),
            "process_group_empty": result.process_group_empty,
            "returncode": result.returncode,
            "timed_out": result.timed_out,
            "process_loss": result.process_loss,
            "exit_outcome": result.exit_outcome,
            "interrupted": result.interrupted,
            "cleanup_failed": result.cleanup_failed,
        },
    }
    rendered = json.dumps(summary, sort_keys=True)
    if OWNER_PATH.search(rendered) or any(
        prompt in rendered for prompt in ("fixture alpha", "fixture recall")
    ):
        raise CaptureError("redacted summary invariant failed")
    return summary


def failure_reasons(summary: Mapping[str, Any]) -> list[str]:
    session = summary["session"]
    lifecycle = summary["lifecycle"]
    containment = summary["containment"]
    reasons: list[str] = []
    if session["expected_turns"] != session["completed_turns"]:
        reasons.append("missing-terminal-results")
    if session["init_events"] != 1 or session["invalid_session_events"]:
        reasons.append("invalid-fresh-session")
    if not session["stable_identity"]:
        reasons.append("identity-instability")
    if not containment["cwd_match"] or not containment["sentinel_unchanged"]:
        reasons.append("containment-failure")
    if lifecycle["timed_out"] is not None:
        reasons.append("timeout")
    if lifecycle["process_loss"] or lifecycle["returncode"] != 0:
        reasons.append("process-loss-or-nonzero-exit")
    group_empty = lifecycle["process_group_empty"]
    host_os = summary.get("provenance", {}).get("host", {}).get("os")
    if group_empty is False or (group_empty is None and host_os != "Windows") or lifecycle["cleanup_failed"]:
        reasons.append("cleanup-failure")
    if session["invalid_terminal_fields"] or session["malformed_stdout_count"] or session["truncated_stdout_frames"] or session["truncated_stderr_frames"]:
        reasons.append("invalid-or-truncated-evidence")
    if session["dropped_events"] or session["dropped_malformed_stdout"] or session["dropped_stderr_lines"]:
        reasons.append("bounded-evidence-dropped")
    if not session["terminal_observations"] or any(
        item.get("status") != "SUCCESS" for item in session["terminal_observations"]
    ):
        reasons.append("incomplete-terminal-status")
    observed = session["observed_bytes"]
    for name, metadata in summary["raw"].items():
        if observed.get(name, 0) > metadata["bytes"]:
            reasons.append("raw-evidence-truncated")
            break
    return list(dict.fromkeys(reasons))


def capture_exit_code(summary: Mapping[str, Any]) -> int:
    return 0 if not failure_reasons(summary) else 1


def _safe_command_label(mode: str, profile: str) -> list[str]:
    if mode == "fake":
        return ["<fixture>/fake_agy.py", "interactive-multi-turn"]
    return ["<committed-safe-wrapper>", profile, "--mode", "plan", "--input-format", "stream-json", "--output-format", "stream-json", "--print-timeout", "60s"]


def _check_pin(provenance: Mapping[str, Any], wrapper: Path, binary: Path) -> None:
    if sha256(APPROVED_WRAPPER) != APPROVED_WRAPPER_SOURCE_SHA256:
        raise CaptureError("committed safe wrapper changed before or during capture")
    if wrapper.read_bytes() != APPROVED_WRAPPER.read_bytes():
        raise CaptureError("committed safe wrapper changed before or during capture")
    if sha256(wrapper) != provenance["wrapper_sha256"] or sha256(binary) != provenance["underlying_sha256"]:
        raise CaptureError("committed safe wrapper or absolute agy target changed before or during capture")


def run_capture(
    command: Sequence[str] | None = None,
    *,
    mode: str,
    capture_dir: Path,
    prompts: Sequence[bytes],
    workspace: Path | None = None,
    repository_root: Path = REPOSITORY_ROOT,
    profile: str = "acc1",
    wrapper: Path = APPROVED_WRAPPER,
    first_token_timeout: float | None = None,
    turn_timeout: float | None = None,
    post_result_exit_grace: float | None = None,
) -> dict[str, Any]:
    if mode not in {"fake", "live"}:
        raise CaptureError("capture mode is invalid")
    git_before = _git_snapshot(repository_root)
    code_before = _code_provenance()
    capture_dir = validate_run_directory(capture_dir, repository_root)
    if capture_dir.is_symlink():
        raise CaptureError("capture directory must be a real directory")
    capture_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(capture_dir, 0o700)
    workspace = (capture_dir / "workspace") if workspace is None else workspace
    workspace = workspace.resolve()
    try:
        workspace.relative_to(capture_dir)
    except ValueError as error:
        raise CaptureError("workspace must be below capture directory") from error
    if workspace.exists() or workspace.is_symlink():
        raise CaptureError("workspace must be a new real directory")
    workspace.mkdir(mode=0o700)
    sentinel = workspace / ".jarvis-901-sentinel"
    sentinel.write_bytes(b"JARVIS-901 fixture sentinel\n")
    raw = {name: capture_dir / f"raw-{name}.bin" for name in ("stdin", "stdout", "stderr")}
    handles = {name: path.open("xb") for name, path in raw.items()}
    counts = {name: 0 for name in raw}

    def sink(name: str, data: bytes) -> None:
        if counts[name] + len(data) <= MAX_RAW_BYTES:
            handles[name].write(data)
        counts[name] += len(data)

    environment, environment_names = minimal_environment()
    started = now()
    pin: dict[str, Any] | None = None
    wrapper_path: Path | None = None
    binary_path: Path | None = None
    try:
        if mode == "live":
            if wrapper.expanduser().resolve() != APPROVED_WRAPPER.resolve():
                raise CaptureError("live mode requires the committed safe wrapper")
            bounded_first = LIVE_FIRST_TOKEN_DEFAULT if first_token_timeout is None else first_token_timeout
            bounded_turn = LIVE_TURN_DEFAULT if turn_timeout is None else turn_timeout
            bounded_exit = LIVE_EXIT_GRACE_DEFAULT if post_result_exit_grace is None else post_result_exit_grace
            for value, name in ((bounded_first, "first-token"), (bounded_turn, "turn"), (bounded_exit, "exit-grace")):
                if not MIN_LIVE_DEADLINE <= value <= MAX_LIVE_DEADLINE:
                    raise CaptureError(f"live {name} deadline is outside safe bounds")
            wrapper_path = wrapper.expanduser().resolve()
            pin = wrapper_provenance(
                wrapper_path,
                profile=profile,
                environment=environment,
                cwd=workspace,
                capture_version=True,
            )
            binary_path = _static_underlying_path(wrapper_path, wrapper_path.read_text(encoding="utf-8")).resolve()
            _check_pin(pin, wrapper_path, binary_path)
            actual_command = [
                str(wrapper_path),
                profile,
                "--mode",
                "plan",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--print-timeout",
                "60s",
            ]
        else:
            bounded_first, bounded_turn, bounded_exit = 0.5, 1.0, 0.1
            actual_command = list(command or [sys.executable, str(SPIKE_ROOT / "fixtures" / "fake_agy.py"), "interactive-multi-turn"])
        try:
            result = run_fixture(
                actual_command,
                cwd=workspace,
                first_token_timeout=bounded_first,
                turn_timeout=bounded_turn,
                post_result_exit_grace=bounded_exit,
                read_chunk_bytes=64,
                max_queue_chunks=4,
                max_frame_bytes=MAX_PROMPT_BYTES,
                max_input_bytes=MAX_PROMPT_BYTES,
                max_events=32,
                max_malformed_stdout=16,
                max_stderr_lines=16,
                stdin_lines=prompts,
                raw_sink=sink,
                env=environment,
                cleanup_grace=0.5 if mode == "live" else 0.1,
            )
        finally:
            if pin is not None and wrapper_path is not None and binary_path is not None:
                _check_pin(pin, wrapper_path, binary_path)
    finally:
        for handle in handles.values():
            handle.close()

    git_after = _git_snapshot(repository_root)
    code_after = _code_provenance()
    if git_after != git_before or code_after != code_before:
        raise CaptureError("tracked git tree or executing evidence code changed during capture")

    provenance: dict[str, Any] = {
        "code_before": code_before,
        "code_after": code_after,
        "runner_sha256": code_before["capture_runner_sha256"],
        "probe_sha256": code_before["probe_sha256"],
        "fake_fixture_sha256": code_before["fake_fixture_sha256"],
        "safe_wrapper_sha256": code_before["safe_wrapper_sha256"],
        "git_head": git_before["head"],
        "git_tree": git_before["tree"],
        "git_before": git_before,
        "git_after": git_after,
        "trusted_path_policy": {
            "name": "fixed-system-path-v1",
            "value": TRUSTED_SYSTEM_PATH,
        },
        "host": {"os": platform.system(), "kernel": platform.release(), "arch": platform.machine()},
        "passed_environment_names": environment_names,
        "raw_observed_bytes": counts,
    }
    if pin is not None:
        provenance["safe_wrapper"] = pin
    manifest = capture_dir / "raw-manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "schema": RAW_MANIFEST_SCHEMA,
                "started_at": started,
                "mode": mode,
                "command": _safe_command_label(mode, profile),
                "workspace": "<WORKSPACE>",
                "provenance": provenance,
                "protocol_policy": {
                    "first_event": "init",
                    "init_identity": "nonempty",
                    "identity": "stable",
                },
                "cleanup_policy": {
                    "absolute_deadline_after_final_escalation": True,
                    "bounded_reader_join": True,
                    "group_survival_is_failure": True,
                },
                "raw": {name: artifact(path) for name, path in raw.items()},
            },
            sort_keys=True,
            indent=2,
        )
        + "\n"
    )
    summary = _summary(result, workspace, raw, manifest, mode, provenance, started)
    summary["failure_reasons"] = failure_reasons(summary)
    summary["complete"] = not summary["failure_reasons"]
    (capture_dir / "redacted-summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
    return summary


def _bounded_argument(value: str | None, *, default: float, name: str, minimum: float, maximum: float) -> float:
    actual = default if value is None else float(value)
    if not math.isfinite(actual) or not minimum <= actual <= maximum:
        raise CaptureError(f"{name} deadline is outside safe bounds")
    return actual


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("fake", "live"), default="fake")
    parser.add_argument("--live-authorization")
    parser.add_argument("--profile", default="acc1")
    parser.add_argument("--prompts-file", type=Path)
    parser.add_argument("--capture-dir", type=Path)
    parser.add_argument("--first-token-timeout", type=float)
    parser.add_argument("--turn-timeout", type=float)
    parser.add_argument("--post-result-exit-grace", type=float)
    arguments = parser.parse_args(argv)
    try:
        if arguments.mode == "live" and arguments.live_authorization != LIVE_AUTHORIZATION:
            raise CaptureError("live mode requires a fresh owner authorization")
        root = REPOSITORY_ROOT / ".agy-captures"
        root.mkdir(mode=0o700, exist_ok=True)
        run_dir = arguments.capture_dir or Path(tempfile.mkdtemp(prefix="run-", dir=root))
        prompts = (
            fake_prompts()
            if arguments.mode == "fake"
            else parse_prompt_file(arguments.prompts_file)
            if arguments.prompts_file
            else (_ for _ in ()).throw(CaptureError("live mode requires --prompts-file"))
        )
        summary = run_capture(
            mode=arguments.mode,
            capture_dir=run_dir,
            prompts=prompts,
            profile=arguments.profile,
            wrapper=APPROVED_WRAPPER,
            first_token_timeout=arguments.first_token_timeout,
            turn_timeout=arguments.turn_timeout,
            post_result_exit_grace=arguments.post_result_exit_grace,
        )
    except (CaptureError, OSError, ValueError) as error:
        print(f"capture failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"mode": summary["mode"], "complete": summary["complete"], "failure_reasons": summary["failure_reasons"]}, sort_keys=True))
    return capture_exit_code(summary)


if __name__ == "__main__":
    raise SystemExit(main())
