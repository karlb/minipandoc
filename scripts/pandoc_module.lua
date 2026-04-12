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
setmetatable(pandoc.List, { __call = function(_, t) return List.new(t) end })

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
  if type(identifier) == "table" and identifier.tag == nil
      and classes == nil and attributes == nil
      and type(identifier[1]) == "string" then
    local t = identifier
    identifier, classes, attributes = t[1], t[2] or {}, t[3] or {}
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
      for _, pair in ipairs(self) do
        if pair[1] == k then pair[2] = v; return end
      end
      rawset(self, #self + 1, { k, v })
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
Element.__index = Element
Element.__name = "Element"

function Element:clone()
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

function Element:show()
  return pandoc_native_show(self)
end

function Element:walk(filter)
  return walk_element(self, filter)
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

local function link_like(tag)
  return function(content, target, title, attr)
    title = title or ""
    return make(tag, {
      content = List.new(content or {}),
      target = target or "",
      title = title,
      attr = to_attr(attr),
    })
  end
end
pandoc.Link = link_like("Link")
pandoc.Image = link_like("Image")

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
-- walk
-- ---------------------------------------------------------------------------
-- Pandoc filter semantics: bottom-up traversal. For each element visited,
-- if the filter has a function for its tag, call it; the return value replaces
-- the element (nil = keep unchanged; false = delete).

local INLINE_TAGS = {
  Str=true, Emph=true, Underline=true, Strong=true, Strikeout=true,
  Superscript=true, Subscript=true, SmallCaps=true, Quoted=true, Cite=true,
  Code=true, Space=true, SoftBreak=true, LineBreak=true, Math=true,
  RawInline=true, Link=true, Image=true, Note=true, Span=true,
}
local BLOCK_TAGS = {
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
    elseif type(walked) == "table" and walked.tag == nil and #walked > 0 then
      -- list of replacements
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

local function split_path(p)
  local parts = {}
  for seg in string.gmatch(p or "", "[^/]+") do parts[#parts+1] = seg end
  return parts
end

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

return pandoc
