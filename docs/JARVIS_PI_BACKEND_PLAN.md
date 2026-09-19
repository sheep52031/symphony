# Jarvis thin Pi backend plan

Status: JARVIS-910 preservation baseline.

This owner-fork document describes fork behavior only; it does not claim that official
`openai/symphony` implements Pi. Codex remains the default and rollback backend. Pi is a retained,
explicit, local-only opt-in backend.

## Baseline and scope

- Accepted fork base: `da5fcf7b1d083b723ec08cae942563fc16b783d3`
  (`f387c34005eb88b17cd717b9862ec14cb18e378d`)
- Official comparison pin: `be10a1b79df723d6d7612b5651c8522704dafb2e`
  (`6e0ae271f586a5855082a52329d34355cad634fd`)
- Pi selection is a closed `AgentBackend` mapping. `agent.backend` defaults to `codex`; `pi` must
  be selected explicitly for a new attempt. There is no arbitrary module selection, per-ticket
  routing, mid-attempt backend switch, or silent fallback.
- Symphony alone owns polling, claims, workspaces, retries, reconciliation, status projection, and
  cleanup. Backends own process/session/protocol behavior only.

## Retained Pi capability

`SymphonyElixir.Pi.Rpc` is the strict JSONL transport for a local Pi process. It correlates
responses, retains stderr separately, forwards native events, cancels unattended dialog UI
requests, observes fire-and-forget UI requests, supports completion predicates, and permits a
bounded abort request.

`SymphonyElixir.Pi.Backend` starts Pi in the existing issue workspace, initializes its native
session with `get_state`, preserves that session for continuation turns, sets the session name,
waits for authoritative `agent_settled`, and collects final text and session statistics. It emits
neutral lifecycle/session/runtime/usage evidence for AgentRunner and status projection. Typed
startup, protocol, provider-turn, timeout, and abort failures follow the existing runner and
orchestrator retry path.

Pi uses a workspace-owned `0700` `PI_CODING_AGENT_SESSION_DIR` and appends `--session-dir`,
`--no-extensions`, `--no-skills`, `--no-themes`, `--no-prompt-templates`, `--no-context-files`,
and `--no-approve`. It does not override `PI_CODING_AGENT_DIR` or append provider/model/thinking
flags, so the operator's Pi profile supplies authentication and default model/thinking settings.
Credential-like variables and configured tracker credential environment names are removed from the
child environment. Pi SSH workers fail closed because no remote Pi transport is implemented.

## Explicitly removed from the thin baseline

JARVIS-910 removes the Pi tracker bridge and generated extension, Linear handoff automation,
per-attempt and cancellation receipt stores/copies/recovery truth, command-based secret resolution,
and Bitwarden resolver scripts. Pi has no tracker callback, host mutation, receipt, or credential
broker path. Tracker credentials remain host-side and are scrubbed from worker children.

## Evidence boundary

Deterministic Codex, runner, configuration, Pi backend, Pi RPC, status, and cleanup tests establish
this code boundary. They are not a provider canary or production-readiness claim. JARVIS-909 owns
Pi absolute deadline/chatter/lifecycle hardening and disposable multi-worker Pi acceptance; those
items are intentionally outside this extraction.

## Non-goals

- no second scheduler, retry controller, control plane, tracker replica, or truth store;
- no provider calls, tracker mutation, credential broker, generic plugin framework, dynamic loading,
  model catalog, per-ticket backend router, or silent fallback;
- no remote Pi worker support;
- no dependency or lockfile update in this ticket.
