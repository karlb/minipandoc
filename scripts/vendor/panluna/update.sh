#!/usr/bin/env bash
# Re-fetch vendored tarleb/panluna files. Usage: update.sh [NEW_SHA]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHA="${1:-$(cat "$HERE/COMMIT")}"
BASE="https://raw.githubusercontent.com/tarleb/panluna/$SHA"
for f in panluna.lua LICENSE; do
  curl -sfL "$BASE/$f" -o "$HERE/$f"
done
echo "$SHA" > "$HERE/COMMIT"
echo "Vendored panluna at $SHA"
