#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEMINI_REPO="${GEMINI_REPO:-$HOME/Code/gemini-cli}"
DEST="$ROOT/Vendor/GeminiCLI"

if [[ ! -d "$GEMINI_REPO" ]]; then
  echo "gemini-cli checkout not found: $GEMINI_REPO" >&2
  exit 1
fi

cd "$GEMINI_REPO"
npm run bundle

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$GEMINI_REPO/bundle" "$DEST/bundle"

VERSION="$(node "$DEST/bundle/gemini.js" --version 2>/dev/null || true)"
SHA="$(git rev-parse HEAD)"
cat > "$DEST/manifest.json" <<JSON
{
  "source": "$GEMINI_REPO",
  "git_sha": "$SHA",
  "version": "$VERSION",
  "entry": "bundle/gemini.js"
}
JSON

echo "Vendored Gemini CLI $VERSION ($SHA) into $DEST"
