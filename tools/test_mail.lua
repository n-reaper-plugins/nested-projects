package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local M = require("NPMail")
local J, H, R = M.json, M.health, M.recover

-- json
local s = J.encode({ a = 1, b = "x\"y\n", c = { 1, 2, 3 }, d = true, e = 1.5, f = {} })
local d = J.decode(s)
T.eq(d.a, 1, "int"); T.eq(d.b, "x\"y\n", "escaped string"); T.eq(#d.c, 3, "array"); T.eq(d.d, true, "bool"); T.eq(d.e, 1.5, "float")
T.eq(J.try_decode("{broken"), nil, "broken json -> nil, no error")
T.eq(J.try_decode(nil), nil, "nil json")
T.eq(J.decode('{"k":[{"x":-2e2}]}').k[1].x, -200, "nested + exponent")
T.eq(J.decode('"\\u00e9"'), "é", "unicode escape")
T.eq(J.encode({ k = "a/b" }), '{"k":"a/b"}', "keys sorted, slash untouched")

-- fake fs
local files, mt, now = {}, {}, 1000
local fs = {
  read = function(p) return files[p] end,
  write_atomic = function(p, s) files[p] = s; mt[p] = now; return true end,
  exists = function(p) return files[p] ~= nil end,
  mkdir = function() end, mtime = function(p) return mt[p] end,
}
local clock = function() return now end
local P = M.parent(fs, "/l", clock)
local C = M.child(fs, "/l", clock)

T.eq(C.poll(), nil, "no command yet")
local seq = P.send("play")
T.eq(seq, 1, "first seq")
T.ok(P.pending(), "pending until acked")
local c = C.poll()
T.eq(c.cmd, "play", "child sees play")
C.ack(c.seq, true)
T.ok(not P.pending(), "acked")
T.eq(C.poll(), nil, "not delivered twice")
T.eq(P.send("locate", { pos = 12.5 }), 2, "second seq")
T.eq(C.poll().pos, 12.5, "locate carries pos")
T.eq(P.send("locate"), nil, "locate without pos rejected")
T.eq(select(2, P.send("explode")), "unknown command explode", "unknown command rejected")
-- helper restarted: must not replay the already handled command
C.ack(2, true)
local C2 = M.child(fs, "/l", clock)
T.eq(C2.poll(), nil, "restarted helper does not replay handled commands")
P.send("stop")
T.eq(C2.poll().cmd, "stop", "but sees new ones")
C2.ack(3, false, "boom")
T.eq(P.ack().err, "boom", "error travels back")

-- boot marker
T.eq(P.boot(), nil, "no boot marker yet")
C.write_boot({ id = "abc", via = "env" })
T.eq(P.boot().via, "env", "boot marker readable by the parent")

-- status + health
local rec = { instance_id = "abc", launched_at = 1000 }
T.eq(H.eval(nil, rec, 1005).state, "starting", "no status yet, inside grace")
T.eq(H.eval(nil, rec, 1100).state, "no_helper", "no status and no boot marker after grace: the helper never ran")
T.eq(H.eval(nil, rec, 1005, nil, { id = "abc" }).state, "booted", "helper started but no status yet")
T.eq(H.eval(nil, rec, 1100, nil, { id = "abc" }).state, "lost", "helper started, then nothing for too long")
T.eq(H.eval({ id = "", t = 1000 }, rec, 1001).state, "ok", "a status without an id is accepted (marker fallback)")
T.eq(H.eval({ id = "other", t = 1000 }, rec, 1005).state, "starting", "foreign status inside the grace period = still starting")
T.eq(H.eval(nil, {}, 1100).state, "not_started", "never launched")
C.write_status({ id = "abc", state = "running", play = 1, pos = 3.5, dirty = true, project = "/x.rpp" })
local h = H.eval(P.status(), rec, 1001)
T.eq(h.state, "ok", "fresh heartbeat = ok"); T.eq(h.dirty, true, "dirty passes through"); T.eq(h.pos, 3.5, "pos passes through")
T.eq(H.eval(P.status(), rec, 1006).state, "stale", "late heartbeat = stale")
T.eq(H.eval(P.status(), rec, 1100).state, "lost", "very late = lost")
T.eq(H.eval({ id = "other", t = 1000 }, rec, 1100).state, "foreign", "status of another launch is not trusted")
T.eq(H.eval({ id = "abc", t = 1000, state = "closing" }, rec, 1001).state, "closing", "closing reported")
T.ok(H.parent_alive({ t = 990 }, 1000), "parent heartbeat fresh")
T.ok(not H.parent_alive({ t = 900 }, 1000), "parent heartbeat old")
T.ok(not H.parent_alive(nil, 1000), "no parent file")

-- recovery
local function acts(p) local o = {} for i, x in ipairs(p) do o[i] = x.action end return table.concat(o, ",") end
T.eq(acts(R.plan({ state = "detached", file = "/c.rpp" }, { file_exists = true, health = { state = "ok" } })), "", "healthy child: nothing to do")
T.eq(acts(R.plan({ state = "detached", file = "/c.rpp" }, { file_exists = true, health = { state = "lost", dirty = true } })), "warn_unsaved,relaunch,reattach", "lost child")
T.eq(acts(R.plan({ state = "detached", file = "/c.rpp" }, { file_exists = true, health = { state = "no_helper" } })), "relaunch,reattach", "helper never started: relaunch or reattach")
T.eq(acts(R.plan({ state = "detached", file = "/c.rpp" }, { file_exists = true, health = { state = "booted" } })), "", "booted: nothing to recover")
T.eq(acts(R.plan({ state = "detached", file = "/c.rpp" }, { file_exists = false, health = { state = "lost" } })), "locate_file,abandon", "missing file")
T.eq(acts(R.plan({ state = "attached", file = "/c.rpp" }, { file_exists = true, file_changed = true })), "pull", "attached + file edited on disk")
T.eq(acts(R.plan({ state = "attached", file = "/c.rpp" }, { file_exists = true, file_changed = false })), "", "attached + unchanged")
T.eq(acts(R.plan({ state = "detached", op = "detach" }, {})), "finish_or_rollback_detach", "interrupted operation comes first")
T.eq(acts(R.plan({ state = "detached", file = "/c" }, { file_exists = true, health = { state = "stale" } })), "wait", "stale = wait")
T.ok(R.can("attached", "detach") and not R.can("attached", "reattach") and R.can("detached", "reattach"), "transitions")
T.done("test_mail")
