#!/usr/bin/env bash
#
# Benchmark minipandoc vs pandoc on real format conversions.
#
# Usage:
#   bench/bench_vs_pandoc.sh [--from FORMATS] [--size BYTES] [--runs N]
#
# Prerequisites: hyperfine, pandoc, cargo build --release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MINIPANDOC="$ROOT/target/release/minipandoc"
VENDOR_DIR="$ROOT/scripts/vendor/djot"
TMPDIR_BASE="${TMPDIR:-/tmp}/minipandoc-bench"

# Defaults
INPUT_SIZE=102400  # 100 KB
RUNS=10
FROM="djot,html"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)  FROM="$2"; shift 2 ;;
        --size)  INPUT_SIZE="$2"; shift 2 ;;
        --runs)  RUNS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--from FORMATS] [--size BYTES] [--runs N]"
            echo ""
            echo "  --from FORMATS Comma-separated input formats (default: djot,html)"
            echo "  --size BYTES   Target input size in bytes (default: 102400)"
            echo "  --runs N       Number of timed runs per command (default: 10)"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Split FROM into an array
IFS=',' read -ra INPUT_FORMATS <<< "$FROM"

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
fail=0
for cmd in hyperfine pandoc; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found" >&2
        fail=1
    fi
done
if [[ ! -x "$MINIPANDOC" ]]; then
    echo "ERROR: $MINIPANDOC not found — run 'cargo build --release' first" >&2
    fail=1
fi
if [[ $fail -ne 0 ]]; then exit 1; fi

echo "pandoc:      $(pandoc --version | head -1)"
echo "minipandoc:  $MINIPANDOC"
echo "hyperfine:   $(hyperfine --version)"
echo ""

# ---------------------------------------------------------------------------
# Format helpers
# ---------------------------------------------------------------------------
LUA_PATH="$VENDOR_DIR/?.lua;;"
DJOT_READER="$VENDOR_DIR/djot-reader.lua"
DJOT_WRITER="$VENDOR_DIR/djot-writer.lua"

# Return the fixture files for a given input format.
fixtures_for() {
    local fmt="$1"
    case "$fmt" in
        djot) echo "$ROOT/tests/fixtures/djot/*.dj" ;;
        html)
            # Exclude basic.html: its sourceCode-classed <pre> triggers
            # different AST shapes in pandoc's reader (Div wrapper) vs ours.
            local f; for f in "$ROOT"/tests/fixtures/html/*.html; do
                [[ "$(basename "$f")" == "basic.html" ]] && continue
                printf '%s ' "$f"
            done ;;
        *)    echo "ERROR: unknown input format: $fmt" >&2; return 1 ;;
    esac
}

# Return the output formats to benchmark for a given input format.
output_formats_for() {
    local fmt="$1"
    case "$fmt" in
        djot) echo "djot html plain markdown latex" ;;
        html) echo "html plain markdown latex" ;;
        *)    echo "ERROR: unknown input format: $fmt" >&2; return 1 ;;
    esac
}

# Apply a format-specific sed to make headings unique per repetition.
dedup_headings() {
    local fmt="$1" index="$2" block_file="$3"
    case "$fmt" in
        djot)
            sed "s/^\\(#\\+.*\\)/\\1 ($index)/" "$block_file"
            ;;
        html)
            sed -e "s/id=\"\\([^\"]*\\)\"/id=\"\\1-$index\"/g" \
                -e "s/\\(<h[1-6][^>]*>\\)\\([^<]*\\)/\\1\\2 ($index)/g" \
                "$block_file"
            ;;
    esac
}

# Return the pandoc reader arg for a given input format.
pandoc_reader_arg() {
    case "$1" in
        djot) echo "$DJOT_READER" ;;
        *)    echo "$1" ;;
    esac
}

# Return the pandoc writer arg for a given output format.
pandoc_writer_arg() {
    case "$1" in
        djot) echo "$DJOT_WRITER" ;;
        *)    echo "$1" ;;
    esac
}

# Does this input/output combo need LUA_PATH for pandoc?
pandoc_needs_lua() {
    [[ "$1" == "djot" || "$2" == "djot" ]]
}

# Build a shell command string for minipandoc (used by hyperfine).
build_minipandoc_cmd() {
    local in_fmt="$1" out_fmt="$2" input="$3"
    echo "$MINIPANDOC -f $in_fmt -t $out_fmt $input"
}

# Build a shell command string for pandoc (used by hyperfine).
build_pandoc_cmd() {
    local in_fmt="$1" out_fmt="$2" input="$3"
    local reader writer
    reader="$(pandoc_reader_arg "$in_fmt")"
    writer="$(pandoc_writer_arg "$out_fmt")"

    if pandoc_needs_lua "$in_fmt" "$out_fmt"; then
        echo "LUA_PATH='$LUA_PATH' pandoc -f $reader -t $writer $input"
    else
        echo "pandoc -f $reader -t $writer $input"
    fi
}

# Run minipandoc directly (for equivalence checks / memory benchmarks).
run_minipandoc() {
    local in_fmt="$1" out_fmt="$2" input="$3"
    "$MINIPANDOC" -f "$in_fmt" -t "$out_fmt" "$input"
}

# Run pandoc directly (for equivalence checks / memory benchmarks).
run_pandoc() {
    local in_fmt="$1" out_fmt="$2" input="$3"
    local reader writer
    reader="$(pandoc_reader_arg "$in_fmt")"
    writer="$(pandoc_writer_arg "$out_fmt")"

    if pandoc_needs_lua "$in_fmt" "$out_fmt"; then
        LUA_PATH="$LUA_PATH" pandoc -f "$reader" -t "$writer" "$input"
    else
        pandoc -f "$reader" -t "$writer" "$input"
    fi
}

# ---------------------------------------------------------------------------
# Generate scaled input for a format
# ---------------------------------------------------------------------------
generate_input() {
    local fmt="$1" tmpdir="$2"
    local fixtures_glob block_file input_file

    fixtures_glob=$(fixtures_for "$fmt")
    block_file="$tmpdir/block.$fmt"
    input_file="$tmpdir/input.$fmt"

    # shellcheck disable=SC2086
    cat $fixtures_glob > "$block_file"
    printf '\n' >> "$block_file"

    : > "$input_file"
    local i=0 current_size=0
    while (( current_size < INPUT_SIZE )); do
        dedup_headings "$fmt" "$i" "$block_file" >> "$input_file"
        current_size=$(wc -c < "$input_file")
        i=$(( i + 1 ))
    done

    local actual_size
    actual_size=$(wc -c < "$input_file")
    echo "Input: $input_file ($(( actual_size / 1024 )) KB, $i repetitions)"
}

# ---------------------------------------------------------------------------
# Main benchmark loop — one iteration per input format
# ---------------------------------------------------------------------------
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"

for input_fmt in "${INPUT_FORMATS[@]}"; do
    echo "========================================="
    echo " Input format: $input_fmt"
    echo "========================================="
    echo ""

    fmt_tmpdir="$TMPDIR_BASE/$input_fmt"
    mkdir -p "$fmt_tmpdir"
    input_file="$fmt_tmpdir/input.$input_fmt"

    # --- Generate scaled input ---
    echo "Generating input..."
    generate_input "$input_fmt" "$fmt_tmpdir"
    echo "Runs:  $RUNS (+ warmup)"
    echo ""

    # --- Check AST equivalence ---
    # Both tools convert the input to native.  minipandoc's compact
    # native is normalized through `pandoc -f native -t native` so
    # it can be compared against pandoc's (already canonical) output.
    # If the normalized ASTs match, the tools are doing equivalent
    # work and all output format pairs are benchmarked.
    read -ra out_fmts <<< "$(output_formats_for "$input_fmt")"

    echo "Checking AST equivalence (normalized native)..."
    mp_ast="$fmt_tmpdir/mp_ast.native"
    pd_ast="$fmt_tmpdir/pd_ast.native"

    run_minipandoc "$input_fmt" native "$input_file" 2>/dev/null \
        | pandoc -f native -t native > "$mp_ast" 2>/dev/null
    run_pandoc "$input_fmt" native "$input_file" > "$pd_ast" 2>/dev/null

    if ! diff -q "$mp_ast" "$pd_ast" &>/dev/null; then
        echo "  ASTs differ after normalization — skipping $input_fmt."
        echo ""
        continue
    fi
    echo "  ASTs match."
    echo ""

    matched=("${out_fmts[@]}")

    # --- CPU benchmarks via hyperfine ---
    echo "-----------------------------------------"
    echo " CPU benchmark: $input_fmt (hyperfine, $RUNS runs)"
    echo "-----------------------------------------"
    echo ""

    for out_fmt in "${matched[@]}"; do
        echo "--- $input_fmt -> $out_fmt ---"
        hyperfine \
            --warmup 3 \
            --runs "$RUNS" \
            --export-markdown "$fmt_tmpdir/bench_$out_fmt.md" \
            -n "minipandoc" "$(build_minipandoc_cmd "$input_fmt" "$out_fmt" "$input_file")" \
            -n "pandoc" "$(build_pandoc_cmd "$input_fmt" "$out_fmt" "$input_file")"
        echo ""
    done

    # --- Memory benchmarks (optional) ---
    if command -v /usr/bin/time &>/dev/null && /usr/bin/time -v true 2>/dev/null; then
        echo "-----------------------------------------"
        echo " Memory benchmark: $input_fmt (peak RSS)"
        echo "-----------------------------------------"
        echo ""

        printf "%-18s %12s %12s %10s\n" "Conversion" "minipandoc" "pandoc" "Ratio"
        printf "%-18s %12s %12s %10s\n" "----------" "----------" "------" "-----"

        for out_fmt in "${matched[@]}"; do
            mp_rss_vals=()
            pd_rss_vals=()
            pd_reader="$(pandoc_reader_arg "$input_fmt")"
            pd_writer="$(pandoc_writer_arg "$out_fmt")"
            for _r in 1 2 3; do
                mp_rss=$( (/usr/bin/time -v "$MINIPANDOC" -f "$input_fmt" -t "$out_fmt" "$input_file" > /dev/null) 2>&1 \
                          | grep "Maximum resident set size" | awk '{print $NF}')
                if pandoc_needs_lua "$input_fmt" "$out_fmt"; then
                    pd_rss=$( (LUA_PATH="$LUA_PATH" /usr/bin/time -v pandoc -f "$pd_reader" -t "$pd_writer" "$input_file" > /dev/null) 2>&1 \
                              | grep "Maximum resident set size" | awk '{print $NF}')
                else
                    pd_rss=$( (/usr/bin/time -v pandoc -f "$pd_reader" -t "$pd_writer" "$input_file" > /dev/null) 2>&1 \
                              | grep "Maximum resident set size" | awk '{print $NF}')
                fi
                mp_rss_vals+=("$mp_rss")
                pd_rss_vals+=("$pd_rss")
            done

            IFS=$'\n' mp_sorted=($(sort -n <<<"${mp_rss_vals[*]}")); unset IFS
            IFS=$'\n' pd_sorted=($(sort -n <<<"${pd_rss_vals[*]}")); unset IFS
            mp_median="${mp_sorted[1]}"
            pd_median="${pd_sorted[1]}"

            if [[ "$mp_median" -gt 0 ]]; then
                ratio=$(awk "BEGIN {printf \"%.1fx\", $pd_median / $mp_median}")
            else
                ratio="N/A"
            fi

            printf "%-18s %10s KB %10s KB %10s\n" \
                "$input_fmt -> $out_fmt" "$mp_median" "$pd_median" "$ratio"
        done
        echo ""
    else
        echo "(Skipping memory benchmark — /usr/bin/time -v not available)"
        echo ""
    fi

done

echo "Temp files in: $TMPDIR_BASE"
echo "Done."
