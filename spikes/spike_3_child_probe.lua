-- Runs INSIDE the test child (started by spike 3). Writes what the child instance can see.
local r = reaper
local link = os.getenv("NP_LINK_DIR") or "(no NP_LINK_DIR)"
local _, fn = r.EnumProjects(-1)
local ok, dev = r.GetAudioDeviceInfo("IDENT_OUT", "")
local lines = {
  "script ran: yes",
  "NP_LINK_DIR: " .. link,
  "NP_ID: " .. tostring(os.getenv("NP_ID")),
  "project: " .. tostring(fn),
  "audio out device: " .. tostring(ok and dev or "(unknown)"),
  "resource path: " .. r.GetResourcePath(),
  "time: " .. os.date(),
}
local f = io.open("/tmp/np_spike_link/probe.txt", "wb")
if f then f:write(table.concat(lines, "\n")); f:close() end
