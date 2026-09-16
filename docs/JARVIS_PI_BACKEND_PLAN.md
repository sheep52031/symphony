# Jarvis thin Pi backend plan

Status: first local feasibility spike implemented; live acceptance still blocked by baseline validation gaps

This fork stays close to `openai/symphony`. It adds a removable Pi execution path without replacing
Symphony's tracker, workspace, polling, retry, reconciliation, concurrency, lifecycle, or
observability responsibilities.

## Baseline and lineage

- Fork: `sheep52031/symphony`
- Upstream: `openai/symphony`
- Baseline: `be10a1b79df723d6d7612b5651c8522704dafb2e` (`main`, currently identical to upstream)
- Working branch: `jarvis/symphony-pi-backends`
- Current Jarvis runtime pin: Symphony Elixir `v0.0.2`, commit `653f8b3cc476db03420479ba6f95b2ed7281c401`
- Jarvis-specific tracker and prompt policy remains in the separate `jarvis-next` checkout. This
  fork's generic `elixir/WORKFLOW.md` must not acquire Jarvis-private project identifiers or
  credentials.
- WSL validation is available through `mise` with Elixir `1.19.5` / OTP `28`. The full upstream
  suite on this branch reports `308 tests, 49 failures, 6 skipped`; a clean upstream baseline
  reports `299 tests, 47 failures, 6 skipped`. The branch-only two failures are timing-sensitive
  retry assertions in this WSL run; the remaining failures are the known WSL/Windows
  fake-process, SSH, snapshot, and timing-fixture mismatch. All new Pi tests pass. This is not
  treated as a green regression result or as live acceptance evidence.

## Cross-device execution contract

Symphony is expected to be hosted by Windows through WSL2, while Jarvis infrastructure and future
PiAgent use also include macOS. The backend therefore follows these host rules:

- Windows runtime validation runs inside WSL2. The Symphony BEAM, `bash -lc`, workspace, Node
  runtime, and Pi process must be observed from the same WSL environment; invoking a Windows `pi.cmd`
  as if it were a native Linux process is not the acceptance path.
- `pi.command` is executed by non-interactive `bash -lc`, not by an interactive shell. A host-specific
  absolute launcher is preferred when shell profile PATH is not inherited. It must point at a Node
  runtime supported by the installed PiAgent package and keep its session directory under the host's
  Developer root.
- On the authorized M2 Air, PiAgent `@earendil-works/pi-coding-agent@0.85.1` is installed under
  `/Users/jason/Developer/Tools/pi-agent`; its launcher uses the Homebrew Node runtime explicitly.
  The existing older global Pi installation is left untouched.
- The Windows WSL2 smoke uses a separate exact-version PiAgent install under
  `/mnt/d/Developer/Tools/pi-agent-wsl` and an explicit Linux-Node launcher, avoiding dependence on
  Windows `pi.cmd` interop or an interactive shell profile.
- Pi remains local-worker-only in this slice. Cross-device access to the M2 Air is infrastructure
  validation, not a new Symphony remote worker transport; SSH workers remain an explicit error.

## Implemented first slice

- `SymphonyElixir.AgentBackend` resolves `codex` (default) and opt-in `pi` without changing the
  scheduler or tracker interfaces.
- `SymphonyElixir.Codex.AppServer` now implements the contract directly; its wire protocol and
  existing call sites remain unchanged.
- `SymphonyElixir.Pi.Rpc` provides strict stdout JSONL request correlation, partial-line buffering,
  CRLF tolerance, separate stderr capture, async event callbacks, unattended UI cancellation,
  completion predicates, timeout, and graceful abort support.
- `SymphonyElixir.Pi.Backend` performs `get_state`, `set_session_name`, `prompt` through
  `agent_settled`, `get_last_assistant_text`, and `get_session_stats`, with Pi-native event and
  usage mapping. It is explicitly local-only; configured SSH workers are rejected rather than
  silently claimed as supported.
- The orchestrator snapshots the selected backend into each new running attempt and passes that
  value to `AgentRunner`; an in-flight attempt does not follow a later workflow reload.
- `pi_rpc_test.exs` and `pi_backend_test.exs` use deterministic fake processes only. They do not
  call an LLM, mutate Linear, install Pi extensions, or replace the Jarvis runtime.
- Focused validation currently passes: `9 tests, 0 failures` for the Pi RPC/backend modules,
  including backend resolution, the `AgentRunner` opt-in path, and timeout-to-abort behavior.
- A real no-prompt Pi smoke through `SymphonyElixir.Pi.Rpc` successfully completed `get_state` in
  WSL2 and on the authorized M2 Air; no LLM prompt was sent.


## PR readiness

This first slice is suitable for a transparent draft PR for CI and review, but it is not
merge-ready. The clean upstream baseline has been measured separately; the full WSL2 suite still
has the known fake-process, SSH, snapshot, and timing-fixture failures noted above. The
cross-device no-prompt bootstrap is proven; a single-ticket LLM turn, orchestrator receipt
coverage, and acceptance/rollback evidence are still required before a non-draft merge candidate.

## Fixed boundaries

### Keep upstream behavior

- Linear/provider adapter and native tracker tools
- per-issue workspace isolation and hooks
- polling, claims, retry/backoff, reconciliation, terminal cleanup
- Codex App Server as the default execution path
- existing Codex tests and runtime configuration

### Add only the execution seam

Introduce a small `AgentBackend` contract implemented by:

- `Codex.AppServer` adapter: wraps the current behavior with no protocol change
- `Pi.Rpc` adapter: owns Pi-native JSONL process/session/turn behavior

A backend owns its process, native session state, event parsing, timeout/abort behavior, credential
boundary, and typed failures. The common contract must not pretend Pi, Codex, Claude, or another
Harness share a wire protocol.

The first configuration selector is `agent.backend`, defaulting to `codex`; `pi` is opt-in only.
A running attempt never changes backend mid-run.

## Delivery sequence

### 0. Baseline evidence

- Keep this branch based on the exact synced upstream main commit.
- Capture current Codex test and build status before backend changes.
- Do not replace the installed Jarvis runtime or start a live Linear dispatch.

### 1. Pi RPC feasibility spike — implemented locally

Implement the smallest isolated Pi RPC client/test seam as an independently testable lower layer; it
must not make the scheduler or tracker speak the Pi protocol:

- spawn a configured command in the issue workspace
- send LF-terminated JSON commands with request IDs
- buffer partial lines and accept CRLF while treating only LF as the delimiter
- parse stdout protocol only and keep stderr as diagnostics
- correlate responses while forwarding asynchronous events
- classify `agent_start`, `agent_end`, `agent_settled`, `turn_*`, tool events, and failures
- auto-cancel unattended dialog UI requests; record fire-and-forget UI events
- exercise `get_state`, `set_session_name`, `prompt`, `abort`, and a bounded completion path
- prove timeout, graceful abort, and forced process termination behavior

The spike must use a fake Pi process for deterministic tests and one no-prompt real Pi smoke when
available. It must not make an LLM call, mutate Linear, install extensions, or write to shared user
sessions.

### 2. Backend integration — first slice started

The resolver, `agent.backend: codex|pi` validation, `AgentRunner` session/turn selection, and
Pi-to-existing-update mapping are now present. Remaining integration work is intentionally
bounded:

- establish a green Codex regression baseline in a supported native environment
- add orchestrator-level coverage for backend identity, error, timeout, and cancellation receipts
- make proof/session summary fields durable at the worker boundary without making the orchestrator
  Pi-aware
- decide the upstream-sync and release pin procedure before any live use

### 3. Single-ticket acceptance

Use one disposable, explicitly authorized Linear ticket and one worker only:

- exact issue/workspace/branch identity
- no auto-merge and stop at Human Review
- Codex baseline regression remains green
- Pi worker proof includes event stream, session identity, final text, stats, stderr tail, and
  timeout/abort outcome
- verify single-writer behavior and rollback to `agent.backend: codex`

## Non-goals

- no second scheduler, queue, control plane, tracker replica, or retry/reviewer controller
- no provider model registry or credential broker
- no automatic DeepSeek backend; DSH remains explicit single-ticket takeover only
- no Eureka code or MemoryBank/Cognee code in this repository
- no Pi-specific PR/merge/dashboard automation copied from `tmustier/pi-symphony`
- no automatic merge, release, or live runtime replacement in the feasibility phase

## Acceptance gates

1. The branch can be rebased/synced from upstream without a broad conflict surface.
2. `agent.backend` omitted means current Codex behavior, with existing tests unchanged.
3. Pi RPC framing, event handling, UI policy, timeout, and abort behavior have deterministic tests.
4. A single Pi worker can execute one isolated issue only after explicit runtime authorization.
5. Every attempt records backend identity and a readable proof summary.
6. Rollback disables Pi selection without deleting its evidence or changing tracker state.
7. No claim of production readiness is made before live acceptance evidence exists.

## Evidence references

- [OpenAI Symphony](https://github.com/openai/symphony)
- [Pi RPC documentation](https://pi.dev/docs/latest/rpc)
- [Pi package directory](https://pi.dev/packages)
- [Pi Symphony reference](https://github.com/tmustier/pi-symphony)
- [Jarvis planning issue JARVIS-862](https://linear.app/luvinai/issue/JARVIS-862/規劃以薄-backend-branch-將-piagent-接入-elixir-symphony)
