-- minipandoc builtin: writers/epub.lua
-- Pure-Lua EPUB3 writer. Produces a valid EPUB container (ZIP archive)
-- by splitting on H1 headers, converting each chapter to XHTML via the
-- HTML writer, and assembling the package files.

local stringify = pandoc.utils.stringify

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local escape_text = pandoc._internal.escape_html
local escape_attr = pandoc._internal.escape_html_attr

local function image_mime(filename)
  local ext = filename:match("%.([^.]+)$")
  if not ext then return "application/octet-stream" end
  ext = ext:lower()
  local map = {
    png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
    gif = "image/gif", svg = "image/svg+xml", webp = "image/webp",
    bmp = "image/bmp",
  }
  return map[ext] or "application/octet-stream"
end

-- Deterministic pseudo-UUID (v4 format) from a seed string.
local function generate_uuid(seed_str)
  local h = 5381
  for i = 1, #seed_str do
    h = ((h * 33) + seed_str:byte(i)) % (2^32)
  end
  local bytes = {}
  local state = h
  for i = 1, 16 do
    state = (state * 1103515245 + 12345) % (2^32)
    bytes[i] = math.floor(state / 65536) % 256
  end
  -- Set version 4 and variant bits
  bytes[7] = (bytes[7] % 16) + 64   -- 0100xxxx
  bytes[9] = (bytes[9] % 64) + 128  -- 10xxxxxx
  return string.format(
    "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    bytes[1], bytes[2], bytes[3], bytes[4],
    bytes[5], bytes[6], bytes[7], bytes[8],
    bytes[9], bytes[10], bytes[11], bytes[12],
    bytes[13], bytes[14], bytes[15], bytes[16]
  )
end

-- Extract a metadata field as a plain string.
local function meta_string(meta, key)
  local v = meta[key]
  if v == nil then return nil end
  if type(v) == "string" then return v end
  return stringify(v)
end

-- Extract a metadata field as a list of strings (e.g. author).
local function meta_list(meta, key)
  local v = meta[key]
  if v == nil then return {} end
  if type(v) == "string" then return { v } end
  if type(v) == "table" then
    -- MetaList of MetaInlines/MetaString
    if #v > 0 and type(v[1]) == "table" and v[1].tag then
      -- Single MetaInlines (not a list of authors)
      return { stringify(v) }
    end
    if #v > 0 then
      local out = {}
      for _, item in ipairs(v) do
        out[#out+1] = stringify(item)
      end
      return out
    end
    return { stringify(v) }
  end
  return { tostring(v) }
end

-- ---------------------------------------------------------------------------
-- Chapter splitting
-- ---------------------------------------------------------------------------

local function split_chapters(blocks)
  local chapters = {}
  local current = {}
  for _, block in ipairs(blocks) do
    if block.tag == "Header" and block.level == 1 then
      if #current > 0 then
        chapters[#chapters+1] = current
      end
      current = { block }
    else
      current[#current+1] = block
    end
  end
  if #current > 0 then
    chapters[#chapters+1] = current
  end
  if #chapters == 0 then
    chapters[1] = {}
  end
  return chapters
end

-- Get a chapter title from its first block (if H1), else "Chapter N".
local function chapter_title(chapter_blocks, index)
  if #chapter_blocks > 0
      and chapter_blocks[1].tag == "Header"
      and chapter_blocks[1].level == 1 then
    return stringify(chapter_blocks[1].content)
  end
  return "Chapter " .. index
end

-- ---------------------------------------------------------------------------
-- Image collection
-- ---------------------------------------------------------------------------

local function collect_images(blocks)
  -- Walk blocks to find all Image src values.
  local image_map = {}   -- src -> { filename, mime }
  local seen = {}
  local counter = 0

  local function walk_inlines(inlines)
    for _, il in ipairs(inlines) do
      if il.tag == "Image" then
        local src = il.src
        if src and src ~= "" and not seen[src] then
          seen[src] = true
          local filename = pandoc.path.filename(src)
          if filename == "" then
            counter = counter + 1
            filename = "image-" .. counter
          end
          -- Deduplicate filenames
          if image_map[filename] then
            counter = counter + 1
            local stem, ext = filename:match("^(.-)(%.[^.]+)$")
            if stem then
              filename = stem .. "-" .. counter .. ext
            else
              filename = filename .. "-" .. counter
            end
          end
          image_map[src] = { filename = filename, mime = image_mime(filename) }
        end
      end
      -- Recurse into container inlines
      if il.content and type(il.content) == "table" then
        walk_inlines(il.content)
      end
    end
  end

  local function walk_blocks(bs)
    for _, b in ipairs(bs) do
      if b.content and type(b.content) == "table" then
        -- Distinguish block content (list of blocks) from inline content
        if #b.content > 0 and type(b.content[1]) == "table" then
          if b.content[1].tag and (b.content[1].tag == "Str"
              or b.content[1].tag == "Space" or b.content[1].tag == "Image"
              or b.content[1].tag == "Link" or b.content[1].tag == "Emph"
              or b.content[1].tag == "Strong" or b.content[1].tag == "Code") then
            walk_inlines(b.content)
          else
            walk_blocks(b.content)
          end
        end
      end
      if b.tag == "BulletList" or b.tag == "OrderedList" then
        for _, item in ipairs(b.content or {}) do
          if type(item) == "table" then walk_blocks(item) end
        end
      end
      if b.tag == "DefinitionList" then
        for _, pair in ipairs(b.content or {}) do
          if type(pair) == "table" then
            if pair[1] then walk_inlines(pair[1]) end
            if pair[2] then
              for _, def in ipairs(pair[2]) do walk_blocks(def) end
            end
          end
        end
      end
      if b.tag == "BlockQuote" then
        walk_blocks(b.content or {})
      end
      if b.tag == "Div" or b.tag == "Figure" then
        walk_blocks(b.content or {})
      end
      if b.tag == "Table" then
        -- Walk table cells
        local function walk_table_part(part)
          if not part then return end
          local rows = part.rows or part
          if type(rows) ~= "table" then return end
          for _, row in ipairs(rows) do
            local cells = row.cells or row
            if type(cells) == "table" then
              for _, cell in ipairs(cells) do
                if type(cell) == "table" and cell.content then
                  walk_blocks(cell.content)
                elseif type(cell) == "table" then
                  walk_blocks(cell)
                end
              end
            end
          end
        end
        if b.head then walk_table_part(b.head) end
        if b.bodies then
          for _, body in ipairs(b.bodies) do
            walk_table_part(body.head)
            walk_table_part(body.body)
          end
        end
        if b.foot then walk_table_part(b.foot) end
      end
    end
  end

  walk_blocks(blocks)
  return image_map
end

-- ---------------------------------------------------------------------------
-- XHTML wrapping
-- ---------------------------------------------------------------------------

local function make_xhtml(title, body_html, lang, has_css)
  local parts = {}
  parts[#parts+1] = '<?xml version="1.0" encoding="UTF-8"?>\n'
  parts[#parts+1] = '<!DOCTYPE html>\n'
  parts[#parts+1] = '<html xmlns="http://www.w3.org/1999/xhtml"'
  parts[#parts+1] = ' xmlns:epub="http://www.idpf.org/2007/ops"'
  parts[#parts+1] = ' xml:lang="' .. escape_attr(lang) .. '">\n'
  parts[#parts+1] = '<head>\n'
  parts[#parts+1] = '<meta charset="utf-8" />\n'
  parts[#parts+1] = '<title>' .. escape_text(title) .. '</title>\n'
  if has_css then
    parts[#parts+1] = '<link rel="stylesheet" type="text/css" href="../styles/stylesheet.css" />\n'
  end
  parts[#parts+1] = '</head>\n'
  parts[#parts+1] = '<body>\n'
  parts[#parts+1] = body_html
  parts[#parts+1] = '\n</body>\n'
  parts[#parts+1] = '</html>\n'
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Package file generation
-- ---------------------------------------------------------------------------

local function make_container_xml()
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    .. '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    .. '  <rootfiles>\n'
    .. '    <rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml" />\n'
    .. '  </rootfiles>\n'
    .. '</container>\n'
end

local function make_content_opf(meta, chapters, image_map, has_css)
  local title = meta_string(meta, "title") or "Untitled"
  local authors = meta_list(meta, "author")
  local lang = meta_string(meta, "lang") or meta_string(meta, "language") or "en"
  local date = meta_string(meta, "date") or ""
  local identifier = meta_string(meta, "identifier")
  if not identifier or identifier == "" then
    identifier = "urn:uuid:" .. generate_uuid(title .. table.concat(authors, ",") .. date)
  end

  local parts = {}
  parts[#parts+1] = '<?xml version="1.0" encoding="UTF-8"?>\n'
  parts[#parts+1] = '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">\n'

  -- metadata
  parts[#parts+1] = '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
  parts[#parts+1] = '    <dc:identifier id="pub-id">' .. escape_text(identifier) .. '</dc:identifier>\n'
  parts[#parts+1] = '    <dc:title>' .. escape_text(title) .. '</dc:title>\n'
  parts[#parts+1] = '    <dc:language>' .. escape_text(lang) .. '</dc:language>\n'
  for _, author in ipairs(authors) do
    parts[#parts+1] = '    <dc:creator>' .. escape_text(author) .. '</dc:creator>\n'
  end
  if date ~= "" then
    parts[#parts+1] = '    <dc:date>' .. escape_text(date) .. '</dc:date>\n'
  end
  parts[#parts+1] = '    <meta property="dcterms:modified">' .. escape_text(date ~= "" and date or "1970-01-01") .. '</meta>\n'
  parts[#parts+1] = '  </metadata>\n'

  -- manifest
  parts[#parts+1] = '  <manifest>\n'
  parts[#parts+1] = '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav" />\n'
  if has_css then
    parts[#parts+1] = '    <item id="css" href="styles/stylesheet.css" media-type="text/css" />\n'
  end
  for i = 1, #chapters do
    parts[#parts+1] = string.format(
      '    <item id="chapter-%d" href="text/chapter-%d.xhtml" media-type="application/xhtml+xml" />\n',
      i, i
    )
  end
  local img_idx = 0
  for _, info in pairs(image_map) do
    img_idx = img_idx + 1
    parts[#parts+1] = string.format(
      '    <item id="image-%d" href="images/%s" media-type="%s" />\n',
      img_idx, escape_attr(info.filename), escape_attr(info.mime)
    )
  end
  parts[#parts+1] = '  </manifest>\n'

  -- spine
  parts[#parts+1] = '  <spine>\n'
  for i = 1, #chapters do
    parts[#parts+1] = string.format('    <itemref idref="chapter-%d" />\n', i)
  end
  parts[#parts+1] = '  </spine>\n'

  parts[#parts+1] = '</package>\n'
  return table.concat(parts)
end

local function make_nav_xhtml(chapters, chapter_titles, lang, has_css)
  local parts = {}
  parts[#parts+1] = '<?xml version="1.0" encoding="UTF-8"?>\n'
  parts[#parts+1] = '<!DOCTYPE html>\n'
  parts[#parts+1] = '<html xmlns="http://www.w3.org/1999/xhtml"'
  parts[#parts+1] = ' xmlns:epub="http://www.idpf.org/2007/ops"'
  parts[#parts+1] = ' xml:lang="' .. escape_attr(lang) .. '">\n'
  parts[#parts+1] = '<head>\n'
  parts[#parts+1] = '<meta charset="utf-8" />\n'
  parts[#parts+1] = '<title>Table of Contents</title>\n'
  if has_css then
    parts[#parts+1] = '<link rel="stylesheet" type="text/css" href="styles/stylesheet.css" />\n'
  end
  parts[#parts+1] = '</head>\n'
  parts[#parts+1] = '<body>\n'
  parts[#parts+1] = '<nav epub:type="toc" id="toc">\n'
  parts[#parts+1] = '  <h1>Table of Contents</h1>\n'
  parts[#parts+1] = '  <ol>\n'
  for i = 1, #chapters do
    parts[#parts+1] = string.format(
      '    <li><a href="text/chapter-%d.xhtml">%s</a></li>\n',
      i, escape_text(chapter_titles[i])
    )
  end
  parts[#parts+1] = '  </ol>\n'
  parts[#parts+1] = '</nav>\n'
  parts[#parts+1] = '</body>\n'
  parts[#parts+1] = '</html>\n'
  return table.concat(parts)
end

local DEFAULT_CSS = [[
body { margin: 1em; font-family: serif; line-height: 1.5; }
h1, h2, h3, h4, h5, h6 { font-family: sans-serif; }
pre, code { font-family: monospace; }
blockquote { margin-left: 1.5em; margin-right: 1.5em; }
table { border-collapse: collapse; }
td, th { border: 1px solid #ccc; padding: 0.4em; }
]]

-- ---------------------------------------------------------------------------
-- ByteStringWriter entry point
-- ---------------------------------------------------------------------------

function ByteStringWriter(doc, opts)
  local meta = doc.meta or {}
  local lang = meta_string(meta, "lang") or meta_string(meta, "language") or "en"
  local title = meta_string(meta, "title") or "Untitled"

  -- Determine CSS
  local css_content = meta_string(meta, "css")
  if not css_content then
    css_content = DEFAULT_CSS
  end
  local has_css = true

  -- Split document into chapters
  local chapters = split_chapters(doc.blocks or {})

  -- Collect images from across the document
  local image_map = collect_images(doc.blocks or {})

  -- Build an image rewrite filter for pandoc.write sub-conversions
  local rewrite_filter = {
    Image = function(el)
      if el.src and image_map[el.src] then
        el.src = "../images/" .. image_map[el.src].filename
      end
      return el
    end
  }

  -- Convert each chapter to XHTML
  local chapter_xhtmls = {}
  local chapter_titles = {}
  for i, ch_blocks in ipairs(chapters) do
    chapter_titles[i] = chapter_title(ch_blocks, i)
    local sub_doc = pandoc.Pandoc(ch_blocks, {})
    sub_doc = sub_doc:walk(rewrite_filter)
    local body_html = pandoc.write(sub_doc, "html")
    chapter_xhtmls[i] = make_xhtml(chapter_titles[i], body_html, lang, has_css)
  end

  -- Fetch image data
  local image_entries = {}
  for src, info in pairs(image_map) do
    local mime, data = pandoc.mediabag.lookup(src)
    if not data then
      mime, data = pandoc.mediabag.fetch(src)
    end
    if data then
      image_entries[#image_entries+1] = {
        path = "EPUB/images/" .. info.filename,
        data = data,
      }
    end
  end

  -- Assemble ZIP entries
  local entries = {}

  -- mimetype MUST be first entry, stored uncompressed
  entries[#entries+1] = {
    path = "mimetype",
    data = "application/epub+zip",
    method = "stored",
  }

  entries[#entries+1] = {
    path = "META-INF/container.xml",
    data = make_container_xml(),
  }

  entries[#entries+1] = {
    path = "EPUB/content.opf",
    data = make_content_opf(meta, chapters, image_map, has_css),
  }

  entries[#entries+1] = {
    path = "EPUB/nav.xhtml",
    data = make_nav_xhtml(chapters, chapter_titles, lang, has_css),
  }

  if has_css then
    entries[#entries+1] = {
      path = "EPUB/styles/stylesheet.css",
      data = css_content,
    }
  end

  for i, xhtml in ipairs(chapter_xhtmls) do
    entries[#entries+1] = {
      path = string.format("EPUB/text/chapter-%d.xhtml", i),
      data = xhtml,
    }
  end

  for _, img in ipairs(image_entries) do
    entries[#entries+1] = img
  end

  return pandoc.zip.create(entries)
end
