-- @description NestedProjects spike 2: does a track chunk survive Get/SetTrackStateChunk? (select ONE track first)
local r = reaper
local function out(s) r.ShowConsoleMsg(s .. "\n") end
local tr = r.GetSelectedTrack(0, 0)
if not tr then r.MB("Select one track (ideally one with items, FX and a send).", "spike 2", 0); return end
out("=== SPIKE 2")
r.Undo_BeginBlock()
local _, chunk = r.GetTrackStateChunk(tr, "", false)
out("chunk starts: " .. chunk:sub(1, chunk:find("\n") or 60))
out("has TRACKID line: " .. tostring(chunk:find("\n%s*TRACKID") ~= nil))
for _, k in ipairs({ "ISBUS", "BEAT", "AUXRECV", "MAINSEND", "IGUID" }) do
  local l = chunk:match("\n%s*(" .. k .. "[^\n]*)")
  out(string.format("  %-9s %s", k, l or "(absent)"))
end

-- does P_EXT live inside the chunk?
r.GetSetMediaTrackInfo_String(tr, "P_EXT:NP_SPIKE", "hello", true)
local _, chunk2 = r.GetTrackStateChunk(tr, "", false)
out("P_EXT appears in the chunk text: " .. tostring(chunk2:find("NP_SPIKE", 1, true) ~= nil))

-- new track from the chunk, with a fresh GUID
local newg = "{" .. string.format("%08X-4E50-4E50-4E50-%012X", math.random(0, 2^31), math.random(0, 2^31)) .. "}"
local c3 = chunk2:gsub("^<TRACK%s+%b{}", "<TRACK " .. newg, 1)
local n = r.CountTracks(0)
r.InsertTrackAtIndex(n, false)
local t2 = r.GetTrack(0, n)
r.GetSetMediaTrackInfo_String(t2, "P_EXT:NP_OTHER", "keep me?", true)
local ok = r.SetTrackStateChunk(t2, c3, false)
out("SetTrackStateChunk returned: " .. tostring(ok))
out("GUID after Set equals the one we wrote: " .. tostring(r.GetTrackGUID(t2) == newg) .. "   (" .. tostring(r.GetTrackGUID(t2)) .. ")")
local _, e1 = r.GetSetMediaTrackInfo_String(t2, "P_EXT:NP_SPIKE", "", false)
local _, e2 = r.GetSetMediaTrackInfo_String(t2, "P_EXT:NP_OTHER", "", false)
out("P_EXT carried by the chunk: '" .. tostring(e1) .. "'   P_EXT set before SetTrackStateChunk survived: '" .. tostring(e2) .. "'")
local _, c4 = r.GetTrackStateChunk(t2, "", false)
local a = c3:gsub("%s+", " "); local b = c4:gsub("%s+", " ")
out("chunk read back identical to the chunk written: " .. tostring(a == b))
if a ~= b then
  local i = 1; while a:sub(i, i) == b:sub(i, i) and i < #a do i = i + 1 end
  out("  first difference near: ..." .. a:sub(math.max(1, i - 30), i + 40) .. "  <>  " .. b:sub(math.max(1, i - 30), i + 40))
end

-- folder depth from a chunk
local c5 = c4:gsub("\n%s*ISBUS[^\n]*", "\n  ISBUS 1 1", 1)
r.SetTrackStateChunk(t2, c5, false)
out("after writing 'ISBUS 1 1': I_FOLDERDEPTH = " .. tostring(r.GetMediaTrackInfo_Value(t2, "I_FOLDERDEPTH")))
r.DeleteTrack(t2)
r.GetSetMediaTrackInfo_String(tr, "P_EXT:NP_SPIKE", "", true)
r.Undo_EndBlock("NestedProjects spike 2", -1)
r.Undo_DoUndo2(0)
out("(test track deleted, selected track's spike tag removed, undo applied)")
out("=== end of spike 2")
