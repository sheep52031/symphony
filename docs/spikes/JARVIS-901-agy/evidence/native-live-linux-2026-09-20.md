# Authorized native Linux `agy` live evidence — 2026-09-20

## Scope and safety

This is a bounded native-Linux follow-up only. All commands ran in a disposable Linux
workspace through `~/.local/bin/agy` or the supplied
`~/.local/bin/agy-profile` launcher; no Windows executable or interop executable was
used as evidence. The observed Linux CLI version was `1.2.7`.

No credential, token, cookie, keyring data, account identifier, settings content, or
model-catalog content was read, retained, printed, copied, hashed, or committed. The ephemeral
runner machine-parsed the opaque conversation identity only to check that it was nonempty and
matched across envelopes; the value was never logged, exposed to the operator, retained, hashed,
or committed. CLI stderr from live prompts was sent to the null device. No run used
`--dangerously-skip-permissions`.

The prompt limit was four. Exactly **two** harmless prompts were submitted, both to `acc1`, and
validation stopped on the first unexpected lifecycle result. No prompt was submitted to `acc2` or
`acc3` after that stop.

## Sanitized results

| Check | Result | Bounded evidence |
| --- | --- | --- |
| Native launcher discovery | **PASS** | `~/.local/bin/agy` and `~/.local/bin/agy-profile` were executable; `agy --version` returned `1.2.7`. |
| Fresh D-Bus catalog invocation | **INCONCLUSIVE** | `dbus-run-session -- agy-profile acc3 models` exited `0` within 30 seconds. It emitted diagnostics, which were not read. This shows only that this command did not fail at process level; it does not prove keyring restart/refresh or profile isolation. |
| First Linux NDJSON turn | **OPERATOR REPORT / non-gating** | During the bounded run, an ephemeral guarded runner reported a valid `init` and terminal `SUCCESS` result for the first harmless prompt, with matching nonempty opaque identity, turn count `1`, a usage object, and the expected response. The runner source and raw envelopes were not retained, so this observation is not independently auditable and does not satisfy the contract row. |
| Canonical stdin multi-turn | **HOLD** | Prompt 2 was submitted only after turn 1 completed. No terminal NDJSON result arrived within the runner's 70-second absolute deadline. The runner terminated its own Linux process group and stopped; it did not submit prompts 3–4. Therefore one-init/two-result framing, second-turn identity/counters, clean stdin close, and cumulative usage remain unproven. |
| Same-slot explicit resume | **HOLD / not submitted** | The planned `acc1 --conversation` check would have been prompt 3, but was not run after the stream deadline. |
| Cross-slot explicit resume fail-closed | **HOLD / not submitted** | The planned `acc2 --conversation` check would have been prompt 4, but was not run after the stream deadline. No claim about slot separation is made. |
| Cancellation and process cleanup | **OPERATOR REPORT / non-gating** | The ephemeral runner reported sending `SIGTERM` to its owned Linux process group. An immediately following process check reported `0` `agy`/`agy-profile` processes and one removed disposable workspace. Because the runner and command transcript were not retained, this is not independently auditable and does not prove an official graceful cancellation envelope, forced-tree behavior under descendants, or adapter cancellation mapping. |
| Permission/input-required behavior | **HOLD / not exercised** | No tool-, file-, shell-, or permission-seeking prompt was sent. This avoids changing profile policy or asking an agent to act outside the harmless prompt scope; it leaves the required observable blocked/input outcome open. |

## Operator-reported invocation boundary

The ephemeral runner was not retained or committed, and no raw transcript or digest exists.
Therefore this section records the operator-reported invocation shape for diagnosis only; it is
not an exactly reproducible or machine-auditable acceptance artifact. The reported run used an
`0700` disposable Linux directory, a sentinel file, `--mode plan`,
`--input-format stream-json --output-format stream-json`, and `--print-timeout 60s`. It removed
known API-key/base-URL environment variable names from the child environment without inspecting
their values. It reportedly sent these prompts sequentially, never piping prompt 2 until the
first terminal result passed the guarded checks:

1. `Reply exactly: AGY_LINUX_ALPHA. Do not use tools, commands, files, network, or make changes.`
2. `What exact token did I ask you to reply with in the previous message? Reply only that token. Do not use tools, commands, files, network, or make changes.`

The operator report says the runner did not write raw stdout/stderr to disk. The only summary
preserved in this document is:

```json
{"dangerous_permission_flag_used":false,"failure_kind":"deadline","native_linux":true,"outcome":"HOLD","prompt_count":2,"stopped_at":"stream"}
```

The operator report says it then performed a leak check without printing process command lines
and removed the disposable directory, reporting `agy-processes=0` and
`disposable-live-workspaces-removed=1`. These values are diagnostic context, not independently
auditable acceptance evidence.

## Decision impact

This evidence confirms only the directly reproducible launcher/version checks and records a
non-gating operator report about one first-turn result and a second-turn deadline. Because the
runner and raw envelopes were not retained, the report does **not** close native NDJSON framing,
the canonical multi-turn contract, same-slot resume, cross-slot fail-closed, native cwd/workspace
containment, official cancellation semantics, permission/input handling, or fresh-session
isolation. JARVIS-901 remains **HOLD**; no adapter, tracker bridge, account rotation, credential
mechanism, or production configuration is authorized.
