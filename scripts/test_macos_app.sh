#!/usr/bin/env bash
set -euo pipefail

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
