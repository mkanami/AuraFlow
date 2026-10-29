#!/usr/bin/env bash
set -euo pipefail

# The full suite opens AppKit windows and changes the test host's activation
# policy. Never start it implicitly on someone's active desktop.
if [[ "${CI:-}" != "true" && "${CI:-}" != "1" && "${AURAFLOW_DEDICATED_TEST_SESSION:-0}" != "1" ]]; then
  echo "Run the full macOS suite in CI or a dedicated macOS test session (AURAFLOW_DEDICATED_TEST_SESSION=1). Use a focused noninteractive test filter on an active desktop." >&2
  exit 2
fi

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_SWIFT="$(xcrun --find swift)"
TASK_SDK="$(xcrun --sdk macosx --show-sdk-path)"
TASK_LOG_DIR="$TASK_ROOT/.build/test-results"
mkdir -p "$TASK_LOG_DIR"

# Agent tests change the process-wide NSApplication lifecycle and activation
# policy. SwiftUI windows need a fresh application host afterwards. Both phases
# together run the complete suite; --skip and --filter use the identical set.
TASK_WINDOW_SUITES='CatalogCardInteractionTests|MainControlPanelTests|PreviewViewportTests|SettingsPopupLayoutTests|AnimationPanelLayoutTests|TerminalPreviewWindowResizeTests|TerminalWallpaperSectionInteractionTests|EngineLibraryHeaderTests'

"$TASK_SWIFT" test --package-path "$TASK_ROOT/macOSApp" --sdk "$TASK_SDK" \
  --no-parallel --skip "$TASK_WINDOW_SUITES" 2>&1 | tee "$TASK_LOG_DIR/runtime.log"
grep -Eq 'Test run with [0-9]+ tests.*passed' "$TASK_LOG_DIR/runtime.log"

"$TASK_SWIFT" test --package-path "$TASK_ROOT/macOSApp" --sdk "$TASK_SDK" \
  --skip-build --no-parallel --filter "$TASK_WINDOW_SUITES" 2>&1 | tee "$TASK_LOG_DIR/windows.log"
grep -Eq 'Test run with [0-9]+ tests.*passed' "$TASK_LOG_DIR/windows.log"
