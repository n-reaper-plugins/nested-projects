-- @description NestedProjects child helper: runs inside a detached child REAPER instance (started by NestedProjects)
-- @version @@VERSION@@
-- @author _n_plugins
-- @about
--   You normally never start this yourself: NestedProjects launches the child REAPER with this script.
--   It listens to the parent (play / stop / locate / save / quit) and reports its health through small files in
--   <parent project folder>/PROJECTS/<name>/.link/.
--   If a child shows "helper not started" in the parent window, run this action once inside the child REAPER window.
--   Running it again asks the running helper to close.

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path
local Child = require("NPChild")

local EXT = "NestedProjectsChild"
if r.GetExtState(EXT, "running") == "1" and (os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)) < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

local fs = {
  read = read,
  write_atomic = function(p, s)
    local tmp = p .. ".tmp"
    local f = io.open(tmp, "wb"); if not f then return false end
    f:write(s); f:close(); os.remove(p)
    return os.rename(tmp, p) and true or false
  end,
}

-- a wall clock with sub-second resolution that never runs backwards
local t0, p0 = os.time(), r.time_precise()
local function clock() return t0 + (r.time_precise() - p0) end

-- where is the mailbox? environment first (set by the parent), else a marker next to the project file
local function find_link()
  local link, id = os.getenv("NP_LINK_DIR"), os.getenv("NP_ID")
  if link and link ~= "" then return link, id, "env" end
  local _, fn = r.EnumProjects(-1)
  if fn and fn ~= "" then
    local cand = fn:match("^(.*)[/\\][^/\\]*$") .. "/.link"
    local marker = read(cand .. "/child.json")
    if marker then return cand, marker:match('"id"%s*:%s*"([^"]*)"'), "marker" end
  end
end

local helper, link, id
local function log(msg)
  if not link then return end
  local f = io.open(link .. "/helper.log", "ab")
  if f then f:write(os.date("%H:%M:%S ") .. tostring(msg) .. "\n"); f:close() end
end

local api = {
  play = function() r.OnPlayButton() end,
  stop = function() r.OnStopButton() end,
  locate = function(pos) r.SetEditCurPos(pos, true, true) end,
  save = function() r.Main_SaveProject(0, false); return r.IsProjectDirty(0) == 0 end,
  quit = function() r.Main_OnCommand(40004, 0) end,      -- File: Quit REAPER
  precise = r.time_precise,
  set_rate = function(rate) if r.CSurf_OnPlayRateChange then r.CSurf_OnPlayRateChange(rate) end end,
  state = function()
    local ps = r.GetPlayState()
    local playing = (ps & 1) == 1
    local _, fn = r.EnumProjects(-1)
    local ok, dev = r.GetAudioDeviceInfo("IDENT_OUT", "")
    return { play = ps & 7, pos = playing and r.GetPlayPosition() or r.GetCursorPosition(), dirty = r.IsProjectDirty(0) == 1,
             project = fn, device = ok and dev or nil }
  end,
}

local function shutdown()
  if helper then helper.closing = true; pcall(helper.write_status, helper) end
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local started_at, last_hb, last_err, told = r.time_precise(), 0, nil, false
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end

  if not helper then
    -- the project may still be loading when a command-line script starts: look again for a while
    local l, i, via = find_link()
    if l then
      link, id = l, i
      helper = Child.new(link, id or "", api, fs, clock)
      local _, fn = r.EnumProjects(-1)
      helper.mail.write_boot({ id = id or "", via = via, project = fn })
    elseif now - started_at > 20 and not told then
      told = true
      r.MB("This project is not a NestedProjects child (no .link folder found).", "NestedProjects child helper", 0)
      shutdown(); return
    end
  else
    local ok, err = pcall(helper.tick, helper)
    if not ok and tostring(err) ~= last_err then last_err = tostring(err); log(err) end
  end
  r.defer(loop)
end
loop()
