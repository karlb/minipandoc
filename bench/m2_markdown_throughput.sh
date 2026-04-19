#!/usr/bin/env bash
#
# M2 — Markdown-reader throughput vs pulldown-cmark on rust-lang/book.
#
# Reports the wall-clock ratio; >10× kills the mdBook SSG replacement
# experiment per notes/use-cases.md §1.
#
# Prerequisites: hyperfine, git, cargo. Builds minipandoc release and a
# minimal pulldown-cmark runner under bench/pulldown_cmark_bench/ on first
# use.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MINIPANDOC="$ROOT/target/release/minipandoc"
PULLDOWN_CRATE="$ROOT/bench/pulldown_cmark_bench"
PULLDOWN_BIN="$PULLDOWN_CRATE/target/release/pulldown_cmark_bench"
CACHE_DIR="${TMPDIR:-/tmp}/minipandoc-m2"
BOOK_DIR="$CACHE_DIR/book"
BOOK_REPO="https://github.com/rust-lang/book.git"
BOOK_SHA="${BOOK_SHA:-}"   # optional pinned ref
FIXTURE="$CACHE_DIR/book.md"

RUNS="${RUNS:-5}"

for cmd in hyperfine git cargo; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found on PATH" >&2
        exit 1
    fi
done

if [[ ! -x "$MINIPANDOC" ]]; then
    echo "==> building minipandoc (release)"
    (cd "$ROOT" && cargo build --release)
fi

if [[ ! -x "$PULLDOWN_BIN" ]]; then
    echo "==> building pulldown_cmark_bench (release)"
    (cd "$PULLDOWN_CRATE" && cargo build --release)
fi

mkdir -p "$CACHE_DIR"
if [[ ! -d "$BOOK_DIR/.git" ]]; then
    echo "==> cloning rust-lang/book → $BOOK_DIR"
    git clone --depth=1 "$BOOK_REPO" "$BOOK_DIR"
fi
if [[ -n "$BOOK_SHA" ]]; then
    (cd "$BOOK_DIR" && git fetch --depth=1 origin "$BOOK_SHA" && git checkout "$BOOK_SHA")
fi
BOOK_COMMIT="$(cd "$BOOK_DIR" && git rev-parse HEAD)"

echo "==> concatenating src/**/*.md → $FIXTURE"
: > "$FIXTURE"
find "$BOOK_DIR/src" -name '*.md' -print0 \
    | sort -z \
    | xargs -0 cat >> "$FIXTURE"
FIXTURE_SIZE="$(wc -c < "$FIXTURE")"
FIXTURE_LINES="$(wc -l < "$FIXTURE")"

echo ""
echo "rust-lang/book @ $BOOK_COMMIT"
echo "fixture:        $FIXTURE ($FIXTURE_SIZE bytes, $FIXTURE_LINES lines)"
echo "minipandoc:     $("$MINIPANDOC" --version | head -1)"
echo "pulldown-cmark: $(grep -E '^pulldown-cmark =' "$PULLDOWN_CRATE/Cargo.toml")"
echo ""

# Sanity: ensure both ends produce non-empty HTML on the fixture.
MP_BYTES="$("$MINIPANDOC" -f markdown -t html < "$FIXTURE" | wc -c)"
PC_BYTES="$("$PULLDOWN_BIN" < "$FIXTURE" | wc -c)"
echo "minipandoc html:     $MP_BYTES bytes"
echo "pulldown-cmark html: $PC_BYTES bytes"
echo ""

hyperfine --warmup 1 --runs "$RUNS" \
    --export-markdown "$CACHE_DIR/hyperfine.md" \
    -n "minipandoc"     "'$MINIPANDOC' -f markdown -t html < '$FIXTURE' > /dev/null" \
    -n "pulldown-cmark" "'$PULLDOWN_BIN' < '$FIXTURE' > /dev/null"

echo ""
echo "==> hyperfine markdown report: $CACHE_DIR/hyperfine.md"
