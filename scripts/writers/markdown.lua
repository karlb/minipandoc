-- minipandoc builtin: writers/markdown.lua
-- Pure-Lua pandoc-flavored markdown writer. Targets semantic parity with
-- `pandoc -t markdown`: the output round-trips through pandoc's markdown
-- reader back to the same native AST (modulo wrap positions and a few
-- idiosyncratic quote/escape choices). Byte-parity is intended on focused
-- fixtures; wrap-sensitive or complex-table fixtures run smoke-only.

local layout = pandoc.layout
local literal, concat, cr, blankline, nest, hang, prefixed, chomp =
  layout.literal, layout.concat, layout.cr, layout.blankline,
  layout.nest, layout.hang, layout.prefixed, layout.chomp
local stringify = pandoc.utils.stringify

local Blocks = {}
local Inlines = {}

local footnotes = {}

-- ---------------------------------------------------------------------------
-- Escaping
-- ---------------------------------------------------------------------------

-- Escape characters that have syntactic meaning in pandoc-flavored markdown
-- body text. We over-escape relative to pandoc's optimum (which is context-
-- aware) because pandoc's reader tolerates superfluous backslashes; the
-- alternative would be a second-pass formatter. Characters escaped:
--   \ ` * _ [ ] < > $ ~ ^
-- We also turn "!" immediately preceding "[" into "\!" so it can't be read
-- as an image introducer.
local function escape_str(s)
  s = tostring(s or "")
  -- Order matters: escape backslash first.
  s = s:gsub("\\", "\\\\")
  s = s:gsub("([%*_%[%]`<>%$~^])", "\\%1")
  s = s:gsub("!(%[)", "\\!%1")
  -- Smart-quote fold: pandoc's markdown writer rewrites Unicode curly
  -- quotes back to ASCII so the source is plain-smart-quotes friendly.
  s = s:gsub("\xe2\x80\x9c", '"')
       :gsub("\xe2\x80\x9d", '"')
       :gsub("\xe2\x80\x98", "'")
       :gsub("\xe2\x80\x99", "'")
  return s
end

local function escape_title(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  return s
end

local function escape_attr_value(s)
  return escape_title(s)
end

-- ---------------------------------------------------------------------------
-- Attribute rendering (pandoc's {#id .class key="val"} form)
-- ---------------------------------------------------------------------------

local function attr_is_empty(attr)
  if not attr then return true end
  local has_id = attr.identifier and attr.identifier ~= ""
  local has_classes = attr.classes and #attr.classes > 0
  local has_kvs = attr.attributes and #attr.attributes > 0
  return not (has_id or has_classes or has_kvs)
end

local function attr_parts(attr)
  local parts = {}
  if attr.identifier and attr.identifier ~= "" then
    parts[#parts+1] = "#" .. attr.identifier
  end
  for _, c in ipairs(attr.classes or {}) do
    parts[#parts+1] = "." .. c
  end
  for _, pair in ipairs(attr.attributes or {}) do
    parts[#parts+1] = pair[1] .. '="' .. escape_attr_value(pair[2]) .. '"'
  end
  return parts
end

local function render_attr(attr)
  if attr_is_empty(attr) then return "" end
  return "{" .. table.concat(attr_parts(attr), " ") .. "}"
end

-- Layout-doc variant with breakable spaces between attributes. Used where
-- the caller wants wrap points inside the attribute block (matches pandoc
-- 3.x markdown writer, which wraps inside `{...}` on long paragraphs).
local function render_attr_doc(attr)
  if attr_is_empty(attr) then return layout.empty end
  local parts = attr_parts(attr)
  local docs = { literal("{") }
  for i, p in ipairs(parts) do
    if i > 1 then docs[#docs+1] = layout.space end
    docs[#docs+1] = literal(p)
  end
  docs[#docs+1] = literal("}")
  return concat(docs)
end

-- For code blocks: pandoc emits `` ```python `` when the only attr is a
-- single class (treated as language). Otherwise the full `{...}` form.
local function render_codeblock_attr(attr)
  if attr_is_empty(attr) then return nil end  -- fall back to indented form
  local has_id = attr.identifier and attr.identifier ~= ""
  local has_kvs = attr.attributes and #attr.attributes > 0
  local classes = attr.classes or {}
  if not has_id and not has_kvs and #classes == 1 then
    return classes[1]  -- bare info-string form
  end
  return render_attr(attr)
end

-- ---------------------------------------------------------------------------
-- Recursive renderers
-- ---------------------------------------------------------------------------

local function inlines(ils)
  ils = ils or {}
  local buf = {}
  for i, el in ipairs(ils) do
    -- A trailing "!" in a Str followed by a Link would render as "![...]"
    -- which pandoc's reader would parse as an Image. Escape the bang.
    if el.tag == "Str" and (el.text or ""):sub(-1) == "!"
       and ils[i+1] and ils[i+1].tag == "Link" then
      buf[#buf+1] = literal(escape_str((el.text):sub(1, -2)) .. "\\!")
    else
      local fn = Inlines[el.tag]
      if fn then buf[#buf+1] = fn(el) end
    end
  end
  return concat(buf)
end

local function is_list_tag(tag)
  return tag == "BulletList" or tag == "OrderedList"
end

local function blocks(bs, sep)
  local buf = {}
  local prev_tag = nil
  for _, el in ipairs(bs or {}) do
    local fn = Blocks[el.tag]
    if fn then
      -- Insert an HTML comment separator between consecutive same-type
      -- lists so pandoc's reader doesn't merge them.
      if is_list_tag(el.tag) and el.tag == prev_tag then
        buf[#buf+1] = literal("<!-- -->")
      end
      buf[#buf+1] = fn(el)
      prev_tag = el.tag
    end
  end
  return concat(buf, sep)
end

-- ---------------------------------------------------------------------------
-- Inline writers
-- ---------------------------------------------------------------------------

Inlines.Str = function(el) return literal(escape_str(el.text)) end
Inlines.Space = function() return layout.space end
Inlines.SoftBreak = function() return layout.space end
Inlines.LineBreak = function() return concat{ literal("\\"), cr } end

local function wrap(open, close)
  return function(el)
    return concat{ literal(open), inlines(el.content), literal(close) }
  end
end

Inlines.Emph = wrap("*", "*")
Inlines.Strong = wrap("**", "**")
Inlines.Strikeout = wrap("~~", "~~")
Inlines.Superscript = wrap("^", "^")
Inlines.Subscript = wrap("~", "~")

Inlines.Underline = function(el)
  return concat{ literal("["), inlines(el.content), literal("]{.underline}") }
end

Inlines.SmallCaps = function(el)
  return concat{ literal("["), inlines(el.content), literal("]{.smallcaps}") }
end

Inlines.Quoted = function(el)
  local o, c
  if el.quotetype == "DoubleQuote" then
    o, c = '"', '"'
  else
    o, c = "'", "'"
  end
  return concat{ literal(o), inlines(el.content), literal(c) }
end

Inlines.Cite = function(el) return inlines(el.content) end

-- Backtick-fence length for an inline code span: one more than the longest
-- internal run; pad with spaces when the text starts or ends with `.
local function code_fence_len(s)
  local max = 0
  for run in s:gmatch("`+") do
    if #run > max then max = #run end
  end
  return max + 1
end

Inlines.Code = function(el)
  local text = el.text or ""
  local ticks = string.rep("`", code_fence_len(text))
  local padded = text
  if padded:sub(1, 1) == "`" then padded = " " .. padded end
  if padded:sub(-1) == "`" then padded = padded .. " " end
  local attr = render_attr(el.attr)
  return literal(ticks .. padded .. ticks .. attr)
end

Inlines.Math = function(el)
  if el.mathtype == "DisplayMath" then
    return literal("$$" .. (el.text or "") .. "$$")
  end
  return literal("$" .. (el.text or "") .. "$")
end

Inlines.RawInline = function(el)
  local fmt = el.format or ""
  if fmt == "markdown" or fmt == "tex" or fmt == "latex" then
    return literal(el.text or "")
  end
  -- Other raw formats use pandoc's raw-attribute syntax: `text`{=fmt}
  local text = el.text or ""
  local ticks = string.rep("`", code_fence_len(text))
  local padded = text
  if padded:sub(1, 1) == "`" then padded = " " .. padded end
  if padded:sub(-1) == "`" then padded = padded .. " " end
  return literal(ticks .. padded .. ticks .. "{=" .. fmt .. "}")
end

local function render_link_target(target)
  target = target or ""
  if target:match("[%s%(%)]") then
    return "<" .. target .. ">"
  end
  return target
end

Inlines.Link = function(el)
  local target = el.target or ""
  local title = el.title or ""
  local attr_str = render_attr(el.attr)
  -- Autolink: empty attr, empty title, target equals stringified content.
  if attr_str == "" and title == "" and target == stringify(el.content) then
    if target:match("^[a-zA-Z][a-zA-Z0-9+.-]*:") or target:match("^[^@]+@[^@]+$") then
      return literal("<" .. target .. ">")
    end
  end
  local parts = { literal("["), inlines(el.content), literal("](") }
  parts[#parts+1] = literal(render_link_target(target))
  if title ~= "" then
    parts[#parts+1] = literal(' "' .. escape_title(title) .. '"')
  end
  parts[#parts+1] = literal(")")
  if attr_str ~= "" then parts[#parts+1] = render_attr_doc(el.attr) end
  return concat(parts)
end

Inlines.Image = function(el)
  local src = el.src or ""
  local title = el.title or ""
  local attr_str = render_attr(el.attr)
  local parts = { literal("!["), inlines(el.caption), literal("](") }
  parts[#parts+1] = literal(render_link_target(src))
  if title ~= "" then
    parts[#parts+1] = literal(' "' .. escape_title(title) .. '"')
  end
  parts[#parts+1] = literal(")")
  if attr_str ~= "" then parts[#parts+1] = render_attr_doc(el.attr) end
  return concat(parts)
end

Inlines.Note = function(el)
  footnotes[#footnotes+1] = el.content
  return literal("[^" .. #footnotes .. "]")
end

Inlines.Span = function(el)
  if attr_is_empty(el.attr) then
    return inlines(el.content)
  end
  return concat{ literal("["), inlines(el.content), literal("]"),
                 render_attr_doc(el.attr) }
end

-- ---------------------------------------------------------------------------
-- Block writers
-- ---------------------------------------------------------------------------

Blocks.Plain = function(el) return inlines(el.content) end
Blocks.Para = function(el) return inlines(el.content) end

-- Compute the auto-generated identifier for heading text, matching
-- pandoc's auto_identifiers algorithm: lowercase, replace spaces with
-- hyphens, strip non-alnum (except hyphens/underscores/periods), and
-- remove leading non-letter characters.
local function auto_identifier_base(ils)
  local text = stringify(ils)
  text = text:lower()
  text = text:gsub("%s+", "-")
  text = text:gsub("[^%w%-_%.]", "")
  text = text:gsub("^[^%a]+", "")
  if text == "" then text = "section" end
  return text
end

-- Per-document set of auto-ids already assigned. Pandoc disambiguates
-- by appending `-1`, `-2`, ... to collisions — our suppress logic must
-- follow the same path to match pandoc byte-for-byte on repeated
-- heading text or when an explicit id clashes with an earlier auto id.
local used_auto_ids = {}

local function auto_identifier(ils)
  local base = auto_identifier_base(ils)
  local candidate = base
  local n = 1
  while used_auto_ids[candidate] do
    candidate = base .. "-" .. n
    n = n + 1
  end
  used_auto_ids[candidate] = true
  return candidate
end

Blocks.Header = function(el)
  local level = el.level or 1
  local hashes = string.rep("#", level)
  -- Suppress attribute block when the only attribute is the auto-derived id
  -- (accounting for pandoc's global disambiguation of repeated headings).
  local attr = el.attr
  local auto = auto_identifier(el.content)
  local suppress = false
  if attr and attr.identifier and attr.identifier ~= "" then
    local has_classes = attr.classes and #attr.classes > 0
    local has_kvs = attr.attributes and #attr.attributes > 0
    if not has_classes and not has_kvs then
      if attr.identifier == auto then
        suppress = true
      end
    end
    -- Reserve the explicit id so future auto-ids don't collide with it.
    used_auto_ids[attr.identifier] = true
  end
  local attr_str = suppress and "" or render_attr(attr)
  local parts = { literal(hashes), literal(" "), inlines(el.content) }
  if attr_str ~= "" then
    parts[#parts+1] = literal(" " .. attr_str)
  end
  return concat(parts)
end

Blocks.BlockQuote = function(el)
  -- Render inner content, then prefix every line with "> ". Blank lines
  -- between blocks get ">" (no trailing space) so pandoc's reader parses
  -- them as part of the same blockquote rather than two separate quotes.
  -- (layout.prefixed doesn't apply the prefix to blank lines, which is why
  -- we post-process manually here.)
  local inner = layout.render(blocks(el.content, blankline), math.huge)
  local out_lines = {}
  for line in (inner .. "\n"):gmatch("(.-)\n") do
    if line == "" then
      out_lines[#out_lines+1] = ">"
    else
      out_lines[#out_lines+1] = "> " .. line
    end
  end
  if #out_lines > 0 and out_lines[#out_lines] == "" then
    out_lines[#out_lines] = nil
  end
  local doc_parts = {}
  for i, line in ipairs(out_lines) do
    if i > 1 then doc_parts[#doc_parts+1] = cr end
    doc_parts[#doc_parts+1] = literal(line)
  end
  return concat(doc_parts)
end

-- Fence length for a fenced code block: at least 3 backticks; widen past
-- any internal run of 3+ backticks.
local function codeblock_fence(text)
  local len = 3
  for run in text:gmatch("`+") do
    if #run >= len then len = #run + 1 end
  end
  return string.rep("`", len)
end

Blocks.CodeBlock = function(el)
  local text = el.text or ""
  local info = render_codeblock_attr(el.attr)
  if info == nil then
    -- No attrs → indented form.
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
      lines[#lines+1] = line
    end
    if #lines > 0 and lines[#lines] == "" then lines[#lines] = nil end
    local parts = {}
    for i, line in ipairs(lines) do
      if i > 1 then parts[#parts+1] = cr end
      parts[#parts+1] = literal(line)
    end
    return nest(concat(parts), 4)
  end
  local fence = codeblock_fence(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines+1] = line
  end
  if #lines > 0 and lines[#lines] == "" then lines[#lines] = nil end
  local body_parts = {}
  for i, line in ipairs(lines) do
    if i > 1 then body_parts[#body_parts+1] = cr end
    body_parts[#body_parts+1] = literal(line)
  end
  return concat{
    literal(fence .. " " .. info), cr,
    concat(body_parts), cr,
    literal(fence),
  }
end

Blocks.LineBlock = function(el)
  local parts = {}
  for i, line in ipairs(el.content or {}) do
    if i > 1 then parts[#parts+1] = cr end
    parts[#parts+1] = concat{ literal("| "), inlines(line) }
  end
  return concat(parts)
end

Blocks.RawBlock = function(el)
  local fmt = el.format or ""
  if fmt == "markdown" or fmt == "html" or fmt == "html5" or fmt == "html4"
     or fmt == "tex" or fmt == "latex" then
    return literal(el.text or "")
  end
  local text = el.text or ""
  local fence = codeblock_fence(text)
  return concat{
    literal(fence .. " {=" .. fmt .. "}"), cr,
    literal(text), cr,
    literal(fence),
  }
end

Blocks.HorizontalRule = function()
  return literal(string.rep("-", 72))
end

-- --- Lists --------------------------------------------------------------

local function is_tight_list(items)
  for _, item in ipairs(items) do
    for _, b in ipairs(item) do
      if b.tag == "Para" then return false end
    end
  end
  return true
end

local function ordered_marker(i, start, style, delim)
  local n = (start or 1) + i - 1
  local label
  if style == "LowerRoman" or style == "UpperRoman" then
    local pairs_ = { {10,"x"},{9,"ix"},{5,"v"},{4,"iv"},{1,"i"} }
    local roman, v = "", n
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
  if delim == "OneParen" then return label .. ")"
  elseif delim == "TwoParens" then return "(" .. label .. ")"
  else return label .. "." end
end

-- Pandoc pads list markers out to a 4-char cell (for bullet) or to a width
-- that accommodates the widest marker in an ordered list. Continuation
-- lines indent by the same width.
local function bullet_marker_string() return "- " end

local function list_to_doc(items, marker_for)
  local tight = is_tight_list(items)
  local sep = tight and cr or blankline
  local out = {}
  for i, item in ipairs(items) do
    local marker = marker_for(i)
    local indent = #marker
    local body = blocks(item, sep)
    out[#out+1] = hang(body, indent, literal(marker))
  end
  return concat(out, sep)
end

Blocks.BulletList = function(el)
  return list_to_doc(el.content or {}, function()
    return bullet_marker_string()
  end)
end

Blocks.OrderedList = function(el)
  local la = el.listAttributes or {}
  local start = el.start or la.start or 1
  local style = el.style or la.style or "Decimal"
  local delim = el.delimiter or la.delimiter or "Period"
  local items = el.content or {}
  -- Compute the widest marker label for padding continuation lines.
  local max_len = 0
  for i = 1, #items do
    local m = ordered_marker(i, start, style, delim)
    if #m > max_len then max_len = #m end
  end
  local width = math.max(max_len + 1, 4)  -- marker + padding; at least 4
  return list_to_doc(items, function(i)
    local m = ordered_marker(i, start, style, delim)
    return m .. string.rep(" ", width - #m)
  end)
end

Blocks.DefinitionList = function(el)
  -- Detect tight/loose: tight when all definition bodies use Plain, not Para.
  local function is_tight()
    for _, item in ipairs(el.content or {}) do
      for _, d in ipairs(item[2] or {}) do
        for _, b in ipairs(d) do
          if b.tag == "Para" then return false end
        end
      end
    end
    return true
  end
  local tight = is_tight()
  local def_sep = tight and cr or blankline
  local out = {}
  for _, item in ipairs(el.content or {}) do
    local term, defs = item[1], item[2]
    local defs_out = {}
    for j, d in ipairs(defs) do
      -- Each definition: ":   " on first line, 4-space indent continuation.
      local body = blocks(d, blankline)
      defs_out[#defs_out+1] = hang(body, 4, literal(":   "))
      if j < #defs then defs_out[#defs_out+1] = def_sep end
    end
    out[#out+1] = concat{ inlines(term), cr, concat(defs_out) }
  end
  return concat(out, blankline)
end

-- Return the class name when the attr has exactly one class, no ID, no
-- key-value attrs; otherwise return nil.
local function div_simple_class(attr)
  if not attr then return nil end
  if attr.identifier and attr.identifier ~= "" then return nil end
  local classes = attr.classes or {}
  if #classes ~= 1 then return nil end
  if attr.attributes and #attr.attributes > 0 then return nil end
  return classes[1]
end

-- Compute the maximum div-fence depth needed for a block list.
-- Pandoc uses one more colon than any nested div so fences don't collide.
local function max_div_depth(bs)
  local d = 0
  for _, b in ipairs(bs or {}) do
    if b.tag == "Div" or b.tag == "Figure" then
      d = math.max(d, 1 + max_div_depth(b.content or {}))
    end
  end
  return d
end

local function div_fence(el)
  local depth = 1 + max_div_depth(el.content or {})
  return string.rep(":", math.max(depth + 2, 3))
end

Blocks.Div = function(el)
  local fence = div_fence(el)
  local simple = div_simple_class(el.attr)
  local open
  if simple then
    open = fence .. " " .. simple
  else
    local attr_str = render_attr(el.attr)
    open = attr_str == "" and fence or (fence .. " " .. attr_str)
  end
  return concat{
    literal(open), cr,
    blocks(el.content, blankline), cr,
    literal(fence),
  }
end

-- A Figure with a single Image block (implicit figure): emit as "![cap](src)"
-- so it re-parses as an implicit figure. Otherwise fall back to a fenced div.
local function figure_is_implicit(el)
  local c = el.content or {}
  if #c ~= 1 then return false end
  local b = c[1]
  if b.tag ~= "Plain" and b.tag ~= "Para" then return false end
  local ic = b.content or {}
  if #ic ~= 1 then return false end
  return ic[1].tag == "Image"
end

Blocks.Figure = function(el)
  if figure_is_implicit(el) then
    local img = el.content[1].content[1]
    -- Promote the figure's caption onto the image if the image has none.
    local cap = img.caption
    if (not cap or #cap == 0) and el.caption and el.caption.long then
      local flat = {}
      for _, b in ipairs(el.caption.long) do
        if b.tag == "Plain" or b.tag == "Para" then
          for _, ii in ipairs(b.content or {}) do flat[#flat+1] = ii end
        end
      end
      img = {
        tag = "Image", caption = flat, src = img.src,
        title = img.title, attr = img.attr,
      }
    end
    return Inlines.Image(img)
  end
  -- Fallback: fenced div tagged with .figure + caption-as-paragraph.
  -- Use dynamic fence depth to avoid collisions with nested divs.
  local depth = 1 + max_div_depth(el.content or {})
  local fence = string.rep(":", math.max(depth + 2, 3))
  local attr_str = render_attr(el.attr)
  local header = attr_str == "" and (fence .. " figure") or (fence .. " figure " .. attr_str)
  local parts = { literal(header), cr, blocks(el.content, blankline) }
  if el.caption and el.caption.long and #el.caption.long > 0 then
    parts[#parts+1] = blankline
    parts[#parts+1] = blocks(el.caption.long, blankline)
  end
  parts[#parts+1] = cr
  parts[#parts+1] = literal(fence)
  return concat(parts)
end

-- --- Tables -------------------------------------------------------------

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

local function is_simple_cell(cell)
  local cb = cell_blocks(cell)
  if #cb > 1 then return false end
  if #cb == 1 then
    local tag = cb[1].tag
    if tag ~= "Plain" and tag ~= "Para" then return false end
  end
  if (cell.row_span or 1) > 1 then return false end
  if (cell.col_span or 1) > 1 then return false end
  return true
end

local function is_pipe_table(el)
  local hrows, brows, frows = rows_from_table(el)
  if #frows > 0 then return false end
  if #(el.bodies or {}) > 1 then return false end
  for _, body in ipairs(el.bodies or {}) do
    if #(body.head or {}) > 0 then return false end
  end
  local function check(rows)
    for _, r in ipairs(rows) do
      for _, cell in ipairs(r.cells or {}) do
        if not is_simple_cell(cell) then return false end
      end
    end
    return true
  end
  return check(hrows) and check(brows)
end

local function render_simple_inline_cell(cell)
  local cb = cell_blocks(cell)
  if #cb == 0 then return "" end
  return layout.render(inlines(cb[1].content or {}), 1/0)
end

-- Escape pipes in cell text so they don't break the pipe table.
local function escape_pipe(s)
  return (s:gsub("|", "\\|"))
end

local function render_pipe_table(el)
  local hrows, brows = rows_from_table(el)
  local ncols = 0
  local function cols_of(row) return #(row.cells or {}) end
  if #hrows > 0 then ncols = cols_of(hrows[1])
  elseif #brows > 0 then ncols = cols_of(brows[1]) end
  if ncols == 0 then return layout.empty end

  local aligns = {}
  for i = 1, ncols do
    local spec = (el.colspecs or {})[i]
    aligns[i] = spec and spec[1] or "AlignDefault"
  end

  local function rendered_cell(cell)
    return escape_pipe(render_simple_inline_cell(cell))
  end

  local widths = {}
  for i = 1, ncols do widths[i] = 3 end  -- minimum dash-count

  local function measure(rows)
    for _, r in ipairs(rows) do
      for i, cell in ipairs(r.cells or {}) do
        local s = rendered_cell(cell)
        if #s > widths[i] then widths[i] = #s end
      end
    end
  end
  measure(hrows); measure(brows)

  local function pad_cell(s, i, align)
    local w = widths[i]
    local need = w - #s
    if need <= 0 then return s end
    if align == "AlignCenter" then
      local left = math.floor(need / 2)
      local right = need - left
      return string.rep(" ", left) .. s .. string.rep(" ", right)
    elseif align == "AlignRight" then
      return string.rep(" ", need) .. s
    else
      return s .. string.rep(" ", need)
    end
  end

  local function row_line(r)
    local parts = {}
    for i = 1, ncols do
      local cell = (r.cells or {})[i]
      local s = cell and rendered_cell(cell) or ""
      parts[i] = pad_cell(s, i, aligns[i])
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end

  local function sep_line()
    local parts = {}
    for i = 1, ncols do
      -- Separator spans the cell width plus the two padding spaces, so
      -- visually it lines up with the "| content |" rows above.
      local w = widths[i] + 2
      local a = aligns[i]
      if a == "AlignLeft" then
        parts[i] = ":" .. string.rep("-", w - 1)
      elseif a == "AlignRight" then
        parts[i] = string.rep("-", w - 1) .. ":"
      elseif a == "AlignCenter" then
        parts[i] = ":" .. string.rep("-", w - 2) .. ":"
      else
        parts[i] = string.rep("-", w)
      end
    end
    return "|" .. table.concat(parts, "|") .. "|"
  end

  local out_lines = {}
  if #hrows > 0 then
    for _, r in ipairs(hrows) do out_lines[#out_lines+1] = row_line(r) end
  else
    -- Pipe tables require a header row; synthesize an empty one.
    local empty_cells = {}
    for i = 1, ncols do empty_cells[i] = "" end
    local parts = {}
    for i = 1, ncols do parts[i] = pad_cell("", i, aligns[i]) end
    out_lines[#out_lines+1] = "| " .. table.concat(parts, " | ") .. " |"
  end
  out_lines[#out_lines+1] = sep_line()
  for _, r in ipairs(brows) do out_lines[#out_lines+1] = row_line(r) end

  local parts = {}
  for i, line in ipairs(out_lines) do
    if i > 1 then parts[#parts+1] = cr end
    parts[#parts+1] = literal(line)
  end
  local body = concat(parts)
  if el.caption and el.caption.long and #el.caption.long > 0 then
    return concat{
      body, blankline,
      literal("  : "), blocks(el.caption.long, cr),
    }
  end
  return body
end

-- Simple-table form: 2-space indent, aligned columns, dashes under the
-- header. Used when alignment is default and no cell spans multiple
-- lines. Matches pandoc 3.x's markdown writer output for such tables.
local function render_simple_table(el)
  local hrows, brows = rows_from_table(el)
  local ncols = 0
  if #hrows > 0 then ncols = #(hrows[1].cells or {})
  elseif #brows > 0 then ncols = #(brows[1].cells or {}) end
  if ncols == 0 then return layout.empty end

  local function rendered(cell)
    return render_simple_inline_cell(cell)
  end

  local widths = {}
  for i = 1, ncols do widths[i] = 3 end

  local function measure(rows)
    for _, r in ipairs(rows) do
      for i, cell in ipairs(r.cells or {}) do
        local s = rendered(cell)
        if layout.real_length(s) > widths[i] then
          widths[i] = layout.real_length(s)
        end
      end
    end
  end
  measure(hrows); measure(brows)

  local function format_row(r)
    local parts = { "" }
    for i = 1, ncols do
      local s = (r.cells or {})[i]
      s = s and rendered(s) or ""
      local pad = widths[i] - layout.real_length(s)
      parts[#parts+1] = s .. string.rep(" ", pad)
    end
    return "  " .. table.concat(parts, " "):gsub("^%s", "")
  end

  local dash_parts = { "" }
  for i = 1, ncols do
    dash_parts[#dash_parts+1] = string.rep("-", widths[i])
  end
  local dash_line = "  " .. table.concat(dash_parts, " "):gsub("^%s", "")

  local lines = {}
  if #hrows > 0 then
    for _, r in ipairs(hrows) do lines[#lines+1] = format_row(r) end
    lines[#lines+1] = dash_line
  else
    lines[#lines+1] = dash_line
  end
  for _, r in ipairs(brows) do lines[#lines+1] = format_row(r) end
  if #hrows == 0 then lines[#lines+1] = dash_line end

  -- Trim trailing spaces from each line (pandoc emits no trailing ws).
  for i, ln in ipairs(lines) do lines[i] = ln:gsub("%s+$", "") end

  local parts = {}
  for i, line in ipairs(lines) do
    if i > 1 then parts[#parts+1] = cr end
    parts[#parts+1] = literal(line)
  end
  local body = concat(parts)
  if el.caption and el.caption.long and #el.caption.long > 0 then
    return concat{
      body, blankline,
      literal("  : "), blocks(el.caption.long, cr),
    }
  end
  return body
end

local function is_simple_table(el)
  if not is_pipe_table(el) then return false end
  for _, spec in ipairs(el.colspecs or {}) do
    local align = spec[1] or "AlignDefault"
    if align ~= "AlignDefault" then return false end
  end
  return true
end

local function render_grid_table(el)
  -- Borrowed, with minor tweaks, from plain.lua's grid-table renderer.
  -- Pandoc's -t markdown accepts (and emits) grid tables for complex cells.
  local hrows, brows = rows_from_table(el)
  local ncols
  if #hrows > 0 then ncols = #(hrows[1].cells or {})
  elseif #brows > 0 then ncols = #(brows[1].cells or {})
  else return layout.empty end

  local function cell_lines(cell)
    local doc = blocks(cell_blocks(cell), blankline)
    local s = layout.render(doc, 1/0)
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do out[#out+1] = line end
    if #out > 0 and out[#out] == "" then out[#out] = nil end
    if #out == 0 then out[1] = "" end
    return out
  end

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
      local ls = cell and cell_lines(cell) or { "" }
      cell_box[i] = ls
      if #ls > height then height = #ls end
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
  local body = concat(parts)
  if el.caption and el.caption.long and #el.caption.long > 0 then
    return concat{
      body, blankline,
      literal("  : "), blocks(el.caption.long, cr),
    }
  end
  return body
end

Blocks.Table = function(el)
  if is_simple_table(el) then return render_simple_table(el) end
  if is_pipe_table(el) then return render_pipe_table(el) end
  return render_grid_table(el)
end

-- ---------------------------------------------------------------------------
-- Footnote section
-- ---------------------------------------------------------------------------

local function render_footnotes()
  if #footnotes == 0 then return layout.empty end
  local items = {}
  for i, content in ipairs(footnotes) do
    local marker = "[^" .. i .. "]: "
    items[#items+1] = hang(blocks(content, blankline), 4, literal(marker))
  end
  return concat{ blankline, concat(items, blankline) }
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
  return ctx
end

function Writer(doc, opts)
  footnotes = {}
  used_auto_ids = {}
  local body = blocks(doc.blocks or {}, blankline)
  local notes = render_footnotes()
  local cols = (opts and opts.columns) or 72
  local out = layout.render(concat{ body, notes }, cols)
  if opts and opts.standalone then
    local tpl_src = (opts and opts.template ~= "" and opts.template)
                    or pandoc.template.default(FORMAT or "markdown")
    local compiled = pandoc.template.compile(tpl_src)
    out = pandoc.template.apply(compiled, build_template_context(doc, opts, out))
  end
  return out
end
