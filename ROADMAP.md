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
  `wasm32-wasip1` unchanged. `scripts/build-wasm.sh` drives the build
  (requires clang 20+ and the wasi-sdk sysroot via `WASI_SYSROOT`).
  `tests/wasi/run-wasi.mjs` runs the `.wasm` under Node's WASI shim;
  `tests/wasi_smoke.rs` is a cargo-integrated smoke test that verifies
  mlua + vendored Lua 5.4 boots and converts djot → html in the wasm
  sandbox. Release wasm: **1.3 MB raw, 399 KB gzipped** — roughly 1/15
  the size of pandoc-wasm, matching the success signal. Browser target
  (`wasm32-unknown-unknown` via `wasm-bindgen`) remains future work —
  mlua's C-Lua path needs libc/setjmp which only `wasip1` (WASI) or
  `emscripten` supply; WASI is lighter and cleaner.
- **`--embed-resources`** — HTML writer inlines referenced `<img src>`
  attributes as `data:<mime>;base64,…` URIs and rewrites the default
  template's `$for(css)$<link>` loop into inline `<style>` blocks via
  `header-includes`. Implies `--standalone`. Rust adds two primitives
  exposed to Lua: `pandoc.mediabag.fetch(source)` (local files only;
  URLs and `data:` sources return `nil, err`) and
  `pandoc._internal.base64_encode(bytes)`. Local paths only;
  `<script src>`, `<video>/<audio>/<source>`, `<embed>`, `<iframe>`,
  and recursive `url(...)` rewriting inside inlined CSS remain future
  work (the HTML writer doesn't emit the former constructs yet). See
  [`notes/embed-resources-url-fetching.md`](notes/embed-resources-url-fetching.md)
  for why URL fetching was deferred.

## Medium-term

The near-term queue is empty — pick the next item from this list based
on what unblocks the most user-visible value.

### HTML reader

Harder than the writer because HTML needs real parsing. Two approaches:
1. Vendor a pure-Lua HTML parser (e.g. `htmlparser`), same pattern as djot.
2. Write one in LPeg.

Unlocks round-trip validation against real HTML content.

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

### Browser WASM target

The WASI build above runs in Node.js and any wasi runtime. Browser
deployment (no filesystem) needs either:
1. `wasm32-unknown-emscripten` with emsdk and the wasmoon-style
   filesystem shim (heavier; ~1 GB of SDK).
2. A Rust/Lua stack without C setjmp/longjmp — e.g. mlua's `luau`
   feature with `wasm32-unknown-unknown`. Loses Lua 5.4 compat, so
   pandoc Lua filters may not run unmodified.

Defer until there's demand from a browser-targeted downstream.

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
