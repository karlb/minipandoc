-- pandoc.layout — pure-Lua implementation of pandoc's Doc layout module.
-- Based on the public API documented at pandoc.org/lua-filters.html.
--
-- Model: a "doc" is a table with a `kind` discriminator. Leaf kinds are
-- literal text, space (breakable), cr (line break), blankline. Composite
-- kinds wrap a child doc with layout decorations (nest/hang/prefixed/etc).
--
-- Rendering walks the tree, flattening to a token stream, then emits a
-- string while tracking column position and indent stack, wrapping at
-- `cols` when a space would overflow.

local layout = {}

local function is_doc(x)
  return type(x) == "table" and x.kind ~= nil
end

local function mk(kind, fields)
  local t = { kind = kind }
  for k, v in pairs(fields or {}) do t[k] = v end
  return t
end

local function lift(x)
  if x == nil then return mk("empty") end
  if type(x) == "string" then
    if x == "" then return mk("empty") end
    return mk("lit", { text = x })
  end
  if type(x) == "number" or type(x) == "boolean" then
    return mk("lit", { text = tostring(x) })
  end
  if is_doc(x) then return x end
  if type(x) == "table" then
    -- list -> concat
    local parts = {}
    for _, v in ipairs(x) do parts[#parts+1] = lift(v) end
    return mk("concat", { parts = parts })
  end
  return mk("empty")
end

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

layout.empty = mk("empty")
layout.space = mk("space")
layout.cr = mk("cr")
layout.blankline = mk("blankline")

function layout.literal(s) return mk("lit", { text = s or "" }) end

function layout.concat(docs, sep)
  local parts = {}
  if is_doc(docs) then parts[1] = docs
  elseif type(docs) == "table" then
    for i, v in ipairs(docs) do
      if sep and i > 1 then parts[#parts+1] = lift(sep) end
      parts[#parts+1] = lift(v)
    end
  else
    parts[1] = lift(docs)
  end
  return mk("concat", { parts = parts })
end

function layout.nest(doc, n)
  return mk("nest", { child = lift(doc), amount = n or 0 })
end

function layout.hang(doc, n, prefix)
  -- pandoc's `hang` prepends prefix and indents subsequent lines by n.
  return mk("hang", { child = lift(doc), amount = n or 0, prefix = lift(prefix) })
end

function layout.prefixed(doc, prefix)
  return mk("prefixed", { child = lift(doc), prefix = prefix or "" })
end

function layout.nowrap(doc)
  return mk("nowrap", { child = lift(doc) })
end

function layout.chomp(doc)
  return mk("chomp", { child = lift(doc) })
end

function layout.cblock(doc, width)
  return mk("block", { child = lift(doc), width = width or 0, align = "center" })
end

function layout.rblock(doc, width)
  return mk("block", { child = lift(doc), width = width or 0, align = "right" })
end

function layout.lblock(doc, width)
  return mk("block", { child = lift(doc), width = width or 0, align = "left" })
end

function layout.double_quotes(doc) return layout.concat({ "\"", doc, "\"" }) end
function layout.parens(doc)        return layout.concat({ "(",  doc, ")" })   end
function layout.brackets(doc)      return layout.concat({ "[",  doc, "]" })   end
function layout.braces(doc)        return layout.concat({ "{",  doc, "}" })   end

-- ---------------------------------------------------------------------------
-- Offset / height — rough measurements of a rendered doc
-- ---------------------------------------------------------------------------

local function render_plain(doc)
  -- Render without line-wrapping and with maximal line width.
  return layout.render(doc, 1 / 0)
end

function layout.offset(doc)
  local s = render_plain(doc)
  local w = 0
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if #line > w then w = #line end
  end
  return w
end

function layout.height(doc)
  local s = render_plain(doc)
  local _, count = s:gsub("\n", "\n")
  if #s > 0 and s:sub(-1) ~= "\n" then count = count + 1 end
  return count
end

function layout.min_offset(doc)
  local s = render_plain(doc)
  local w
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if #line > 0 and (w == nil or #line < w) then w = #line end
  end
  return w or 0
end

function layout.real_length(s)
  return #tostring(s or "")
end

-- ---------------------------------------------------------------------------
-- Flatten to token stream
--
-- Tokens:
--   {t="txt", s=string}
--   {t="sp"}              soft break (renders as space or newline)
--   {t="cr"}              forced newline
--   {t="bl"}              blank line marker
--   {t="push_indent", amount=n}
--   {t="pop_indent"}
--   {t="push_prefix", text=p}
--   {t="pop_prefix"}
--   {t="push_nowrap"} / {t="pop_nowrap"}
--   {t="push_hang_first", amount=n}  -- first line suppresses indent
--   {t="pop_hang_first"}
--   {t="block", child=doc, width=w, align=str}  (rendered atomically)
--   {t="chomp_on"} / {t="chomp_off"}
-- ---------------------------------------------------------------------------

local function flatten(doc, out)
  local k = doc.kind
  if k == "empty" then
    -- nothing
  elseif k == "lit" then
    -- Split on embedded newlines so cr tokens are emitted for them.
    local text = doc.text
    if text == "" then return end
    local first = true
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if not first then out[#out+1] = { t = "cr" } end
      if #line > 0 then out[#out+1] = { t = "txt", s = line } end
      first = false
    end
    -- Drop the extra empty line at end (we artificially added a \n above).
  elseif k == "space" then
    out[#out+1] = { t = "sp" }
  elseif k == "cr" then
    out[#out+1] = { t = "cr" }
  elseif k == "blankline" then
    out[#out+1] = { t = "bl" }
  elseif k == "concat" then
    for _, child in ipairs(doc.parts or {}) do flatten(child, out) end
  elseif k == "nest" then
    out[#out+1] = { t = "push_indent", amount = doc.amount }
    flatten(doc.child, out)
    out[#out+1] = { t = "pop_indent" }
  elseif k == "hang" then
    -- pandoc's hang: first line uses prefix (no indent), following lines
    -- indented by `amount`. The prefix is prepended to the first line.
    flatten(doc.prefix, out)
    out[#out+1] = { t = "push_indent", amount = doc.amount }
    flatten(doc.child, out)
    out[#out+1] = { t = "pop_indent" }
  elseif k == "prefixed" then
    out[#out+1] = { t = "push_prefix", text = doc.prefix }
    flatten(doc.child, out)
    out[#out+1] = { t = "pop_prefix" }
  elseif k == "nowrap" then
    out[#out+1] = { t = "push_nowrap" }
    flatten(doc.child, out)
    out[#out+1] = { t = "pop_nowrap" }
  elseif k == "chomp" then
    flatten(doc.child, out)
    out[#out+1] = { t = "chomp" }
  elseif k == "block" then
    out[#out+1] = { t = "block", child = doc.child, width = doc.width, align = doc.align }
  end
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

local function render_block_atomic(child, width, align)
  local inner = render_plain(child)
  local lines = {}
  for line in (inner .. "\n"):gmatch("(.-)\n") do lines[#lines+1] = line end
  if #lines == 0 then lines[1] = "" end
  for i, line in ipairs(lines) do
    local pad = width - #line
    if pad < 0 then pad = 0 end
    if align == "right" then lines[i] = string.rep(" ", pad) .. line
    elseif align == "center" then
      local lp = math.floor(pad / 2)
      -- Don't emit trailing padding; pandoc's layout trims right whitespace.
      lines[i] = string.rep(" ", lp) .. line
    else
      lines[i] = line
    end
  end
  return lines
end

function layout.render(doc, cols)
  if doc == nil then return "" end
  doc = lift(doc)
  cols = cols or math.huge
  local tokens = {}
  flatten(doc, tokens)

  -- Output strategy: maintain a flat list of lines. `cur` is the current
  -- (in-progress) line; once we break we push it to `lines`. `blanks_pending`
  -- counts blank lines to be emitted before the next content line.
  local lines = {}
  local cur = ""
  local line_col = 0
  local indent_stack = { 0 }
  local prefix_stack = {}
  local nowrap_depth = 0
  local blanks_pending = 0   -- count of blank lines queued before next content
  local line_started = false -- has the current line had its indent/prefix emitted?

  local function current_indent()
    local s = 0
    for _, v in ipairs(indent_stack) do s = s + v end
    return s
  end
  local function current_prefix()
    local s = ""
    for _, p in ipairs(prefix_stack) do s = s .. p end
    return s
  end

  local function push_line()
    lines[#lines+1] = cur
    cur = ""
    line_col = 0
    line_started = false
  end

  -- Emit queued blank lines. Call before writing content.
  local function emit_blanks()
    while blanks_pending > 0 do
      -- An empty line (no content, no prefix applied).
      lines[#lines+1] = ""
      blanks_pending = blanks_pending - 1
    end
  end

  local function start_line()
    if not line_started then
      emit_blanks()
      local p = current_prefix()
      local ind = current_indent()
      local s = p .. string.rep(" ", ind)
      if #s > 0 then
        cur = s
        line_col = #s
      end
      line_started = true
    end
  end

  local function force_newline()
    if line_started or #cur > 0 then
      push_line()
    elseif blanks_pending > 0 then
      emit_blanks()
    end
  end

  local function append_text(text)
    if text == "" then return end
    start_line()
    cur = cur .. text
    line_col = line_col + #text
  end

  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local t = tok.t
    if t == "txt" then
      append_text(tok.s)
    elseif t == "sp" then
      if nowrap_depth > 0 then
        append_text(" ")
      else
        -- Look ahead to find next word width.
        local next_w = 0
        local j = i + 1
        while j <= #tokens do
          local nt = tokens[j]
          if nt.t == "txt" then
            next_w = next_w + #nt.s; j = j + 1
          else
            break
          end
        end
        if line_col > 0 and (line_col + 1 + next_w) > cols then
          push_line()
        elseif line_col > 0 then
          append_text(" ")
        end
      end
    elseif t == "cr" then
      -- Conditional newline: only break if there's content on the line.
      -- Strip trailing space (breakable space before cr is absorbed).
      if line_started or #cur > 0 then
        cur = cur:gsub(" +$", "")
        push_line()
      end
    elseif t == "bl" then
      -- Blank line: if we have content on current line, push it first.
      -- Then queue a single blank (collapse consecutive blanklines).
      if line_started or #cur > 0 then
        cur = cur:gsub(" +$", "")
        push_line()
      end
      if blanks_pending < 1 then blanks_pending = 1 end
    elseif t == "push_indent" then
      indent_stack[#indent_stack+1] = tok.amount
    elseif t == "pop_indent" then
      indent_stack[#indent_stack] = nil
    elseif t == "push_prefix" then
      prefix_stack[#prefix_stack+1] = tok.text
    elseif t == "pop_prefix" then
      prefix_stack[#prefix_stack] = nil
    elseif t == "push_nowrap" then nowrap_depth = nowrap_depth + 1
    elseif t == "pop_nowrap" then nowrap_depth = nowrap_depth - 1
    elseif t == "block" then
      local blines = render_block_atomic(tok.child, tok.width, tok.align)
      for k, line in ipairs(blines) do
        if k > 1 then push_line() end
        append_text(line)
      end
    elseif t == "chomp" then
      -- Strip trailing whitespace on current line and drop any pending blanks.
      cur = cur:match("^(.-)%s*$") or cur
      line_col = #cur
      blanks_pending = 0
      -- Also strip trailing blank lines from lines[]
      while #lines > 0 and lines[#lines]:match("^%s*$") do
        lines[#lines] = nil
      end
    end
    i = i + 1
  end
  if line_started or #cur > 0 then push_line() end
  -- Strip a single trailing blank line if it came from a final blankline token.
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
  return table.concat(lines, "\n")
end

return layout
