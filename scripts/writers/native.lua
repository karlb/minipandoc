-- minipandoc builtin: writers/native.lua
-- Emits pandoc's native Haskell-show-style representation.
-- Output is pretty-printed with indentation; compatible with pandoc's
-- native reader (i.e. parses back to the same AST) but does not attempt
-- byte-exact match with pandoc's pretty-printer width heuristics.

local INDENT = "    "

local function esc_string(s)
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  s = s:gsub('\r', '\\r')
  s = s:gsub('\t', '\\t')
  return '"' .. s .. '"'
end

local write_inline, write_block, write_inlines, write_blocks

local function write_attr(a)
  if not a then return '( "" , [] , [] )' end
  local classes = {}
  for _, c in ipairs(a.classes or {}) do classes[#classes+1] = esc_string(c) end
  local kvs = {}
  -- Iterate in insertion order; attributes is an ordered array of {k,v} pairs
  for _, pair in ipairs(a.attributes or {}) do
    kvs[#kvs+1] = "( " .. esc_string(pair[1]) .. " , " .. esc_string(pair[2]) .. " )"
  end
  return string.format("( %s , [%s] , [%s] )",
    esc_string(a.identifier or ""),
    table.concat(classes, " , "),
    table.concat(kvs, " , "))
end

local function write_target(t, title)
  return string.format("( %s , %s )", esc_string(t or ""), esc_string(title or ""))
end

local function write_list(items, fn)
  if #items == 0 then return "[]" end
  local parts = {}
  for _, it in ipairs(items) do parts[#parts+1] = fn(it) end
  return "[" .. table.concat(parts, ", ") .. "]"
end

function write_inline(el)
  local tag = el.tag
  if tag == "Str" then
    return "Str " .. esc_string(el.text)
  elseif tag == "Space" then
    return "Space"
  elseif tag == "SoftBreak" then
    return "SoftBreak"
  elseif tag == "LineBreak" then
    return "LineBreak"
  elseif tag == "Emph" or tag == "Strong" or tag == "Underline"
      or tag == "Strikeout" or tag == "Superscript" or tag == "Subscript"
      or tag == "SmallCaps" then
    return tag .. " " .. write_inlines(el.content)
  elseif tag == "Quoted" then
    return "Quoted " .. el.quotetype .. " " .. write_inlines(el.content)
  elseif tag == "Cite" then
    return "Cite [] " .. write_inlines(el.content)  -- citations stub
  elseif tag == "Code" then
    return "Code " .. write_attr(el.attr) .. " " .. esc_string(el.text)
  elseif tag == "Math" then
    return "Math " .. el.mathtype .. " " .. esc_string(el.text)
  elseif tag == "RawInline" then
    return "RawInline (Format " .. esc_string(el.format) .. ") " .. esc_string(el.text)
  elseif tag == "Link" or tag == "Image" then
    return tag .. " " .. write_attr(el.attr) .. " "
      .. write_inlines(el.content) .. " "
      .. write_target(el.target, el.title)
  elseif tag == "Note" then
    return "Note " .. write_blocks(el.content)
  elseif tag == "Span" then
    return "Span " .. write_attr(el.attr) .. " " .. write_inlines(el.content)
  end
  error("unknown inline tag: " .. tostring(tag))
end

function write_inlines(xs)
  return write_list(xs, write_inline)
end

local function write_list_attrs(la)
  local start = la.start or 1
  local style = la.style or "DefaultStyle"
  local delim = la.delimiter or "DefaultDelim"
  return string.format("( %d , %s , %s )", start, style, delim)
end

function write_block(el)
  local tag = el.tag
  if tag == "Plain" or tag == "Para" then
    return tag .. " " .. write_inlines(el.content)
  elseif tag == "Header" then
    return string.format("Header %d %s %s", el.level,
      write_attr(el.attr), write_inlines(el.content))
  elseif tag == "CodeBlock" then
    return "CodeBlock " .. write_attr(el.attr) .. " " .. esc_string(el.text)
  elseif tag == "RawBlock" then
    return "RawBlock (Format " .. esc_string(el.format) .. ") " .. esc_string(el.text)
  elseif tag == "BlockQuote" then
    return "BlockQuote " .. write_blocks(el.content)
  elseif tag == "BulletList" then
    local items = {}
    for _, item in ipairs(el.content) do
      items[#items+1] = write_blocks(item)
    end
    return "BulletList " .. "[" .. table.concat(items, ", ") .. "]"
  elseif tag == "OrderedList" then
    local la = el.listAttributes or
      { start = el.start, style = el.style, delimiter = el.delimiter }
    local items = {}
    for _, item in ipairs(el.content) do items[#items+1] = write_blocks(item) end
    return "OrderedList " .. write_list_attrs(la) .. " [" .. table.concat(items, ", ") .. "]"
  elseif tag == "DefinitionList" then
    local items = {}
    for _, item in ipairs(el.content) do
      local term, defs = item[1], item[2]
      local dparts = {}
      for _, d in ipairs(defs) do dparts[#dparts+1] = write_blocks(d) end
      items[#items+1] = "( " .. write_inlines(term) .. " , [" .. table.concat(dparts, ", ") .. "] )"
    end
    return "DefinitionList [" .. table.concat(items, ", ") .. "]"
  elseif tag == "HorizontalRule" then
    return "HorizontalRule"
  elseif tag == "Div" then
    return "Div " .. write_attr(el.attr) .. " " .. write_blocks(el.content)
  elseif tag == "Figure" then
    return "Figure " .. write_attr(el.attr) .. " " .. write_caption(el.caption)
      .. " " .. write_blocks(el.content)
  elseif tag == "Table" then
    local parts = {
      "Table", write_attr(el.attr), write_caption(el.caption),
      write_colspecs(el.colspecs or {}),
      write_table_head(el.head),
      write_table_bodies(el.bodies or {}),
      write_table_foot(el.foot),
    }
    return table.concat(parts, " ")
  end
  error("unknown block tag: " .. tostring(tag))
end

function write_blocks(xs)
  return write_list(xs, write_block)
end

function write_caption(c)
  if not c then return "(Caption Nothing [])" end
  local short
  if c.short == nil then
    short = "Nothing"
  else
    short = "(Just " .. write_inlines(c.short) .. ")"
  end
  return "(Caption " .. short .. " " .. write_blocks(c.long or {}) .. ")"
end

function write_colwidth(cw)
  if not cw or cw.tag == "ColWidthDefault" then return "ColWidthDefault"
  elseif cw.tag == "ColWidth" then return "ColWidth " .. tostring(cw.width)
  end
  return "ColWidthDefault"
end

function write_colspecs(cs)
  local parts = {}
  for _, spec in ipairs(cs) do
    local align = spec[1] or "AlignDefault"
    local cw = spec[2] or { tag = "ColWidthDefault" }
    parts[#parts+1] = "( " .. align .. " , " .. write_colwidth(cw) .. " )"
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

function write_row(r)
  local cells = {}
  for _, c in ipairs(r.cells or {}) do
    cells[#cells+1] = "(Cell " .. write_attr(c.attr) .. " "
      .. (c.alignment or "AlignDefault") .. " "
      .. "(RowSpan " .. tostring(c.row_span or 1) .. ") "
      .. "(ColSpan " .. tostring(c.col_span or 1) .. ") "
      .. write_blocks(c.content or {}) .. ")"
  end
  return "(Row " .. write_attr(r.attr) .. " [" .. table.concat(cells, ", ") .. "])"
end

function write_rows(rs)
  local parts = {}
  for _, r in ipairs(rs or {}) do parts[#parts+1] = write_row(r) end
  return "[" .. table.concat(parts, ", ") .. "]"
end

function write_table_head(h)
  h = h or { attr = nil, rows = {} }
  return "(TableHead " .. write_attr(h.attr) .. " " .. write_rows(h.rows) .. ")"
end

function write_table_foot(f)
  f = f or { attr = nil, rows = {} }
  return "(TableFoot " .. write_attr(f.attr) .. " " .. write_rows(f.rows) .. ")"
end

function write_table_bodies(bs)
  local parts = {}
  for _, b in ipairs(bs or {}) do
    parts[#parts+1] = "(TableBody " .. write_attr(b.attr) .. " "
      .. "(RowHeadColumns " .. tostring(b.row_head_columns or 0) .. ") "
      .. write_rows(b.head) .. " " .. write_rows(b.body) .. ")"
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

local function write_meta_value(v)
  if type(v) == "string" then
    return "MetaString " .. esc_string(v)
  elseif type(v) == "boolean" then
    return "MetaBool " .. (v and "True" or "False")
  elseif type(v) == "table" then
    -- List-like = MetaList; has .tag = inline/block; map otherwise
    if v.tag and v.text ~= nil then  -- single Inline
      return "MetaInlines " .. write_inlines({v})
    elseif #v > 0 and type(v[1]) == "table" and v[1].tag then
      -- list of inlines/blocks — assume inlines unless first is block-ish
      return "MetaInlines " .. write_inlines(v)
    elseif #v > 0 then
      local parts = {}
      for _, it in ipairs(v) do parts[#parts+1] = write_meta_value(it) end
      return "MetaList [" .. table.concat(parts, ", ") .. "]"
    else
      local keys = {}
      for k,_ in pairs(v) do keys[#keys+1] = k end
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts+1] = "(" .. esc_string(k) .. " , " .. write_meta_value(v[k]) .. ")"
      end
      return "MetaMap (fromList [" .. table.concat(parts, ", ") .. "])"
    end
  end
  return "MetaString " .. esc_string(tostring(v))
end

local function write_meta(m)
  local keys = {}
  for k,_ in pairs(m or {}) do keys[#keys+1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts+1] = "(" .. esc_string(k) .. " , " .. write_meta_value(m[k]) .. ")"
  end
  return "Meta {unMeta = fromList [" .. table.concat(parts, ", ") .. "]}"
end

function Writer(doc, opts)
  local blocks_out = write_blocks(doc.blocks or {})
  if opts and opts.standalone then
    return "Pandoc " .. write_meta(doc.meta or {}) .. " " .. blocks_out
  end
  return blocks_out
end
