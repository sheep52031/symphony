# Pi worker canary acceptance evidence

- Issue: `JARVIS-877`
- Candidate SHA: `d11bbb780bc8ab1ed4a3aee222e6f709bf37e579`
- Base SHA: `be10a1b79df723d6d7612b5651c8522704dafb2e`
- Effective Pi provider: `openai-codex`
- Effective Pi model: `gpt-5.6-luna`
- Effective Pi thinking: `high`

## LLM-callable shell presence

- `LINEAR_API_KEY`: absent
- `BW_SESSION`: absent
- `SYMPHONY_PI_TRACKER_TOKEN`: absent
- `SYMPHONY_PI_TRACKER_URL`: absent
- `PI_CODING_AGENT_DIR`: present
- `PI_CODING_AGENT_SESSION_DIR`: present

The Pi config directory contained only the explicitly provisioned `openai-codex` provider credential type plus Symphony-owned session data. Credential bytes were neither printed nor hashed.

Globally installed Pi extensions, Skills, themes, prompts, context files, and PiCrew were not loaded. The only explicitly provisioned Pi extension was Symphony's generated loopback tracker bridge.

- `git diff --check`: pass