-- minipandoc builtin: readers/native.lua
-- Parses pandoc's native (Haskell-show) representation of a document.
--
-- Accepts either:
--   [Block, Block, ...]                     (just the block list)
--   Pandoc Meta {...} [Block, Block, ...]   (standalone)

local function tokenize(src)
  local tokens = {}
  local i = 1
  local n = #src
  while i <= n do
    local c = src:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    elseif c == "[" or c == "]" or c == "(" or c == ")" or c == "," or c == "{" or c == "}" or c == "=" then
      tokens[#tokens+1] = { kind = "punct", val = c }
      i = i + 1
    elseif c == '"' then
      local j = i + 1
      local buf = {}
      while j <= n do
        local cc = src:sub(j, j)
        if cc == '\\' then
          local esc = src:sub(j+1, j+1)
          if esc == 'n' then buf[#buf+1] = '\n'
          elseif esc == 'r' then buf[#buf+1] = '\r'
          elseif esc == 't' then buf[#buf+1] = '\t'
          elseif esc == '\\' then buf[#buf+1] = '\\'
          elseif esc == '"' then buf[#buf+1] = '"'
          elseif esc == "'" then buf[#buf+1] = "'"
          elseif esc:match("%d") then
            -- decimal escape \NNN
            local num = {}
            local k = j + 1
            while k <= n and src:sub(k,k):match("%d") do
              num[#num+1] = src:sub(k,k); k = k + 1
            end
            buf[#buf+1] = string.char(tonumber(table.concat(num)))
            j = k
            goto continue
          else
            buf[#buf+1] = esc
          end
          j = j + 2
          ::continue::
        elseif cc == '"' then
          tokens[#tokens+1] = { kind = "str", val = table.concat(buf) }
          j = j + 1
          break
        else
          buf[#buf+1] = cc
          j = j + 1
        end
      end
      i = j
    elseif c:match("[%-%d]") then
      local j = i
      if c == "-" then j = j + 1 end
      while j <= n and src:sub(j,j):match("[%d%.]") do j = j + 1 end
      tokens[#tokens+1] = { kind = "num", val = tonumber(src:sub(i, j-1)) }
      i = j
    elseif c:match("[%a_]") then
      local j = i
      while j <= n and src:sub(j,j):match("[%w_']") do j = j + 1 end
      tokens[#tokens+1] = { kind = "ident", val = src:sub(i, j-1) }
      i = j
    else
      error("native reader: unexpected character at position " .. i .. ": " .. c)
    end
  end
  return tokens
end

local parser_mt = {}
parser_mt.__index = parser_mt

function parser_mt:peek(off) return self.tokens[self.pos + (off or 0)] end
function parser_mt:advance() self.pos = self.pos + 1; return self.tokens[self.pos - 1] end

function parser_mt:accept(kind, val)
  local t = self:peek()
  if t and t.kind == kind and (val == nil or t.val == val) then
    self.pos = self.pos + 1
    return t
  end
end

function parser_mt:expect(kind, val)
  local t = self:accept(kind, val)
  if not t then
    local got = self:peek()
    error(string.format("native reader: expected %s %s, got %s", kind, val or "",
      got and (got.kind .. " " .. tostring(got.val)) or "EOF"))
  end
  return t
end

function parser_mt:parse_attr()
  self:expect("punct", "(")
  local ident = self:expect("str").val
  self:expect("punct", ",")
  self:expect("punct", "[")
  local classes = {}
  if not self:accept("punct", "]") then
    classes[#classes+1] = self:expect("str").val
    while self:accept("punct", ",") do
      classes[#classes+1] = self:expect("str").val
    end
    self:expect("punct", "]")
  end
  self:expect("punct", ",")
  self:expect("punct", "[")
  local kvs = {}
  if not self:accept("punct", "]") then
    self:expect("punct", "(")
    local k = self:expect("str").val
    self:expect("punct", ",")
    local v = self:expect("str").val
    self:expect("punct", ")")
    kvs[#kvs+1] = { k, v }
    while self:accept("punct", ",") do
      self:expect("punct", "(")
      local k2 = self:expect("str").val
      self:expect("punct", ",")
      local v2 = self:expect("str").val
      self:expect("punct", ")")
      kvs[#kvs+1] = { k2, v2 }
    end
    self:expect("punct", "]")
  end
  self:expect("punct", ")")
  return pandoc.Attr(ident, classes, kvs)
end

function parser_mt:parse_target()
  self:expect("punct", "(")
  local url = self:expect("str").val
  self:expect("punct", ",")
  local title = self:expect("str").val
  self:expect("punct", ")")
  return url, title
end

function parser_mt:parse_list(elem_parser)
  self:expect("punct", "[")
  local out = {}
  if not self:accept("punct", "]") then
    out[#out+1] = elem_parser(self)
    while self:accept("punct", ",") do
      out[#out+1] = elem_parser(self)
    end
    self:expect("punct", "]")
  end
  return out
end

function parser_mt:parse_inlines()
  return self:parse_list(function(p) return p:parse_inline() end)
end

function parser_mt:parse_blocks()
  return self:parse_list(function(p) return p:parse_block() end)
end

-- Parse optional parenthesized constructor call: `(Ctor args...)` or just `Ctor args`
function parser_mt:parse_wrapped(fn)
  if self:accept("punct", "(") then
    local v = fn(self)
    self:expect("punct", ")")
    return v
  end
  return fn(self)
end

function parser_mt:parse_inline()
  local t = self:peek()
  if t.kind == "punct" and t.val == "(" then
    self:advance()
    local v = self:parse_inline()
    self:expect("punct", ")")
    return v
  end
  if t.kind ~= "ident" then
    error("native reader: expected inline constructor, got " .. t.kind)
  end
  local tag = self:advance().val
  if tag == "Str" then
    return pandoc.Str(self:expect("str").val)
  elseif tag == "Space" then return pandoc.Space()
  elseif tag == "SoftBreak" then return pandoc.SoftBreak()
  elseif tag == "LineBreak" then return pandoc.LineBreak()
  elseif tag == "Emph" then return pandoc.Emph(self:parse_inlines())
  elseif tag == "Strong" then return pandoc.Strong(self:parse_inlines())
  elseif tag == "Underline" then return pandoc.Underline(self:parse_inlines())
  elseif tag == "Strikeout" then return pandoc.Strikeout(self:parse_inlines())
  elseif tag == "Superscript" then return pandoc.Superscript(self:parse_inlines())
  elseif tag == "Subscript" then return pandoc.Subscript(self:parse_inlines())
  elseif tag == "SmallCaps" then return pandoc.SmallCaps(self:parse_inlines())
  elseif tag == "Quoted" then
    local qt = self:expect("ident").val
    return pandoc.Quoted(qt, self:parse_inlines())
  elseif tag == "Cite" then
    local _cites = self:parse_list(function(p) return p:parse_citation() end)
    return pandoc.Cite(_cites, self:parse_inlines())
  elseif tag == "Code" then
    local attr = self:parse_attr()
    local txt = self:expect("str").val
    return pandoc.Code(txt, attr)
  elseif tag == "Math" then
    local mt = self:expect("ident").val
    local txt = self:expect("str").val
    return pandoc.Math(mt, txt)
  elseif tag == "RawInline" then
    local fmt = self:parse_format()
    local txt = self:expect("str").val
    return pandoc.RawInline(fmt, txt)
  elseif tag == "Link" then
    local attr = self:parse_attr()
    local content = self:parse_inlines()
    local url, title = self:parse_target()
    return pandoc.Link(content, url, title, attr)
  elseif tag == "Image" then
    local attr = self:parse_attr()
    local caption = self:parse_inlines()
    local src, title = self:parse_target()
    return pandoc.Image(caption, src, title, attr)
  elseif tag == "Note" then
    return pandoc.Note(self:parse_blocks())
  elseif tag == "Span" then
    local attr = self:parse_attr()
    return pandoc.Span(self:parse_inlines(), attr)
  end
  error("native reader: unknown inline tag: " .. tag)
end

function parser_mt:parse_format()
  -- Format "html" — may be parenthesized: (Format "html")
  local paren = self:accept("punct", "(")
  self:expect("ident", "Format")
  local val = self:expect("str").val
  if paren then self:expect("punct", ")") end
  return val
end

function parser_mt:parse_citation()
  -- Citation {citationId = "...", ...}
  self:expect("ident", "Citation")
  self:expect("punct", "{")
  local c = { citationId = "", citationPrefix = {}, citationSuffix = {},
              citationMode = "NormalCitation", citationNoteNum = 0, citationHash = 0 }
  local first = true
  while not self:accept("punct", "}") do
    if not first then self:expect("punct", ",") end
    first = false
    local key = self:expect("ident").val
    self:expect("punct", "=")
    if key == "citationId" then c.citationId = self:expect("str").val
    elseif key == "citationPrefix" then c.citationPrefix = self:parse_inlines()
    elseif key == "citationSuffix" then c.citationSuffix = self:parse_inlines()
    elseif key == "citationMode" then c.citationMode = self:expect("ident").val
    elseif key == "citationNoteNum" then c.citationNoteNum = self:expect("num").val
    elseif key == "citationHash" then c.citationHash = self:expect("num").val
    else error("native reader: unknown citation field: " .. key) end
  end
  return c
end

function parser_mt:parse_list_attrs()
  self:expect("punct", "(")
  local start = self:expect("num").val
  self:expect("punct", ",")
  local style = self:expect("ident").val
  self:expect("punct", ",")
  local delim = self:expect("ident").val
  self:expect("punct", ")")
  return { start = start, style = style, delimiter = delim }
end

function parser_mt:parse_block()
  local t = self:peek()
  if t.kind == "punct" and t.val == "(" then
    self:advance()
    local v = self:parse_block()
    self:expect("punct", ")")
    return v
  end
  if t.kind ~= "ident" then
    error("native reader: expected block constructor, got " .. t.kind)
  end
  local tag = self:advance().val
  if tag == "Plain" then return pandoc.Plain(self:parse_inlines())
  elseif tag == "Para" then return pandoc.Para(self:parse_inlines())
  elseif tag == "LineBlock" then
    local lines = self:parse_list(function(p) return p:parse_inlines() end)
    return pandoc.LineBlock(lines)
  elseif tag == "CodeBlock" then
    local attr = self:parse_attr()
    local txt = self:expect("str").val
    return pandoc.CodeBlock(txt, attr)
  elseif tag == "RawBlock" then
    local fmt = self:parse_format()
    local txt = self:expect("str").val
    return pandoc.RawBlock(fmt, txt)
  elseif tag == "BlockQuote" then return pandoc.BlockQuote(self:parse_blocks())
  elseif tag == "BulletList" then
    local items = self:parse_list(function(p) return p:parse_blocks() end)
    return pandoc.BulletList(items)
  elseif tag == "OrderedList" then
    local la = self:parse_list_attrs()
    local items = self:parse_list(function(p) return p:parse_blocks() end)
    return pandoc.OrderedList(items, la)
  elseif tag == "DefinitionList" then
    local items = self:parse_list(function(p)
      p:expect("punct", "(")
      local term = p:parse_inlines()
      p:expect("punct", ",")
      local defs = p:parse_list(function(pp) return pp:parse_blocks() end)
      p:expect("punct", ")")
      return { term, defs }
    end)
    return pandoc.DefinitionList(items)
  elseif tag == "Header" then
    local lvl = self:expect("num").val
    local attr = self:parse_attr()
    local content = self:parse_inlines()
    return pandoc.Header(lvl, content, attr)
  elseif tag == "HorizontalRule" then return pandoc.HorizontalRule()
  elseif tag == "Div" then
    local attr = self:parse_attr()
    local content = self:parse_blocks()
    return pandoc.Div(content, attr)
  elseif tag == "Figure" then
    local attr = self:parse_attr()
    local caption = self:parse_caption()
    local content = self:parse_blocks()
    return pandoc.Figure(content, caption, attr)
  elseif tag == "Table" then
    local attr = self:parse_attr()
    local caption = self:parse_caption()
    local colspecs = self:parse_list(function(p) return p:parse_colspec() end)
    local head = self:parse_table_head()
    local bodies = self:parse_list(function(p) return p:parse_table_body() end)
    local foot = self:parse_table_foot()
    return pandoc.Table(caption, colspecs, head, bodies, foot, attr)
  end
  error("native reader: unknown block tag: " .. tag)
end

function parser_mt:parse_caption()
  local paren = self:accept("punct", "(")
  self:expect("ident", "Caption")
  local short
  if self:accept("ident", "Nothing") then
    short = nil
  elseif self:accept("ident", "Just") then
    short = self:parse_inlines()
  end
  local long = self:parse_blocks()
  if paren then self:expect("punct", ")") end
  return { short = short, long = long }
end

function parser_mt:parse_colspec()
  self:expect("punct", "(")
  local align = self:expect("ident").val
  self:expect("punct", ",")
  -- ColWidth 0.5 or ColWidthDefault
  local cw
  local paren2 = self:accept("punct", "(")
  local id = self:expect("ident").val
  if id == "ColWidth" then
    cw = { tag = "ColWidth", width = self:expect("num").val }
  else
    cw = { tag = "ColWidthDefault" }
  end
  if paren2 then self:expect("punct", ")") end
  self:expect("punct", ")")
  return { align, cw }
end

function parser_mt:parse_table_head()
  local paren = self:accept("punct", "(")
  self:expect("ident", "TableHead")
  local attr = self:parse_attr()
  local rows = self:parse_list(function(p) return p:parse_row() end)
  if paren then self:expect("punct", ")") end
  return { attr = attr, rows = rows }
end

function parser_mt:parse_table_body()
  local paren = self:accept("punct", "(")
  self:expect("ident", "TableBody")
  local attr = self:parse_attr()
  -- RowHeadColumns n
  local paren2 = self:accept("punct", "(")
  self:expect("ident", "RowHeadColumns")
  local rhc = self:expect("num").val
  if paren2 then self:expect("punct", ")") end
  local head_rows = self:parse_list(function(p) return p:parse_row() end)
  local body_rows = self:parse_list(function(p) return p:parse_row() end)
  if paren then self:expect("punct", ")") end
  return {
    attr = attr, row_head_columns = rhc,
    head = head_rows, body = body_rows,
  }
end

function parser_mt:parse_table_foot()
  local paren = self:accept("punct", "(")
  self:expect("ident", "TableFoot")
  local attr = self:parse_attr()
  local rows = self:parse_list(function(p) return p:parse_row() end)
  if paren then self:expect("punct", ")") end
  return { attr = attr, rows = rows }
end

function parser_mt:parse_row()
  local paren = self:accept("punct", "(")
  self:expect("ident", "Row")
  local attr = self:parse_attr()
  local cells = self:parse_list(function(p) return p:parse_cell() end)
  if paren then self:expect("punct", ")") end
  return { attr = attr, cells = cells }
end

function parser_mt:parse_cell()
  local paren = self:accept("punct", "(")
  self:expect("ident", "Cell")
  local attr = self:parse_attr()
  local align = self:expect("ident").val
  -- RowSpan n ColSpan n
  local function parse_span(name)
    local p = self:accept("punct", "(")
    self:expect("ident", name)
    local v = self:expect("num").val
    if p then self:expect("punct", ")") end
    return v
  end
  local rs = parse_span("RowSpan")
  local cs = parse_span("ColSpan")
  local content = self:parse_blocks()
  if paren then self:expect("punct", ")") end
  return {
    attr = attr, alignment = align,
    row_span = rs, col_span = cs, content = content,
  }
end

function parser_mt:parse_meta_value()
  local t = self:peek()
  if t.kind == "punct" and t.val == "(" then
    self:advance()
    local v = self:parse_meta_value()
    self:expect("punct", ")")
    return v
  end
  local tag = self:expect("ident").val
  if tag == "MetaString" then return self:expect("str").val
  elseif tag == "MetaBool" then
    local b = self:expect("ident").val
    return b == "True"
  elseif tag == "MetaInlines" then return self:parse_inlines()
  elseif tag == "MetaBlocks" then return self:parse_blocks()
  elseif tag == "MetaList" then
    return self:parse_list(function(p) return p:parse_meta_value() end)
  elseif tag == "MetaMap" then
    -- MetaMap (fromList [("k", MetaValue), ...])
    local paren = self:accept("punct", "(")
    self:expect("ident", "fromList")
    local entries = self:parse_list(function(p)
      p:expect("punct", "(")
      local k = p:expect("str").val
      p:expect("punct", ",")
      local v = p:parse_meta_value()
      p:expect("punct", ")")
      return { k, v }
    end)
    if paren then self:expect("punct", ")") end
    local out = {}
    for _, e in ipairs(entries) do out[e[1]] = e[2] end
    return out
  end
  error("native reader: unknown MetaValue tag: " .. tag)
end

function parser_mt:parse_meta()
  -- Meta {unMeta = fromList [("k", MetaValue), ...]}
  local paren = self:accept("punct", "(")
  self:expect("ident", "Meta")
  self:expect("punct", "{")
  self:expect("ident", "unMeta")
  self:expect("punct", "=")
  self:expect("ident", "fromList")
  local entries = self:parse_list(function(p)
    p:expect("punct", "(")
    local k = p:expect("str").val
    p:expect("punct", ",")
    local v = p:parse_meta_value()
    p:expect("punct", ")")
    return { k, v }
  end)
  self:expect("punct", "}")
  if paren then self:expect("punct", ")") end
  local out = {}
  for _, e in ipairs(entries) do out[e[1]] = e[2] end
  return out
end

function Reader(input, opts)
  local tokens = tokenize(input)
  local p = setmetatable({ tokens = tokens, pos = 1 }, parser_mt)
  -- Standalone form starts with `Pandoc Meta {...} [Blocks]`
  local first = p:peek()
  if first and first.kind == "ident" and first.val == "Pandoc" then
    p:advance()
    local meta = p:parse_meta()
    local blocks = p:parse_blocks()
    return pandoc.Pandoc(blocks, meta)
  end
  -- Otherwise expect a block list.
  local blocks = p:parse_blocks()
  return pandoc.Pandoc(blocks, {})
end
