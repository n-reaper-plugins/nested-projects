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
