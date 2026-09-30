-- NPRpp.lua
-- Pure Lua. Reads / writes REAPER project text (.rpp and track chunks) as a tree.
-- Lines we don't touch are kept byte-for-byte (leaf.raw), so unknown / future syntax survives a round trip.
--
--   block : { kind="block", head="<TRACK {GUID}", name="TRACK", args={"{GUID}"}, items={...} }
--   leaf  : { kind="leaf",  raw='NAME "x"', key="NAME" }      (tokens are parsed lazily: Rpp.tok(leaf))

local Rpp = {}

function Rpp.tokens(line)
  local t, i, n = {}, 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c:match("%s") then i = i + 1
    elseif c == '"' or c == "'" or c == "`" then
      local j = line:find(c, i + 1, true)
      if not j then t[#t + 1] = line:sub(i + 1); i = n + 1
      else t[#t + 1] = line:sub(i + 1, j - 1); i = j + 1 end
    else
      local j = line:find("%s", i) or (n + 1)
      t[#t + 1] = line:sub(i, j - 1); i = j
    end
  end
  return t
end

function Rpp.quote(s)
  s = tostring(s)
  if s ~= "" and not s:find("[%s\"'`]") then return s end
  if not s:find('"', 1, true) then return '"' .. s .. '"' end
  if not s:find("'", 1, true) then return "'" .. s .. "'" end
  return "`" .. s:gsub("`", "'") .. "`"
end

function Rpp.num(x)
  if x == math.floor(x) and math.abs(x) < 1e15 then return string.format("%d", x) end
  return string.format("%.14g", x)
end

function Rpp.parse_fragment(text)
  local root = { kind = "root", items = {} }
  local stack = { root }
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local s = line:match("^%s*(.-)%s*$")
    if s ~= "" then
      local top = stack[#stack]
      if s == ">" then
        if #stack > 1 then table.remove(stack) end
      elseif s:sub(1, 1) == "<" then
        local toks = Rpp.tokens(s:sub(2))
        local b = { kind = "block", head = s, name = toks[1] or "", args = { table.unpack(toks, 2) }, items = {} }
        top.items[#top.items + 1] = b
        stack[#stack + 1] = b
      else
        top.items[#top.items + 1] = { kind = "leaf", raw = s, key = s:match("^(%S+)") }
      end
    end
  end
  return root.items
end

-- whole project (or one chunk): returns the first top-level block
function Rpp.parse(text)
  local items = Rpp.parse_fragment(text)
  for _, n in ipairs(items) do if n.kind == "block" then return n end end
  return nil, "no block found"
end

local function emit(node, depth, out)
  local pad = string.rep("  ", depth)
  if node.kind == "leaf" then out[#out + 1] = pad .. node.raw
  else
    out[#out + 1] = pad .. node.head
    for _, c in ipairs(node.items) do emit(c, depth + 1, out) end
    out[#out + 1] = pad .. ">"
  end
end

function Rpp.serialize(node)
  local out = {}
  emit(node, 0, out)
  return table.concat(out, "\n") .. "\n"
end

-- serialize a list of nodes (fragment)
function Rpp.serialize_list(nodes)
  local out = {}
  for _, n in ipairs(nodes) do emit(n, 0, out) end
  return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- access
--------------------------------------------------------------------------------
function Rpp.tok(leaf)
  if not leaf.tk then leaf.tk = Rpp.tokens(leaf.raw) end
  return leaf.tk
end

function Rpp.leaf(node, key)
  for _, c in ipairs(node.items) do if c.kind == "leaf" and c.key == key then return c end end
end

function Rpp.block(node, name)
  for _, c in ipairs(node.items) do if c.kind == "block" and c.name == name then return c end end
end

function Rpp.blocks(node, name)
  local out = {}
  for _, c in ipairs(node.items) do if c.kind == "block" and c.name == name then out[#out + 1] = c end end
  return out
end

function Rpp.leaves(node, key)
  local out = {}
  for _, c in ipairs(node.items) do if c.kind == "leaf" and c.key == key then out[#out + 1] = c end end
  return out
end

function Rpp.new_leaf(key, ...)
  local parts = { key }
  for _, v in ipairs({ ... }) do parts[#parts + 1] = type(v) == "number" and Rpp.num(v) or Rpp.quote(v) end
  return { kind = "leaf", raw = table.concat(parts, " "), key = key }
end

function Rpp.new_block(head_name, ...)
  local parts = { head_name }
  local args = {}
  for _, v in ipairs({ ... }) do
    parts[#parts + 1] = type(v) == "number" and Rpp.num(v) or Rpp.quote(v)
    args[#args + 1] = tostring(v)
  end
  return { kind = "block", head = "<" .. table.concat(parts, " "), name = head_name, args = args, items = {} }
end

-- replaces the first leaf with this key, or appends one
function Rpp.set_leaf(node, key, ...)
  local new = Rpp.new_leaf(key, ...)
  for i, c in ipairs(node.items) do
    if c.kind == "leaf" and c.key == key then node.items[i] = new; return new end
  end
  node.items[#node.items + 1] = new
  return new
end

-- same, but a new leaf is inserted right after `after_key` (or appended if that is missing)
function Rpp.set_leaf_after(node, key, after_key, ...)
  local new = Rpp.new_leaf(key, ...)
  for i, c in ipairs(node.items) do
    if c.kind == "leaf" and c.key == key then node.items[i] = new; return new end
  end
  local pos = #node.items + 1
  for i, c in ipairs(node.items) do
    if c.kind == "leaf" and c.key == after_key then pos = i + 1; break end
  end
  table.insert(node.items, pos, new)
  return new
end

function Rpp.remove(node, child)
  for i, c in ipairs(node.items) do if c == child then table.remove(node.items, i); return true end end
end

-- depth-first walk; fn(node, parent, path) ; return false to skip children
function Rpp.walk(node, fn, parent, path)
  path = path or {}
  if fn(node, parent, path) == false then return end
  if node.kind == "block" then
    path[#path + 1] = node
    for _, c in ipairs(node.items) do Rpp.walk(c, fn, node, path) end
    path[#path] = nil
  end
end

function Rpp.clone(node)
  return Rpp.parse_fragment(Rpp.serialize_list({ node }))[1]
end

--------------------------------------------------------------------------------
-- small helpers used by several modules
--------------------------------------------------------------------------------
function Rpp.is_abs(p) return (p:match("^/") or p:match("^%a:[/\\]") or p:match("^~") or p:match("^\\\\")) ~= nil end

function Rpp.dirname(p) return (p:match("^(.*)[/\\][^/\\]*$")) or "" end
function Rpp.basename(p) return (p:match("([^/\\]*)$")) end
function Rpp.join(a, b)
  if a == nil or a == "" then return b end
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

-- normalise "a/./b/../c" (forward slashes only; enough for media paths)
function Rpp.normpath(p)
  local abs = p:sub(1, 1) == "/"
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." and #parts > 0 and parts[#parts] ~= ".." then parts[#parts] = nil
    elseif seg ~= "." then parts[#parts + 1] = seg end
  end
  return (abs and "/" or "") .. table.concat(parts, "/")
end

-- a minimal, valid, empty project (used when a group of tracks is turned into a project for the first time)
function Rpp.skeleton(opts)
  opts = opts or {}
  local root = Rpp.new_block("REAPER_PROJECT", 0.1, opts.version or "7.0", os.time())
  local it = root.items
  it[#it + 1] = Rpp.new_leaf("RIPPLE", 0, 0)
  it[#it + 1] = Rpp.new_leaf("SAMPLERATE", opts.samplerate or 44100, 0, 0)
  it[#it + 1] = Rpp.new_leaf("TEMPO", opts.bpm or 120, opts.num or 4, opts.den or 4)
  it[#it + 1] = Rpp.new_leaf("PROJOFFS", 0, 0, 0)
  it[#it + 1] = Rpp.new_leaf("MASTER_VOLUME", 1, 0, -1, -1, 1)
  return root
end

return Rpp
