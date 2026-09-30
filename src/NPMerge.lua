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
