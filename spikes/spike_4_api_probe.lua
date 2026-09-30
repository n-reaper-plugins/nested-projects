-- @description NestedProjects spike 4: which API functions exist here, and what do markers return?
local r = reaper
local function out(s) r.ShowConsoleMsg(s .. "\n") end
out("=== SPIKE 4   REAPER " .. r.GetAppVersion() .. "   " .. r.GetOS())
local names = { "GetTrackStateChunk", "SetTrackStateChunk", "GetTrackGUID", "InsertTrackAtIndex", "DeleteTrack", "EnumProjectMarkers3",
  "AddProjectMarker2", "SetProjectMarker4", "DeleteProjectMarker", "GetSetMediaTrackInfo_String", "GetTrackDepth", "Main_SaveProject",
  "IsProjectDirty", "GetAudioDeviceInfo", "GetExePath", "GetResourcePath", "RecursiveCreateDirectory", "GetUserFileNameForRead",
  "ImGui_CreateContext", "JS_Dialog_BrowseForOpenFiles", "ExecProcess", "CF_SetClipboard" }
local missing = {}
for _, n in ipairs(names) do if not r[n] then missing[#missing + 1] = n end end
out("missing functions: " .. (#missing == 0 and "none" or table.concat(missing, ", ")))
out("(ImGui_* / JS_* / CF_* missing just means that extension is not installed)")

-- marker numbering
local cnt = 0
local i = 0
while true do local ok = r.EnumProjectMarkers3(0, i); if not ok or ok == 0 then break end i = i + 1 end
out("project has " .. i .. " markers/regions already")
local want = 9001
local ret = r.AddProjectMarker2(0, false, 1.0, 1.0, "np spike marker", want, 0)
out("AddProjectMarker2(want=" .. want .. ") returned: " .. tostring(ret))
local j = 0
while true do
  local ok, isrgn, pos, rgnend, name, num, color = r.EnumProjectMarkers3(0, j)
  if not ok or ok == 0 then break end
  if name == "np spike marker" then out(string.format("  enumerated: index=%s isrgn=%s pos=%s number=%s color=%s", tostring(ok), tostring(isrgn), pos, num, color)) end
  j = j + 1
end
out("SetProjectMarker4 -> " .. tostring(r.SetProjectMarker4(0, want, false, 2.0, 2.0, "np spike marker", 0, 0)))
out("DeleteProjectMarker -> " .. tostring(r.DeleteProjectMarker(0, want, false)))
if r.GetTrackDepth and r.CountTracks(0) > 0 then out("GetTrackDepth(track 0) = " .. tostring(r.GetTrackDepth(r.GetTrack(0, 0)))) end
out("=== end of spike 4")
