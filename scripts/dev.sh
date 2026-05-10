#!/usr/bin/env bash
# Watch Soul-Desktop sources, rebuild + relaunch on save.
# Requires: fswatch (brew install fswatch).

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Soul-Desktop.xcodeproj"
SCHEME="Soul-Desktop"
APP_NAME="Soul-Desktop"
WATCH_DIR="Soul-Desktop"

if ! command -v fswatch >/dev/null 2>&1; then
  echo "fswatch not found. Install with: brew install fswatch" >&2
  exit 1
fi

if pgrep -x Xcode >/dev/null 2>&1 && pgrep -f "Xcode.*$APP_NAME" >/dev/null 2>&1; then
  cat <<EOF >&2
⚠️  Xcode appears to be running this app under the debugger.
    dev.sh and Xcode-Run can't share an app process — use one or the other.
    Stop the Xcode session (⌘.) then re-run this script.
EOF
  exit 1
fi

build_and_run() {
  echo "🔨  Building..."
  if xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
       -destination 'platform=macOS' build \
       -quiet >/tmp/soul-desktop-build.log 2>&1; then
    echo "✅  Build OK"
  else
    echo "❌  Build failed (see /tmp/soul-desktop-build.log):" >&2
    grep -E "error:" /tmp/soul-desktop-build.log | head -5 >&2 || true
    return 1
  fi

  APP_PATH=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
              -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
              | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
  APP_PATH="$APP_PATH/$APP_NAME.app"

  # Only kill processes launched from this build path, not Xcode-debugged ones.
  pkill -f "$APP_PATH" 2>/dev/null || true
  open "$APP_PATH"
  echo "🚀  Relaunched"
}

build_and_run || true

echo "👀  Watching $WATCH_DIR for changes (Ctrl-C to stop)"
fswatch -o -e ".*" -i "\\.swift$" "$WATCH_DIR" | while read -r _; do
  build_and_run || true
done
