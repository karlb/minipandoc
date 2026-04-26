# minipandoc

A small, pandoc-compatible document converter where every format
reader and writer is a Lua script. The Rust core (~2.3 MB release
binary, ~400 KB gzipped wasm) provides the pipeline, the `pandoc.*`
Lua API, and format resolution. No format knowledge lives in Rust.

## Status

Readers: `native`, `djot`, `html`, `markdown`.

Writers: `native`, `djot`, `html`, `plain`, `markdown`, `latex`, `epub`.

Standalone output (`-s`) is template-driven and ships defaults for
`html`, `plain`, `markdown`, and `latex`. `--embed-resources` inlines
local images and CSS in HTML output.

Pandoc Lua filters using the canonical 3.x idioms (`el.content[i]`,
`#el.content`, `ipairs`, in-place mutation, multi-handler tables, etc.)
run unmodified — see `tests/filter_parity.rs`. Libraries that branch
on `type(x) == "userdata"` (e.g. `tarleb/panluna`) won't work; our AST
elements are plain Lua tables.

### Caveats

- Markdown reader is a fork of `jgm/lunamark` with grammar fixes;
  ~50% of the CommonMark spec suite passes today
  (see `tests/commonmark_spec.rs`). Block-level work is ongoing for
  specific downstream pitches; full CommonMark/GFM parity is not the
  goal. Grid tables, delimiter-run emphasis, and full HTML-block
  precedence are out of scope.
- Plain writer's complex-table column-width algorithm doesn't
  byte-match pandoc's, and `Math` elements emit raw TeX rather than
  Unicode.
- Native writer output is compact, not pretty-printed.
- `pandoc.template` covers `$var$`, `$if$`, `$for$`, `$$`, dotted
  paths, and pandoc's whitespace rule. Partials (`${name}`) and
  `$var/pat/repl$` filters are not implemented.
- No docx/odt — needs an XML primitive that hasn't landed yet.
  EPUB works because it only needs ZIP.

## Build

```sh
cargo build --release
./target/release/minipandoc -f markdown -t html input.md
```

`mlua` is vendored with the `lua54` feature, so no system Lua is
required. `build.rs` compiles LPeg from `scripts/vendor/lpeg/` against
the same Lua headers and regenerates the amalgamated reader/writer
bundles when vendored sources change.

```sh
cargo test                                  # full suite
./target/debug/minipandoc --list-input-formats
./target/debug/minipandoc --list-output-formats
```

Integration tests that compare against real pandoc skip gracefully
when `pandoc` is not on `PATH`.

## Usage

The CLI mirrors pandoc's flag surface where it overlaps:

```
minipandoc -f FROM -t TO [-o OUT] [-s] [--template FILE]
           [-V key=val] [-M key=val] [-L filter.lua]
           [--embed-resources] [--data-dir DIR] [INPUT...]
```

Examples:

```sh
minipandoc -f djot   -t html  notes.dj
minipandoc -f markdown -t latex -s paper.md -o paper.tex
minipandoc -f markdown -t epub -s book.md -o book.epub
minipandoc -f html -t markdown -L cleanup.lua page.html
```

## Browser / WASM

`scripts/build-wasm.sh` produces a WASI artifact that runs unchanged
in the browser via the vendored `@bjorn3/browser_wasi_shim`. The
script auto-downloads a pinned wasi-sdk into `~/.cache/` on first
run (LPeg is C, so a wasm-targeted clang + sysroot is required);
if you already have wasi-sdk wired up via `CC_wasm32_wasip1` /
`AR_wasm32_wasip1` / `CFLAGS_wasm32_wasip1` / `RUSTFLAGS`, plain
`cargo build --target wasm32-wasip1 --release` works too.
`web/minipandoc.mjs` is the ES-module loader; `web/index.html` is
a demo. Pandoc Lua filters work unmodified there too — the browser
path is the same Lua-5.4 binary.

## Architecture

```
src/ast.rs        pandoc-types in Rust (reference; not on the hot path)
src/cli.rs        clap-derive parser, pandoc-compatible flags
src/format.rs     format resolution (data dir + bundled fallbacks)
src/options.rs    ReaderOptions / WriterOptions passed to Lua
src/pipeline.rs   read → filters → write orchestration
src/lua/mod.rs    Lua state setup, pandoc.read / pandoc.write recursion

scripts/pandoc_module.lua    pandoc.* Lua API
scripts/layout.lua           pandoc.layout pretty-printer
scripts/template.lua         pandoc.template (doctemplates subset)
scripts/readers/*.lua        bundled readers
scripts/writers/*.lua        bundled writers
scripts/templates/*          bundled default templates
scripts/vendor/djot/         upstream jgm/djot.lua, unmodified
scripts/vendor/lpeg/         LPeg 1.1.0 C sources, built by build.rs
scripts/lunamark/            forked jgm/lunamark (markdown reader)
```

The AST lives in Lua as plain tables with metatables; Rust never
converts to `src/ast.rs` types in the pipeline. A fresh Lua state is
created per conversion. `pandoc.read` / `pandoc.write` recurse via
sub-states.

Formats can also be supplied on the CLI without registering them,
matching pandoc's custom-reader/writer convention: `-f ./gemtext.lua`
(literal path) or `-f gemtext.lua` (resolved against
`<data_dir>/custom/`, including `~/.local/share/pandoc/custom/`).
A bare name like `-f gemtext` only resolves built-ins.

Adding a *built-in* format means writing Lua under `scripts/readers/`
or `scripts/writers/` (or vendoring an upstream pandoc-API script
under `scripts/vendor/`) and registering it in `src/format.rs`. See
`CLAUDE.md` for the full procedure and conventions.

## License

MIT OR Apache-2.0. Vendored third-party code retains its original
license — see `scripts/vendor/<name>/LICENSE` and
`scripts/lunamark/FORKED_FROM`.
