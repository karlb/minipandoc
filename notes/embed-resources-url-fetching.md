# Why `--embed-resources` defers URL fetching

The current `pandoc.mediabag.fetch(source)` rejects anything starting with
`http://`, `https://`, or `data:` — it only reads local files. Pandoc's
real `--embed-resources` also fetches remote URLs. Adding that isn't a
line-or-two change.

## 1. No HTTP client in the tree

`Cargo.toml` today:

```toml
[dependencies]
mlua = { version = "0.11", features = ["lua54", "vendored"] }
clap = { version = "4", features = ["derive"] }
thiserror = "2"
```

No `reqwest`, no `ureq`, no `hyper`. Adding one means either:

- **`ureq`** (blocking, rustls) — ~600 KB added to the release binary,
  pulls in `rustls` + `webpki-roots`. Still the lightest option. Would
  push us from 1.77 MB toward ~2.3 MB — fine against the 5 MB budget
  but a real size hit for an optional feature.
- **`reqwest`** — drags in `tokio` or requires the `blocking` feature;
  much heavier.
- **`std::net` + hand-rolled HTTP** — doable for HTTP but TLS for HTTPS
  is a hard no (would need a crypto stack).

`CLAUDE.md` calls out "Release binary target: under 5 MB. Currently
1.7 MB" — every dep is scrutinized. An HTTP client for a feature that
works fine on 95% of inputs (local paths) is a questionable trade.

## 2. The WASI/browser story gets ugly

The roadmap already shipped a WASI build (`tests/wasi_smoke.rs`,
~399 KB gzipped) and the long-term target is the browser. Each of
those environments has a different story:

| Environment | Disk read | HTTP |
|---|---|---|
| Native | `std::fs::read` ✓ | needs TLS stack |
| WASI (`wasm32-wasip1`) | `std::fs::read` works if the dir is preopened | **no socket preopens in wasip1 yet**, so `ureq`/`reqwest` don't link. Would need `wasix` or a host-provided fetch shim. |
| Browser | no filesystem | would have to call `fetch()` via `wasm-bindgen` — different API entirely |

So a single `pandoc.mediabag.fetch` implementation that works across
all three targets doesn't exist without platform-specific code. Right
now the local-file path uses `std::fs::read`, which is the one
operation that works uniformly (once you sort out WASI preopens).

## 3. Security and determinism implications

Local-file embed is a pure function of the input. Remote fetch isn't:

- **Network at build-time is surprising.** If someone runs
  `minipandoc -f djot -t html --embed-resources doc.dj` in CI, a
  remote reference silently becomes a live network dependency —
  tests flake, build environments without egress break, and the
  output depends on whatever the remote server returned today.
- **Trust boundary.** Pandoc has `--request-header` and respects
  redirects, timeouts, and size limits. Doing this right means
  exposing configuration for all of that.
- **Cache semantics.** Real pandoc has a resource path search order
  and a mediabag cache. We haven't built either.

## 4. MIME detection from URLs is lossier

`guess_mime` today walks the file extension. URLs often don't have
useful extensions (`https://cdn.example.com/logo?v=3`) or serve
different content than the URL suggests. Proper URL embedding needs
to trust the `Content-Type` response header, which means parsing
HTTP responses, not just bytes.

## 5. What the current code does instead

`src/lua/mod.rs` in `pandoc.mediabag.fetch`:

```rust
if source.starts_with("http://")
    || source.starts_with("https://")
    || source.starts_with("data:")
{
    let msg = lua.create_string(
        &format!("remote fetching not supported: {source}"),
    )?;
    return Ok((Value::Nil, Value::String(msg)));
}
```

And `scripts/writers/html.lua` guards on the same prefixes before
even calling fetch:

```lua
if embed_resources and src ~= ""
   and not src:match("^data:")
   and not src:match("^https?://") then
```

So a remote `<img src="https://…">` passes through unchanged — the
HTML still loads the image at view time, just not as an embedded
data URI. That's a reasonable graceful degradation: the output isn't
self-contained with respect to remote refs, but nothing breaks.

## When to revisit

The roadmap's "Extended compatibility" bullet gives a natural
trigger: if someone builds a downstream that routinely references
CDN-hosted logos/fonts in documents, add `ureq` behind a cargo
feature (`http`), gated off by default for the WASI build. That
keeps the minimal binary small and contains the TLS/platform mess
behind an opt-in.
