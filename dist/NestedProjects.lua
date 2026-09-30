-- @description NestedProjects: PROJECT folder tracks that can be attached to / detached from separate REAPER projects
-- @version 0.1.3
-- @author _n_plugins
-- @about
--   Run this action to open the NestedProjects window (needs ReaImGui: ReaPack > ReaTeam Extensions).
--   Attach a .rpp as a PROJECT folder track, edit it here, or Detach it into its own REAPER instance (own audio device,
--   own transport) and Reattach it later. Edits made on both sides are merged.
--   Run the action again while the window is open to close it.
--   Keep NestedProjectsChild.lua in the same folder: it is what runs inside detached children.
-- BUNDLED BUILD of NestedProjects v0.1.3 - edit the files in src/, not this one.
local __preload = package.preload
__preload["NPVersion"] = function(...)
return { VERSION = "0.1.3" }

end
__preload["NPRpp"] = function(...)
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

end
__preload["NPXform"] = function(...)
-- NPXform.lua
-- Pure Lua. Moves project content between the two "spaces":
--
--   child space  = as stored in the child .rpp   (its own time zero, its own tempo map, relative media paths)
--   parent space = as it lives inside the parent (shifted by offset + project start offset, time-based, absolute media)
--
-- forward()  child  -> parent      backward()  parent -> child
-- Everything that is NOT listed in POLICY is left alone (and kept byte-for-byte).

local Rpp = require("NPRpp")

local X = {}

-- The table from multi-project.md as data: what happens to each project-level feature on attach.
-- status: "done" implemented here, "glue" done by NPReaper (needs REAPER), "ignore" dropped on purpose, "todo" not yet
X.POLICY = {
  { "Tempo map / time signatures", "baked: tracks forced time-based, MIDI sources get 'ignore project tempo'", "done" },
  { "Render settings",             "ignored (kept untouched in the child file)",                      "ignore" },
  { "Project automation",          "track envelopes shifted; master envelopes -> PROJECT track",       "done" },
  { "Master FX",                   "copied to the PROJECT track FX chain",                             "done" },
  { "Master volume / pan",         "copied to the PROJECT track",                                      "done" },
  { "Master routing / sends",      "tracks inside the folder send to the folder; hardware outs kept",  "todo" },
  { "Markers",                     "imported (shifted), owned by the PROJECT",                         "done" },
  { "Regions",                     "imported (shifted), owned by the PROJECT",                         "done" },
  { "Project start offset",        "baked into all times",                                             "done" },
  { "Sample rate",                 "ignored; parent wins",                                             "ignore" },
  { "Media paths",                 "relative paths resolved to absolute; made relative again on export","done" },
  { "Project timebase",            "tracks forced to time",                                            "done" },
  { "Transport state",             "ignored",                                                          "ignore" },
  { "MIDI hardware routing",       "kept as is; check by hand",                                        "todo" },
  { "Separate project identity",   "replaced by the PROJECT track (P_EXT)",                            "glue" },
}

--------------------------------------------------------------------------------
-- ids
--------------------------------------------------------------------------------
local function fnv(s, seed)
  local h = seed or 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h
end

-- deterministic GUID-shaped id from a seed string (used when a track/item/marker has none)
function X.new_guid(seed)
  local a, b, c, d = fnv(seed, 1), fnv(seed, 2), fnv(seed, 3), fnv(seed, 4)
  return string.format("{%08X-%04X-%04X-%04X-%08X%04X}", a, b & 0xFFFF, (b >> 16) & 0xFFFF, c & 0xFFFF, d, (c >> 16) & 0xFFFF)
end

-- random GUID (only for genuinely new objects, e.g. the PROJECT track); `rnd` may be injected for tests
function X.random_guid(rnd)
  rnd = rnd or math.random
  local function h(n) local s = {} for i = 1, n do s[i] = string.format("%X", rnd(0, 15)) end return table.concat(s) end
  return "{" .. h(8) .. "-" .. h(4) .. "-" .. h(4) .. "-" .. h(4) .. "-" .. h(12) .. "}"
end

function X.track_guid(track) return track.args[1] end

--------------------------------------------------------------------------------
-- reading a whole project
--------------------------------------------------------------------------------
function X.tempo_at(tempo, t)
  if not tempo then return 120, 4, 4 end
  local bpm = tempo.bpm or 120
  if tempo.pts and #tempo.pts > 0 then
    local p1, p2
    for _, p in ipairs(tempo.pts) do
      if p.t <= t then p1 = p else p2 = p; break end
    end
    if p1 then
      bpm = p1.bpm
      -- linear shape (0) ramps to the next point
      if p2 and p1.shape == 0 and p2.t > p1.t then bpm = p1.bpm + (p2.bpm - p1.bpm) * (t - p1.t) / (p2.t - p1.t) end
    else bpm = tempo.pts[1].bpm end
  end
  return bpm, tempo.num or 4, tempo.den or 4
end

local function read_tempo(root)
  local tempo = { bpm = 120, num = 4, den = 4, pts = {} }
  local l = Rpp.leaf(root, "TEMPO")
  if l then
    local t = Rpp.tok(l)
    tempo.bpm, tempo.num, tempo.den = tonumber(t[2]) or 120, tonumber(t[3]) or 4, tonumber(t[4]) or 4
  end
  local env = Rpp.block(root, "TEMPOENVEX")
  if env then
    for _, p in ipairs(Rpp.leaves(env, "PT")) do
      local t = Rpp.tok(p)
      tempo.pts[#tempo.pts + 1] = { t = tonumber(t[2]) or 0, bpm = tonumber(t[3]) or tempo.bpm, shape = tonumber(t[4]) or 1 }
    end
  end
  return tempo
end

local ENV_PAT = { "^VOLENV%d*$", "^PANENV%d*$", "^MUTEENV$", "^WIDTHENV%d*$" }
local function is_master_env(name)
  for _, p in ipairs(ENV_PAT) do if name:match(p) then return true end end
  return false
end

-- MARKER lines  ->  { {idx,pos,rgnend,name,isrgn,color,guid}, ... }
function X.read_markers(root)
  local out, open = {}, {}
  for _, l in ipairs(Rpp.leaves(root, "MARKER")) do
    local t = Rpp.tok(l)
    local idx, pos = tonumber(t[2]), tonumber(t[3])
    if idx and pos then
      local name, flag, color = t[4] or "", tonumber(t[5]) or 0, tonumber(t[6]) or 0
      local guid
      for i = 7, #t do if t[i]:match("^{.*}$") then guid = t[i] end end
      if flag & 1 == 1 then
        if open[idx] then open[idx].rgnend = pos; open[idx] = nil
        else
          local m = { idx = idx, pos = pos, rgnend = pos, name = name, isrgn = true, color = color, guid = guid }
          open[idx] = m; out[#out + 1] = m
        end
      else
        out[#out + 1] = { idx = idx, pos = pos, rgnend = pos, name = name, isrgn = false, color = color, guid = guid }
      end
    end
  end
  for _, m in ipairs(out) do
    if not m.guid then m.guid = X.new_guid("marker:" .. m.idx .. ":" .. (m.isrgn and "r" or "m") .. ":" .. m.name) end
  end
  return out
end

function X.marker_leaves(m)
  local function line(pos, name)
    return Rpp.new_leaf("MARKER", m.idx, pos, name, m.isrgn and 1 or 0, m.color or 0, 1, m.isrgn and "R" or "B", m.guid, 0)
  end
  if m.isrgn then return { line(m.pos, m.name), line(m.rgnend, "") } end
  return { line(m.pos, m.name) }
end

function X.shift_markers(list, dt)
  local out = {}
  for i, m in ipairs(list) do
    local c = {}
    for k, v in pairs(m) do c[k] = v end
    c.pos = m.pos + dt
    c.rgnend = m.rgnend + dt
    out[i] = c
  end
  return out
end

-- replace all MARKER lines of a project root by `markers`, placed before the first TRACK
function X.write_markers(root, markers)
  for i = #root.items, 1, -1 do
    local c = root.items[i]
    if c.kind == "leaf" and c.key == "MARKER" then table.remove(root.items, i) end
  end
  local pos = #root.items + 1
  for i, c in ipairs(root.items) do if c.kind == "block" and c.name == "TRACK" then pos = i; break end end
  for _, m in ipairs(markers) do
    for _, l in ipairs(X.marker_leaves(m)) do table.insert(root.items, pos, l); pos = pos + 1 end
  end
end

-- pseudo track "MASTER": VOLPAN + FXCHAIN + master envelopes, so master state can be diffed/merged like a track
function X.master_pseudo(root)
  local n = Rpp.new_block("TRACK", "MASTER")
  local mv = Rpp.leaf(root, "MASTER_VOLUME")
  if mv then
    local t = Rpp.tok(mv)
    n.items[#n.items + 1] = Rpp.new_leaf("VOLPAN", table.unpack(t, 2))
  end
  local ml = Rpp.block(root, "MASTERFXLIST")
  local chain = ml and Rpp.block(ml, "FXCHAIN")
  if chain then n.items[#n.items + 1] = Rpp.clone(chain) end
  for _, c in ipairs(root.items) do
    if c.kind == "block" and is_master_env(c.name) then n.items[#n.items + 1] = Rpp.clone(c) end
  end
  return n
end

function X.read_project(text)
  local root, err = Rpp.parse(text)
  if not root then return nil, err end
  if root.name ~= "REAPER_PROJECT" then return nil, "not a REAPER project (" .. tostring(root.name) .. ")" end
  local view = { root = root, tracks = {}, tempo = read_tempo(root) }
  local pl = Rpp.leaf(root, "PROJOFFS")
  view.projoffs = pl and tonumber(Rpp.tok(pl)[2]) or 0
  local sr = Rpp.leaf(root, "SAMPLERATE")
  view.samplerate = sr and tonumber(Rpp.tok(sr)[2]) or nil
  for i, tr in ipairs(Rpp.blocks(root, "TRACK")) do
    if not tr.args[1] or not tr.args[1]:match("^{.*}$") then
      local nm = Rpp.leaf(tr, "NAME")
      tr.args[1] = X.new_guid("track:" .. i .. ":" .. (nm and nm.raw or ""))
      tr.head = "<TRACK " .. tr.args[1]
    end
    view.tracks[#view.tracks + 1] = tr
  end
  view.master = X.master_pseudo(root)
  view.markers = X.read_markers(root)
  return view
end

-- writes master state back into a project root (child space)
function X.apply_master(root, pseudo)
  local vp = Rpp.leaf(pseudo, "VOLPAN")
  if vp then
    local t = Rpp.tok(vp)
    Rpp.set_leaf(root, "MASTER_VOLUME", table.unpack(t, 2))
  end
  local chain = Rpp.block(pseudo, "FXCHAIN")
  local ml = Rpp.block(root, "MASTERFXLIST")
  if chain then
    if not ml then
      ml = Rpp.new_block("MASTERFXLIST")
      local pos = #root.items + 1
      for i, c in ipairs(root.items) do if c.kind == "block" and c.name == "TRACK" then pos = i; break end end
      table.insert(root.items, pos, ml)
    end
    local old = Rpp.block(ml, "FXCHAIN")
    if old then Rpp.remove(ml, old) end
    ml.items[#ml.items + 1] = Rpp.clone(chain)
  elseif ml then
    local old = Rpp.block(ml, "FXCHAIN")
    if old then Rpp.remove(ml, old) end
  end
  for i = #root.items, 1, -1 do
    local c = root.items[i]
    if c.kind == "block" and is_master_env(c.name) then table.remove(root.items, i) end
  end
  local pos = #root.items + 1
  for i, c in ipairs(root.items) do if c.kind == "block" and c.name == "TRACK" then pos = i; break end end
  for _, c in ipairs(pseudo.items) do
    if c.kind == "block" and is_master_env(c.name) then table.insert(root.items, pos, Rpp.clone(c)); pos = pos + 1 end
  end
end

--------------------------------------------------------------------------------
-- forward / backward for one track (or the MASTER pseudo track)
--------------------------------------------------------------------------------
local function shift_leaf(leaf, tokidx, dt)
  local t = Rpp.tok(leaf)
  local v = tonumber(t[tokidx])
  if not v then return end
  local nt = { table.unpack(t) }
  nt[tokidx] = Rpp.num(v + dt)
  local parts = {}
  for i, s in ipairs(nt) do parts[i] = (i == 1) and s or (tonumber(s) and s or Rpp.quote(s)) end
  leaf.raw = table.concat(parts, " ")
  leaf.tk = nil
end

local function set_first_token_after_key(leaf, tokidx, value)
  local t = Rpp.tok(leaf)
  local nt = { table.unpack(t) }
  nt[tokidx] = value
  local parts = {}
  for i, s in ipairs(nt) do parts[i] = (i == 1) and s or (tonumber(s) and s or Rpp.quote(s)) end
  leaf.raw = table.concat(parts, " ")
  leaf.tk = nil
end

-- REAPER always writes FILE paths in quotes
local function qfile(p)
  if not p:find('"', 1, true) then return '"' .. p .. '"' end
  return Rpp.quote(p)
end

local function in_env(path)
  for _, b in ipairs(path) do if b.name:find("ENV", 1, true) then return true end end
  return false
end

-- ctx: { offset, projoffs, media_dir, tempo }
local function process(track, ctx, dir, st)
  local shift = dir * ((ctx.offset or 0) + (ctx.projoffs or 0))
  local media = ctx.media_dir and Rpp.normpath(ctx.media_dir) or nil

  ctx.beat_orig = ctx.beat_orig or {}
  ctx.baked = ctx.baked or {}
  local tguid = track.args[1]

  -- track timebase: forced to "time" going in, put back exactly as it was going out
  if track.args[1] ~= "MASTER" then
    local b = Rpp.leaf(track, "BEAT")
    if dir > 0 then
      if b then
        local v = Rpp.tok(b)[2] or "0"
        if v ~= "0" then ctx.beat_orig[tguid] = v; set_first_token_after_key(b, 2, "0") end
      else
        ctx.beat_orig[tguid] = "ABSENT"
        Rpp.set_leaf_after(track, "BEAT", "NAME", 0)
      end
    else
      local o = ctx.beat_orig[tguid]
      if o == "ABSENT" then if b then Rpp.remove(track, b) end
      elseif o and b then set_first_token_after_key(b, 2, o) end
    end
  end

  local function do_item(item)
    local pl = Rpp.leaf(item, "POSITION")
    local orig_pos = pl and tonumber(Rpp.tok(pl)[2]) or 0
    local ll = Rpp.leaf(item, "LENGTH")
    local len = ll and tonumber(Rpp.tok(ll)[2]) or 0
    if pl and shift ~= 0 then shift_leaf(pl, 2, shift) end
    local ig = Rpp.leaf(item, "IGUID")
    local iguid = ig and Rpp.tok(ig)[2] or nil
    local b = Rpp.leaf(item, "BEAT")
    if dir > 0 then
      if b then
        local v = Rpp.tok(b)[2] or "0"
        if v == "1" or v == "2" then
          st.beat = st.beat + 1
          if iguid then ctx.beat_orig[iguid] = v end
          set_first_token_after_key(b, 2, "0")
        end
      end
    elseif b and iguid and ctx.beat_orig[iguid] then
      set_first_token_after_key(b, 2, ctx.beat_orig[iguid])
    end
    Rpp.walk(item, function(n, parent, path)
      if n.kind == "block" and n.name == "SOURCE" then
        local f = Rpp.leaf(n, "FILE")
        if f and media then
          local p = Rpp.tok(f)[2]
          if p then
            if dir > 0 and not Rpp.is_abs(p) then
              local rest = { table.unpack(Rpp.tok(f), 3) }
              local raw = "FILE " .. qfile(Rpp.normpath(Rpp.join(media, p)))
              for _, x in ipairs(rest) do raw = raw .. " " .. Rpp.quote(x) end
              f.raw = raw; f.tk = nil; st.files = st.files + 1
            elseif dir < 0 and p:sub(1, #media + 1) == media .. "/" then
              local rest = { table.unpack(Rpp.tok(f), 3) }
              local raw = "FILE " .. qfile(p:sub(#media + 2))
              for _, x in ipairs(rest) do raw = raw .. " " .. Rpp.quote(x) end
              f.raw = raw; f.tk = nil
            end
          end
        end
        -- MIDI: keep the musical content sounding as in the child by fixing the tempo it is interpreted with
        if dir > 0 and n.args[1] == "MIDI" and ctx.tempo then
          local ig = Rpp.leaf(n, "IGNTEMPO")
          if not ig or (Rpp.tok(ig)[2] or "0") == "0" then
            local bpm, num, den = X.tempo_at(ctx.tempo, orig_pos)
            local new = Rpp.new_leaf("IGNTEMPO", 1, bpm, num, den)
            if ig then
              for i, c in ipairs(n.items) do if c == ig then n.items[i] = new end end
            else
              local at = 1
              for i, c in ipairs(n.items) do if c.kind == "leaf" and c.key == "HASDATA" then at = i + 1 end end
              table.insert(n.items, at, new)
            end
            st.midi = st.midi + 1
            if iguid then ctx.baked[iguid] = true end
            for _, p in ipairs(ctx.tempo.pts or {}) do
              if p.t > orig_pos and p.t < orig_pos + len then st.midi_var = st.midi_var + 1; break end
            end
          end
        end
        -- undo our own bake on the way out (only for sources we baked ourselves)
        if dir < 0 and n.args[1] == "MIDI" and iguid and ctx.baked[iguid] then
          local ig2 = Rpp.leaf(n, "IGNTEMPO")
          if ig2 then Rpp.remove(n, ig2) end
        end
        return false
      end
    end, item, {})
  end

  local function visit(node, path)
    if node.kind == "leaf" then
      if node.key == "PT" and shift ~= 0 and in_env(path) then shift_leaf(node, 2, shift) end
      if node.key == "POSITION" and shift ~= 0 and in_env(path) then shift_leaf(node, 2, shift) end
      return
    end
    if node.name == "ITEM" then do_item(node); -- item contents (take envelopes) below
      path[#path + 1] = node
      for _, c in ipairs(node.items) do if c.kind == "block" then visit(c, path) end end
      path[#path] = nil
      return
    end
    if node.name == "POOLEDENVINST" then st.pooled = (st.pooled or 0) + 1 end
    path[#path + 1] = node
    for _, c in ipairs(node.items) do visit(c, path) end
    path[#path] = nil
  end
  for _, c in ipairs(track.items) do visit(c, {}) end
end

function X.forward(track, ctx)
  local st = { beat = 0, midi = 0, midi_var = 0, files = 0 }
  process(track, ctx, 1, st)
  return st
end

function X.backward(track, ctx)
  local st = { beat = 0, midi = 0, midi_var = 0, files = 0 }
  process(track, ctx, -1, st)
  return st
end

-- makes every relative media path of a track absolute (used once at attach, so the working copy can live anywhere)
function X.absolutize(track, media_dir)
  local media = Rpp.normpath(media_dir)
  local n = 0
  Rpp.walk(track, function(node)
    if node.kind == "block" and node.name == "SOURCE" then
      local f = Rpp.leaf(node, "FILE")
      local p = f and Rpp.tok(f)[2]
      if p and not Rpp.is_abs(p) then
        local rest = { table.unpack(Rpp.tok(f), 3) }
        local raw = "FILE " .. qfile(Rpp.normpath(Rpp.join(media, p)))
        for _, x in ipairs(rest) do raw = raw .. " " .. Rpp.quote(x) end
        f.raw = raw; f.tk = nil; n = n + 1
      end
    end
  end)
  return n
end

--------------------------------------------------------------------------------
-- the PROJECT folder track (parent space)
--------------------------------------------------------------------------------
-- pseudo: forward-transformed master pseudo track
function X.make_folder(guid, name, pseudo, extra)
  local n = Rpp.new_block("TRACK", guid)
  local it = n.items
  it[#it + 1] = Rpp.new_leaf("NAME", name)
  if extra and extra.color then it[#it + 1] = Rpp.new_leaf("PEAKCOL", extra.color) end
  it[#it + 1] = Rpp.new_leaf("ISBUS", 1, 1)
  if pseudo then
    for _, c in ipairs(pseudo.items) do it[#it + 1] = Rpp.clone(c) end
  end
  return n
end

-- read the master-like state back from a folder track (parent space), then undo the time shift
function X.pseudo_from_folder(folder, ctx)
  local n = Rpp.new_block("TRACK", "MASTER")
  local vp = Rpp.leaf(folder, "VOLPAN")
  if vp then n.items[#n.items + 1] = Rpp.clone(vp) end
  local chain = Rpp.block(folder, "FXCHAIN")
  if chain then n.items[#n.items + 1] = Rpp.clone(chain) end
  for _, c in ipairs(folder.items) do
    if c.kind == "block" and is_master_env(c.name) then n.items[#n.items + 1] = Rpp.clone(c) end
  end
  X.backward(n, ctx)
  return n
end

-- human readable list of things the attach cannot carry over (shown to the user)
function X.report(view, parent_info)
  local out = {}
  parent_info = parent_info or {}
  if view.samplerate and parent_info.samplerate and view.samplerate ~= parent_info.samplerate then
    out[#out + 1] = string.format("sample rate %d differs from parent (%d): parent wins", view.samplerate, parent_info.samplerate)
  end
  if #view.tempo.pts > 0 then out[#out + 1] = string.format("tempo envelope with %d points is baked (not imported)", #view.tempo.pts) end
  if Rpp.leaf(view.root, "RENDER_FILE") then out[#out + 1] = "render settings ignored" end
  return out
end

return X

end
__preload["NPSnap"] = function(...)
-- NPSnap.lua
-- Pure Lua. Turns project content into a flat, ID-keyed model that can be diffed / merged field by field,
-- and back into rpp nodes.
--
--   entity = { id=, keys={ordered prop keys}, vals={ key -> raw text } }
--   model  = { tracks={id->ent}, order={ids}, items={id->ent}, item_order={trackid->{ids}},
--              markers={id->ent}, marker_order={ids}, master=ent|nil }
--
-- Property keys:  "NAME"                a plain line of the track / item
--                 "<FXCHAIN"            a nested block (compared as a whole)
--                 "AUXRECV:{guid}"      a receive, identified by its SOURCE TRACK GUID (not by index)
--                 "t1:NAME"             a line that belongs to take #1 of an item
--                 "@parent" / "@track"  structure (folder parent of a track / owning track of an item)
--                 "ISBUS", "<ITEMS"     placeholders that fix the position of folder info / of the items

local Rpp = require("NPRpp")
local X = require("NPXform")

local Snap = {}

function Snap.empty()
  return { tracks = {}, order = {}, items = {}, item_order = {}, markers = {}, marker_order = {} }
end

local function put(ent, key, val)
  local k, n = key, 1
  while ent.vals[k] ~= nil do n = n + 1; k = key .. "#" .. n end
  ent.keys[#ent.keys + 1] = k
  ent.vals[k] = val
end

local function join_tokens(t, from)
  local parts = {}
  for i = from, #t do parts[#parts + 1] = (tonumber(t[i]) and t[i]) or Rpp.quote(t[i]) end
  return table.concat(parts, " ")
end

local function build_item(item, track_guid, n, model)
  local ig = Rpp.leaf(item, "IGUID")
  local id = ig and Rpp.tok(ig)[2]
  local ent = { keys = {}, vals = {} }
  if not id then
    local pl = Rpp.leaf(item, "POSITION")
    id = X.new_guid("item:" .. track_guid .. ":" .. n .. ":" .. (pl and pl.raw or ""))
    put(ent, "IGUID", "IGUID " .. id)
  end
  ent.id = id
  put(ent, "@track", track_guid)
  local take = 0
  for _, c in ipairs(item.items) do
    if c.kind == "leaf" then
      if c.key == "TAKE" then take = take + 1 end
      local k = (take > 0) and ("t" .. take .. ":" .. c.key) or c.key
      put(ent, k, c.raw)
    else
      local k = "<" .. c.name
      if take > 0 then k = "t" .. take .. ":" .. k end
      put(ent, k, Rpp.serialize(c))
    end
  end
  model.items[id] = ent
  return id
end

local function build_track(tr, guid_at, parent, model)
  local guid = tr.args[1]
  local ent = { id = guid, keys = {}, vals = {} }
  local items_seen, item_ids = false, {}
  local n_item = 0
  for _, c in ipairs(tr.items) do
    if c.kind == "leaf" then
      if c.key == "ISBUS" then
        put(ent, "ISBUS", "")
      elseif c.key == "AUXRECV" then
        local t = Rpp.tok(c)
        local src = guid_at[(tonumber(t[2]) or -1) + 1]
        put(ent, "AUXRECV:" .. (src or ("?" .. tostring(t[2]))), join_tokens(t, 3))
      else
        put(ent, c.key, c.raw)
      end
    elseif c.name == "ITEM" then
      n_item = n_item + 1
      if not items_seen then items_seen = true; put(ent, "<ITEMS", "") end
      item_ids[#item_ids + 1] = build_item(c, guid, n_item, model)
    else
      put(ent, "<" .. c.name, Rpp.serialize(c))
    end
  end
  put(ent, "@parent", parent or "")
  model.tracks[guid] = ent
  model.order[#model.order + 1] = guid
  model.item_order[guid] = item_ids
end

-- view = { tracks={nodes in project order}, master=node|nil, markers={...} }  (all in ONE space)
function Snap.build(view)
  local model = Snap.empty()
  local guid_at = {}
  for i, tr in ipairs(view.tracks) do guid_at[i] = tr.args[1] end
  -- folder parents from the ISBUS deltas (a pop below zero = the PROJECT folder closing: ignored)
  local stack = {}
  for _, tr in ipairs(view.tracks) do
    local parent = stack[#stack]
    build_track(tr, guid_at, parent, model)
    local isb = Rpp.leaf(tr, "ISBUS")
    local d = isb and tonumber(Rpp.tok(isb)[3]) or 0
    if d > 0 then for _ = 1, d do stack[#stack + 1] = tr.args[1] end
    elseif d < 0 then for _ = 1, -d do stack[#stack] = nil end end
  end
  if view.master then
    local saved_o, saved_i = model.order, model.item_order
    model.order, model.item_order = {}, {}
    build_track(view.master, {}, nil, model)
    model.master = model.tracks["MASTER"]
    model.tracks["MASTER"] = nil
    model.order, model.item_order = saved_o, saved_i
    model.master.vals["@parent"] = nil
    for i, k in ipairs(model.master.keys) do if k == "@parent" then table.remove(model.master.keys, i); break end end
  end
  for _, m in ipairs(view.markers or {}) do
    local ent = { id = m.guid, keys = {}, vals = {} }
    put(ent, "idx", Rpp.num(m.idx))
    put(ent, "pos", Rpp.num(m.pos))
    put(ent, "rgnend", Rpp.num(m.rgnend))
    put(ent, "name", m.name or "")
    put(ent, "isrgn", m.isrgn and "1" or "0")
    put(ent, "color", Rpp.num(m.color or 0))
    model.markers[m.guid] = ent
    model.marker_order[#model.marker_order + 1] = m.guid
  end
  return model
end

--------------------------------------------------------------------------------
-- rendering
--------------------------------------------------------------------------------
local function parse_into(node, text)
  for _, n in ipairs(Rpp.parse_fragment(text)) do node.items[#node.items + 1] = n end
end

local function unprefix(key)
  return (key:gsub("^t%d+:", ""))
end

-- opts: index_base (index of the first track in the target project, for AUXRECV), end_level (0 standalone, -1 inside a PROJECT folder)
function Snap.render(model, opts)
  opts = opts or {}
  local base = opts.index_base or 0
  local end_level = opts.end_level or 0

  local kids = {}
  local function alive(id) return model.tracks[id] ~= nil end
  for _, id in ipairs(model.order) do
    if alive(id) then
      local p = model.tracks[id].vals["@parent"] or ""
      if p == id or not alive(p) then p = "" end
      kids[p] = kids[p] or {}
      kids[p][#kids[p] + 1] = id
    end
  end
  local flat, lvl, seen = {}, {}, {}
  local function dfs(id, l)
    if seen[id] then return end
    seen[id] = true
    flat[#flat + 1] = id; lvl[#lvl + 1] = l
    for _, k in ipairs(kids[id] or {}) do dfs(k, l + 1) end
  end
  for _, id in ipairs(kids[""] or {}) do dfs(id, 0) end
  for _, id in ipairs(model.order) do if alive(id) and not seen[id] then dfs(id, 0) end end   -- cycles: never lose a track

  local index_of = {}
  for i, id in ipairs(flat) do index_of[id] = base + i - 1 end

  local tracks, dropped_sends = {}, 0
  for i, id in ipairs(flat) do
    local ent = model.tracks[id]
    local node = Rpp.new_block("TRACK", id)
    local has_kids = kids[id] and #kids[id] > 0
    local d
    if has_kids then d = 1
    else d = ((i < #flat) and lvl[i + 1] or end_level) - lvl[i] end
    local isbus = Rpp.new_leaf("ISBUS", d > 0 and 1 or (d < 0 and 2 or 0), d)
    local seen_isbus, seen_items = false, false

    local function add_items()
      for _, iid in ipairs(model.item_order[id] or {}) do
        local ie = model.items[iid]
        if ie then
          local inode = Rpp.new_block("ITEM")
          for _, k in ipairs(ie.keys) do
            if k:sub(1, 1) ~= "@" then parse_into(inode, ie.vals[k]) end
          end
          node.items[#node.items + 1] = inode
        end
      end
    end

    for _, k in ipairs(ent.keys) do
      local v = ent.vals[k]
      if k == "ISBUS" then node.items[#node.items + 1] = isbus; seen_isbus = true
      elseif k == "<ITEMS" then add_items(); seen_items = true
      elseif k:sub(1, 1) == "@" then -- structure only
      elseif k:sub(1, 8) == "AUXRECV:" then
        local src = k:sub(9):gsub("#%d+$", "")
        local idx = index_of[src]
        if src:sub(1, 1) == "?" then idx = tonumber(src:sub(2)) end
        if idx then
          node.items[#node.items + 1] = { kind = "leaf", key = "AUXRECV", raw = "AUXRECV " .. Rpp.num(idx) .. " " .. v }
        else dropped_sends = dropped_sends + 1 end
      else parse_into(node, v) end
    end
    if not seen_isbus then
      local pos = 1
      for j, c in ipairs(node.items) do if c.kind == "leaf" and c.key == "NAME" then pos = j + 1 end end
      table.insert(node.items, pos, isbus)
    end
    if not seen_items then add_items() end
    tracks[#tracks + 1] = node
  end

  local out = { tracks = tracks, index_of = index_of, dropped_sends = dropped_sends, flat = flat }

  if model.master then
    local node = Rpp.new_block("TRACK", "MASTER")
    for _, k in ipairs(model.master.keys) do
      if k:sub(1, 1) ~= "@" then parse_into(node, model.master.vals[k]) end
    end
    out.master = node
  end

  out.markers = {}
  for _, id in ipairs(model.marker_order) do
    local e = model.markers[id]
    if e then
      out.markers[#out.markers + 1] = {
        guid = id, idx = tonumber(e.vals.idx), pos = tonumber(e.vals.pos), rgnend = tonumber(e.vals.rgnend),
        name = e.vals.name, isrgn = e.vals.isrgn == "1", color = tonumber(e.vals.color) or 0,
      }
    end
  end
  return out
end

-- same content?
function Snap.ent_equal(a, b)
  if not a or not b then return a == b end
  for k, v in pairs(a.vals) do if b.vals[k] ~= v then return false end end
  for k, v in pairs(b.vals) do if a.vals[k] ~= v then return false end end
  return true
end

local function same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function same_store(a, b)
  for id, e in pairs(a) do if not Snap.ent_equal(e, b[id]) then return false end end
  for id in pairs(b) do if not a[id] then return false end end
  return true
end

-- structurally identical models (content and order)?
function Snap.equal(a, b)
  if not same_list(a.order, b.order) or not same_list(a.marker_order, b.marker_order) then return false end
  if not same_store(a.tracks, b.tracks) or not same_store(a.items, b.items) or not same_store(a.markers, b.markers) then return false end
  if not Snap.ent_equal(a.master, b.master) then return false end
  for tid in pairs(a.tracks) do
    if not same_list(a.item_order[tid] or {}, b.item_order[tid] or {}) then return false end
  end
  return true
end

-- flat list of item ids in track order (used to merge item order)
function Snap.item_sequence(model)
  local seq = {}
  for _, tid in ipairs(model.order) do
    for _, iid in ipairs(model.item_order[tid] or {}) do
      if model.items[iid] then seq[#seq + 1] = iid end
    end
  end
  return seq
end

-- convenience for the glue: text of a whole view rendered as a project (child space)
function Snap.to_project(model, skeleton_root, extra_markers)
  local root = Rpp.clone(skeleton_root)
  for i = #root.items, 1, -1 do
    local c = root.items[i]
    if c.kind == "block" and c.name == "TRACK" then table.remove(root.items, i) end
  end
  local r = Snap.render(model, { index_base = 0, end_level = 0 })
  if r.master then X.apply_master(root, r.master) end
  X.write_markers(root, r.markers)
  for _, t in ipairs(r.tracks) do root.items[#root.items + 1] = t end
  return root, r
end

return Snap

end
__preload["NPMerge"] = function(...)
-- NPMerge.lua
-- Pure Lua. Three-way merge of two snapshot models (NPSnap) against their common ancestor.
--
--   base   : what both sides agreed on last time (the file we exported / imported)
--   parent : the tracks as they are now in the parent project      (converted back to child space)
--   child  : the child .rpp as it is now on disk
--
-- Rules, per entity (track / item / marker / master) and per property:
--   only one side changed it        -> take that change
--   both changed it the same way    -> fine
--   both changed it differently     -> CONFLICT   (default: parent's value; policy "child" flips the default)
--   deleted on one side, untouched on the other -> deleted;  deleted vs edited -> CONFLICT (default: keep)
-- Order (tracks, items, markers): a side that re-ordered wins over one that didn't; both re-ordered differently -> CONFLICT.
--
-- Nothing here touches REAPER. The result is again a model; Snap.render turns it into rpp nodes.

local Snap = require("NPSnap")

local Merge = {}

local function set_of(list)
  local s = {}
  for _, id in ipairs(list or {}) do s[id] = true end
  return s
end

local function index_of(list, id)
  for i, x in ipairs(list) do if x == id then return i end end
end

local function same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function restrict(list, set)
  local out = {}
  for _, id in ipairs(list or {}) do if set[id] then out[#out + 1] = id end end
  return out
end

-- did `side` change the relative order of the ids it shares with `base`?
local function reordered(base, side)
  local sb, ss = set_of(base), set_of(side)
  local common = {}
  for id in pairs(sb) do if ss[id] then common[id] = true end end
  return not same_list(restrict(base, common), restrict(side, common))
end

-- returns merged list, order_conflict(bool)
local function merge_seq(b, p, c, alive, pick)
  local rp, rc = reordered(b, p), reordered(b, c)
  local primary, secondary = p, c
  if rc and not rp then primary, secondary = c, p end
  local conflict = false
  if rp and rc then
    local pc = set_of(c)
    local both = {}
    for _, id in ipairs(p) do if pc[id] and alive[id] then both[id] = true end end
    conflict = not same_list(restrict(p, both), restrict(c, both))
  end
  if conflict and pick == "child" then primary, secondary = c, p end
  local merged, present = {}, {}
  for _, id in ipairs(primary) do
    if alive[id] and not present[id] then merged[#merged + 1] = id; present[id] = true end
  end
  for i, id in ipairs(secondary) do
    if alive[id] and not present[id] then
      local pos = 0
      for j = i - 1, 1, -1 do
        if present[secondary[j]] then pos = index_of(merged, secondary[j]); break end
      end
      table.insert(merged, pos + 1, id)
      present[id] = true
    end
  end
  return merged, conflict
end

--------------------------------------------------------------------------------
local function new_result(base, parent, child, opts)
  return {
    model = Snap.empty(), conflicts = {}, log = {},
    sides = { base = base, parent = parent, child = child },
    alive = { track = {}, item = {}, marker = {} },
    shadow_items = {},     -- items deleted on one side only because their track was; they come back if the track is kept
    picks = {},            -- order conflict choices per class
    opts = opts,
  }
end

local function add_conflict(res, c)
  c.n = #res.conflicts + 1
  c.choice = c.default or "parent"
  res.conflicts[#res.conflicts + 1] = c
  return c
end

local function log(res, kind, cls, id, key, from)
  res.log[#res.log + 1] = { kind = kind, cls = cls, id = id, key = key, from = from }
end

local function merge_ent(res, cls, id, b, p, c)
  local out = { id = id, keys = {}, vals = {} }
  local seen, order = {}, {}
  for _, e in ipairs({ p or false, c or false, b or false }) do
    if e then for _, k in ipairs(e.keys) do if not seen[k] then seen[k] = true; order[#order + 1] = k end end end
  end
  local policy = res.opts.policy or "ask"
  for _, k in ipairs(order) do
    local vb, vp, vc = b and b.vals[k], p and p.vals[k], c and c.vals[k]
    local v
    if vp == vc then v = vp
    elseif vp == vb then v = vc; log(res, "child_change", cls, id, k, "child")
    elseif vc == vb then v = vp; log(res, "parent_change", cls, id, k, "parent")
    else
      local cf = add_conflict(res, { kind = "field", cls = cls, id = id, key = k, base = vb, parent = vp, child = vc,
                                     default = (policy == "child") and "child" or "parent" })
      v = (cf.choice == "child") and vc or vp
    end
    if v ~= nil then out.keys[#out.keys + 1] = k; out.vals[k] = v end
  end
  return out
end

local function merge_class(res, cls, store, B, P, C)
  local ids, seen = {}, {}
  for _, M in ipairs({ P, C, B }) do
    for id in pairs(M[store]) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
  end
  table.sort(ids)
  local alive = res.alive[cls]
  for _, id in ipairs(ids) do
    local b, p, c = B[store][id], P[store][id], C[store][id]
    local ent
    if b then
      if not p and not c then log(res, "deleted_both", cls, id)
      elseif not p or not c then
        local survivor, gone = p or c, (not p) and "parent" or "child"
        if Snap.ent_equal(b, survivor) then
          log(res, "deleted_" .. gone, cls, id)
          if cls == "item" then res.shadow_items[id] = survivor end
        else
          ent = survivor
          add_conflict(res, { kind = "delete_edit", cls = cls, id = id, deleted_side = gone, ent = survivor, default = (gone == "parent") and "child" or "parent" })
        end
      else ent = merge_ent(res, cls, id, b, p, c) end
    else
      if p and c then ent = merge_ent(res, cls, id, nil, p, c)
      elseif p then ent = p; log(res, "added_parent", cls, id)
      else ent = c; log(res, "added_child", cls, id) end
    end
    if ent then res.model[store][id] = ent; alive[id] = true end
  end
end

-- (re)builds order lists from the current `alive` sets and the order picks; called after run() and after every choose()
function Merge.finalize(res)
  local m, S = res.model, res.sides
  -- items whose track vanished are left out (and reported); they stay in the pool so that choosing the track back restores them
  m.items, res.alive.item = {}, {}
  local dropped = {}
  for id, ent in pairs(res.pool_items) do
    if m.tracks[ent.vals["@track"]] then m.items[id] = ent; res.alive.item[id] = true
    else dropped[#dropped + 1] = id end
  end
  table.sort(dropped)
  local kept = {}
  for _, l in ipairs(res.log) do if l.kind ~= "orphan_item_dropped" then kept[#kept + 1] = l end end
  res.log = kept
  for _, id in ipairs(dropped) do log(res, "orphan_item_dropped", "item", id) end
  local conflicts = {}
  local function seq(cls, pick, b, p, c)
    local merged, cf = merge_seq(b, p, c, res.alive[cls], pick)
    conflicts[cls] = cf
    return merged
  end
  m.order = seq("track", res.picks.track, S.base.order, S.parent.order, S.child.order)
  m.marker_order = seq("marker", res.picks.marker, S.base.marker_order, S.parent.marker_order, S.child.marker_order)
  local items = seq("item", res.picks.item, Snap.item_sequence(S.base), Snap.item_sequence(S.parent), Snap.item_sequence(S.child))
  m.item_order = {}
  for tid in pairs(m.tracks) do m.item_order[tid] = {} end
  for _, iid in ipairs(items) do
    local t = m.items[iid].vals["@track"]
    if m.item_order[t] then table.insert(m.item_order[t], iid) end
  end
  res.order_conflicts = conflicts
  -- one entry in the conflict list per class with an order conflict
  local have = {}
  for _, c in ipairs(res.conflicts) do if c.kind == "order" then have[c.cls] = c end end
  for cls, cf in pairs(conflicts) do
    if cf and not have[cls] then add_conflict(res, { kind = "order", cls = cls, default = "parent" }) end
  end
end

function Merge.run(base, parent, child, opts)
  opts = opts or {}
  base = base or Snap.empty()
  local res = new_result(base, parent, child, opts)
  merge_class(res, "track", "tracks", base, parent, child)
  merge_class(res, "item", "items", base, parent, child)
  res.pool_items = res.model.items
  merge_class(res, "marker", "markers", base, parent, child)
  -- master is a single entity
  if base.master or parent.master or child.master then
    local b, p, c = base.master, parent.master, child.master
    local ent
    if p and c then ent = merge_ent(res, "master", "MASTER", b, p, c) else ent = p or c end
    res.model.master = ent
  end
  Merge.finalize(res)
  if opts.policy == "parent" or opts.policy == "child" then
    for _, cf in ipairs(res.conflicts) do Merge.choose(res, cf.n, opts.policy) end
  end
  return res
end

-- side = "parent" | "child".  field: take that side's value.  delete_edit: the side that deleted wins if it is chosen.
--         order: that side's arrangement.
function Merge.choose(res, n, side)
  local cf = res.conflicts[n]
  if not cf then return false, "no such conflict" end
  cf.choice = side
  local m = res.model
  if cf.kind == "field" then
    local ent
    if cf.cls == "master" then ent = m.master
    elseif cf.cls == "item" then ent = res.pool_items[cf.id]
    else ent = m[cf.cls == "track" and "tracks" or "markers"][cf.id] end
    if ent then
      local v = cf[side]
      local present = ent.vals[cf.key] ~= nil
      ent.vals[cf.key] = v
      if v == nil and present then
        for i, k in ipairs(ent.keys) do if k == cf.key then table.remove(ent.keys, i); break end end
      elseif v ~= nil and not present then ent.keys[#ent.keys + 1] = cf.key end
    end
  elseif cf.kind == "delete_edit" then
    local target = (cf.cls == "item") and res.pool_items or m[cf.cls == "track" and "tracks" or "markers"]
    if side == cf.deleted_side then target[cf.id] = nil; res.alive[cf.cls][cf.id] = nil
    else
      target[cf.id] = cf.ent; res.alive[cf.cls][cf.id] = true
      if cf.cls == "track" then
        for iid, ie in pairs(res.shadow_items) do
          if ie.vals["@track"] == cf.id then res.pool_items[iid] = ie end
        end
      end
    end
  elseif cf.kind == "order" then
    res.picks[cf.cls] = side
  end
  Merge.finalize(res)
  return true
end

function Merge.resolve_all(res, side)
  for _, cf in ipairs(res.conflicts) do Merge.choose(res, cf.n, side) end
end

function Merge.open_conflicts(res)
  return #res.conflicts
end

-- short human-readable description of one conflict / of the whole result
local function short(v)
  if v == nil then return "(none)" end
  v = tostring(v):gsub("\n", " ")
  return #v > 48 and (v:sub(1, 45) .. "...") or v
end

function Merge.describe(res, cf)
  local who = (cf.cls == "master") and "master" or (cf.cls .. " " .. tostring(cf.id))
  local names = res.sides.parent[cf.cls == "track" and "tracks" or cf.cls == "item" and "items" or "markers"]
  if cf.kind == "field" then
    return string.format("%s: %s  parent=%s  child=%s", who, cf.key, short(cf.parent), short(cf.child))
  elseif cf.kind == "delete_edit" then
    return string.format("%s: deleted in %s but edited in the other", who, cf.deleted_side)
  else
    return string.format("%s order differs", cf.cls)
  end
end

function Merge.summary(res)
  local n = { child_change = 0, parent_change = 0, added_child = 0, added_parent = 0, deleted_child = 0, deleted_parent = 0, orphan = 0 }
  for _, l in ipairs(res.log) do
    if l.kind == "orphan_item_dropped" then n.orphan = n.orphan + 1
    elseif n[l.kind] then n[l.kind] = n[l.kind] + 1 end
  end
  n.conflicts = #res.conflicts
  return n
end

return Merge

end
__preload["NPMail"] = function(...)
-- NPMail.lua
-- Pure Lua. The file mailbox between the parent REAPER and a detached child REAPER, plus the health / recovery rules.
-- Nothing here calls REAPER or the OS: everything goes through an `fs` object so it can be tested offline.
--
--   fs = { read(path)->string|nil, write_atomic(path,data)->bool, exists(path)->bool, mkdir(path), mtime(path)->number|nil }
--
-- Files in <link dir>:
--   cmd.json     parent -> child   { seq, cmd = "play"|"stop"|"locate"|"transport"|"save"|"quit"|"ping", pos?, t }
--                                  transport = { play=1|0, pos (child time), tp (parent time_precise), rate }: the whole state, idempotent
--   ack.json     child  -> parent  { seq, ok, err?, t }               (last command the child handled)
--   status.json  child  -> parent  { id, t, pid?, project, play, pos, dirty, device?, device_err?, state }
--   parent.json  parent -> child   { t, project }                     (parent heartbeat, so a child can tell it was orphaned)
--   boot.json    child  -> parent  { id, t, via, project }            (written the moment the helper script starts running)
--   helper.log   child  -> anyone  errors of the helper, one per line

local M = {}

--------------------------------------------------------------------------------
-- tiny JSON (objects, arrays, strings, numbers, booleans, null) - enough for our own files
--------------------------------------------------------------------------------
local J = {}
M.json = J

local esc = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function enc(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return esc[c] or string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = "["
      for i, x in ipairs(v) do if i > 1 then out[#out + 1] = "," end enc(x, out) end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        enc(k, out); out[#out + 1] = ":"; enc(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else out[#out + 1] = "null" end
end

function J.encode(v) local out = {}; enc(v, out); return table.concat(out) end

function J.decode(s)
  local i = 1
  local function ws() i = s:find("%S", i) or (#s + 1) end
  local val
  local function str()
    local out = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == "" then error("unterminated string") end
      if c == '"' then i = i + 1; break end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        if n == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16)); i = i + 6
        else
          out[#out + 1] = ({ n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" })[n] or n
          i = i + 2
        end
      else out[#out + 1] = c; i = i + 1 end
    end
    return table.concat(out)
  end
  function val()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local o = {}
      i = i + 1; ws()
      if s:sub(i, i) == "}" then i = i + 1; return o end
      while true do
        ws()
        local k = str(); ws()
        assert(s:sub(i, i) == ":", "expected ':' at " .. i); i = i + 1
        o[k] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "}" then break end
        assert(d == ",", "expected ',' at " .. i)
      end
      return o
    elseif c == "[" then
      local a = {}
      i = i + 1; ws()
      if s:sub(i, i) == "]" then i = i + 1; return a end
      while true do
        a[#a + 1] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "]" then break end
        assert(d == ",", "expected ',' at " .. i)
      end
      return a
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
      assert(num and num ~= "", "bad json at " .. i)
      i = i + #num
      return tonumber(num)
    end
  end
  local v = val()
  return v
end

function J.try_decode(s)
  if not s or s == "" then return nil end
  local ok, v = pcall(J.decode, s)
  if ok then return v end
  return nil
end

--------------------------------------------------------------------------------
-- mailbox
--------------------------------------------------------------------------------
local function read_json(fs, path) return J.try_decode(fs.read(path)) end
local function write_json(fs, path, tbl) return fs.write_atomic(path, J.encode(tbl)) end

M.COMMANDS = { play = true, stop = true, locate = true, transport = true, save = true, quit = true, ping = true }

function M.parent(fs, dir, clock)
  local self = { fs = fs, dir = dir, clock = clock }
  local function p(name) return dir .. "/" .. name end

  function self.last_seq()
    local c = read_json(fs, p("cmd.json"))
    return c and c.seq or 0
  end

  -- returns seq, or nil + error
  function self.send(cmd, args)
    if not M.COMMANDS[cmd] then return nil, "unknown command " .. tostring(cmd) end
    local msg = { seq = self.last_seq() + 1, cmd = cmd, t = clock() }
    for k, v in pairs(args or {}) do msg[k] = v end
    if cmd == "locate" and type(msg.pos) ~= "number" then return nil, "locate needs a position" end
    if cmd == "transport" and (type(msg.pos) ~= "number" or type(msg.play) ~= "number") then return nil, "transport needs play and pos" end
    if not write_json(fs, p("cmd.json"), msg) then return nil, "could not write cmd.json" end
    return msg.seq
  end

  function self.ack() return read_json(fs, p("ack.json")) end
  function self.status() return read_json(fs, p("status.json")) end
  function self.boot() return read_json(fs, p("boot.json")) end

  -- true while the last command has not been acknowledged
  function self.pending()
    local c = read_json(fs, p("cmd.json"))
    if not c then return false end
    local a = read_json(fs, p("ack.json"))
    return (a and a.seq or 0) < c.seq
  end

  function self.heartbeat(project)
    return write_json(fs, p("parent.json"), { t = clock(), project = project })
  end
  return self
end

function M.child(fs, dir, clock)
  local self = { fs = fs, dir = dir, clock = clock, handled = 0 }
  local function p(name) return dir .. "/" .. name end

  -- the acknowledged seq survives a restart of the helper: never run the same command twice
  local a = read_json(fs, p("ack.json"))
  if a and a.seq then self.handled = a.seq end

  function self.poll()
    local c = read_json(fs, p("cmd.json"))
    if c and c.seq and c.seq > self.handled then return c end
  end

  function self.ack(seq, ok, err)
    self.handled = seq
    return write_json(fs, p("ack.json"), { seq = seq, ok = ok and true or false, err = err, t = clock() })
  end

  function self.write_status(st)
    st.t = clock()
    return write_json(fs, p("status.json"), st)
  end

  function self.parent_info() return read_json(fs, p("parent.json")) end
  function self.write_boot(info)
    info.t = clock()
    return write_json(fs, p("boot.json"), info)
  end
  return self
end

--------------------------------------------------------------------------------
-- health
--------------------------------------------------------------------------------
local H = {}
M.health = H
H.DEFAULTS = { stale = 3, lost = 15, start_grace = 30, parent_lost = 20 }

-- status: contents of status.json or nil;  rec: { instance_id, launched_at };  boot: contents of boot.json or nil
-- -> { state, age, dirty, play, pos, device_err }
-- state: "not_started" | "starting" | "booted" | "ok" | "stale" | "lost" | "closing" | "foreign" | "no_helper"
--   starting   launched, nothing seen yet (inside the grace period)
--   booted     the helper script is running but has not written a status yet
--   no_helper  grace period over and the helper script never ran: REAPER may have opened, but our script did not start
--   lost       the helper was seen, then went quiet (or the process is gone)
function H.eval(status, rec, now, cfg, boot)
  cfg = cfg or H.DEFAULTS
  local out = { state = "not_started" }
  local grace = rec.launched_at and (now - rec.launched_at < cfg.start_grace)
  if status and rec.instance_id and status.id and status.id ~= "" and status.id ~= rec.instance_id then
    -- a status file written by some other launch: do not trust it, it is not our child
    out.state = grace and "starting" or "foreign"
    return out
  end
  if not status then
    if not rec.launched_at then return out end
    if boot then out.state = grace and "booted" or "lost"
    else out.state = grace and "starting" or "no_helper" end
    return out
  end
  out.age = now - (status.t or 0)
  out.dirty, out.play, out.pos, out.device_err, out.tp = status.dirty, status.play, status.pos, status.device_err, status.tp
  if status.state == "closing" then out.state = "closing"
  elseif out.age <= cfg.stale then out.state = "ok"
  elseif out.age <= cfg.lost then out.state = "stale"
  else out.state = "lost" end
  return out
end

-- for the child helper: has the parent stopped writing its heartbeat?
function H.parent_alive(parent_info, now, cfg)
  cfg = cfg or H.DEFAULTS
  if not parent_info or not parent_info.t then return false end
  return now - parent_info.t <= cfg.parent_lost
end

--------------------------------------------------------------------------------
-- lifecycle + recovery
--------------------------------------------------------------------------------
local R = {}
M.recover = R

-- allowed moves of a PROJECT record's `state`
R.TRANSITIONS = {
  attached = { detach = "detached", sync = "attached" },
  detached = { reattach = "attached", relaunch = "detached" },
}

function R.can(state, action) return R.TRANSITIONS[state] ~= nil and R.TRANSITIONS[state][action] ~= nil end

-- rec:   { state, op?, file }                      op = the operation that was in progress when the record was last written
-- facts: { file_exists, file_changed (content hash differs from the last agreed base), health = H.eval(...) }
-- -> list of { action, why }  (most sensible first). Empty list = nothing to do.
function R.plan(rec, facts)
  local out = {}
  local function add(a, why) out[#out + 1] = { action = a, why = why } end
  if rec.op then
    add("finish_or_rollback_" .. rec.op, "'" .. rec.op .. "' was interrupted (REAPER closed or crashed while it ran)")
    return out
  end
  local edited = facts.file_exists and facts.file_changed
  if rec.state == "detached" then
    local h = facts.health and facts.health.state or "not_started"
    if not facts.file_exists then
      add("locate_file", "the child project file is missing: " .. tostring(rec.file))
      add("abandon", "forget the detached child (its tracks are not in this project)")
    elseif h == "ok" or h == "starting" or h == "booted" or h == "stale" then
      -- running: nothing to recover
      if h == "stale" then add("wait", "child heartbeat is late; it may be busy") end
    else
      if facts.health and facts.health.dirty then add("warn_unsaved", "the child was last seen with unsaved changes") end
      add("relaunch", "the child instance is not running")
      add("reattach", edited and "the child file was edited since it was detached" or "take the tracks back into this project")
    end
  elseif rec.state == "attached" then
    if edited then add("pull", "the child file changed on disk since the last sync") end
    if not facts.file_exists and rec.file then add("export", "the child file is missing: write it from the tracks in this project") end
  end
  return out
end

return M

end
__preload["NPSync"] = function(...)
-- NPSync.lua
-- Pure Lua. Parent side of "follow the parent's transport": watches the parent's play state / position and decides
-- WHEN to tell a detached child what to do. It never sends "press play"; it sends the whole transport STATE
-- ({play, pos in the child's own time, timestamp}), so a lost or overwritten message is harmless: the next one repairs it.
--
--   child time = parent time - shift         shift = attach offset + the child project's start offset
--
-- When a message is sent:
--   * play/stop changed                      (edge)
--   * the position jumped while playing      (seek: further than SEEK from where it should be)
--   * every DRIFT_EVERY seconds while playing (the two audio clocks are never exactly equal; the child corrects itself)
--   * the cursor moved while stopped         (at most every CURSOR_EVERY seconds)
--   * forced (child just came up / Follow switched on)

local Sync = {}
Sync.__index = Sync

Sync.SEEK = 0.25
Sync.DRIFT_EVERY = 1.0
Sync.CURSOR_EVERY = 0.1

function Sync.new(shift)
  return setmetatable({ shift = shift or 0, force = true, last_play = nil, last_pos = 0, last_t = 0, last_sent = -1e9, last_rate = 1 }, Sync)
end

function Sync:set_shift(shift)
  if shift ~= self.shift then self.shift = shift; self.force = true end
end

function Sync:reset() self.force = true end

-- ps = { play=bool, pos=seconds (parent time), rate=number|nil }, now = monotonic seconds (r.time_precise)
-- returns the message table for the child, or nil
function Sync:step(ps, now)
  local rate = ps.rate or 1
  local send = false
  if self.force then send = true; self.force = false
  elseif ps.play ~= self.last_play then send = true
  elseif math.abs(rate - self.last_rate) > 1e-3 then send = true
  elseif ps.play then
    local expected = self.last_pos + (now - self.last_t) * self.last_rate
    if math.abs(ps.pos - expected) > Sync.SEEK then send = true
    elseif now - self.last_sent >= Sync.DRIFT_EVERY then send = true end
  else
    if math.abs(ps.pos - self.last_pos) > 1e-4 and now - self.last_sent >= Sync.CURSOR_EVERY then send = true end
  end
  -- while stopped and waiting for the throttle, keep last_pos where we last SENT so the move is not forgotten
  if ps.play or send or self.last_play == nil then self.last_pos = ps.pos end
  self.last_play, self.last_t, self.last_rate = ps.play, now, rate
  if not send then return nil end
  self.last_sent = now
  return { play = ps.play and 1 or 0, pos = ps.pos - self.shift, tp = now, rate = rate }
end

-- seconds the child is ahead (+) / behind (-) of where it should be, given its last status
--   st = { play, pos, tp }  (child status.json, tp = the child's time_precise when it wrote pos), parent_pos, now
function Sync.drift(st, parent_pos, shift, now, rate)
  if not st or not st.play or (st.play & 1) ~= 1 or not st.tp then return nil end
  local age = now - st.tp
  if age < 0 or age > 2 then return nil end
  local child_now = st.pos + age * (rate or 1)
  return child_now + shift - parent_pos
end

return Sync

end
__preload["NPReaper"] = function(...)
-- NPReaper.lua
-- Everything that talks to REAPER or the file system. The logic it relies on (parse, transform, snapshot, merge,
-- mailbox, health) lives in the pure modules and is tested offline; THIS file is only verifiable inside REAPER
-- (see spikes/SPIKES.md).
--
-- Model:  a PROJECT is a folder track with a record in its P_EXT "NP_DATA" (JSON).
--         attached : the child's tracks are the folder's children.      detached : they are gone (or muted "shadow"
--         copies) and live in another REAPER instance editing <parent>/PROJECTS/<name>/<name>.rpp.
--         <dir>/.link/ holds base.rpp (last agreed state), state.json (transform bookkeeping), mailbox files.

local Rpp = require("NPRpp")
local X = require("NPXform")
local Snap = require("NPSnap")
local Merge = require("NPMerge")
local Mail = require("NPMail")

local r = reaper
local J = Mail.json

local RA = {}
RA.EXT = "NP_DATA"
RA.PREFIX = "PROJECT: "

--------------------------------------------------------------------------------
-- environment (replaceable for tests)
--------------------------------------------------------------------------------
RA.clock = function() return os.time() end

RA.fs = {
  read = function(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
  end,
  write_atomic = function(p, s)
    local tmp = p .. ".tmp"
    local f = io.open(tmp, "wb"); if not f then return false end
    f:write(s); f:close()
    os.remove(p)                         -- rename() does not replace on Windows
    return os.rename(tmp, p) and true or false
  end,
  exists = function(p) return r.file_exists(p) end,
  mkdir = function(p) r.RecursiveCreateDirectory(p, 0) end,
}

RA.shell = function(cmd) return os.execute(cmd) end

local function fs() return RA.fs end

local function hash(text)
  local h = 2166136261
  for i = 1, #text do h = ((h ~ text:byte(i)) * 16777619) & 0xFFFFFFFF end
  return string.format("%08x:%d", h, #text)
end
RA.hash = hash

local function safe_name(s)
  s = tostring(s):gsub("^" .. RA.PREFIX, ""):gsub("[^%w%-%._ ]", "_"):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then s = "Project" end
  return s
end

local function sq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

--------------------------------------------------------------------------------
-- config (window state etc.) in ExtState
--------------------------------------------------------------------------------
local CFG = "NestedProjects"
function RA.load_cfg()
  local c = { child_script = r.GetExtState(CFG, "child_script"), own_config = r.GetExtState(CFG, "own_config_v2") == "1",
              policy = r.GetExtState(CFG, "policy") }
  if c.policy == "" then c.policy = "ask" end
  return c
end
function RA.save_cfg(c)
  r.SetExtState(CFG, "child_script", c.child_script or "", true)
  r.SetExtState(CFG, "own_config_v2", c.own_config and "1" or "0", true)
  r.SetExtState(CFG, "policy", c.policy or "ask", true)
end

--------------------------------------------------------------------------------
-- paths
--------------------------------------------------------------------------------
function RA.project_file(proj)
  local _, fn = r.EnumProjects(-1)
  if proj and proj ~= 0 then
    for i = 0, 1000 do
      local p, f = r.EnumProjects(i)
      if not p then break end
      if p == proj then fn = f; break end
    end
  end
  if not fn or fn == "" then return nil end
  return fn
end

function RA.paths(parent_file, name)
  local pdir = Rpp.dirname(parent_file)
  local n = safe_name(name)
  local dir = pdir .. "/PROJECTS/" .. n
  return { dir = dir, link = dir .. "/.link", file = dir .. "/" .. n .. ".rpp", base = dir .. "/.link/base.rpp",
           state = dir .. "/.link/state.json", name = n }
end

--------------------------------------------------------------------------------
-- records on folder tracks
--------------------------------------------------------------------------------
local function ext_get(track)
  local ok, s = r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. RA.EXT, "", false)
  if ok and s and s ~= "" then return J.try_decode(s) end
end
local function ext_set(track, rec) r.GetSetMediaTrackInfo_String(track, "P_EXT:" .. RA.EXT, J.encode(rec), true) end

function RA.read_rec(track) return ext_get(track) end
function RA.write_rec(entry)
  ext_set(entry.track, entry.rec)
end

function RA.list(proj)
  local out = {}
  for i = 0, r.CountTracks(proj) - 1 do
    local tr = r.GetTrack(proj, i)
    local rec = ext_get(tr)
    if rec and rec.id then out[#out + 1] = { track = tr, index = i, rec = rec } end
  end
  return out
end

function RA.find(proj, id)
  for _, e in ipairs(RA.list(proj)) do if e.rec.id == id then return e end end
end

function RA.subtree(proj, folder_index)
  local list, depth = {}, 1
  local ft = r.GetTrack(proj, folder_index)
  if not ft or r.GetMediaTrackInfo_Value(ft, "I_FOLDERDEPTH") ~= 1 then return list end   -- not open: no children
  for i = folder_index + 1, r.CountTracks(proj) - 1 do
    local tr = r.GetTrack(proj, i)
    list[#list + 1] = tr
    depth = depth + r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    if depth <= 0 then break end
  end
  return list
end

local function load_state(rec)
  local s = J.try_decode(fs().read(rec.link .. "/state.json")) or {}
  s.ctx = s.ctx or {}
  s.ctx.beat_orig = s.ctx.beat_orig or {}
  s.ctx.baked = s.ctx.baked or {}
  s.markers = s.markers or {}
  return s
end
local function save_state(rec, st)
  fs().mkdir(rec.link)
  return fs().write_atomic(rec.link .. "/state.json", J.encode(st))
end
RA.load_state, RA.save_state = load_state, save_state

local function get_chunk(track)
  local ok, c = r.GetTrackStateChunk(track, "", false)
  return ok and c or nil
end

local function ctx_of(st)
  local c = st.ctx
  return { offset = c.offset or 0, projoffs = c.projoffs or 0, tempo = c.tempo, beat_orig = c.beat_orig, baked = c.baked }
end

--------------------------------------------------------------------------------
-- reading the three sides (all returned in child space)
--------------------------------------------------------------------------------
function RA.read_base(rec)
  local text = fs().read(rec.link .. "/base.rpp")
  if not text then return Snap.empty(), nil end
  local view = X.read_project(text)
  if not view then return Snap.empty(), nil end
  return Snap.build(view), view
end

function RA.read_child(rec)
  local text = fs().read(rec.file)
  if not text then return Snap.empty(), nil, nil end
  local view, err = X.read_project(text)
  if not view then return nil, nil, err end
  return Snap.build(view), view, text
end

local function read_markers(proj, st, shift)
  local out = {}
  local want = {}
  for _, m in ipairs(st.markers) do want[m.idx .. (m.isrgn and "r" or "m")] = m end
  local i = 0
  while true do
    local ok, isrgn, pos, rgnend, name, num, color = r.EnumProjectMarkers3(proj, i)
    if not ok or ok == 0 then break end
    local m = want[num .. (isrgn and "r" or "m")]
    if m then
      out[m.n] = { guid = m.guid, idx = m.child_idx or num, pos = pos - shift, rgnend = (isrgn and rgnend or pos) - shift,
                   name = name, isrgn = isrgn, color = color }
    end
    i = i + 1
  end
  local list = {}
  for n = 1, #st.markers do if out[n] then list[#list + 1] = out[n] end end
  return list
end

-- the current content of a PROJECT's folder in the parent, converted back to child space
function RA.read_parent(proj, entry, st)
  local ctx = ctx_of(st)
  local fchunk = get_chunk(entry.track)
  local fnode = fchunk and Rpp.parse(fchunk)
  if not fnode then return nil, "cannot read the PROJECT track" end
  local tracks = {}
  for _, tr in ipairs(RA.subtree(proj, entry.index)) do
    local c = get_chunk(tr)
    local node = c and Rpp.parse(c)
    if node then
      local g = r.GetTrackGUID(tr)
      if g and g ~= "" then node.args[1] = g; node.head = "<TRACK " .. g end
      X.backward(node, ctx)
      tracks[#tracks + 1] = node
    end
  end
  local shift = ctx.offset + ctx.projoffs
  local view = { tracks = tracks, master = X.pseudo_from_folder(fnode, ctx), markers = read_markers(proj, st, shift) }
  return Snap.build(view), view
end

--------------------------------------------------------------------------------
-- writing the parent side
--------------------------------------------------------------------------------
local function set_chunk(track, chunk)
  return r.SetTrackStateChunk(track, chunk, false)
end

local function next_free_idx(proj, isrgn)
  local used, i = 0, 0
  while true do
    local ok, rg, _, _, _, num = r.EnumProjectMarkers3(proj, i)
    if not ok or ok == 0 then break end
    if (rg and true or false) == (isrgn and true or false) and num > used then used = num end
    i = i + 1
  end
  return used + 1
end

local function apply_markers(proj, st, markers, shift)
  local keep = {}
  for _, m in ipairs(markers) do keep[m.guid] = true end
  for _, old in ipairs(st.markers) do
    if not keep[old.guid] then r.DeleteProjectMarker(proj, old.idx, old.isrgn) end
  end
  local prev = {}
  for _, old in ipairs(st.markers) do prev[old.guid] = old end
  local new_list = {}
  for n, m in ipairs(markers) do
    local old = prev[m.guid]
    local pos, rend = m.pos + shift, m.rgnend + shift
    local entry
    if old then
      r.SetProjectMarker4(proj, old.idx, old.isrgn, pos, rend, m.name, m.color or 0, 0)
      entry = { guid = m.guid, idx = old.idx, isrgn = old.isrgn, child_idx = m.idx, n = n }
    else
      local want = next_free_idx(proj, m.isrgn)
      local idx = r.AddProjectMarker2(proj, m.isrgn, pos, rend, m.name, want, m.color or 0)
      if not idx or idx < 0 then idx = want end
      entry = { guid = m.guid, idx = idx, isrgn = m.isrgn, child_idx = m.idx, n = n }
    end
    new_list[#new_list + 1] = entry
  end
  st.markers = new_list
end

local function remove_markers(proj, st)
  for _, old in ipairs(st.markers) do r.DeleteProjectMarker(proj, old.idx, old.isrgn) end
  st.markers = {}
end

local function update_folder_chunk(entry, pseudo_fw)
  local chunk = get_chunk(entry.track)
  local node = chunk and Rpp.parse(chunk)
  if not node then return false end
  -- replace master-like state: VOLPAN, FXCHAIN and the envelopes
  for i = #node.items, 1, -1 do
    local c = node.items[i]
    if (c.kind == "leaf" and c.key == "VOLPAN") or (c.kind == "block" and (c.name == "FXCHAIN" or c.name:match("^VOLENV") or c.name:match("^PANENV") or c.name:match("^MUTEENV") or c.name:match("^WIDTHENV"))) then
      table.remove(node.items, i)
    end
  end
  for _, c in ipairs(pseudo_fw.items) do node.items[#node.items + 1] = Rpp.clone(c) end
  set_chunk(entry.track, Rpp.serialize(node))
  ext_set(entry.track, entry.rec)             -- SetTrackStateChunk may drop P_EXT: put the record back
  return true
end

-- Rebuilds the folder's children from a merged model and refreshes master state + markers.
function RA.apply_to_parent(proj, entry, st, model)
  local ctx = ctx_of(st)
  local rendered = Snap.render(model, { index_base = entry.index + 1, end_level = -1 })
  -- 1. out with the old children
  local old = RA.subtree(proj, entry.index)
  for i = #old, 1, -1 do r.DeleteTrack(old[i]) end
  -- 2. in with the new ones
  local stats = { beat = 0, midi = 0, midi_var = 0, files = 0 }
  for i, node in ipairs(rendered.tracks) do
    local s = X.forward(node, ctx)
    for k, v in pairs(s) do stats[k] = (stats[k] or 0) + v end
    r.InsertTrackAtIndex(entry.index + i, false)
    local tr = r.GetTrack(proj, entry.index + i)
    set_chunk(tr, Rpp.serialize(node))
    local isb = Rpp.leaf(node, "ISBUS")
    r.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", tonumber(Rpp.tok(isb)[3]) or 0)
  end
  -- the folder itself must open exactly one level
  r.SetMediaTrackInfo_Value(entry.track, "I_FOLDERDEPTH", #rendered.tracks > 0 and 1 or 0)   -- an empty folder must not swallow the next track
  -- 3. master-like state and markers
  if rendered.master then
    X.forward(rendered.master, ctx)
    update_folder_chunk(entry, rendered.master)
  end
  apply_markers(proj, st, rendered.markers, ctx.offset + ctx.projoffs)
  return stats, rendered
end

--------------------------------------------------------------------------------
-- compare / commit
--------------------------------------------------------------------------------
-- Three-way comparison of the current parent tracks, the child file and the last agreed base.
-- Returns a bundle b (b.res = merge result; resolve b.res.conflicts with Merge.choose, then RA.commit(proj, b)).
function RA.compare(proj, entry, opts)
  opts = opts or {}
  local rec = entry.rec
  local st = load_state(rec)
  local base, base_view = RA.read_base(rec)
  local child, child_view, err = RA.read_child(rec)
  if not child then return nil, err end
  local parent, pview
  if rec.state == "detached" and not rec.shadow then
    parent = base                                   -- nothing of it lives in the parent: no parent-side changes
  else
    local perr
    parent, pview, perr = RA.read_parent(proj, entry, st)
    if not parent then return nil, pview end
  end
  local res = Merge.run(base, parent, child, { policy = opts.policy })
  local skeleton = (child_view and child_view.root) or (base_view and base_view.root)
    or Rpp.skeleton({ bpm = r.Master_GetTempo and r.Master_GetTempo() or 120 })
  return { res = res, base = base, parent = parent, child = child, skeleton = skeleton, st = st, entry = entry,
           removed_from_parent = (rec.state == "detached" and not rec.shadow) }
end

-- Writes the merged result: child file + base, and (when the parent needs it) the parent tracks.
function RA.commit(proj, b, opts)
  opts = opts or {}
  local entry, st, rec = b.entry, b.st, b.entry.rec
  local root = Snap.to_project(b.res.model, b.skeleton)
  local text = Rpp.serialize(root)
  fs().mkdir(rec.dir or Rpp.dirname(rec.file)); fs().mkdir(rec.link)
  if not fs().write_atomic(rec.file, text) then return nil, "cannot write " .. rec.file end
  fs().write_atomic(rec.link .. "/base.rpp", text)
  st.base_hash = hash(text)
  local stats
  local need_parent = opts.update_parent
  if need_parent == nil then need_parent = b.removed_from_parent or not Snap.equal(b.res.model, b.parent) end
  if need_parent and not opts.skip_parent then stats = RA.apply_to_parent(proj, entry, st, b.res.model) end
  save_state(rec, st)
  return { text = text, stats = stats, updated_parent = need_parent and not opts.skip_parent }
end

local function undo_wrap(proj, label, fn)
  r.Undo_BeginBlock2(proj)
  r.PreventUIRefresh(1)
  local ok, a, b, c = pcall(fn)
  r.PreventUIRefresh(-1)
  r.Undo_EndBlock2(proj, label, -1)
  r.UpdateArrange()
  if not ok then return nil, tostring(a) end
  return a, b, c
end

local function resolve_by_policy(b, policy)
  if #b.res.conflicts == 0 then return true end
  if policy == "parent" or policy == "child" then Merge.resolve_all(b.res, policy); return true end
  return false
end

--------------------------------------------------------------------------------
-- operations
--------------------------------------------------------------------------------
local function track_guids(proj)
  local set = {}
  for i = 0, r.CountTracks(proj) - 1 do set[r.GetTrackGUID(r.GetTrack(proj, i))] = true end
  return set
end

-- Attach an existing .rpp as a PROJECT folder.  opts: { name, offset, index }
function RA.attach(proj, src, opts)
  opts = opts or {}
  local pfile = RA.project_file(proj)
  if not pfile then return nil, "Save the parent project first: the child projects are stored next to it." end
  local text = fs().read(src)
  if not text then return nil, "Cannot read " .. tostring(src) end
  local view, err = X.read_project(text)
  if not view then return nil, err end

  local name = opts.name or Rpp.basename(src):gsub("%.[Rr][Pp][Pp]$", "")
  local paths = RA.paths(pfile, name)
  if fs().exists(paths.file) then return nil, "A child project named '" .. paths.name .. "' already exists next to this project. Choose another name." end
  local existing = track_guids(proj)
  for _, tr in ipairs(view.tracks) do
    if existing[tr.args[1]] then
      return nil, "This project (or a copy of it) is already attached: track " .. tr.args[1] .. " exists here."
    end
  end

  return undo_wrap(proj, "Attach project " .. name, function()
    local media = Rpp.dirname(src)
    for _, tr in ipairs(view.tracks) do X.absolutize(tr, media) end
    local offset = opts.offset or 0
    local st = { ctx = { offset = offset, projoffs = view.projoffs, tempo = view.tempo, beat_orig = {}, baked = {} }, markers = {} }
    local rec = { v = 1, id = X.random_guid(), name = paths.name, state = "attached", file = paths.file, dir = paths.dir,
                  link = paths.link, offset = offset, src = src, own_config = true }
    fs().mkdir(paths.dir); fs().mkdir(paths.link)

    local index = opts.index or r.CountTracks(proj)
    local ctx = ctx_of(st)
    local pseudo = Rpp.clone(view.master)
    X.forward(pseudo, ctx)
    local folder = X.make_folder(X.random_guid(), RA.PREFIX .. paths.name, pseudo)
    r.InsertTrackAtIndex(index, false)
    local ftr = r.GetTrack(proj, index)
    set_chunk(ftr, Rpp.serialize(folder))
    r.SetMediaTrackInfo_Value(ftr, "I_FOLDERDEPTH", 0)      -- opened by apply_to_parent once it has children
    local entry = { track = ftr, index = index, rec = rec }
    ext_set(ftr, rec)

    -- children, markers: through the same path a merge uses
    local model = Snap.build({ tracks = view.tracks, master = nil, markers = view.markers })
    model.master = nil
    local stats, rendered = RA.apply_to_parent(proj, entry, st, model)
    ext_set(ftr, rec)

    -- The base is what REAPER itself makes of the tracks (normalised), so the first comparison shows no false changes.
    local pmodel = RA.read_parent(proj, entry, st)
    local text2 = text
    if pmodel then
      local root = Snap.to_project(pmodel, view.root)
      text2 = Rpp.serialize(root)
    end
    fs().write_atomic(paths.file, text2)
    fs().write_atomic(paths.link .. "/base.rpp", text2)
    st.base_hash = hash(text2)
    save_state(rec, st)
    return entry, { stats = stats, report = X.report(view, {}), tracks = #view.tracks }
  end)
end

-- Turn an existing folder track (and its children) into a PROJECT; the child file is written straight away.
function RA.make_project(proj, track, name)
  local pfile = RA.project_file(proj)
  if not pfile then return nil, "Save the parent project first: the child projects are stored next to it." end
  if ext_get(track) then return nil, "This track already is a PROJECT." end
  if r.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") ~= 1 then return nil, "Select a folder track (a track that contains other tracks)." end
  local index = math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")) - 1
  local ok, tname = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  name = name or ((tname and tname ~= "") and tname or "Project")
  local paths = RA.paths(pfile, name)
  if fs().exists(paths.file) then return nil, "A child project named '" .. paths.name .. "' already exists next to this project." end
  return undo_wrap(proj, "Make PROJECT " .. name, function()
    fs().mkdir(paths.dir); fs().mkdir(paths.link)
    local rec = { v = 1, id = X.random_guid(), name = paths.name, state = "attached", file = paths.file, dir = paths.dir,
                  link = paths.link, offset = 0 }
    local st = { ctx = { offset = 0, projoffs = 0, beat_orig = {}, baked = {} }, markers = {} }
    save_state(rec, st)
    local entry = { track = track, index = index, rec = rec }
    ext_set(track, rec)
    r.GetSetMediaTrackInfo_String(track, "P_NAME", RA.PREFIX .. paths.name, true)
    local b, err = RA.compare(proj, entry)
    if not b then error(err) end
    Merge.resolve_all(b.res, "parent")
    local out, cerr = RA.commit(proj, b, { skip_parent = true })
    if not out then error(cerr) end
    return entry
  end)
end

-- Both sides against the base; applies automatically unless there are conflicts (returned for the UI).
function RA.sync(proj, entry, opts)
  opts = opts or {}
  local b, err = RA.compare(proj, entry, { policy = opts.policy })
  if not b then return nil, err end
  if not resolve_by_policy(b, opts.policy) then return nil, "conflicts", b end
  return undo_wrap(proj, "Sync PROJECT " .. entry.rec.name, function()
    local out, cerr = RA.commit(proj, b)
    if not out then error(cerr) end
    return out, b
  end)
end

function RA.apply_bundle(proj, b, label)
  return undo_wrap(proj, label or "Apply PROJECT merge", function()
    local out, cerr = RA.commit(proj, b)
    if not out then error(cerr) end
    return out
  end)
end

--------------------------------------------------------------------------------
-- detach / reattach
--------------------------------------------------------------------------------
-- opts: { shadow=bool, policy=, launch=bool }, bundle: result of an earlier "conflicts" return, after the user resolved it
function RA.detach(proj, entry, opts, bundle)
  opts = opts or {}
  local rec = entry.rec
  if rec.state ~= "attached" then return nil, "This PROJECT is already detached." end
  local b = bundle
  if not b then
    local err
    b, err = RA.compare(proj, entry, { policy = opts.policy })
    if not b then return nil, err end
    if not resolve_by_policy(b, opts.policy) then return nil, "conflicts", b end
  end
  local res, err = undo_wrap(proj, "Detach PROJECT " .. rec.name, function()
    rec.op = "detach"; ext_set(entry.track, rec)
    local up = false                                   -- tracks are about to be removed: no need to refresh them
    if opts.shadow then up = nil end                   -- shadow copies stay: refresh if the merge changed them
    local out, cerr = RA.commit(proj, b, { update_parent = up })
    if not out then error(cerr) end
    local st = b.st
    if not opts.shadow then
      local old = RA.subtree(proj, entry.index)
      for i = #old, 1, -1 do r.DeleteTrack(old[i]) end
      r.SetMediaTrackInfo_Value(entry.track, "I_FOLDERDEPTH", 0)
      remove_markers(proj, st)
    else
      r.SetMediaTrackInfo_Value(entry.track, "B_MUTE", 1)
    end
    save_state(rec, st)
    rec.state = "detached"; rec.shadow = opts.shadow and true or nil
    rec.instance_id = X.random_guid(); rec.launched_at = nil
    rec.op = nil
    ext_set(entry.track, rec)
    r.GetSetMediaTrackInfo_String(entry.track, "P_NAME", RA.PREFIX .. rec.name .. " [detached]", true)
    return true
  end)
  if not res then return nil, err end
  if opts.launch then return RA.launch(proj, entry) end
  return true
end

-- opts: { policy=, force=bool }.  Returns true | nil,"child_running" | nil,"conflicts",bundle
function RA.reattach(proj, entry, opts, bundle)
  opts = opts or {}
  local rec = entry.rec
  if rec.state ~= "detached" then return nil, "This PROJECT is not detached." end
  if not opts.force then
    local h = RA.health(entry)
    if h.state == "ok" or h.state == "stale" then return nil, "child_running" end
  end
  local b = bundle
  if not b then
    local err
    b, err = RA.compare(proj, entry, { policy = opts.policy })
    if not b then return nil, err end
    if not resolve_by_policy(b, opts.policy) then return nil, "conflicts", b end
  end
  local res, err = undo_wrap(proj, "Reattach PROJECT " .. rec.name, function()
    rec.op = "reattach"; ext_set(entry.track, rec)
    local out, cerr = RA.commit(proj, b, { update_parent = true })
    if not out then error(cerr) end
    rec.state = "attached"; rec.shadow = nil; rec.instance_id = nil; rec.launched_at = nil; rec.op = nil
    r.SetMediaTrackInfo_Value(entry.track, "B_MUTE", 0)
    ext_set(entry.track, rec)
    r.GetSetMediaTrackInfo_String(entry.track, "P_NAME", RA.PREFIX .. rec.name, true)
    return out
  end)
  if not res then return nil, err end
  return true
end

-- Interrupted detach / reattach: the record says which one; both are safe to redo because commit() is idempotent.
function RA.finish_interrupted(proj, entry, opts)
  local op = entry.rec.op
  if not op then return true end
  entry.rec.op = nil
  if op == "detach" then entry.rec.state = "attached"; ext_set(entry.track, entry.rec); return RA.detach(proj, entry, opts or { policy = "parent" }) end
  entry.rec.state = "detached"; ext_set(entry.track, entry.rec)
  return RA.reattach(proj, entry, { policy = "parent", force = true })
end

function RA.forget(proj, entry)
  r.GetSetMediaTrackInfo_String(entry.track, "P_EXT:" .. RA.EXT, "", true)
  r.GetSetMediaTrackInfo_String(entry.track, "P_NAME", RA.PREFIX:gsub(": $", "") .. " (unlinked) " .. entry.rec.name, true)
end

--------------------------------------------------------------------------------
-- child instance: launch, commands, health
--------------------------------------------------------------------------------
local function mail_parent(rec) return Mail.parent(fs(), rec.link, RA.clock) end

-- parent time - shift = child time.  shift = attach offset + the child project's start offset (both baked into the parent)
function RA.shift(entry)
  local st = load_state(entry.rec)
  return (st.ctx.offset or 0) + (st.ctx.projoffs or 0)
end

function RA.set_follow(entry, on)
  entry.rec.follow = on and true or false
  ext_set(entry.track, entry.rec)
end

function RA.command(entry, cmd, args)
  return mail_parent(entry.rec).send(cmd, args)
end

function RA.health(entry)
  local rec = entry.rec
  local m = mail_parent(rec)
  return Mail.health.eval(m.status(), rec, RA.clock(), nil, m.boot())
end

function RA.heartbeat(entry, parent_file)
  return mail_parent(entry.rec).heartbeat(parent_file)
end

function RA.facts(entry)
  local rec = entry.rec
  local text = fs().read(rec.file or "")
  local st = load_state(rec)
  return { file_exists = text ~= nil, file_changed = text ~= nil and st.base_hash ~= nil and hash(text) ~= st.base_hash,
           health = RA.health(entry) }
end

function RA.plan(entry) return Mail.recover.plan(entry.rec, RA.facts(entry)) end

-- Finds the REAPER executable. GetExePath() is not the same thing on every platform / version, so try the usual places.
function RA.find_exe()
  local osn = r.GetOS()
  local p = r.GetExePath()
  if osn:match("^Win") then return p .. "\\reaper.exe" end
  if osn:match("^OSX") or osn:match("^macOS") then
    local app = p:gsub("/Contents/MacOS/?$", "")
    local cands = { p .. "/REAPER", app .. "/Contents/MacOS/REAPER", p .. "/REAPER.app/Contents/MacOS/REAPER",
                    "/Applications/REAPER.app/Contents/MacOS/REAPER", "/Applications/REAPER64.app/Contents/MacOS/REAPER" }
    for _, c in ipairs(cands) do if r.file_exists(c) then return c end end
    return cands[1]
  end
  return p .. "/reaper"
end

function RA.launch_command(entry, cfg)
  local rec = entry.rec
  local osn = r.GetOS()
  local exe = RA.find_exe()
  local args = { "-newinst", "-nosplash" }
  if cfg and cfg.own_config then args[#args + 1] = "-cfgfile " .. sq(rec.link .. "/cfg/reaper.ini") end
  args[#args + 1] = sq(rec.file)
  if cfg and cfg.child_script and cfg.child_script ~= "" then args[#args + 1] = sq(cfg.child_script) end
  local log = rec.link .. "/launch.log"
  if osn:match("^Win") then
    return 'start "" ' .. sq(exe):gsub("'", '"') .. " " .. table.concat(args, " "):gsub("'", '"')
  end
  local env = "NP_LINK_DIR=" .. sq(rec.link) .. " NP_ID=" .. sq(rec.instance_id or "")
  return env .. " " .. sq(exe) .. " " .. table.concat(args, " ") .. " >" .. sq(log) .. " 2>&1 &"
end

-- With -cfgfile REAPER treats the folder of that reaper.ini as its whole resource folder: the license, scripts, plugins
-- and actions would be missing (the child then looks like a fresh install on another machine). So the private folder
-- gets its own reaper.ini and LINKS to everything else in the real resource folder.
function RA.prepare_config(rec)
  local res = r.GetResourcePath()
  local dst = rec.link .. "/cfg"
  fs().mkdir(dst)
  if not fs().exists(dst .. "/reaper.ini") then
    local ini = fs().read(res .. "/reaper.ini")
    if not ini then return false end
    fs().write_atomic(dst .. "/reaper.ini", ini)
  end
  if r.GetOS():match("^Win") then
    -- no symlinks without admin rights: copy the files that matter
    for _, name in ipairs({ "reaper-license.rk", "reaper-kb.ini" }) do
      local t = fs().read(res .. "/" .. name)
      if t and not fs().exists(dst .. "/" .. name) then fs().write_atomic(dst .. "/" .. name, t) end
    end
  else
    RA.shell("sh -c " .. sq('RES=' .. sq(res) .. '; DST=' .. sq(dst) .. '; for f in "$RES"/* "$RES"/.[!.]*; do [ -e "$f" ] || continue; '
      .. 'b=$(basename "$f"); case "$b" in reaper.ini|.DS_Store) continue;; esac; '
      .. '[ -e "$DST/$b" ] || [ -L "$DST/$b" ] || ln -s "$f" "$DST/$b"; done'))
  end
  return true
end

function RA.launch(proj, entry, cfg)
  local rec = entry.rec
  if rec.state ~= "detached" then return nil, "Detach the PROJECT first." end
  if not fs().exists(rec.file) then return nil, "Child file is missing: " .. rec.file end
  cfg = cfg or RA.load_cfg()
  rec.instance_id = rec.instance_id or X.random_guid()
  -- marker file so the child helper can find its link folder even without the environment variable
  fs().write_atomic(rec.link .. "/child.json", J.encode({ id = rec.instance_id, parent = RA.project_file(proj), name = rec.name }))
  if cfg.own_config and not RA.prepare_config(rec) then cfg = { child_script = cfg.child_script } end
  -- forget everything a previous launch left behind so health starts from "starting"
  for _, f in ipairs({ "status.json", "boot.json", "launch.log", "helper.log" }) do fs().write_atomic(rec.link .. "/" .. f, "") end
  rec.launched_at = RA.clock()
  ext_set(entry.track, rec)
  local cmd = RA.launch_command(entry, cfg)
  RA.shell(cmd)
  return true, cmd
end

-- Short text for the UI when a child does not come up: what the launch printed and what the helper logged.
function RA.diagnostics(entry)
  local rec = entry.rec
  local function tail(name)
    local t = fs().read(rec.link .. "/" .. name)
    if not t or t == "" then return nil end
    t = t:gsub("%s+$", "")
    return #t > 400 and ("..." .. t:sub(-400)) or t
  end
  return { launch_log = tail("launch.log"), helper_log = tail("helper.log") }
end

return RA

end
__preload["NPApp"] = function(...)
-- NPApp.lua
-- State + main tick. No drawing in here; the UI only reads fields and calls the methods below.

local r = reaper
local RA = require("NPReaper")
local Merge = require("NPMerge")
local Sync = require("NPSync")

local App = {}
App.__index = App

local REFRESH, HEALTH, BEAT, REATTACH_TIMEOUT = 1.0, 0.5, 1.0, 25

function App.new()
  local self = setmetatable({}, App)
  self.proj = r.EnumProjects(-1)
  self.cfg = RA.load_cfg()
  self.entries = {}          -- list of { track, index, rec }
  self.health = {}           -- rec.id -> health table
  self.plans = {}            -- rec.id -> recovery suggestions
  self.pending = nil         -- { op, id, b, opts }   an operation waiting for conflict decisions
  self.waiting = {}          -- rec.id -> { t0 }       reattach waiting for the child to close
  self.syncers, self.was_ok = {}, {}   -- rec.id -> NPSync / bool   transport following
  self.shift = {}            -- rec.id -> seconds between parent time and child time
  self.drift = {}            -- rec.id -> seconds the child is ahead (+) / behind (-) while both play
  self.msg, self.err = nil, nil
  self.t_refresh, self.t_health, self.t_beat = -1e9, -1e9, -1e9
  self.parent_file = nil
  self:refresh()
  return self
end

function App:save() RA.save_cfg(self.cfg) end

function App:say(msg) self.msg, self.err = msg, nil end
function App:fail(err) self.err, self.msg = tostring(err), nil end

function App:entry(id)
  for _, e in ipairs(self.entries) do if e.rec.id == id then return e end end
end

function App:refresh()
  self.proj = r.EnumProjects(-1)
  self.parent_file = RA.project_file(self.proj)
  self.entries = RA.list(self.proj)
  local live = {}
  for _, e in ipairs(self.entries) do
    live[e.rec.id] = true
    self.health[e.rec.id] = RA.health(e)
    self.plans[e.rec.id] = RA.plan(e)
  end
  for id in pairs(self.health) do if not live[id] then self.health[id] = nil; self.plans[id] = nil; self.syncers[id] = nil end end
  for _, e in ipairs(self.entries) do
    if e.rec.state == "detached" then self.shift[e.rec.id] = RA.shift(e) end
  end
end

--------------------------------------------------------------------------------
-- transport following
--------------------------------------------------------------------------------
function App:parent_transport()
  local st = r.GetPlayStateEx and r.GetPlayStateEx(self.proj) or 0
  local paused = (st & 2) ~= 0
  local playing = (st & 1) ~= 0 and not paused
  local pos
  if playing or paused then pos = r.GetPlayPositionEx(self.proj) else pos = r.GetCursorPositionEx(self.proj) end
  return { play = playing, pos = pos, rate = r.Master_GetPlayRate and r.Master_GetPlayRate(self.proj) or 1 }
end

function App:following(e) return e.rec.follow ~= false end

function App:sync_tick(now)
  local ps
  for _, e in ipairs(self.entries) do
    local id = e.rec.id
    if e.rec.state == "detached" then
      local h = self.health[id]
      local ok = h ~= nil and h.state == "ok"
      local sy = self.syncers[id]
      if not sy then sy = Sync.new(self.shift[id] or 0); self.syncers[id] = sy end
      sy:set_shift(self.shift[id] or 0)
      if ok and not self.was_ok[id] then sy:reset() end         -- child just came up: tell it where we are
      self.was_ok[id] = ok
      self.drift[id] = nil
      if ok and self:following(e) then
        ps = ps or self:parent_transport()
        local msg = sy:step(ps, now)
        if msg then
          local seq, err = RA.command(e, "transport", msg)
          if not seq then self:fail(err) end
        end
        if ps.play then self.drift[id] = Sync.drift(h, ps.pos, self.shift[id] or 0, now, ps.rate) end
      elseif not self:following(e) then sy:reset() end          -- switched on again later: resend at once
    end
  end
end

function App:set_follow(id, on)
  local e = self:entry(id); if not e then return end
  RA.set_follow(e, on)
  if self.syncers[id] then self.syncers[id]:reset() end
  self:refresh()
end

function App:tick()
  local now = r.time_precise()
  if now - self.t_refresh > REFRESH then self.t_refresh = now; self:refresh() end
  if now - self.t_health > HEALTH then
    self.t_health = now
    for _, e in ipairs(self.entries) do if e.rec.state == "detached" then self.health[e.rec.id] = RA.health(e) end end
    self:check_waiting(now)
  end
  if now - self.t_beat > BEAT then
    self.t_beat = now
    for _, e in ipairs(self.entries) do
      if e.rec.state == "detached" and self.parent_file then RA.heartbeat(e, self.parent_file) end
    end
  end
  self:sync_tick(now)
end

--------------------------------------------------------------------------------
-- results
--------------------------------------------------------------------------------
-- handles the common (ok | nil,"conflicts",bundle | nil,err) return shape
function App:handle(op, id, opts, ok, err, bundle, done_msg)
  if ok then self:say(done_msg); self:refresh(); return true end
  if err == "conflicts" and bundle then
    self.pending = { op = op, id = id, b = bundle, opts = opts }
    self:say(#bundle.res.conflicts .. " conflict(s): choose which side wins, then Apply.")
    return false
  end
  self:fail(err)
  return false
end

--------------------------------------------------------------------------------
-- operations (id = rec.id)
--------------------------------------------------------------------------------
function App:attach(path, name, offset)
  if not path or path == "" then return self:fail("Choose a .rpp file first.") end
  local entry, info = RA.attach(self.proj, path, { name = (name and name ~= "") and name or nil, offset = offset or 0 })
  if not entry then return self:fail(info) end
  local extra = (info.report and #info.report > 0) and ("  Note: " .. table.concat(info.report, "; ")) or ""
  self:say(string.format("Attached %s (%d tracks).%s", entry.rec.name, info.tracks or 0, extra))
  self:refresh()
  return true
end

function App:make_project()
  local tr = r.GetSelectedTrack(self.proj, 0)
  if not tr then return self:fail("Select a folder track first.") end
  local entry, err = RA.make_project(self.proj, tr)
  if not entry then return self:fail(err) end
  self:say("Created PROJECT " .. entry.rec.name .. ".")
  self:refresh()
  return true
end

function App:sync(id)
  local e = self:entry(id); if not e then return end
  local ok, err, b = RA.sync(self.proj, e, { policy = self.cfg.policy ~= "ask" and self.cfg.policy or nil })
  return self:handle("sync", id, {}, ok, err, b, "Synced " .. e.rec.name .. ".")
end

function App:detach(id, opts)
  local e = self:entry(id); if not e then return end
  opts = opts or {}
  opts.policy = opts.policy or (self.cfg.policy ~= "ask" and self.cfg.policy or nil)
  opts.launch = opts.launch ~= false
  local ok, err, b = RA.detach(self.proj, e, opts)
  return self:handle("detach", id, opts, ok, err, b, "Detached " .. e.rec.name .. (opts.launch and " and started its REAPER instance." or "."))
end

function App:launch(id)
  local e = self:entry(id); if not e then return end
  local ok, err = RA.launch(self.proj, e, self.cfg)
  if not ok then return self:fail(err) end
  self:say("Started a REAPER instance for " .. e.rec.name .. ".")
  self:refresh()
end

function App:diagnostics(id)
  local e = self:entry(id); if not e then return nil end
  return RA.diagnostics(e)
end

function App:launch_command(id)
  local e = self:entry(id); if not e then return nil end
  return RA.launch_command(e, self.cfg)
end

function App:command(id, cmd, args)
  local e = self:entry(id); if not e then return end
  local seq, err = RA.command(e, cmd, args)
  if not seq then return self:fail(err) end
  self.msg, self.err = nil, nil
end

function App:cursor() return r.GetCursorPositionEx and r.GetCursorPositionEx(self.proj) or 0 end

-- the child's cursor to where this project's edit cursor is, in the CHILD's time (offset and start offset removed)
function App:locate_to_cursor(id)
  local e = self:entry(id); if not e then return end
  local shift = self.shift[id] or RA.shift(e)
  return self:command(id, "locate", { pos = math.max(0, self:cursor() - shift) })
end

-- Asks a running child to save and close, waits for it, then merges it back.
function App:reattach(id)
  local e = self:entry(id); if not e then return end
  local h = RA.health(e)
  if h.state == "ok" or h.state == "stale" then
    local seq, err = RA.command(e, "quit")
    if not seq then return self:fail(err) end
    self.waiting[id] = { t0 = r.time_precise() }
    self:say("Asked " .. e.rec.name .. " to save and close...")
    return
  end
  self:finish_reattach(id)
end

function App:finish_reattach(id, force)
  local e = self:entry(id); if not e then return end
  local opts = { policy = self.cfg.policy ~= "ask" and self.cfg.policy or nil, force = force }
  local ok, err, b = RA.reattach(self.proj, e, opts)
  if err == "child_running" then
    return self:fail("The child REAPER is still running. Close it (File > Quit in that window) or use 'Reattach anyway'.")
  end
  return self:handle("reattach", id, opts, ok, err, b, "Reattached " .. e.rec.name .. ".")
end

function App:check_waiting(now)
  for id, w in pairs(self.waiting) do
    local e = self:entry(id)
    if not e then self.waiting[id] = nil
    else
      local h = self.health[id] or RA.health(e)
      if h.state == "closing" or h.state == "lost" or h.state == "not_started" or h.state == "foreign" or h.state == "no_helper" then
        self.waiting[id] = nil
        self:finish_reattach(id, true)
      elseif now - w.t0 > REATTACH_TIMEOUT then
        self.waiting[id] = nil
        self:fail("The child did not close in time. Save and close it yourself, or use 'Reattach anyway'.")
      end
    end
  end
end

function App:forget(id)
  local e = self:entry(id); if not e then return end
  RA.forget(self.proj, e)
  self:say("Unlinked " .. e.rec.name .. " (files left in place).")
  self:refresh()
end

function App:finish_interrupted(id)
  local e = self:entry(id); if not e then return end
  local ok, err, b = RA.finish_interrupted(self.proj, e, { policy = "parent" })
  return self:handle("interrupted", id, {}, ok, err, b, "Finished the interrupted operation.")
end

--------------------------------------------------------------------------------
-- conflicts
--------------------------------------------------------------------------------
function App:choose(n, side)
  if self.pending then Merge.choose(self.pending.b.res, n, side) end
end

function App:choose_all(side)
  if self.pending then Merge.resolve_all(self.pending.b.res, side) end
end

function App:apply_pending()
  local p = self.pending; if not p then return end
  local e = self:entry(p.id); self.pending = nil
  if not e then return self:fail("The PROJECT is gone.") end
  local ok, err, b
  if p.op == "sync" then ok, err = RA.apply_bundle(self.proj, p.b, "Sync PROJECT " .. e.rec.name)
  elseif p.op == "detach" then ok, err, b = RA.detach(self.proj, e, p.opts, p.b)
  elseif p.op == "reattach" then ok, err, b = RA.reattach(self.proj, e, p.opts, p.b)
  else ok, err = RA.apply_bundle(self.proj, p.b) end
  return self:handle(p.op, p.id, p.opts, ok, err, b, "Done.")
end

function App:cancel_pending()
  self.pending = nil
  self:say("Cancelled: nothing was changed.")
end

return App

end
__preload["NPUI"] = function(...)
-- NPUI.lua
-- ReaImGui front-end. Reads App state, calls App methods. Same style as PrototypeSequence.

local r = reaper
local V = require("NPVersion")
local X = require("NPXform")
local Merge = require("NPMerge")

local UI = {}
UI.__index = UI

local COL_HEAD = 0xFFCC44FF
local COL_OK   = 0x5FE07FFF
local COL_BAD  = 0xFF5F5FFF
local COL_WARN = 0xFFAA33FF
local COL_DIM  = 0x999999FF
local COL_INFO = 0x6FB7FFFF

-- Accent colour scheme. Hue 262 deg (from #4700C2); saturation, brightness and alpha are those of ImGui's default dark
-- style (its blue is hue 212 deg), so buttons/headers are translucent like the default instead of solid and heavy.
local BG = 0x181A1AFF
local THEME = {
  { "WindowBg", BG }, { "PopupBg", BG }, { "ChildBg", BG },
  { "FrameBg", 0x47297A8A }, { "FrameBgHovered", 0x8542FA66 }, { "FrameBgActive", 0x8542FAAB },
  { "Button", 0x8542FA66 }, { "ButtonHovered", 0x8542FAFF }, { "ButtonActive", 0x650FFAFF },
  { "SliderGrab", 0x793DE0FF }, { "SliderGrabActive", 0x8542FAFF }, { "CheckMark", 0x8542FAFF },
  { "Header", 0x8542FA4F }, { "HeaderHovered", 0x8542FACC }, { "HeaderActive", 0x8542FAFF },
  { "PlotHistogram", 0x8542FAFF }, { "TitleBgActive", 0x47297AFF },
}

local HEALTH_TEXT = {
  ok = { "running", COL_OK }, starting = { "starting...", COL_WARN }, booted = { "helper up, waiting...", COL_WARN },
  stale = { "not responding", COL_WARN }, lost = { "lost", COL_BAD }, closing = { "closing", COL_WARN },
  foreign = { "unknown instance", COL_BAD }, no_helper = { "helper not started", COL_BAD },
  not_started = { "not started", COL_DIM },
}

function UI.new(app)
  local self = setmetatable({}, UI)
  self.A = app
  self.ctx = r.ImGui_CreateContext("NestedProjects")
  self.title = "NestedProjects v" .. V.VERSION .. "###nested_projects_main"
  self.offset = 0.0
  self.name_buf = ""
  self.script_buf = nil
  return self
end

function UI:tip(text)
  if r.ImGui_IsItemHovered(self.ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(self.ctx, text) end
end

function UI:heading(text)
  local ctx = self.ctx
  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, COL_HEAD, text)
  r.ImGui_Separator(ctx)
end

-- small button that also carries a tooltip; returns true when clicked
function UI:btn(label, tip, disabled)
  local ctx = self.ctx
  if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
  local clicked = r.ImGui_SmallButton(ctx, label)
  if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
  if tip then self:tip(tip) end
  return clicked and not disabled
end

--------------------------------------------------------------------------------
function UI:draw_top()
  local A, ctx = self.A, self.ctx
  if not A.parent_file then
    r.ImGui_TextColored(ctx, COL_WARN, "Save the parent project first: child projects are stored next to it (PROJECTS/<name>/).")
  else
    r.ImGui_TextColored(ctx, COL_DIM, A.parent_file)
  end
  r.ImGui_Spacing(ctx)
  local ch, v = r.ImGui_InputDouble(ctx, "Start offset (s)##offset", self.offset)
  if ch then self.offset = v end
  self:tip("Where the child's time zero lands in this project. Applies to the next 'Attach'.")
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Attach .rpp...") then
    local ok, path = r.GetUserFileNameForRead("", "Choose the child project to attach", "rpp")
    if ok and path and path ~= "" then A:attach(path, nil, self.offset) end
  end
  self:tip("Adds the file's tracks below a new PROJECT folder. A working copy is made in PROJECTS/<name>/; your original is never touched.")
  if r.ImGui_Button(ctx, "Make PROJECT from selected folder") then A:make_project() end
  self:tip("Turns the selected folder track and its children into a PROJECT, so they can be detached into their own REAPER.")
end

local function health_of(A, e)
  local h = A.health[e.rec.id]
  return h and h.state or "not_started"
end

function UI:draw_projects()
  local A, ctx = self.A, self.ctx
  self:heading("PROJECT tracks")
  if #A.entries == 0 then
    r.ImGui_TextColored(ctx, COL_DIM, "None yet. Attach a .rpp, or select a folder track and press 'Make PROJECT'.")
    return
  end
  local flags = r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()
  if r.ImGui_BeginTable(ctx, "projects", 4, flags) then
    r.ImGui_TableSetupColumn(ctx, "Name", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "State", r.ImGui_TableColumnFlags_WidthFixed(), 100)
    r.ImGui_TableSetupColumn(ctx, "Child REAPER", r.ImGui_TableColumnFlags_WidthFixed(), 130)
    r.ImGui_TableSetupColumn(ctx, "Actions", r.ImGui_TableColumnFlags_WidthStretch(), 5)
    r.ImGui_TableHeadersRow(ctx)
    for _, e in ipairs(A.entries) do
      local rec = e.rec
      r.ImGui_PushID(ctx, rec.id)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx, rec.name)
      r.ImGui_TableNextColumn(ctx)
      if rec.state == "attached" then r.ImGui_TextColored(ctx, COL_OK, "attached")
      else r.ImGui_TextColored(ctx, COL_INFO, rec.shadow and "detached (shadow)" or "detached") end
      r.ImGui_TableNextColumn(ctx)
      if rec.state == "detached" then
        local hs = health_of(A, e)
        local t = HEALTH_TEXT[hs] or { hs, COL_DIM }
        local h = A.health[rec.id] or {}
        local extra = ""
        if hs == "ok" then extra = (h.play and (h.play & 1) == 1) and string.format("  play %.1fs", h.pos or 0) or "  stopped" end
        if h.dirty then extra = extra .. "  *" end
        local d = A.drift[rec.id]
        if d then extra = extra .. string.format("  %+.0f ms", d * 1000) end
        r.ImGui_TextColored(ctx, t[2], t[1] .. extra)
        if h.device_err then r.ImGui_TextColored(ctx, COL_BAD, h.device_err) end
      else r.ImGui_TextColored(ctx, COL_DIM, "-") end
      r.ImGui_TableNextColumn(ctx)
      self:draw_actions(e)
      r.ImGui_PopID(ctx)
    end
    r.ImGui_EndTable(ctx)
  end
  for _, e in ipairs(A.entries) do self:draw_plan(e); self:draw_diagnostics(e) end
end

-- what to do when a detached child does not come up
function UI:draw_diagnostics(e)
  local A, ctx = self.A, self.ctx
  if e.rec.state ~= "detached" then return end
  local hs = health_of(A, e)
  if hs ~= "no_helper" and hs ~= "lost" and hs ~= "starting" and hs ~= "booted" then return end
  local d = A:diagnostics(e.rec.id) or {}
  if hs == "no_helper" then
    r.ImGui_TextColored(ctx, COL_BAD, e.rec.name .. ": a REAPER may have opened, but the helper script did not start in it.")
    r.ImGui_TextWrapped(ctx, "In that child REAPER window run the action 'Script: NestedProjectsChild.lua' once (Actions > Show action list). It finds its folder by itself. If no second REAPER opened at all, see the launch log below.")
  elseif hs == "lost" then
    r.ImGui_TextColored(ctx, COL_WARN, e.rec.name .. ": the child stopped answering (closed or crashed). Relaunch it, or Reattach to take the saved file back.")
  end
  if d.launch_log then r.ImGui_TextColored(ctx, COL_DIM, "launch.log: " .. d.launch_log) end
  if d.helper_log then r.ImGui_TextColored(ctx, COL_BAD, "helper.log: " .. d.helper_log) end
  if hs == "no_helper" or hs == "lost" then
    r.ImGui_PushID(ctx, "diag" .. e.rec.id)
    if self:btn("Copy launch command", "Paste it into Terminal to see exactly what happens.") then
      if r.ImGui_SetClipboardText then r.ImGui_SetClipboardText(ctx, A:launch_command(e.rec.id) or "") end
    end
    r.ImGui_PopID(ctx)
  end
end

function UI:draw_actions(e)
  local A, ctx = self.A, self.ctx
  local rec, id = e.rec, e.rec.id
  local busy = A.pending ~= nil or A.waiting[id] ~= nil
  if rec.state == "attached" then
    if self:btn("Sync", "Compare the tracks here with the child file and merge both ways.", busy) then A:sync(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Detach", "Move the tracks out into their own REAPER instance (its own audio device and transport).", busy) then A:detach(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Detach (keep shadow)", "Same, but keep muted copies here. Edits made on both sides are merged on reattach.", busy) then A:detach(id, { shadow = true }) end
  else
    local hs = health_of(A, e)
    local running = hs == "ok" or hs == "stale"
    local follow = A:following(e)
    if self:btn("Launch", "Start the child REAPER instance.", busy or running) then A:launch(id) end
    r.ImGui_SameLine(ctx)
    local ch, on = r.ImGui_Checkbox(ctx, "Follow", follow)
    if ch then A:set_follow(id, on) end
    self:tip("The child plays, stops and seeks with this project's transport (its start offset is taken into account). The number in the Child REAPER column is how far ahead (+) or behind (-) it is.")
    r.ImGui_SameLine(ctx)
    local manual_off = busy or not running or follow
    local why = follow and "Switch Follow off to control the child by hand." or nil
    if self:btn("Play", why, manual_off) then A:command(id, "play") end
    r.ImGui_SameLine(ctx)
    if self:btn("Stop", why, manual_off) then A:command(id, "stop") end
    r.ImGui_SameLine(ctx)
    if self:btn("Go to cursor", "Move the child's cursor to this project's edit cursor (offsets taken into account).", busy or not running) then A:locate_to_cursor(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Save", "Ask the child to save its project.", busy or not running) then A:command(id, "save") end
    r.ImGui_SameLine(ctx)
    if self:btn("Reattach", "Ask the child to save and close, then merge its tracks back in here.", busy) then A:reattach(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Reattach anyway", "Merge the child file as it is on disk now, even if the child is still running.", busy) then A:finish_reattach(id, true) end
  end
  r.ImGui_SameLine(ctx)
  if self:btn("Unlink", "Forget this PROJECT here. Files stay on disk.", busy) then A:forget(id) end
end

function UI:draw_plan(e)
  local A, ctx = self.A, self.ctx
  local plan = A.plans[e.rec.id]
  if not plan or #plan == 0 then return end
  for _, p in ipairs(plan) do
    r.ImGui_TextColored(ctx, COL_WARN, string.format("%s: %s", e.rec.name, p.why))
    if p.action:match("^finish_or_rollback") then
      r.ImGui_SameLine(ctx)
      r.ImGui_PushID(ctx, "fin" .. e.rec.id)
      if self:btn("Finish it", "Redo the interrupted operation (safe to repeat).") then A:finish_interrupted(e.rec.id) end
      r.ImGui_PopID(ctx)
    end
  end
end

function UI:draw_pending()
  local A, ctx = self.A, self.ctx
  local p = A.pending
  if not p then return end
  local res = p.b.res
  self:heading("Conflicts: " .. #res.conflicts .. " (nothing has been changed yet)")
  r.ImGui_TextWrapped(ctx, "Both the tracks here and the child file changed the same thing. Choose a side for each; everything else merges automatically.")
  if r.ImGui_Button(ctx, "All: this project") then A:choose_all("parent") end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "All: child file") then A:choose_all("child") end
  for _, cf in ipairs(res.conflicts) do
    r.ImGui_PushID(ctx, "cf" .. cf.n)
    local label = Merge.describe(res, cf)
    if cf.kind == "delete_edit" then
      local other = (cf.deleted_side == "parent") and "child file" or "this project"
      if self:btn((cf.choice == cf.deleted_side) and "[delete]" or "delete", "Delete it") then A:choose(cf.n, cf.deleted_side) end
      r.ImGui_SameLine(ctx)
      if self:btn((cf.choice ~= cf.deleted_side) and "[keep]" or "keep", "Keep it (" .. other .. " still has it)") then A:choose(cf.n, cf.deleted_side == "parent" and "child" or "parent") end
    else
      if self:btn(cf.choice == "parent" and "[this project]" or "this project") then A:choose(cf.n, "parent") end
      r.ImGui_SameLine(ctx)
      if self:btn(cf.choice == "child" and "[child file]" or "child file") then A:choose(cf.n, "child") end
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, label)
    r.ImGui_PopID(ctx)
  end
  r.ImGui_Spacing(ctx)
  if r.ImGui_Button(ctx, "Apply") then A:apply_pending() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Cancel") then A:cancel_pending() end
end

function UI:draw_settings()
  local A, ctx = self.A, self.ctx
  if not r.ImGui_CollapsingHeader(ctx, "Settings") then return end
  r.ImGui_Text(ctx, "When both sides changed the same thing:")
  for _, pol in ipairs({ "ask", "parent", "child" }) do
    r.ImGui_SameLine(ctx)
    local label = (A.cfg.policy == pol) and ("[" .. pol .. "]") or pol
    if r.ImGui_SmallButton(ctx, label .. "##pol" .. pol) then A.cfg.policy = pol; A:save() end
  end
  local ch, v = r.ImGui_Checkbox(ctx, "Give each child its own REAPER config (experimental)", A.cfg.own_config)
  if ch then A.cfg.own_config = v; A:save() end
  self:tip("Off by default. The child gets its own copy of reaper.ini (so it can use another audio device); your license, scripts, plugins and actions are linked in from the normal REAPER folder. Changes made in the child window to other shared files are shared too.")
  self.script_buf = self.script_buf or A.cfg.child_script or ""
  local ch2, s = r.ImGui_InputText(ctx, "Child helper script##script", self.script_buf)
  if ch2 then self.script_buf = s; A.cfg.child_script = s; A:save() end
  if A.cfg.child_script == "" then r.ImGui_TextColored(ctx, COL_WARN, "No helper script set: children will run but cannot be controlled or monitored.") end
end

function UI:draw_policy()
  local ctx = self.ctx
  if not r.ImGui_CollapsingHeader(ctx, "What happens to project-level features on attach") then return end
  for _, row in ipairs(X.POLICY) do
    local col = (row[3] == "done" or row[3] == "glue") and COL_OK or (row[3] == "ignore" and COL_DIM or COL_WARN)
    r.ImGui_TextColored(ctx, col, string.format("%-30s %s", row[1], row[2]))
  end
end

function UI:draw()
  local A, ctx = self.A, self.ctx
  self:draw_top()
  self:draw_projects()
  self:draw_pending()
  r.ImGui_Spacing(ctx)
  if A.err then r.ImGui_TextColored(ctx, COL_BAD, A.err)
  elseif A.msg then r.ImGui_TextColored(ctx, COL_OK, A.msg) end
  self:draw_settings()
  self:draw_policy()
end

-- pushes the accent colours; returns how many were pushed (an unknown colour name in an old ReaImGui is skipped, not fatal)
local function push_theme(ctx)
  local n = 0
  for _, c in ipairs(THEME) do
    local get = r["ImGui_Col_" .. c[1]]
    if get then r.ImGui_PushStyleColor(ctx, get(), c[2]); n = n + 1 end
  end
  return n
end

function UI:frame()
  local ctx = self.ctx
  local pushed = push_theme(ctx)
  r.ImGui_SetNextWindowSize(ctx, 900, 520, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, self.title, true)
  if visible then
    local ok, e = pcall(self.draw, self)
    if not ok then self.A.err = "UI error: " .. tostring(e) end
    r.ImGui_End(ctx)
  end
  r.ImGui_PopStyleColor(ctx, pushed)       -- also when the window is collapsed: the colour stack must stay balanced
  return open
end

return UI

end

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "NestedProjects", 0)
  return
end

local App = require("NPApp")
local UI  = require("NPUI")
local RA  = require("NPReaper")

local EXT = "NestedProjectsApp"

local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

math.randomseed(os.time())
local app = App.new()
-- the helper script lives next to this one; remember it unless the user chose another
if (app.cfg.child_script or "") == "" then
  local cand = dir .. "NestedProjectsChild.lua"
  if r.file_exists(cand) then app.cfg.child_script = cand; app:save() end
end
local ui = UI.new(app)

local function shutdown()
  app:save()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end
  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then last_err = tostring(err); app.err = "Error: " .. last_err end
  if ui:frame() then r.defer(loop) else shutdown() end
end

loop()

