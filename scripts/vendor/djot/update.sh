#\!/usr/bin/env bash
# Re-fetch vendored jgm/djot.lua files. Usage: update.sh [NEW_SHA]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHA="${1:-$(cat "$HERE/COMMIT")}"
BASE="https://raw.githubusercontent.com/jgm/djot.lua/$SHA"
for f in djot-reader.lua djot-writer.lua djot.lua LICENSE; do
  curl -sfL "$BASE/$f" -o "$HERE/$f"
done
mkdir -p "$HERE/djot"
for m in ast attributes block filter html inline json; do
  curl -sfL "$BASE/djot/$m.lua" -o "$HERE/djot/$m.lua"
done
echo "$SHA" > "$HERE/COMMIT"
echo "Vendored djot.lua at $SHA"
