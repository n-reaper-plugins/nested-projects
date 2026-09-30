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
