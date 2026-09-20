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
from typing import Any, Callable, Sequence


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

    def stop(self) -> None:
        if self.job is not None:
            import ctypes

            kernel32, job = self.job
            if not kernel32.TerminateJobObject(job, 1):
                raise ProbeError(f"could not terminate Windows process tree: {ctypes.get_last_error()}")
            return
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        time.sleep(0.05)
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

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
    interrupted: bool = False
    dropped_events: int = 0
    dropped_malformed_stdout: int = 0
    dropped_stderr_lines: int = 0
    truncated_stdout_frames: int = 0
    truncated_stderr_frames: int = 0


def _interrupt(process: subprocess.Popen[bytes]) -> None:
    if os.name == "nt" and hasattr(signal, "CTRL_BREAK_EVENT"):
        process.send_signal(signal.CTRL_BREAK_EVENT)
    else:
        process.send_signal(signal.SIGINT)


def _bounded_append(items: list[Any], item: Any, maximum: int) -> bool:
    """Keep the newest bounded evidence and report whether one retained item was dropped."""
    if len(items) >= maximum:
        items.pop(0)
        items.append(item)
        return True
    items.append(item)
    return False


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
    max_events: int = 64,
    max_malformed_stdout: int = 32,
    max_stderr_lines: int = 32,
    stdin_lines: Sequence[bytes] = (),
    raw_sink: Callable[[str, bytes], None] | None = None,
) -> RunResult:
    """Run a fake headless process with bounded framing and absolute lifecycle deadlines.

    The fixture root is retained in a Windows kill-on-close Job Object or a POSIX process group.
    Reader backpressure bounds queued bytes. Only LF terminates a frame; an oversized unterminated
    frame is discarded through its next LF so later valid frames can be parsed.
    """
    if min(
        read_chunk_bytes,
        max_queue_chunks,
        max_frame_bytes,
        max_events,
        max_malformed_stdout,
        max_stderr_lines,
    ) < 1:
        raise ValueError("all probe evidence limits must be positive")

    process_kwargs: dict[str, Any] = {}
    if os.name == "nt":
        process_kwargs["creationflags"] = (
            subprocess.CREATE_NEW_PROCESS_GROUP | 0x00000004  # CREATE_SUSPENDED
        )
    else:
        process_kwargs["start_new_session"] = True

    process = subprocess.Popen(
        list(command),
        cwd=cwd,
        stdin=subprocess.PIPE if stdin_lines else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **process_kwargs,
    )
    assert process.stdout is not None
    assert process.stderr is not None
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
    if stdin_lines:
        assert process.stdin is not None
        for line in stdin_lines:
            if raw_sink is not None:
                raw_sink("stdin", line)
            process.stdin.write(line)
            process.stdin.flush()
        process.stdin.close()

    result = RunResult()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    discarding = {"stdout": False, "stderr": False}
    streams_closed: set[str] = set()
    started = time.monotonic()
    first_token_at: float | None = None
    terminal_at: float | None = None
    interrupted = False
    stop_started_at: float | None = None

    def consume_line(name: str, line: bytes) -> None:
        nonlocal first_token_at, terminal_at
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
        if isinstance(step, dict) and step.get("text_delta") and first_token_at is None:
            first_token_at = time.monotonic()
        if isinstance(event.get("result"), dict) and terminal_at is None:
            terminal_at = time.monotonic()

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

    while True:
        now = time.monotonic()
        if cancel_after is not None and not interrupted and now - started >= cancel_after:
            _interrupt(process)
            interrupted = True
            result.interrupted = True

        if stop_started_at is None and terminal_at is not None and now - terminal_at >= post_result_exit_grace:
            result.exit_outcome = "cancel-exit" if interrupted else "post-result-exit"
            tree.stop()
            stop_started_at = now
        elif stop_started_at is None and terminal_at is None and first_token_at is None and now - started >= first_token_timeout:
            result.timed_out = "first-token"
            tree.stop()
            stop_started_at = now
        elif stop_started_at is None and terminal_at is None and now - started >= turn_timeout:
            result.timed_out = "turn"
            tree.stop()
            stop_started_at = now

        try:
            name, chunk = received.get(timeout=0.01)
        except queue.Empty:
            if process.poll() is not None and streams_closed == {"stdout", "stderr"}:
                break
            if stop_started_at is not None and now - stop_started_at >= 1.0:
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
        tree.stop()
    try:
        result.returncode = process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        process.kill()
        result.returncode = process.wait(timeout=0.2)
    stop_readers.set()
    for reader in readers:
        reader.join(timeout=0.1)
    if not any(reader.is_alive() for reader in readers):
        for stream in (process.stdout, process.stderr):
            try:
                stream.close()
            except OSError:
                pass
    tree.close()
    return result
