# minipandoc — Roadmap

Long-term direction. The Rust core, pandoc-compatible CLI, and a working
set of readers/writers have landed; the open questions now are which
formats to add next, how close to match pandoc's output byte-for-byte,
and how to ship the artifact.

Priorities for new readers, writers, and reader overhauls are driven
by the target pitches tracked in
[`notes/use-cases.md`](notes/use-cases.md). Items below tagged
"(use-cases §X)" link back to a specific pitch there.

## Done

Readers: `native`, `djot`, `html`, `markdown` (first-cut — conformance
and GFM parity are Next #3). Writers: `native`, `djot`, `html`,
`plain`, `markdown`, `latex`, `epub`. Everything below is summarized;
CHANGELOG / git log has the detail.

- **Rust core + Lua bridge + pandoc-compatible CLI** — commit `4ef7007`.
  AST lives in Lua; `src/ast.rs` is a reference shape, not on the hot
  path. One Lua state per conversion; `pandoc.read`/`pandoc.write`
  recurse via fresh sub-states.
- **`native` reader/writer** — commit `4ef7007`.
- **`djot`** — commit `dd96e7c`. Vendored `jgm/djot.lua` + pure-Lua
  `pandoc.layout`. Byte-identical writer output to pandoc running the
  same vendored script.
- **`html` writer** — commit `1875e27`. Pure-Lua, ~340 lines.
- **`plain` writer** — commit `93fdb9f`. Unblocks djot's complex-table
  fallback; byte-parity with `pandoc -t plain` on focused fixtures.
- **Template engine** — commit `f9dabf6`. Pure-Lua doctemplates subset
  (`$var$`, `$if/$else/$endif$`, `$for/$sep/$endfor$`, `$$`, dotted
  paths, pandoc's whitespace rule). Bundled `default.{html,plain,
  markdown,latex}`. `--template`, `-V`, `-M` all flow through.
- **`markdown` writer** — pandoc-flavored, ~600 lines, ATX headers,
  pipe + grid tables, fenced code/divs, footnotes collected to
  end-of-document, YAML front-matter.
- **`latex` writer** — ~500 lines, `longtable`+booktabs for simple
  tables, figure environments, `\hyperlink`/`\href`, `\includegraphics`,
  `\verb` with auto-delimiter pick. `default.latex` ships a minimal
  `article` preamble. Pandoc 3.x parity via phantomsection/label
  (commit `ab5c1fc`).
- **`epub` writer** — commits `4a0eb35`, `0318284`, `f4d5ca2`. First
  binary format. Rust-backed `pandoc.zip.create()` +
  `ByteStringWriter`. 9 integration tests.
- **`html` reader** — handwritten tokenizer + block/inline parser, no
  vendored parser, no LPeg. Unknown tags degrade to
  `RawInline`/`RawBlock (html)`; footnote refs + `<section
  id="footnotes">` reconstruct pandoc `Note` elements.
- **WASI build** — `wasm32-wasip1` cross-compile, auto-provisioned
  wasi-sdk. `tests/wasi_smoke.rs` runs the artifact under Node's WASI
  shim. Release wasm: 1.3 MB raw / 399 KB gzipped.
- **Browser target** — same WASI binary runs unchanged under
  vendored `@bjorn3/browser_wasi_shim` (~20 KB). `web/minipandoc.mjs`
  is the ES-module loader; `web/index.html` is the demo. Pandoc Lua
  filters work unmodified because the browser path is pure JS over the
  existing Lua-5.4-backed WASI artifact.
- **`--embed-resources`** — HTML writer inlines `<img src>` as
  `data:` URIs and rewrites `$for(css)$<link>` to inline `<style>`
  via `header-includes`. Implies `--standalone`. New primitives:
  `pandoc.mediabag.fetch` (local files; URLs return `nil, err`) and
  `pandoc._internal.base64_encode`. Local paths only; scripts,
  media tags, and recursive CSS `url(...)` rewriting deferred. See
  [`notes/embed-resources-url-fetching.md`](notes/embed-resources-url-fetching.md).
- **Benchmark harness** — `bench/bench_vs_pandoc.sh` runs hyperfine
  head-to-head against pandoc. Framework + parity work landed across
  `32c829b` → `f2042c8`; writer-level parity closeouts landed in
  `1360cca` (djot input, 3/5 → 5/5) and `24fdaff` (html input,
  0/4 → 4/4). Both scorecards now at full parity against pandoc 3.9.

## Next (committed work)

Priority-ordered. Each is scoped small enough to ship as its own
milestone.

### 1. Measurements — scope the markdown reader overhaul ✓

Both gating measurements landed — see
[`notes/measurements.md`](notes/measurements.md):

- **M1 — CommonMark spec-suite pass rate: 33.3 %** (217 / 652).
  Block parsing (tabs, indented/fenced code, headings, lists, HTML
  blocks, block quotes, paragraphs) is where the damage is; inline
  parsing is roughly half-right. Scoreboard test at
  `tests/commonmark_spec.rs` (`#[ignore]`-gated).
- **M2 — throughput: ~365× slower** than `pulldown-cmark` on
  `rust-lang/book` (3.89 s vs 10.7 ms). Bench harness at
  `bench/m2_markdown_throughput.sh` + `bench/pulldown_cmark_bench/`.

**Consequences, applied below:**

- **Use-cases §1 (mdBook/Zola replacement) is killed by M2.** No
  feasible parser rewrite closes a 365× gap against handwritten
  Rust. Dropped from the priority list.
- **#3 is rescoped** away from "~95 % CommonMark + GFM" to
  "fix the blocks our committed pitches (0a JupyterLite, 0b
  HedgeDoc) actually depend on."

### 2. npm package for the WASM build

The browser target works end-to-end and the wasm is 399 KB gzipped.
Packaging unblocks downstream adoption and exercises the stable
public API surface (`convert(input, from, to, opts)` in
`web/minipandoc.mjs`). Success-signal #4 depends on this.

### 3. Markdown reader — target-driven block parity

Goal, rescoped post-M1/M2: fix the block-level constructs the
committed pitches (0a JupyterLite, 0b HedgeDoc, 5 Zettelkasten) need,
not the full CommonMark spec. 34 % spec conformance (M1) is not
worth rebuilding the grammar to 95 % — M2 already removed the SSG
replacement carrot that justified that scope.

As of this ROADMAP update the lunamark tree is **forked in-tree** at
`scripts/lunamark/` (see `scripts/lunamark/FORKED_FROM`); upstream has
been dormant since 2024-07 and the grammar edits needed here were
previously blocked by the vendored-unchanged rule. We own it now —
grammar fixes land as direct edits with per-section scorecard
movement as the acceptance signal.

Concretely: close the block-level gaps that actually bite downstream
users, verify via `tests/commonmark_spec.rs` per-section deltas.
Ordered by cost vs pitch leverage:

1. **ATX headings ✓** — require space/tab after the opening hashes
   and allow up to 3 leading spaces. Landed (commit
   [`4bc16ec`](#)): ATX 2/18 → 12/18, Setext 1/27 → 8/27.
2. **`link_attributes` on `DirectLink` + multi-line attr blocks ✓**
   — copy the Image branch's trailing capture into DirectLink, and
   let `parsers.attributes` tolerate a newline between tokens.
   Landed (commit [`9c989e7`](#)); graduated `figure.md` and
   `header_attrs.md` from SMOKE_ONLY.
3. **Two-pass note / reference resolution ✓** — prescan the input
   with `(NoteBlock + Reference + any)^0` so `register_note` /
   `register_link` run before any inline resolution. Landed (commit
   [`f8a9f56`](#)); graduated `footnote.md` and pushed the overall
   scorecard 254 → 283 (biggest move so far because it unblocks
   every forward reference-link in the spec).
4. **Nested lists ✓** — column-anchor BulletList / OrderedList /
   TaskList markers via a Lua-side list-column stack driven by Cmt
   callbacks; create_parser snapshots the stack around every
   recursive parse. Landed (commit [`5e2b70b`](#)); graduated
   `lists.md` (strict pandoc AST parity). Biggest downstream win
   for HedgeDoc.
5. **Indented + fenced code blocks** (today 0/12 and 1/29). Tab
   handling inside code is completely wrong; fence indent tolerance
   is off. Required for every downstream pitch.
6. **GFM extensions relevant to the committed pitches**: task lists,
   strikethrough, autolinks, footnotes — verify against GFM fixtures
   once 1–5 land.
7. **TeX math** (`$…$` / `$$…$$`) — required for JupyterLite and
   HedgeDoc. New inline/block parser in the forked grammar.

`grid tables` remains a tactical follow-up; delimiter-run emphasis
and full HTML-block precedence are out of scope — if a pitch ever
demands that depth we reach for cmark-gfm instead of pushing lunamark
further.

Current state (through PR 4): 43.1 % CommonMark pass rate
(281 / 652). The scorecard now runs with
`-f markdown-auto_identifiers-smart` so pandoc-markdown extras
don't count against grammar conformance — numbers here are not
directly comparable to the 33.3 % recorded in
`notes/measurements.md`, which used the default `-f markdown`.
11 of 15 canonical fixtures pass strict AST parity with pandoc 3.9
(was 7); 4 remain smoke-only pending the work above
(`tests/markdown_reader_parity.rs` `SMOKE_ONLY` and "Known
limitations" in `CLAUDE.md`). The parity scorecard
(`tests/commonmark_spec.rs`) tracks per-section improvement as each
gap closes.

## Polish

Small, individually tractable items mostly surfaced in CLAUDE.md's
"Known limitations" section. Can be picked up opportunistically
between milestones.

- **Template engine**: partials (`${name}`), `$var/pattern/repl$`
  filters.
- **Plain writer**: byte-match pandoc's column-width algorithm for
  complex tables; implement texmath (Unicode rendering for `Math`
  elements) instead of raw TeX passthrough.
- **Latex writer strengthening** (use-cases §0a, JupyterLite):
  close notebook-export gaps — verify code-block, figure, caption,
  and math output against pandoc `nbconvert`-style fixtures.
  Incremental, fixture-driven.
- **`--embed-resources`**: `<script src>`, `<video>`/`<audio>`/
  `<source>`, `<embed>`, `<iframe>`, recursive `url(...)` rewriting
  inside inlined CSS.
- **`pandoc.mediabag.*`** / **`pandoc.system.*`**: flesh out the
  stubs as individual writers need them.
- **`pandoc.layout`**: fill in combinators as new writers expose
  gaps.

## Larger efforts

### Binary formats — docx, ODT

EPUB landed the ZIP primitive (`pandoc.zip.create`). docx/ODT add
**XML**: `pandoc.xml.parse(text)` / `serialize(table)` backed by
`quick-xml` on the Rust side. Once that primitive exists, writers
follow the same shape as the EPUB writer. docx has more user demand
than ODT; tackle it first.

### Additional text formats

RST, Org-mode, JATS, AsciiDoc. Medium-effort each, benefit from the
layout engine and whatever markdown scaffolding has landed. Pick by
demand.

### Slide formats — reveal.js, beamer

reveal.js (html-based) is required for HedgeDoc parity
(use-cases §0b) and broadly useful for any editor with a "present"
mode. beamer (latex-based) is the natural follow-up. Both are
writers over pandoc's slide-structured AST (level-1/level-2 header
breaks), reusing the existing html/latex writers with slide-break
handling.

### Reader coverage for existing writers

Right now we read native / djot / html / markdown but write seven
formats. Plausible follow-ups, each a sub-project of its own:

- **`ipynb` reader** (use-cases §0a, JupyterLite) — Jupyter
  notebooks are JSON with markdown / code / raw cells; a thin Lua
  reader over the markdown reader. Priority follow-up once the
  markdown reader overhaul (Next #3) lands.
- **LaTeX, EPUB, RST readers** — larger sub-projects; demand-driven.

### Citeproc

Citation processing is a major sub-project. Defer until there's
demand.

### Syntax highlighting

Integrate a Lua library or expose `syntect` from Rust. Non-trivial
surface area; defer until a writer needs it.

### PDF output

Via external engines (xelatex, tectonic). Mostly a CLI + subprocess
wiring problem once the LaTeX writer is at parity.

### JSON filter protocol

Lower priority — Lua filters are the preferred path and already work.

## Packaging & distribution

### Next release

- `cargo install minipandoc`
- npm package for the WASM build (see Next #2)
- **Published Docker image** `ghcr.io/karlb/minipandoc:alpine` for
  CI adoption (use-cases §3). Zero code, immediate traction — an
  alpine + minipandoc image should land under 10 MB vs
  `pandoc/core`'s ~500 MB.

### Future

- Homebrew tap, Debian package
- `minipandoc --install-format <name>` — fetch format scripts on
  demand
- Format scripts extracted to a separate repository once the count
  justifies independent release cadence

## Performance

Explicit goal: **match or beat pandoc per format, per conversion
direction**. The benchmark harness at `bench/bench_vs_pandoc.sh`
tracks this; current state against pandoc 3.9 is djot 5/5 and
html 4/4 at parity. Record regressions as they land rather than
batch-fixing later.

## Filter ecosystem compatibility

Success-signal #2 ("an existing pandoc Lua filter runs unmodified")
is now exercised per writer by `tests/filter_parity.rs`: one filter
that uses the canonical pandoc 3.x idioms (`el.content[i]`,
`#el.content`, `ipairs`, in-place mutation, `pandoc.utils.stringify`
/ `type`, multi-handler filter tables, nil/false/empty-list/splice
return semantics) is run against native, html, plain, markdown, and
latex, and compared to pandoc 3.9's output. Extend this filter (or
add writer rows) as new writers land and as new idioms surface. That
is the CI-ish corpus call-out; a vendored third-party filter
collection remains a future option but isn't required now that the
canonical idioms are covered end-to-end.

**No longer a gap**: the prior "elements as sequences" note
(`para[1]`, `#para`, `ipairs(para)`) was based on outdated pandoc
docs. Pandoc 3.9 does **not** support sequence-on-element access —
`#el` raises, `el[1] = x` raises, `el[1]` (read) returns `nil` —
so no change in minipandoc is needed to match it. See
[`notes/ast-element-sequence-semantics.md`](notes/ast-element-sequence-semantics.md)
for the empirical verification and resolution. A real bug was fixed
in the process: our filter walker treated `return {}` (pandoc's
idiom for "delete this element") as a no-op splice that injected an
empty table, crashing the native writer downstream. Now `{}` deletes
as expected.

**Wontfix — panluna-style libraries**: libraries like `tarleb/panluna`
branch on `type(x)`; our elements are plain tables (`"table"`) rather
than pandoc's userdata (`"userdata"`), so those libraries misidentify
elements as generic containers. Closing this would require migrating
AST construction back across the mlua boundary — Rust-side `UserData`
impls and field proxies for every element type, breaking the
"AST lives in Lua, Rust doesn't convert on the hot path" principle
from `CLAUDE.md`, touching every reader/writer/filter path, and
complicating `pandoc.read`/`pandoc.write` sub-state recursion (userdata
doesn't cross Lua states). The problem has surfaced exactly once in
project history (vendoring panluna for the markdown reader, routed
around with a ~300-LOC in-tree bridge that ships fine). The
cost/benefit doesn't justify the refactor. Cheaper fix if it ever
matters: upstream a ~5-line patch to the offending library so it
checks `el.tag ~= nil` before falling into the `ipairs` branch — one
fix helps every plain-table-AST consumer, not just minipandoc.

## Success signals

The project matters when:

1. A user writes `minipandoc -f djot -t html input.dj`. **Done.**
2. An existing pandoc Lua filter runs unmodified against minipandoc.
   **Done** for `native`/`djot`; re-verify per format (see Filter
   ecosystem compatibility above).
3. The WASM build loads in a browser and converts markdown to HTML
   under 1 MB compressed. **Done for the MVP cut** — browser target
   works, wasm is 565 KB gzipped (raised from 399 KB by bundled LPeg
   + lunamark; still well under the 1 MB cap), markdown reader
   shipped in the same commit. Ongoing parity work is iterative (see
   Next #2), not a blocker for success-signal #3.
4. A downstream project depends on minipandoc's format scripts.
   **Open** — gated on packaging (Next #2).
