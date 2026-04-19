#!/usr/bin/env bash
# Re-fetch the vendored CommonMark spec. Usage: update.sh [NEW_SHA]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHA="${1:-$(cat "$HERE/COMMIT")}"
BASE="https://raw.githubusercontent.com/commonmark/commonmark-spec/$SHA"
for f in spec.txt LICENSE; do
  curl -sfL "$BASE/$f" -o "$HERE/$f"
done
echo "$SHA" > "$HERE/COMMIT"
echo "Vendored commonmark-spec at $SHA"
