#!/usr/bin/env bash
set -euo pipefail

# Replays the checked-in public operations in an isolated api-anything home.
# Does not install MCP integrations or publish operations to the shared registry.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export API_ANYTHING_HOME="$ROOT_DIR/.build/catalog-api"
export API_ANYTHING_LOCAL_ONLY=1
mkdir -p "$API_ANYTHING_HOME/sites"
for site in desktophut livewallpapers4free; do
  cp "$ROOT_DIR/macOSApp/Sources/WallpaperControlApp/Resources/$site-api.json" "$API_ANYTHING_HOME/sites/$site.json"
done

if [[ -n "${API_ANYTHING_CLI:-}" ]]; then
  CLI=(node "$API_ANYTHING_CLI")
else
  CLI=(npx --yes api-anything@0.4.0)
fi

MODE="${1:-verify}"
if [[ $# -gt 0 ]]; then shift; fi
case "$MODE" in
  verify) exec "${CLI[@]}" verify desktophut livewallpapers4free "$@" ;;
  serve) exec "${CLI[@]}" serve --host 127.0.0.1 --sites desktophut,livewallpapers4free --no-learn "$@" ;;
  call) exec "${CLI[@]}" call "$@" --max-tier 1 ;;
  *) echo "Usage: $0 [verify | serve | call SITE OP key=value ...]" >&2; exit 2 ;;
esac
