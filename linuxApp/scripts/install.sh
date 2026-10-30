#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
  echo 'This installer is for Linux. The macOS app remains in macOSApp/.' >&2
  exit 1
fi

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
data_root="${XDG_DATA_HOME:-$HOME/.local/share}"
if [[ "$data_root" != /* ]]; then
  data_root="$HOME/.local/share"
fi
install_root="${AURAFLOW_INSTALL_DIR:-$data_root/auraflow}"
bin_root="${AURAFLOW_BIN_DIR:-$HOME/.local/bin}"
if [[ "$install_root" != /* || "$bin_root" != /* ]]; then
  echo 'AURAFLOW_INSTALL_DIR and AURAFLOW_BIN_DIR must be absolute paths.' >&2
  exit 1
fi

python_command="${PYTHON:-python3}"
"$python_command" -m venv "$install_root/venv"
"$install_root/venv/bin/python" -m pip install --upgrade "$source_root[gui]"

"$install_root/venv/bin/python" - "$bin_root/auraflow" "$install_root/venv/bin/python" <<'PY'
import shlex
import sys
from pathlib import Path

target = Path(sys.argv[1])
marker = "# AuraFlow Linux launcher"
if target.exists() and marker not in target.read_text().splitlines():
    raise SystemExit(f"Preserving an existing launcher: {target}. Choose AURAFLOW_BIN_DIR.")
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(f'#!/bin/sh\n{marker}\nexec {shlex.quote(sys.argv[2])} -m auraflow "$@"\n')
target.chmod(0o755)
PY

"$install_root/venv/bin/python" -m auraflow install-desktop
echo "Installed AuraFlow. Open it from your application menu or run: $bin_root/auraflow"
echo 'Run auraflow doctor to check your desktop session. Autostart is off by default.'
