package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
local Rpp = require("NPRpp")
local X = require("NPXform")
local Mail = require("NPMail")
local F = require("fixture")
local RA = require("NPReaper")
RA.fs, RA.shell = Mock.fs, Mock.shell
RA.clock = function() return S.clock end

local function item_pos(tr, iguid)
  local n = Rpp.parse(tr.chunk)
  for _, it in ipairs(Rpp.blocks(n, "ITEM")) do
    if Rpp.tok(Rpp.leaf(it, "IGUID"))[2] == iguid then return Rpp.tok(Rpp.leaf(it, "POSITION"))[2] end
  end
end
local IK = "{BBBBBBBB-0000-0000-0000-000000000001}"

-- a parent with two ordinary tracks, saved
Mock.new_track("Music", 0); Mock.new_track("Voice", 0)
S.files["/src/Intro/Intro.rpp"] = F.child_rpp()

--------------------------------------------------------------------------------
-- attach
--------------------------------------------------------------------------------
local entry, info = RA.attach(0, "/src/Intro/Intro.rpp", { offset = 10 })
T.ok(entry, "attach works: " .. tostring(info))
T.eq(#S.tracks, 7, "2 + folder + 4 children")
T.eq(Mock.names()[3], "PROJECT: Intro", "folder name")
T.eq(Mock.depth_sum(), 0, "folder structure balanced after attach")
T.eq(S.tracks[6].depth, -1, "Snare closes Drums")
T.eq(S.tracks[7].depth, -1, "last child closes the PROJECT")
T.eq(S.tracks[3].depth, 1, "PROJECT opens")
T.eq(#S.markers, 2, "marker + region imported")
T.eq(S.markers[1].pos, 9, "marker shifted by offset(10) + projoffs(-2)")
T.eq(S.markers[2].rgnend, 16, "region end shifted")
T.eq(item_pos(S.tracks[5], IK), "9.5", "kick item shifted")
T.ok(Mock.S.files["/proj/PROJECTS/Intro/Intro.rpp"], "working copy written next to the parent")
T.ok(Mock.S.files["/proj/PROJECTS/Intro/.link/base.rpp"], "base written")
T.ok(Mock.S.files["/proj/PROJECTS/Intro/.link/state.json"], "state written")
T.ok(Rpp.serialize(Rpp.parse(S.files["/proj/PROJECTS/Intro/Intro.rpp"])):find("/src/Intro/audio/kick.wav", 1, true), "media made absolute in the copy")
T.eq(S.tracks[3].ext.NP_DATA ~= nil, true, "record on the folder")
T.eq(S.tracks[1].ext.NP_DATA, nil, "ordinary tracks untouched")
local e2, err2 = RA.attach(0, "/src/Intro/Intro.rpp", {})
T.eq(e2, nil, "attaching the same file twice is refused")
T.ok(tostring(err2):find("already"), "with a reason: " .. tostring(err2))
T.eq(#S.tracks, 7, "and changed nothing")

local list = RA.list(0)
T.eq(#list, 1, "one PROJECT found")
entry = list[1]
T.eq(entry.rec.state, "attached", "state attached")
T.eq(entry.index, 2, "folder index")

--------------------------------------------------------------------------------
-- sync: nothing changed -> nothing happens (REAPER's own normalisation must not look like an edit)
--------------------------------------------------------------------------------
local out, b = RA.sync(0, entry)
T.ok(out, "sync ok")
T.eq(#b.res.conflicts, 0, "no conflicts")
T.eq(#b.res.log, 0, "no changes detected despite REAPER adding default lines")
T.eq(out.updated_parent, false, "parent untouched")

-- parent edit -> goes to the file
Mock.edit_track(S.tracks[5], function(n)
  for _, it in ipairs(Rpp.blocks(n, "ITEM")) do
    if Rpp.tok(Rpp.leaf(it, "IGUID"))[2] == IK then Rpp.set_leaf(it, "POSITION", 12.5) end
  end
end)
out, b = RA.sync(0, entry)
T.ok(out and #b.res.conflicts == 0, "parent edit synced")
local filetext = S.files["/proj/PROJECTS/Intro/Intro.rpp"]
T.ok(filetext:find("POSITION 4.5", 1, true), "file has the position in child space (12.5 - 8)")
T.ok(not filetext:find("POSITION 12.5", 1, true), "no parent-space time leaked into the file")

-- child file edit -> comes into the parent
S.files["/proj/PROJECTS/Intro/Intro.rpp"] = filetext:gsub("NAME Snare", "NAME Snare2")
out, b = RA.sync(0, entry)
T.ok(out, "child edit synced")
T.eq(out.updated_parent, true, "parent refreshed")
T.eq(#S.tracks, 7, "still 7 tracks after rebuilding the folder")
T.eq(Mock.names()[6], "Snare2", "child rename arrived in the parent")
T.eq(Mock.depth_sum(), 0, "still balanced")
T.eq(item_pos(S.tracks[5], IK), "12.5", "earlier parent edit survived the rebuild")
T.ok(S.tracks[3].ext.NP_DATA ~= nil, "record survived the chunk rewrite")
entry = RA.list(0)[1]

-- conflict: both change the same thing
Mock.edit_track(S.tracks[5], function(n)
  for _, it in ipairs(Rpp.blocks(n, "ITEM")) do
    if Rpp.tok(Rpp.leaf(it, "IGUID"))[2] == IK then Rpp.set_leaf(it, "POSITION", 20) end
  end
end)
S.files["/proj/PROJECTS/Intro/Intro.rpp"] = S.files["/proj/PROJECTS/Intro/Intro.rpp"]:gsub("POSITION 4%.5", "POSITION 1")
out, err, b = RA.sync(0, entry)
T.eq(out, nil, "conflict: nothing applied"); T.eq(err, "conflicts", "reported as conflicts")
T.eq(#b.res.conflicts, 1, "one conflict")
T.eq(item_pos(S.tracks[5], IK), "20", "parent unchanged while unresolved")
require("NPMerge").choose(b.res, 1, "child")
out = RA.apply_bundle(0, b)
T.ok(out, "resolved bundle applied")
T.eq(item_pos(S.tracks[5], IK), "9", "child's value (1 + 8) now in the parent")
entry = RA.list(0)[1]

--------------------------------------------------------------------------------
-- detach + launch + commands + health
--------------------------------------------------------------------------------
local ok, derr = RA.detach(0, entry, { launch = false })
T.ok(ok, "detach ok: " .. tostring(derr))
T.eq(#S.tracks, 3, "children gone, ghost folder stays")
T.eq(S.tracks[3].depth, 0, "ghost is not a folder any more")
T.eq(#S.markers, 0, "markers gone")
T.ok(Mock.names()[3]:find("%[detached%]"), "ghost labelled")
entry = RA.list(0)[1]
T.eq(entry.rec.state, "detached", "state detached")
T.eq(entry.rec.op, nil, "journal cleared")
T.ok(entry.rec.instance_id, "instance id assigned")
T.ok(S.files["/proj/PROJECTS/Intro/Intro.rpp"]:find("POSITION 1", 1, true), "file holds the latest content")

S.files["/Users/x/Library/Application Support/REAPER/reaper.ini"] = "[REAPER]\nx=1\n"
S.files["/Applications/REAPER.app/Contents/MacOS/REAPER"] = "binary"
local ok2, cmd = RA.launch(0, entry, { child_script = "/scripts/NestedProjectsChild.lua" })
T.ok(ok2, "launch ok")
T.ok(cmd:find("-newinst", 1, true), "own instance")
T.ok(not cmd:find("-cfgfile", 1, true), "own config is opt-in: not used by default")
T.ok(cmd:find("'/Applications/REAPER.app/Contents/MacOS/REAPER'", 1, true), "executable found among the usual places")
T.ok(cmd:find(">'/proj/PROJECTS/Intro/.link/launch.log' 2>&1 &", 1, true), "output goes to launch.log, in the background")
T.ok(cmd:find("NP_LINK_DIR='/proj/PROJECTS/Intro/.link'", 1, true), "link dir passed by environment")
T.ok(cmd:find("'/proj/PROJECTS/Intro/Intro.rpp'", 1, true) and cmd:find("NestedProjectsChild.lua", 1, true), "project + helper on the command line")
T.ok(S.files["/proj/PROJECTS/Intro/.link/child.json"], "fallback marker written")
T.ok(not S.files["/proj/PROJECTS/Intro/.link/reaper.ini"], "no config copy by default")
entry = RA.list(0)[1]
T.eq(RA.health(entry).state, "starting", "starting right after launch")
-- nothing happens: after the grace period we say the helper never started, and show what we know
S.clock = S.clock + 31
T.eq(RA.health(entry).state, "no_helper", "no boot marker after the grace period = the helper never ran")
S.files["/proj/PROJECTS/Intro/.link/launch.log"] = "dyld: Library not loaded\n"
T.ok(RA.diagnostics(entry).launch_log:find("dyld"), "launch.log is available for display")
-- the helper script starts but has not reported yet
Mail.child(Mock.fs, entry.rec.link, RA.clock).write_boot({ id = entry.rec.instance_id, via = "env" })
S.clock = S.clock - 26
T.eq(RA.health(entry).state, "booted", "boot marker seen: the helper is alive, waiting for its first status")
S.clock = S.clock + 26
-- relaunch clears everything the previous launch left
S.files["/Users/x/Library/Application Support/REAPER/reaper.ini"] = "[REAPER]\nx=1\n"
local okc, cmdc = RA.launch(0, entry, { child_script = "/scripts/NestedProjectsChild.lua", own_config = true })
T.ok(cmdc:find("-cfgfile '/proj/PROJECTS/Intro/.link/cfg/reaper.ini'", 1, true), "own config used when the setting is on")
T.ok(S.files["/proj/PROJECTS/Intro/.link/cfg/reaper.ini"], "reaper.ini copied into the private config folder")
local link_cmd = S.shell[#S.shell - 1]
T.ok(link_cmd and link_cmd:find("ln -s", 1, true), "the rest of the resource folder is linked in (license, scripts, plugins) before launching")
T.ok(link_cmd:find("Library/Application Support/REAPER", 1, true) and link_cmd:find("/cfg", 1, true), "from the real resource folder into the private one")
T.ok(link_cmd:find("reaper.ini|.DS_Store", 1, true), "but never the ini itself")
T.ok(S.shell[#S.shell]:find("-cfgfile", 1, true), "and the launch comes after the linking")
-- an old value saved by 0.1.0 (which defaulted to ON) must not switch the option on again
reaper.SetExtState("NestedProjects", "own_config", "1", true)
T.eq(RA.load_cfg().own_config, false, "setting saved by an older version is ignored: off")
reaper.SetExtState("NestedProjects", "own_config_v2", "1", true)
T.eq(RA.load_cfg().own_config, true, "and the new one is honoured")
reaper.SetExtState("NestedProjects", "own_config_v2", "0", true)
-- Windows: no symlinks, the license file is copied
local real_os = reaper.GetOS
reaper.GetOS = function() return "Win64" end
S.files["/Users/x/Library/Application Support/REAPER/reaper-license.rk"] = "LICENSE"
local nshell = #S.shell
RA.prepare_config(entry.rec)
T.eq(S.files["/proj/PROJECTS/Intro/.link/cfg/reaper-license.rk"], "LICENSE", "windows: license copied into the private folder")
T.eq(#S.shell, nshell, "windows: no shell linking")
reaper.GetOS = real_os
T.eq(RA.health(RA.list(0)[1]).state, "starting", "relaunch resets to starting (old boot marker and log cleared)")
T.eq(RA.diagnostics(entry).launch_log, nil, "old launch log cleared")
entry = RA.list(0)[1]

-- the child helper answers
local child = Mail.child(Mock.fs, entry.rec.link, RA.clock)
child.write_status({ id = entry.rec.instance_id, state = "running", play = 0, pos = 0, dirty = false, project = entry.rec.file })
T.eq(RA.health(entry).state, "ok", "ok once the child writes status")
T.eq(RA.command(entry, "locate", { pos = 12 }), 1, "locate sent")
T.eq(child.poll().cmd, "locate", "child receives it")
T.eq(#RA.plan(entry), 0, "healthy child: no recovery actions")

-- child still running: reattach is refused
local r1, r2 = RA.reattach(0, entry, {})
T.eq(r1, nil, "reattach refused while the child runs"); T.eq(r2, "child_running", "with the reason")

-- child is edited in its own instance (file on disk), then closes
S.files["/proj/PROJECTS/Intro/Intro.rpp"] = S.files["/proj/PROJECTS/Intro/Intro.rpp"]:gsub("NAME Bass", "NAME BassChild")
S.clock = S.clock + 60
T.eq(RA.health(entry).state, "lost", "no heartbeat any more: lost")
local plan = RA.plan(entry)
T.eq(plan[1].action, "relaunch", "recovery offers relaunch"); T.eq(plan[2].action, "reattach", "and reattach")
ok, derr = RA.reattach(0, entry, { policy = "parent" })
T.ok(ok, "reattach ok: " .. tostring(derr))
T.eq(#S.tracks, 7, "tracks are back")
T.eq(Mock.names()[7], "BassChild", "child edit arrived")
T.eq(Mock.names()[3], "PROJECT: Intro", "label restored")
T.eq(Mock.depth_sum(), 0, "balanced")
T.eq(#S.markers, 2, "markers back")
T.eq(S.markers[1].pos, 9, "at the right place")
T.eq(item_pos(S.tracks[5], IK), "9", "items at the right place")
entry = RA.list(0)[1]
T.eq(entry.rec.state, "attached", "attached again")

--------------------------------------------------------------------------------
-- shadow detach: both sides keep editing, reattach merges
--------------------------------------------------------------------------------
ok = RA.detach(0, entry, { shadow = true })
T.ok(ok, "shadow detach")
T.eq(#S.tracks, 7, "shadow copies stay")
T.eq(S.tracks[3].mute, 1, "and are muted")
entry = RA.list(0)[1]
Mock.edit_track(S.tracks[4], function(n) Rpp.set_leaf(n, "VOLPAN", 0.5, 0, -1, -1, 1) end)             -- parent edits Drums
S.files["/proj/PROJECTS/Intro/Intro.rpp"] = S.files["/proj/PROJECTS/Intro/Intro.rpp"]:gsub("NAME Kick", "NAME KickChild")   -- child edits Kick
S.clock = S.clock + 60
ok, derr = RA.reattach(0, entry, {})
T.ok(ok, "reattach with shadow: " .. tostring(derr))
T.eq(S.tracks[3].mute, 0, "unmuted")
local drums = Rpp.parse(S.tracks[4].chunk)
T.eq(Rpp.leaf(drums, "VOLPAN").raw, "VOLPAN 0.5 0 -1 -1 1", "parent's edit kept")
T.eq(Mock.names()[5], "KickChild", "child's edit arrived")

--------------------------------------------------------------------------------
-- interrupted operation is reported first
--------------------------------------------------------------------------------
entry = RA.list(0)[1]
entry.rec.op = "detach"
T.eq(RA.plan(entry)[1].action, "finish_or_rollback_detach", "interrupted op recognised")
entry.rec.op = nil

--------------------------------------------------------------------------------
-- an existing folder becomes a PROJECT
--------------------------------------------------------------------------------
local n0 = #S.tracks
local f = Mock.new_track("Atmos", 1); Mock.new_track("Wind", 0); Mock.new_track("Rain", -1)
S.files["/proj/PROJECTS/Atmos/Atmos.rpp"] = nil
local mp, merr = RA.make_project(0, f)
T.ok(mp, "make_project: " .. tostring(merr))
local atext = S.files["/proj/PROJECTS/Atmos/Atmos.rpp"]
T.ok(atext, "child file written")
local av = X.read_project(atext)
T.eq(#av.tracks, 2, "child file holds the folder's 2 children")
T.eq(#S.tracks, n0 + 3, "parent unchanged")
T.eq(Mock.depth_sum(), 0, "still balanced")
local e3 = RA.list(0)[2]
T.eq(e3.rec.name, "Atmos", "listed")
ok = RA.detach(0, e3, {})
T.ok(ok and #S.tracks == n0 + 1, "detach the converted group")
e3 = RA.list(0)[2]
S.clock = S.clock + 60
ok = RA.reattach(0, e3, {})
T.ok(ok and #S.tracks == n0 + 3, "and bring it back")
T.eq(Mock.depth_sum(), 0, "balanced after the round trip")
T.eq(Mock.names()[#S.tracks], "Rain", "order kept")

-- precondition errors
local bad = RA.make_project(0, S.tracks[1])
T.eq(bad, nil, "a plain track cannot become a PROJECT")
T.done("test_reaper")
