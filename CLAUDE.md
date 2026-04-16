# minipandoc — Claude guide

A pandoc-compatible document converter where all format readers/writers are
Lua scripts. The Rust core is a small binary (~1.7 MB release) that provides
the pipeline, the pandoc Lua API, and format resolution. Zero format
knowledge lives in Rust.

## Current state

Readers: `native`, `djot`, `html`. Writers: `native`, `djot`, `html`,
`plain`, `markdown`, `latex`, `epub`. Standalone output via `-s` is
template-driven (pandoc-style doctemplates). EPUB is the first binary
(ZIP-based) format; it uses `ByteStringWriter` + `pandoc.zip.create()`.

Committed milestones:
- `4ef7007` — Phases 1+2: AST, mlua bridge, pipeline, pandoc-compatible CLI, bundled native reader/writer.
- `dd96e7c` — Djot via vendored `jgm/djot.lua` + pure-Lua `pandoc.layout`.
- `1875e27` — HTML writer.
- `93fdb9f` — Plain writer (unblocks djot's complex-table fallback).
- `f9dabf6` — Template engine (`pandoc.template.*`, bundled defaults).

25 tests pass (`cargo test`), including parity against real pandoc when
it's on PATH (tests skip gracefully otherwise).

## Build & test

```
cargo build [--release]
cargo test
./target/debug/minipandoc -f djot -t native fx.dj   # convert file
./target/debug/minipandoc --list-input-formats      # list formats
```

`mlua` is vendored with the `lua54` feature, so no system Lua is required.
`build.rs` regenerates `$OUT_DIR/djot_{reader,writer}.lua` from
`scripts/vendor/djot/` on every vendor-dir change.

## Architecture

```
src/ast.rs        — pandoc-types in Rust (reference; not on the hot path)
src/cli.rs        — clap-derive parser, pandoc-compatible flags
src/format.rs     — format name resolution (data dir + bundled fallbacks)
src/options.rs    — ReaderOptions/WriterOptions passed to Lua
src/pipeline.rs   — read → filters → write orchestration
src/lua/mod.rs    — Lua state setup, pandoc.read/write recursion
src/main.rs       — thin entry point

scripts/pandoc_module.lua — the pandoc.* Lua API (most of it)
scripts/layout.lua        — pandoc.layout pretty-printer
scripts/template.lua      — pandoc.template (doctemplates subset)
scripts/readers/*.lua     — bundled readers (native)
scripts/writers/*.lua     — bundled writers (native, html, plain, epub, …)
scripts/templates/*       — bundled default templates (default.html, default.plain)
scripts/vendor/djot/      — upstream jgm/djot.lua, unmodified
```

Flow: the AST lives in Lua as plain tables with metatables. Rust never
converts to `src/ast.rs` types in the pipeline; that file exists as a
shape reference for future use.

A Lua state is created per conversion. `bootstrap()` in `src/lua/mod.rs`
loads `pandoc_module.lua`, `layout.lua`, and `template.lua`, then
installs `pandoc.read` / `pandoc.write` that recurse into the pipeline
via fresh sub-states. It also injects a Rust-backed
`pandoc.template._load_builtin(name)` that the Lua side calls to
resolve `default.<format>` template lookups against data dirs and the
bundled fallback map.

## Conventions

- **Never modify files under `scripts/vendor/`.** They must match the pinned
  upstream SHA byte-for-byte. If a vendored script needs different behavior,
  fix our pandoc module or the amalgamator, not the vendored code.
  `scripts/vendor/djot/update.sh [SHA]` re-fetches cleanly.
- **Fixtures come from real pandoc**, not hand-written. Djot goldens are
  generated with the vendored reader (`LUA_PATH=... pandoc -f vendor/...`)
  so tests compare like-for-like.
- **Text writer output terminates in a single `\n`** (mimics pandoc). The
  pipeline adds it in `src/pipeline.rs::run` if missing. Binary writers
  (`ByteStringWriter`) return raw bytes with no trailing newline.
- **Release binary target: under 5 MB.** Currently 1.7 MB. Bundled Lua
  scripts are embedded via `include_str!`.
- **Test parity with pandoc semantically**, not byte-for-byte. Our native
  writer emits compact form; pandoc's is pretty-printed. Tests normalize
  both through `pandoc -f native -t native`.

## Adding a new format

1. If upstream ships pandoc-API reader/writer scripts, vendor them under
   `scripts/vendor/<format>/` with an `update.sh`, `COMMIT` (SHA), and
   `LICENSE`. Update `build.rs` if amalgamation is needed.
2. Otherwise write Lua in `scripts/readers/<fmt>.lua` and
   `scripts/writers/<fmt>.lua`.
3. Register in `src/format.rs`: extend `builtin_script` and `builtin_names`.
4. Add fixtures under `tests/fixtures/<fmt>/` with pandoc-generated goldens.
5. Add an integration test in `tests/`. Follow the pattern of
   `djot_parity.rs` (reader semantic parity + writer byte-parity against
   pandoc running the same vendored scripts, with pandoc-absent skip).
6. If the format needs pandoc API surface we don't have, extend
   `scripts/pandoc_module.lua` rather than hacking in the new format script.

## Known limitations

- Native writer is compact, not pretty-printed like pandoc's.
- `pandoc.layout` covers djot-writer's usage; new writers may surface
  missing combinators or edge cases.
- `pandoc.mediabag.*` and `pandoc.system.*` are stubs.
- `pandoc.template` covers `$var$`, `$if/$else/$endif$`,
  `$for/$sep/$endfor$`, `$$`, dotted paths, and pandoc's whitespace
  rule. Partials (`${name}`) and `$var/pattern/repl$` filters are not
  implemented.
- Plain writer's complex-table output uses a grid form but doesn't
  byte-match pandoc's column-width algorithm (smoke-tested only).
- Plain writer doesn't implement texmath: `Math` elements emit raw
  TeX, not pandoc's Unicode rendering.
- No docx/odt support — needs `pandoc.xml` (read/parse). EPUB writing
  works via `pandoc.zip.create()` (Rust-backed) + the Lua epub writer.

## Useful invocations

```
# Regenerate a djot golden:
LUA_PATH="./scripts/vendor/djot/?.lua;;" \
  pandoc -f scripts/vendor/djot/djot-reader.lua -t native fx.dj > fx.native

# Bump the vendored djot SHA:
./scripts/vendor/djot/update.sh <NEW_SHA>

# Verify vendored tree is unmodified:
diff -r <(mktemp_with_upstream_files) scripts/vendor/djot
```
