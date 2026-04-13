-- minipandoc builtin: writers/html.lua
-- Pure-Lua HTML5 writer. Not byte-identical to pandoc's -t html5 output
-- (pandoc's writer carries years of accreted features, e.g. syntax
-- highlighting, smart-quote rendering) — we target semantic parity:
-- `pandoc -f html -t native` should parse our HTML back to the same AST.

local layout = pandoc.layout
local literal, concat, cr, blankline = layout.literal, layout.concat,
  layout.cr, layout.blankline
local stringify = pandoc.utils.stringify

local Blocks = {}
local Inlines = {}

local footnotes = {}

local function escape_text(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

local function escape_attr(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  return s
end

local function render_attrs(attr)
  if not attr then return "" end
  local buf = {}
  if attr.identifier and attr.identifier ~= "" then
    buf[#buf+1] = ' id="' .. escape_attr(attr.identifier) .. '"'
  end
  if attr.classes and #attr.classes > 0 then
    local cs = {}
    for _, c in ipairs(attr.classes) do cs[#cs+1] = escape_attr(c) end
    buf[#buf+1] = ' class="' .. table.concat(cs, " ") .. '"'
  end
  if attr.attributes then
    for _, pair in ipairs(attr.attributes) do
      buf[#buf+1] = ' ' .. pair[1] .. '="' .. escape_attr(pair[2]) .. '"'
    end
  end
  return table.concat(buf)
end

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

Inlines.Str = function(el) return literal(escape_text(el.text)) end
Inlines.Space = function() return literal(" ") end
Inlines.SoftBreak = function() return cr end
Inlines.LineBreak = function() return concat{ literal("<br />"), cr } end

local function wrap_tag(name)
  return function(el)
    return concat{ literal("<" .. name .. ">"), inlines(el.content),
                   literal("</" .. name .. ">") }
  end
end

Inlines.Emph = wrap_tag("em")
Inlines.Strong = wrap_tag("strong")
Inlines.Underline = wrap_tag("u")
Inlines.Strikeout = wrap_tag("del")
Inlines.Superscript = wrap_tag("sup")
Inlines.Subscript = wrap_tag("sub")

Inlines.SmallCaps = function(el)
  return concat{ literal('<span class="smallcaps">'),
                 inlines(el.content), literal("</span>") }
end

Inlines.Quoted = function(el)
  -- Pandoc's HTML writer renders curly unicode quotes; its HTML reader only
  -- recognizes <q>…</q> as Quoted DoubleQuote, so perfect round-trip is
  -- impossible. Matching pandoc's emission keeps our round-trip equivalent
  -- to pandoc's.
  local o, c
  if el.quotetype == "DoubleQuote" then
    o, c = "\226\128\156", "\226\128\157"  -- U+201C, U+201D
  else
    o, c = "\226\128\152", "\226\128\153"  -- U+2018, U+2019
  end
  return concat{ literal(o), inlines(el.content), literal(c) }
end

Inlines.Cite = function(el) return inlines(el.content) end

Inlines.Code = function(el)
  return concat{ literal("<code" .. render_attrs(el.attr) .. ">"),
                 literal(escape_text(el.text)),
                 literal("</code>") }
end

Inlines.Math = function(el)
  if el.mathtype == "DisplayMath" then
    return concat{ literal('<span class="math display">\\['),
                   literal(escape_text(el.text)),
                   literal("\\]</span>") }
  else
    return concat{ literal('<span class="math inline">\\('),
                   literal(escape_text(el.text)),
                   literal("\\)</span>") }
  end
end

Inlines.RawInline = function(el)
  if el.format == "html" or el.format == "html5" or el.format == "html4" then
    return literal(el.text)
  end
  return literal("")
end

Inlines.Link = function(el)
  local attrs = { ' href="' .. escape_attr(el.target or "") .. '"' }
  if el.title and el.title ~= "" then
    attrs[#attrs+1] = ' title="' .. escape_attr(el.title) .. '"'
  end
  attrs[#attrs+1] = render_attrs(el.attr)
  return concat{ literal("<a" .. table.concat(attrs) .. ">"),
                 inlines(el.content), literal("</a>") }
end

Inlines.Image = function(el)
  local alt = escape_attr(stringify(el.caption))
  local attrs = { ' src="' .. escape_attr(el.src or "") .. '"',
                  ' alt="' .. alt .. '"' }
  if el.title and el.title ~= "" then
    attrs[#attrs+1] = ' title="' .. escape_attr(el.title) .. '"'
  end
  attrs[#attrs+1] = render_attrs(el.attr)
  return literal("<img" .. table.concat(attrs) .. " />")
end

Inlines.Note = function(el)
  footnotes[#footnotes+1] = el.content
  local num = #footnotes
  return literal(string.format(
    '<a href="#fn%d" class="footnote-ref" id="fnref%d" role="doc-noteref"><sup>%d</sup></a>',
    num, num, num))
end

Inlines.Span = function(el)
  return concat{ literal("<span" .. render_attrs(el.attr) .. ">"),
                 inlines(el.content), literal("</span>") }
end

-- ---------------------------------------------------------------------------
-- Block writers
-- ---------------------------------------------------------------------------

Blocks.Para = function(el)
  return concat{ literal("<p>"), inlines(el.content), literal("</p>") }
end

Blocks.Plain = function(el) return inlines(el.content) end

Blocks.Header = function(el)
  local tag = "h" .. tostring(el.level)
  return concat{ literal("<" .. tag .. render_attrs(el.attr) .. ">"),
                 inlines(el.content), literal("</" .. tag .. ">") }
end

Blocks.BlockQuote = function(el)
  return concat{ literal("<blockquote>"), cr,
                 blocks(el.content, cr), cr,
                 literal("</blockquote>") }
end

local function list_items(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out+1] = concat{ literal("<li>"), blocks(item, cr), literal("</li>") }
  end
  return concat(out, cr)
end

Blocks.BulletList = function(el)
  return concat{ literal("<ul>"), cr,
                 list_items(el.content), cr,
                 literal("</ul>") }
end

Blocks.OrderedList = function(el)
  local attrs = {}
  local start = el.start or (el.listAttributes and el.listAttributes.start) or 1
  if start ~= 1 then attrs[#attrs+1] = ' start="' .. tostring(start) .. '"' end
  local style = el.style or (el.listAttributes and el.listAttributes.style)
  local type_attr
  if style == "LowerAlpha" then type_attr = "a"
  elseif style == "UpperAlpha" then type_attr = "A"
  elseif style == "LowerRoman" then type_attr = "i"
  elseif style == "UpperRoman" then type_attr = "I"
  elseif style == "Decimal" or style == "Example" then type_attr = "1"
  end
  if type_attr then
    attrs[#attrs+1] = ' type="' .. type_attr .. '"'
  end
  return concat{ literal("<ol" .. table.concat(attrs) .. ">"), cr,
                 list_items(el.content), cr,
                 literal("</ol>") }
end

Blocks.DefinitionList = function(el)
  local out = {}
  for _, item in ipairs(el.content) do
    local term, defs = item[1], item[2]
    out[#out+1] = concat{ literal("<dt>"), inlines(term), literal("</dt>") }
    for _, d in ipairs(defs) do
      out[#out+1] = concat{ literal("<dd>"), blocks(d, cr), literal("</dd>") }
    end
  end
  return concat{ literal("<dl>"), cr, concat(out, cr), cr, literal("</dl>") }
end

Blocks.CodeBlock = function(el)
  return concat{ literal("<pre><code" .. render_attrs(el.attr) .. ">"),
                 literal(escape_text(el.text)),
                 literal("</code></pre>") }
end

Blocks.RawBlock = function(el)
  if el.format == "html" or el.format == "html5" or el.format == "html4" then
    return literal(el.text)
  end
  return layout.empty
end

Blocks.LineBlock = function(el)
  local lines = {}
  for _, line in ipairs(el.content) do
    lines[#lines+1] = concat{ literal('<div class="line">'),
                              inlines(line), literal("</div>") }
  end
  return concat{ literal('<div class="line-block">'), cr,
                 concat(lines, cr), cr, literal("</div>") }
end

Blocks.HorizontalRule = function() return literal("<hr />") end

local function has_class(attr, name)
  if not attr or not attr.classes then return false end
  for _, c in ipairs(attr.classes) do
    if c == name then return true end
  end
  return false
end

local function attr_without_class(attr, drop_class)
  if not attr then return nil end
  local classes = {}
  for _, c in ipairs(attr.classes or {}) do
    if c ~= drop_class then classes[#classes+1] = c end
  end
  local kvs = {}
  for _, pair in ipairs(attr.attributes or {}) do
    kvs[#kvs+1] = { pair[1], pair[2] }
  end
  return pandoc.Attr(attr.identifier, classes, kvs)
end

Blocks.Div = function(el)
  -- Emit <section> for Divs with "section" class so pandoc's HTML reader
  -- reconstructs them as section-Divs on round-trip.
  if has_class(el.attr, "section") then
    local trimmed = attr_without_class(el.attr, "section")
    return concat{ literal("<section" .. render_attrs(trimmed) .. ">"), cr,
                   blocks(el.content, cr), cr,
                   literal("</section>") }
  end
  return concat{ literal("<div" .. render_attrs(el.attr) .. ">"), cr,
                 blocks(el.content, cr), cr,
                 literal("</div>") }
end

Blocks.Figure = function(el)
  local parts = { literal("<figure" .. render_attrs(el.attr) .. ">"), cr,
                  blocks(el.content, cr) }
  if el.caption and el.caption.long and #el.caption.long > 0 then
    parts[#parts+1] = cr
    parts[#parts+1] = concat{ literal("<figcaption>"),
                              blocks(el.caption.long, cr),
                              literal("</figcaption>") }
  end
  parts[#parts+1] = cr
  parts[#parts+1] = literal("</figure>")
  return concat(parts)
end

local function align_style(a)
  if a == "AlignLeft" then return ' style="text-align: left;"'
  elseif a == "AlignRight" then return ' style="text-align: right;"'
  elseif a == "AlignCenter" then return ' style="text-align: center;"'
  end
  return ""
end

local function render_cell(cell, tag, colalign)
  local align = cell.alignment
  if align == nil or align == "AlignDefault" then align = colalign end
  local style = align_style(align)
  local attrs = render_attrs(cell.attr) .. style
  if cell.row_span and cell.row_span > 1 then
    attrs = attrs .. ' rowspan="' .. tostring(cell.row_span) .. '"'
  end
  if cell.col_span and cell.col_span > 1 then
    attrs = attrs .. ' colspan="' .. tostring(cell.col_span) .. '"'
  end
  return concat{ literal("<" .. tag .. attrs .. ">"),
                 blocks(cell.content, cr),
                 literal("</" .. tag .. ">") }
end

local function render_row(row, tag, colaligns)
  local cells = {}
  for i, cell in ipairs(row.cells or {}) do
    cells[#cells+1] = render_cell(cell, tag, (colaligns or {})[i])
  end
  return concat{ literal("<tr" .. render_attrs(row.attr) .. ">"), cr,
                 concat(cells, cr), cr,
                 literal("</tr>") }
end

Blocks.Table = function(el)
  local colaligns = {}
  for _, spec in ipairs(el.colspecs or {}) do
    colaligns[#colaligns+1] = spec[1] or "AlignDefault"
  end
  local parts = { literal("<table" .. render_attrs(el.attr) .. ">"), cr }
  if el.caption and el.caption.long and #el.caption.long > 0 then
    parts[#parts+1] = concat{ literal("<caption>"),
                              blocks(el.caption.long, cr),
                              literal("</caption>") }
    parts[#parts+1] = cr
  end
  local head_rows = (el.head or {}).rows or {}
  if #head_rows > 0 then
    local hrows = {}
    for _, r in ipairs(head_rows) do
      hrows[#hrows+1] = render_row(r, "th", colaligns)
    end
    parts[#parts+1] = concat{ literal("<thead>"), cr,
                              concat(hrows, cr), cr,
                              literal("</thead>") }
    parts[#parts+1] = cr
  end
  for _, body in ipairs(el.bodies or {}) do
    local brows = {}
    for _, r in ipairs(body.head or {}) do
      brows[#brows+1] = render_row(r, "th", colaligns)
    end
    for _, r in ipairs(body.body or {}) do
      brows[#brows+1] = render_row(r, "td", colaligns)
    end
    parts[#parts+1] = concat{ literal("<tbody>"), cr,
                              concat(brows, cr), cr,
                              literal("</tbody>") }
    parts[#parts+1] = cr
  end
  local foot_rows = (el.foot or {}).rows or {}
  if #foot_rows > 0 then
    local frows = {}
    for _, r in ipairs(foot_rows) do
      frows[#frows+1] = render_row(r, "td", colaligns)
    end
    parts[#parts+1] = concat{ literal("<tfoot>"), cr,
                              concat(frows, cr), cr,
                              literal("</tfoot>") }
    parts[#parts+1] = cr
  end
  parts[#parts+1] = literal("</table>")
  return concat(parts)
end

-- ---------------------------------------------------------------------------
-- Footnote section
-- ---------------------------------------------------------------------------

local function render_footnotes()
  if #footnotes == 0 then return layout.empty end
  local items = {}
  for i, content in ipairs(footnotes) do
    local note = blocks(content, cr)
    local backref = literal(string.format(
      '<a href="#fnref%d" class="footnote-back" role="doc-backlink">↩︎</a>', i))
    -- Append the backref inline to the last Para/Plain's content when possible,
    -- so pandoc's HTML reader can reconstruct a single Note element.
    items[#items+1] = concat{
      literal(string.format('<li id="fn%d">', i)), cr,
      note, backref, cr, literal("</li>") }
  end
  return concat{ blankline,
    literal('<section id="footnotes" class="footnotes footnotes-end-of-document" role="doc-endnotes">'), cr,
    literal("<hr />"), cr,
    literal("<ol>"), cr,
    concat(items, cr), cr,
    literal("</ol>"), cr,
    literal("</section>") }
end

-- ---------------------------------------------------------------------------
-- Writer entry point
-- ---------------------------------------------------------------------------

local function build_template_context(doc, opts, body)
  local ctx = pandoc.template.meta_to_context(doc.meta or {})
  if opts and opts.variables then
    for k, v in pairs(opts.variables) do ctx[k] = v end
  end
  ctx.body = body
  if not ctx.pagetitle and ctx.title then
    ctx.pagetitle = ctx.title
  end
  return ctx
end

function Writer(doc, opts)
  footnotes = {}
  local body = blocks(doc.blocks or {}, blankline)
  local notes = render_footnotes()
  local out = layout.render(concat{ body, notes })
  if opts and opts.standalone then
    local tpl_src = (opts and opts.template ~= "" and opts.template)
                    or pandoc.template.default(FORMAT or "html")
    local compiled = pandoc.template.compile(tpl_src)
    out = pandoc.template.apply(compiled, build_template_context(doc, opts, out))
  end
  return out
end
