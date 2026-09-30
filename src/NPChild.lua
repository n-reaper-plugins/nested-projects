-- NPChild.lua
-- Logic of the helper that runs INSIDE a detached child REAPER instance. It answers the parent through the file mailbox:
--   * executes play / stop / locate / save / quit / ping from cmd.json and acknowledges each one
--   * writes status.json (heartbeat, play state, position, dirty flag, audio device) a couple of times a second
--   * notices when the parent stopped writing its heartbeat (orphaned child) - it keeps running, isolation is the point
-- All REAPER calls go through `api`, so this is testable offline.
--
--   api = { play(), stop(), locate(pos), save()->bool, quit(), state()->{play,pos,dirty,project,device,device_err},
--           precise()->seconds (shared monotonic clock, optional), set_rate(rate) (optional) }

local Mail = require("NPMail")

local Child = {}
Child.__index = Child

Child.POLL = 0.1        -- seconds between mailbox checks
Child.STATUS = 0.5      -- seconds between status writes
Child.TOL = 0.06        -- while playing: further than this from where the parent says we should be -> seek
Child.MAX_LAT = 1.0     -- a message older than this is not trusted for latency compensation

function Child.new(link_dir, id, api, fs, clock)
  local self = setmetatable({}, Child)
  self.id, self.api, self.clock = id, api, clock
  self.mail = Mail.child(fs, link_dir, clock)
  self.last_poll, self.last_status = -1e9, -1e9
  self.closing = false
  self.orphaned = false
  self.start_at = nil      -- child clock time at which to start playing from 0 (parent is still before the child's start)
  self.rate = 1
  return self
end

local function is_playing(st) return st.play ~= nil and math.floor(st.play) % 2 == 1 end
local function is_paused(st) return st.play ~= nil and math.floor(st.play / 2) % 2 == 1 end

-- Puts the child where the parent's transport says. Idempotent: applying the same message twice changes nothing.
function Child:apply_transport(c)
  local a = self.api
  local st = a.state()
  self.start_at = nil
  if c.rate and a.set_rate and math.abs(c.rate - self.rate) > 1e-4 then a.set_rate(c.rate); self.rate = c.rate end
  -- how long the message has been on its way (same machine, shared monotonic clock); ignored if it looks wrong
  local lat = 0
  if c.tp and a.precise then
    local d = a.precise() - c.tp
    if d >= 0 and d <= Child.MAX_LAT then lat = d end
  end
  if c.play == 1 then
    local target = c.pos + lat * (c.rate or 1)
    if target < 0 then
      -- the parent has not reached the child's start yet: sit at 0 and start exactly when it does
      if is_playing(st) or is_paused(st) then a.stop() end
      a.locate(0)
      self.start_at = self.clock() + (-target) / (c.rate or 1)
    elseif not is_playing(st) then
      if is_paused(st) then a.stop() end
      a.locate(target)
      a.play()
    elseif math.abs(st.pos - target) > Child.TOL then
      a.locate(target)
    end
  else
    if is_playing(st) or is_paused(st) then a.stop() end
    a.locate(math.max(0, c.pos))
  end
end

local function run(self, c)
  local a = self.api
  if c.cmd == "play" then
    local st = a.state()
    if not st.play or st.play == 0 then a.play() end
  elseif c.cmd == "stop" then a.stop()
  elseif c.cmd == "locate" then a.locate(c.pos)
  elseif c.cmd == "save" then
    if not a.save() then return false, "save failed" end
  elseif c.cmd == "quit" then
    if not a.save() then return false, "save failed: not quitting" end
    self.closing = true
    self:write_status(true)
    a.quit()
  elseif c.cmd == "transport" then self:apply_transport(c)
  elseif c.cmd == "ping" then
  else return false, "unknown command" end
  return true
end

function Child:write_status(force)
  local s = self.api.state()
  local parent = self.mail.parent_info()
  self.orphaned = parent ~= nil and not Mail.health.parent_alive(parent, self.clock())
  self.mail.write_status({
    id = self.id, state = self.closing and "closing" or "running", play = s.play, pos = s.pos, dirty = s.dirty,
    project = s.project, device = s.device, device_err = s.device_err, orphaned = self.orphaned or nil,
    tp = self.api.precise and self.api.precise() or nil,
  })
end

function Child:tick()
  local now = self.clock()
  local ran = false
  if self.start_at and now >= self.start_at then
    local over = now - self.start_at
    self.start_at = nil
    self.api.locate(over * self.rate)
    self.api.play()
    ran = true
  end
  if now - self.last_poll >= Child.POLL then
    self.last_poll = now
    local c = self.mail.poll()
    if c then
      local ok, err = run(self, c)
      if type(ok) ~= "boolean" then ok, err = false, tostring(err) end
      self.mail.ack(c.seq, ok, err)
      ran = true
    end
  end
  if ran or now - self.last_status >= Child.STATUS then
    self.last_status = now
    self:write_status()
  end
end

return Child
