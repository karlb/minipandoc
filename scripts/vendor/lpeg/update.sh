#!/usr/bin/env bash
# Re-fetch vendored lpeg sources. Usage: update.sh [VERSION]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-$(cat "$HERE/VERSION")}"
URL="https://www.inf.puc-rio.br/~roberto/lpeg/lpeg-${VERSION}.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP/lpeg.tar.gz"
tar -xzf "$TMP/lpeg.tar.gz" -C "$TMP"
SRC="$TMP/lpeg-${VERSION}"
for f in lpcap.c lpcap.h lpcode.c lpcode.h lpcset.c lpcset.h \
         lpprint.c lpprint.h lptree.c lptree.h lptypes.h lpvm.c lpvm.h \
         re.lua; do
  cp "$SRC/$f" "$HERE/$f"
done
echo "$VERSION" > "$HERE/VERSION"
echo "Vendored lpeg at $VERSION"
