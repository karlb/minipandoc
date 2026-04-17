# minipandoc — Roadmap

Long-term direction. The Rust core, pandoc-compatible CLI, and a working
set of readers/writers have landed; the open questions now are which
formats to add next, how close to match pandoc's output byte-for-byte,
and how to ship the artifact.

## Done

Readers: `native`, `djot`, `html`. Writers: `native`, `djot`, `html`,
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

### 1. npm package for the WASM build

The browser target works end-to-end and the wasm is 399 KB gzipped.
Packaging unblocks downstream adoption and exercises the stable
public API surface (`convert(input, from, to, opts)` in
`web/minipandoc.mjs`). Success-signal #4 depends on this.

### 2. Markdown reader — iterate on parity

Landed (commit will be labelled once squash/push happens): LPeg 1.1.0
+ `jgm/lunamark` are vendored; `scripts/readers/markdown.lua` is an
in-tree bridge that drives lunamark with a handwritten pandoc-AST
writer. 7 of 15 canonical fixtures pass strict AST parity with
pandoc 3.9; 8 are smoke-only pending follow-ups (see
`tests/markdown_reader_parity.rs` `SMOKE_ONLY` and the "Known
limitations" section of `CLAUDE.md`). `cmark-lua` (the ROADMAP's
original recommendation) turned out to be a SWIG wrapper around
`libcmark` — not portable to `wasm32-wasip1` — so we went with
LPeg + lunamark instead, matching pandoc's own custom-reader
convention (`pandoc.lpeg` / `pandoc.re`).

Next iterations, in rough priority order:
- Unindented footnote bodies (pandoc's default writer form).
- Nested bullet / ordered lists (biggest semantic gap).
- Key-value attribute propagation on headers / link_attributes.
- Pandoc's "simple" indented table form.
- Grid tables (lunamark doesn't parse these at all).
- `escaped_line_breaks` → SoftBreak parity.

This unblocks success-signal #3 end-to-end; the parity scorecard
will catch regressions as each gap closes.

## Polish

Small, individually tractable items mostly surfaced in CLAUDE.md's
"Known limitations" section. Can be picked up opportunistically
between milestones.

- **Template engine**: partials (`${name}`), `$var/pattern/repl$`
  filters.
- **Plain writer**: byte-match pandoc's column-width algorithm for
  complex tables; implement texmath (Unicode rendering for `Math`
  elements) instead of raw TeX passthrough.
- **Native writer**: pretty-printing to match pandoc's output form.
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

### Reader coverage for existing writers

Right now we read native / djot / html but write seven formats. A
markdown reader lands with Next #3; LaTeX, EPUB, and RST readers
are plausible follow-ups, each a sub-project of its own.

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
was demonstrated for native and djot but hasn't been re-verified
per format. Track a small canonical set of third-party filters and
re-run them against each writer on release. Candidates:
- `pandoc-lua-filters/` collection (per-element transforms)
- simple AST rewriters (walk-and-replace patterns)
- stubs for `pandoc-crossref`, `pandoc-citeproc` (parity for
  surface API only; full citeproc is a separate effort)

Add a CI job that runs the filter set once the list exists.

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
