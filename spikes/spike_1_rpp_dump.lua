-- @description NestedProjects spike 1: dump the structure of the CURRENT project's .rpp (save the project first)
-- Checks the guesses NPXform/NPSnap make about the file format. Output goes to the REAPER console; paste it back.
local r = reaper
local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""
package.path = dir .. "../src/?.lua;" .. dir .. "?.lua;" .. package.path
local Rpp = require("NPRpp")

local function out(s) r.ShowConsoleMsg(s .. "\n") end
local _, fn = r.EnumProjects(-1)
if not fn or fn == "" then r.MB("Save the project first.", "spike 1", 0); return end
local f = io.open(fn, "rb"); local text = f:read("*a"); f:close()
local root = Rpp.parse(text)
out("=== SPIKE 1: " .. fn)
out("root: " .. root.head)

local counts, order = {}, {}
for _, c in ipairs(root.items) do
  local k = (c.kind == "block" and "<" or "") .. (c.kind == "block" and c.name or c.key)
  if not counts[k] then counts[k] = 0; order[#order + 1] = k end
  counts[k] = counts[k] + 1
end
out("-- top-level entries (name x count):")
for _, k in ipairs(order) do out(string.format("   %-24s x%d", k, counts[k])) end

local function sample(key, n)
  local got = 0
  for _, c in ipairs(root.items) do
    if c.kind == "leaf" and c.key == key and got < (n or 1) then out("   " .. c.raw); got = got + 1 end
  end
end
out("-- samples:")
for _, k in ipairs({ "TEMPO", "PROJOFFS", "SAMPLERATE", "MASTER_VOLUME", "TIMEMODE" }) do sample(k) end
sample("MARKER", 4)

local ml = Rpp.block(root, "MASTERFXLIST")
out("-- MASTERFXLIST: " .. (ml and "found" or "NOT FOUND (master FX may live elsewhere)"))
if ml then for _, c in ipairs(ml.items) do out("   inside: " .. (c.kind == "block" and ("<" .. c.name) or c.raw:sub(1, 60))) end end
for _, c in ipairs(root.items) do
  if c.kind == "block" and c.name:find("ENV", 1, true) then out("-- top-level envelope block: <" .. c.name .. "  (" .. #c.items .. " lines)") end
end

local tr = Rpp.block(root, "TRACK")
if tr then
  out("-- first TRACK head: " .. tr.head)
  local keys = {}
  for _, c in ipairs(tr.items) do keys[#keys + 1] = (c.kind == "block" and "<" or "") .. (c.kind == "block" and c.name or c.key) end
  out("   entries: " .. table.concat(keys, " "))
  for _, k in ipairs({ "ISBUS", "BEAT", "VOLPAN", "AUXRECV", "TRACKID" }) do
    local l = Rpp.leaf(tr, k); if l then out("   " .. l.raw) end
  end
  local it = Rpp.block(tr, "ITEM")
  if it then
    local ik = {}
    for _, c in ipairs(it.items) do ik[#ik + 1] = (c.kind == "block" and "<" or "") .. (c.kind == "block" and c.name or c.key) end
    out("-- first ITEM entries: " .. table.concat(ik, " "))
    for _, k in ipairs({ "POSITION", "LENGTH", "IGUID", "BEAT" }) do local l = Rpp.leaf(it, k); if l then out("   " .. l.raw) end end
    local src = Rpp.block(it, "SOURCE"); if src then out("   " .. src.head) end
  end
end
-- any MIDI source?
local r_done = false
Rpp.walk(root, function(n)
  if n.kind == "block" and n.name == "SOURCE" and n.args[1] == "MIDI" and not r_done then
    r_done = true
    local ks = {}
    for _, c in ipairs(n.items) do if c.kind == "leaf" and #ks < 8 then ks[#ks + 1] = c.raw:sub(1, 40) end end
    out("-- a MIDI source starts with: " .. table.concat(ks, " | "))
  end
end)
out("=== end of spike 1")
