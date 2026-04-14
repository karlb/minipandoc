#!/usr/bin/env bash
# Serve the browser demo at http://localhost:8000/web/.
#
# Needs a release wasm build to exist at
# target/wasm32-wasip1/release/minipandoc.wasm. Build it once with
# scripts/build-wasm.sh; this script does not rebuild.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WASM="$HERE/target/wasm32-wasip1/release/minipandoc.wasm"
PORT="${PORT:-8000}"

if [ ! -f "$WASM" ]; then
  cat >&2 <<EOF
error: $WASM not found.

Build it first:
  scripts/build-wasm.sh release

Then rerun this script.
EOF
  exit 1
fi

cd "$HERE"
echo "serving $HERE on http://localhost:$PORT"
echo "open http://localhost:$PORT/web/"
exec python3 -m http.server "$PORT"
