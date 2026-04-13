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
- **HTML writer** — pure-Lua, ~340 lines at `scripts/writers/html.lua`.
  `minipandoc -f djot -t html input.dj` now produces a real deliverable.
  Semantic round-trip parity against pandoc's HTML reader (strict for
  clean fixtures; smoke-tested where HTML can't preserve `Quoted`, `Math`,
  or raw formats losslessly). Includes a minimal hardcoded standalone
  HTML5 shell; a full template engine remains a separate roadmap item.

## Near-term (next 1-2 sessions)

### Plain writer — quick unblock

Half a day. The vendored djot-writer falls back to
`pandoc.write(el, "plain")` for complex tables and currently errors
because we have no `plain` builtin. Shipping it unblocks richer table
fixtures and gives us an easy format to validate filters against.

### Template engine

Prerequisite for `-s --standalone` to actually produce full documents
(`<!DOCTYPE html>…<title>{{title}}</title>…`). Accepted as a flag today
but silently ignored. ~500 lines of Lua or port of pandoc's
`doctemplates`. Blocks HTML/LaTeX writers from emitting standalone docs.

## Medium-term

### HTML reader

Harder than the writer because HTML needs real parsing. Two approaches:
1. Vendor a pure-Lua HTML parser (e.g. `htmlparser`), same pattern as djot.
2. Write one in LPeg.

Unlocks round-trip validation against real HTML content.

### LaTeX writer

Uses `pandoc.layout`, conceptually similar to djot-writer. Larger scope
(math, citations, figures with captions) but mostly combinator work.

### Markdown writer

Pandoc-flavored markdown with extensions (smart, pipe tables, task lists,
raw blocks). Uses `pandoc.layout`. Medium-large — lots of edge cases in
escaping.

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

### WASM target — orthogonal, architecturally important

The project's unique value proposition vs `pandoc-wasm`: Lua support
intact, ~1/15th the size. `mlua` supports `wasm32-unknown-unknown` /
`wasm32-wasi` with the right features. Format scripts already embed via
`include_str!`, so bundling works out of the box.

Work: Cargo feature gating, `wasm-bindgen` or manual JS wrapper, browser
+ Node.js smoke tests. A couple days if the dependency graph cooperates.

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
