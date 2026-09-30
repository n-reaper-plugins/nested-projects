-- NPApp.lua
-- State + main tick. No drawing in here; the UI only reads fields and calls the methods below.

local r = reaper
local RA = require("NPReaper")
local Merge = require("NPMerge")
local Sync = require("NPSync")

local App = {}
App.__index = App

local REFRESH, HEALTH, BEAT, REATTACH_TIMEOUT = 1.0, 0.5, 1.0, 25

function App.new()
  local self = setmetatable({}, App)
  self.proj = r.EnumProjects(-1)
  self.cfg = RA.load_cfg()
  self.entries = {}          -- list of { track, index, rec }
  self.health = {}           -- rec.id -> health table
  self.plans = {}            -- rec.id -> recovery suggestions
  self.pending = nil         -- { op, id, b, opts }   an operation waiting for conflict decisions
  self.waiting = {}          -- rec.id -> { t0 }       reattach waiting for the child to close
  self.syncers, self.was_ok = {}, {}   -- rec.id -> NPSync / bool   transport following
  self.shift = {}            -- rec.id -> seconds between parent time and child time
  self.drift = {}            -- rec.id -> seconds the child is ahead (+) / behind (-) while both play
  self.msg, self.err = nil, nil
  self.t_refresh, self.t_health, self.t_beat = -1e9, -1e9, -1e9
  self.parent_file = nil
  self:refresh()
  return self
end

function App:save() RA.save_cfg(self.cfg) end

function App:say(msg) self.msg, self.err = msg, nil end
function App:fail(err) self.err, self.msg = tostring(err), nil end

function App:entry(id)
  for _, e in ipairs(self.entries) do if e.rec.id == id then return e end end
end

function App:refresh()
  self.proj = r.EnumProjects(-1)
  self.parent_file = RA.project_file(self.proj)
  self.entries = RA.list(self.proj)
  local live = {}
  for _, e in ipairs(self.entries) do
    live[e.rec.id] = true
    self.health[e.rec.id] = RA.health(e)
    self.plans[e.rec.id] = RA.plan(e)
  end
  for id in pairs(self.health) do if not live[id] then self.health[id] = nil; self.plans[id] = nil; self.syncers[id] = nil end end
  for _, e in ipairs(self.entries) do
    if e.rec.state == "detached" then self.shift[e.rec.id] = RA.shift(e) end
  end
end

--------------------------------------------------------------------------------
-- transport following
--------------------------------------------------------------------------------
function App:parent_transport()
  local st = r.GetPlayStateEx and r.GetPlayStateEx(self.proj) or 0
  local paused = (st & 2) ~= 0
  local playing = (st & 1) ~= 0 and not paused
  local pos
  if playing or paused then pos = r.GetPlayPositionEx(self.proj) else pos = r.GetCursorPositionEx(self.proj) end
  return { play = playing, pos = pos, rate = r.Master_GetPlayRate and r.Master_GetPlayRate(self.proj) or 1 }
end

function App:following(e) return e.rec.follow ~= false end

function App:sync_tick(now)
  local ps
  for _, e in ipairs(self.entries) do
    local id = e.rec.id
    if e.rec.state == "detached" then
      local h = self.health[id]
      local ok = h ~= nil and h.state == "ok"
      local sy = self.syncers[id]
      if not sy then sy = Sync.new(self.shift[id] or 0); self.syncers[id] = sy end
      sy:set_shift(self.shift[id] or 0)
      if ok and not self.was_ok[id] then sy:reset() end         -- child just came up: tell it where we are
      self.was_ok[id] = ok
      self.drift[id] = nil
      if ok and self:following(e) then
        ps = ps or self:parent_transport()
        local msg = sy:step(ps, now)
        if msg then
          local seq, err = RA.command(e, "transport", msg)
          if not seq then self:fail(err) end
        end
        if ps.play then self.drift[id] = Sync.drift(h, ps.pos, self.shift[id] or 0, now, ps.rate) end
      elseif not self:following(e) then sy:reset() end          -- switched on again later: resend at once
    end
  end
end

function App:set_follow(id, on)
  local e = self:entry(id); if not e then return end
  RA.set_follow(e, on)
  if self.syncers[id] then self.syncers[id]:reset() end
  self:refresh()
end

function App:tick()
  local now = r.time_precise()
  if now - self.t_refresh > REFRESH then self.t_refresh = now; self:refresh() end
  if now - self.t_health > HEALTH then
    self.t_health = now
    for _, e in ipairs(self.entries) do if e.rec.state == "detached" then self.health[e.rec.id] = RA.health(e) end end
    self:check_waiting(now)
  end
  if now - self.t_beat > BEAT then
    self.t_beat = now
    for _, e in ipairs(self.entries) do
      if e.rec.state == "detached" and self.parent_file then RA.heartbeat(e, self.parent_file) end
    end
  end
  self:sync_tick(now)
end

--------------------------------------------------------------------------------
-- results
--------------------------------------------------------------------------------
-- handles the common (ok | nil,"conflicts",bundle | nil,err) return shape
function App:handle(op, id, opts, ok, err, bundle, done_msg)
  if ok then self:say(done_msg); self:refresh(); return true end
  if err == "conflicts" and bundle then
    self.pending = { op = op, id = id, b = bundle, opts = opts }
    self:say(#bundle.res.conflicts .. " conflict(s): choose which side wins, then Apply.")
    return false
  end
  self:fail(err)
  return false
end

--------------------------------------------------------------------------------
-- operations (id = rec.id)
--------------------------------------------------------------------------------
function App:attach(path, name, offset)
  if not path or path == "" then return self:fail("Choose a .rpp file first.") end
  local entry, info = RA.attach(self.proj, path, { name = (name and name ~= "") and name or nil, offset = offset or 0 })
  if not entry then return self:fail(info) end
  local extra = (info.report and #info.report > 0) and ("  Note: " .. table.concat(info.report, "; ")) or ""
  self:say(string.format("Attached %s (%d tracks).%s", entry.rec.name, info.tracks or 0, extra))
  self:refresh()
  return true
end

function App:make_project()
  local tr = r.GetSelectedTrack(self.proj, 0)
  if not tr then return self:fail("Select a folder track first.") end
  local entry, err = RA.make_project(self.proj, tr)
  if not entry then return self:fail(err) end
  self:say("Created PROJECT " .. entry.rec.name .. ".")
  self:refresh()
  return true
end

function App:sync(id)
  local e = self:entry(id); if not e then return end
  local ok, err, b = RA.sync(self.proj, e, { policy = self.cfg.policy ~= "ask" and self.cfg.policy or nil })
  return self:handle("sync", id, {}, ok, err, b, "Synced " .. e.rec.name .. ".")
end

function App:detach(id, opts)
  local e = self:entry(id); if not e then return end
  opts = opts or {}
  opts.policy = opts.policy or (self.cfg.policy ~= "ask" and self.cfg.policy or nil)
  opts.launch = opts.launch ~= false
  local ok, err, b = RA.detach(self.proj, e, opts)
  return self:handle("detach", id, opts, ok, err, b, "Detached " .. e.rec.name .. (opts.launch and " and started its REAPER instance." or "."))
end

function App:launch(id)
  local e = self:entry(id); if not e then return end
  local ok, err = RA.launch(self.proj, e, self.cfg)
  if not ok then return self:fail(err) end
  self:say("Started a REAPER instance for " .. e.rec.name .. ".")
  self:refresh()
end

function App:diagnostics(id)
  local e = self:entry(id); if not e then return nil end
  return RA.diagnostics(e)
end

function App:launch_command(id)
  local e = self:entry(id); if not e then return nil end
  return RA.launch_command(e, self.cfg)
end

function App:command(id, cmd, args)
  local e = self:entry(id); if not e then return end
  local seq, err = RA.command(e, cmd, args)
  if not seq then return self:fail(err) end
  self.msg, self.err = nil, nil
end

function App:cursor() return r.GetCursorPositionEx and r.GetCursorPositionEx(self.proj) or 0 end

-- the child's cursor to where this project's edit cursor is, in the CHILD's time (offset and start offset removed)
function App:locate_to_cursor(id)
  local e = self:entry(id); if not e then return end
  local shift = self.shift[id] or RA.shift(e)
  return self:command(id, "locate", { pos = math.max(0, self:cursor() - shift) })
end

-- Asks a running child to save and close, waits for it, then merges it back.
function App:reattach(id)
  local e = self:entry(id); if not e then return end
  local h = RA.health(e)
  if h.state == "ok" or h.state == "stale" then
    local seq, err = RA.command(e, "quit")
    if not seq then return self:fail(err) end
    self.waiting[id] = { t0 = r.time_precise() }
    self:say("Asked " .. e.rec.name .. " to save and close...")
    return
  end
  self:finish_reattach(id)
end

function App:finish_reattach(id, force)
  local e = self:entry(id); if not e then return end
  local opts = { policy = self.cfg.policy ~= "ask" and self.cfg.policy or nil, force = force }
  local ok, err, b = RA.reattach(self.proj, e, opts)
  if err == "child_running" then
    return self:fail("The child REAPER is still running. Close it (File > Quit in that window) or use 'Reattach anyway'.")
  end
  return self:handle("reattach", id, opts, ok, err, b, "Reattached " .. e.rec.name .. ".")
end

function App:check_waiting(now)
  for id, w in pairs(self.waiting) do
    local e = self:entry(id)
    if not e then self.waiting[id] = nil
    else
      local h = self.health[id] or RA.health(e)
      if h.state == "closing" or h.state == "lost" or h.state == "not_started" or h.state == "foreign" or h.state == "no_helper" then
        self.waiting[id] = nil
        self:finish_reattach(id, true)
      elseif now - w.t0 > REATTACH_TIMEOUT then
        self.waiting[id] = nil
        self:fail("The child did not close in time. Save and close it yourself, or use 'Reattach anyway'.")
      end
    end
  end
end

function App:forget(id)
  local e = self:entry(id); if not e then return end
  RA.forget(self.proj, e)
  self:say("Unlinked " .. e.rec.name .. " (files left in place).")
  self:refresh()
end

function App:finish_interrupted(id)
  local e = self:entry(id); if not e then return end
  local ok, err, b = RA.finish_interrupted(self.proj, e, { policy = "parent" })
  return self:handle("interrupted", id, {}, ok, err, b, "Finished the interrupted operation.")
end

--------------------------------------------------------------------------------
-- conflicts
--------------------------------------------------------------------------------
function App:choose(n, side)
  if self.pending then Merge.choose(self.pending.b.res, n, side) end
end

function App:choose_all(side)
  if self.pending then Merge.resolve_all(self.pending.b.res, side) end
end

function App:apply_pending()
  local p = self.pending; if not p then return end
  local e = self:entry(p.id); self.pending = nil
  if not e then return self:fail("The PROJECT is gone.") end
  local ok, err, b
  if p.op == "sync" then ok, err = RA.apply_bundle(self.proj, p.b, "Sync PROJECT " .. e.rec.name)
  elseif p.op == "detach" then ok, err, b = RA.detach(self.proj, e, p.opts, p.b)
  elseif p.op == "reattach" then ok, err, b = RA.reattach(self.proj, e, p.opts, p.b)
  else ok, err = RA.apply_bundle(self.proj, p.b) end
  return self:handle(p.op, p.id, p.opts, ok, err, b, "Done.")
end

function App:cancel_pending()
  self.pending = nil
  self:say("Cancelled: nothing was changed.")
end

return App
