# Immutable source pins

| Subject | Committed capture | Source |
| --- | --- | --- |
| Historical JARVIS-908 parity contract | [`jarvis-908-antigravity-parity.md`](jarvis-908-antigravity-parity.md), SHA-256 `e479143aa701baad4ceb446fbad7ab36373f663b8b88938805010bd21c95949b` | [commit `94baec2`](https://github.com/sheep52031/symphony-engine-docs/commit/94baec212ba6e31821d1059fdd4565b9e3184f22), [source file](https://github.com/sheep52031/symphony-engine-docs/blob/94baec212ba6e31821d1059fdd4565b9e3184f22/docs/overlays/sheep52031-symphony/safe-change/antigravity-parity.md), [PR #1](https://github.com/sheep52031/symphony-engine-docs/pull/1) |
| Superseding owner contract | — | [merge `6d713ce`](https://github.com/sheep52031/symphony-engine-docs/commit/6d713cebb001a127a6bf70253635b884ee39f6bd), [source file](https://github.com/sheep52031/symphony-engine-docs/blob/6d713cebb001a127a6bf70253635b884ee39f6bd/docs/overlays/sheep52031-symphony/safe-change/antigravity-parity.md), [PR #2](https://github.com/sheep52031/symphony-engine-docs/pull/2) |
| Official Symphony authority | — | <https://github.com/openai/symphony/tree/be10a1b79df723d6d7612b5651c8522704dafb2e> |
| Measured fork baseline | — | <https://github.com/sheep52031/symphony/tree/da5fcf7b1d083b723ec08cae942563fc16b783d3> |
| Official AntiGravity headless reference | [`official-headless-reference-full.md`](official-headless-reference-full.md), SHA-256 `836ee2dcb9078f214f68859cc862c1d7faaa1225df7a068178d30dc4e8a5807a` | <https://www.antigravity.google/docs/cli/headless/> |
| Official AntiGravity install/auth reference | [`official-install-auth-reference-full.md`](official-install-auth-reference-full.md), SHA-256 `49aa5ea907061a7c0cb1a05b60fb30ee45314d5ba91d67b7658e1c495ca0e51f` | <https://antigravity.google/docs/cli/install/> |
| Authorized native Windows capture | [`native-live-windows-2026-09-19-capture.md`](native-live-windows-2026-09-19-capture.md), SHA-256 `7081aa73a0147d10f100e62f8864beb3c097d7412c19ae9f45b13edd837bfa1c` (repository-normalized LF bytes) | local owner-authorized execution summarized in [`native-live-windows-2026-09-19.md`](native-live-windows-2026-09-19.md) |
| Authorized native Linux follow-up | [`native-live-linux-2026-09-20.md`](native-live-linux-2026-09-20.md) | local owner-authorized native-Linux execution; only sanitized lifecycle summary is retained, with no raw live capture or digest of sensitive output |
| Superseding native Linux acceptance | [`native-live-linux-2026-09-21.md`](native-live-linux-2026-09-21.md); reviewed aggregate [`native-live-linux-2026-09-21-summary.json`](native-live-linux-2026-09-21-summary.json), SHA-256 `180ceebf18bad14065ce304e019f3573f85668cb456d073a11b6bdae13890e38` | owner-authorized same-host Omarchy execution; exact raw envelopes remain ignored locally and are bound by hashes in the reviewed aggregate |

The committed official-reference and Windows capture files make their exact reviewed content
available even when a repository is private or a live documentation URL later changes. The
2026-09-20 Linux follow-up remains a sanitized, non-gating operator report. The superseding
2026-09-21 acceptance used the committed capture runner for its canonical stream and retained
ignored raw streams with recorded hashes; reviewed follow-up summaries close resume, permissions,
lifecycle, profile separation, and the mandatory outer-containment design. The local static and
committed reviewed records omit executable paths, settings contents, credentials, raw account
identifiers, and authentication material.
