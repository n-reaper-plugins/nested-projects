-- @description NestedProjects child helper: runs inside a detached child REAPER instance (started by NestedProjects)
-- @version 0.1.3
-- @author _n_plugins
-- @about
--   You normally never start this yourself: NestedProjects launches the child REAPER with this script.
--   It listens to the parent (play / stop / locate / save / quit) and reports its health through small files in
--   <parent project folder>/PROJECTS/<name>/.link/.
--   If a child shows "helper not started" in the parent window, run this action once inside the child REAPER window.
--   Running it again asks the running helper to close.
-- BUNDLED BUILD of NestedProjectsChild v0.1.3 - edit the files in src/, not this one.
local __preload = package.preload
__preload["NPMail"] = function(...)
-- NPMail.lua
-- Pure Lua. The file mailbox between the parent REAPER and a detached child REAPER, plus the health / recovery rules.
-- Nothing here calls REAPER or the OS: everything goes through an `fs` object so it can be tested offline.
--
--   fs = { read(path)->string|nil, write_atomic(path,data)->bool, exists(path)->bool, mkdir(path), mtime(path)->number|nil }
--
-- Files in <link dir>:
--   cmd.json     parent -> child   { seq, cmd = "play"|"stop"|"locate"|"transport"|"save"|"quit"|"ping", pos?, t }
--                                  transport = { play=1|0, pos (child time), tp (parent time_precise), rate }: the whole state, idempotent
--   ack.json     child  -> parent  { seq, ok, err?, t }               (last command the child handled)
--   status.json  child  -> parent  { id, t, pid?, project, play, pos, dirty, device?, device_err?, state }
--   parent.json  parent -> child   { t, project }                     (parent heartbeat, so a child can tell it was orphaned)
--   boot.json    child  -> parent  { id, t, via, project }            (written the moment the helper script starts running)
--   helper.log   child  -> anyone  errors of the helper, one per line

local M = {}

--------------------------------------------------------------------------------
-- tiny JSON (objects, arrays, strings, numbers, booleans, null) - enough for our own files
--------------------------------------------------------------------------------
local J = {}
M.json = J

local esc = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function enc(v, out)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif v == math.floor(v) and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
    else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return esc[c] or string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = "["
      for i, x in ipairs(v) do if i > 1 then out[#out + 1] = "," end enc(x, out) end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        enc(k, out); out[#out + 1] = ":"; enc(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else out[#out + 1] = "null" end
end

function J.encode(v) local out = {}; enc(v, out); return table.concat(out) end

function J.decode(s)
  local i = 1
  local function ws() i = s:find("%S", i) or (#s + 1) end
  local val
  local function str()
    local out = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == "" then error("unterminated string") end
      if c == '"' then i = i + 1; break end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        if n == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16)); i = i + 6
        else
          out[#out + 1] = ({ n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" })[n] or n
          i = i + 2
        end
      else out[#out + 1] = c; i = i + 1 end
    end
    return table.concat(out)
  end
  function val()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local o = {}
      i = i + 1; ws()
      if s:sub(i, i) == "}" then i = i + 1; return o end
      while true do
        ws()
        local k = str(); ws()
        assert(s:sub(i, i) == ":", "expected ':' at " .. i); i = i + 1
        o[k] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "}" then break end
        assert(d == ",", "expected ',' at " .. i)
      end
      return o
    elseif c == "[" then
      local a = {}
      i = i + 1; ws()
      if s:sub(i, i) == "]" then i = i + 1; return a end
      while true do
        a[#a + 1] = val(); ws()
        local d = s:sub(i, i); i = i + 1
        if d == "]" then break end
        assert(d == ",", "expected ',' at " .. i)
      end
      return a
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4; return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5; return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
      assert(num and num ~= "", "bad json at " .. i)
      i = i + #num
      return tonumber(num)
    end
  end
  local v = val()
  return v
end

function J.try_decode(s)
  if not s or s == "" then return nil end
  local ok, v = pcall(J.decode, s)
  if ok then return v end
  return nil
end

--------------------------------------------------------------------------------
-- mailbox
--------------------------------------------------------------------------------
local function read_json(fs, path) return J.try_decode(fs.read(path)) end
local function write_json(fs, path, tbl) return fs.write_atomic(path, J.encode(tbl)) end

M.COMMANDS = { play = true, stop = true, locate = true, transport = true, save = true, quit = true, ping = true }

function M.parent(fs, dir, clock)
  local self = { fs = fs, dir = dir, clock = clock }
  local function p(name) return dir .. "/" .. name end

  function self.last_seq()
    local c = read_json(fs, p("cmd.json"))
    return c and c.seq or 0
  end

  -- returns seq, or nil + error
  function self.send(cmd, args)
    if not M.COMMANDS[cmd] then return nil, "unknown command " .. tostring(cmd) end
    local msg = { seq = self.last_seq() + 1, cmd = cmd, t = clock() }
    for k, v in pairs(args or {}) do msg[k] = v end
    if cmd == "locate" and type(msg.pos) ~= "number" then return nil, "locate needs a position" end
    if cmd == "transport" and (type(msg.pos) ~= "number" or type(msg.play) ~= "number") then return nil, "transport needs play and pos" end
    if not write_json(fs, p("cmd.json"), msg) then return nil, "could not write cmd.json" end
    return msg.seq
  end

  function self.ack() return read_json(fs, p("ack.json")) end
  function self.status() return read_json(fs, p("status.json")) end
  function self.boot() return read_json(fs, p("boot.json")) end

  -- true while the last command has not been acknowledged
  function self.pending()
    local c = read_json(fs, p("cmd.json"))
    if not c then return false end
    local a = read_json(fs, p("ack.json"))
    return (a and a.seq or 0) < c.seq
  end

  function self.heartbeat(project)
    return write_json(fs, p("parent.json"), { t = clock(), project = project })
  end
  return self
end

function M.child(fs, dir, clock)
  local self = { fs = fs, dir = dir, clock = clock, handled = 0 }
  local function p(name) return dir .. "/" .. name end

  -- the acknowledged seq survives a restart of the helper: never run the same command twice
  local a = read_json(fs, p("ack.json"))
  if a and a.seq then self.handled = a.seq end

  function self.poll()
    local c = read_json(fs, p("cmd.json"))
    if c and c.seq and c.seq > self.handled then return c end
  end

  function self.ack(seq, ok, err)
    self.handled = seq
    return write_json(fs, p("ack.json"), { seq = seq, ok = ok and true or false, err = err, t = clock() })
  end

  function self.write_status(st)
    st.t = clock()
    return write_json(fs, p("status.json"), st)
  end

  function self.parent_info() return read_json(fs, p("parent.json")) end
  function self.write_boot(info)
    info.t = clock()
    return write_json(fs, p("boot.json"), info)
  end
  return self
end

--------------------------------------------------------------------------------
-- health
--------------------------------------------------------------------------------
local H = {}
M.health = H
H.DEFAULTS = { stale = 3, lost = 15, start_grace = 30, parent_lost = 20 }

-- status: contents of status.json or nil;  rec: { instance_id, launched_at };  boot: contents of boot.json or nil
-- -> { state, age, dirty, play, pos, device_err }
-- state: "not_started" | "starting" | "booted" | "ok" | "stale" | "lost" | "closing" | "foreign" | "no_helper"
--   starting   launched, nothing seen yet (inside the grace period)
--   booted     the helper script is running but has not written a status yet
--   no_helper  grace period over and the helper script never ran: REAPER may have opened, but our script did not start
--   lost       the helper was seen, then went quiet (or the process is gone)
function H.eval(status, rec, now, cfg, boot)
  cfg = cfg or H.DEFAULTS
  local out = { state = "not_started" }
  local grace = rec.launched_at and (now - rec.launched_at < cfg.start_grace)
  if status and rec.instance_id and status.id and status.id ~= "" and status.id ~= rec.instance_id then
    -- a status file written by some other launch: do not trust it, it is not our child
    out.state = grace and "starting" or "foreign"
    return out
  end
  if not status then
    if not rec.launched_at then return out end
    if boot then out.state = grace and "booted" or "lost"
    else out.state = grace and "starting" or "no_helper" end
    return out
  end
  out.age = now - (status.t or 0)
  out.dirty, out.play, out.pos, out.device_err, out.tp = status.dirty, status.play, status.pos, status.device_err, status.tp
  if status.state == "closing" then out.state = "closing"
  elseif out.age <= cfg.stale then out.state = "ok"
  elseif out.age <= cfg.lost then out.state = "stale"
  else out.state = "lost" end
  return out
end

-- for the child helper: has the parent stopped writing its heartbeat?
function H.parent_alive(parent_info, now, cfg)
  cfg = cfg or H.DEFAULTS
  if not parent_info or not parent_info.t then return false end
  return now - parent_info.t <= cfg.parent_lost
end

--------------------------------------------------------------------------------
-- lifecycle + recovery
--------------------------------------------------------------------------------
local R = {}
M.recover = R

-- allowed moves of a PROJECT record's `state`
R.TRANSITIONS = {
  attached = { detach = "detached", sync = "attached" },
  detached = { reattach = "attached", relaunch = "detached" },
}

function R.can(state, action) return R.TRANSITIONS[state] ~= nil and R.TRANSITIONS[state][action] ~= nil end

-- rec:   { state, op?, file }                      op = the operation that was in progress when the record was last written
-- facts: { file_exists, file_changed (content hash differs from the last agreed base), health = H.eval(...) }
-- -> list of { action, why }  (most sensible first). Empty list = nothing to do.
function R.plan(rec, facts)
  local out = {}
  local function add(a, why) out[#out + 1] = { action = a, why = why } end
  if rec.op then
    add("finish_or_rollback_" .. rec.op, "'" .. rec.op .. "' was interrupted (REAPER closed or crashed while it ran)")
    return out
  end
  local edited = facts.file_exists and facts.file_changed
  if rec.state == "detached" then
    local h = facts.health and facts.health.state or "not_started"
    if not facts.file_exists then
      add("locate_file", "the child project file is missing: " .. tostring(rec.file))
      add("abandon", "forget the detached child (its tracks are not in this project)")
    elseif h == "ok" or h == "starting" or h == "booted" or h == "stale" then
      -- running: nothing to recover
      if h == "stale" then add("wait", "child heartbeat is late; it may be busy") end
    else
      if facts.health and facts.health.dirty then add("warn_unsaved", "the child was last seen with unsaved changes") end
      add("relaunch", "the child instance is not running")
      add("reattach", edited and "the child file was edited since it was detached" or "take the tracks back into this project")
    end
  elseif rec.state == "attached" then
    if edited then add("pull", "the child file changed on disk since the last sync") end
    if not facts.file_exists and rec.file then add("export", "the child file is missing: write it from the tracks in this project") end
  end
  return out
end

return M

end
__preload["NPChild"] = function(...)
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

end

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

