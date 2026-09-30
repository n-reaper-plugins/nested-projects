-- In-memory stand-in for the parts of REAPER that NPReaper uses. It checks OUR logic, not REAPER's behaviour.
-- Deliberately awkward on purpose:
--   * GetTrackStateChunk adds default lines ("MAINSEND 1 0", NAME) that the source did not have  -> false-change test
--   * SetTrackStateChunk wipes the track's P_EXT                                                  -> worst case
package.path = "./src/?.lua;" .. package.path
local Rpp = require("NPRpp")

local M = {}

function M.install()
  local S = { tracks = {}, markers = {}, ext = {}, files = {}, dirs = {}, shell = {}, clock = 1000, guid_n = 0, undo = 0,
              project_file = "/proj/Main.rpp", tempo = 120 }
  M.S = S
  local function new_guid() S.guid_n = S.guid_n + 1; return string.format("{00000000-0000-0000-0000-%012X}", S.guid_n) end
  local function chunk_guid(c) return c:match("^<TRACK%s+(%b{})") end
  local function depth_of(chunk)
    local n = Rpp.parse(chunk)
    local l = n and Rpp.leaf(n, "ISBUS")
    return l and tonumber(Rpp.tok(l)[3]) or 0
  end
  local function idx_of(tr) for i, t in ipairs(S.tracks) do if t == tr then return i end end end

  local R = {}
  reaper = R

  function M.new_track(name, depth)
    local g = new_guid()
    local tr = { chunk = string.format("<TRACK %s\n  NAME %s\n  ISBUS %d %d\n  VOLPAN 1 0 -1 -1 1\n>\n", g, Rpp.quote(name), depth > 0 and 1 or (depth < 0 and 2 or 0), depth),
                 depth = depth, ext = {}, mute = 0 }
    S.tracks[#S.tracks + 1] = tr
    return tr
  end

  function R.EnumProjects(i) if i == -1 or i == 0 then return "P", S.project_file end end
  function R.CountTracks() return #S.tracks end
  function R.GetTrack(_, i) return S.tracks[i + 1] end
  function R.InsertTrackAtIndex(i)
    local tr = { chunk = string.format("<TRACK %s\n  NAME \"\"\n>\n", new_guid()), depth = 0, ext = {}, mute = 0 }
    table.insert(S.tracks, i + 1, tr)
  end
  function R.DeleteTrack(tr) table.remove(S.tracks, idx_of(tr)) end
  function R.GetTrackGUID(tr) return chunk_guid(tr.chunk) end

  function R.GetTrackStateChunk(tr)
    local n = Rpp.parse(tr.chunk)
    if not Rpp.leaf(n, "NAME") then table.insert(n.items, 1, Rpp.new_leaf("NAME", "")) end
    Rpp.set_leaf(n, "ISBUS", tr.depth > 0 and 1 or (tr.depth < 0 and 2 or 0), tr.depth)
    if not Rpp.leaf(n, "MAINSEND") then
      local pos = 1
      for i, c in ipairs(n.items) do if c.kind == "leaf" then pos = i + 1 end end
      table.insert(n.items, pos, Rpp.new_leaf("MAINSEND", 1, 0))
    end
    return true, Rpp.serialize(n)
  end
  function R.SetTrackStateChunk(tr, chunk)
    tr.chunk = chunk; tr.depth = depth_of(chunk); tr.ext = {}
    return true
  end

  function R.GetSetMediaTrackInfo_String(tr, key, val, set)
    local k = key:match("^P_EXT:(.+)$")
    if k then
      if set then tr.ext[k] = val; return true, val end
      return true, tr.ext[k] or ""
    end
    if key == "P_NAME" then
      local n = Rpp.parse(tr.chunk)
      if set then Rpp.set_leaf(n, "NAME", val); tr.chunk = Rpp.serialize(n); return true, val end
      local l = Rpp.leaf(n, "NAME")
      return true, l and Rpp.tok(l)[2] or ""
    end
    return false, ""
  end
  function R.GetMediaTrackInfo_Value(tr, key)
    if key == "I_FOLDERDEPTH" then return tr.depth end
    if key == "B_MUTE" then return tr.mute end
    if key == "IP_TRACKNUMBER" then return idx_of(tr) end
    return 0
  end
  function R.SetMediaTrackInfo_Value(tr, key, v)
    if key == "I_FOLDERDEPTH" then tr.depth = v elseif key == "B_MUTE" then tr.mute = v end
    return true
  end

  -- markers
  function R.EnumProjectMarkers3(_, i)
    local m = S.markers[i + 1]
    if not m then return 0 end
    return i + 1, m.isrgn, m.pos, m.rgnend, m.name, m.num, m.color
  end
  function R.AddProjectMarker2(_, isrgn, pos, rgnend, name, want, color)
    S.markers[#S.markers + 1] = { isrgn = isrgn, pos = pos, rgnend = rgnend, name = name, num = want, color = color }
    return want
  end
  function R.DeleteProjectMarker(_, num, isrgn)
    for i, m in ipairs(S.markers) do if m.num == num and m.isrgn == isrgn then table.remove(S.markers, i); return true end end
  end
  function R.SetProjectMarker4(_, num, isrgn, pos, rgnend, name, color)
    for _, m in ipairs(S.markers) do
      if m.num == num and m.isrgn == isrgn then m.pos, m.rgnend, m.name, m.color = pos, rgnend, name, color; return true end
    end
  end

  function R.time_precise() return S.clock end
  function R.GetSelectedTrack(_, i) return S.selected and i == 0 and S.selected or nil end
  function R.GetCursorPositionEx() return S.cursor or 0 end
  function R.GetPlayStateEx() return S.play_state or 0 end
  function R.GetPlayPositionEx() return S.play_pos or 0 end
  function R.Master_GetPlayRate() return S.rate or 1 end
  function R.GetUserFileNameForRead() return S.picked_file ~= nil, S.picked_file or "" end
  function R.Undo_BeginBlock2() end
  function R.Undo_EndBlock2() S.undo = S.undo + 1 end
  function R.PreventUIRefresh() end
  function R.UpdateArrange() end
  function R.GetExtState(sec, k) return S.ext[sec .. "/" .. k] or "" end
  function R.SetExtState(sec, k, v) S.ext[sec .. "/" .. k] = v end
  function R.GetOS() return "OSX64" end
  function R.GetExePath() return "/Applications/REAPER.app/Contents/MacOS" end
  function R.GetResourcePath() return "/Users/x/Library/Application Support/REAPER" end
  function R.Master_GetTempo() return S.tempo end
  function R.file_exists(p) return S.files[p] ~= nil end
  function R.RecursiveCreateDirectory(p) S.dirs[p] = true; return 1 end

  -- fs + shell for NPReaper
  local fs = {
    read = function(p) return S.files[p] end,
    write_atomic = function(p, s) S.files[p] = s; return true end,
    exists = function(p) return S.files[p] ~= nil end,
    mkdir = function(p) S.dirs[p] = true end,
  }
  M.fs = fs
  M.shell = function(cmd) S.shell[#S.shell + 1] = cmd; return true end
  return S
end

-- test helpers
function M.edit_track(tr, fn)
  local n = Rpp.parse(tr.chunk)
  fn(n)
  tr.chunk = Rpp.serialize(n)
  tr.depth = (function() local l = Rpp.leaf(n, "ISBUS"); return l and tonumber(Rpp.tok(l)[3]) or 0 end)()
end

function M.names()
  local out = {}
  for _, tr in ipairs(M.S.tracks) do
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    out[#out + 1] = nm
  end
  return out
end

function M.depth_sum()
  local d = 0
  for _, tr in ipairs(M.S.tracks) do d = d + tr.depth end
  return d
end

function M.track_named(name)
  for _, tr in ipairs(M.S.tracks) do
    local _, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if nm == name then return tr end
  end
end

return M
