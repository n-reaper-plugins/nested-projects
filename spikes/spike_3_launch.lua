-- @description NestedProjects spike 3: can we start a second REAPER with its own config, and does our script run in it? (macOS)
local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
local function out(s) r.ShowConsoleMsg(s .. "\n") end
out("=== SPIKE 3")
os.execute("mkdir -p /tmp/np_spike_link && rm -f /tmp/np_spike_link/probe.txt")
local f = io.open("/tmp/np_spike.rpp", "wb"); f:write('<REAPER_PROJECT 0.1 "7.0" 0\n  TEMPO 120 4 4\n>\n'); f:close()
-- private config folder: own reaper.ini + links to everything else (license, scripts, plugins), like NestedProjects does
os.execute("mkdir -p /tmp/np_spike_link/cfg")
local ini = io.open(r.GetResourcePath() .. "/reaper.ini", "rb")
if ini then local s = ini:read("*a"); ini:close(); local o = io.open("/tmp/np_spike_link/cfg/reaper.ini", "wb"); o:write(s); o:close() end
os.execute("RES='" .. r.GetResourcePath() .. "'; DST=/tmp/np_spike_link/cfg; for f in \"$RES\"/* \"$RES\"/.[!.]*; do [ -e \"$f\" ] || continue; b=$(basename \"$f\"); case \"$b\" in reaper.ini|.DS_Store) continue;; esac; [ -e \"$DST/$b\" ] || [ -L \"$DST/$b\" ] || ln -s \"$f\" \"$DST/$b\"; done")
local use_cfg = r.MB("Start the test child WITH -cfgfile (own copy of reaper.ini)?\n\nYes = with,  No = without.\nRun it once without first, then once with.", "spike 3", 4) == 6
local exe
for _, c in ipairs({ r.GetExePath() .. "/REAPER", r.GetExePath() .. "/Contents/MacOS/REAPER", "/Applications/REAPER.app/Contents/MacOS/REAPER" }) do
  if r.file_exists(c) then exe = c; break end
end
exe = exe or (r.GetExePath() .. "/REAPER")
out("executable: " .. exe .. "   (found: " .. tostring(r.file_exists(exe)) .. ")   with -cfgfile: " .. tostring(use_cfg))
local cmd = "NP_LINK_DIR='/tmp/np_spike_link' NP_ID='spike' '" .. exe .. "' -newinst -nosplash " .. (use_cfg and "-cfgfile '/tmp/np_spike_link/cfg/reaper.ini' " or "") .. "'/tmp/np_spike.rpp' '" .. dir .. "spike_3_child_probe.lua' >/tmp/np_spike_link/launch.log 2>&1 &"
out("running: " .. cmd)
out("os: " .. r.GetOS() .. "   exe path: " .. r.GetExePath())
out("execute returned: " .. tostring(os.execute(cmd)))
out("waiting up to 40 s for /tmp/np_spike_link/probe.txt ...")
local t0 = r.time_precise()
local function poll()
  local p = io.open("/tmp/np_spike_link/probe.txt", "rb")
  if p then
    out("--- the child says:\n" .. p:read("*a")); p:close()
    out("Now look at the NEW REAPER window: is it licensed (Help > About / no nag)? Preferences > Audio: can you pick a different device than in this REAPER?")
    out("When done, quit the new instance yourself (Cmd+Q in ITS window).\n=== end of spike 3")
    return
  end
  if r.time_precise() - t0 > 40 then
    out("no probe.txt after 40 s. Did a second REAPER window open?  (yes + no probe = the script argument was not run: tell me)")
    local lg = io.open("/tmp/np_spike_link/launch.log", "rb")
    if lg then out("launch.log:\n" .. lg:read("*a")); lg:close() end
    out("=== end of spike 3")
    return
  end
  r.defer(poll)
end
poll()
