package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mail = require("NPMail")
local Child = require("NPChild")

local files, now = {}, 100
local fs = { read = function(p) return files[p] end, write_atomic = function(p, s) files[p] = s; return true end }
local clock = function() return now end
local calls, st = {}, { play = 0, pos = 0, dirty = false, project = "/c.rpp", device = "Built-in" }
local api = {
  play = function() calls[#calls + 1] = "play"; st.play = 1 end,
  stop = function() calls[#calls + 1] = "stop"; st.play = 0 end,
  locate = function(p) calls[#calls + 1] = "locate " .. p; st.pos = p end,
  save = function() calls[#calls + 1] = "save"; return not st.save_fails end,
  quit = function() calls[#calls + 1] = "quit" end,
  state = function() return st end,
}
local child = Child.new("/l", "ID1", api, fs, clock)
local parent = Mail.parent(fs, "/l", clock)

child:tick()
local s = parent.status()
T.eq(s.id, "ID1", "status written on the first tick"); T.eq(s.state, "running", "running")
T.eq(s.device, "Built-in", "device reported")

parent.send("play"); now = now + 0.2; child:tick()
T.eq(calls[#calls], "play", "play executed"); T.eq(parent.ack().ok, true, "acked ok"); T.ok(not parent.pending(), "no longer pending")
parent.send("play"); now = now + 0.2; child:tick()
T.eq(#calls, 1, "play while already playing does nothing")
parent.send("locate", { pos = 42 }); now = now + 0.2; child:tick()
T.eq(calls[#calls], "locate 42", "locate")
T.eq(parent.status().pos, 42, "status shows the new position at once")
parent.send("stop"); now = now + 0.2; child:tick()
T.eq(calls[#calls], "stop", "stop")

-- status cadence: not written on every poll
files["/l/status.json"] = nil
now = now + 0.2; child:tick()
T.eq(files["/l/status.json"], nil, "no status write before the interval")
now = now + 0.6; child:tick()
T.ok(files["/l/status.json"], "status written after the interval")

-- save failure is reported, quit does not happen
st.save_fails = true
parent.send("quit"); now = now + 0.2; child:tick()
T.eq(parent.ack().ok, false, "failed save reported"); T.ok(parent.ack().err:find("save"), "with a reason")
T.eq(calls[#calls], "save", "did not quit with unsaved work")
st.save_fails = nil
parent.send("quit"); now = now + 0.2; child:tick()
T.eq(calls[#calls], "quit", "quit after a good save")
T.eq(parent.status().state, "closing", "status says closing before REAPER exits")

-- orphan detection
local c2 = Child.new("/l2", "ID2", api, fs, clock)
parent = Mail.parent(fs, "/l2", clock); parent.heartbeat("/p.rpp")
now = now + 60; c2:tick()
T.eq(Mail.json.decode(files["/l2/status.json"]).orphaned, true, "child notices the parent went quiet")
T.done("test_child")
