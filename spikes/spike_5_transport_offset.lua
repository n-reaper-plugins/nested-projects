-- @description NestedProjects spike 5: time offsets and the clock shared between two REAPER instances
-- Part A (run in ONE REAPER, in a project whose Project settings > Project start time is e.g. -2): do API times include the start offset?
-- Part B (run in BOTH the parent and a child REAPER at about the same time): is r.time_precise() the same clock in both?
local r = reaper
local function out(s) r.ShowConsoleMsg(s .. "\n") end
out("=== SPIKE 5")

-- Part A
local off = r.GetProjectTimeOffset(0, false)
out("project start time offset (GetProjectTimeOffset): " .. tostring(off))
r.SetEditCurPos(5, false, false)
local api = r.GetCursorPosition()
out(string.format("SetEditCurPos(5) then GetCursorPosition() = %.3f", api))
out("ruler text for that position (format_timestr_pos(pos,'',3), seconds): " .. r.format_timestr_pos(api, "", 3))
out("  -> if the ruler text is api+offset (" .. string.format("%.3f", api + off) .. ") the API uses internal time and NestedProjects' maths is right;")
out("     if it equals api (" .. string.format("%.3f", api) .. "), the API uses displayed time and the child shift must not include its start offset: tell me.")

-- Part B
local label = string.format("%04x", math.random(0, 65535))
local n, t0 = 0, r.time_precise()
local f = io.open("/tmp/np_clock.txt", "ab")
local function tick()
  if f and n < 12 then
    f:write(string.format("%s  os.time=%d  time_precise=%.3f\n", label, os.time(), r.time_precise())); f:flush()
    n = n + 1
    r.defer(function() local t = r.time_precise(); if t - t0 >= n * 0.5 then tick() else r.defer(tick) end end)
  else
    if f then f:close() end
    out("clock samples appended to /tmp/np_clock.txt as label " .. label .. ". Run this in the other REAPER too, then `cat /tmp/np_clock.txt` and paste it.")
    out("Good sign: for two lines with equal os.time, time_precise differs by less than ~1 s between the two labels.")
    out("=== end of spike 5")
  end
end
tick()
