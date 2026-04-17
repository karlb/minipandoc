-- minipandoc builtin: writers/latex.lua
-- Pure-Lua LaTeX writer. Output targets pandoc-compatible LaTeX that
-- `pdflatex`/`xelatex` compiles when combined with the bundled
-- default.latex template (which pulls in hyperref, graphicx, ulem).
-- Round-trips through `pandoc -f latex -t native` to an equivalent AST;
-- byte-parity with `pandoc -t latex` is the goal on focused fixtures.

local layout = pandoc.layout
local literal, concat, cr, blankline, nest, hang, chomp =
  layout.literal, layout.concat, layout.cr, layout.blankline,
  layout.nest, layout.hang, layout.chomp
local stringify = pandoc.utils.stringify
local to_roman = pandoc.utils.to_roman_numeral

local Blocks = {}
local Inlines = {}

-- ---------------------------------------------------------------------------
-- Escaping
-- ---------------------------------------------------------------------------

-- Map of single-char → replacement for LaTeX body text. The set matches
-- pandoc's LaTeX writer defaults; the surrounding preamble is assumed to
-- load hyperref (for \url etc.) and inputenc/fontenc for unicode.
local TEXT_ESCAPES = {
  ["\\"] = "\\textbackslash{}",
  ["{"]  = "\\{",
  ["}"]  = "\\}",
  ["$"]  = "\\$",
  ["&"]  = "\\&",
  ["#"]  = "\\#",
  ["%"]  = "\\%",
  ["^"]  = "\\^{}",
  ["_"]  = "\\_",
  ["~"]  = "\\textasciitilde{}",
  ["<"]  = "\\textless{}",
  [">"]  = "\\textgreater{}",
}

-- Unicode → TeX quote/dash conversions (matches pandoc's LaTeX writer).
local UNICODE_REPLACEMENTS = {
  ["\xe2\x80\x9c"] = "``",   -- U+201C LEFT DOUBLE QUOTATION MARK
  ["\xe2\x80\x9d"] = "''",   -- U+201D RIGHT DOUBLE QUOTATION MARK
  ["\xe2\x80\x98"] = "`",    -- U+2018 LEFT SINGLE QUOTATION MARK
  ["\xe2\x80\x99"] = "'",    -- U+2019 RIGHT SINGLE QUOTATION MARK
  ["\xe2\x80\x94"] = "---",  -- U+2014 EM DASH
  ["\xe2\x80\x93"] = "--",   -- U+2013 EN DASH
  ["\xe2\x80\xa6"] = "\\ldots{}", -- U+2026 HORIZONTAL ELLIPSIS
}

local function escape_str(s)
  s = tostring(s or "")
  -- Unicode punctuation → TeX sequences.
  s = s:gsub("\xe2\x80[\x93\x94\x98\x99\x9c\x9d\xa6]", UNICODE_REPLACEMENTS)
  -- Backslash specially: pandoc emits `\textbackslash ` before a letter,
  -- `\textbackslash{}` at end-of-string, `\textbackslash` bare before
  -- non-letters (punctuation, digits).
  s = s:gsub("\\(%a)", "\\textbackslash %1")
  s = s:gsub("\\$", "\\textbackslash{}")
  s = s:gsub("\\(%W)", "\\textbackslash%1")
  -- Tilde similarly: `\textasciitilde ` before letter, `\textasciitilde{}` else.
  s = s:gsub("~(%a)", "\\textasciitilde %1")
  s = s:gsub("~", "\\textasciitilde{}")
  return (s:gsub("[%{%}%$&#%%^_<>]", TEXT_ESCAPES))
end

-- Link targets / image paths: the only chars that genuinely need escaping
-- inside \href{URL}{...} and \includegraphics{PATH} are `#`, `%`, and
-- `\` (the last only if the URL actually contains a literal backslash).
local function escape_url(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\")
  s = s:gsub("#", "\\#")
  s = s:gsub("%%", "\\%%")
  return s
end

-- Title attributes inside \href{}{}[title] and \includegraphics titles
-- need to escape braces and backslashes.
local function escape_title(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\textbackslash{}")
  s = s:gsub("{", "\\{")
  s = s:gsub("}", "\\}")
  return s
end

-- ---------------------------------------------------------------------------
-- Recursive renderers
-- ---------------------------------------------------------------------------

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

Inlines.Str = function(el) return literal(escape_str(el.text)) end
Inlines.Space = function() return layout.space end
Inlines.SoftBreak = function() return layout.space end
Inlines.LineBreak = function() return concat{ literal("\\\\"), cr } end

local function wrap_cmd(cmd)
  return function(el)
    return concat{ literal("\\" .. cmd .. "{"), inlines(el.content),
                   literal("}") }
  end
end

Inlines.Emph        = wrap_cmd("emph")
Inlines.Strong      = wrap_cmd("textbf")
Inlines.Underline   = wrap_cmd("uline")
Inlines.Strikeout   = wrap_cmd("st")
Inlines.Superscript = wrap_cmd("textsuperscript")
Inlines.Subscript   = wrap_cmd("textsubscript")
Inlines.SmallCaps   = wrap_cmd("textsc")

Inlines.Quoted = function(el)
  local o, c
  if el.quotetype == "DoubleQuote" then
    o, c = "``", "''"
  else
    o, c = "`", "'"
  end
  return concat{ literal(o), inlines(el.content), literal(c) }
end

Inlines.Cite = function(el)
  local cites = el.citations or el.cites or {}
  local keys = {}
  for _, c in ipairs(cites) do
    if c.id then keys[#keys+1] = c.id end
  end
  if #keys == 0 then return inlines(el.content) end
  return literal("\\cite{" .. table.concat(keys, ",") .. "}")
end

Inlines.Code = function(el)
  -- In verbatim context, the space-terminated `\textbackslash ` form
  -- clashes with our Code space-escape; use the braced form instead.
  local text = escape_str(el.text or "")
    :gsub("\\textbackslash ", "\\textbackslash{}")
    :gsub("\\textasciitilde ", "\\textasciitilde{}")
    :gsub(" ", "\\ ")
  return literal("\\texttt{" .. text .. "}")
end

Inlines.Math = function(el)
  local text = el.text or ""
  if el.mathtype == "DisplayMath" then
    return literal("\\[" .. text .. "\\]")
  end
  return literal("\\(" .. text .. "\\)")
end

Inlines.RawInline = function(el)
  local fmt = el.format or ""
  if fmt == "latex" or fmt == "tex" then
    return literal(el.text or "")
  end
  return layout.empty
end

Inlines.Link = function(el)
  local target = el.target or ""
  local content = inlines(el.content)
  local attr = el.attr
  local prefix = layout.empty
  if attr and attr.identifier and attr.identifier ~= "" then
    prefix = literal("\\protect\\phantomsection\\label{" .. attr.identifier .. "}")
  end
  -- Internal link (#id) → \hyperlink{id}{text}; external → \href{url}{text}.
  if target:sub(1, 1) == "#" then
    local id = target:sub(2)
    return concat{ prefix,
                   literal("\\protect\\hyperlink{" .. id .. "}{"),
                   content, literal("}") }
  end
  return concat{ prefix,
                 literal("\\href{" .. escape_url(target) .. "}{"),
                 content, literal("}") }
end

local function image_opts(attr)
  if not attr or not attr.attributes then return "" end
  local parts = {}
  for _, pair in ipairs(attr.attributes) do
    local k, v = pair[1], pair[2]
    if k == "width" or k == "height" then
      parts[#parts+1] = k .. "=" .. v
    end
  end
  if #parts == 0 then return "" end
  return "[" .. table.concat(parts, ",") .. "]"
end

Inlines.Image = function(el)
  local src = el.src or ""
  local opts = image_opts(el.attr)
  return literal("\\includegraphics" .. opts .. "{" .. escape_url(src) .. "}")
end

Inlines.Note = function(el)
  -- Render footnote body as a layout doc so the outer \footnote{...}
  -- can wrap inside the braces (matches pandoc's hanging-indent form:
  -- `\footnote{long body...\n  continuation}`). Multi-paragraph bodies
  -- separate with `\par`.
  local parts = {}
  for i, b in ipairs(el.content or {}) do
    if i > 1 then parts[#parts+1] = literal("\\par ") end
    local fn = Blocks[b.tag]
    if fn then parts[#parts+1] = fn(b) end
  end
  return concat{ literal("\\footnote{"), layout.nest(concat(parts), 2), literal("}") }
end

Inlines.Span = function(el)
  local content = inlines(el.content)
  if el.attr and el.attr.identifier and el.attr.identifier ~= "" then
    return concat{
      literal("\\protect\\phantomsection\\label{" .. el.attr.identifier .. "}{"),
      content,
      literal("}"),
    }
  end
  for _, c in ipairs(el.attr and el.attr.classes or {}) do
    if c == "mark" then
      return concat{ literal("\\hl{"), content, literal("}") }
    end
  end
  return concat{ literal("{"), content, literal("}") }
end

-- ---------------------------------------------------------------------------
-- Block writers
-- ---------------------------------------------------------------------------

Blocks.Plain = function(el) return inlines(el.content) end
Blocks.Para = function(el) return inlines(el.content) end

local SECTION_CMDS = {
  [1] = "section", [2] = "subsection", [3] = "subsubsection",
  [4] = "paragraph", [5] = "subparagraph",
}

Blocks.Header = function(el)
  local level = el.level or 1
  local cmd = SECTION_CMDS[level] or "subparagraph"
  local body = concat{ literal("\\" .. cmd .. "{"), inlines(el.content),
                       literal("}") }
  local attr = el.attr
  if attr and attr.identifier and attr.identifier ~= "" then
    return concat{ body, literal("\\label{" .. attr.identifier .. "}") }
  end
  return body
end

Blocks.BlockQuote = function(el)
  return concat{
    literal("\\begin{quote}"), cr,
    blocks(el.content, blankline), cr,
    literal("\\end{quote}"),
  }
end

Blocks.CodeBlock = function(el)
  local text = el.text or ""
  -- verbatim can't contain "\end{verbatim}"; if it does, fall back to
  -- a Verbatim-wrapped form via fancyvrb (not in default preamble) —
  -- in practice this is extremely rare; emit as-is and let compilation
  -- surface the issue.
  return concat{
    literal("\\begin{verbatim}"), cr,
    literal(text), cr,
    literal("\\end{verbatim}"),
  }
end

Blocks.RawBlock = function(el)
  local fmt = el.format or ""
  if fmt == "latex" or fmt == "tex" then
    return literal(el.text or "")
  end
  return layout.empty
end

Blocks.LineBlock = function(el)
  -- Pandoc's \\ joining for simple poetry — one line per Inlines list.
  local parts = {}
  for i, line in ipairs(el.content or {}) do
    if i > 1 then
      parts[#parts+1] = literal("\\\\")
      parts[#parts+1] = cr
    end
    parts[#parts+1] = inlines(line)
  end
  return concat(parts)
end

Blocks.HorizontalRule = function()
  return literal("\\begin{center}\\rule{0.5\\linewidth}{0.5pt}\\end{center}")
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

local function list_items(items)
  local sep = is_tight_list(items) and cr or blankline
  local out = {}
  for _, item in ipairs(items) do
    out[#out+1] = concat{ literal("\\item"), cr, nest(blocks(item, blankline), 2) }
  end
  return concat(out, sep)
end

Blocks.BulletList = function(el)
  return concat{
    literal("\\begin{itemize}"), cr,
    literal("\\tightlist"), cr,  -- overwritten below when loose
    list_items(el.content or {}), cr,
    literal("\\end{itemize}"),
  }
end

-- Override: only emit \tightlist when the list is tight.
Blocks.BulletList = function(el)
  local items = el.content or {}
  local body = list_items(items)
  local parts = { literal("\\begin{itemize}"), cr }
  if is_tight_list(items) then
    parts[#parts+1] = literal("\\tightlist")
    parts[#parts+1] = cr
  end
  parts[#parts+1] = body
  parts[#parts+1] = cr
  parts[#parts+1] = literal("\\end{itemize}")
  return concat(parts)
end

local function enum_label_def(style, delim)
  -- Returns the \def\labelenumi{...} line, or nil when the list uses
  -- default Decimal+Period (pandoc omits the def in that case).
  if style == "DefaultStyle" or style == "Decimal" then
    if delim == "DefaultDelim" or delim == "Period" then
      if style == "DefaultStyle" and delim == "DefaultDelim" then
        return nil
      end
    end
  end
  local fmt
  if style == "LowerRoman" then fmt = "\\roman{enumi}"
  elseif style == "UpperRoman" then fmt = "\\Roman{enumi}"
  elseif style == "LowerAlpha" then fmt = "\\alph{enumi}"
  elseif style == "UpperAlpha" then fmt = "\\Alph{enumi}"
  else fmt = "\\arabic{enumi}" end
  local labeled
  if delim == "OneParen" then labeled = fmt .. ")"
  elseif delim == "TwoParens" then labeled = "(" .. fmt .. ")"
  else labeled = fmt .. "." end
  return "\\def\\labelenumi{" .. labeled .. "}"
end

Blocks.OrderedList = function(el)
  local la = el.listAttributes or {}
  local start = el.start or la.start or 1
  local style = el.style or la.style or "DefaultStyle"
  local delim = el.delimiter or la.delimiter or "DefaultDelim"
  local items = el.content or {}
  local parts = { literal("\\begin{enumerate}"), cr }
  local label_def = enum_label_def(style, delim)
  if label_def then
    parts[#parts+1] = literal(label_def)
    parts[#parts+1] = cr
  end
  if start and start > 1 then
    parts[#parts+1] = literal("\\setcounter{enumi}{" .. tostring(start - 1) .. "}")
    parts[#parts+1] = cr
  end
  if is_tight_list(items) then
    parts[#parts+1] = literal("\\tightlist")
    parts[#parts+1] = cr
  end
  parts[#parts+1] = list_items(items)
  parts[#parts+1] = cr
  parts[#parts+1] = literal("\\end{enumerate}")
  return concat(parts)
end

Blocks.DefinitionList = function(el)
  local items = el.content or {}
  -- Tight list: every definition is a single Plain block (no Paras).
  local tight = true
  for _, item in ipairs(items) do
    for _, d in ipairs(item[2] or {}) do
      for _, blk in ipairs(d) do
        if blk.tag ~= "Plain" then tight = false; break end
      end
      if not tight then break end
    end
    if not tight then break end
  end

  local parts = { literal("\\begin{description}"), cr }
  if tight then parts[#parts+1] = concat{ literal("\\tightlist"), cr } end
  local item_docs = {}
  for _, item in ipairs(items) do
    local term, defs = item[1], item[2]
    local def_bodies = {}
    for _, d in ipairs(defs or {}) do
      def_bodies[#def_bodies+1] = blocks(d, blankline)
    end
    item_docs[#item_docs+1] = concat{
      literal("\\item["), inlines(term), literal("]"), cr,
      concat(def_bodies, blankline),
    }
  end
  parts[#parts+1] = concat(item_docs, cr)
  parts[#parts+1] = cr
  parts[#parts+1] = literal("\\end{description}")
  return concat(parts)
end

local function has_class(attr, name)
  if not attr or not attr.classes then return false end
  for _, c in ipairs(attr.classes) do
    if c == name then return true end
  end
  return false
end

Blocks.Div = function(el)
  local content_blocks = el.content or {}
  local attr = el.attr
  local id = attr and attr.identifier and attr.identifier ~= "" and attr.identifier

  if has_class(attr, "section") and id then
    -- Section Div: hoist the Div's ID as \label onto the first child Header
    -- (if it lacks its own ID), then render children directly.
    if #content_blocks > 0 and content_blocks[1].tag == "Header" then
      local hdr = content_blocks[1]
      local hdr_attr = hdr.attr
      if not hdr_attr or not hdr_attr.identifier or hdr_attr.identifier == "" then
        -- Hoist the div's ID to the header by creating a modified copy
        local modified_hdr = {
          tag = "Header",
          level = hdr.level,
          content = hdr.content,
          attr = { identifier = id, classes = hdr_attr and hdr_attr.classes or {},
                   attributes = hdr_attr and hdr_attr.attributes or {} },
        }
        local parts = { Blocks.Header(modified_hdr) }
        for i = 2, #content_blocks do
          local fn = Blocks[content_blocks[i].tag]
          if fn then parts[#parts+1] = fn(content_blocks[i]) end
        end
        return concat(parts, blankline)
      end
    end
    -- Section div but header already has an ID: render children directly.
    return blocks(content_blocks, blankline)
  end

  -- Non-section Div with ID: emit \protect\phantomsection\label{id} before content.
  if id then
    return concat{
      literal("\\protect\\phantomsection\\label{" .. id .. "}"), cr,
      blocks(content_blocks, blankline),
    }
  end

  return blocks(content_blocks, blankline)
end

-- --- Figures ------------------------------------------------------------

local function figure_single_image(el)
  local c = el.content or {}
  if #c ~= 1 then return nil end
  local b = c[1]
  if b.tag ~= "Plain" and b.tag ~= "Para" then return nil end
  local ic = b.content or {}
  if #ic ~= 1 then return nil end
  if ic[1].tag ~= "Image" then return nil end
  return ic[1]
end

Blocks.Figure = function(el)
  local img = figure_single_image(el)
  local caption = el.caption and el.caption.long or {}
  local has_caption = caption and #caption > 0
  if img and not has_caption then
    return Inlines.Image(img)
  end
  -- Wrap in a figure environment.
  local parts = {
    literal("\\begin{figure}"), cr,
    literal("\\centering"), cr,
  }
  if img then
    parts[#parts+1] = Inlines.Image(img)
    parts[#parts+1] = cr
  else
    parts[#parts+1] = blocks(el.content, blankline)
    parts[#parts+1] = cr
  end
  if has_caption then
    parts[#parts+1] = literal("\\caption{")
    parts[#parts+1] = inlines(el.caption.long[1].content or {})
    -- If caption.long has more than one block (rare), flatten to the
    -- first block's content — a pragmatic simplification for v1.
    parts[#parts+1] = literal("}")
    parts[#parts+1] = cr
  end
  local attr = el.attr
  if attr and attr.identifier and attr.identifier ~= "" then
    parts[#parts+1] = literal("\\label{" .. attr.identifier .. "}")
    parts[#parts+1] = cr
  end
  parts[#parts+1] = literal("\\end{figure}")
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

local function is_simple_table(el)
  if #(el.bodies or {}) > 1 then return false end
  if #((el.foot or {}).rows or {}) > 0 then return false end
  for _, body in ipairs(el.bodies or {}) do
    if #(body.head or {}) > 0 then return false end
  end
  local hrows, brows = rows_from_table(el)
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

local ALIGN_SPEC = {
  AlignLeft    = "l",
  AlignRight   = "r",
  AlignCenter  = "c",
  AlignDefault = "l",
}

local function render_simple_cell(cell)
  local cb = cell_blocks(cell)
  if #cb == 0 then return literal("") end
  return inlines(cb[1].content or {})
end

local function render_longtable(el)
  local hrows, brows = rows_from_table(el)
  local ncols = 0
  if #hrows > 0 then ncols = #(hrows[1].cells or {})
  elseif #brows > 0 then ncols = #(brows[1].cells or {}) end
  if ncols == 0 then return layout.empty end

  local col_specs = {}
  for i = 1, ncols do
    local spec = (el.colspecs or {})[i]
    local align = spec and spec[1] or "AlignDefault"
    col_specs[i] = ALIGN_SPEC[align] or "l"
  end
  local col_spec_str = "@{}" .. table.concat(col_specs) .. "@{}"

  local function row_doc(row)
    local cells = {}
    for i, cell in ipairs(row.cells or {}) do
      cells[i] = render_simple_cell(cell)
    end
    local parts = {}
    for i, c in ipairs(cells) do
      if i > 1 then parts[#parts+1] = literal(" & ") end
      parts[#parts+1] = c
    end
    parts[#parts+1] = literal(" \\\\")
    return layout.nowrap(concat(parts))
  end

  local parts = {
    literal("\\begin{longtable}[]{" .. col_spec_str .. "}"),
    cr,
  }

  if el.caption and el.caption.long and #el.caption.long > 0 then
    parts[#parts+1] = literal("\\caption{")
    parts[#parts+1] = inlines(el.caption.long[1].content or {})
    parts[#parts+1] = literal("}\\tabularnewline")
    parts[#parts+1] = cr
  end

  -- When there's a caption, pandoc emits the head block twice: once
  -- closed by \endfirsthead (first page) and once by \endhead
  -- (continuation pages). Without a caption, only the \endhead form.
  local has_caption = el.caption and el.caption.long
                      and #el.caption.long > 0
  local function emit_head_block()
    if #hrows > 0 then
      parts[#parts+1] = literal("\\toprule\\noalign{}")
      parts[#parts+1] = cr
      for _, r in ipairs(hrows) do
        parts[#parts+1] = row_doc(r)
        parts[#parts+1] = cr
      end
      parts[#parts+1] = literal("\\midrule\\noalign{}")
      parts[#parts+1] = cr
    else
      parts[#parts+1] = literal("\\toprule\\noalign{}")
      parts[#parts+1] = cr
    end
  end
  if has_caption then
    emit_head_block()
    parts[#parts+1] = literal("\\endfirsthead")
    parts[#parts+1] = cr
  end
  emit_head_block()
  parts[#parts+1] = literal("\\endhead")
  parts[#parts+1] = cr
  parts[#parts+1] = literal("\\bottomrule\\noalign{}")
  parts[#parts+1] = cr
  parts[#parts+1] = literal("\\endlastfoot")
  parts[#parts+1] = cr

  for _, r in ipairs(brows) do
    parts[#parts+1] = row_doc(r)
    parts[#parts+1] = cr
  end

  parts[#parts+1] = literal("\\end{longtable}")
  return concat(parts)
end

local function render_table_fallback(el)
  -- Complex tables: render via the plain writer and wrap in verbatim.
  local plain = pandoc.write(pandoc.Pandoc({ el }), "plain")
  return concat{
    literal("\\begin{verbatim}"), cr,
    literal(plain:gsub("\n+$", "")), cr,
    literal("\\end{verbatim}"),
  }
end

Blocks.Table = function(el)
  if is_simple_table(el) then
    return render_longtable(el)
  end
  return render_table_fallback(el)
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
  -- Template defaults: pandoc assumes `documentclass = "article"` unless
  -- the user overrides via `-V documentclass=…` or metadata.
  if ctx.documentclass == nil then ctx.documentclass = "article" end
  return ctx
end

function Writer(doc, opts)
  PANDOC_WRITER_OPTIONS = opts or {}
  local body = blocks(doc.blocks or {}, blankline)
  local cols = (opts and opts.columns) or 72
  local out = layout.render(body, cols)
  if opts and opts.standalone then
    local tpl_src = (opts and opts.template ~= "" and opts.template)
                    or pandoc.template.default(FORMAT or "latex")
    local compiled = pandoc.template.compile(tpl_src)
    out = pandoc.template.apply(compiled, build_template_context(doc, opts, out))
  end
  return out
end
