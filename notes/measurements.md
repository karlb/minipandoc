# Markdown-reader measurements (M1 + M2)

Both measurements gate ROADMAP Next #3 (CommonMark conformance + GFM).
See `notes/use-cases.md` "Measurements first" for the acceptance
thresholds this report lands against.

- Date: 2026-04-19
- minipandoc: `e76c17e` (HEAD at measurement)
- Reference: `pulldown-cmark` 0.13.3, `rust-lang/book` @
  `05d114287b7d6f6c9253d5242540f00fbd6172ab`, CommonMark spec 0.31.2
  (`9103e341a973013013bb1a80e13567007c5cef6f`)

## M1 — CommonMark spec-suite pass rate

**Headline: 217 / 652 = 33.3 %.**

Far below the ~95 % bar `notes/use-cases.md` §1 set for the mdBook
replacement experiment. Inline parsing is roughly half-right; block
parsing is largely broken.

**Reproduce:**

```
cargo build --release
cargo test --release --test commonmark_spec -- --ignored --nocapture
```

Spec vendored at `scripts/vendor/commonmark/spec.txt`; re-fetch with
`scripts/vendor/commonmark/update.sh`. The scorecard normalizer is
deliberately lenient (strips XHTML `/` in void tags, decodes the six
common entities, collapses blank lines between block tags). It does
**not** touch whitespace inside `<pre>` content.

**Per-section breakdown** (top 10 worst, ≥3 examples):

| section | pass |
| --- | --- |
| Tabs | 0 / 11 |
| Indented code blocks | 0 / 12 |
| Fenced code blocks | 1 / 29 |
| Setext headings | 1 / 27 |
| ATX headings | 2 / 18 |
| Lists | 4 / 27 |
| Thematic breaks | 3 / 19 |
| HTML blocks | 7 / 44 |
| Block quotes | 5 / 25 |
| Paragraphs | 2 / 8 |

**Top-scoring sections** (for contrast): Precedence 1/1, Code spans
15/22, Autolinks 11/19, Emphasis 74/132, Hard line breaks 8/15.

**Top 3 observations:**

1. Every block-level construct is substantially broken. The core
   lunamark grammar predates CommonMark and resolves ambiguity
   differently than the spec on nearly every boundary case — list
   continuation, heading trailing `#`, fence indent tolerance, tab
   expansion inside code blocks, paragraph continuation rules, etc.
2. Inline parsing is usably close but not there: emphasis/strong is
   at 56 %, links at 38 %, images at 32 %. Lunamark's emphasis rules
   pre-date the current spec's delimiter-run algorithm.
3. The HTML writer's XHTML-style void tags and entity choices are
   not the driver of the low score — the normalizer neutralizes
   those. The failures are parser failures.

**Scope implication for Next #3:** the tactical follow-up list in
`ROADMAP.md:122–129` (unindented footnote bodies, nested lists, attr
propagation, grid tables, TeX math) is nowhere near enough to reach
95 %. Closing every item on that list would likely leave us below 50
%. A CommonMark-level conformance target means replacing the core
block grammar, not patching around lunamark.

## M2 — Markdown-reader throughput vs `pulldown-cmark`

**Headline: 365× slower** (3.887 s ± 0.048 s vs 10.7 ms ± 1.1 ms on a
1.22 MB concatenation of `rust-lang/book/src/**/*.md`).

**Reproduce:**

```
cargo build --release
bash bench/m2_markdown_throughput.sh
```

Caches the book clone under `${TMPDIR:-/tmp}/minipandoc-m2/book`.
Reference renderer is a minimal pulldown-cmark runner at
`bench/pulldown_cmark_bench/` (GFM-relevant options enabled: tables,
footnotes, strikethrough, task lists, heading attributes).

**Top 3 observations:**

1. The ratio is ~36× the 10× kill threshold from `use-cases.md` §1.
   pulldown-cmark processed the full 1.2 MB corpus in ~10 ms; we
   took ~4 s.
2. Cost is fundamental, not harness overhead: we run LPeg-backed
   Lua over an amalgamated bundle, which is the right engineering
   for a tiny portable artifact but not a throughput peer for
   handwritten Rust.
3. Output size is comparable (1.39 MB vs 1.37 MB), so we're not
   paying the cost for dramatically different output — the time is
   pure parsing cost.

**Scope implication:** `use-cases.md` §1 (mdBook/Zola replacement) is
**dead** regardless of how M1 lands. No feasible parser rewrite will
bring Lua+LPeg within an order of magnitude of handwritten Rust.
Re-prioritize to the other §0/0a/0b/3/6/7 pitches where in-browser
reach and binary size are the actual differentiators.

## Decisions driven by these numbers

1. **Kill use-cases §1** (SSG replacement experiment). Update that
   section to "not feasible" and reprioritize.
2. **Retarget Next #3.** Drop the "95 % CommonMark + GFM" framing.
   The useful work here is bounded to what specific downstream
   targets actually need: ipynb (§0a) needs the markdown reader to
   cover code fences, math, and lists well; HedgeDoc (§0b) needs GFM
   extensions. Scope #3 as "fix the blocks our committed pitches
   depend on", not "pass the CommonMark spec."
3. **Treat the scorecard as a regression guard.** Keep
   `tests/commonmark_spec.rs` as `#[ignore]`-gated so the pass rate
   can be re-run on demand; adding per-section assertions isn't
   worth it until we're chasing specific targets.
