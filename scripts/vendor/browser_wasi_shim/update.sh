#!/usr/bin/env bash
# Re-fetch vendored bjorn3/browser_wasi_shim dist files.
#
# The shim is authored in TypeScript; the upstream git tree only contains
# src/ and has no compiled dist/. We therefore fetch the published npm
# tarball for the pinned version, which ships the compiled ES-module JS
# under package/dist/. Usage: update.sh [VERSION]
#
#   VERSION defaults to the tag recorded in COMMIT (e.g. v0.4.2). The
#   COMMIT file stores the git SHA the npm tarball was built from, for
#   cross-reference with the GitHub repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-v0.4.2}"
NPM_VERSION="${VERSION#v}"
TARBALL="https://registry.npmjs.org/@bjorn3/browser_wasi_shim/-/browser_wasi_shim-$NPM_VERSION.tgz"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -sfL "$TARBALL" -o "$TMP/shim.tgz"
tar -xzf "$TMP/shim.tgz" -C "$TMP"

for f in debug.js fd.js fs_mem.js fs_opfs.js index.js strace.js wasi.js wasi_defs.js; do
  cp "$TMP/package/dist/$f" "$HERE/$f"
done
cp "$TMP/package/LICENSE-MIT" "$HERE/LICENSE-MIT"
cp "$TMP/package/LICENSE-APACHE" "$HERE/LICENSE-APACHE"

# Resolve the git SHA for the tag and record it.
SHA="$(curl -sfL "https://api.github.com/repos/bjorn3/browser_wasi_shim/git/refs/tags/$VERSION" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])')"
echo "$SHA" > "$HERE/COMMIT"
echo "Vendored browser_wasi_shim $VERSION (git $SHA)"
