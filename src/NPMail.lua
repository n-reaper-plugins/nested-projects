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
