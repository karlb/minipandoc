# Projects that could benefit from minipandoc

## Context

The user wants a candidate list of real-world projects where swapping (or
adopting) minipandoc would give an **objective, measurable** benefit over
pandoc — not vague "smaller is nicer" — together with the concrete blockers
that would have to be cleared first. This informs where to pitch the
project, where to open PRs, and which gaps to close next.

Findings below are grounded in a capability audit of minipandoc at HEAD.

## minipandoc's unique value props (confirmed)

Confirmed against the source (see file:line refs):

- **Binary size 2.3 MB** stripped, single static-ish ELF; `pandoc` is
  ~170 MB, `pandoc/core` Docker image is ~500 MB (Cargo.toml:26-29,
  `target/release/minipandoc`).
- **Full Rust library surface**: `[lib]` in Cargo.toml:8-10 re-exports
  `pipeline::{Config,run,Error}`, `ast`, `format::FormatRegistry`,
  `lua::bootstrap` (`src/lib.rs:1-11`). Any Rust crate can
  `cargo add minipandoc` and convert in-process — no `Command::spawn`,
  no binary dependency, no PATH lookup.
- **Pandoc-compatible CLI and filter API** (subset). Filter idioms
  covered in `tests/filter_parity.rs`.
- **Formats shipped today**
  - Readers: `native`, `djot`, `html`, `markdown` (lunamark-based).
  - Writers: `native`, `djot`, `html`, `plain`, `markdown`, `latex`, `epub`.
- **Standalone (`-s`) works** for html / latex / markdown / plain
  (bundled templates in `scripts/templates/`; `src/format.rs:189-192`).
- **Lua-extensible**: add a reader/writer without recompiling the Rust.
- **Ships as WASI wasm** (`scripts/build-wasm.sh`, `wasm32-wasip1`):
  release wasm **~1.3 MB raw / ~565 KB gzipped** (ROADMAP.md:46, 239).
  Runs in-browser via `web/minipandoc.mjs` + `browser_wasi_shim`, and
  in Node via `node:wasi` (`tests/wasi/run-wasi.mjs`). This is the
  differentiator pandoc has no answer to — pandoc's Haskell runtime has
  no supported browser build.

### Value props that do **not** hold (ruling these out up front)

- **C FFI / non-wasm embedding**: no `extern "C"` surface, no cbindgen.
  But WASI gives a **language-neutral** embedding boundary: any host
  that can run wasm + wasi_snapshot_preview1 (Node, browsers,
  wasmtime, wasmer, wazero, wasmedge) can embed minipandoc without a
  Rust toolchain. This covers Go, Python, Ruby, Java, .NET, Deno,
  Bun, Cloudflare Workers, Fastly Compute@Edge, etc.
- **Drop-in pandoc replacement**: no docx / odt / rst / org / asciidoc /
  commonmark-as-distinct / PDF. Filters that `type()`-check for
  `"userdata"` (panluna) silently corrupt documents
  (`scripts/readers/markdown.lua:8-14`).

So the addressable audience is **anywhere that processes
markdown/djot/html → html/markdown/latex/djot/plain/epub** — native
Rust apps, containerized pipelines, **browsers**, serverless/edge
runtimes, and any wasm-capable host language.

---

## Tier 1 — clear, defensible wins

### 0. In-browser / client-side document conversion (the headline win)

- **Project fit**: any web app that today either ships a partial
  JS markdown renderer (marked, markdown-it, remark) or round-trips
  documents through a pandoc server. Concrete candidates:
  StackEdit-style online editors, GitHub/GitLab's client-side
  markdown preview, Docusaurus / Nextra / VitePress live-preview
  plugins, Observable-style notebooks, online djot playgrounds,
  privacy-preserving "cloudconvert lite" UIs.
- **Benefit over pandoc**
  - Pandoc has **no supported browser build** (GHC-wasm is early and
    the output is orders of magnitude larger). Minipandoc ships a
    ~565 KB gzipped wasm today.
  - Zero server round-trip → latency, privacy, offline, and cost wins
    all compound.
  - Same Lua filter story works in the browser — users can write one
    filter and run it in CI, desktop, and the web playground.
- **Blockers**
  - wasi-sdk requires the `__wasi_init_tp` stub (documented in the
    harness) — trivial but surprising.
  - Format coverage limits still apply: no docx/pdf in the browser.
  - Size budget: 565 KB gzipped is great, but if a host app was
    already using markdown-it (~60 KB), switching costs ~500 KB.

### 1. Rust static-site generators (Zola, Cobalt, mdBook)

- **Project fit**: Zola (`getzola/zola`) and mdBook (`rust-lang/mdBook`)
  use `pulldown-cmark`, which has no pandoc filter API, no djot, no
  templated standalone pipeline beyond their own. Users routinely ask
  for pandoc-style features (cross-refs, citations-lite, Lua filters).
- **Benefit over pandoc**
  - mdBook/Zola can embed minipandoc as a **library** (Cargo dep) and
    keep their single-binary distribution story. Shelling out to pandoc
    would break it.
  - Adds djot support, a growing pandoc-adjacent format pulldown-cmark
    will never implement.
  - Lua filters give users a plugin point without Rust recompiles.
- **Blockers**
  - Markdown reader gaps: grid tables, TeX math, auto header ids (see
    CLAUDE.md "Known limitations"). Without auto ids, anchor links break.
  - Upstream buy-in: Zola's maintainers prize minimalism and are unlikely
    to take a second renderer unless it's opt-in.
  - Output byte-parity with pandoc not guaranteed (native compact form);
    user-facing html is fine, but snapshot tests would churn.

### 2. Rust desktop markdown/note editors (Tauri / egui / iced)

- **Project fit**: editors like `getmarker/marker`, Tauri-based markdown
  previewers, Zed's markdown preview path, forthcoming Rust-based Obsidian
  clones. They either bundle nothing (weak export) or bundle pandoc
  (~170 MB in the installer).
- **Benefit over pandoc**
  - Installer shrinks by ~150 MB — noticeable for notarized macOS
    / signed Windows installers shipped via auto-update.
  - In-process conversion: no subprocess latency on "Preview" / "Export"
    clicks; no shell escaping; no PATH dependency on end-user machines.
  - Lua filters let users customize export without a plugin SDK.
- **Blockers**
  - No docx / pdf export — those are the two formats users most expect
    from "Export". minipandoc can produce latex → user runs tectonic,
    but that adds a toolchain.
  - html/css theming for preview already solved by pulldown-cmark for
    many editors; switching needs a reason beyond export.

### 3. CI / GitHub Actions doc-conversion images

- **Project fit**: anyone using `docker://pandoc/core`,
  `pandoc/minimal`, or `pandoc-action/` for markdown/djot → html /
  latex / epub conversion in release pipelines.
- **Benefit over pandoc**
  - Image size: `pandoc/core` is ~500 MB, `pandoc/minimal` ~170 MB. An
    alpine + minipandoc image is realistically <10 MB.
  - CI cold-pull time drops from ~10–30 s to sub-second, multiplied
    across every job.
  - Startup time: pandoc Haskell startup is ~150 ms; minipandoc is
    essentially Rust startup + Lua state init.
- **Blockers**
  - Workflows that pandoc-convert to docx or pdf can't switch at all.
  - No official published image yet — someone has to build and maintain
    `ghcr.io/karlb/minipandoc`.

### 4. Replacing the `pandoc` Rust crate (`oli-obk/rust-pandoc`)

- **Project fit**: Rust crates that wrap pandoc today by spawning the
  binary (`oli-obk/rust-pandoc` and its reverse-deps on crates.io —
  mdslides, pandoc-ast consumers, static-site toys, cv-generators,
  some Zola plugins).
- **Benefit over pandoc**
  - Eliminates a runtime system dependency (users don't need pandoc
    installed, CI doesn't need to `apt install pandoc`).
  - No subprocess overhead; direct AST access via `pipeline::Config`.
  - Deterministic build: `cargo build` gets you a converter, full stop.
- **Blockers**
  - API shape is different (minipandoc is Config + run, not a fluent
    builder). Migrating crates need a thin shim.
  - Any caller that relied on pandoc's full format matrix breaks.

### 5. Rust-native Zettelkasten / note-graph tools

- **Project fit**: `marksman`, `vault.nvim` backends, any future
  Rust-port of `zk-org/zk` (Go, shells to pandoc). Use cases:
  rendering previews, exporting single notes, running structural
  filters over a corpus.
- **Benefit over pandoc**
  - Per-note conversion cost drops meaningfully when walking thousands
    of notes (no process fork).
  - Filters can compute backlinks / wikilinks as a Lua pass instead of
    a second tool chain.
- **Blockers**
  - Wikilink `[[…]]` syntax isn't in our markdown reader; would need a
    small extension (feasible — it's Lua).
  - No built-in citation processor (pandoc has pandoc-citeproc).

---

### 6. Electron-based note apps (Obsidian, Logseq, Joplin plugins)

Moved up from Tier 2 now that the wasm path is confirmed.

- **Project fit**: Obsidian, Logseq, Joplin, Standard Notes — all run
  in Electron (Chromium + Node). They either bundle pandoc (huge
  installer/plugin payload) or do without it.
- **Benefit over pandoc**
  - Plugin size drops from ~150 MB (bundled pandoc per-OS) to ~1 MB
    wasm. Install-time and update-time both improve dramatically.
  - Electron's Node side can use `node:wasi` (see
    `tests/wasi/run-wasi.mjs`) or the renderer side can use the
    browser shim — same wasm binary, either host.
  - No subprocess / PATH / code-signing issues with bundling an
    external binary.
- **Blockers**
  - No docx/pdf — biggest ask for these apps.
  - Lua filters from pandoc's user corpus mostly work, but any
    panluna-based filter silently corrupts (same as elsewhere).

### 7. Serverless / edge runtimes (Cloudflare Workers, Fastly C@E, Deno Deploy)

- **Project fit**: edge functions that convert user-submitted docs —
  webhooks that render release notes to html, comment preview APIs,
  on-the-fly readme rendering. Today these either call a pandoc HTTP
  service or live without pandoc features.
- **Benefit over pandoc**
  - Pandoc can't run at the edge at all. Workers/C@E are wasm-native
    and explicitly support WASI; a 565 KB gzipped module fits the
    bundle size caps comfortably.
  - No cold-start fork, no network hop to a pandoc service.
- **Blockers**
  - Some edge runtimes restrict filesystem preopens — would need
    stdin/stdout-only conversion mode (currently CLI accepts a file
    path; wasi preopen of an in-memory file works per `web/*.mjs`).
  - Per-request memory limits need validation for large documents.

---

## Tier 2 — plausible but conditional

- **Hugo / Jekyll users who shell to pandoc for one format**: CI win
  only; adoption friction because Hugo has its own renderer.
- **Quarto**: deeply coupled to pandoc's full surface (docx, reveal.js,
  crossref, citeproc). Not realistic until minipandoc covers ~5× more.
- **Academic tooling (papis, zotero scripts)**: benefits minimal;
  citations aren't covered.
- **Non-Rust server embeddings** (Go/Python/Ruby/Java services that
  want in-process conversion): wasmtime/wasmer bindings work, but
  ecosystem ergonomics (no idiomatic crate per language) mean most
  teams will pick native libs instead until someone publishes a
  wrapper.

## Not feasible today

- Anything needing **docx / pdf / odt / rst / org / asciidoc**.
- Filter ecosystems built on **panluna** or other
  `type(x) == "userdata"` branches.

## Cross-cutting blockers to close next (highest leverage)

Closing these unlocks whole tiers at once:

1. **Markdown reader: grid tables + auto header ids + TeX math.**
   Required for Zola/mdBook parity and for Zettelkasten tools.
   (`scripts/vendor/lunamark/`, amalgamator in `build.rs:72-100`.)
2. **Panluna compatibility fix** — `type` shim that reports `"userdata"`
   for element tables (tracked in `tests/panluna_fix_verification.rs`).
   Opens the door to reusing the existing filter library corpus.
3. **Docx writer** (via existing `pandoc.zip.create` + a writer script) —
   single biggest feature gap for desktop editors and CI.
4. **Published Docker image** `ghcr.io/karlb/minipandoc:alpine` — zero
   code, immediate CI traction.

## Verification / how to validate the research

- **Native binary size**: `cargo build --release && du -h
  target/release/minipandoc`.
- **Wasm size**: `scripts/build-wasm.sh release && ls -la
  target/wasm32-wasip1/release/minipandoc.wasm && gzip -c … | wc -c`
  (expect ~1.3 MB raw / ~565 KB gz per ROADMAP.md:239).
- **Browser end-to-end**: `scripts/serve-browser-demo.sh`, open
  `web/index.html`, run a djot→html conversion in devtools.
- **Node WASI**: `node tests/wasi/run-wasi.mjs -f djot -t html
  tests/fixtures/djot/basic.dj`.
- **Library API**: 20-line Rust example calling
  `pipeline::run(&Config { … })` for md→html.
- **Docker size**: `FROM alpine; COPY minipandoc /usr/bin/`; `docker
  images` vs `pandoc/core`.
- **Format coverage**: `minipandoc --list-input-formats`/
  `--list-output-formats`.
- **Pandoc crate reverse-deps** (for Tier 1.4): `cargo search pandoc`
  and crates.io reverse-dependency page.
- **Upstream appetite**: search Zola/mdBook/Obsidian/Logseq/Docusaurus
  issue trackers for "pandoc", "djot", "lua filter" to gauge demand
  before pitching.

## Critical files (reference, read-only for this task)

- `Cargo.toml` — lib surface, release profile.
- `src/lib.rs`, `src/pipeline.rs` — public embedding API.
- `src/format.rs` — `builtin_names` / `builtin_script` (authoritative
  format list).
- `scripts/readers/markdown.lua` — panluna incompatibility comment.
- `CLAUDE.md` — "Known limitations" section.
- `tests/filter_parity.rs`, `tests/panluna_fix_verification.rs` — the
  filter-API story.

## Deliverable

This plan file itself is the deliverable — a researched shortlist of
target projects with concrete, tier-ranked benefits and blockers. No
code changes required.
