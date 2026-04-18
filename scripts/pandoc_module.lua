-- minipandoc: Lua-side definition of the pandoc.* module.
-- Loaded once per Lua state during startup.
-- The host (Rust) may inject additional entries (pandoc.read, pandoc.write, etc.)
-- after this script runs, by assigning to the returned table.

local pandoc = {}
pandoc.utils = {}
pandoc.mediabag = {}
pandoc.path = {}
pandoc.system = {}
pandoc.template = {}

-- ---------------------------------------------------------------------------
-- pandoc.List
-- ---------------------------------------------------------------------------

local List = {}
List.__index = List
List.__name = "List"

function List.new(t)
  t = t or {}
  return setmetatable(t, List)
end

pandoc.List = {}

function List:clone()
  local out = {}
  for i, v in ipairs(self) do
    if type(v) == "table" and type(v.clone) == "function" then
      out[i] = v:clone()
    else
      out[i] = v
    end
  end
  return List.new(out)
end

function List:map(f)
  local out = {}
  for i, v in ipairs(self) do out[i] = f(v) end
  return List.new(out)
end

function List:filter(f)
  local out = {}
  for _, v in ipairs(self) do
    if f(v) then out[#out + 1] = v end
  end
  return List.new(out)
end

function List:includes(needle, eq)
  eq = eq or function(a, b) return a == b end
  for _, v in ipairs(self) do if eq(v, needle) then return true end end
  return false
end

function List:find(needle, init)
  for i = (init or 1), #self do
    if self[i] == needle then return self[i], i end
  end
  return nil
end

function List:find_if(pred, init)
  for i = (init or 1), #self do
    if pred(self[i]) then return self[i], i end
  end
  return nil
end

function List:insert(pos, val)
  if val == nil then
    -- one-arg form: insert at end
    table.insert(self, pos)
  else
    table.insert(self, pos, val)
  end
end

function List:remove(pos)
  return table.remove(self, pos)
end

function List:extend(other)
  for _, v in ipairs(other) do self[#self + 1] = v end
  return self
end

function List:__concat(other)
  local out = self:clone()
  for _, v in ipairs(other) do out[#out + 1] = v end
  return out
end

function List:__eq(other)
  if #self ~= #other then return false end
  for i = 1, #self do
    if not deep_eq(self[i], other[i]) then return false end
  end
  return true
end

-- Forward declare
function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if a.tag ~= b.tag then return false end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

pandoc.List.__index = List
pandoc.List.__name = "List"
-- Expose methods both ways: `list:map(f)` (via List metatable on instances)
-- and `pandoc.List.map(list, f)` (static form that pandoc's real module
-- also supports and that e.g. panluna relies on). Metatable __index on
-- pandoc.List makes the unbound method lookup resolve to List.
setmetatable(pandoc.List, {
  __call = function(_, t) return List.new(t) end,
  __index = List,
})

-- ---------------------------------------------------------------------------
-- Attr
-- ---------------------------------------------------------------------------

local Attr = {}
Attr.__index = Attr
Attr.__name = "Attr"

function Attr:clone()
  return pandoc.Attr(self.identifier, List.new(self.classes):clone(),
    clone_kvs(self.attributes))
end

function clone_kvs(kvs)
  local out = {}
  for k, v in pairs(kvs) do out[k] = v end
  return out
end

function pandoc.Attr(identifier, classes, attributes)
  if type(identifier) == "table" and getmetatable(identifier) == Attr then
    return identifier
  end
  -- Accept positional 3-tuple: {"id", [classes], [kvs]}
  if type(identifier) == "table" and identifier.tag == nil
      and classes == nil and attributes == nil
      and type(identifier[1]) == "string" then
    local t = identifier
    identifier, classes, attributes = t[1], t[2] or {}, t[3] or {}
  end
  -- Accept dict form: {identifier="id", classes={...}, attributes={...}}
  -- Also handles djot-style extras: `class` (space-separated classes string),
  -- `id` (alias for identifier).
  if type(identifier) == "table" and classes == nil and attributes == nil then
    local t = identifier
    local id_val = t.identifier or t.id or ""
    local class_list = {}
    if type(t.classes) == "table" then
      for _, c in ipairs(t.classes) do class_list[#class_list+1] = c end
    end
    if type(t.class) == "string" then
      for c in t.class:gmatch("%S+") do class_list[#class_list+1] = c end
    end
    local attr_kvs = {}
    if type(t.attributes) == "table" then
      if #t.attributes > 0 and type(t.attributes[1]) == "table" then
        for _, p in ipairs(t.attributes) do attr_kvs[#attr_kvs+1] = { p[1], p[2] } end
      else
        for k, v in pairs(t.attributes) do
          if type(k) == "string" then attr_kvs[#attr_kvs+1] = { k, v } end
        end
      end
    end
    -- Treat any other string-keyed entries as attributes, excluding known keys.
    for k, v in pairs(t) do
      if type(k) == "string"
          and k ~= "identifier" and k ~= "id"
          and k ~= "classes" and k ~= "class"
          and k ~= "attributes" and k ~= "tag" and k ~= "t" then
        attr_kvs[#attr_kvs+1] = { k, tostring(v) }
      end
    end
    identifier = id_val
    classes = class_list
    attributes = attr_kvs
  end
  identifier = identifier or ""
  classes = List.new(classes or {})
  -- attributes are stored as an ordered array of {k, v} pairs, with
  -- map-style access provided via a metatable.
  local ordered = {}
  if type(attributes) == "table" then
    if #attributes > 0 and type(attributes[1]) == "table" then
      for _, pair in ipairs(attributes) do
        ordered[#ordered+1] = { pair[1], pair[2] }
      end
    else
      local keys = {}
      for k, _ in pairs(attributes) do
        if type(k) == "string" then keys[#keys+1] = k end
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        ordered[#ordered+1] = { k, attributes[k] }
      end
    end
  end
  local attr_proxy = setmetatable(ordered, {
    __index = function(self, k)
      if type(k) == "number" then return rawget(self, k) end
      for _, pair in ipairs(self) do
        if pair[1] == k then return pair[2] end
      end
      return nil
    end,
    __newindex = function(self, k, v)
      if type(k) == "number" then rawset(self, k, v); return end
      for i, pair in ipairs(self) do
        if pair[1] == k then
          if v == nil then
            table.remove(self, i)
          else
            pair[2] = v
          end
          return
        end
      end
      if v ~= nil then
        rawset(self, #self + 1, { k, v })
      end
    end,
    __pairs = function(self)
      -- Iterate as a map: key → value (string → string).
      local i = 0
      return function()
        i = i + 1
        local pair = rawget(self, i)
        if pair == nil then return nil end
        return pair[1], pair[2]
      end
    end,
  })
  return setmetatable({
    identifier = identifier,
    classes = classes,
    attributes = attr_proxy,
  }, Attr)
end

local function to_attr(a)
  if a == nil then return pandoc.Attr() end
  if getmetatable(a) == Attr then return a end
  return pandoc.Attr(a)
end

-- ---------------------------------------------------------------------------
-- AST element factory
-- ---------------------------------------------------------------------------

local Element = {}
Element.__name = "Element"

local Element_methods = {}

function Element_methods:clone()
  local out = {}
  for k, v in pairs(self) do
    if type(v) == "table" and type(v.clone) == "function" then
      out[k] = v:clone()
    else
      out[k] = v
    end
  end
  return setmetatable(out, getmetatable(self))
end

function Element_methods:show()
  return pandoc_native_show(self)
end

function Element_methods:walk(filter)
  return walk_element(self, filter)
end

-- Proxy identifier/classes/attributes access to el.attr, so djot-style
-- `el.classes:includes(...)` and `el.attributes.key = ...` work on any
-- Attr-bearing element.
Element.__index = function(self, key)
  local m = Element_methods[key]
  if m ~= nil then return m end
  local attr = rawget(self, "attr")
  if attr then
    if key == "identifier" or key == "classes" or key == "attributes" then
      return attr[key]
    end
  end
  return nil
end

Element.__newindex = function(self, key, value)
  local attr = rawget(self, "attr")
  if attr and (key == "identifier" or key == "classes" or key == "attributes") then
    attr[key] = value
    return
  end
  rawset(self, key, value)
end

local function make(tag, fields)
  local t = { tag = tag, t = tag }
  for k, v in pairs(fields) do t[k] = v end
  return setmetatable(t, Element)
end

-- ---------------------------------------------------------------------------
-- Inline constructors
-- ---------------------------------------------------------------------------

function pandoc.Str(s)
  return make("Str", { text = tostring(s or "") })
end

function pandoc.Space() return make("Space", {}) end
function pandoc.SoftBreak() return make("SoftBreak", {}) end
function pandoc.LineBreak() return make("LineBreak", {}) end
function pandoc.HorizontalRule() return make("HorizontalRule", {}) end

local function wrap_content(tag)
  return function(content)
    return make(tag, { content = List.new(content or {}) })
  end
end

pandoc.Emph = wrap_content("Emph")
pandoc.Strong = wrap_content("Strong")
pandoc.Underline = wrap_content("Underline")
pandoc.Strikeout = wrap_content("Strikeout")
pandoc.Superscript = wrap_content("Superscript")
pandoc.Subscript = wrap_content("Subscript")
pandoc.SmallCaps = wrap_content("SmallCaps")

function pandoc.Quoted(qt, content)
  return make("Quoted", { quotetype = qt, content = List.new(content or {}) })
end

function pandoc.SingleQuoted(content) return pandoc.Quoted("SingleQuote", content) end
function pandoc.DoubleQuoted(content) return pandoc.Quoted("DoubleQuote", content) end

function pandoc.Cite(cites, content)
  return make("Cite", {
    citations = List.new(cites or {}),
    content = List.new(content or {}),
  })
end

function pandoc.Code(text, attr)
  if type(text) ~= "string" then
    attr, text = text, attr
  end
  return make("Code", { text = text or "", attr = to_attr(attr) })
end

function pandoc.Math(mt, text)
  return make("Math", { mathtype = mt, text = text or "" })
end

function pandoc.DisplayMath(text) return pandoc.Math("DisplayMath", text) end
function pandoc.InlineMath(text) return pandoc.Math("InlineMath", text) end

function pandoc.RawInline(format, text)
  return make("RawInline", { format = format or "", text = text or "" })
end

function pandoc.Link(content, target, title, attr)
  return make("Link", {
    content = List.new(content or {}),
    target = target or "",
    title = title or "",
    attr = to_attr(attr),
  })
end

function pandoc.Image(caption, src, title, attr)
  return make("Image", {
    caption = List.new(caption or {}),
    src = src or "",
    title = title or "",
    attr = to_attr(attr),
  })
end

function pandoc.Note(content)
  return make("Note", { content = List.new(content or {}) })
end

function pandoc.Span(content, attr)
  return make("Span", {
    content = List.new(content or {}),
    attr = to_attr(attr),
  })
end

-- ---------------------------------------------------------------------------
-- Block constructors
-- ---------------------------------------------------------------------------

pandoc.Plain = wrap_content("Plain")
pandoc.Para = wrap_content("Para")

function pandoc.LineBlock(lines)
  local ls = List.new({})
  for _, line in ipairs(lines or {}) do
    ls:insert(List.new(line))
  end
  return make("LineBlock", { content = ls })
end

function pandoc.CodeBlock(text, attr)
  return make("CodeBlock", { text = text or "", attr = to_attr(attr) })
end

function pandoc.RawBlock(format, text)
  return make("RawBlock", { format = format or "", text = text or "" })
end

function pandoc.BlockQuote(content)
  return make("BlockQuote", { content = List.new(content or {}) })
end

function pandoc.BulletList(items)
  local ls = List.new({})
  for _, it in ipairs(items or {}) do
    ls:insert(List.new(it))
  end
  return make("BulletList", { content = ls })
end

function pandoc.OrderedList(items, list_attrs)
  list_attrs = list_attrs or { 1, "DefaultStyle", "DefaultDelim" }
  local la
  if type(list_attrs) == "table" and list_attrs.start then
    la = list_attrs
  else
    la = {
      start = list_attrs[1] or 1,
      style = list_attrs[2] or "DefaultStyle",
      delimiter = list_attrs[3] or "DefaultDelim",
    }
  end
  local ls = List.new({})
  for _, it in ipairs(items or {}) do ls:insert(List.new(it)) end
  return make("OrderedList", {
    content = ls,
    listAttributes = la,
    start = la.start,
    style = la.style,
    delimiter = la.delimiter,
  })
end

function pandoc.DefinitionList(items)
  local ls = List.new({})
  for _, it in ipairs(items or {}) do
    local term = List.new(it[1] or {})
    local defs = List.new({})
    for _, d in ipairs(it[2] or {}) do defs:insert(List.new(d)) end
    ls:insert({ term, defs })
  end
  return make("DefinitionList", { content = ls })
end

function pandoc.Header(level, content, attr)
  return make("Header", {
    level = level or 1,
    content = List.new(content or {}),
    attr = to_attr(attr),
  })
end

function pandoc.Div(content, attr)
  return make("Div", {
    content = List.new(content or {}),
    attr = to_attr(attr),
  })
end

function pandoc.Figure(content, caption, attr)
  return make("Figure", {
    content = List.new(content or {}),
    caption = caption or { short = nil, long = List.new({}) },
    attr = to_attr(attr),
  })
end

function pandoc.Table(caption, colspecs, head, bodies, foot, attr)
  return make("Table", {
    attr = to_attr(attr),
    caption = caption or { short = nil, long = List.new({}) },
    colspecs = List.new(colspecs or {}),
    head = head or pandoc.TableHead(),
    bodies = List.new(bodies or {}),
    foot = foot or pandoc.TableFoot(),
  })
end

function pandoc.TableHead(rows, attr)
  return { attr = to_attr(attr), rows = List.new(rows or {}) }
end

function pandoc.TableFoot(rows, attr)
  return { attr = to_attr(attr), rows = List.new(rows or {}) }
end

function pandoc.TableBody(body, head, row_head_columns, attr)
  return {
    attr = to_attr(attr),
    body = List.new(body or {}),
    head = List.new(head or {}),
    row_head_columns = row_head_columns or 0,
  }
end

function pandoc.Row(cells, attr)
  return { attr = to_attr(attr), cells = List.new(cells or {}) }
end

function pandoc.Cell(content, align, rowspan, colspan, attr)
  return {
    attr = to_attr(attr),
    alignment = align or "AlignDefault",
    row_span = rowspan or 1,
    col_span = colspan or 1,
    content = List.new(content or {}),
  }
end

function pandoc.Caption(long, short)
  return { long = List.new(long or {}), short = short }
end

-- ---------------------------------------------------------------------------
-- Pandoc top-level
-- ---------------------------------------------------------------------------

local Pandoc = {}
Pandoc.__index = Pandoc
Pandoc.__name = "Pandoc"

function Pandoc:clone()
  return pandoc.Pandoc(List.new(self.blocks):clone(), clone_meta(self.meta))
end

function Pandoc:walk(filter)
  return walk_pandoc(self, filter)
end

function Pandoc:normalize() return self end

function clone_meta(m)
  local out = {}
  for k, v in pairs(m or {}) do
    if type(v) == "table" and type(v.clone) == "function" then
      out[k] = v:clone()
    else
      out[k] = v
    end
  end
  return out
end

function pandoc.Pandoc(blocks, meta)
  return setmetatable({
    blocks = List.new(blocks or {}),
    meta = meta or {},
  }, Pandoc)
end

function pandoc.Meta(tbl) return tbl or {} end
function pandoc.MetaString(s) return tostring(s) end
function pandoc.MetaBool(b) return b and true or false end
function pandoc.MetaInlines(inlines) return List.new(inlines or {}) end
function pandoc.MetaBlocks(blocks) return List.new(blocks or {}) end
function pandoc.MetaList(list) return List.new(list or {}) end
function pandoc.MetaMap(tbl) return tbl or {} end

-- ---------------------------------------------------------------------------
-- Inlines / Blocks — tagged List variants
-- ---------------------------------------------------------------------------

-- Forward-declared so pandoc.Inlines / pandoc.Blocks capture them as
-- upvalues; the tables are populated in the "Element tag sets" block
-- further down. Previously these were looked up as implicit globals,
-- which errored on non-nil element-table inputs.
local INLINE_TAGS, BLOCK_TAGS

local Inlines = setmetatable({}, { __index = List })
Inlines.__index = Inlines
Inlines.__name = "Inlines"

local Blocks = setmetatable({}, { __index = List })
Blocks.__index = Blocks
Blocks.__name = "Blocks"

function pandoc.Inlines(x)
  if x == nil then return setmetatable({}, Inlines) end
  if type(x) == "string" then
    -- Tokenize: runs of non-whitespace → Str, runs of spaces → Space,
    -- newlines → SoftBreak. Matches pandoc's own Inlines(string) behavior.
    local out = {}
    local i = 1
    local n = #x
    while i <= n do
      local c = x:sub(i, i)
      if c == "\n" then
        out[#out+1] = pandoc.SoftBreak(); i = i + 1
      elseif c == " " or c == "\t" then
        -- collapse runs of spaces/tabs into single Space
        out[#out+1] = pandoc.Space()
        while i <= n and (x:sub(i,i) == " " or x:sub(i,i) == "\t") do i = i + 1 end
      else
        local j = i
        while j <= n do
          local cc = x:sub(j, j)
          if cc == " " or cc == "\t" or cc == "\n" then break end
          j = j + 1
        end
        out[#out+1] = pandoc.Str(x:sub(i, j - 1))
        i = j
      end
    end
    return setmetatable(out, Inlines)
  end
  if type(x) == "table" and x.tag and INLINE_TAGS[x.tag] then
    return setmetatable({ x }, Inlines)
  end
  if type(x) == "table" then
    local out = {}
    for i, v in ipairs(x) do out[i] = v end
    return setmetatable(out, Inlines)
  end
  return setmetatable({ pandoc.Str(tostring(x)) }, Inlines)
end

function pandoc.Blocks(x)
  if x == nil then return setmetatable({}, Blocks) end
  if type(x) == "string" then
    return setmetatable({ pandoc.Plain({ pandoc.Str(x) }) }, Blocks)
  end
  if type(x) == "table" and x.tag and BLOCK_TAGS[x.tag] then
    return setmetatable({ x }, Blocks)
  end
  if type(x) == "table" then
    local out = {}
    for i, v in ipairs(x) do out[i] = v end
    return setmetatable(out, Blocks)
  end
  return setmetatable({}, Blocks)
end

-- ---------------------------------------------------------------------------
-- ListAttributes — positional (start, style, delimiter) + named
-- ---------------------------------------------------------------------------

local ListAttributesMT = {}
ListAttributesMT.__name = "ListAttributes"
ListAttributesMT.__index = function(self, k)
  if k == 1 then return rawget(self, "start")
  elseif k == 2 then return rawget(self, "style")
  elseif k == 3 then return rawget(self, "delimiter")
  end
  return nil
end
ListAttributesMT.__newindex = function(self, k, v)
  if k == 1 then rawset(self, "start", v)
  elseif k == 2 then rawset(self, "style", v)
  elseif k == 3 then rawset(self, "delimiter", v)
  else rawset(self, k, v) end
end

function pandoc.ListAttributes(start, style, delimiter)
  return setmetatable({
    start = start or 1,
    style = style or "DefaultStyle",
    delimiter = delimiter or "DefaultDelim",
  }, ListAttributesMT)
end

-- ---------------------------------------------------------------------------
-- SimpleTable — legacy simple-table constructor and conversions
-- ---------------------------------------------------------------------------

function pandoc.SimpleTable(caption, aligns, widths, headers, rows)
  return {
    tag = "SimpleTable",
    caption = List.new(caption or {}),
    aligns = List.new(aligns or {}),
    widths = List.new(widths or {}),
    headers = List.new(headers or {}),
    rows = List.new(rows or {}),
  }
end

function pandoc.utils.to_simple_table(el)
  if not el or el.tag ~= "Table" then
    error("pandoc.utils.to_simple_table: argument is not a Table")
  end
  local caption = List.new({})
  if el.caption and el.caption.long then
    for _, b in ipairs(el.caption.long) do
      if b.tag == "Plain" or b.tag == "Para" then
        for _, c in ipairs(b.content or {}) do caption:insert(c) end
      end
    end
  end
  local aligns = List.new({})
  local widths = List.new({})
  for _, spec in ipairs(el.colspecs or {}) do
    aligns:insert(spec[1] or "AlignDefault")
    local cw = spec[2]
    if cw and cw.tag == "ColWidth" then widths:insert(cw.width)
    else widths:insert(0) end
  end
  local headers = List.new({})
  local head_rows = (el.head or {}).rows or {}
  if #head_rows > 0 then
    for _, cell in ipairs(head_rows[1].cells or {}) do
      headers:insert(List.new(cell.content or {}))
    end
  end
  local rows = List.new({})
  for _, body in ipairs(el.bodies or {}) do
    for _, row in ipairs(body.body or {}) do
      local cells = List.new({})
      for _, cell in ipairs(row.cells or {}) do
        cells:insert(List.new(cell.content or {}))
      end
      rows:insert(cells)
    end
  end
  return pandoc.SimpleTable(caption, aligns, widths, headers, rows)
end

function pandoc.utils.from_simple_table(st)
  -- Convert a SimpleTable back to a modern Table block.
  local ncols = #st.aligns
  local colspecs = List.new({})
  for i = 1, ncols do
    local w = st.widths[i] or 0
    local cw = (w > 0) and { tag = "ColWidth", width = w }
                       or { tag = "ColWidthDefault" }
    colspecs:insert({ st.aligns[i] or "AlignDefault", cw })
  end
  local function make_cell(content)
    return {
      attr = pandoc.Attr(),
      alignment = "AlignDefault",
      row_span = 1, col_span = 1,
      content = { pandoc.Plain(content or {}) },
    }
  end
  local function make_row(cells)
    local cs = {}
    for _, c in ipairs(cells or {}) do cs[#cs+1] = make_cell(c) end
    return { attr = pandoc.Attr(), cells = cs }
  end
  local head_rows = {}
  if st.headers and #st.headers > 0 then
    -- Non-empty header row
    local any = false
    for _, h in ipairs(st.headers) do if #h > 0 then any = true break end end
    if any then head_rows[1] = make_row(st.headers) end
  end
  local head = { attr = pandoc.Attr(), rows = head_rows }
  local body_rows = {}
  for _, r in ipairs(st.rows or {}) do body_rows[#body_rows+1] = make_row(r) end
  local body = {
    attr = pandoc.Attr(),
    row_head_columns = 0,
    head = {},
    body = body_rows,
  }
  local foot = { attr = pandoc.Attr(), rows = {} }
  local caption = { short = nil, long = {} }
  if st.caption and #st.caption > 0 then
    caption.long = { pandoc.Plain(st.caption) }
  end
  return pandoc.Table(caption, colspecs, head, { body }, foot, pandoc.Attr())
end

-- ---------------------------------------------------------------------------
-- pandoc.utils.to_roman_numeral
-- ---------------------------------------------------------------------------

function pandoc.utils.to_roman_numeral(n)
  n = tonumber(n) or 0
  if n <= 0 or n >= 4000 then return tostring(n) end
  local syms = {
    { 1000, "M" }, { 900, "CM" }, { 500, "D" }, { 400, "CD" },
    { 100, "C" },  { 90, "XC" },  { 50, "L" },  { 40, "XL" },
    { 10, "X" },   { 9, "IX" },   { 5, "V" },   { 4, "IV" },
    { 1, "I" },
  }
  local out = {}
  for _, s in ipairs(syms) do
    while n >= s[1] do out[#out+1] = s[2]; n = n - s[1] end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- walk
-- ---------------------------------------------------------------------------
-- Pandoc filter semantics: bottom-up traversal. For each element visited,
-- if the filter has a function for its tag, call it; the return value replaces
-- the element (nil = keep unchanged; false = delete).

INLINE_TAGS = {
  Str=true, Emph=true, Underline=true, Strong=true, Strikeout=true,
  Superscript=true, Subscript=true, SmallCaps=true, Quoted=true, Cite=true,
  Code=true, Space=true, SoftBreak=true, LineBreak=true, Math=true,
  RawInline=true, Link=true, Image=true, Note=true, Span=true,
}
BLOCK_TAGS = {
  Plain=true, Para=true, LineBlock=true, CodeBlock=true, RawBlock=true,
  BlockQuote=true, OrderedList=true, BulletList=true, DefinitionList=true,
  Header=true, HorizontalRule=true, Table=true, Figure=true, Div=true,
}
local INLINE_CONTAINERS = {
  Emph=true, Underline=true, Strong=true, Strikeout=true, Superscript=true,
  Subscript=true, SmallCaps=true, Quoted=true, Cite=true, Link=true, Image=true, Span=true,
}
local BLOCK_CONTAINERS = {
  BlockQuote=true, Div=true, Note=true,
}

local function is_inline(el)
  return type(el) == "table" and el.tag and INLINE_TAGS[el.tag]
end
local function is_block(el)
  return type(el) == "table" and el.tag and BLOCK_TAGS[el.tag]
end

local function walk_list(list, filter, kind)
  local out = List.new({})
  for _, el in ipairs(list) do
    local walked = walk_element(el, filter)
    if walked == false then
      -- delete
    elseif type(walked) == "table" and walked.tag == nil then
      -- list of replacements (empty list = delete; pandoc idiom)
      for _, w in ipairs(walked) do out:insert(w) end
    elseif walked == nil then
      out:insert(el)
    else
      out:insert(walked)
    end
  end
  return out
end

function walk_element(el, filter)
  if type(el) ~= "table" or el.tag == nil then return el end
  local tag = el.tag
  -- Image uses a `caption` field (list of inlines) instead of `content`.
  if tag == "Image" and el.caption and type(el.caption) == "table" then
    el.caption = walk_list(el.caption, filter, "Inline")
  end
  -- Recurse into children first (bottom-up)
  if el.content and type(el.content) == "table" then
    if tag == "LineBlock" then
      local new_lines = List.new({})
      for _, line in ipairs(el.content) do
        new_lines:insert(walk_list(line, filter, "Inline"))
      end
      el.content = new_lines
    elseif tag == "BulletList" or tag == "OrderedList" then
      local new_items = List.new({})
      for _, item in ipairs(el.content) do
        new_items:insert(walk_list(item, filter, "Block"))
      end
      el.content = new_items
    elseif tag == "DefinitionList" then
      local new_items = List.new({})
      for _, item in ipairs(el.content) do
        local term = walk_list(item[1] or {}, filter, "Inline")
        local defs = List.new({})
        for _, d in ipairs(item[2] or {}) do
          defs:insert(walk_list(d, filter, "Block"))
        end
        new_items:insert({ term, defs })
      end
      el.content = new_items
    else
      -- Decide inline vs block children based on element kind.
      local kind = BLOCK_CONTAINERS[tag] and "Block" or "Inline"
      if tag == "Plain" or tag == "Para" or tag == "Header" then kind = "Inline" end
      if tag == "BlockQuote" or tag == "Div" or tag == "Note" then kind = "Block" end
      if tag == "Figure" then kind = "Block" end
      el.content = walk_list(el.content, filter, kind)
    end
  end
  -- Apply filter for this element
  local fn = filter[tag]
  if fn == nil then
    if INLINE_TAGS[tag] and filter.Inline then fn = filter.Inline
    elseif BLOCK_TAGS[tag] and filter.Block then fn = filter.Block end
  end
  if fn then
    local r = fn(el)
    if r == nil then return el end
    return r
  end
  return el
end

function walk_pandoc(doc, filter)
  -- Pandoc filter: traverse meta + blocks
  if filter.Meta then
    local r = filter.Meta(doc.meta)
    if r ~= nil then doc.meta = r end
  end
  doc.blocks = walk_list(doc.blocks or {}, filter, "Block")
  if filter.Pandoc then
    local r = filter.Pandoc(doc)
    if r ~= nil then doc = r end
  end
  return doc
end

-- ---------------------------------------------------------------------------
-- pandoc.utils
-- ---------------------------------------------------------------------------

function pandoc.utils.stringify(x)
  if x == nil then return "" end
  if type(x) == "string" then return x end
  if type(x) == "number" or type(x) == "boolean" then return tostring(x) end
  if type(x) ~= "table" then return "" end
  local tag = x.tag
  if tag == "Str" then return x.text or ""
  elseif tag == "Space" then return " "
  elseif tag == "SoftBreak" then return "\n"
  elseif tag == "LineBreak" then return "\n"
  elseif tag == "HorizontalRule" then return ""
  elseif tag == "Code" or tag == "CodeBlock" or tag == "Math"
      or tag == "RawInline" or tag == "RawBlock" then
    return x.text or ""
  end
  -- Container with content
  if x.content ~= nil then return pandoc.utils.stringify(x.content) end
  if x.blocks ~= nil then return pandoc.utils.stringify(x.blocks) end
  -- Pandoc
  if x.meta and x.blocks then return pandoc.utils.stringify(x.blocks) end
  -- list
  local parts = {}
  for i, v in ipairs(x) do parts[i] = pandoc.utils.stringify(v) end
  return table.concat(parts, "")
end

function pandoc.utils.type(x)
  if x == nil then return "nil" end
  local mt = getmetatable(x)
  if mt == Pandoc then return "Pandoc" end
  if mt == Attr then return "Attr" end
  if mt and mt.__name == "Inlines" then return "Inlines" end
  if mt and mt.__name == "Blocks" then return "Blocks" end
  if mt == List then return "List" end
  if mt == Element then
    if INLINE_TAGS[x.tag] then return "Inline" end
    if BLOCK_TAGS[x.tag] then return "Block" end
    return x.tag or "Element"
  end
  return type(x)
end

function pandoc.utils.equals(a, b) return deep_eq(a, b) end

function pandoc.utils.blocks_to_inlines(blocks, sep)
  sep = sep or { pandoc.Space() }
  local out = List.new({})
  for i, b in ipairs(blocks) do
    if i > 1 then for _, s in ipairs(sep) do out:insert(s) end end
    if b.content then
      for _, c in ipairs(b.content) do out:insert(c) end
    end
  end
  return out
end

function pandoc.utils.make_sections(_, _, blocks) return blocks end
function pandoc.utils.normalize_date(s) return s end

-- ---------------------------------------------------------------------------
-- pandoc.path stubs (minimal, enough for most scripts)
-- ---------------------------------------------------------------------------

function pandoc.path.directory(p)
  p = p or ""
  local i = p:find("/[^/]*$")
  if not i then return "." end
  if i == 1 then return "/" end
  return p:sub(1, i - 1)
end

function pandoc.path.filename(p)
  p = p or ""
  local i = p:find("/[^/]*$")
  if not i then return p end
  return p:sub(i + 1)
end

function pandoc.path.split_extension(p)
  p = p or ""
  local name = pandoc.path.filename(p)
  local i = name:find("%.[^.]*$")
  if not i or i == 1 then return p, "" end
  local dir = pandoc.path.directory(p)
  local stem = name:sub(1, i - 1)
  local ext = name:sub(i)
  if dir == "." or dir == "" then return stem, ext end
  return dir .. "/" .. stem, ext
end

function pandoc.path.join(parts)
  local out
  for _, p in ipairs(parts) do
    if not out then out = p
    elseif p:sub(1,1) == "/" then out = p
    elseif out:sub(-1) == "/" then out = out .. p
    else out = out .. "/" .. p end
  end
  return out or ""
end

pandoc.path.separator = "/"

-- ---------------------------------------------------------------------------
-- pandoc.mediabag stubs
-- ---------------------------------------------------------------------------

local _mediabag = {}
function pandoc.mediabag.insert(filename, mime, contents)
  _mediabag[filename] = { mime = mime, contents = contents }
end
function pandoc.mediabag.lookup(filename)
  local e = _mediabag[filename]
  if not e then return nil end
  return e.mime, e.contents
end
function pandoc.mediabag.list()
  local out = List.new({})
  for k, v in pairs(_mediabag) do
    out:insert({ path = k, mime_type = v.mime, length = #(v.contents or "") })
  end
  return out
end
function pandoc.mediabag.items()
  local i = 0
  local keys = {}
  for k, _ in pairs(_mediabag) do keys[#keys+1] = k end
  return function()
    i = i + 1
    if i > #keys then return nil end
    local k = keys[i]
    return k, _mediabag[k].mime, _mediabag[k].contents
  end
end

-- ---------------------------------------------------------------------------
-- pandoc.system stubs
-- ---------------------------------------------------------------------------

pandoc.system.os = "linux"
pandoc.system.arch = "x86_64"
function pandoc.system.environment() return {} end
function pandoc.system.get_working_directory() return "." end

-- ---------------------------------------------------------------------------
-- Internal hooks for host-provided functions
-- ---------------------------------------------------------------------------

-- The host may override this later.
function pandoc_native_show(_) return "" end

-- Expose the internal tables so the host can attach additional methods.
pandoc._internal = {
  List = List,
  Attr = Attr,
  Element = Element,
  Pandoc = Pandoc,
  INLINE_TAGS = INLINE_TAGS,
  BLOCK_TAGS = BLOCK_TAGS,
}

-- Shared HTML-family escapes. Used by the bundled html and epub writers;
-- any new XML/HTML writer should reuse these rather than rolling its own.
function pandoc._internal.escape_html(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  return s
end

function pandoc._internal.escape_html_attr(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;"):gsub('"', "&quot;")
       :gsub("<", "&lt;"):gsub(">", "&gt;")
  return s
end

-- Expose lpeg and re under pandoc.* to match pandoc's convention for
-- custom readers. Preloaded from the Rust bootstrap.
local ok_lpeg, lpeg = pcall(require, "lpeg")
if ok_lpeg then pandoc.lpeg = lpeg end
local ok_re, re = pcall(require, "re")
if ok_re then pandoc.re = re end

return pandoc
