package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Sync = require("NPSync")
local Child = require("NPChild")
local Mail = require("NPMail")

--------------------------------------------------------------------------------
-- 1. when does the parent side send?
--------------------------------------------------------------------------------
do
  local sy = Sync.new(8)
  local m = sy:step({ play = false, pos = 0 }, 0)
  T.ok(m and m.play == 0, "first step always sends (child just came up)")
  T.eq(m.pos, -8, "child time = parent time - shift")
  T.eq(sy:step({ play = false, pos = 0 }, 0.1), nil, "nothing while nothing changes")
  m = sy:step({ play = true, pos = 20 }, 1.0)
  T.ok(m and m.play == 1 and m.pos == 12, "play edge: 20 - 8 = 12"); T.eq(m.tp, 1.0, "carries the parent's clock for latency compensation")
  T.eq(sy:step({ play = true, pos = 20.033 }, 1.033), nil, "playing normally: silent")
  T.eq(sy:step({ play = true, pos = 20.5 }, 1.5), nil, "still silent")
  m = sy:step({ play = true, pos = 21.05 }, 2.05)
  T.ok(m and m.play == 1, "drift message after DRIFT_EVERY seconds")
  m = sy:step({ play = true, pos = 50 }, 2.1)
  T.ok(m and m.pos == 42, "a jump while playing = seek")
  m = sy:step({ play = false, pos = 50.2 }, 2.3)
  T.ok(m and m.play == 0 and m.pos == 42.2, "stop edge, with the stop position")
  T.eq(sy:step({ play = false, pos = 50.2 }, 2.4), nil, "stopped and still: silent")
  m = sy:step({ play = false, pos = 60 }, 2.5)
  T.ok(m and m.pos == 52, "cursor moved while stopped")
  -- throttle: moves faster than CURSOR_EVERY are not forgotten
  sy:step({ play = false, pos = 61 }, 2.55)
  local m2 = sy:step({ play = false, pos = 61 }, 2.7)
  T.ok(m2 and m2.pos == 53, "a throttled cursor move is sent later, not lost")
  -- rate change
  m = sy:step({ play = false, pos = 61, rate = 0.5 }, 3.0)
  T.ok(m and m.rate == 0.5, "playrate change is sent")
  sy:set_shift(10)
  m = sy:step({ play = false, pos = 61, rate = 0.5 }, 3.1)
  T.ok(m and m.pos == 51, "a changed shift forces a resend in the new child time")
  sy:reset()
  T.ok(sy:step({ play = false, pos = 61, rate = 0.5 }, 3.2), "reset forces a resend")
  -- drift helper
  T.eq(Sync.drift({ play = 1, pos = 10, tp = 100 }, 20, 8, 100.5, 1), 10 + 0.5 + 8 - 20, "drift extrapolates the child's position")
  T.eq(Sync.drift({ play = 0, pos = 10, tp = 100 }, 20, 8, 100.5, 1), nil, "no drift figure when the child is not playing")
  T.eq(Sync.drift({ play = 1, pos = 10, tp = 100 }, 20, 8, 110, 1), nil, "no drift figure from a stale status")
end

--------------------------------------------------------------------------------
-- 2. what does the child do with a message?
--------------------------------------------------------------------------------
do
  local files, now = {}, 100
  local fs = { read = function(p) return files[p] end, write_atomic = function(p, s) files[p] = s; return true end }
  local st = { play = 0, pos = 0, dirty = false, project = "/c.rpp" }
  local calls = {}
  local api = {
    play = function() calls[#calls + 1] = "play"; st.play = 1 end,
    stop = function() calls[#calls + 1] = "stop"; st.play = 0 end,
    locate = function(p) calls[#calls + 1] = string.format("locate %.3f", p); st.pos = p end,
    save = function() return true end, quit = function() end, state = function() return st end,
    precise = function() return now end,
    set_rate = function(x) calls[#calls + 1] = "rate " .. x end,
  }
  local child = Child.new("/l", "ID", api, fs, function() return now end)
  local function reset() calls = {} end
  local function joined() return table.concat(calls, ",") end

  child:apply_transport({ play = 1, pos = 12, tp = now - 0.08 })
  T.eq(joined(), "locate 12.080,play", "play: latency (80 ms in flight) is added to the position, locate comes before play")
  reset(); st.pos = 12.10
  child:apply_transport({ play = 1, pos = 12.1, tp = now })
  T.eq(joined(), "", "already playing at the right place: nothing (no glitch)")
  reset(); st.pos = 12.5
  child:apply_transport({ play = 1, pos = 12.0, tp = now })
  T.eq(joined(), "locate 12.000", "drifted beyond the tolerance: one seek, no stop")
  reset(); st.pos = 12.03
  child:apply_transport({ play = 1, pos = 12.0, tp = now })
  T.eq(joined(), "", "inside the tolerance: leave it alone")
  reset()
  child:apply_transport({ play = 0, pos = 30 })
  T.eq(joined(), "stop,locate 30.000", "stop: stops and puts the cursor where the parent's is")
  reset()
  child:apply_transport({ play = 0, pos = 30 })
  T.eq(joined(), "locate 30.000", "stopped twice: harmless")
  reset()
  child:apply_transport({ play = 0, pos = -5 })
  T.eq(joined(), "locate 0.000", "parent before the child's start: child sits at 0")
  -- absurd timestamps do not shift anything
  reset(); st.play = 0
  child:apply_transport({ play = 1, pos = 3, tp = now + 50 })
  T.eq(joined(), "locate 3.000,play", "timestamp from the future: no compensation")
  reset(); st.play = 0
  child:apply_transport({ play = 1, pos = 3, tp = now - 50 })
  T.eq(joined(), "locate 3.000,play", "timestamp far in the past: no compensation")
  -- paused child: stop first so play starts from the cursor
  reset(); st.play = 2
  child:apply_transport({ play = 1, pos = 3 })
  T.eq(joined(), "stop,locate 3.000,play", "a paused child is stopped first")
  -- rate
  reset(); st.play = 0
  child:apply_transport({ play = 0, pos = 1, rate = 0.5 })
  T.ok(joined():find("rate 0.5", 1, true), "playrate follows the parent")

  -- parent has not reached the child's start yet: wait, then start on time
  child:apply_transport({ play = 0, pos = 0, rate = 1 })      -- back to normal speed
  reset(); st.play = 0; st.pos = 0
  local t0 = now
  child:apply_transport({ play = 1, pos = -2, tp = now })
  T.eq(joined(), "locate 0.000", "negative child time: sit at 0")
  T.ok(child.start_at and math.abs(child.start_at - (t0 + 2)) < 1e-9, "start scheduled 2 s ahead")
  reset(); now = t0 + 1.9; child:tick()
  T.eq(joined(), "", "not yet")
  now = t0 + 2.02; child.last_poll = -1e9; child:tick()
  T.eq(joined(), "locate 0.020,play", "then it starts exactly on time (20 ms late -> starts 20 ms in)")
  T.eq(child.start_at, nil, "and the schedule is cleared")
  -- a newer message cancels the schedule
  reset(); st.play = 0
  child:apply_transport({ play = 1, pos = -2, tp = now })
  child:apply_transport({ play = 0, pos = 0 })
  T.eq(child.start_at, nil, "a stop cancels a pending start")
end

--------------------------------------------------------------------------------
-- 3. the whole loop: parent transport -> App -> mailbox -> Child -> (simulated) audio, with clock drift
--------------------------------------------------------------------------------
local Mock = require("mock_reaper")
local S = Mock.install()
local Stub = require("imgui_stub"); Stub.install(reaper)
local F = require("fixture")
local RA = require("NPReaper")
RA.fs, RA.shell = Mock.fs, Mock.shell
RA.clock = function() return S.clock end
local App = require("NPApp")

Mock.new_track("Music", 0)
S.files["/src/Intro/Intro.rpp"] = F.child_rpp()      -- start offset -2 s
local app = App.new()
T.ok(app:attach("/src/Intro/Intro.rpp", nil, 10), "attach with offset 10")
local id = app.entries[1].rec.id
S.clock = 1000
T.ok(app:detach(id, { launch = true }) ~= nil, "detach")
app:refresh()
local e = app.entries[1]
T.eq(app.shift[id], 8, "shift = attach offset 10 + project start offset -2")

-- simulated child audio engine (its own clock can run fast or slow against the parent's)
local dev = { playing = false, pos = 0, speed = 1.0, locates = 0 }
local api = {
  play = function() dev.playing = true end,
  stop = function() dev.playing = false end,
  locate = function(p) dev.pos = p; dev.locates = dev.locates + 1 end,
  save = function() return true end, quit = function() end,
  state = function() return { play = dev.playing and 1 or 0, pos = dev.pos, dirty = false, project = e.rec.file } end,
  precise = function() return S.clock end,
}
local child = Child.new(e.rec.link, e.rec.instance_id, api, Mock.fs, function() return S.clock end)

local DT = 1 / 30
local worst, samples = 0, 0
local function step(n, track_drift)
  for _ = 1, n do
    S.clock = S.clock + DT
    if S.play_state == 1 then S.play_pos = S.play_pos + DT end
    if dev.playing then dev.pos = dev.pos + DT * dev.speed end
    app:tick()
    child:tick()
    if track_drift and dev.playing and S.play_state == 1 then
      local err = math.abs((dev.pos + app.shift[id]) - S.play_pos)
      if err > worst then worst = err end
      samples = samples + 1
    end
  end
end
local function child_minus_parent() return (dev.pos + app.shift[id]) - S.play_pos end

-- a) child comes up while the parent is stopped somewhere
S.play_state, S.cursor = 0, 30
step(45)
T.eq(app.health[id].state, "ok", "child connected")
T.ok(not dev.playing, "stopped parent = stopped child")
T.ok(math.abs(dev.pos - 22) < 1e-6, "child cursor is at parent 30 - shift 8 = 22, got " .. dev.pos)

-- b) parent plays
S.play_state, S.play_pos = 1, 40
step(30)
T.ok(dev.playing, "parent plays -> child plays")
T.ok(math.abs(child_minus_parent()) < 0.1, string.format("in sync within 100 ms right after the start (%.0f ms)", child_minus_parent() * 1000))
worst = 0; step(30 * 10, true)
T.ok(worst < 0.1, string.format("stays in sync for 10 s (worst %.0f ms)", worst * 1000))
T.ok(app.drift[id] ~= nil and math.abs(app.drift[id]) < 0.15, "the window shows a drift figure: " .. tostring(app.drift[id]))

-- c) the child's clock runs 0.5 % fast: drift is corrected, sparingly
dev.speed = 1.005; dev.locates = 0; worst = 0
step(30 * 40, true)
T.ok(worst < 0.16, string.format("0.5%% clock drift over 40 s is kept in check (worst %.0f ms)", worst * 1000))
T.ok(dev.locates >= 1 and dev.locates <= 8, "corrections happen but not constantly: " .. dev.locates)
dev.speed = 1.0

-- d) seek while playing
S.play_pos = 200
step(15)
T.ok(math.abs(child_minus_parent()) < 0.15, "parent seeks -> child follows within half a second")

-- e) stop
S.play_state = 0; S.cursor = 210
step(10)
T.ok(not dev.playing, "parent stops -> child stops")
T.ok(math.abs(dev.pos - 202) < 1e-6, "and rests at parent 210 - 8 = 202, got " .. dev.pos)

-- f) parent starts BEFORE the child's start (child time negative)
S.play_state, S.play_pos = 1, 5              -- child time -3
step(15)
T.ok(not dev.playing, "parent at 5 s, child starts at 8 s: child waits")
step(30 * 3)                                  -- parent now at ~8.5
T.ok(dev.playing, "and starts by itself when the parent reaches the child's start")
T.ok(math.abs(child_minus_parent()) < 0.15, string.format("aligned (%.0f ms)", child_minus_parent() * 1000))
S.play_state = 0; step(10)

-- g) Follow off: nothing is sent
app:set_follow(id, false)
local seq_before = Mail.parent(Mock.fs, e.rec.link, RA.clock).last_seq()
S.play_state, S.play_pos = 1, 300
step(60)
T.eq(Mail.parent(Mock.fs, e.rec.link, RA.clock).last_seq(), seq_before, "Follow off: parent transport is not forwarded")
T.ok(not dev.playing, "child stays as it was")
S.play_state = 0
app:set_follow(id, true)
S.play_state, S.play_pos = 1, 300
step(20)
T.ok(dev.playing and math.abs(child_minus_parent()) < 0.15, "Follow on again: catches up at once")

-- h) the child goes away and comes back while the parent keeps playing
local silent_until = S.clock + 25
while S.clock < silent_until do
  S.clock = S.clock + DT; S.play_pos = S.play_pos + DT
  app:tick()                                   -- child does not tick: no status
end
T.ok(app.health[id].state ~= "ok", "child stopped answering: " .. app.health[id].state)
dev.playing = false                            -- it was restarted, so it is stopped
step(40)
T.eq(app.health[id].state, "ok", "child answers again")
T.ok(dev.playing and math.abs(child_minus_parent()) < 0.15, "and is brought back into sync without a button press")

-- i) Go to cursor uses child time
S.cursor = 50
app:set_follow(id, false)
app:locate_to_cursor(id)
local c = Mail.parent(Mock.fs, e.rec.link, RA.clock)
local raw = Mail.json.decode(Mock.fs.read(e.rec.link .. "/cmd.json"))
T.eq(raw.cmd, "locate", "locate sent"); T.eq(raw.pos, 42, "50 - 8 = 42")
S.cursor = 3
app:locate_to_cursor(id)
T.eq(Mail.json.decode(Mock.fs.read(e.rec.link .. "/cmd.json")).pos, 0, "before the child's start: clamped to 0")

T.eq(Mail.parent(Mock.fs, "/nowhere", RA.clock).send("transport", { play = 1 }), nil, "transport without a position is rejected")
T.done("test_sync")
