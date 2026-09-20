#!/usr/bin/env python3
"""Deterministic fake process for the JARVIS-901 probe; it never contacts a provider."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


CONVERSATION_ID = "fixture-conversation-001"
USAGE = {
    "input_tokens": 10,
    "output_tokens": 2,
    "thinking_tokens": 1,
    "cache_read_tokens": 0,
    "total_tokens": 13,
}


def emit(value: object, *, fragment: bool = False, crlf: bool = False) -> None:
    data = json.dumps(value, separators=(",", ":")).encode() + (b"\r\n" if crlf else b"\n")
    if fragment:
        midpoint = len(data) // 2
        sys.stdout.buffer.write(data[:midpoint])
        sys.stdout.buffer.flush()
        time.sleep(0.02)
        sys.stdout.buffer.write(data[midpoint:])
    else:
        sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def init() -> dict[str, object]:
    return {
        "event": "init",
        "conversation_id": CONVERSATION_ID,
        "init": {"cwd": str(Path.cwd()), "permission_mode": "request-review"},
    }


def result(status: str, *, turns: int, response: str = "", error: str | None = None) -> dict[str, object]:
    payload: dict[str, object] = {
        "conversation_id": CONVERSATION_ID,
        "status": status,
        "response": response,
        "duration_seconds": 0.02,
        "num_turns": turns,
        "usage": USAGE,
    }
    if error is not None:
        payload["error"] = error
    return {"event": "result", "result": payload}


def canceled(_signum: int, _frame: object) -> None:
    emit(result("CANCELED", turns=1, error="fixture interrupted"))
    raise SystemExit(130)


def main(scenario: str) -> int:
    if scenario == "environment":
        emit(init())
        emit(result("SUCCESS", turns=1, response=json.dumps(sorted(os.environ))))
        return 0

    if scenario == "path-helper":
        emit(init())
        try:
            subprocess.run(["jarvis-901-path-helper"], check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            emit(result("SUCCESS", turns=1, response="trusted-path-not-user-helper"))
            return 0
        emit(result("ERROR", turns=1, error="untrusted PATH helper executed"))
        return 3

    if scenario == "interactive-multi-turn":
        turns = 0
        for line in sys.stdin.buffer:
            message = json.loads(line)
            if message.get("event") != "user":
                emit(result("ERROR", turns=turns, error="fixture expected user envelope"))
                return 2
            if turns == 0:
                emit(init(), fragment=True)
            turns += 1
            emit(
                {
                    "event": "step_update",
                    "step_update": {
                        "conversation_id": CONVERSATION_ID,
                        "state": "DONE",
                        "step_type": "agent_response",
                        "text_delta": f"fixture turn {turns}",
                    },
                },
                fragment=True,
            )
            emit(result("SUCCESS", turns=turns, response=f"fixture turn {turns}"))
        return 0

    if scenario == "ignore-signals":
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        emit(init())
        while True:
            time.sleep(0.02)

    if scenario == "partial-crlf":
        emit(init(), fragment=True, crlf=True)
        sys.stdout.buffer.write(b'{"event":\r\n')
        sys.stdout.buffer.flush()
        emit(
            {
                "event": "step_update",
                "step_update": {
                    "conversation_id": CONVERSATION_ID,
                    "state": "ACTIVE",
                    "step_type": "agent_response",
                    "text_delta": "hel",
                },
            },
            fragment=True,
        )
        emit(result("SUCCESS", turns=1, response="hello"), crlf=True)
        sys.stderr.buffer.write(b"fixture diagnostic\r\n")
        sys.stderr.buffer.flush()
        return 0

    if scenario == "nonzero-error":
        emit(init())
        emit(result("ERROR", turns=1, error="fixture failure"))
        sys.stderr.buffer.write(b"fixture error diagnostic\n")
        sys.stderr.buffer.flush()
        return 2

    if scenario == "two-result-transcript":
        emit(init())
        emit(result("SUCCESS", turns=1, response="first"))
        emit(
            {
                "event": "step_update",
                "step_update": {
                    "conversation_id": CONVERSATION_ID,
                    "state": "DONE",
                    "step_type": "agent_response",
                    "text_delta": "second",
                    "usage": USAGE,
                },
            }
        )
        emit(result("SUCCESS", turns=2, response="second"))
        return 0

    if scenario == "duplicate-result":
        emit(init())
        emit(result("SUCCESS", turns=1, response="first"))
        emit(result("SUCCESS", turns=1, response="duplicate"))
        return 0

    if scenario == "out-of-order-result":
        emit(init())
        emit(result("SUCCESS", turns=2, response="out of order"))
        return 0

    if scenario == "noncumulative-usage":
        emit(init())
        emit(result("SUCCESS", turns=1, response="first"))
        lower_usage = {name: value for name, value in USAGE.items()}
        lower_usage["input_tokens"] = 1
        emit({"event": "result", "result": {**result("SUCCESS", turns=2)["result"], "usage": lower_usage}})
        return 0

    if scenario == "malformed-usage":
        emit(init())
        malformed = {name: value for name, value in USAGE.items()}
        malformed["output_tokens"] = "two"
        emit({"event": "result", "result": {**result("SUCCESS", turns=1)["result"], "usage": malformed}})
        return 0

    if scenario == "permission-waiting":
        emit(init())
        emit(result("WAITING", turns=1, error="permission requires input"))
        sys.stderr.buffer.write(b"permission notice: request review\n")
        sys.stderr.buffer.flush()
        return 0

    if scenario == "chatter":
        emit(init())
        while True:
            sys.stdout.write("progress chatter\n")
            sys.stdout.flush()
            time.sleep(0.02)

    if scenario == "first-token-stall":
        emit(init())
        emit(
            {
                "event": "step_update",
                "step_update": {
                    "conversation_id": CONVERSATION_ID,
                    "state": "ACTIVE",
                    "step_type": "agent_response",
                    "text_delta": "one token",
                },
            }
        )
        while True:
            time.sleep(0.02)

    if scenario == "cancel-race":
        signal.signal(signal.SIGINT, canceled)
        if hasattr(signal, "SIGBREAK"):
            signal.signal(signal.SIGBREAK, canceled)
        emit(init())
        emit(
            {
                "event": "step_update",
                "step_update": {
                    "conversation_id": CONVERSATION_ID,
                    "state": "ACTIVE",
                    "step_type": "agent_response",
                    "text_delta": "started",
                },
            }
        )
        while True:
            time.sleep(0.02)

    if scenario == "result-then-hang":
        emit(init())
        emit(result("SUCCESS", turns=1, response="complete"))
        while True:
            time.sleep(0.02)

    if scenario == "exited-parent-pipe-holder":
        emit(init())
        emit(result("SUCCESS", turns=1, response="parent exited"))
        subprocess.Popen(
            [sys.executable, __file__, "pipe-holder"],
            stdin=subprocess.DEVNULL,
            stdout=sys.stdout,
            stderr=sys.stderr,
            close_fds=False,
        )
        return 0

    if scenario == "parent-exits-term-ignoring-descendant":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        emit(init())
        emit(result("SUCCESS", turns=1, response="parent exited"))
        child = subprocess.Popen(
            [sys.executable, __file__, "term-ignoring-descendant"],
            cwd=Path.cwd(),
            stdin=subprocess.DEVNULL,
            stdout=sys.stdout,
            stderr=sys.stderr,
            close_fds=False,
        )
        (Path.cwd() / ".descendant.pid").write_text(str(child.pid) + "\n")
        deadline = time.monotonic() + 1.0
        while not (Path.cwd() / ".descendant-ready").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        return 0

    if scenario == "term-ignoring-descendant":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        (Path.cwd() / ".descendant-ready").write_text("ready\n")
        while True:
            time.sleep(0.02)

    if scenario == "pipe-holder":
        while True:
            time.sleep(0.02)

    if scenario == "high-volume":
        emit(init())
        for index in range(24):
            emit(
                {
                    "event": "step_update",
                    "step_update": {
                        "conversation_id": CONVERSATION_ID,
                        "state": "ACTIVE",
                        "step_type": "agent_response",
                        "text_delta": str(index),
                    },
                }
            )
            sys.stdout.write("malformed chatter\n")
            sys.stdout.flush()
            sys.stderr.buffer.write(b"stderr chatter\n")
        sys.stderr.buffer.flush()
        emit(result("SUCCESS", turns=1, response="complete"))
        return 0

    if scenario == "oversized-output":
        emit(init())
        sys.stdout.buffer.write(b"x" * 4096 + b"\n")
        sys.stderr.buffer.write(b"y" * 4096 + b"\n")
        sys.stdout.buffer.flush()
        sys.stderr.buffer.flush()
        emit(result("SUCCESS", turns=1, response="after oversized frames"))
        return 0

    if scenario == "process-loss":
        emit(init())
        sys.stdout.flush()
        os._exit(17)

    if scenario == "cwd":
        emit(init())
        emit(result("SUCCESS", turns=1, response="cwd"))
        return 0

    raise SystemExit(f"unknown fixture scenario: {scenario}")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
