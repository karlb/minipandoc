-- minipandoc builtin: readers/html.lua
-- Pure-Lua HTML reader. Targets the HTML subset our writer emits plus the
-- HTML that pandoc's own -t html writer produces on our fixtures. Not a
-- full HTML5 spec implementation: unknown tags fall back to RawInline /
-- RawBlock (format "html"), and HTML5 parser quirks (implicit closing,
-- foster parenting, formatting-element re-opening) are not modeled.

-- ---------------------------------------------------------------------------
-- Entity decoding
-- ---------------------------------------------------------------------------

local uchar = (utf8 and utf8.char) or function(cp)
  -- Lua 5.1 / 5.2 fallback (mlua ships 5.4, but be defensive).
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40),
                       0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000),
                       0x80 + math.floor(cp / 0x40) % 0x40,
                       0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000),
                     0x80 + math.floor(cp / 0x1000) % 0x40,
                     0x80 + math.floor(cp / 0x40) % 0x40,
                     0x80 + cp % 0x40)
end

local ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
  nbsp = uchar(160), copy = uchar(169), reg = uchar(174), trade = uchar(8482),
  hellip = uchar(8230), mdash = uchar(8212), ndash = uchar(8211),
  lsquo = uchar(8216), rsquo = uchar(8217),
  ldquo = uchar(8220), rdquo = uchar(8221),
  laquo = uchar(171), raquo = uchar(187),
  middot = uchar(183), bull = uchar(8226),
  larr = uchar(8592), rarr = uchar(8594),
  uarr = uchar(8593), darr = uchar(8595), harr = uchar(8596),
  times = uchar(215), divide = uchar(247),
  deg = uchar(176), plusmn = uchar(177),
  frac12 = uchar(189), frac14 = uchar(188), frac34 = uchar(190),
  sect = uchar(167), para = uchar(182),
  iexcl = uchar(161), iquest = uchar(191),
  cent = uchar(162), pound = uchar(163), euro = uchar(8364),
  yen = uchar(165), brvbar = uchar(166), uml = uchar(168),
  ordf = uchar(170), shy = uchar(173), macr = uchar(175),
  sup1 = uchar(185), sup2 = uchar(178), sup3 = uchar(179),
  acute = uchar(180), micro = uchar(181), cedil = uchar(184),
  ordm = uchar(186),
  sbquo = uchar(8218), bdquo = uchar(8222),
  dagger = uchar(8224), Dagger = uchar(8225),
  permil = uchar(8240), lsaquo = uchar(8249), rsaquo = uchar(8250),
  minus = uchar(8722), prime = uchar(8242), Prime = uchar(8243),
}

local function decode_entities(s)
  if not s or s == "" then return s or "" end
  s = tostring(s)
  s = s:gsub("&#[xX](%x+);", function(h)
    local n = tonumber(h, 16)
    if n then return uchar(n) end
  end)
  s = s:gsub("&#(%d+);", function(d)
    local n = tonumber(d)
    if n then return uchar(n) end
  end)
  s = s:gsub("&(%w+);", function(name)
    return ENTITIES[name] or ("&" .. name .. ";")
  end)
  return s
end

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

local VOID_ELEMENTS = {
  area = true, base = true, br = true, col = true, embed = true,
  hr = true, img = true, input = true, link = true, meta = true,
  source = true, track = true, wbr = true,
}

local function parse_attrs(s)
  local attrs = {}
  local i = 1
  local n = #s
  while i <= n do
    -- Skip whitespace and stray slashes.
    while i <= n do
      local c = s:sub(i, i)
      if c == " " or c == "\t" or c == "\n" or c == "\r" or c == "/" then
        i = i + 1
      else break end
    end
    if i > n then break end
    local kstart = i
    while i <= n do
      local c = s:sub(i, i)
      if c == "=" or c == " " or c == "\t" or c == "\n" or c == "\r"
         or c == "/" or c == ">" then break end
      i = i + 1
    end
    local key = s:sub(kstart, i - 1):lower()
    if key == "" then break end
    while i <= n do
      local c = s:sub(i, i)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1
      else break end
    end
    local val = ""
    if i <= n and s:sub(i, i) == "=" then
      i = i + 1
      while i <= n do
        local c = s:sub(i, i)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1
        else break end
      end
      if i <= n then
        local c = s:sub(i, i)
        if c == '"' or c == "'" then
          local endp = s:find(c, i + 1, true)
          if endp then
            val = s:sub(i + 1, endp - 1)
            i = endp + 1
          else
            val = s:sub(i + 1)
            i = n + 1
          end
        else
          local vstart = i
          while i <= n do
            local cc = s:sub(i, i)
            if cc == " " or cc == "\t" or cc == "\n" or cc == "\r"
               or cc == ">" then break end
            i = i + 1
          end
          val = s:sub(vstart, i - 1)
        end
      end
    end
    attrs[#attrs + 1] = { key, decode_entities(val) }
  end
  return attrs
end

local function tokenize(input)
  local tokens = {}
  local pos = 1
  local n = #input
  while pos <= n do
    local lt = input:find("<", pos, true)
    if not lt then
      tokens[#tokens + 1] = {
        kind = "text", val = input:sub(pos), start = pos, stop = n,
      }
      break
    end
    if lt > pos then
      tokens[#tokens + 1] = {
        kind = "text", val = input:sub(pos, lt - 1), start = pos, stop = lt - 1,
      }
    end
    pos = lt
    local next_ch = input:sub(pos + 1, pos + 1)
    if input:sub(pos, pos + 3) == "<!--" then
      local endp = input:find("-->", pos + 4, true)
      if endp then
        tokens[#tokens + 1] = {
          kind = "comment", val = input:sub(pos + 4, endp - 1),
          start = pos, stop = endp + 2,
        }
        pos = endp + 3
      else
        pos = n + 1
      end
    elseif input:sub(pos, pos + 8) == "<![CDATA[" then
      local endp = input:find("]]>", pos + 9, true)
      if endp then
        tokens[#tokens + 1] = {
          kind = "text", val = input:sub(pos + 9, endp - 1),
          start = pos, stop = endp + 2,
        }
        pos = endp + 3
      else
        pos = n + 1
      end
    elseif next_ch == "!" or next_ch == "?" then
      local endp = input:find(">", pos + 2, true)
      if endp then
        tokens[#tokens + 1] = {
          kind = "doctype", start = pos, stop = endp,
        }
        pos = endp + 1
      else
        pos = n + 1
      end
    elseif next_ch == "/" then
      local endp = input:find(">", pos + 2, true)
      if not endp then pos = n + 1; break end
      local body = input:sub(pos + 2, endp - 1)
      local name = body:match("^%s*([%w:_%-]+)")
      if name then
        tokens[#tokens + 1] = {
          kind = "close", name = name:lower(),
          start = pos, stop = endp,
        }
      end
      pos = endp + 1
    elseif next_ch:match("[%a]") then
      -- Find end of tag, respecting quoted attribute values.
      local i = pos + 1
      local in_quote = nil
      local endp = nil
      while i <= n do
        local ch = input:sub(i, i)
        if in_quote then
          if ch == in_quote then in_quote = nil end
        else
          if ch == '"' or ch == "'" then in_quote = ch
          elseif ch == ">" then endp = i; break end
        end
        i = i + 1
      end
      if not endp then pos = n + 1; break end
      local body = input:sub(pos + 1, endp - 1)
      local self_closing = false
      if body:sub(-1) == "/" then
        self_closing = true
        body = body:sub(1, -2)
      end
      local name, rest = body:match("^([%w:_%-]+)%s*(.*)$")
      if not name then
        tokens[#tokens + 1] = {
          kind = "text", val = input:sub(pos, endp),
          start = pos, stop = endp,
        }
        pos = endp + 1
      else
        local lname = name:lower()
        local attrs = parse_attrs(rest or "")
        if VOID_ELEMENTS[lname] then self_closing = true end
        tokens[#tokens + 1] = {
          kind = "open", name = lname, attrs = attrs,
          self_closing = self_closing, start = pos, stop = endp,
        }
        pos = endp + 1
        -- Raw-text elements: consume verbatim until matching close.
        if (lname == "script" or lname == "style") and not self_closing then
          local raw_end = input:lower():find("</" .. lname, pos, true)
          local raw_text = ""
          if raw_end then
            raw_text = input:sub(pos, raw_end - 1)
            local gt = input:find(">", raw_end, true)
            tokens[#tokens + 1] = {
              kind = "raw", val = raw_text, name = lname,
              start = pos, stop = (raw_end or n) - 1,
            }
            if gt then
              tokens[#tokens + 1] = {
                kind = "close", name = lname,
                start = raw_end, stop = gt,
              }
              pos = gt + 1
            else
              pos = n + 1
            end
          else
            tokens[#tokens + 1] = {
              kind = "raw", val = input:sub(pos), name = lname,
              start = pos, stop = n,
            }
            pos = n + 1
          end
        end
      end
    else
      -- lone "<" — take verbatim as text up to next "<".
      local j = input:find("<", pos + 1, true) or (n + 1)
      tokens[#tokens + 1] = {
        kind = "text", val = input:sub(pos, j - 1),
        start = pos, stop = j - 1,
      }
      pos = j
    end
  end
  return tokens
end

-- ---------------------------------------------------------------------------
-- Attribute helpers
-- ---------------------------------------------------------------------------

local function attrs_get(attrs, key)
  for _, pair in ipairs(attrs or {}) do
    if pair[1] == key then return pair[2] end
  end
  return nil
end

local function split_classes(s)
  local out = {}
  for w in tostring(s or ""):gmatch("%S+") do out[#out + 1] = w end
  return out
end

local function build_attr(attrs, drop_keys, extra_classes, drop_classes)
  drop_keys = drop_keys or {}
  local drop = {}
  for _, k in ipairs(drop_keys) do drop[k] = true end
  local dropc = {}
  for _, c in ipairs(drop_classes or {}) do dropc[c] = true end
  local id = ""
  local classes = {}
  local kvs = {}
  for _, pair in ipairs(attrs or {}) do
    local k, v = pair[1], pair[2]
    if k == "id" then id = v
    elseif k == "class" then
      for _, c in ipairs(split_classes(v)) do
        if not dropc[c] then classes[#classes + 1] = c end
      end
    elseif not drop[k] then
      -- Pandoc strips the "data-" prefix from custom HTML attributes.
      local key_out = k:match("^data%-(.+)$") or k
      kvs[#kvs + 1] = { key_out, v }
    end
  end
  for _, c in ipairs(extra_classes or {}) do classes[#classes + 1] = c end
  return pandoc.Attr(id, classes, kvs)
end

local function has_class(attrs, name)
  local cls = attrs_get(attrs, "class")
  if not cls then return false end
  for c in cls:gmatch("%S+") do
    if c == name then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Inline accumulator: turns text fragments into Str/Space/SoftBreak
-- ---------------------------------------------------------------------------

local function append_text_as_inlines(out, text)
  -- text already has entities decoded
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == " " or c == "\t" then
      local has_nl = false
      while i <= n do
        local cc = text:sub(i, i)
        if cc == " " or cc == "\t" then i = i + 1
        elseif cc == "\n" or cc == "\r" then has_nl = true; i = i + 1
        else break end
      end
      out[#out + 1] = has_nl and pandoc.SoftBreak() or pandoc.Space()
    elseif c == "\n" or c == "\r" then
      while i <= n do
        local cc = text:sub(i, i)
        if cc == " " or cc == "\t" or cc == "\n" or cc == "\r" then i = i + 1
        else break end
      end
      out[#out + 1] = pandoc.SoftBreak()
    else
      local j = i
      while j <= n do
        local cc = text:sub(j, j)
        if cc == " " or cc == "\t" or cc == "\n" or cc == "\r" then break end
        j = j + 1
      end
      out[#out + 1] = pandoc.Str(text:sub(i, j - 1))
      i = j
    end
  end
end

local function normalize_inlines(inls)
  -- Collapse adjacent Space/SoftBreak (SoftBreak wins), drop leading/
  -- trailing, and drop those adjacent to LineBreak.
  local tmp = {}
  for _, el in ipairs(inls) do
    if el.tag == "Space" or el.tag == "SoftBreak" then
      local prev = tmp[#tmp]
      if prev and (prev.tag == "Space" or prev.tag == "SoftBreak") then
        if el.tag == "SoftBreak" then tmp[#tmp] = el end
      else
        tmp[#tmp + 1] = el
      end
    else
      tmp[#tmp + 1] = el
    end
  end
  while #tmp > 0 and (tmp[1].tag == "Space" or tmp[1].tag == "SoftBreak") do
    table.remove(tmp, 1)
  end
  while #tmp > 0 and (tmp[#tmp].tag == "Space" or tmp[#tmp].tag == "SoftBreak") do
    table.remove(tmp)
  end
  local out = {}
  for i, el in ipairs(tmp) do
    if el.tag == "Space" or el.tag == "SoftBreak" then
      local prev = out[#out]
      local nxt = tmp[i + 1]
      if (prev and prev.tag == "LineBreak")
         or (nxt and nxt.tag == "LineBreak") then
        -- skip
      else
        out[#out + 1] = el
      end
    else
      out[#out + 1] = el
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

local BLOCK_TAGS = {
  p = true, div = true, section = true, article = true, aside = true,
  header = true, footer = true, nav = true, main = true,
  h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
  ul = true, ol = true, li = true, dl = true, dt = true, dd = true,
  blockquote = true, pre = true, hr = true, figure = true, figcaption = true,
  table = true, thead = true, tbody = true, tfoot = true, tr = true,
  th = true, td = true, caption = true, colgroup = true, col = true,
  address = true, details = true, summary = true,
}

local INLINE_TAGS = {
  a = true, em = true, strong = true, u = true, i = true, b = true,
  s = true, del = true, ins = true, mark = true,
  sup = true, sub = true, small = true, big = true,
  code = true, kbd = true, samp = true, var = true, cite = true,
  span = true, q = true, abbr = true, time = true, bdi = true, bdo = true,
  br = true, img = true, ruby = true, rt = true, rp = true,
  wbr = true, dfn = true,
}

-- Forward declarations.
local read_inlines, read_blocks_until, read_block
local raw_input
local has_class_attr

local function advance(state)
  state.pos = state.pos + 1
end

local function peek(state) return state.tokens[state.pos] end

local function consume_whitespace_text(state)
  while true do
    local t = peek(state)
    if not t then return end
    if t.kind == "text" and t.val:match("^%s*$") then
      advance(state)
    elseif t.kind == "comment" or t.kind == "doctype" then
      advance(state)
    else
      return
    end
  end
end

local function find_matching_close(state, name)
  -- Return index of the matching close token, or nil if unbalanced.
  local depth = 1
  local i = state.pos
  while i <= #state.tokens do
    local t = state.tokens[i]
    if t.kind == "open" and t.name == name and not t.self_closing then
      depth = depth + 1
    elseif t.kind == "close" and t.name == name then
      depth = depth - 1
      if depth == 0 then return i end
    end
    i = i + 1
  end
  return nil
end

-- Read inlines until we hit a close token in `stop_set`, or an unknown block
-- open (which implicitly closes the inline context), or EOF.
read_inlines = function(state, stop_set)
  local out = {}
  stop_set = stop_set or {}
  while true do
    local t = peek(state)
    if not t then break end
    if t.kind == "close" then
      -- Any close token we didn't open is treated as an outer-boundary stop;
      -- this prevents runaway consumption past li/td/section boundaries when
      -- the tag that would have "caught" the close was dropped upstream.
      break
    elseif t.kind == "comment" or t.kind == "doctype" or t.kind == "raw" then
      advance(state)
    elseif t.kind == "text" then
      advance(state)
      append_text_as_inlines(out, decode_entities(t.val))
    elseif t.kind == "open" then
      local name = t.name
      if BLOCK_TAGS[name] and not INLINE_TAGS[name] then
        -- Block open inside inline context: stop, let caller handle.
        break
      end
      advance(state)
      -- Inline tag dispatch.
      if name == "em" or name == "i" then
        local content = read_inlines(state, { [name] = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Emph(normalize_inlines(content))
      elseif name == "strong" or name == "b" then
        local content = read_inlines(state, { [name] = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Strong(normalize_inlines(content))
      elseif name == "u" then
        local content = read_inlines(state, { u = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Underline(normalize_inlines(content))
      elseif name == "del" or name == "s" then
        local content = read_inlines(state, { [name] = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Strikeout(normalize_inlines(content))
      elseif name == "sup" then
        local content = read_inlines(state, { sup = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Superscript(normalize_inlines(content))
      elseif name == "sub" then
        local content = read_inlines(state, { sub = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Subscript(normalize_inlines(content))
      elseif name == "br" then
        out[#out + 1] = pandoc.LineBreak()
      elseif name == "code" then
        local content = read_inlines(state, { code = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        local text = {}
        for _, el in ipairs(content) do
          if el.tag == "Str" then text[#text + 1] = el.text
          elseif el.tag == "Space" then text[#text + 1] = " "
          elseif el.tag == "SoftBreak" then text[#text + 1] = "\n"
          elseif el.tag == "LineBreak" then text[#text + 1] = "\n"
          end
        end
        out[#out + 1] = pandoc.Code(table.concat(text), build_attr(t.attrs))
      elseif name == "a" then
        local href = attrs_get(t.attrs, "href") or ""
        local title = attrs_get(t.attrs, "title") or ""
        local content = read_inlines(state, { a = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        if has_class(t.attrs, "footnote-ref") then
          out[#out + 1] = {
            tag = "FootnoteRef", t = "FootnoteRef",
            target = href, attrs = t.attrs,
          }
        elseif has_class(t.attrs, "footnote-back") then
          -- Drop backref entirely (we reconstruct the Note.)
        else
          out[#out + 1] = pandoc.Link(
            normalize_inlines(content), href, title,
            build_attr(t.attrs, { "href", "title" }))
        end
      elseif name == "img" then
        local src = attrs_get(t.attrs, "src") or ""
        local title = attrs_get(t.attrs, "title") or ""
        local alt = attrs_get(t.attrs, "alt") or ""
        local caption = {}
        if alt ~= "" then
          append_text_as_inlines(caption, decode_entities(alt))
        end
        out[#out + 1] = pandoc.Image(
          caption, src, title,
          build_attr(t.attrs, { "src", "title", "alt" }))
      elseif name == "span" then
        local content
        if t.self_closing then content = {}
        else
          content = read_inlines(state, { span = true })
          if peek(state) and peek(state).kind == "close" then advance(state) end
        end
        if has_class(t.attrs, "smallcaps") then
          out[#out + 1] = pandoc.SmallCaps(normalize_inlines(content))
        elseif has_class(t.attrs, "math") then
          -- Only recover as Math if the inner text is wrapped in \(...\) or
          -- \[...\] (what our writer emits). Pandoc's HTML writer renders
          -- math as HTML (Emph/Sup/Sub mix) and its reader keeps those as
          -- Span — matching that behavior here.
          local parts = {}
          local all_text = true
          for _, el in ipairs(content) do
            if el.tag == "Str" then parts[#parts + 1] = el.text
            elseif el.tag == "Space" then parts[#parts + 1] = " "
            elseif el.tag == "SoftBreak" then parts[#parts + 1] = "\n"
            else all_text = false; break
            end
          end
          local text = all_text and table.concat(parts) or ""
          local mtype
          if all_text then
            local stripped = text:match("^\\%((.*)\\%)$")
            if stripped then mtype = "InlineMath"; text = stripped
            else
              stripped = text:match("^\\%[(.*)\\%]$")
              if stripped then mtype = "DisplayMath"; text = stripped end
            end
          end
          if mtype then
            out[#out + 1] = pandoc.Math(mtype, text)
          else
            out[#out + 1] = pandoc.Span(normalize_inlines(content),
                                        build_attr(t.attrs))
          end
        else
          out[#out + 1] = pandoc.Span(normalize_inlines(content),
                                      build_attr(t.attrs))
        end
      elseif name == "q" then
        local content = read_inlines(state, { q = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Quoted("DoubleQuote",
                                      normalize_inlines(content))
      elseif name == "cite" then
        local content = read_inlines(state, { cite = true })
        if peek(state) and peek(state).kind == "close" then advance(state) end
        out[#out + 1] = pandoc.Cite({}, normalize_inlines(content))
      elseif name == "small" or name == "big" or name == "mark"
             or name == "ins" or name == "abbr" or name == "kbd"
             or name == "samp" or name == "var" or name == "time"
             or name == "bdi" or name == "bdo" or name == "dfn"
             or name == "ruby" or name == "rt" or name == "rp" then
        local content
        if t.self_closing then content = {}
        else
          content = read_inlines(state, { [name] = true })
          if peek(state) and peek(state).kind == "close" then advance(state) end
        end
        out[#out + 1] = pandoc.Span(normalize_inlines(content),
                                    build_attr(t.attrs))
      elseif name == "script" or name == "style" then
        -- dropped; content is in a raw token we skip at read time
      else
        -- Unknown inline tag: raw passthrough.
        local s = raw_input:sub(t.start, t.stop)
        if not t.self_closing then
          local close_idx = find_matching_close(state, name)
          if close_idx then
            -- Include inner content + close in the raw slice.
            s = raw_input:sub(t.start, state.tokens[close_idx].stop)
            state.pos = close_idx + 1
          end
        end
        out[#out + 1] = pandoc.RawInline("html", s)
      end
    else
      advance(state)
    end
  end
  return out
end

-- Read blocks until close token in stop_set (or EOF).
read_blocks_until = function(state, stop_set)
  local out = {}
  stop_set = stop_set or {}
  while true do
    local t = peek(state)
    if not t then break end
    if t.kind == "close" then
      if stop_set[t.name] then break end
      advance(state)
    elseif t.kind == "text" then
      if t.val:match("^%s*$") then
        advance(state)
      else
        -- Stray text in block context → wrap in Plain.
        advance(state)
        local ils = {}
        append_text_as_inlines(ils, decode_entities(t.val))
        -- Keep reading inlines until we hit a block boundary.
        local more = read_inlines(state, stop_set)
        for _, el in ipairs(more) do ils[#ils + 1] = el end
        out[#out + 1] = pandoc.Plain(normalize_inlines(ils))
      end
    elseif t.kind == "comment" or t.kind == "doctype" or t.kind == "raw" then
      advance(state)
    elseif t.kind == "open" then
      local blk = read_block(state, stop_set)
      if blk then
        if type(blk) == "table" and blk.tag then
          out[#out + 1] = blk
        elseif type(blk) == "table" then
          for _, b in ipairs(blk) do out[#out + 1] = b end
        end
      end
    else
      advance(state)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Block-level handlers (forward-declared as `read_block`)
-- ---------------------------------------------------------------------------

local function expect_close(state, name)
  while peek(state) do
    local t = peek(state)
    if t.kind == "close" and t.name == name then
      advance(state); return
    end
    advance(state)
  end
end

local function strip_leading_newline(s)
  if s:sub(1, 1) == "\n" then return s:sub(2) end
  if s:sub(1, 2) == "\r\n" then return s:sub(3) end
  return s
end

local function read_list_items(state, container, item_tag)
  -- Read a sequence of <li> children under <ul>/<ol>, until container close.
  local items = {}
  while true do
    local t = peek(state)
    if not t then break end
    if t.kind == "close" and t.name == container then break end
    if t.kind == "open" and t.name == item_tag then
      advance(state)
      local blocks = read_blocks_until(state, { [item_tag] = true,
                                                [container] = true })
      if peek(state) and peek(state).kind == "close"
         and peek(state).name == item_tag then
        advance(state)
      end
      -- If the li contains only a single Plain with inlines, leave as-is
      -- (matches pandoc's behavior for compact lists).
      if #blocks == 0 then
        items[#items + 1] = { pandoc.Plain({}) }
      else
        items[#items + 1] = blocks
      end
    else
      advance(state)
    end
  end
  return items
end

local function read_dl(state)
  local items = {}
  local cur_term = nil
  local cur_defs = nil
  local function flush()
    if cur_term then
      items[#items + 1] = { cur_term, cur_defs or {} }
      cur_term = nil
      cur_defs = nil
    end
  end
  while true do
    local t = peek(state)
    if not t then break end
    if t.kind == "close" and t.name == "dl" then break end
    if t.kind == "open" and t.name == "dt" then
      flush()
      advance(state)
      local inls = read_inlines(state, { dt = true, dd = true, dl = true })
      if peek(state) and peek(state).kind == "close"
         and peek(state).name == "dt" then advance(state) end
      cur_term = normalize_inlines(inls)
      cur_defs = {}
    elseif t.kind == "open" and t.name == "dd" then
      advance(state)
      local blocks = read_blocks_until(state, { dd = true, dt = true, dl = true })
      if peek(state) and peek(state).kind == "close"
         and peek(state).name == "dd" then advance(state) end
      if cur_term == nil then
        cur_term = {}; cur_defs = {}
      end
      -- Collapse single Plain/Para wrapping to match pandoc's output.
      cur_defs[#cur_defs + 1] = blocks
    else
      advance(state)
    end
  end
  flush()
  return pandoc.DefinitionList(items)
end

local function parse_alignment(style)
  if not style then return nil end
  local a = style:match("text%-align%s*:%s*([%a]+)")
  if not a then return nil end
  a = a:lower()
  if a == "left" then return "AlignLeft"
  elseif a == "right" then return "AlignRight"
  elseif a == "center" then return "AlignCenter" end
  return nil
end

local function style_without_align(style)
  if not style or style == "" then return "" end
  local rest = style:gsub("text%-align%s*:%s*[%a]+%s*;?%s*", "")
  rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
  return rest
end

local function read_cell(state, close_name)
  advance(state)  -- consume the open
  local t = state.tokens[state.pos - 1]
  local blocks = read_blocks_until(state, { [close_name] = true,
                                             tr = true, thead = true,
                                             tbody = true, tfoot = true,
                                             table = true })
  if peek(state) and peek(state).kind == "close"
     and peek(state).name == close_name then
    advance(state)
  end
  -- If a cell only has inline content that got wrapped as Para, collapse to
  -- Plain (pandoc's tables use Plain for simple cells).
  if #blocks == 1 and blocks[1].tag == "Para" then
    blocks = { pandoc.Plain(blocks[1].content) }
  end
  local style = attrs_get(t.attrs, "style") or ""
  local align = parse_alignment(style) or "AlignDefault"
  local rs = tonumber(attrs_get(t.attrs, "rowspan")) or 1
  local cs = tonumber(attrs_get(t.attrs, "colspan")) or 1
  local rest_style = style_without_align(style)
  -- Drop class="even"/"odd" noise that pandoc's writer sometimes emits.
  local attr = build_attr(t.attrs, { "style", "rowspan", "colspan" },
                          nil, { "even", "odd" })
  if rest_style ~= "" then
    -- Preserve non-alignment style in attributes.
    local new_attrs = {}
    for _, p in ipairs(attr.attributes or {}) do
      new_attrs[#new_attrs + 1] = p
    end
    new_attrs[#new_attrs + 1] = { "style", rest_style }
    attr = pandoc.Attr(attr.identifier, attr.classes, new_attrs)
  end
  return pandoc.Cell(blocks, align, rs, cs, attr), align
end

local function read_row(state)
  advance(state)  -- consume <tr>
  local t = state.tokens[state.pos - 1]
  local cells = {}
  local aligns = {}
  while true do
    local tt = peek(state)
    if not tt then break end
    if tt.kind == "close" and tt.name == "tr" then advance(state); break end
    if tt.kind == "close"
       and (tt.name == "thead" or tt.name == "tbody"
            or tt.name == "tfoot" or tt.name == "table") then
      break
    end
    if tt.kind == "open" and (tt.name == "td" or tt.name == "th") then
      local cell, align = read_cell(state, tt.name)
      cells[#cells + 1] = cell
      aligns[#aligns + 1] = align
    else
      advance(state)
    end
  end
  return pandoc.Row(cells, build_attr(t.attrs)), aligns
end

local function read_table(state)
  advance(state)  -- consume <table>
  local tok_open = state.tokens[state.pos - 1]
  local caption = { long = {}, short = nil }
  local head_rows = {}
  local body_rows = {}
  local foot_rows = {}
  local first_body_aligns = nil
  local current = "body"  -- default when no thead/tbody/tfoot wrapper
  while true do
    local t = peek(state)
    if not t then break end
    if t.kind == "close" and t.name == "table" then advance(state); break end
    if t.kind == "open" and t.name == "caption" then
      advance(state)
      local blocks = read_blocks_until(state, { caption = true })
      if peek(state) and peek(state).kind == "close"
         and peek(state).name == "caption" then advance(state) end
      caption = { long = blocks, short = nil }
    elseif t.kind == "open" and t.name == "thead" then
      advance(state); current = "head"
    elseif t.kind == "open" and t.name == "tbody" then
      advance(state); current = "body"
    elseif t.kind == "open" and t.name == "tfoot" then
      advance(state); current = "foot"
    elseif t.kind == "close"
           and (t.name == "thead" or t.name == "tbody" or t.name == "tfoot") then
      advance(state); current = "body"
    elseif t.kind == "open" and t.name == "tr" then
      local row, aligns = read_row(state)
      if current == "head" then head_rows[#head_rows + 1] = row
      elseif current == "foot" then foot_rows[#foot_rows + 1] = row
      else
        body_rows[#body_rows + 1] = row
        if first_body_aligns == nil then first_body_aligns = aligns end
      end
    elseif t.kind == "open" and (t.name == "colgroup" or t.name == "col") then
      advance(state)
      if not t.self_closing and t.name == "colgroup" then
        expect_close(state, "colgroup")
      end
    else
      advance(state)
    end
  end
  -- Derive colspecs from first body row (or head row if no body), using the
  -- cells' alignments.
  local aligns = first_body_aligns
  if (not aligns or #aligns == 0) and #head_rows > 0 then
    -- Pull alignments out of the first head row's cells.
    local alist = {}
    for _, c in ipairs(head_rows[1].cells or {}) do
      alist[#alist + 1] = c.alignment or "AlignDefault"
    end
    aligns = alist
  end
  aligns = aligns or {}
  -- Determine the full column count in case first row underspecifies.
  local col_count = #aligns
  for _, r in ipairs(head_rows) do
    if #r.cells > col_count then col_count = #r.cells end
  end
  for _, r in ipairs(body_rows) do
    if #r.cells > col_count then col_count = #r.cells end
  end
  while #aligns < col_count do aligns[#aligns + 1] = "AlignDefault" end
  local colspecs = {}
  for _, a in ipairs(aligns) do
    colspecs[#colspecs + 1] = { a, nil }
  end
  local head = pandoc.TableHead(head_rows)
  local body = pandoc.TableBody(body_rows, {}, 0)
  local foot = pandoc.TableFoot(foot_rows)
  return pandoc.Table(caption, colspecs, head, { body }, foot,
                      build_attr(tok_open.attrs))
end

local function read_pre(state)
  advance(state)  -- consume <pre>
  local tok_pre = state.tokens[state.pos - 1]
  -- Find the pre close.
  local close_idx = find_matching_close(state, "pre")
  if not close_idx then
    return pandoc.CodeBlock("", build_attr(tok_pre.attrs))
  end
  -- Check whether the only meaningful child is a single <code> element.
  local code_open = nil
  local code_close = nil
  local only_code = true
  local i = state.pos
  while i < close_idx do
    local t = state.tokens[i]
    if t.kind == "text" then
      if not t.val:match("^%s*$") then only_code = false end
    elseif t.kind == "open" then
      if not code_open and t.name == "code" then
        code_open = i
        -- Find matching </code>.
        local depth = 1
        local j = i + 1
        while j < close_idx do
          local tt = state.tokens[j]
          if tt.kind == "open" and tt.name == "code" and not tt.self_closing then
            depth = depth + 1
          elseif tt.kind == "close" and tt.name == "code" then
            depth = depth - 1
            if depth == 0 then code_close = j; break end
          end
          j = j + 1
        end
        if not code_close then only_code = false; break end
        i = code_close
      else
        only_code = false; break
      end
    elseif t.kind == "close" then
      if t.name ~= "code" then only_code = false; break end
    end
    i = i + 1
  end
  local text_parts = {}
  local attr
  if only_code and code_open and code_close then
    -- Extract text between code_open.stop+1 and code_close.start-1, then
    -- strip HTML tags inside (for pandoc's sourceCode span soup).
    local raw = raw_input:sub(state.tokens[code_open].stop + 1,
                              state.tokens[code_close].start - 1)
    -- Strip all nested tags and decode entities.
    raw = raw:gsub("<[^>]*>", "")
    raw = decode_entities(raw)
    text_parts = { strip_leading_newline(raw) }
    attr = build_attr(state.tokens[code_open].attrs, nil, nil,
                      { "sourceCode" })
  else
    -- Collect text from all children verbatim, stripping any nested tags.
    local raw = raw_input:sub(tok_pre.stop + 1,
                              state.tokens[close_idx].start - 1)
    raw = raw:gsub("<[^>]*>", "")
    raw = decode_entities(raw)
    text_parts = { strip_leading_newline(raw) }
    attr = build_attr(tok_pre.attrs, nil, nil, { "sourceCode" })
  end
  state.pos = close_idx + 1
  local text = table.concat(text_parts)
  -- Strip trailing newline (pandoc trims codeblock trailing newline).
  if text:sub(-1) == "\n" then text = text:sub(1, -2) end
  return pandoc.CodeBlock(text, attr)
end

local function last_plain_or_para(blocks)
  for i = #blocks, 1, -1 do
    local b = blocks[i]
    if b.tag == "Para" or b.tag == "Plain" then return i end
  end
  return nil
end

local function inline_is_backref(el)
  if el.tag ~= "Link" or not el.attr or not el.attr.classes then return false end
  for _, c in ipairs(el.attr.classes) do
    if c == "footnote-back" then return true end
  end
  return false
end

local function strip_trailing_backref(blocks)
  -- First, drop any trailing stand-alone blocks whose content is the backref
  -- link (Plain [Link footnote-back]) — these occur when the writer emits the
  -- backref as a sibling after the Para.
  while #blocks > 0 do
    local last = blocks[#blocks]
    if last.tag == "Plain" and last.content and #last.content >= 1 then
      local only_backref = true
      for _, el in ipairs(last.content) do
        if not (inline_is_backref(el)
                or el.tag == "Space" or el.tag == "SoftBreak"
                or el.tag == "LineBreak") then
          only_backref = false; break
        end
      end
      if only_backref then table.remove(blocks); else break end
    else
      break
    end
  end
  -- Then strip a trailing footnote-back inline from the last Para/Plain.
  local idx = last_plain_or_para(blocks)
  if not idx then return blocks end
  local content = blocks[idx].content
  while #content > 0 do
    local last = content[#content]
    if inline_is_backref(last) then
      table.remove(content)
    elseif last.tag == "Space" or last.tag == "SoftBreak"
           or last.tag == "LineBreak" then
      table.remove(content)
    else
      break
    end
  end
  return blocks
end

read_block = function(state, outer_stop)
  local t = peek(state)
  if not t or t.kind ~= "open" then advance(state); return nil end
  local name = t.name
  -- Inline tag in block context → read an inlines run bounded by the outer
  -- block stop set, and wrap in Plain.
  if INLINE_TAGS[name] and not BLOCK_TAGS[name] then
    local ils = read_inlines(state, outer_stop or {})
    local norm = normalize_inlines(ils)
    if #norm == 0 then return nil end
    return pandoc.Plain(norm)
  end
  if name == "h1" or name == "h2" or name == "h3"
     or name == "h4" or name == "h5" or name == "h6" then
    advance(state)
    local level = tonumber(name:sub(2))
    local inls = {}
    if not t.self_closing then
      inls = read_inlines(state, { [name] = true })
      if peek(state) and peek(state).kind == "close"
         and peek(state).name == name then advance(state) end
    end
    return pandoc.Header(level, normalize_inlines(inls),
                          build_attr(t.attrs))
  elseif name == "p" then
    advance(state)
    local inls = {}
    if not t.self_closing then
      inls = read_inlines(state, { p = true })
      if peek(state) and peek(state).kind == "close"
         and peek(state).name == "p" then advance(state) end
    end
    return pandoc.Para(normalize_inlines(inls))
  elseif name == "blockquote" then
    advance(state)
    local blocks = read_blocks_until(state, { blockquote = true })
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == "blockquote" then advance(state) end
    return pandoc.BlockQuote(blocks)
  elseif name == "ul" then
    advance(state)
    local items = read_list_items(state, "ul", "li")
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == "ul" then advance(state) end
    return pandoc.BulletList(items)
  elseif name == "ol" then
    advance(state)
    local items = read_list_items(state, "ol", "li")
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == "ol" then advance(state) end
    local start = tonumber(attrs_get(t.attrs, "start")) or 1
    local type_attr = attrs_get(t.attrs, "type")
    local style
    if type_attr == "a" then style = "LowerAlpha"
    elseif type_attr == "A" then style = "UpperAlpha"
    elseif type_attr == "i" then style = "LowerRoman"
    elseif type_attr == "I" then style = "UpperRoman"
    elseif type_attr == "1" then style = "Decimal"
    else style = "DefaultStyle"
    end
    return pandoc.OrderedList(items, { start, style, "DefaultDelim" })
  elseif name == "dl" then
    advance(state)
    local dl = read_dl(state)
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == "dl" then advance(state) end
    return dl
  elseif name == "pre" then
    return read_pre(state)
  elseif name == "hr" then
    advance(state)
    return pandoc.HorizontalRule()
  elseif name == "table" then
    return read_table(state)
  elseif name == "figure" then
    advance(state)
    local content = {}
    local cap_blocks = {}
    while true do
      local tt = peek(state)
      if not tt then break end
      if tt.kind == "close" and tt.name == "figure" then
        advance(state); break end
      if tt.kind == "open" and tt.name == "figcaption" then
        advance(state)
        cap_blocks = read_blocks_until(state, { figcaption = true })
        if peek(state) and peek(state).kind == "close"
           and peek(state).name == "figcaption" then advance(state) end
      else
        local blk = read_block(state)
        if blk then
          if type(blk) == "table" and blk.tag then
            content[#content + 1] = blk
          else
            for _, b in ipairs(blk) do content[#content + 1] = b end
          end
        end
      end
    end
    local caption = { long = cap_blocks, short = nil }
    return pandoc.Figure(content, caption, build_attr(t.attrs))
  elseif name == "section" then
    advance(state)
    local blocks = read_blocks_until(state, { section = true })
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == "section" then advance(state) end
    -- The footnote section is collected by `collect_footnote_defs` in a
    -- pre-pass against the token stream. Drop it here.
    local id = attrs_get(t.attrs, "id") or ""
    if id == "footnotes" or has_class(t.attrs, "footnotes") then
      return nil
    end
    return pandoc.Div(blocks, build_attr(t.attrs, nil, { "section" }))
  elseif name == "div" then
    advance(state)
    if t.self_closing then
      return pandoc.Div({}, build_attr(t.attrs))
    end
    local blocks = read_blocks_until(state, { div = true })
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == "div" then advance(state) end
    if has_class(t.attrs, "line-block") then
      local lines = {}
      for _, b in ipairs(blocks) do
        if b.tag == "Div" and has_class_attr(b.attr, "line") then
          lines[#lines + 1] = b.content
        end
      end
      return pandoc.LineBlock(lines)
    end
    if has_class(t.attrs, "sourceCode") then
      -- Pandoc wraps syntax-highlighted code blocks in <div class="sourceCode">
      -- containing a <pre><code>. The inner CodeBlock should already be the
      -- only child; unwrap.
      if #blocks == 1 and blocks[1].tag == "CodeBlock" then
        return blocks[1]
      end
    end
    return pandoc.Div(blocks, build_attr(t.attrs))
  elseif name == "article" or name == "aside" or name == "header"
         or name == "footer" or name == "nav" or name == "main"
         or name == "address" or name == "details" or name == "summary" then
    advance(state)
    local blocks = read_blocks_until(state, { [name] = true })
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == name then advance(state) end
    return pandoc.Div(blocks, build_attr(t.attrs, nil, { name }))
  elseif name == "html" or name == "body" or name == "head" then
    advance(state)
    local blocks = read_blocks_until(state, { [name] = true })
    if peek(state) and peek(state).kind == "close"
       and peek(state).name == name then advance(state) end
    return blocks
  elseif name == "title" or name == "meta" or name == "link"
         or name == "script" or name == "style" or name == "noscript" then
    -- Drop. (title is harvested in a separate pre-pass.)
    advance(state)
    if not t.self_closing then
      local depth = 1
      while peek(state) and depth > 0 do
        local tt = peek(state)
        if tt.kind == "open" and tt.name == name and not tt.self_closing then
          depth = depth + 1
        elseif tt.kind == "close" and tt.name == name then
          depth = depth - 1
        end
        advance(state)
      end
    end
    return nil
  else
    -- Unknown block-level tag → RawBlock with verbatim source.
    advance(state)
    if t.self_closing then
      return pandoc.RawBlock("html", raw_input:sub(t.start, t.stop))
    end
    -- Walk forward to find matching close, include verbatim source.
    local depth = 1
    local j = state.pos
    while j <= #state.tokens and depth > 0 do
      local tt = state.tokens[j]
      if tt.kind == "open" and tt.name == name and not tt.self_closing then
        depth = depth + 1
      elseif tt.kind == "close" and tt.name == name then
        depth = depth - 1
        if depth == 0 then break end
      end
      j = j + 1
    end
    if j <= #state.tokens then
      local stop = state.tokens[j].stop
      state.pos = j + 1
      return pandoc.RawBlock("html", raw_input:sub(t.start, stop))
    else
      state.pos = #state.tokens + 1
      return pandoc.RawBlock("html", raw_input:sub(t.start))
    end
  end
end

-- has_class_attr: class check on an Attr table
has_class_attr = function(attr, name)
  if not attr or not attr.classes then return false end
  for _, c in ipairs(attr.classes) do
    if c == name then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Footnote extraction + reattachment
-- ---------------------------------------------------------------------------

local function collect_footnote_defs(tokens)
  -- Find the <section id="footnotes"> ... </section> block and extract the
  -- <li id="fnN"> ... </li> children.  Returns { [id]=blocks, ... }.
  local defs = {}
  local i = 1
  local in_section = false
  local section_depth = 0
  while i <= #tokens do
    local t = tokens[i]
    if t.kind == "open" and t.name == "section" then
      local id = attrs_get(t.attrs, "id") or ""
      local is_fn = id == "footnotes"
      if not is_fn then
        local cls = attrs_get(t.attrs, "class") or ""
        for c in cls:gmatch("%S+") do
          if c == "footnotes" then is_fn = true; break end
        end
      end
      if is_fn then
        in_section = true
        section_depth = 1
        i = i + 1
      else
        i = i + 1
      end
    elseif in_section then
      if t.kind == "open" and t.name == "section" then
        section_depth = section_depth + 1; i = i + 1
      elseif t.kind == "close" and t.name == "section" then
        section_depth = section_depth - 1
        i = i + 1
        if section_depth == 0 then in_section = false end
      elseif t.kind == "open" and t.name == "li" then
        local li_id = attrs_get(t.attrs, "id") or ""
        -- Parse the li content as blocks using a sub-state.
        local sub = { tokens = tokens, pos = i + 1 }
        local blocks = read_blocks_until(sub, { li = true, ol = true,
                                                section = true })
        -- Strip trailing backref.
        strip_trailing_backref(blocks)
        if li_id ~= "" then defs[li_id] = blocks end
        -- Advance past the matching </li>.
        local j = sub.pos
        while j <= #tokens do
          if tokens[j].kind == "close" and tokens[j].name == "li" then
            j = j + 1; break
          end
          j = j + 1
        end
        i = j
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return defs
end

local function resolve_footnotes(inls, defs)
  for i, el in ipairs(inls) do
    if el.tag == "FootnoteRef" then
      local id = (el.target or ""):gsub("^#", "")
      local blocks = defs[id] or {}
      inls[i] = pandoc.Note(blocks)
    elseif el.content and type(el.content) == "table" and el.tag then
      -- Inline containers only; we handle block containers separately.
      if el.tag == "Emph" or el.tag == "Strong" or el.tag == "Underline"
         or el.tag == "Strikeout" or el.tag == "Superscript"
         or el.tag == "Subscript" or el.tag == "SmallCaps"
         or el.tag == "Link" or el.tag == "Span" or el.tag == "Quoted"
         or el.tag == "Cite" then
        resolve_footnotes(el.content, defs)
      end
    end
  end
end

local function walk_blocks_resolve(blocks, defs)
  for _, b in ipairs(blocks) do
    if b.tag == "Para" or b.tag == "Plain" or b.tag == "Header"
       or b.tag == "LineBlock" then
      if b.tag == "LineBlock" then
        for _, line in ipairs(b.content or {}) do
          resolve_footnotes(line, defs)
        end
      else
        resolve_footnotes(b.content, defs)
      end
    elseif b.tag == "BlockQuote" or b.tag == "Div" or b.tag == "Figure" then
      walk_blocks_resolve(b.content, defs)
    elseif b.tag == "BulletList" or b.tag == "OrderedList" then
      for _, item in ipairs(b.content or {}) do
        walk_blocks_resolve(item, defs)
      end
    elseif b.tag == "DefinitionList" then
      for _, item in ipairs(b.content or {}) do
        resolve_footnotes(item[1], defs)
        for _, def in ipairs(item[2] or {}) do
          walk_blocks_resolve(def, defs)
        end
      end
    elseif b.tag == "Table" then
      if b.caption and b.caption.long then
        walk_blocks_resolve(b.caption.long, defs)
      end
      local function walk_rows(rows)
        for _, row in ipairs(rows or {}) do
          for _, cell in ipairs(row.cells or {}) do
            walk_blocks_resolve(cell.content, defs)
          end
        end
      end
      walk_rows((b.head or {}).rows)
      for _, body in ipairs(b.bodies or {}) do
        walk_rows(body.head); walk_rows(body.body)
      end
      walk_rows((b.foot or {}).rows)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Meta extraction
-- ---------------------------------------------------------------------------

local function extract_meta(tokens)
  local meta = {}
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    if t.kind == "open" and t.name == "title" then
      local close = nil
      local j = i + 1
      while j <= #tokens do
        if tokens[j].kind == "close" and tokens[j].name == "title" then
          close = j; break end
        j = j + 1
      end
      local text = ""
      if close then
        for k = i + 1, close - 1 do
          if tokens[k].kind == "text" then text = text .. tokens[k].val end
        end
        i = close
      end
      text = decode_entities(text)
      text = text:gsub("^%s+", ""):gsub("%s+$", "")
      if text ~= "" then
        local inls = {}
        append_text_as_inlines(inls, text)
        meta.title = pandoc.MetaInlines(inls)
      end
    elseif t.kind == "open" and t.name == "meta" then
      local n = attrs_get(t.attrs, "name")
      local c = attrs_get(t.attrs, "content")
      if n and c and c ~= "" then
        local n_l = n:lower()
        if n_l == "author" then
          local inls = {}
          append_text_as_inlines(inls, decode_entities(c))
          meta.author = pandoc.MetaInlines(inls)
        elseif n_l == "date" then
          local inls = {}
          append_text_as_inlines(inls, decode_entities(c))
          meta.date = pandoc.MetaInlines(inls)
        end
      end
    end
    i = i + 1
  end
  return meta
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function Reader(input, opts)
  raw_input = input or ""
  local tokens = tokenize(raw_input)
  local meta = extract_meta(tokens)
  local defs = collect_footnote_defs(tokens)
  local state = { tokens = tokens, pos = 1 }
  local blocks = read_blocks_until(state, {})
  -- Drop footnote section (was absorbed into defs).
  local kept = {}
  for _, b in ipairs(blocks) do
    if b.tag == "Div" then
      local is_fn = false
      if b.attr and b.attr.identifier == "footnotes" then is_fn = true end
      if has_class_attr(b.attr, "footnotes") then is_fn = true end
      if not is_fn then kept[#kept + 1] = b end
    elseif b.tag ~= nil then
      kept[#kept + 1] = b
    end
  end
  walk_blocks_resolve(kept, defs)
  return pandoc.Pandoc(kept, meta)
end
