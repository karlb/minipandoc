# Pandoc filter compatibility: AST element sequence semantics

## The gap

Pandoc's [Lua filters guide](https://pandoc.org/lua-filters.html#type-para)
documents that many AST element types can be "treated as a list" of their
primary content:

```lua
-- all idioms pandoc's Lua API promises
para[1]                           -- first inline
#para                             -- inline count
for i, inl in ipairs(para) do ... -- iterate inlines
para[1] = pandoc.Str("x")         -- mutate first inline
```

Real pandoc implements this because its AST elements are Haskell-backed
**userdata**; the metatable provides `__index` / `__newindex` / `__len`
that proxy to the underlying Haskell representation.

Our `scripts/pandoc_module.lua` implements elements as plain Lua tables:

```lua
-- pandoc_module.lua:319
local function make(tag, fields)
  local t = { tag = tag, t = tag }
  for k, v in pairs(fields) do t[k] = v end
  return setmetatable(t, Element)
end
```

`type()` returns `"table"`; content lives under named fields (`content`,
`blocks`, `level`, `text`, ...). There are no integer keys, so:

| idiom                   | real pandoc         | minipandoc today |
|-------------------------|---------------------|------------------|
| `para[1]`               | first inline        | `nil`            |
| `#para`                 | inline count        | `0`              |
| `ipairs(para)`          | iterates inlines    | yields nothing   |
| `para.content[1]`       | first inline        | first inline     |
| `#para.content`         | inline count        | inline count     |
| `para:walk{...}`        | walks the element   | walks the element|

Filters written against the `.content` field path all work. Filters
written against the sequence API silently produce wrong output — no
error, no warning.

Surfaced while wiring the markdown reader (commit `50a9d9d`): trying to
vendor `tarleb/panluna` as the lunamark→pandoc-AST bridge hit exactly
this. Panluna's `unrope` walker branches on `type(x)`:

```lua
-- panluna.lua
elseif typ == 'table' then
  local result = List{}
  for _, item in ipairs(List.map(rope, unrope)) do
    result:extend(item)
  end
  return result
else
  return List{rope}
end
```

In real pandoc, `type(pandoc.Para(...))` is `"userdata"`, hitting the
`else` → element preserved intact. In minipandoc, it's `"table"`,
hitting the recursive branch → `ipairs` yields nothing → element vanishes.
The whole document flattens to empty.

## Why it wasn't caught earlier

- Our own writers (djot, html, markdown-writer, latex, epub, ...) are
  in-tree and access fields directly (`el.content`, `el.blocks`,
  `el.text`). They don't exercise the sequence API.
- The filter-compat checkbox in `ROADMAP.md` was verified for
  "native/djot" by running a handler-style filter. Handler-style
  filters (`function Emph(el) ... end`) use the metatable-dispatched
  field path, so they're unaffected.
- No existing test spins up a filter that indexes elements by integer
  or calls `#el`.

## Scope of the risk

**Safe**: filters that use `function Tag(el) ... end` handlers and
field access. This is the bulk of the ecosystem — pandoc's own `lua-filters`
collection, most one-off project filters, the AST-walk patterns
documented in pandoc's tutorial.

**Broken, silently**: filters or libraries that use
`el[i]` / `#el` / `ipairs(el)` / `el:insert(...)` directly on elements.
Includes any code that was designed to work interchangeably with pandoc's
Haskell userdata representation, e.g. `panluna`, or filters that do
deep walks with `for _, inl in ipairs(para) do ... end`.

**Broken, loudly**: code that checks `pandoc.utils.type(x) == 'Inline'`
— this still works because we implement `pandoc.utils.type` via
metatable lookup, not `type()`.

## Fix sketch

Add metamethods on `Element` so sequence operations proxy to whichever
field is the element's "primary container." In pandoc's model, each
element type has exactly one such field:

| element tag                            | primary container |
|----------------------------------------|-------------------|
| Para, Plain, Emph, Strong, Header, ... | `content`         |
| BlockQuote, Div, Note, Figure          | `blocks`          |
| BulletList, OrderedList                | `content` (list of items) |
| Code, Str, Math, RawInline, RawBlock   | `text`            |
| LineBlock                              | `content` (list of lines) |
| DefinitionList                         | `content`         |
| Table                                  | (composite, no single sequence) |

Sketch in `scripts/pandoc_module.lua` near the Element definition
(line 270):

```lua
local ELEMENT_SEQUENCE_FIELD = {
  Para="content", Plain="content", Emph="content", Strong="content",
  Strikeout="content", Subscript="content", Superscript="content",
  Underline="content", SmallCaps="content", Quoted="content",
  Link="content", Image="content", Span="content", Header="content",
  Cite="content", Note="content",
  BlockQuote="blocks", Div="blocks", Figure="blocks",
  BulletList="content", OrderedList="content",
  DefinitionList="content", LineBlock="content",
}

local original_index = Element.__index
Element.__index = function(self, key)
  if type(key) == "number" then
    local field = ELEMENT_SEQUENCE_FIELD[rawget(self, "tag")]
    if field then return rawget(self, field)[key] end
    return nil
  end
  return original_index(self, key)
end

Element.__newindex = function(self, key, val)
  if type(key) == "number" then
    local field = ELEMENT_SEQUENCE_FIELD[rawget(self, "tag")]
    if field then rawget(self, field)[key] = val; return end
  end
  rawset(self, key, val)
end

Element.__len = function(self)
  local field = ELEMENT_SEQUENCE_FIELD[rawget(self, "tag")]
  if field then return #(rawget(self, field) or {}) end
  return 0
end
```

Simple cases (Para, Emph, ...) work immediately. Complications:

- `Str`, `Code`, etc. have a `text` field that's a string, not a list —
  `#str_el` should return the count of Unicode code points (or bytes).
  Either omit these from the mapping or handle them specially.
- `Table` doesn't have one primary sequence. Pandoc's Lua API returns
  its bodies in `[1]`. Treat it as a special case.
- `Image` / `Link` have a `content` (caption / link text) *and* a
  `target` / `src`. Sequence access goes to content, matching pandoc.

The refactor is ~80 LOC. It doesn't touch vendored code. It doesn't
require changing anything on the writer side — our writers already use
field access.

## Verification plan

1. Add a focused filter-compat integration test: a filter that uses
   sequence indexing and `#el`, run against each writer. Assert the
   output matches a hand-computed golden.
2. Run pandoc's `lua-filters` test corpus (or a curated subset) against
   minipandoc, comparing AST before/after filter. Any filter that
   passes in pandoc 3.9 and fails here is a gap.
3. Re-vendor `tarleb/panluna` as a smoke check once the metamethods
   land — if panluna works unmodified, the compatibility gap is closed
   for the library-level case.

## Current workaround

None in the AST layer. The markdown reader bypasses the issue by
implementing its own writer bridge in-tree
(`scripts/readers/markdown.lua`) — ~300 LOC rather than vendoring
panluna. This is fine for one reader; if a second panluna-class
library shows up we should land the metamethod fix instead of
reinventing the bridge each time.

## Related

- Success-signal #2 in `ROADMAP.md` ("existing pandoc Lua filter runs
  unmodified") should be re-verified against a filter corpus that
  exercises sequence access, not just handler-style filters.
- Pandoc Lua filter reference: <https://pandoc.org/lua-filters.html>
- `pandoc.utils.type` already works correctly because it branches on
  the metatable, not `type()`.
