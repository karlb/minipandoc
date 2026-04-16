#!/usr/bin/env bash
#
# Benchmark minipandoc vs pandoc on real format conversions.
#
# Usage:
#   bench/bench_vs_pandoc.sh [--size BYTES] [--runs N]
#
# Prerequisites: hyperfine, pandoc, /usr/bin/time, cargo build --release
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MINIPANDOC="$ROOT/target/release/minipandoc"
VENDOR_DIR="$ROOT/scripts/vendor/djot"
FIXTURES_DIR="$ROOT/tests/fixtures/djot"
TMPDIR_BASE="${TMPDIR:-/tmp}/minipandoc-bench"

# Defaults
INPUT_SIZE=102400  # 100 KB
RUNS=10

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)  INPUT_SIZE="$2"; shift 2 ;;
        --runs)  RUNS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--size BYTES] [--runs N]"
            echo ""
            echo "  --size BYTES   Target input size in bytes (default: 102400)"
            echo "  --runs N       Number of timed runs per command (default: 10)"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
fail=0
for cmd in hyperfine pandoc /usr/bin/time; do
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
# Generate scaled input
# ---------------------------------------------------------------------------
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"

# Concatenate all djot fixtures into a single block
block=""
for f in "$FIXTURES_DIR"/*.dj; do
    block+="$(cat "$f")"$'\n\n'
done
block_size=${#block}

# Repeat until we reach the target size, rewriting headings to avoid
# duplicate IDs (append repetition index to each heading line).
input_file="$TMPDIR_BASE/input.dj"
: > "$input_file"
i=0
current_size=0
while (( current_size < INPUT_SIZE )); do
    # Rewrite lines starting with # to append a unique suffix
    while IFS= read -r line; do
        if [[ "$line" =~ ^#+ ]]; then
            echo "$line ($i)" >> "$input_file"
        else
            echo "$line" >> "$input_file"
        fi
    done <<< "$block"
    current_size=$(stat --printf='%s' "$input_file" 2>/dev/null \
                   || stat -f '%z' "$input_file")
    ((i++))
done

actual_size=$(stat --printf='%s' "$input_file" 2>/dev/null \
              || stat -f '%z' "$input_file")
echo "Input: $input_file ($(( actual_size / 1024 )) KB, $i repetitions)"
echo "Runs:  $RUNS (+ warmup)"
echo ""

# ---------------------------------------------------------------------------
# Format combos to benchmark
# ---------------------------------------------------------------------------
# Each entry: "output_format pandoc_writer_arg"
# For djot output, pandoc uses the vendored writer script.
# For other formats, pandoc uses its built-in writer.
LUA_PATH="$VENDOR_DIR/?.lua;;"
DJOT_READER="$VENDOR_DIR/djot-reader.lua"
DJOT_WRITER="$VENDOR_DIR/djot-writer.lua"

declare -A COMBOS
COMBOS=(
    [djot]="$DJOT_WRITER"
    [html]="html"
    [plain]="plain"
    [markdown]="markdown"
    [latex]="latex"
)

# ---------------------------------------------------------------------------
# Verify output equivalence and benchmark
# ---------------------------------------------------------------------------
matched=()
skipped=()

for fmt in djot html plain markdown latex; do
    writer="${COMBOS[$fmt]}"

    mp_out="$TMPDIR_BASE/mp_$fmt.out"
    pd_out="$TMPDIR_BASE/pd_$fmt.out"

    "$MINIPANDOC" -f djot -t "$fmt" "$input_file" > "$mp_out" 2>/dev/null
    LUA_PATH="$LUA_PATH" pandoc -f "$DJOT_READER" -t "$writer" "$input_file" > "$pd_out" 2>/dev/null

    if diff -q "$mp_out" "$pd_out" &>/dev/null; then
        matched+=("$fmt")
        echo "djot -> $fmt: output matches"
    else
        skipped+=("$fmt")
        # Show a brief summary of differences
        diff_lines=$(diff "$mp_out" "$pd_out" | head -20 | wc -l)
        echo "djot -> $fmt: OUTPUT DIFFERS (skipping benchmark; $diff_lines diff lines shown below)"
        diff "$mp_out" "$pd_out" | head -6 || true
        echo ""
    fi
done
echo ""

if [[ ${#matched[@]} -eq 0 ]]; then
    echo "No format combos produced matching output. Nothing to benchmark."
    rm -rf "$TMPDIR_BASE"
    exit 0
fi

# ---------------------------------------------------------------------------
# CPU benchmarks via hyperfine
# ---------------------------------------------------------------------------
echo "========================================="
echo " CPU benchmark (hyperfine, $RUNS runs)"
echo "========================================="
echo ""

for fmt in "${matched[@]}"; do
    writer="${COMBOS[$fmt]}"

    echo "--- djot -> $fmt ---"
    hyperfine \
        --warmup 3 \
        --runs "$RUNS" \
        --export-markdown "$TMPDIR_BASE/bench_$fmt.md" \
        -n "minipandoc" "$MINIPANDOC -f djot -t $fmt $input_file" \
        -n "pandoc" "LUA_PATH='$LUA_PATH' pandoc -f $DJOT_READER -t $writer $input_file"
    echo ""
done

# ---------------------------------------------------------------------------
# Memory benchmarks via /usr/bin/time
# ---------------------------------------------------------------------------
echo "========================================="
echo " Memory benchmark (peak RSS via /usr/bin/time)"
echo "========================================="
echo ""

printf "%-18s %12s %12s %10s\n" "Conversion" "minipandoc" "pandoc" "Ratio"
printf "%-18s %12s %12s %10s\n" "----------" "----------" "------" "-----"

for fmt in "${matched[@]}"; do
    writer="${COMBOS[$fmt]}"

    # Run 3 times, take the median peak RSS
    mp_rss_vals=()
    pd_rss_vals=()
    for _r in 1 2 3; do
        mp_rss=$( (/usr/bin/time -v "$MINIPANDOC" -f djot -t "$fmt" "$input_file" > /dev/null) 2>&1 \
                  | grep "Maximum resident set size" | awk '{print $NF}')
        pd_rss=$( (LUA_PATH="$LUA_PATH" /usr/bin/time -v pandoc -f "$DJOT_READER" -t "$writer" "$input_file" > /dev/null) 2>&1 \
                  | grep "Maximum resident set size" | awk '{print $NF}')
        mp_rss_vals+=("$mp_rss")
        pd_rss_vals+=("$pd_rss")
    done

    # Sort and take median (index 1 of 3)
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
        "djot -> $fmt" "$mp_median" "$pd_median" "$ratio"
done

echo ""

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "Skipped (output differs): ${skipped[*]}"
fi
echo "Temp files in: $TMPDIR_BASE"
echo "Done."
