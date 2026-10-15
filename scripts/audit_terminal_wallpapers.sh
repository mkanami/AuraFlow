#!/usr/bin/env bash
set -euo pipefail

# Run on a disposable macOS account/runner. --install explicitly provisions
# reviewed packages; normal audits never install or modify an active wallpaper.
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_OUTPUT="${AURAFLOW_TERMINAL_RENDER_ARTIFACTS:-$TASK_ROOT/.build/terminal-compatibility-audit}"
TASK_SWIFT="${AURAFLOW_SWIFT_BIN:-swift}"
TASK_SWIFT_ARGS=()
if [[ -x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  TASK_SWIFT="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  TASK_SWIFT_ARGS=(--sdk "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
fi
case "${1:-}" in
  --install)
    TASK_BREW="$(command -v brew || true)"
    [[ -n "$TASK_BREW" ]] || { echo "Homebrew is required for --install" >&2; exit 1; }
    TASK_FORMULAE=()
    while IFS= read -r formula; do TASK_FORMULAE+=("homebrew/core/$formula"); done < <(
      python3 - "$TASK_ROOT/macOSApp/Sources/AuraTerminalWallpaperCore/TerminalWallpaperCompatibility.swift" <<'PY'
import re, sys
source = open(sys.argv[1]).read()
for formula in sorted(set(re.findall(r'^\s*profile\("[^"]+", "[^"]+", "([a-z0-9@.+-]+)"', source, re.M))):
    print(formula)
PY
    )
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$TASK_BREW" install --formula "${TASK_FORMULAE[@]}"
    ;;
  "") ;;
  *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

AURAFLOW_WALLPAPER_COMPATIBILITY_AUDIT=1 \
AURAFLOW_TERMINAL_RENDER_ARTIFACTS="$AUDIT_OUTPUT" \
  "$TASK_SWIFT" test --package-path "$TASK_ROOT/macOSApp" "${TASK_SWIFT_ARGS[@]}" \
    --filter wallpaperCompatibilityAudit
echo "Review rendered preset PNGs: $AUDIT_OUTPUT"
