# Authorized native Linux `agy` acceptance — 2026-09-21

## Decision

**JARVIS-901 is GO for JARVIS-907 implementation, with mandatory OS-level containment.** This is
not production-dispatch approval. JARVIS-906 still owns the integrated disposable Symphony canary,
Codex/Pi regression, rollback/removal proof, and final runtime acceptance.

The native CLI alone did **not** pass filesystem containment: `agy 1.2.7 --sandbox` allowed its
`write_to_file` tool to modify a disposable host file outside the active workspace. A second probe
showed that a fail-closed Bubblewrap mount boundary prevents that write while preserving
provider access and writes inside the selected workspace. JARVIS-907 must therefore treat the
outer mount sandbox as part of the backend launch contract, not as an optional deployment hint.

The reviewed aggregate is
[`native-live-linux-2026-09-21-summary.json`](native-live-linux-2026-09-21-summary.json), SHA-256
`180ceebf18bad14065ce304e019f3573f85668cb456d073a11b6bdae13890e38`.
Exact raw stdin/stdout/stderr remains in the ignored local capture root and is bound by hashes in
that summary. Raw envelopes, prompts, paths, and conversation IDs must never be force-added.

## Scope and safety

The owner explicitly authorized continuing AntiGravity worker development and the bounded live
checks. All runs used the native Linux executable on the same Omarchy host as BEAM/Symphony; no
Windows interop, SSH launcher, tracker dispatch, MCP bridge, production issue, or account rotation
was used. The observed executable was `agy 1.2.7` on Linux `x86_64`, kernel
`7.2.5-3-omarchy`.

The main capture ran from clean git commit `83bb21f6acbb97a2f6e87407afa3b6b1872fd745`, tree
`b2622796101708eadab81dfb909e080821713858`. Its pinned safe wrapper SHA-256 was
`6f51a53038fe98f434bb483a6288ac747f8d76b1984fd695910644b3668627bb`; the resolved native
executable SHA-256 was `9991515b6d5307bcf701069622b0537b6b206e605f3c891c0cf3a3d208dea8b0`.
The child environment contained only `HOME`, the fixed trusted `PATH`, locale data,
`XDG_RUNTIME_DIR`, and `DBUS_SESSION_BUS_ADDRESS`. No Linear secret or generic API-key/token name
was inherited. No run used `--dangerously-skip-permissions`.

## Acceptance matrix

| Contract row | Result | Bounded observation / required implementation policy |
| --- | --- | --- |
| Native placement and auth | **GO** | The same-host Linux launcher returned `1.2.7`; authenticated `acc1` and `acc2` processes completed provider turns. |
| NDJSON framing | **GO** | Exactly one `init`, valid `step_update` frames, and two terminal nested `result` envelopes; no malformed, dropped, truncated, or invalid-identity events. |
| Canonical stdin multi-turn | **GO** | Two sequential prompts completed `SUCCESS/SUCCESS` in one process, one stable opaque identity, cumulative turns `1/2`, cumulative usage, exit `0`, and an empty owned process group. |
| Same-slot explicit resume | **GO** | A new `acc1 --conversation` process returned the source identity and exactly recalled the first-turn token. |
| Cross-slot binding | **GO with adapter invariant** | `acc2 --conversation <acc1-id>` did not recover the source identity; the CLI silently started a distinct successful conversation. The adapter must compare the requested and returned identities and fail closed on mismatch rather than accept a fresh session as continuation. |
| Permission/input-required | **GO** | `permission_mode` was `request-review`. A shell request produced one structured `denied_actions` entry plus a stderr notice, returned a terminal result, and did not create its sentinel. Permission bypass and auto-answer were absent. |
| Cancellation | **GO with normalization** | After native activity, owner-initiated `SIGINT` produced a terminal `ERROR` whose error class indicated interrupt/cancel, then exited boundedly with an empty process group. The adapter must use its locally recorded cancellation cause as authority rather than misclassify the native `ERROR` as provider failure. |
| Timeout/tree cleanup | **GO** | A bounded live deadline produced a terminal error, sent `SIGTERM`, left the process group empty, and reported no cleanup failure. Deterministic tests separately cover `SIGINT`/`SIGTERM`/`SIGKILL`, inherited-pipe descendants, and final cleanup deadlines. |
| Native cwd | **GO but insufficient alone** | `init.cwd` exactly matched the disposable workspace and its sentinel remained unchanged during no-tool turns. |
| Native `--sandbox` filesystem boundary | **FAIL / negative control** | Even with `--sandbox`, `write_to_file` modified a disposable file outside the workspace. Native terminal sandboxing does not confine native file tools. |
| Outer OS containment | **GO, mandatory** | Bubblewrap `0.12.0` with read-only host root, writable workspace, writable selected profile root, private `/tmp`, private `/dev` and `/proc`, namespace isolation, and shared network preserved authenticated inference. An outside-host write and a workspace-symlink escape left host sentinels unchanged; an absolute in-workspace write succeeded exactly. |
| Profile/keyring separation | **GO for selected explicit slot** | `acc1` and `acc2` completed in separate profile-root launches; cross-slot continuation did not recover the source identity. No profile content or account identifier was read or copied. |
| Owner/runtime authorization | **GO for development evidence** | The owner requested completion of AntiGravity worker development and authorized these bounded checks through the runner guard. Production dispatch remains JARVIS-906 authority. |

## Containment result

The negative control is a required part of the decision. It prevents future code from equating any
of the following with containment:

- setting the child cwd;
- observing matching `init.cwd`;
- using `--mode plan` or `--mode accept-edits`;
- using native `--sandbox`; or
- relying only on `request-review`.

The accepted Linux launch shape adds an outer Bubblewrap boundary with these minimum properties:

1. fail closed when `/usr/bin/bwrap`, the selected profile root, the workspace, or the native
   executable is missing or non-canonical;
2. `--unshare-all --share-net --unshare-user --disable-userns`, `--die-with-parent`, and a new
   session;
3. host `/` read-only, a private `/dev`, `/proc`, and tmpfs `/tmp`;
4. only the canonical issue workspace and one explicitly configured profile root bound writable;
5. exact workspace cwd inside the mount namespace;
6. native `--sandbox` retained as defense in depth;
7. no `--add-dir`, no `unsandboxed(...)` grant, and no dangerous permission-bypass flag; and
8. adapter checks for exact init cwd and stable native identity before accepting any result.

The selected profile root is writable because the CLI persists its own session/runtime state there.
It is an explicit backend state boundary, not an issue workspace and not an arbitrary additional
write root. The adapter must not bind an entire real home writable and must not project `.ssh`,
`.gitconfig`, Linear credentials, or unrelated profile roots.

## Lifecycle details

The main stream capture completed two turns in roughly five seconds and exited `0`. Its manifest
SHA-256 is `ae99c5fb89b26457b80b5328b315ce72e51fcfa5927f4268ac559d6f54e5caae`;
raw stdin/stdout/stderr hashes are retained in the aggregate summary. Same-slot resume preserved
identity and context. Cross-slot resume returned `SUCCESS` under a new identity, which makes exact
identity checking a required fail-closed adapter behavior.

The native interrupt vocabulary does not match the documented ideal status on this build. A
locally initiated `SIGINT` returned terminal `ERROR`, not `INTERRUPTED`, while carrying an
interrupt/cancel-class diagnostic. This is acceptable only because the parent knows it initiated
cancellation, retains the terminal envelope, bounds cleanup, and verifies the process group is
empty. Unsolicited native `ERROR` remains a provider failure.

## Gate impact

JARVIS-901 no longer has an unresolved native-feasibility row. JARVIS-907 may implement the closed
backend mapping, adapter module tree, exact protocol parser, mandatory Bubblewrap launcher, and
shared contract tests. It must not add a scheduler branch, poller, retry loop, tracker lifecycle,
workspace manager, account rotator, silent fallback, or second controller.

Codex remains the default and rollback path. Pi remains a supported opt-in backend. JARVIS-906 must
run one exact-issue disposable integrated canary and prove that deleting the AntiGravity mapping and
module tree restores the accepted Codex+Pi baseline.
