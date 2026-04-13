-- minipandoc: pandoc.template — pure-Lua doctemplates.
-- Subset of the pandoc template language sufficient for the bundled
-- default.* templates and most user templates:
--
--   $variable$               -- interpolate; missing renders ""
--   $variable.subfield$      -- nested field access
--   $if(path)$ ... $endif$   -- conditional; supports $else$
--   $for(path)$ ... $endfor$ -- loop; $sep$ between iterations; $it$
--   $$                       -- literal '$'
--
-- Whitespace rule (pandoc-compatible): when a directive ($if, $else,
-- $endif, $for, $sep, $endfor) is the only non-whitespace on its line,
-- swallow the preceding leading whitespace and the trailing newline so
-- the directive doesn't introduce a blank line.

local template = {}

local stringify = pandoc.utils.stringify

-- ---------------------------------------------------------------------------
-- Lexer / parser
-- ---------------------------------------------------------------------------

local function is_ident_char(c)
  return c:match("[%w%-_.]") ~= nil
end

local function read_path(src, i)
  -- Reads identifier (with optional dotted parts) starting at i.
  -- Returns {path = {"a","b",...}, next_i}.
  local start = i
  while i <= #src and is_ident_char(src:sub(i, i)) do i = i + 1 end
  if i == start then return nil end
  local raw = src:sub(start, i - 1)
  local parts = {}
  for p in raw:gmatch("[^.]+") do parts[#parts+1] = p end
  return parts, i
end

-- Find the next directive boundary `$...$` starting at `i`. Returns
-- the directive kind, payload, and indices for slicing.
local function next_directive(src, i)
  while true do
    local s = src:find("$", i, true)
    if not s then return nil end
    local nxt = src:sub(s + 1, s + 1)
    if nxt == "$" then
      -- escape: $$ -> literal $
      return { kind = "lit", text = "$", lit_start = s, lit_end = s + 1 }
    elseif nxt == "" then
      -- Stray $ at EOF; treat as literal.
      return { kind = "lit", text = "$", lit_start = s, lit_end = s }
    else
      -- A directive of some kind.
      local after = s + 1
      -- Keyword? if(...), else, endif, for(...), sep, endfor, partial
      local kw = src:sub(after):match("^(if)%(")
      if kw then
        local p_start = after + #kw + 1
        local close = src:find("%)%$", p_start, false)
        if not close then error("template: unterminated $if(") end
        local path_str = src:sub(p_start, close - 1)
        local parts = {}
        for p in path_str:gmatch("[^.]+") do parts[#parts+1] = p end
        return { kind = "if", path = parts,
                 dir_start = s, dir_end = close + 1 }
      end
      kw = src:sub(after):match("^(for)%(")
      if kw then
        local p_start = after + #kw + 1
        local close = src:find("%)%$", p_start, false)
        if not close then error("template: unterminated $for(") end
        local path_str = src:sub(p_start, close - 1)
        local parts = {}
        for p in path_str:gmatch("[^.]+") do parts[#parts+1] = p end
        return { kind = "for", path = parts,
                 dir_start = s, dir_end = close + 1 }
      end
      for _, w in ipairs({ "else", "endif", "endfor", "sep" }) do
        if src:sub(after, after + #w - 1) == w
           and src:sub(after + #w, after + #w) == "$" then
          return { kind = w, dir_start = s, dir_end = after + #w }
        end
      end
      -- Otherwise: variable interpolation $path$
      local parts, p_end = read_path(src, after)
      if not parts or src:sub(p_end, p_end) ~= "$" then
        -- Unknown directive — treat the leading $ as literal text.
        return { kind = "lit", text = "$",
                 lit_start = s, lit_end = s }
      end
      return { kind = "var", path = parts,
               dir_start = s, dir_end = p_end }
    end
  end
end

-- Apply pandoc's whitespace rule: if a directive (kind in {if/else/endif/
-- for/sep/endfor}) sits alone on its line (only whitespace before it on
-- the line, then optional whitespace and \n after), trim that leading
-- whitespace from the preceding literal AND swallow the trailing
-- newline so the directive doesn't introduce a blank line.
local function is_block_kind(k)
  return k == "if" or k == "else" or k == "endif"
      or k == "for" or k == "endfor" or k == "sep"
end

-- Pre-process source: when a block directive ($if(...)$, $else$, $endif$,
-- $for(...)$, $sep$, $endfor$) is the only non-whitespace content on its
-- line, strip the line's leading whitespace and trailing \n. Pandoc's
-- doctemplates does the same so a block directive on its own line
-- doesn't introduce a blank line in the output.
local function strip_alone_directive_lines(src)
  local out = {}
  local i = 1
  while i <= #src do
    local nl = src:find("\n", i, true)
    local line, nl_part
    if nl then
      line = src:sub(i, nl - 1)
      nl_part = "\n"
      i = nl + 1
    else
      line = src:sub(i)
      nl_part = ""
      i = #src + 1
    end
    -- Does the line consist of optional whitespace + a single block
    -- directive + optional whitespace?
    local lead, dir, trail =
      line:match("^([ \t]*)(%$%S.-%S?%$)([ \t]*)$")
    if not dir then
      lead, dir, trail = line:match("^([ \t]*)(%$%S?%$)([ \t]*)$")
    end
    local is_block = false
    if dir then
      is_block = dir:match("^%$if%(.-%)%$$") ~= nil
              or dir:match("^%$for%(.-%)%$$") ~= nil
              or dir == "$else$" or dir == "$endif$"
              or dir == "$endfor$" or dir == "$sep$"
    end
    if is_block then
      out[#out+1] = dir  -- swallow leading ws and trailing \n
    else
      out[#out+1] = line
      out[#out+1] = nl_part
    end
  end
  return table.concat(out)
end

local function parse(src)
  src = strip_alone_directive_lines(src)
  -- Token list of {kind, ...}; later folded into an AST.
  local tokens = {}
  local i = 1
  while i <= #src do
    local d = next_directive(src, i)
    if not d then
      tokens[#tokens+1] = { kind = "lit", text = src:sub(i) }
      break
    end
    if d.kind == "lit" then
      if d.lit_start > i then
        tokens[#tokens+1] = { kind = "lit", text = src:sub(i, d.lit_start - 1) }
      end
      tokens[#tokens+1] = { kind = "lit", text = d.text }
      i = d.lit_end + 1
    else
      if d.dir_start > i then
        tokens[#tokens+1] = { kind = "lit", text = src:sub(i, d.dir_start - 1) }
      end
      tokens[#tokens+1] = d
      i = d.dir_end + 1
    end
  end

  -- Fold into a tree.
  local pos = 1
  local function parse_seq(stop_set)
    local items = {}
    while pos <= #tokens do
      local tok = tokens[pos]
      if stop_set and stop_set[tok.kind] then return items end
      pos = pos + 1
      if tok.kind == "lit" then
        if tok.text ~= "" then items[#items+1] = tok end
      elseif tok.kind == "var" then
        items[#items+1] = tok
      elseif tok.kind == "if" then
        local then_items = parse_seq({ ["else"] = true, endif = true })
        local else_items = nil
        if tokens[pos] and tokens[pos].kind == "else" then
          pos = pos + 1
          else_items = parse_seq({ endif = true })
        end
        if not (tokens[pos] and tokens[pos].kind == "endif") then
          error("template: missing $endif$")
        end
        pos = pos + 1
        items[#items+1] = { kind = "if", path = tok.path,
                            then_branch = then_items,
                            else_branch = else_items }
      elseif tok.kind == "for" then
        local body = parse_seq({ sep = true, endfor = true })
        local sep = nil
        if tokens[pos] and tokens[pos].kind == "sep" then
          pos = pos + 1
          sep = parse_seq({ endfor = true })
        end
        if not (tokens[pos] and tokens[pos].kind == "endfor") then
          error("template: missing $endfor$")
        end
        pos = pos + 1
        items[#items+1] = { kind = "for", path = tok.path,
                            body = body, sep = sep }
      else
        error("template: unexpected directive '" .. tok.kind .. "'")
      end
    end
    return items
  end
  return { kind = "seq", items = parse_seq(nil) }
end

-- ---------------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------------

local function lookup(ctx, path)
  local cur = ctx
  for _, p in ipairs(path) do
    if type(cur) ~= "table" then return nil end
    cur = cur[p]
  end
  return cur
end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n > 0 and #t == n
end

local function truthy(v)
  if v == nil or v == false then return false end
  if v == "" then return false end
  if type(v) == "table" then
    if next(v) == nil then return false end
    if is_array(v) and #v == 0 then return false end
  end
  return true
end

local function render_value(v)
  if v == nil then return "" end
  if type(v) == "string" then return v end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  if type(v) == "table" then
    if is_array(v) then
      local parts = {}
      for _, item in ipairs(v) do parts[#parts+1] = render_value(item) end
      return table.concat(parts)
    end
    -- Pandoc Inline/Block table -> stringify
    return stringify(v)
  end
  return ""
end

local function render(node, ctx)
  if node.kind == "seq" then
    local out = {}
    for _, child in ipairs(node.items) do
      out[#out+1] = render(child, ctx)
    end
    return table.concat(out)
  elseif node.kind == "lit" then
    return node.text
  elseif node.kind == "var" then
    -- Inside $for(x)$, $it$ is the current iteration value.
    if #node.path == 1 and node.path[1] == "it" and ctx.__it ~= nil then
      return render_value(ctx.__it)
    end
    return render_value(lookup(ctx, node.path))
  elseif node.kind == "if" then
    local v = lookup(ctx, node.path)
    if truthy(v) then
      return render({ kind = "seq", items = node.then_branch }, ctx)
    elseif node.else_branch then
      return render({ kind = "seq", items = node.else_branch }, ctx)
    end
    return ""
  elseif node.kind == "for" then
    local v = lookup(ctx, node.path)
    if not truthy(v) then return "" end
    local items
    if is_array(v) then items = v else items = { v } end
    local out = {}
    for i, item in ipairs(items) do
      if i > 1 and node.sep then
        out[#out+1] = render({ kind = "seq", items = node.sep }, ctx)
      end
      -- Build a sub-context: $it$ is the current item, and the loop
      -- variable name itself also binds to the current item so
      -- `$for(author)$$author$$endfor$` works.
      local sub = setmetatable({}, { __index = ctx })
      sub.__it = item
      sub[node.path[#node.path]] = item
      out[#out+1] = render({ kind = "seq", items = node.body }, sub)
    end
    return table.concat(out)
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function template.compile(source)
  return parse(source or "")
end

function template.apply(compiled, ctx)
  return render(compiled, ctx or {})
end

function template.default(format)
  -- _load_builtin is injected by the Rust host (src/lua/mod.rs).
  -- It searches data dirs under templates/<name> and falls back to the
  -- bundled default.<format>.
  local name = "default." .. tostring(format)
  if template._load_builtin then
    local s = template._load_builtin(name)
    if s then return s end
  end
  error("template: no default template for format '" .. tostring(format) .. "'")
end

-- Normalise a pandoc Meta into a template context. Inlines/Blocks leaves
-- become strings; lists and maps recurse.
function template.meta_to_context(meta)
  local function conv(v)
    if v == nil then return nil end
    if type(v) ~= "table" then return v end
    if v.tag then
      -- A single Inline/Block element
      return stringify(v)
    end
    -- Inlines list (no .tag, all integer keys, items have .tag)
    if is_array(v) then
      -- Heuristic: if every element is an Inline-tagged element, stringify.
      local all_inline = true
      for _, e in ipairs(v) do
        if type(e) ~= "table" or e.tag == nil then all_inline = false; break end
      end
      if all_inline and #v > 0 then return stringify(v) end
      local out = {}
      for i, e in ipairs(v) do out[i] = conv(e) end
      return out
    end
    -- Map / nested meta
    local out = {}
    for k, e in pairs(v) do out[k] = conv(e) end
    return out
  end
  local out = {}
  for k, v in pairs(meta or {}) do out[k] = conv(v) end
  return out
end

return template
