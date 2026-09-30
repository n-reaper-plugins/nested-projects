-- @description NestedProjects: PROJECT folder tracks that can be attached to / detached from separate REAPER projects
-- @version @@VERSION@@
-- @author _n_plugins
-- @about
--   Run this action to open the NestedProjects window (needs ReaImGui: ReaPack > ReaTeam Extensions).
--   Attach a .rpp as a PROJECT folder track, edit it here, or Detach it into its own REAPER instance (own audio device,
--   own transport) and Reattach it later. Edits made on both sides are merged.
--   Run the action again while the window is open to close it.
--   Keep NestedProjectsChild.lua in the same folder: it is what runs inside detached children.

local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "?.lua;" .. package.path

if not r.ImGui_CreateContext then
  r.MB("This script needs the ReaImGui extension.\n\nInstall it via ReaPack (Extensions > ReaPack > Browse packages > 'ReaImGui').", "NestedProjects", 0)
  return
end

local App = require("NPApp")
local UI  = require("NPUI")
local RA  = require("NPReaper")

local EXT = "NestedProjectsApp"

local hb_age = os.time() - (tonumber(r.GetExtState(EXT, "hb")) or 0)
if r.GetExtState(EXT, "running") == "1" and hb_age < 3 then
  r.SetExtState(EXT, "stop", "1", false)
  return
end
r.SetExtState(EXT, "running", "1", false)
r.SetExtState(EXT, "stop", "0", false)
r.SetExtState(EXT, "hb", tostring(os.time()), false)

local _, _, sec, cmdid = r.get_action_context()
local function set_toggle(on)
  if cmdid and cmdid ~= 0 then r.SetToggleCommandState(sec, cmdid, on and 1 or 0); r.RefreshToolbar2(sec, cmdid) end
end
set_toggle(true)

math.randomseed(os.time())
local app = App.new()
-- the helper script lives next to this one; remember it unless the user chose another
if (app.cfg.child_script or "") == "" then
  local cand = dir .. "NestedProjectsChild.lua"
  if r.file_exists(cand) then app.cfg.child_script = cand; app:save() end
end
local ui = UI.new(app)

local function shutdown()
  app:save()
  set_toggle(false)
  r.SetExtState(EXT, "running", "0", false)
  r.SetExtState(EXT, "stop", "0", false)
end
r.atexit(shutdown)

local last_hb, last_err = 0, nil
local function loop()
  if r.GetExtState(EXT, "stop") == "1" then shutdown(); return end
  local now = r.time_precise()
  if now - last_hb > 1 then r.SetExtState(EXT, "hb", tostring(os.time()), false); last_hb = now end
  local ok, err = pcall(app.tick, app)
  if not ok and tostring(err) ~= last_err then last_err = tostring(err); app.err = "Error: " .. last_err end
  if ui:frame() then r.defer(loop) else shutdown() end
end

loop()
