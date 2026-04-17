-- Pandoc Lua filter: unwrap section-Divs, hoisting the Div's id and
-- classes/attrs onto the first Header child (or dropping the wrapper).
-- Matches pandoc's own HTML writer behavior, so fixtures can be compared
-- against the AST produced by round-tripping our HTML output through
-- pandoc's HTML reader.

local function merge_classes(a, b)
  local out = {}
  for _, c in ipairs(a or {}) do out[#out+1] = c end
  for _, c in ipairs(b or {}) do
    if c ~= "section" then out[#out+1] = c end
  end
  return out
end

local function merge_attrs(a, b)
  local out = {}
  for k, v in pairs(a or {}) do out[k] = v end
  for k, v in pairs(b or {}) do
    if out[k] == nil then out[k] = v end
  end
  return out
end

function Div(el)
  local is_section = false
  for _, c in ipairs(el.classes) do
    if c == "section" then is_section = true; break end
  end
  if not is_section then return nil end

  if #el.content > 0 and el.content[1].tag == "Header"
     and (el.content[1].identifier == nil or el.content[1].identifier == "") then
    local h = el.content[1]
    h.identifier = el.identifier
    h.classes = merge_classes(h.classes, el.classes)
    h.attributes = merge_attrs(h.attributes, el.attributes)
    el.content[1] = h
  end
  return el.content
end
