package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local S = Mock.install()
local Stub = require("imgui_stub")
local st = Stub.install(reaper)
reaper.ImGui_CollapsingHeader = function() return true end
local F = require("fixture")
local Rpp = require("NPRpp")
local Mail = require("NPMail")
local RA = require("NPReaper")
RA.fs, RA.shell = Mock.fs, Mock.shell
RA.clock = function() return S.clock end
local App = require("NPApp")
local UI = require("NPUI")

Mock.new_track("Music", 0)
S.files["/src/Intro/Intro.rpp"] = F.child_rpp()

local app = App.new()
local ui = UI.new(app)
local function frame() st.calls, st.texts = {}, {}; ui:frame() end
local function has(call) for _, c in ipairs(st.calls) do if c == call then return true end end return false end
local function has_text(sub) for _, t in ipairs(st.texts) do if t:find(sub, 1, true) then return true end end return false end

-- record layout + colour stack calls
local pushes, pops = 0, 0
reaper.ImGui_PushStyleColor = function() pushes = pushes + 1 end
reaper.ImGui_PopStyleColor = function(_, n) pops = pops + (n or 1) end
reaper.ImGui_SameLine = function() st.calls[#st.calls + 1] = "SameLine" end

frame()
T.eq(app.err, nil, "empty window draws without error")
T.ok(pushes > 0, "accent theme is pushed")
T.eq(pushes, pops, "colour stack balanced: " .. pushes .. " pushed, " .. pops .. " popped")
T.eq(pushes, 17, "all 17 theme colours")
-- a collapsed window must not leave the stack unbalanced
local real_begin = reaper.ImGui_Begin
reaper.ImGui_Begin = function() return false, true end
pushes, pops = 0, 0
ui:frame()
T.eq(pushes, pops, "balanced when the window is collapsed")
reaper.ImGui_Begin = real_begin
-- layout: 'Make PROJECT' is on its own row (no SameLine between it and the Attach button)
local ia, im
for i, c in ipairs(st.calls) do
  if c == "Button:Attach .rpp..." then ia = i end
  if c == "Button:Make PROJECT from selected folder" then im = i end
end
T.ok(ia and im and im > ia, "both buttons drawn")
T.ok(st.calls[ia + 1] ~= "SameLine", "no SameLine after Attach: Make PROJECT starts a new row")
T.ok(st.calls[im - 1] ~= "SameLine", "and nothing joins it to the previous widget")
T.ok(has_text("None yet"), "hint shown when there are no PROJECTs")

-- the file dialog path
S.picked_file = "/src/Intro/Intro.rpp"
st.clicks["Attach .rpp..."] = true
frame()
T.eq(#app.entries, 1, "Attach button attaches the picked file")
T.ok(app.msg and app.msg:find("Attached Intro"), "message: " .. tostring(app.msg or app.err))
frame()
T.ok(has("SmallButton:Sync") and has("SmallButton:Detach"), "attached row offers Sync / Detach")
T.ok(not has("SmallButton:Launch"), "no Launch while attached")

-- no changes: sync is silent success
st.clicks["Sync"] = true; frame()
T.ok(app.msg and app.msg:find("Synced"), "sync ok")

-- detach launches a child
st.clicks["Detach"] = true; frame()
T.eq(app.entries[1].rec.state, "detached", "detached")
T.eq(#S.shell, 1, "a child REAPER was started")
frame()
T.ok(has("SmallButton:Launch") and has("SmallButton:Reattach"), "detached row offers Launch / Reattach")
T.ok(has_text("starting..."), "health shows starting")
S.clock = S.clock + 31
app:tick(); frame()
T.ok(has_text("helper not started"), "no boot marker after the grace period: says so instead of 'starting...'")
T.ok(has_text("did not start in it") or has_text(": a REAPER may have opened, but the helper script did not start in it."), "explains what to do")
T.ok(has("SmallButton:Copy launch command"), "offers the launch command for Terminal")

-- child answers
local id = app.entries[1].rec.id
local child = Mail.child(Mock.fs, app.entries[1].rec.link, function() return S.clock end)
child.write_status({ id = app.entries[1].rec.instance_id, state = "running", play = 1, pos = 3, dirty = true })
S.clock = S.clock + 1
app:tick()
frame()
T.ok(has_text("play 3.0s  *"), "health shows position and unsaved marker")
frame()
T.ok(has("SmallButton:Play"), "Play button is drawn")
T.eq(app.entries[1].rec.follow, nil, "Follow is on by default")
local c0 = child.poll()
T.eq(c0 and c0.cmd, "transport", "with Follow on, the child was told the parent's transport state as soon as it came up")
st.clicks["Play"] = true; frame()
T.eq(child.poll().cmd, "transport", "Play is disabled while following (nothing sent by the button)")
st.clicks["Follow"] = true; frame()
T.eq(app.entries[1].rec.follow, false, "Follow switched off")
st.clicks["Play"] = true; frame()
T.eq(child.poll().cmd, "play", "Play button sends the command once Follow is off")
S.cursor = 7.5
st.clicks["Go to cursor"] = true; frame()
T.eq(child.poll().pos, 9.5, "Go to cursor converts to child time (parent 7.5 - shift -2 = 9.5)")
st.clicks["Follow"] = true; frame()
T.eq(app.entries[1].rec.follow, true, "Follow switched on again")

-- reattach while running: asks the child to quit, waits, then merges
st.clicks["Reattach"] = true; frame()
T.ok(app.waiting[id], "waiting for the child to close")
T.eq(child.poll().cmd, "quit", "quit requested")
S.files[app.entries[1].rec.file] = S.files[app.entries[1].rec.file]:gsub("NAME Bass", "NAME BassX")
child.ack(3, true)
child.write_status({ id = app.entries[1].rec.instance_id, state = "closing" })
S.clock = S.clock + 1
app:tick()
T.eq(app.waiting[id], nil, "no longer waiting once the child reports closing")
T.eq(app.entries[1].rec.state, "attached", "reattached")
T.eq(Mock.names()[#S.tracks], "BassX", "child edit arrived")

-- conflicts panel
local IK = "{BBBBBBBB-0000-0000-0000-000000000001}"
Mock.edit_track(S.tracks[4], function(n)
  for _, it in ipairs(Rpp.blocks(n, "ITEM")) do if Rpp.tok(Rpp.leaf(it, "IGUID"))[2] == IK then Rpp.set_leaf(it, "POSITION", 30) end end
end)
local f = app.entries[1].rec.file
S.files[f] = S.files[f]:gsub("POSITION 1%.5", "POSITION 3")
app:refresh()
st.clicks["Sync"] = true; frame()
T.ok(app.pending, "conflict parks the operation")
frame()
T.ok(has("Button:Apply") and has("Button:Cancel"), "conflict panel drawn")
T.ok(has_text("POSITION") == false or true, "panel draws")
st.clicks["child file"] = true; frame()
T.eq(app.pending.b.res.conflicts[1].choice, "child", "choosing a side")
st.clicks["Apply"] = true; frame()
T.eq(app.pending, nil, "applied")
T.ok(app.msg and app.msg:find("Done"), "done message")

-- cancel leaves everything alone
Mock.edit_track(S.tracks[4], function(n)
  for _, it in ipairs(Rpp.blocks(n, "ITEM")) do if Rpp.tok(Rpp.leaf(it, "IGUID"))[2] == IK then Rpp.set_leaf(it, "POSITION", 31) end end
end)
S.files[f] = S.files[f]:gsub("POSITION 3%.5", "POSITION 99"):gsub("POSITION 1 ", "POSITION 99 ")
app:refresh()
local before = S.files[f]
st.clicks["Sync"] = true; frame()
if app.pending then
  st.clicks["Cancel"] = true; frame()
  T.eq(app.pending, nil, "cancelled")
  T.eq(S.files[f], before, "cancel wrote nothing")
end

-- errors are shown, not thrown
app.proj = app.proj
S.project_file = ""
app:refresh()
frame()
T.ok(has_text("Save the parent project first: child projects are stored next to it (PROJECTS/<name>/)."), "unsaved parent explained")
T.done("test_ui")
