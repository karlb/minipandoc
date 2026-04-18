-- Load vendored panluna.lua twice — once unchanged, once with the
-- proposed `rope.tag == nil` guard in unrope — and assert the
-- behavior difference. Driven by tests/panluna_fix_verification.rs,
-- which passes MP_PANLUNA_PATH.
--
-- The asserts run at filter-load time (before the chunk returns the
-- empty filter table). A failed assert surfaces as a Lua error and
-- the host minipandoc exits non-zero, failing the Rust test.

-- Panluna does `require 'pandoc'` / `'pandoc.utils'` / `'pandoc.List'`.
-- In real pandoc those are registered module loaders; in minipandoc
-- `pandoc` is a global. Bridge via package.preload so the unchanged
-- vendored source loads cleanly.
local function preload(name, mod)
  package.preload[name] = function() return mod end
end
preload("pandoc", pandoc)
preload("pandoc.utils", pandoc.utils)
preload("pandoc.List", pandoc.List)

local vendor_path = assert(os.getenv("MP_PANLUNA_PATH"),
  "MP_PANLUNA_PATH must be set by the test harness")
local f = assert(io.open(vendor_path, "r"))
local src = f:read("*a")
f:close()

-- Clear any cached load of panluna from a prior `require` so each
-- load() below gets a fresh module with its own upvalues.
package.loaded["panluna"] = nil

local unpatched = assert(load(src, "panluna-unpatched", "t"))()

-- Apply the one-line guard the PR proposes.
local patched_src, n = src:gsub(
  "elseif typ == 'table' then",
  "elseif typ == 'table' and rope.tag == nil then",
  1)
assert(n == 1,
  "expected exactly one substitution in panluna.lua; got " .. tostring(n))
local patched = assert(load(patched_src, "panluna-patched", "t"))()

-- Plain-table pandoc element constructed via our Lua API.
local para = pandoc.Para({ pandoc.Str("hi") })
assert(type(para) == "table",
  "precondition: minipandoc's element must be a plain table; got " .. type(para))
assert(para.tag == "Para",
  "precondition: tag must be Para; got " .. tostring(para.tag))

-- Unpatched behavior: element falls into the `table` branch, gets
-- recursed into, `ipairs` yields nothing over the named fields, the
-- element silently disappears.
local r_unpatched = unpatched.unrope({ para })
assert(#r_unpatched == 0,
  "expected unpatched unrope to flatten plain-table element to empty; " ..
  "got length " .. tostring(#r_unpatched))

-- Patched behavior: guard detects the `tag` field, falls through to
-- the `else` branch, element preserved as a leaf.
local r_patched = patched.unrope({ para })
assert(#r_patched == 1,
  "expected patched unrope to preserve element; got length " ..
  tostring(#r_patched))
assert(r_patched[1] == para,
  "expected patched unrope to return the exact same Para reference")
assert(r_patched[1].tag == "Para",
  "expected preserved Para's tag to survive; got " ..
  tostring(r_patched[1].tag))

-- No-op filter; real assertions ran above.
return {}
