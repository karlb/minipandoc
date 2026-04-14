# minipandoc — Roadmap

Long-term direction after Phases 1+2 (Rust core + CLI) and the `djot` format
both landed. Order below reflects a recommended sequence but items are
mostly independent.

## Done

- **Rust core, Lua bridge, pandoc-compatible CLI** (commit `4ef7007`).
- **`native` format** bundled as Lua reader/writer (commit `4ef7007`).
- **`djot` format** via vendored `jgm/djot.lua` + pure-Lua `pandoc.layout`
  (commit `dd96e7c`). Byte-identical writer output to pandoc running the
  same vendored script.
- **HTML writer** (commit `1875e27`) — pure-Lua, ~340 lines at
  `scripts/writers/html.lua`. `minipandoc -f djot -t html input.dj` now
  produces a real deliverable. Semantic round-trip parity against
  pandoc's HTML reader (strict for clean fixtures; smoke-tested where
  HTML can't preserve `Quoted`, `Math`, or raw formats losslessly).
- **Plain writer** (commit `93fdb9f`) — pure-Lua plain writer at
  `scripts/writers/plain.lua`. Unblocks djot's complex-table fallback
  (`pandoc.write(el, "plain")` no longer errors). Byte-parity with
  `pandoc -t plain` on focused fixtures; complex grid tables emitted
  but not byte-matched.
- **Template engine** (commit `f9dabf6`) — pure-Lua doctemplates port at
  `scripts/template.lua` exposing `pandoc.template.{compile,apply,
  default,meta_to_context}`. Supports `$var$`, `$if/$else/$endif$`,
  `$for/$sep/$endfor$`, `$$`, dotted paths, and pandoc's whitespace
  rule for line-only directives. `--template`, `-V`, and `-M` all
  flow through. Bundled `default.html` and `default.plain`; the
  format registry searches `templates/` under data dirs before
  falling back to the bundled defaults. Replaces the html writer's
  hardcoded HTML5 shell.
- **Markdown writer** — pure-Lua pandoc-flavored markdown writer at
  `scripts/writers/markdown.lua` (~600 lines). ATX headers with attr
  blocks, pipe + grid tables, fenced code with info-string, fenced
  divs, footnotes collected to end-of-document, YAML front-matter via
  bundled `default.markdown` template. Parity test skips gracefully
  when pandoc isn't on PATH; smoke-only fallback for fixtures where
  we intentionally diverge (curly quotes, grid-table widths, escape
  set). `minipandoc -f djot -t markdown input.dj` now works.
- **LaTeX writer** — pure-Lua LaTeX writer at `scripts/writers/latex.lua`
  (~500 lines). Section commands with `\hypertarget`/`\label` wrapping
  for ids, `enumitem`-style ordered list labels, `longtable` with
  booktabs rules for simple tables (verbatim-wrapped plain fallback for
  complex), `\footnote{}` inline, `\href`/`\hyperlink` for external vs
  internal links, `\includegraphics` with width/height attrs, figure
  environment with caption/label, `\verb` with auto delimiter picking
  for inline code. Bundled `default.latex` template ships a minimal
  `article` preamble (hyperref, graphicx, ulem, longtable, booktabs).
  `minipandoc -f djot -t latex -s input.dj` now produces a full
  compilable document.
- **WASI build** — the existing CLI binary cross-compiles to
  `wasm32-wasip1` unchanged. `scripts/build-wasm.sh` drives the build;
  it auto-provisions a pinned wasi-sdk (clang + sysroot) under
  `$XDG_CACHE_HOME/minipandoc/` on first run, so zero host setup is
  required beyond rustup.
  `tests/wasi/run-wasi.mjs` runs the `.wasm` under Node's WASI shim;
  `tests/wasi_smoke.rs` is a cargo-integrated smoke test that verifies
  mlua + vendored Lua 5.4 boots and converts djot → html in the wasm
  sandbox. Release wasm: **1.3 MB raw, 399 KB gzipped** — roughly 1/15
  the size of pandoc-wasm, matching the success signal.
- **HTML reader** — pure-Lua reader at `scripts/readers/html.lua`.
  Handwritten tokenizer + block/inline parser (no vendored parser, no
  LPeg) producing pandoc AST directly. Self round-trips against our
  writer on all shareable fixtures and matches pandoc's HTML reader
  semantically on the hand-written `tests/fixtures/html/` fixtures
  (pandoc's syntax-highlighted `sourceCode` soup is smoke-tested only).
  Unknown tags fall back to `RawInline`/`RawBlock (html)`; footnote
  refs + `<section id="footnotes">` are reconstructed back into
  pandoc `Note` elements; `<span class="math">` only recovers to
  `Math` when the content is wrapped in `\(…\)` / `\[…\]` (our
  writer's form) — otherwise it stays as `Span`, matching pandoc's
  reader behavior on rendered-HTML math. `minipandoc -f html -t native
  input.html` now works.
- **Browser target** — the same WASI binary runs unchanged in the
  browser under a pure-JS WASI shim. Vendored
  [`@bjorn3/browser_wasi_shim`](https://github.com/bjorn3/browser_wasi_shim)
  (~20 KB min, zero deps) at `scripts/vendor/browser_wasi_shim/`
  implements `wasi_snapshot_preview1`; `web/minipandoc.mjs` is a small
  ES-module loader exposing `convert(input, from, to, { standalone })`;
  `web/index.html` is a working demo. `scripts/serve-browser-demo.sh`
  starts `python3 -m http.server` after verifying a release wasm is
  built. No emscripten, no `wasm32-unknown-unknown`, no Luau — the
  browser path is a pure JS layer over the existing Lua-5.4-backed
  WASI artifact, so pandoc Lua filters keep working unmodified. Still
  open: a markdown reader (success signal #3's final piece) and a
  packaged npm distribution.

## Medium-term

The near-term queue is empty — pick the next item from this list based
on what unblocks the most user-visible value.

### Markdown reader — the hardest single piece

The original plan flagged this: pandoc's Haskell markdown reader is
~5000 lines with decades of accumulated fixes. Don't start from scratch
in Lua. Options:
1. Vendor `cmark-lua` (CommonMark baseline) + write extension layers on
   top for pandoc-specific syntax.
2. Adapt an existing LPeg-based markdown parser.
3. Call out to a native-code parser via a Rust-side helper.

Pick an approach before committing. Expect weeks of iteration against
pandoc's test corpus.

## Longer-term

### Binary formats (docx, epub, ODT)

Need Rust-side helpers exposed to Lua:
- `pandoc.zip.read(path)` / `write(path, entries)`
- `pandoc.xml.parse(text)` / `serialize(table)`

Add `zip` and `quick-xml` to `Cargo.toml` when this starts. Writers
proceed roughly like the text formats once these primitives exist.

### RST, Org-mode, JATS, AsciiDoc

Medium-effort text formats. Each benefits from the layout engine and
whatever HTML/markdown scaffolding has already landed.

### Citeproc

Citation processing is a major sub-project. Defer until there's demand.

### Extended compatibility

- `--embed-resources`
- YAML metadata parsing
- Syntax highlighting (integrate a Lua library or expose `syntect`)
- PDF output via external engines
- JSON filter protocol (lower priority — Lua filters are preferred)

## Packaging & distribution

- `cargo install minipandoc`
- npm package for the WASM build
- Homebrew, Debian package
- `minipandoc --install-format markdown` — fetch format scripts on demand
- Format scripts as a separate repository once there are enough to need
  independent release cadence

## Success signals

The project matters when:
1. A user writes `minipandoc -f djot -t html input.dj` (Phase: HTML writer).
2. An existing pandoc Lua filter runs unmodified against minipandoc (Phase: done for `native`/`djot`, re-verify per format).
3. The WASM build loads in a browser and converts markdown to HTML under 1 MB compressed (Phase: markdown reader + WASM).
4. A downstream project depends on minipandoc's format scripts (Phase: packaging).
