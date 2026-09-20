"""JARVIS-901-only deterministic harness; it is not a Symphony runtime component."""

from __future__ import annotations

import json
import os
import queue
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


DEFAULT_ENV_NAMES = ("HOME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")
USAGE_FIELDS = ("input_tokens", "output_tokens", "thinking_tokens", "cache_read_tokens", "total_tokens")


class ProbeError(RuntimeError):
    """A deterministic pre-launch or process-lifecycle failure."""


def require_contained_workspace(workspace_root: Path, workspace: Path) -> Path:
    """Resolve a fixture workspace and reject paths outside the declared root."""
    root = workspace_root.resolve()
    candidate = workspace.resolve()
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise ProbeError("workspace escapes declared root") from error
    return candidate


def require_same_host(worker_host: str, executable_host: str) -> None:
    """Reject a launcher discovered on a host other than the worker host."""
    if worker_host != executable_host:
        raise ProbeError(
            f"worker host {worker_host!r} cannot launch executable on {executable_host!r}"
        )


class _TreeLifetime:
    """Own the complete fake-process tree even if its root exits before inherited pipes close."""

    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        self.process = process
        self.pgid = process.pid
        self.job: Any = None
        self.kernel32: Any = None
        if os.name == "nt":
            self._create_windows_job()

    def _create_windows_job(self) -> None:
        import ctypes
        from ctypes import wintypes

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in (
                "ReadOperationCount",
                "WriteOperationCount",
                "OtherOperationCount",
                "ReadTransferCount",
                "WriteTransferCount",
                "OtherTransferCount",
            )]

        class BasicLimitInformation(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class ExtendedLimitInformation(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BasicLimitInformation),
                ("IoInfo", IoCounters),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateJobObjectW.argtypes = (wintypes.LPVOID, wintypes.LPCWSTR)
        kernel32.CreateJobObjectW.restype = wintypes.HANDLE
        kernel32.SetInformationJobObject.argtypes = (
            wintypes.HANDLE,
            ctypes.c_int,
            wintypes.LPVOID,
            wintypes.DWORD,
        )
        kernel32.SetInformationJobObject.restype = wintypes.BOOL
        kernel32.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
        kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel32.TerminateJobObject.argtypes = (wintypes.HANDLE, wintypes.UINT)
        kernel32.TerminateJobObject.restype = wintypes.BOOL
        kernel32.CreateToolhelp32Snapshot.argtypes = (wintypes.DWORD, wintypes.DWORD)
        kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        kernel32.Thread32First.argtypes = (wintypes.HANDLE, wintypes.LPVOID)
        kernel32.Thread32First.restype = wintypes.BOOL
        kernel32.Thread32Next.argtypes = (wintypes.HANDLE, wintypes.LPVOID)
        kernel32.Thread32Next.restype = wintypes.BOOL
        kernel32.OpenThread.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel32.OpenThread.restype = wintypes.HANDLE
        kernel32.ResumeThread.argtypes = (wintypes.HANDLE,)
        kernel32.ResumeThread.restype = wintypes.DWORD
        kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
        kernel32.CloseHandle.restype = wintypes.BOOL

        job = kernel32.CreateJobObjectW(None, None)
        if not job:
            raise ProbeError(f"could not create Windows process-tree job: {ctypes.get_last_error()}")
        info = ExtendedLimitInformation()
        info.BasicLimitInformation.LimitFlags = 0x00002000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):
            error = ctypes.get_last_error()
            kernel32.CloseHandle(job)
            raise ProbeError(f"could not configure Windows process-tree job: {error}")
        if not kernel32.AssignProcessToJobObject(job, self.process._handle):
            error = ctypes.get_last_error()
            kernel32.CloseHandle(job)
            raise ProbeError(f"could not retain Windows process tree: {error}")
        self.kernel32 = kernel32
        self.job = (kernel32, job)

    def resume_root(self) -> None:
        if self.job is None:
            return
        import ctypes
        from ctypes import wintypes

        class ThreadEntry32(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ThreadID", wintypes.DWORD),
                ("th32OwnerProcessID", wintypes.DWORD),
                ("tpBasePri", ctypes.c_long),
                ("tpDeltaPri", ctypes.c_long),
                ("dwFlags", wintypes.DWORD),
            ]

        snapshot = self.kernel32.CreateToolhelp32Snapshot(0x00000004, 0)
        if snapshot == ctypes.c_void_p(-1).value:
            raise ProbeError(f"could not enumerate suspended root thread: {ctypes.get_last_error()}")
        entry = ThreadEntry32()
        entry.dwSize = ctypes.sizeof(entry)
        try:
            found = self.kernel32.Thread32First(snapshot, ctypes.byref(entry))
            while found:
                if entry.th32OwnerProcessID == self.process.pid:
                    thread = self.kernel32.OpenThread(0x0002, False, entry.th32ThreadID)
                    if not thread:
                        raise ProbeError(f"could not open suspended root thread: {ctypes.get_last_error()}")
                    try:
                        if self.kernel32.ResumeThread(thread) == 0xFFFFFFFF:
                            raise ProbeError(f"could not resume retained root process: {ctypes.get_last_error()}")
                        return
                    finally:
                        self.kernel32.CloseHandle(thread)
                found = self.kernel32.Thread32Next(snapshot, ctypes.byref(entry))
        finally:
            self.kernel32.CloseHandle(snapshot)
        raise ProbeError("could not find suspended root thread")

    def send(self, signum: int) -> None:
        if self.job is not None:
            import ctypes

            kernel32, job = self.job
            if not kernel32.TerminateJobObject(job, 1):
                raise ProbeError(f"could not terminate Windows process tree: {ctypes.get_last_error()}")
            return
        try:
            os.killpg(self.pgid, signum)
        except ProcessLookupError:
            pass

    def process_group_empty(self) -> bool | None:
        if self.job is not None:
            return None
        try:
            os.killpg(self.pgid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        return False

    def close(self) -> None:
        if self.job is not None:
            kernel32, job = self.job
            kernel32.CloseHandle(job)
            self.job = None


@dataclass
class RunResult:
    events: list[dict[str, Any]] = field(default_factory=list)
    malformed_stdout: list[str] = field(default_factory=list)
    stderr_lines: list[str] = field(default_factory=list)
    returncode: int | None = None
    timed_out: str | None = None
    exit_outcome: str | None = None
    process_loss: bool = False
    interrupted: bool = False
    pid: int | None = None
    pgid: int | None = None
    signals: list[str] = field(default_factory=list)
    process_group_empty: bool | None = None
    cleanup_failed: bool = False
    expected_turns: int = 0
    completed_turns: int = 0
    invalid_terminal_results: int = 0
    init_events: int = 0
    invalid_session_events: int = 0
    observed_bytes: dict[str, int] = field(default_factory=lambda: {"stdin": 0, "stdout": 0, "stderr": 0})
    dropped_events: int = 0
    dropped_malformed_stdout: int = 0
    dropped_stderr_lines: int = 0
    truncated_stdout_frames: int = 0
    truncated_stderr_frames: int = 0


def _signal_process(process: subprocess.Popen[bytes]) -> str:
    if os.name == "nt" and hasattr(signal, "CTRL_BREAK_EVENT"):
        process.send_signal(signal.CTRL_BREAK_EVENT)
        return "CTRL_BREAK_EVENT"
    process.send_signal(signal.SIGINT)
    return "SIGINT"


def _bounded_append(items: list[Any], item: Any, maximum: int) -> bool:
    """Keep the newest bounded evidence and report whether one retained item was dropped."""
    if len(items) >= maximum:
        items.pop(0)
        items.append(item)
        return True
    items.append(item)
    return False


TERMINAL_STATUSES = frozenset({"SUCCESS", "ERROR", "CANCELED", "INTERRUPTED", "INVALID", "WAITING", "RUNNING"})


def _usage(payload: Mapping[str, Any], previous: Mapping[str, int] | None) -> dict[str, int] | None:
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        return None
    values: dict[str, int] = {}
    for name in USAGE_FIELDS:
        value = usage.get(name)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        values[name] = value
    if previous is not None and any(values[name] < previous[name] for name in USAGE_FIELDS):
        return None
    return values


def _valid_terminal(
    payload: object,
    *,
    expected_turn: int,
    previous_usage: Mapping[str, int] | None,
    identity: str | None,
) -> dict[str, int] | None:
    if not isinstance(payload, dict) or payload.get("status") not in TERMINAL_STATUSES:
        return None
    turns = payload.get("num_turns")
    if not isinstance(turns, int) or isinstance(turns, bool) or turns != expected_turn:
        return None
    if not isinstance(payload.get("conversation_id"), str) or payload["conversation_id"] != identity:
        return None
    return _usage(payload, previous_usage)


def run_fixture(
    command: Sequence[str],
    *,
    cwd: Path,
    first_token_timeout: float,
    turn_timeout: float,
    post_result_exit_grace: float = 0.1,
    cancel_after: float | None = None,
    read_chunk_bytes: int = 256,
    max_queue_chunks: int = 8,
    max_frame_bytes: int = 1024,
    max_input_bytes: int = 4096,
    max_events: int = 64,
    max_malformed_stdout: int = 32,
    max_stderr_lines: int = 32,
    stdin_lines: Sequence[bytes] = (),
    raw_sink: Callable[[str, bytes], None] | None = None,
    env: Mapping[str, str] | None = None,
    cleanup_grace: float = 0.2,
) -> RunResult:
    """Run a bounded NDJSON process with an explicit child environment.

    Interactive input is written one capped line at a time. A new line is not written until the
    preceding validated terminal result has been consumed. POSIX children own a fresh process
    group; Windows children are retained by a kill-on-close Job Object.
    """
    if min(
        read_chunk_bytes,
        max_queue_chunks,
        max_frame_bytes,
        max_input_bytes,
        max_events,
        max_malformed_stdout,
        max_stderr_lines,
    ) < 1 or min(first_token_timeout, turn_timeout, post_result_exit_grace, cleanup_grace) <= 0:
        raise ValueError("probe limits and deadlines must be positive")

    input_lines = list(stdin_lines)
    result = RunResult(expected_turns=len(input_lines))
    effective_env = dict(env) if env is not None else {name: os.environ[name] for name in DEFAULT_ENV_NAMES if name in os.environ}
    process_kwargs: dict[str, Any] = {"env": effective_env}
    if os.name == "nt":
        process_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | 0x00000004
    else:
        process_kwargs["start_new_session"] = True

    process = subprocess.Popen(
        list(command),
        cwd=cwd,
        stdin=subprocess.PIPE if input_lines else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **process_kwargs,
    )
    assert process.stdout is not None and process.stderr is not None
    result.pid = process.pid
    if os.name != "nt":
        try:
            result.pgid = os.getpgid(process.pid)
        except ProcessLookupError:
            result.pgid = process.pid
    try:
        tree = _TreeLifetime(process)
        tree.resume_root()
    except Exception:
        process.kill()
        process.wait(timeout=0.2)
        raise

    received: queue.Queue[tuple[str, bytes | None]] = queue.Queue(maxsize=max_queue_chunks)
    stop_readers = threading.Event()

    def enqueue(name: str, chunk: bytes | None) -> None:
        while not stop_readers.is_set():
            try:
                received.put((name, chunk), timeout=0.01)
                return
            except queue.Full:
                pass

    def read_stream(name: str, stream: Any) -> None:
        try:
            while not stop_readers.is_set() and (chunk := stream.read1(read_chunk_bytes)):
                result.observed_bytes[name] += len(chunk)
                if raw_sink is not None:
                    raw_sink(name, chunk)
                enqueue(name, chunk)
        except (OSError, ValueError):
            pass
        finally:
            enqueue(name, None)

    readers = [
        threading.Thread(target=read_stream, args=("stdout", process.stdout), daemon=True),
        threading.Thread(target=read_stream, args=("stderr", process.stderr), daemon=True),
    ]
    for reader in readers:
        reader.start()

    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    discarding = {"stdout": False, "stderr": False}
    streams_closed: set[str] = set()
    started = time.monotonic()
    turn_started_at = started
    first_token_seen = False
    terminal_at: float | None = None
    submitted_turns = 0
    advanced_turns = 0
    input_closed = not input_lines
    stop_started_at: float | None = None
    stop_reason: str | None = None
    escalation_stage = 0
    session_initialized = False
    session_identity: str | None = None
    previous_usage: dict[str, int] | None = None

    def send_named(name: str) -> None:
        nonlocal escalation_stage
        try:
            if name == "SIGINT":
                if os.name == "nt":
                    actual = _signal_process(process)
                else:
                    tree.send(signal.SIGINT)
                    actual = name
            elif name == "SIGTERM":
                tree.send(signal.SIGTERM)
                actual = name
            elif name == "SIGKILL":
                tree.send(signal.SIGKILL)
                actual = name
            else:
                raise ProbeError(f"unknown process signal {name}")
            result.signals.append(actual)
            escalation_stage += 1
        except (OSError, ProcessLookupError, ProbeError):
            result.cleanup_failed = True

    def request_stop(reason: str, initial_signal: str) -> None:
        nonlocal stop_started_at, stop_reason
        if stop_started_at is not None:
            return
        stop_reason = reason
        if reason in {"first-token", "turn", "write"}:
            result.timed_out = reason
        stop_started_at = time.monotonic()
        send_named(initial_signal)

    def close_input() -> None:
        nonlocal input_closed
        if input_closed or process.stdin is None:
            return
        try:
            process.stdin.close()
        except OSError:
            result.cleanup_failed = True
        input_closed = True

    def begin_turn(line: bytes) -> None:
        nonlocal turn_started_at, first_token_seen, terminal_at, submitted_turns
        if len(line) > max_input_bytes:
            request_stop("write", "SIGTERM")
            return
        turn_started_at = time.monotonic()
        first_token_seen = False
        terminal_at = None
        submitted_turns += 1
        result.observed_bytes["stdin"] += len(line)
        if raw_sink is not None:
            raw_sink("stdin", line)
        assert process.stdin is not None
        completed = threading.Event()
        error: list[BaseException] = []

        def write() -> None:
            try:
                process.stdin.write(line)
                process.stdin.flush()
            except BaseException as exc:  # communicate failure to the bounded writer join
                error.append(exc)
            finally:
                completed.set()

        writer = threading.Thread(target=write, daemon=True)
        writer.start()
        writer.join(timeout=max(0.0, turn_timeout - (time.monotonic() - turn_started_at)))
        if not completed.is_set():
            request_stop("write", "SIGTERM")
        elif error:
            request_stop("write", "SIGTERM")

    def maybe_advance_turn() -> None:
        nonlocal advanced_turns
        if not input_lines or result.completed_turns <= advanced_turns:
            return
        if result.completed_turns != submitted_turns:
            result.invalid_terminal_results += 1
            return
        advanced_turns = result.completed_turns
        if advanced_turns < len(input_lines):
            begin_turn(input_lines[advanced_turns])
        else:
            close_input()

    def consume_line(name: str, line: bytes) -> None:
        nonlocal first_token_seen, terminal_at, session_initialized, session_identity, previous_usage
        normalized = line[:-1] if line.endswith(b"\r") else line
        text = normalized.decode("utf-8", errors="replace")
        if name == "stderr":
            if text and _bounded_append(result.stderr_lines, text, max_stderr_lines):
                result.dropped_stderr_lines += 1
            return
        if not text:
            return
        try:
            event = json.loads(text)
        except json.JSONDecodeError:
            if _bounded_append(result.malformed_stdout, text, max_malformed_stdout):
                result.dropped_malformed_stdout += 1
            return
        if not isinstance(event, dict):
            if _bounded_append(result.malformed_stdout, text, max_malformed_stdout):
                result.dropped_malformed_stdout += 1
            return
        if _bounded_append(result.events, event, max_events):
            result.dropped_events += 1
        step = event.get("step_update")
        payload = event.get("result")
        identities = [
            value
            for value in (
                event.get("conversation_id"),
                step.get("conversation_id") if isinstance(step, dict) else None,
                payload.get("conversation_id") if isinstance(payload, dict) else None,
            )
            if isinstance(value, str) and value
        ]
        for identity in identities:
            if session_identity is None:
                session_identity = identity
            elif identity != session_identity:
                result.invalid_session_events += 1
        if isinstance(step, dict) and isinstance(step.get("text_delta"), str) and step["text_delta"]:
            first_token_seen = True
        if event.get("event") == "init":
            result.init_events += 1
            if result.init_events != 1 or not session_identity:
                result.invalid_session_events += 1
            else:
                session_initialized = True
            return
        if payload is not None:
            expected_turn = submitted_turns if input_lines else result.completed_turns + 1
            usage = (
                _valid_terminal(
                    payload,
                    expected_turn=expected_turn,
                    previous_usage=previous_usage,
                    identity=session_identity,
                )
                if event.get("event") == "result" and session_initialized
                else None
            )
            if usage is None:
                result.invalid_terminal_results += 1
            else:
                result.completed_turns += 1
                previous_usage = usage
                terminal_at = time.monotonic()
                maybe_advance_turn()

    def count_truncation(name: str) -> None:
        if name == "stdout":
            result.truncated_stdout_frames += 1
        else:
            result.truncated_stderr_frames += 1

    def consume_chunk(name: str, chunk: bytes) -> None:
        while chunk:
            if discarding[name]:
                newline = chunk.find(b"\n")
                if newline < 0:
                    return
                discarding[name] = False
                chunk = chunk[newline + 1 :]
                continue
            newline = chunk.find(b"\n")
            segment = chunk if newline < 0 else chunk[:newline]
            if len(buffers[name]) + len(segment) > max_frame_bytes:
                buffers[name].clear()
                discarding[name] = True
                count_truncation(name)
                if newline < 0:
                    return
                discarding[name] = False
                chunk = chunk[newline + 1 :]
                continue
            buffers[name].extend(segment)
            if newline < 0:
                return
            consume_line(name, bytes(buffers[name]))
            buffers[name].clear()
            chunk = chunk[newline + 1 :]

    if input_lines:
        begin_turn(input_lines[0])

    while True:
        now = time.monotonic()
        if cancel_after is not None and not result.interrupted and now - started >= cancel_after:
            result.interrupted = True
            send_named("SIGINT")
            stop_started_at = now
            stop_reason = "cancel"

        if stop_started_at is None:
            if input_lines and result.completed_turns < submitted_turns:
                elapsed = now - turn_started_at
                if not first_token_seen and elapsed >= first_token_timeout:
                    request_stop("first-token", "SIGTERM")
                elif elapsed >= turn_timeout:
                    request_stop("turn", "SIGTERM")
            elif terminal_at is None and not first_token_seen and now - started >= first_token_timeout:
                request_stop("first-token", "SIGTERM")
            elif terminal_at is None and now - started >= turn_timeout:
                request_stop("turn", "SIGTERM")
            elif terminal_at is not None and now - terminal_at >= post_result_exit_grace:
                result.exit_outcome = "cancel-exit" if result.interrupted else "post-result-exit"
                request_stop("post-result-exit", "SIGTERM")
        elif tree.process_group_empty() is False:
            elapsed = now - stop_started_at
            if escalation_stage == 1 and elapsed >= cleanup_grace:
                send_named("SIGKILL" if result.signals[-1] == "SIGTERM" else "SIGTERM")
            elif escalation_stage == 2 and elapsed >= cleanup_grace * 2:
                send_named("SIGKILL")

        try:
            name, chunk = received.get(timeout=0.01)
        except queue.Empty:
            if process.poll() is not None and streams_closed == {"stdout", "stderr"} and tree.process_group_empty() is not False:
                break
            if (
                stop_started_at is not None
                and now - stop_started_at >= cleanup_grace * 3
                and tree.process_group_empty() is not False
            ):
                break
            continue
        if chunk is None:
            streams_closed.add(name)
            if buffers[name] and not discarding[name]:
                consume_line(name, bytes(buffers[name]))
                buffers[name].clear()
            continue
        consume_chunk(name, chunk)

    if process.poll() is None:
        request_stop("cleanup", "SIGTERM")
    if tree.process_group_empty() is False:
        send_named("SIGKILL")
        deadline = time.monotonic() + cleanup_grace
        while tree.process_group_empty() is False and time.monotonic() < deadline:
            time.sleep(0.01)
    try:
        result.returncode = process.wait(timeout=max(0.2, cleanup_grace))
    except subprocess.TimeoutExpired:
        result.cleanup_failed = True
        try:
            process.kill()
            result.returncode = process.wait(timeout=0.2)
        except (OSError, subprocess.TimeoutExpired):
            result.returncode = None
    close_input()
    stop_readers.set()
    for reader in readers:
        reader.join(timeout=0.1)
    if not any(reader.is_alive() for reader in readers):
        for stream in (process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass
    if result.init_events != 1:
        result.invalid_session_events += 1
    if result.expected_turns and result.completed_turns < result.expected_turns:
        result.process_loss = result.timed_out is None
    elif not result.expected_turns and result.completed_turns == 0 and result.timed_out is None:
        result.process_loss = True
    result.process_group_empty = tree.process_group_empty()
    if result.process_group_empty is False:
        result.cleanup_failed = True
    if result.process_loss and result.exit_outcome is None:
        result.exit_outcome = "process-loss"
    if result.cleanup_failed and result.exit_outcome is None:
        result.exit_outcome = "cleanup-failure"
    tree.close()
    return result
