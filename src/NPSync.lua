-- NPSync.lua
-- Pure Lua. Parent side of "follow the parent's transport": watches the parent's play state / position and decides
-- WHEN to tell a detached child what to do. It never sends "press play"; it sends the whole transport STATE
-- ({play, pos in the child's own time, timestamp}), so a lost or overwritten message is harmless: the next one repairs it.
--
--   child time = parent time - shift         shift = attach offset + the child project's start offset
--
-- When a message is sent:
--   * play/stop changed                      (edge)
--   * the position jumped while playing      (seek: further than SEEK from where it should be)
--   * every DRIFT_EVERY seconds while playing (the two audio clocks are never exactly equal; the child corrects itself)
--   * the cursor moved while stopped         (at most every CURSOR_EVERY seconds)
--   * forced (child just came up / Follow switched on)

local Sync = {}
Sync.__index = Sync

Sync.SEEK = 0.25
Sync.DRIFT_EVERY = 1.0
Sync.CURSOR_EVERY = 0.1

function Sync.new(shift)
  return setmetatable({ shift = shift or 0, force = true, last_play = nil, last_pos = 0, last_t = 0, last_sent = -1e9, last_rate = 1 }, Sync)
end

function Sync:set_shift(shift)
  if shift ~= self.shift then self.shift = shift; self.force = true end
end

function Sync:reset() self.force = true end

-- ps = { play=bool, pos=seconds (parent time), rate=number|nil }, now = monotonic seconds (r.time_precise)
-- returns the message table for the child, or nil
function Sync:step(ps, now)
  local rate = ps.rate or 1
  local send = false
  if self.force then send = true; self.force = false
  elseif ps.play ~= self.last_play then send = true
  elseif math.abs(rate - self.last_rate) > 1e-3 then send = true
  elseif ps.play then
    local expected = self.last_pos + (now - self.last_t) * self.last_rate
    if math.abs(ps.pos - expected) > Sync.SEEK then send = true
    elseif now - self.last_sent >= Sync.DRIFT_EVERY then send = true end
  else
    if math.abs(ps.pos - self.last_pos) > 1e-4 and now - self.last_sent >= Sync.CURSOR_EVERY then send = true end
  end
  -- while stopped and waiting for the throttle, keep last_pos where we last SENT so the move is not forgotten
  if ps.play or send or self.last_play == nil then self.last_pos = ps.pos end
  self.last_play, self.last_t, self.last_rate = ps.play, now, rate
  if not send then return nil end
  self.last_sent = now
  return { play = ps.play and 1 or 0, pos = ps.pos - self.shift, tp = now, rate = rate }
end

-- seconds the child is ahead (+) / behind (-) of where it should be, given its last status
--   st = { play, pos, tp }  (child status.json, tp = the child's time_precise when it wrote pos), parent_pos, now
function Sync.drift(st, parent_pos, shift, now, rate)
  if not st or not st.play or (st.play & 1) ~= 1 or not st.tp then return nil end
  local age = now - st.tp
  if age < 0 or age > 2 then return nil end
  local child_now = st.pos + age * (rate or 1)
  return child_now + shift - parent_pos
end

return Sync
