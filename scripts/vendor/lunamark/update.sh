#!/usr/bin/env bash
# Re-fetch vendored lunamark sources from github.com/jgm/lunamark.
# Usage: update.sh [COMMIT_SHA]   (defaults to the pinned SHA in ./COMMIT)
#
# We vendor only the subset the markdown reader needs. Everything else
# (writers, README, tests, rockspecs) lives upstream.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SHA="${1:-$(cat "$HERE/COMMIT")}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --quiet https://github.com/jgm/lunamark "$TMP/lunamark"
(cd "$TMP/lunamark" && git checkout --quiet "$SHA")
SRC="$TMP/lunamark"
cp "$SRC/LICENSE"                    "$HERE/LICENSE"
cp "$SRC/lunamark/util.lua"          "$HERE/lunamark/util.lua"
cp "$SRC/lunamark/entities.lua"      "$HERE/lunamark/entities.lua"
cp "$SRC/lunamark/reader/markdown.lua" "$HERE/lunamark/reader/markdown.lua"
echo "$SHA" > "$HERE/COMMIT"
echo "Vendored lunamark at $SHA"
