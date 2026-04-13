-- minipandoc builtin: writers/plain.lua
-- Pure-Lua "plain" writer. Mirrors pandoc -t plain semantics: stripped
-- markdown — no markup syntax for emph/strong/header/link, but a few
-- inlines do keep telegraphic syntax: ~~strike~~, _(sub), ^(sup),
-- SMALLCAPS in uppercase. Tables render as 2-indented columns; complex
-- cells fall back to a grid-table form that pandoc also accepts.

local layout = pandoc.layout
local literal, concat, cr, blankline, nest, hang =
  layout.literal, layout.concat, layout.cr, layout.blankline,
  layout.nest, layout.hang
local stringify = pandoc.utils.stringify

local Blocks = {}
local Inlines = {}

local footnotes = {}

local function inlines(ils)
  local buf = {}
  for _, el in ipairs(ils or {}) do
    local fn = Inlines[el.tag]
    if fn then buf[#buf+1] = fn(el) end
  end
  return concat(buf)
end

local function blocks(bs, sep)
  local buf = {}
  for _, el in ipairs(bs or {}) do
    local fn = Blocks[el.tag]
    if fn then buf[#buf+1] = fn(el) end
  end
  return concat(buf, sep)
end

-- ---------------------------------------------------------------------------
-- Inline writers
-- ---------------------------------------------------------------------------

Inlines.Str = function(el) return literal(el.text or "") end
Inlines.Space = function() return literal(" ") end
Inlines.SoftBreak = function() return layout.space end
Inlines.LineBreak = function() return cr end

local function pass_through(el) return inlines(el.content) end

Inlines.Emph = pass_through
Inlines.Strong = pass_through
Inlines.Underline = pass_through
Inlines.Cite = pass_through
Inlines.Span = pass_through

Inlines.Strikeout = function(el)
  return concat{ literal("~~"), inlines(el.content), literal("~~") }
end

Inlines.Subscript = function(el)
  return concat{ literal("_("), inlines(el.content), literal(")") }
end

Inlines.Superscript = function(el)
  return concat{ literal("^("), inlines(el.content), literal(")") }
end

Inlines.SmallCaps = function(el)
  return literal(string.upper(stringify(el.content)))
end

Inlines.Quoted = function(el)
  local o, c
  if el.quotetype == "DoubleQuote" then
    o, c = "\226\128\156", "\226\128\157"  -- U+201C, U+201D
  else
    o, c = "\226\128\152", "\226\128\153"  -- U+2018, U+2019
  end
  return concat{ literal(o), inlines(el.content), literal(c) }
end

Inlines.Code = function(el) return literal(el.text or "") end

Inlines.Math = function(el)
  -- Pandoc converts TeX math to Unicode (texmath). We can't replicate
  -- that without a math engine, so emit the raw source. Display math
  -- gets surrounding line breaks.
  if el.mathtype == "DisplayMath" then
    return concat{ cr, literal(el.text or ""), cr }
  end
  return literal(el.text or "")
end

Inlines.RawInline = function(el)
  if el.format == "plain" then return literal(el.text or "") end
  return layout.empty
end

Inlines.Link = function(el) return inlines(el.content) end

Inlines.Image = function(el)
  -- Pandoc plain emits "\!alt" — escape the leading bang so a markdown
  -- reader won't reinterpret as an image.
  local alt = stringify(el.caption)
  return literal("\\!" .. alt)
end

Inlines.Note = function(el)
  footnotes[#footnotes+1] = el.content
  return literal("[" .. #footnotes .. "]")
end

-- ---------------------------------------------------------------------------
-- Block writers
-- ---------------------------------------------------------------------------

Blocks.Plain = function(el) return inlines(el.content) end
Blocks.Para = function(el) return inlines(el.content) end

Blocks.Header = function(el) return inlines(el.content) end

Blocks.BlockQuote = function(el)
  return nest(blocks(el.content, blankline), 2)
end

Blocks.CodeBlock = function(el)
  return nest(literal(el.text or ""), 4)
end

Blocks.LineBlock = function(el)
  local out = {}
  for _, line in ipairs(el.content or {}) do
    out[#out+1] = inlines(line)
  end
  return concat(out, cr)
end

Blocks.RawBlock = function(el)
  if el.format == "plain" then return literal(el.text or "") end
  return layout.empty
end

Blocks.HorizontalRule = function()
  local cols = (PANDOC_WRITER_OPTIONS and PANDOC_WRITER_OPTIONS.columns) or 72
  return literal(string.rep("-", cols))
end

local function bullet_marker() return "- " end

local function ordered_marker(i, start, style, delim)
  local n = (start or 1) + i - 1
  local label
  if style == "LowerRoman" or style == "UpperRoman" then
    -- Minimal roman numerals (1..49 covers reasonable lists)
    local roman = ""
    local v = n
    local pairs_ = {
      {10,"x"},{9,"ix"},{5,"v"},{4,"iv"},{1,"i"},
    }
    while v > 0 do
      for _, pr in ipairs(pairs_) do
        while v >= pr[1] do roman = roman .. pr[2]; v = v - pr[1] end
      end
    end
    label = (style == "UpperRoman") and string.upper(roman) or roman
  elseif style == "LowerAlpha" or style == "UpperAlpha" then
    local letter = string.char(string.byte("a") + ((n - 1) % 26))
    label = (style == "UpperAlpha") and string.upper(letter) or letter
  else
    label = tostring(n)
  end
  if delim == "OneParen" then return label .. ")  "
  elseif delim == "TwoParens" then return "(" .. label .. ")  "
  else return label .. ".  " end
end

local function is_tight_list(items)
  for _, item in ipairs(items) do
    for _, b in ipairs(item) do
      if b.tag == "Para" then return false end
    end
  end
  return true
end

local function list_to_doc(items, marker_fn)
  local sep = is_tight_list(items) and cr or blankline
  local out = {}
  for i, item in ipairs(items) do
    local marker = marker_fn(i)
    local indent = #marker
    local body = blocks(item, sep)
    out[#out+1] = hang(body, indent, literal(marker))
  end
  return concat(out, sep)
end

Blocks.BulletList = function(el)
  return list_to_doc(el.content or {}, function() return bullet_marker() end)
end

Blocks.OrderedList = function(el)
  local la = el.listAttributes or {}
  local start = el.start or la.start or 1
  local style = el.style or la.style
  local delim = el.delimiter or la.delimiter
  return list_to_doc(el.content or {}, function(i)
    return ordered_marker(i, start, style, delim)
  end)
end

Blocks.DefinitionList = function(el)
  local function tight()
    for _, item in ipairs(el.content or {}) do
      for _, defn in ipairs(item[2]) do
        for _, b in ipairs(defn) do
          if b.tag == "Para" then return false end
        end
      end
    end
    return true
  end
  local sep = tight() and cr or blankline
  local out = {}
  for _, item in ipairs(el.content or {}) do
    local term, defs = item[1], item[2]
    local rendered_defs = {}
    for _, d in ipairs(defs) do
      rendered_defs[#rendered_defs+1] = blocks(d, sep)
    end
    out[#out+1] = concat{
      inlines(term), cr,
      nest(concat(rendered_defs, sep), 4),
    }
  end
  return concat(out, blankline)
end

Blocks.Div = function(el)
  return blocks(el.content, blankline)
end

Blocks.Figure = function(el)
  local parts = { blocks(el.content, cr) }
  if el.caption and el.caption.long and #el.caption.long > 0 then
    parts[#parts+1] = cr
    parts[#parts+1] = blocks(el.caption.long, cr)
  end
  return concat(parts)
end

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

local function rows_from_table(el)
  local hrows = (el.head or {}).rows or {}
  local brows = {}
  for _, body in ipairs(el.bodies or {}) do
    for _, r in ipairs(body.body or {}) do brows[#brows+1] = r end
  end
  local frows = (el.foot or {}).rows or {}
  return hrows, brows, frows
end

local function cell_blocks(cell) return cell.content or {} end

local function is_simple_table(el)
  local hrows, brows, frows = rows_from_table(el)
  local function check(rows)
    for _, r in ipairs(rows) do
      for _, cell in ipairs(r.cells or {}) do
        local cb = cell_blocks(cell)
        if #cb > 1 then return false end
        if #cb == 1 then
          local tag = cb[1].tag
          if tag ~= "Plain" and tag ~= "Para" then return false end
        end
      end
    end
    return true
  end
  return check(hrows) and check(brows) and check(frows)
end

local function render_simple_cell(cell)
  local cb = cell_blocks(cell)
  if #cb == 0 then return "" end
  return layout.render(inlines(cb[1].content or {}), 1/0)
end

local function render_simple_table(el)
  local hrows, brows = rows_from_table(el)
  local first_body = brows[1] or (hrows[1] or { cells = {} })
  local ncols = #(first_body.cells or {})
  if ncols == 0 and #hrows > 0 then ncols = #(hrows[1].cells or {}) end
  if ncols == 0 then return layout.empty end

  local widths = {}
  for i = 1, ncols do widths[i] = 0 end
  local function measure(rows)
    for _, r in ipairs(rows) do
      for i, cell in ipairs(r.cells or {}) do
        local s = render_simple_cell(cell)
        if #s > widths[i] then widths[i] = #s end
      end
    end
  end
  measure(hrows); measure(brows)
  for i = 1, ncols do widths[i] = widths[i] + 2 end

  local function row_to_line(r)
    local parts = {}
    for i = 1, ncols do
      local cell = (r.cells or {})[i]
      local s = cell and render_simple_cell(cell) or ""
      local pad = widths[i] - #s
      if pad < 0 then pad = 0 end
      parts[i] = s .. string.rep(" ", pad)
    end
    -- Strip trailing whitespace (pandoc does).
    local line = table.concat(parts, " ")
    return (line:gsub("%s+$", ""))
  end

  local function dash_line()
    local parts = {}
    for i = 1, ncols do parts[i] = string.rep("-", widths[i]) end
    return table.concat(parts, " ")
  end

  local lines = {}
  if #hrows > 0 then
    for _, r in ipairs(hrows) do lines[#lines+1] = row_to_line(r) end
    lines[#lines+1] = dash_line()
  else
    -- Headerless table: pandoc still emits a leading dash line.
    lines[#lines+1] = dash_line()
  end
  for _, r in ipairs(brows) do lines[#lines+1] = row_to_line(r) end
  if #hrows == 0 then lines[#lines+1] = dash_line() end

  -- Build doc; nest 2 indents the whole block.
  local doc_parts = {}
  for i, line in ipairs(lines) do
    if i > 1 then doc_parts[#doc_parts+1] = cr end
    doc_parts[#doc_parts+1] = literal(line)
  end
  local body = nest(concat(doc_parts), 2)
  if el.caption and el.caption.long and #el.caption.long > 0 then
    return concat{
      body, blankline,
      nest(concat{ literal(": "), blocks(el.caption.long, cr) }, 2),
    }
  end
  return body
end

local function render_grid_table(el)
  -- Complex (multi-block) cells: render as a grid table — pandoc accepts
  -- this both visually and as input. Layout: each cell is a column block,
  -- columns separated by '|', rows separated by '+---+' borders. Header
  -- row is followed by a '=' border.
  local hrows, brows = rows_from_table(el)
  local ncols
  if #hrows > 0 then ncols = #(hrows[1].cells or {})
  elseif #brows > 0 then ncols = #(brows[1].cells or {})
  else return layout.empty end

  -- Render each cell into a list of lines.
  local function cell_lines(cell)
    local doc = blocks(cell_blocks(cell), blankline)
    local s = layout.render(doc, 1/0)
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do out[#out+1] = line end
    if #out > 0 and out[#out] == "" then out[#out] = nil end
    if #out == 0 then out[1] = "" end
    return out
  end

  -- Compute column widths.
  local widths = {}
  for i = 1, ncols do widths[i] = 0 end
  local function measure(rows)
    for _, r in ipairs(rows) do
      for i, cell in ipairs(r.cells or {}) do
        for _, line in ipairs(cell_lines(cell)) do
          if #line > widths[i] then widths[i] = #line end
        end
      end
    end
  end
  measure(hrows); measure(brows)
  for i = 1, ncols do widths[i] = math.max(widths[i] + 2, 3) end

  local function border(ch)
    local parts = {}
    for i = 1, ncols do parts[i] = string.rep(ch, widths[i]) end
    return "+" .. table.concat(parts, "+") .. "+"
  end

  local function render_row(r)
    local cell_box = {}
    local height = 0
    for i = 1, ncols do
      local cell = (r.cells or {})[i]
      local lines = cell and cell_lines(cell) or { "" }
      cell_box[i] = lines
      if #lines > height then height = #lines end
    end
    local out_lines = {}
    for line_i = 1, height do
      local parts = {}
      for i = 1, ncols do
        local s = cell_box[i][line_i] or ""
        local pad = widths[i] - 1 - #s
        if pad < 0 then pad = 0 end
        parts[i] = " " .. s .. string.rep(" ", pad)
      end
      out_lines[line_i] = "|" .. table.concat(parts, "|") .. "|"
    end
    return out_lines
  end

  local lines = { border("-") }
  if #hrows > 0 then
    for _, r in ipairs(hrows) do
      for _, l in ipairs(render_row(r)) do lines[#lines+1] = l end
    end
    lines[#lines+1] = border("=")
  end
  for ri, r in ipairs(brows) do
    for _, l in ipairs(render_row(r)) do lines[#lines+1] = l end
    if ri < #brows then lines[#lines+1] = border("-") end
  end
  lines[#lines+1] = border("-")

  local parts = {}
  for i, line in ipairs(lines) do
    if i > 1 then parts[#parts+1] = cr end
    parts[#parts+1] = literal(line)
  end
  return concat(parts)
end

Blocks.Table = function(el)
  if is_simple_table(el) then
    return render_simple_table(el)
  end
  return render_grid_table(el)
end

-- ---------------------------------------------------------------------------
-- Footnote section
-- ---------------------------------------------------------------------------

local function render_footnotes()
  if #footnotes == 0 then return layout.empty end
  local items = {}
  for i, content in ipairs(footnotes) do
    local marker = "[" .. i .. "] "
    items[#items+1] = hang(blocks(content, blankline), 0, literal(marker))
  end
  return concat{ blankline, concat(items, blankline) }
end

-- ---------------------------------------------------------------------------
-- Writer entry point
-- ---------------------------------------------------------------------------

function Writer(doc, opts)
  footnotes = {}
  local body = blocks(doc.blocks or {}, blankline)
  local notes = render_footnotes()
  local cols = (opts and opts.columns) or 72
  return layout.render(concat{ body, notes }, cols)
end
