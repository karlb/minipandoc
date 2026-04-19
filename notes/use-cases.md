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

Filtered to projects with sizable user bases where minipandoc fills an
unoccupied niche in the browser. Ranked.

#### 0a. JupyterLite and Jupyter's browser export story

- **Project fit**: JupyterLite is browser-native Jupyter, officially
  maintained by Project Jupyter. Classic Jupyter uses `nbconvert` →
  pandoc for notebook → html / latex / pdf / epub export. JupyterLite
  runs entirely in the browser and has **no equivalent**: the
  Python-side `nbconvert` does not run in-browser, and pandoc has no
  supported browser build. The gap is real and unoccupied.
- **User base**: Jupyter's reach is tens of millions; JupyterLite is
  actively adopted for teaching, docs, interactive books, and the
  Jupyter Book / Executable Books ecosystem.
- **Benefit over pandoc**
  - Fills the nbconvert-in-browser gap nothing else covers.
  - Same wasm serves JupyterLite, classic JupyterLab (via an
    extension), and Jupyter Book's live preview — single artifact.
  - Lua filters let notebook authors apply pandoc-ecosystem
    transformations inside the browser, consistent with server-side
    nbconvert behavior.
- **Blockers (improvements required)**
  - **`ipynb` reader.** Feasible — ipynb is JSON with markdown / code
    / raw cells. Sits on top of our existing markdown reader; a few
    hundred lines of Lua. New work, but small.
  - **Latex writer strengthening.** Current writer is minimal;
    notebook latex export needs code blocks, figures, captions, and
    math rendering. Incremental, not a rewrite.
  - **TeX math in the markdown reader** (already on the cross-cutting
    list — required here too).
- **Upstream shape**: lands as a JupyterLab / JupyterLite extension,
  not a core fork. Low adoption friction compared with renderer swaps.

#### 0b. HedgeDoc / HackMD (collaborative markdown editors)

- **Project fit**: HedgeDoc is actively developed FOSS with thousands
  of self-hosted instances (universities, FOSS orgs, companies);
  HackMD's hosted service has hundreds of thousands of users. Current
  export path: markdown-it → html client-side, plus server-side pandoc
  for pdf / epub / docx on instances that installed it. Server pandoc
  is an operational tax and a source of per-instance inconsistency.
- **Benefit over pandoc**
  - Instances drop the pandoc system dependency — no more "export
    broken because the admin didn't install pandoc".
  - Consistent export across self-hosted instances (today each one
    gets whatever pandoc version its OS ships).
  - Per-request latency improves (no server fork, no subprocess).
  - Client-side export keeps document contents in the browser — a
    real benefit for privacy-sensitive deployments.
- **Blockers (improvements required)**
  - **Slides writer (reveal.js, optionally beamer).** Slideshow
    export is a core HedgeDoc feature, so this is required for parity.
  - **Docx writer** — biggest ask from knowledge-base users (already
    on the cross-cutting list).
  - TeX math in the markdown reader (same as above).
- **Upstream shape**: HedgeDoc maintainers are receptive to
  client-side improvements; likely lands as a frontend PR toggling the
  existing export menu to a wasm path.

### 1. Rust static-site generators (mdBook, Zola) — replacement experiment

Framed as a **replacement experiment**, not a preprocessor / plugin
pitch. The preprocessor pitch is weak: it only helps users who opt in,
and turns the value story into "Zola gains niche capabilities" rather
than a measurable win. The experiment instead asks: *can minipandoc
replace `pulldown-cmark` in an existing Rust SSG, and what does the
output / performance delta look like on a real corpus?* The deliverable
is a research answer, which may or may not lead to upstream adoption.

- **Project fit**: mdBook (`rust-lang/mdBook`, ~19k stars, renders
  `rust-lang/book` and much of the Rust documentation ecosystem) and
  Zola (`getzola/zola`, ~14k stars) both embed `pulldown-cmark`.
  Neither supports djot, pandoc Lua filters, or multi-format output
  beyond what they hand-wire.
- **User base**: large — mdBook in particular is load-bearing for
  official Rust docs, The Rust Reference, the Cargo Book, etc.
- **Benefit if the experiment succeeds**
  - Djot support (pulldown-cmark will never implement it).
  - Pandoc Lua filters as a first-class plugin point, no Rust recompile.
  - Multi-format output (latex/epub/native) from one pipeline.
  - Preserves single-binary distribution — minipandoc is a Cargo lib.
- **Gates, in order**
  1. **CommonMark conformance.** Lunamark predates CommonMark and
     will fail the spec suite on edge cases (list tightness, HTML
     blocks, link resolution, emphasis). pulldown-cmark passes the
     spec, so SSG users depend on those edges whether they know it or
     not. If we're below ~95% on the CommonMark test suite, the
     experiment ends here — measure before investing in the rest.
  2. **GFM parity.** Task lists, strikethrough, autolinks, footnotes,
     and **GitHub-slug auto header ids** (currently our biggest gap —
     silent anchor breakage today).
  3. **Integration surface.** `pulldown-cmark` exposes an *event
     stream*; mdBook/Zola walk it mid-stream to inject syntax
     highlighting and shortcodes. We expose AST + `run()`. Two paths:
     (a) fork the SSG to walk our AST directly (tractable — ~days
     once the reader is ready); (b) build a pulldown-cmark-shaped
     event adapter over our AST (true drop-in, more work). Fork is
     the right experiment shape.
- **Concrete demo path**: fork `rust-lang/mdBook` (smaller and cleaner
  `HtmlHandlebars` renderer than Zola), rebuild on our AST, diff the
  rendered output of `rust-lang/book` against the pulldown-cmark build,
  measure build-time delta. Reusable answer: "here's what replacement
  costs, here's the output/perf gap."
- **Non-gates** (things *not* blocking the experiment)
  - Upstream merge. The artifact is the measurement; adoption is
    downstream of that.
  - Native writer pretty-printing — SSGs don't consume native.
  - Grid tables and TeX math — not core to mdBook/Zola corpora.
- **Known risk — performance.** `pulldown-cmark` is pure Rust and
  very fast; Lua-based reader will be slower. If we're 10× slower on
  a 500-page book, the experiment ends there regardless of feature
  parity. Benchmark on `rust-lang/book` early, **before** investing in
  CommonMark conformance work.

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

Closing these unlocks whole tiers at once. Start with the **two
measurements** below — they are cheap, fast, and determine the scope
of everything that follows. Do not commit to the numbered
implementation blockers until both measurements are in hand.

### Measurements first (do these before any implementation)

- **M1. CommonMark spec-suite pass rate** for our markdown reader.
  Run the canonical spec tests against `scripts/readers/markdown.lua`.
  Determines the scope of blocker 1 and whether the SSG replacement
  experiment (section 1) is even viable at ~95%+ conformance.
- **M2. Markdown-reader throughput** vs `pulldown-cmark` on a large
  corpus (e.g., `rust-lang/book`, ~500 pages). If we're >10× slower,
  section 1 dies regardless of conformance and focus shifts to 0a,
  0b, 3, 6, 7.

### Implementation blockers (post-measurement)

1. **Markdown reader overhaul: CommonMark conformance + GFM (task
   lists, strikethrough, autolinks, footnotes, GitHub-slug auto
   header ids) + grid tables + TeX math.** Largest chunk of work on
   the list; unlocks the SSG replacement experiment, JupyterLite,
   HedgeDoc, and Zettelkasten tools. Scope depends on M1.
   (`scripts/vendor/lunamark/`, amalgamator in `build.rs:72-100`.)
2. **`ipynb` reader.** Unlocks JupyterLite / Jupyter-ecosystem
   targets. New Lua reader on top of the markdown reader; small.
3. **Slides writer — reveal.js (and eventually beamer).** Required
   for HedgeDoc parity and broadly useful for any editor with a
   "present" mode.
4. **Latex writer strengthening** — code blocks, figures, captions,
   math. Required for JupyterLite; widens desktop-editor fit too.
5. **Panluna compatibility fix** — `type` shim that reports
   `"userdata"` for element tables (tracked in
   `tests/panluna_fix_verification.rs`). Opens the door to reusing
   the existing filter library corpus.
6. **Docx writer** (via existing `pandoc.zip.create` + a writer
   script) — biggest feature gap for desktop editors, HedgeDoc, and
   CI.
7. **Published Docker image** `ghcr.io/karlb/minipandoc:alpine` —
   zero code, immediate CI traction.

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
- **M1 — CommonMark spec-suite pass rate**: fetch
  `commonmark/CommonMark` spec tests (the `spec.json` / `spec.txt`
  fixtures), run each input through
  `minipandoc -f markdown -t html`, and diff against the expected
  html. Report pass percentage and top failure categories. Gates
  section 1; scopes blocker 1.
- **M2 — markdown-reader throughput**: clone `rust-lang/book`, run
  `time` over a full render with both `pulldown-cmark` (via mdBook
  itself) and our reader (via `minipandoc -f markdown -t html` over
  every chapter). Ratio > 10× kills section 1 outright.
- **JupyterLite fit**: check `jupyterlite/jupyterlite` and
  `jupyter/nbconvert` issue trackers for "browser export", "client-side
  nbconvert", "pandoc" to gauge demand; validate that an ipynb →
  latex/html/epub extension has no existing browser competitor.
- **HedgeDoc fit**: inspect `hedgedoc/hedgedoc` export code path (look
  for pandoc invocation sites) and open issues tagged `export`, `pdf`,
  `docx` to confirm the operational pain we'd remove.
- **Upstream appetite**: search Zola/mdBook/Obsidian/Logseq/JupyterLite/
  HedgeDoc issue trackers for "pandoc", "djot", "lua filter",
  "client-side export" to gauge demand before pitching.

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

This plan file is a living artifact with two roles:

1. **Shortlist** of target projects with tier-ranked benefits and
   blockers — used to decide where to pitch, where to open PRs, and
   which format/reader gaps to close next.
2. **Prioritized work queue** — the "Cross-cutting blockers" section
   (with its two gating measurements) is the ordered next-action
   list. Update in place as measurements come in, blockers close, or
   upstream-appetite signals shift the priorities.

Current priority pitches: **0a (JupyterLite)** and **1 (mdBook
replacement experiment)**. The experiment's viability is unknown
pending **M1** (CommonMark pass rate) and **M2** (markdown-reader
throughput) — run these first.
