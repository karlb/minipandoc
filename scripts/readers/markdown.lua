-- Markdown reader: thin bridge over our forked lunamark.
--
-- lunamark (jgm/lunamark, forked in-tree at scripts/lunamark/ — see
-- scripts/lunamark/FORKED_FROM) is an LPeg-based markdown parser. It's
-- writer-agnostic: the caller supplies a writer table whose callbacks
-- build up the output. This file supplies a writer that constructs
-- pandoc AST elements directly.
--
-- Panluna (tarleb/panluna) is the canonical pandoc-AST writer for
-- lunamark, but it relies on pandoc's elements being distinguishable
-- from plain tables via Lua's `type()` (they're userdata in real
-- pandoc, falling through its rope-flattening `unrope` function's
-- `else` branch). Our elements in scripts/pandoc_module.lua are plain
-- tables, so unrope recurses into them and erases their content. We
-- therefore implement the writer inline rather than vendor panluna.

local mdreader = require("lunamark.reader.markdown")
local List     = pandoc.List
local utype    = pandoc.utils.type

-- UTF-8 encodings of the smart-punctuation glyphs lunamark asks for.
local MDASH    = "\226\128\148" -- U+2014
local NDASH    = "\226\128\147" -- U+2013
local ELLIPSIS = "\226\128\166" -- U+2026
local NBSP     = "\194\160"     -- U+00A0

-- ---------------------------------------------------------------------------
-- Rope flattening
-- ---------------------------------------------------------------------------
-- Lunamark builds nested-table "ropes" whose leaves are whatever each
-- writer callback returned. To turn a block rope into a Blocks list we
-- walk recursively, keeping AST elements we encounter and skipping
-- sentinels (nil, false, empty tables). Strings collected at inline
-- level become pandoc.Str.

local flatten_inlines, flatten_blocks

function flatten_inlines(out, node)
  if node == nil or node == false or node == "" then return end
  local t = type(node)
  if t == "string" then
    out[#out + 1] = pandoc.Str(node)
  elseif t == "function" then
    flatten_inlines(out, node())
  elseif t == "table" then
    local pt = utype(node)
    if pt == "Inline" then
      out[#out + 1] = node
    elseif pt == "Block" or pt == "Pandoc" then
      -- stray block at inline level — skip defensively
      return
    else
      for _, child in ipairs(node) do flatten_inlines(out, child) end
    end
  end
end

function flatten_blocks(out, node)
  if node == nil or node == false then return end
  local t = type(node)
  if t == "function" then
    flatten_blocks(out, node())
  elseif t == "string" then
    -- stray string at block level → paragraph if non-empty
    if node ~= "" then out[#out + 1] = pandoc.Plain({ pandoc.Str(node) }) end
  elseif t == "table" then
    local pt = utype(node)
    if pt == "Block" then
      out[#out + 1] = node
    elseif pt == "Inline" then
      -- lone inline at block level → wrap in Plain
      out[#out + 1] = pandoc.Plain({ node })
    elseif pt == "Pandoc" then
      for _, b in ipairs(node.blocks) do out[#out + 1] = b end
    else
      for _, child in ipairs(node) do flatten_blocks(out, child) end
    end
  end
end

local function collect_inlines(rope)
  local out = {}
  flatten_inlines(out, rope)
  -- Coalesce adjacent Str nodes. Lunamark tokenizes "word." as
  -- Str "word" + Str "." (its `Symbol` parser fires on the period);
  -- pandoc emits Str "word." — merging here gets us to parity for most
  -- punctuation-adjoining cases.
  local merged = {}
  for _, node in ipairs(out) do
    local last = merged[#merged]
    if node.tag == "Str" and last and last.tag == "Str" then
      last.text = last.text .. node.text
    else
      merged[#merged + 1] = node
    end
  end
  return pandoc.Inlines(merged)
end

local function collect_blocks(rope)
  local out = {}
  flatten_blocks(out, rope)
  return pandoc.Blocks(out)
end

-- ---------------------------------------------------------------------------
-- Attr coercion
-- ---------------------------------------------------------------------------
-- Lunamark hands attributes in a few shapes:
--   nil
--   {id}                           — fenced code with no class
--   {id, classlist}                — fenced code with class
--   {id, classlist, kv_pairs}      — header_attributes etc.
--   { class = "foo" }              — bracketed spans (from a keyword)
-- pandoc.Attr accepts positional or keyword. Normalize.

local function to_attr(a)
  if a == nil then return nil end
  if type(a) ~= "table" then return nil end
  if a.tag == "Attr" then return a end
  -- Keyword form: {class="foo"} or {id="x", class="y z"}.
  -- lunamark's `parsers.attributes` produces this shape and also carries
  -- each `key=value` pair as an ordered {k,v} entry in the array part
  -- so the pandoc AST records them in source order. Walk the array
  -- first; fall back to `pairs()` if a caller built the table by hand
  -- (e.g. fenced-code-block auto-class construction).
  if a.class or a.id then
    local classes = {}
    if a.class then
      for tok in tostring(a.class):gmatch("%S+") do classes[#classes + 1] = tok end
    end
    local kvs = {}
    local seen = {}
    for _, pair in ipairs(a) do
      if type(pair) == "table" and pair[1] then
        local k = tostring(pair[1])
        if not seen[k] and k ~= "id" and k ~= "class" then
          seen[k] = true
          kvs[#kvs + 1] = { k, tostring(pair[2] or "") }
        end
      end
    end
    if #kvs == 0 then
      for k, v in pairs(a) do
        if k ~= "id" and k ~= "class" and type(k) == "string" then
          kvs[#kvs + 1] = { k, tostring(v) }
        end
      end
    end
    return pandoc.Attr(a.id or "", classes, kvs)
  end
  -- Positional: { id, classes, kvs }
  return pandoc.Attr(a[1] or "", a[2] or {}, a[3] or {})
end

-- ---------------------------------------------------------------------------
-- Header auto-id
-- ---------------------------------------------------------------------------
-- Pandoc's `auto_identifiers` extension slugifies the header text when
-- no explicit {#id} is given:
--   1. Strip whitespace; lowercase letters.
--   2. Replace internal whitespace with `-`.
--   3. Drop anything that isn't letter / digit / `_` / `-` / `.`.
--   4. Chop leading non-letters (so an id always starts with a letter).
--   5. Empty result becomes "section".
-- We keep a running set of seen ids so duplicates get -1/-2 suffixes.

local function slugify(text)
  text = tostring(text or ""):lower()
  -- Strip everything not alnum/space/underscore/dash/dot.
  text = text:gsub("[^%w%s%-_%.]", "")
  -- Collapse runs of whitespace to single dashes.
  text = text:gsub("%s+", "-")
  -- Drop leading non-letters.
  text = text:gsub("^[^%a]+", "")
  if text == "" then text = "section" end
  return text
end

-- ---------------------------------------------------------------------------
-- List helpers
-- ---------------------------------------------------------------------------

local function list_items(items, tight)
  local out = {}
  for _, item in ipairs(items) do
    local blocks = collect_blocks(item)
    if tight then
      -- Pandoc "tight" lists: top-level Para → Plain.
      for i, b in ipairs(blocks) do
        if b.tag == "Para" then blocks[i] = pandoc.Plain(b.content) end
      end
    end
    out[#out + 1] = blocks
  end
  return out
end

local function deflist_items(items)
  local out = {}
  for _, item in ipairs(items) do
    local term = collect_inlines(item.term)
    local defs = {}
    for _, def in ipairs(item.definitions) do
      defs[#defs + 1] = collect_blocks(def)
    end
    out[#out + 1] = { term, defs }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Metadata
-- ---------------------------------------------------------------------------
-- Lunamark's YAML metadata parser emits {key = rope_of_inlines} or nested
-- maps. Walk the tree flattening inline ropes to Inlines.

local function collect_meta(tbl)
  local out = {}
  for k, v in pairs(tbl) do
    if type(v) == "table" and v[1] == nil then
      -- Nested map
      out[k] = collect_meta(v)
    else
      out[k] = collect_inlines(v)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

local function make_writer(auto_ids)
  local meta = {}
  local w = {}
  local seen_ids = {}  -- used to uniquify auto-generated header ids

  w.start_document = function() return nil end
  w.stop_document  = function() return nil end
  w.set_metadata   = function(k, v) meta[k] = v end
  w.get_metadata   = function() return collect_meta(meta) end
  w.rope_to_output = function(result) return collect_blocks(result[2]) end

  -- Separator lunamark inserts between sibling blocks. LPeg's `/` only
  -- accepts tables/strings/functions/numbers as capture values, so we
  -- use an empty table — the flattener then iterates nothing and moves
  -- on.
  w.interblocksep  = {}

  -- Inline leaves
  w.string     = function(s) return s end
  w.space      = function() return pandoc.Space() end
  w.linebreak  = function() return pandoc.LineBreak() end
  w.ellipsis   = ELLIPSIS
  w.mdash      = MDASH
  w.ndash      = NDASH
  w.nbsp       = NBSP

  -- Inline containers
  w.emphasis    = function(x) return pandoc.Emph(collect_inlines(x)) end
  w.strong      = function(x) return pandoc.Strong(collect_inlines(x)) end
  w.strikeout   = function(x) return pandoc.Strikeout(collect_inlines(x)) end
  w.subscript   = function(x) return pandoc.Subscript(collect_inlines(x)) end
  w.superscript = function(x) return pandoc.Superscript(collect_inlines(x)) end
  w.singlequoted = function(x) return pandoc.Quoted("SingleQuote", collect_inlines(x)) end
  w.doublequoted = function(x) return pandoc.Quoted("DoubleQuote", collect_inlines(x)) end
  w.code        = function(text, attr)
    -- Normalize code-span content to match pandoc's reader: collapse
    -- embedded newlines to spaces, strip surrounding whitespace. Matches
    -- pandoc 3.9 on `\`foo\``, `\` foo \``, and multi-line `\`\`foo\n\`\``.
    text = text:gsub("\n", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return pandoc.Code(text, to_attr(attr))
  end
  w.link        = function(inlines, url, title, attr)
    return pandoc.Link(collect_inlines(inlines), url, title or "", to_attr(attr))
  end
  w.image       = function(inlines, src, title, attr)
    return pandoc.Image(collect_inlines(inlines), src, title or "", to_attr(attr))
  end
  w.span        = function(inlines, attr)
    local a = to_attr(attr)
    -- Pandoc's bracketed-span syntax `[text]{.smallcaps}` and similar
    -- class-only spans are canonicalized to SmallCaps / Underline nodes.
    if a and a.identifier == "" and (not a.attributes or next(a.attributes) == nil)
       and a.classes and #a.classes == 1 then
      local cls = a.classes[1]
      if cls == "smallcaps" then return pandoc.SmallCaps(collect_inlines(inlines)) end
      if cls == "underline" then return pandoc.Underline(collect_inlines(inlines)) end
    end
    return pandoc.Span(collect_inlines(inlines), a)
  end
  w.rawinline   = function(text, format) return pandoc.RawInline(format, text) end
  w.inline_html = function(text) return pandoc.RawInline("html", text) end

  -- Block containers
  w.paragraph   = function(x) return pandoc.Para(collect_inlines(x)) end
  w.plain       = function(x) return pandoc.Plain(collect_inlines(x)) end
  w.header      = function(content, level, attr)
    local inlines = collect_inlines(content)
    local a = to_attr(attr)
    if auto_ids and (not a or (a.identifier or "") == "") then
      local base = slugify(pandoc.utils.stringify(inlines))
      local id = base
      local n = 1
      while seen_ids[id] do n = n + 1; id = base .. "-" .. n end
      seen_ids[id] = true
      a = pandoc.Attr(id, a and a.classes or {}, a and a.attributes or {})
    end
    return pandoc.Header(level, inlines, a)
  end
  w.blockquote  = function(blocks)
    -- Pandoc wraps paragraph-like content in BlockQuote as Para; lunamark
    -- may emit Plain for the last block (tight-block-separator heuristic).
    -- Convert Plain→Para at the BlockQuote boundary for parity.
    local bs = collect_blocks(blocks)
    for i, b in ipairs(bs) do
      if b.tag == "Plain" then bs[i] = pandoc.Para(b.content) end
    end
    return pandoc.BlockQuote(bs)
  end
  w.hrule       = pandoc.HorizontalRule
  w.verbatim = function(text, attr)
    -- Strip the trailing newline lunamark includes in the code body;
    -- pandoc doesn't preserve it.
    text = text:gsub("\n$", "")
    return pandoc.CodeBlock(text, to_attr(attr))
  end
  w.fenced_code = function(text, lang, attr)
    if not attr then
      attr = (lang and lang ~= "") and { "", { lang } } or nil
    end
    text = text:gsub("\n$", "")
    return pandoc.CodeBlock(text, to_attr(attr))
  end
  w.rawblock    = function(text, format, attr) return pandoc.RawBlock(format, text) end
  w.display_html = function(text) return pandoc.RawBlock("html", text) end
  w.bulletlist  = function(items, tight) return pandoc.BulletList(list_items(items, tight)) end
  w.orderedlist = function(items, tight, startnum, style, delim)
    return pandoc.OrderedList(
      list_items(items, tight),
      pandoc.ListAttributes(startnum or 1, style or "DefaultStyle", delim or "DefaultDelim")
    )
  end
  w.definitionlist = function(items, _tight)
    return pandoc.DefinitionList(deflist_items(items))
  end
  w.lineblock = function(lines)
    local out = {}
    for _, line in ipairs(lines) do out[#out + 1] = collect_inlines(line) end
    return pandoc.LineBlock(out)
  end
  w.div = function(blocks, attr)
    -- Same tight/loose handling as BlockQuote: lunamark may hand us a
    -- Plain for a trailing paragraph-like block, but pandoc always
    -- emits Para at the Div boundary.
    local bs = collect_blocks(blocks)
    for i, b in ipairs(bs) do
      if b.tag == "Plain" then bs[i] = pandoc.Para(b.content) end
    end
    return pandoc.Div(bs, to_attr(attr))
  end

  -- Footnotes: the argument is either a block rope (block notes) or an
  -- inline rope (inline notes). Try block-first; fall back to Plain if
  -- the flattener found only inlines.
  w.note = function(rope)
    local blocks = collect_blocks(rope)
    if #blocks == 0 then
      local inlines = collect_inlines(rope)
      if #inlines > 0 then blocks = pandoc.Blocks({ pandoc.Plain(inlines) }) end
    end
    return pandoc.Note(blocks)
  end

  -- Task list: each item is {"[ ]" or "[x]", item_blocks_rope}. Prepend
  -- a ☐ / ☒ marker inline to the first paragraph / plain block.
  w.tasklist = function(items, tight)
    local rewrapped = {}
    for _, pair in ipairs(items) do
      local marker = (pair[1] == "[ ]") and "\226\152\144 " or "\226\152\146 "
      local body = collect_blocks(pair[2])
      local first = body[1]
      if first and (first.tag == "Para" or first.tag == "Plain") then
        local content = first.content
        content:insert(1, pandoc.Space())
        content:insert(1, pandoc.Str(marker:gsub(" $", "")))
      else
        body:insert(1, pandoc.Plain({ pandoc.Str(marker) }))
      end
      rewrapped[#rewrapped + 1] = body
    end
    return pandoc.BulletList(rewrapped)
  end

  -- Tables: lunamark passes (rows, caption, aligns) where rows is a
  -- list of lists of inline ropes, caption is an inline rope, aligns is
  -- a list of "d"/"l"/"r"/"c". Best-effort pipe-table rendering.
  w.table = function(rows, caption, aligns)
    local function align_of(c)
      if c == "l" then return "AlignLeft"
      elseif c == "r" then return "AlignRight"
      elseif c == "c" then return "AlignCenter"
      else return "AlignDefault" end
    end
    local colspecs = {}
    local headerrow = rows[1] or {}
    for i = 1, #headerrow do
      colspecs[i] = { align_of(aligns and aligns[i] or "d"),
                      { tag = "ColWidthDefault" } }
    end
    local function to_cells(row)
      local cells = {}
      for i, cell_inlines in ipairs(row) do
        cells[i] = pandoc.Cell({ pandoc.Plain(collect_inlines(cell_inlines)) })
      end
      return pandoc.Row(cells)
    end
    local head = pandoc.TableHead({ to_cells(headerrow) })
    local body_rows = {}
    for i = 2, #rows do body_rows[#body_rows + 1] = to_cells(rows[i]) end
    local body = pandoc.TableBody(body_rows)
    local foot = pandoc.TableFoot({})
    local cap = { long = collect_blocks(caption or {}) }
    return pandoc.Table(cap, colspecs, head, { body }, foot)
  end

  -- Citations: pass-through for now. Without `citations` extension the
  -- parser never emits these.
  w.citation  = function(x) return x end
  w.citations = function(text_cites, cites) return cites end

  return w
end

-- ---------------------------------------------------------------------------
-- Extensions: pandoc-name → lunamark option-name mapping.
-- Lifted from tarleb/panluna's M.extensions_to_options (MIT) for parity
-- with pandoc's pandoc-markdown extension vocabulary.
-- ---------------------------------------------------------------------------

local EXT_TO_OPT = {
  blank_before_blockquote        = "require_blank_before_blockquote",
  blank_before_fenced_code_block = "require_blank_before_fenced_code_block",
  blank_before_header            = "require_blank_before_header",
  bracketed_spans                = "bracketed_spans",
  citations                      = "citations",
  definition_lists               = "definition_lists",
  escaped_line_breaks            = "escaped_line_breaks",
  fancy_lists                    = "fancy_lists",
  fenced_code_attributes         = "fenced_code_attributes",
  fenced_code_blocks             = "fenced_code_blocks",
  fenced_divs                    = "fenced_divs",
  hash_enumerators               = "hash_enumerators",
  header_attributes              = "header_attributes",
  inline_notes                   = "inline_notes",
  link_attributes                = "link_attributes",
  line_blocks                    = "line_blocks",
  mark                           = "mark",
  notes                          = "notes",
  pandoc_title_blocks            = "pandoc_title_blocks",
  pipe_tables                    = "pipe_tables",
  raw_attribute                  = "raw_attribute",
  smart                          = "smart",
  startnum                       = "startnum",
  strikeout                      = "strikeout",
  subscript                      = "subscript",
  superscript                    = "superscript",
  task_list                      = "task_list",
}

local function to_lunamark_options(opts)
  -- Pandoc treats bare `-f markdown` as "markdown + default extension
  -- set" — it doesn't run with extensions off unless you write
  -- `markdown_strict`. We start with everything lunamark knows about
  -- enabled, then honor explicit disables from `markdown+foo-bar`.
  local options = {}
  for _, lun in pairs(EXT_TO_OPT) do options[lun] = true end

  local exts = opts and opts.extensions or {}
  if type(exts) == "table" then
    for k, v in pairs(exts) do
      if type(k) == "string" then
        local target = EXT_TO_OPT[k]
        if target then options[target] = v and true or false end
      elseif type(k) == "number" and type(v) == "string" then
        local target = EXT_TO_OPT[v]
        if target then options[target] = true end
      end
    end
  end
  return options
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

Extensions = function()
  local s = {}
  for k in pairs(EXT_TO_OPT) do s[k] = true end
  return s
end

function Reader(input, opts)
  local options = to_lunamark_options(opts)
  -- Pandoc's `auto_identifiers` extension is on for markdown by default.
  -- Our EXT_TO_OPT map doesn't list it (lunamark has no knob; we do it
  -- ourselves), so consult the raw extensions table.
  local exts = opts and opts.extensions or {}
  local auto_ids = true
  if type(exts) == "table" then
    if exts.auto_identifiers == false then auto_ids = false end
  end
  local parser = mdreader.new(make_writer(auto_ids), options)
  -- Several of lunamark's block parsers (NoteBlock, FencedCodeBlock,
  -- Blockquote, …) terminate on `blankline^1`, so a block at EOF without
  -- a trailing blank line causes the parser to fall back to Paragraph.
  -- Pandoc tolerates unterminated blocks at EOF; append a sentinel pair
  -- of newlines so our output matches. Harmless when the input already
  -- ends in whitespace.
  local src = tostring(input)
  if not src:find("\n\n$") then src = src .. "\n\n" end
  local blocks, meta = parser(src)
  blocks = blocks or pandoc.Blocks{}
  -- Lunamark emits writer.plain for paragraph-like blocks that end the
  -- document or lack a trailing blank line. Pandoc only emits Plain
  -- inside tight list items; at the document root, promote back to
  -- Para. List items are not affected because they've already been
  -- tightness-processed inside list_items().
  for i, b in ipairs(blocks) do
    if b.tag == "Plain" then blocks[i] = pandoc.Para(b.content) end
  end
  return pandoc.Pandoc(blocks, meta or {})
end
