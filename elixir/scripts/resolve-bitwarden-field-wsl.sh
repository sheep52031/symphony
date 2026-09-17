#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
powershell_script=$(wslpath -w "${script_dir}/resolve-bitwarden-field.ps1")

exec powershell.exe \
  -NoLogo \
  -NoProfile \
  -NonInteractive \
  -ExecutionPolicy Bypass \
  -File "${powershell_script}" \
  "$@"
