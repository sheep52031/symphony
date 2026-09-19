# Official AntiGravity headless reference — content-pinned excerpt

- Source: <https://www.antigravity.google/docs/cli/headless/>
- Retrieved UTC: `2026-09-19T06:38:59Z`
- Extraction: `defuddle parse <source> --md`
- Committed full extraction: [`official-headless-reference-full.md`](official-headless-reference-full.md)
- Full extracted Markdown SHA-256: `836ee2dcb9078f214f68859cc862c1d7faaa1225df7a068178d30dc4e8a5807a`
- This committed excerpt and full extraction are static/reference evidence only; neither is a native execution capture.

> Headless mode (also called print mode) sends a single prompt to the agent, streams or returns
> the response, and exits.

> The response goes to `stdout`. Diagnostics — errors, authentication prompts, progress, and
> permission notices — go to `stderr`.

The reference documents `text`, `json`, and `stream-json` output formats. It says the stream
opens with one `init`, includes zero or more `step_update` events, and ends with exactly one
`result`; documented result metadata includes a `conversation_id`, terminal status, response,
duration, turn count, and token-usage totals.

For stdin sessions, it documents `--input-format stream-json --output-format stream-json`, one
NDJSON `user` input per line, one `result` per turn, and a clean close after stdin closes and the
active turn completes. It separately documents `--continue` and `--conversation <id>` for
cross-process continuation.

The reference lists `SUCCESS`, `ERROR`, `CANCELED`, `INTERRUPTED`, `INVALID`, `WAITING`, and
`RUNNING` status values. It says successful runs exit `0`; response failures exit nonzero and,
in JSON formats, are represented by `status` and `error`.

The source also describes headless permission soft-denial and warns that
`--dangerously-skip-permissions` auto-approves tool requests. That bypass was not used.
