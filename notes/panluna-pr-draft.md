# Draft PR to `tarleb/panluna` — preserve plain-table AST elements in `unrope`

Status: **verified locally, ready to send upstream.** The fix is
exercised by `tests/panluna_fix_verification.rs` against the vendored
copy under `scripts/vendor/panluna/` and passes.

Target upstream SHA at drafting time:
[`819431eb`](https://github.com/tarleb/panluna/commit/819431eb723257af5769253652c377900ecce296).

---

## Title

`Preserve plain-table AST elements in unrope`

## Body

### Problem

`unrope` (panluna.lua:46–55) distinguishes a rope (nested table of
items) from a leaf (a pandoc AST element) via `type()`:

```lua
local function unrope (rope)
    local typ = type(rope)
    if typ == 'nil' then
      return List{}
    elseif typ == 'table' then
      local result = List{}
      for _, item in ipairs(List.map(rope, unrope)) do
        result:extend(item)
      end
      return result
    elseif typ == 'function' then
      return unrope(rope())
    else
      return List{rope}
    end
end
```

In pandoc itself, AST elements are `userdata`, so they hit the final
`else` branch and are preserved. In alternative pandoc-compatible Lua
runtimes that back the AST with plain tables
(e.g. [minipandoc](https://github.com/karlb/minipandoc)),
`type(pandoc.Para(...))` is `"table"`. Such elements fall into the
`table` branch and get recursed into. Because their keys are named
(`tag`, `content`, …), not integer, `ipairs` yields nothing and the
element silently disappears.

### Proposed change

```diff
-    elseif typ == 'table' then
+    elseif typ == 'table' and rope.tag == nil then
```

### Why it's safe

- **Pandoc unchanged.** Userdata elements never match
  `typ == 'table'`, so the new guard is only ever evaluated on
  tables. Behavior on pandoc itself is unaffected.
- **Real ropes unaffected.** Rope-shaped values are
  `List`s/tables with integer keys and no `tag` field. They still
  flatten.
- **Plain-table AST elements preserved.** Tables carrying a `tag`
  field fall through to the `function` / `else` branches and
  become leaves — matching the userdata path.

`tag` is part of pandoc's documented Lua API for elements
(`para.tag == "Para"`, etc.), so the check relies on the public
surface, not on an implementation detail.

### Test

```lua
local fake_para = { tag = "Para", content = { { tag = "Str", text = "hi" } } }
assert.same({ fake_para }, unrope({ fake_para }))
```

Fails on `main`; passes with the guard.

### Why it matters

Dispatching on `tag` (documented API) rather than `userdata` vs
`table` (FFI detail) keeps panluna useful across every
pandoc-compatible Lua runtime — present and future — at no
maintenance cost.

---

## Alternative considered

`pandoc.utils.type(x) == 'Inline'` / `'Block'` would also
disambiguate AST elements from ropes, but it depends on
`pandoc.utils` being loaded and on the runtime wiring `pandoc.utils.type`
to dispatch via the element's metatable. The `tag`-field check is
simpler and more portable. Happy to switch to the `pandoc.utils`
form if preferred.

## Verification performed locally

See `tests/panluna_fix_verification.rs` in this repo. The test:

1. Reads the vendored `scripts/vendor/panluna/panluna.lua`.
2. Loads it once unchanged, once with the one-line gsub above.
3. Calls `unrope({plain_table_Para})` on both.
4. Asserts: unpatched returns an empty list (element lost);
   patched returns a list of length 1 whose first element is the
   same Para with its `tag` preserved.

Outcome recorded inline here once the test lands (see
"Verification" section below).

## Verification

Ran `cargo test --test panluna_fix_verification` against vendored
panluna at SHA `819431eb`. Result: **passes**.

The test loads `scripts/vendor/panluna/panluna.lua` twice (once as
shipped, once with the one-line gsub above) and calls `unrope` on a
plain-table `pandoc.Para` constructed via minipandoc's Lua API:

- **Unpatched**: `#unrope({para})` returns `0` — the element
  silently vanishes, confirming the reported bug on non-userdata
  runtimes.
- **Patched**: `#unrope({para})` returns `1` and the first item is
  the same `Para` reference with its `tag` intact.

Full source: `tests/panluna_fix_verification.rs` +
`tests/panluna_fix_verification_filter.lua`. One caveat for
reviewers: panluna uses `require 'pandoc'` / `require 'pandoc.utils'`
/ `require 'pandoc.List'` at the top of the module. Our test wires
those into `package.preload` before loading, because minipandoc
exposes `pandoc` as a global rather than via the Lua module loader.
Real pandoc already registers these loaders, so no change is needed
on the upstream side.
