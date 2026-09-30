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
