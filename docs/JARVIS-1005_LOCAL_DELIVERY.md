# Local verification and release

This fork uses local verification and local artifact creation. GitHub-hosted Actions are not part
of the delivery gate. The historical workflow recipes are preserved byte-for-byte outside
`.github/workflows/`; `mix test` pins their SHA-256 digests and checks that no workflow is
registered. Do not restore a workflow there as a placeholder: GitHub's workflow directory must
remain empty for this policy.

## Verify an exact candidate

Start from the intended candidate commit in a clean worktree. Record its identity before running
the gate:

```sh
git status --short
git rev-parse HEAD
git rev-parse HEAD^{tree}
git diff --check
make -C elixir all
cd elixir
mise exec -- mix pr_body.check --file /absolute/path/to/pr-body.md
cd ..
```

The PR body check is run with the exact body intended for review. If no PR body exists yet, record
it as pending rather than treating the command as passed. The full `make all` gate uses the tool
versions pinned in `elixir/mise.toml` (Erlang 28 and Elixir 1.19.5-otp-28). Give Mix a task-owned
temporary directory under `/var/tmp` for `TMPDIR` and `MIX_BUILD_PATH`; the Antigravity sandbox
fixture checks differ for `/tmp` paths because `/tmp` is replaced by a private mount.

```sh
gate_tmp="$(mktemp -d /var/tmp/symphony-local-gate.XXXXXX)"
mkdir -p "$gate_tmp/tmp"
TMPDIR="$gate_tmp/tmp" MIX_BUILD_PATH="$gate_tmp/build" make -C elixir all
```

## Build and smoke a local Linux x86_64 package

Run this only after the exact candidate's full gate passes. The build pins Zig 0.15.2, as in the
former release recipe. Set `VERSION` to the committed `elixir/mix.exs` version and verify any
requested stable tag matches it. A local build does not create or move a Git tag or publish a
GitHub release.

```sh
set -eu
VERSION="$(sed -nE 's/^[[:space:]]*version: "([^"]+)",$/\1/p' elixir/mix.exs | head -n 1)"
test -n "$VERSION"
TAG="v$VERSION"
printf 'candidate=%s\ntree=%s\nversion=%s\nexpected-tag=%s\n' \
  "$(git rev-parse HEAD)" "$(git rev-parse HEAD^{tree})" "$VERSION" "$TAG"
if git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" >/dev/null; then
  tag_commit="$(git rev-parse "$TAG^{commit}")"
  test "$tag_commit" = "$(git rev-parse HEAD)" || {
    printf 'tag %s points to %s, not this candidate; stop\n' "$TAG" "$tag_commit" >&2
    exit 1
  }
else
  printf 'no local %s tag; this is a local validation package only\n' "$TAG"
fi

cd elixir
TMPDIR="$gate_tmp/tmp" MIX_BUILD_PATH="$gate_tmp/build" \
  BURRITO_TARGET=linux_x86_64 MIX_ENV=prod mise exec zig@0.15.2 -- \
  mix release symphony --overwrite
artifact="burrito_out/symphony_linux_x86_64"
test -f "$artifact"
chmod +x "$artifact"
sha256sum "$artifact" | tee "$artifact.sha256"
sha256sum --check "$artifact.sha256"

install_dir="$(mktemp -d "$gate_tmp/install.XXXXXX")"
set +e
output="$(SYMPHONY_INSTALL_DIR="$install_dir" "$artifact" 2>&1)"
status=$?
set -e
test "$status" -eq 1
printf '%s\n' "$output" | grep -F \
  'This Symphony implementation is a low key engineering preview.'
```

Keep the artifact and checksum together with a receipt containing the candidate commit and tree,
`VERSION`, expected `TAG`, exact commands, tool versions, host OS/architecture, exit statuses, and
smoke output. Preserve the artifact SHA-256 in that receipt. This native Linux build is evidence
only for the host target. macOS and other cross-build/package/install claims remain UNKNOWN until
they have native build and smoke receipts on the respective platforms.

## Review and reference limits

Bind the independent smart-model Agent review to the same candidate commit and tree, and include
the review result with the local gate receipt. Re-run the local gate and rebuild if the candidate
changes. This is local evidence; it must not be described as a passing GitHub check.

This recipe does not push branches, create or move tags, update the `nightly` ref, create or edit
GitHub releases/assets, or change repository Actions settings. Historical remote refs, releases,
assets, and workflow runs remain as they were. Any remote publication or repository-setting change
is a separate owner-authorized action after its exact target and effects are reviewed.
