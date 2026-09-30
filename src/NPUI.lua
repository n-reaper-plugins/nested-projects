-- NPUI.lua
-- ReaImGui front-end. Reads App state, calls App methods. Same style as PrototypeSequence.

local r = reaper
local V = require("NPVersion")
local X = require("NPXform")
local Merge = require("NPMerge")

local UI = {}
UI.__index = UI

local COL_HEAD = 0xFFCC44FF
local COL_OK   = 0x5FE07FFF
local COL_BAD  = 0xFF5F5FFF
local COL_WARN = 0xFFAA33FF
local COL_DIM  = 0x999999FF
local COL_INFO = 0x6FB7FFFF

-- Accent colour scheme. Hue 262 deg (from #4700C2); saturation, brightness and alpha are those of ImGui's default dark
-- style (its blue is hue 212 deg), so buttons/headers are translucent like the default instead of solid and heavy.
local BG = 0x181A1AFF
local THEME = {
  { "WindowBg", BG }, { "PopupBg", BG }, { "ChildBg", BG },
  { "FrameBg", 0x47297A8A }, { "FrameBgHovered", 0x8542FA66 }, { "FrameBgActive", 0x8542FAAB },
  { "Button", 0x8542FA66 }, { "ButtonHovered", 0x8542FAFF }, { "ButtonActive", 0x650FFAFF },
  { "SliderGrab", 0x793DE0FF }, { "SliderGrabActive", 0x8542FAFF }, { "CheckMark", 0x8542FAFF },
  { "Header", 0x8542FA4F }, { "HeaderHovered", 0x8542FACC }, { "HeaderActive", 0x8542FAFF },
  { "PlotHistogram", 0x8542FAFF }, { "TitleBgActive", 0x47297AFF },
}

local HEALTH_TEXT = {
  ok = { "running", COL_OK }, starting = { "starting...", COL_WARN }, booted = { "helper up, waiting...", COL_WARN },
  stale = { "not responding", COL_WARN }, lost = { "lost", COL_BAD }, closing = { "closing", COL_WARN },
  foreign = { "unknown instance", COL_BAD }, no_helper = { "helper not started", COL_BAD },
  not_started = { "not started", COL_DIM },
}

function UI.new(app)
  local self = setmetatable({}, UI)
  self.A = app
  self.ctx = r.ImGui_CreateContext("NestedProjects")
  self.title = "NestedProjects v" .. V.VERSION .. "###nested_projects_main"
  self.offset = 0.0
  self.name_buf = ""
  self.script_buf = nil
  return self
end

function UI:tip(text)
  if r.ImGui_IsItemHovered(self.ctx) and r.ImGui_SetTooltip then r.ImGui_SetTooltip(self.ctx, text) end
end

function UI:heading(text)
  local ctx = self.ctx
  r.ImGui_Spacing(ctx)
  r.ImGui_TextColored(ctx, COL_HEAD, text)
  r.ImGui_Separator(ctx)
end

-- small button that also carries a tooltip; returns true when clicked
function UI:btn(label, tip, disabled)
  local ctx = self.ctx
  if disabled and r.ImGui_BeginDisabled then r.ImGui_BeginDisabled(ctx, true) end
  local clicked = r.ImGui_SmallButton(ctx, label)
  if disabled and r.ImGui_EndDisabled then r.ImGui_EndDisabled(ctx) end
  if tip then self:tip(tip) end
  return clicked and not disabled
end

--------------------------------------------------------------------------------
function UI:draw_top()
  local A, ctx = self.A, self.ctx
  if not A.parent_file then
    r.ImGui_TextColored(ctx, COL_WARN, "Save the parent project first: child projects are stored next to it (PROJECTS/<name>/).")
  else
    r.ImGui_TextColored(ctx, COL_DIM, A.parent_file)
  end
  r.ImGui_Spacing(ctx)
  local ch, v = r.ImGui_InputDouble(ctx, "Start offset (s)##offset", self.offset)
  if ch then self.offset = v end
  self:tip("Where the child's time zero lands in this project. Applies to the next 'Attach'.")
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Attach .rpp...") then
    local ok, path = r.GetUserFileNameForRead("", "Choose the child project to attach", "rpp")
    if ok and path and path ~= "" then A:attach(path, nil, self.offset) end
  end
  self:tip("Adds the file's tracks below a new PROJECT folder. A working copy is made in PROJECTS/<name>/; your original is never touched.")
  if r.ImGui_Button(ctx, "Make PROJECT from selected folder") then A:make_project() end
  self:tip("Turns the selected folder track and its children into a PROJECT, so they can be detached into their own REAPER.")
end

local function health_of(A, e)
  local h = A.health[e.rec.id]
  return h and h.state or "not_started"
end

function UI:draw_projects()
  local A, ctx = self.A, self.ctx
  self:heading("PROJECT tracks")
  if #A.entries == 0 then
    r.ImGui_TextColored(ctx, COL_DIM, "None yet. Attach a .rpp, or select a folder track and press 'Make PROJECT'.")
    return
  end
  local flags = r.ImGui_TableFlags_Borders() | r.ImGui_TableFlags_RowBg()
  if r.ImGui_BeginTable(ctx, "projects", 4, flags) then
    r.ImGui_TableSetupColumn(ctx, "Name", r.ImGui_TableColumnFlags_WidthStretch(), 2)
    r.ImGui_TableSetupColumn(ctx, "State", r.ImGui_TableColumnFlags_WidthFixed(), 100)
    r.ImGui_TableSetupColumn(ctx, "Child REAPER", r.ImGui_TableColumnFlags_WidthFixed(), 130)
    r.ImGui_TableSetupColumn(ctx, "Actions", r.ImGui_TableColumnFlags_WidthStretch(), 5)
    r.ImGui_TableHeadersRow(ctx)
    for _, e in ipairs(A.entries) do
      local rec = e.rec
      r.ImGui_PushID(ctx, rec.id)
      r.ImGui_TableNextRow(ctx)
      r.ImGui_TableNextColumn(ctx); r.ImGui_Text(ctx, rec.name)
      r.ImGui_TableNextColumn(ctx)
      if rec.state == "attached" then r.ImGui_TextColored(ctx, COL_OK, "attached")
      else r.ImGui_TextColored(ctx, COL_INFO, rec.shadow and "detached (shadow)" or "detached") end
      r.ImGui_TableNextColumn(ctx)
      if rec.state == "detached" then
        local hs = health_of(A, e)
        local t = HEALTH_TEXT[hs] or { hs, COL_DIM }
        local h = A.health[rec.id] or {}
        local extra = ""
        if hs == "ok" then extra = (h.play and (h.play & 1) == 1) and string.format("  play %.1fs", h.pos or 0) or "  stopped" end
        if h.dirty then extra = extra .. "  *" end
        local d = A.drift[rec.id]
        if d then extra = extra .. string.format("  %+.0f ms", d * 1000) end
        r.ImGui_TextColored(ctx, t[2], t[1] .. extra)
        if h.device_err then r.ImGui_TextColored(ctx, COL_BAD, h.device_err) end
      else r.ImGui_TextColored(ctx, COL_DIM, "-") end
      r.ImGui_TableNextColumn(ctx)
      self:draw_actions(e)
      r.ImGui_PopID(ctx)
    end
    r.ImGui_EndTable(ctx)
  end
  for _, e in ipairs(A.entries) do self:draw_plan(e); self:draw_diagnostics(e) end
end

-- what to do when a detached child does not come up
function UI:draw_diagnostics(e)
  local A, ctx = self.A, self.ctx
  if e.rec.state ~= "detached" then return end
  local hs = health_of(A, e)
  if hs ~= "no_helper" and hs ~= "lost" and hs ~= "starting" and hs ~= "booted" then return end
  local d = A:diagnostics(e.rec.id) or {}
  if hs == "no_helper" then
    r.ImGui_TextColored(ctx, COL_BAD, e.rec.name .. ": a REAPER may have opened, but the helper script did not start in it.")
    r.ImGui_TextWrapped(ctx, "In that child REAPER window run the action 'Script: NestedProjectsChild.lua' once (Actions > Show action list). It finds its folder by itself. If no second REAPER opened at all, see the launch log below.")
  elseif hs == "lost" then
    r.ImGui_TextColored(ctx, COL_WARN, e.rec.name .. ": the child stopped answering (closed or crashed). Relaunch it, or Reattach to take the saved file back.")
  end
  if d.launch_log then r.ImGui_TextColored(ctx, COL_DIM, "launch.log: " .. d.launch_log) end
  if d.helper_log then r.ImGui_TextColored(ctx, COL_BAD, "helper.log: " .. d.helper_log) end
  if hs == "no_helper" or hs == "lost" then
    r.ImGui_PushID(ctx, "diag" .. e.rec.id)
    if self:btn("Copy launch command", "Paste it into Terminal to see exactly what happens.") then
      if r.ImGui_SetClipboardText then r.ImGui_SetClipboardText(ctx, A:launch_command(e.rec.id) or "") end
    end
    r.ImGui_PopID(ctx)
  end
end

function UI:draw_actions(e)
  local A, ctx = self.A, self.ctx
  local rec, id = e.rec, e.rec.id
  local busy = A.pending ~= nil or A.waiting[id] ~= nil
  if rec.state == "attached" then
    if self:btn("Sync", "Compare the tracks here with the child file and merge both ways.", busy) then A:sync(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Detach", "Move the tracks out into their own REAPER instance (its own audio device and transport).", busy) then A:detach(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Detach (keep shadow)", "Same, but keep muted copies here. Edits made on both sides are merged on reattach.", busy) then A:detach(id, { shadow = true }) end
  else
    local hs = health_of(A, e)
    local running = hs == "ok" or hs == "stale"
    local follow = A:following(e)
    if self:btn("Launch", "Start the child REAPER instance.", busy or running) then A:launch(id) end
    r.ImGui_SameLine(ctx)
    local ch, on = r.ImGui_Checkbox(ctx, "Follow", follow)
    if ch then A:set_follow(id, on) end
    self:tip("The child plays, stops and seeks with this project's transport (its start offset is taken into account). The number in the Child REAPER column is how far ahead (+) or behind (-) it is.")
    r.ImGui_SameLine(ctx)
    local manual_off = busy or not running or follow
    local why = follow and "Switch Follow off to control the child by hand." or nil
    if self:btn("Play", why, manual_off) then A:command(id, "play") end
    r.ImGui_SameLine(ctx)
    if self:btn("Stop", why, manual_off) then A:command(id, "stop") end
    r.ImGui_SameLine(ctx)
    if self:btn("Go to cursor", "Move the child's cursor to this project's edit cursor (offsets taken into account).", busy or not running) then A:locate_to_cursor(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Save", "Ask the child to save its project.", busy or not running) then A:command(id, "save") end
    r.ImGui_SameLine(ctx)
    if self:btn("Reattach", "Ask the child to save and close, then merge its tracks back in here.", busy) then A:reattach(id) end
    r.ImGui_SameLine(ctx)
    if self:btn("Reattach anyway", "Merge the child file as it is on disk now, even if the child is still running.", busy) then A:finish_reattach(id, true) end
  end
  r.ImGui_SameLine(ctx)
  if self:btn("Unlink", "Forget this PROJECT here. Files stay on disk.", busy) then A:forget(id) end
end

function UI:draw_plan(e)
  local A, ctx = self.A, self.ctx
  local plan = A.plans[e.rec.id]
  if not plan or #plan == 0 then return end
  for _, p in ipairs(plan) do
    r.ImGui_TextColored(ctx, COL_WARN, string.format("%s: %s", e.rec.name, p.why))
    if p.action:match("^finish_or_rollback") then
      r.ImGui_SameLine(ctx)
      r.ImGui_PushID(ctx, "fin" .. e.rec.id)
      if self:btn("Finish it", "Redo the interrupted operation (safe to repeat).") then A:finish_interrupted(e.rec.id) end
      r.ImGui_PopID(ctx)
    end
  end
end

function UI:draw_pending()
  local A, ctx = self.A, self.ctx
  local p = A.pending
  if not p then return end
  local res = p.b.res
  self:heading("Conflicts: " .. #res.conflicts .. " (nothing has been changed yet)")
  r.ImGui_TextWrapped(ctx, "Both the tracks here and the child file changed the same thing. Choose a side for each; everything else merges automatically.")
  if r.ImGui_Button(ctx, "All: this project") then A:choose_all("parent") end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "All: child file") then A:choose_all("child") end
  for _, cf in ipairs(res.conflicts) do
    r.ImGui_PushID(ctx, "cf" .. cf.n)
    local label = Merge.describe(res, cf)
    if cf.kind == "delete_edit" then
      local other = (cf.deleted_side == "parent") and "child file" or "this project"
      if self:btn((cf.choice == cf.deleted_side) and "[delete]" or "delete", "Delete it") then A:choose(cf.n, cf.deleted_side) end
      r.ImGui_SameLine(ctx)
      if self:btn((cf.choice ~= cf.deleted_side) and "[keep]" or "keep", "Keep it (" .. other .. " still has it)") then A:choose(cf.n, cf.deleted_side == "parent" and "child" or "parent") end
    else
      if self:btn(cf.choice == "parent" and "[this project]" or "this project") then A:choose(cf.n, "parent") end
      r.ImGui_SameLine(ctx)
      if self:btn(cf.choice == "child" and "[child file]" or "child file") then A:choose(cf.n, "child") end
    end
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, label)
    r.ImGui_PopID(ctx)
  end
  r.ImGui_Spacing(ctx)
  if r.ImGui_Button(ctx, "Apply") then A:apply_pending() end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, "Cancel") then A:cancel_pending() end
end

function UI:draw_settings()
  local A, ctx = self.A, self.ctx
  if not r.ImGui_CollapsingHeader(ctx, "Settings") then return end
  r.ImGui_Text(ctx, "When both sides changed the same thing:")
  for _, pol in ipairs({ "ask", "parent", "child" }) do
    r.ImGui_SameLine(ctx)
    local label = (A.cfg.policy == pol) and ("[" .. pol .. "]") or pol
    if r.ImGui_SmallButton(ctx, label .. "##pol" .. pol) then A.cfg.policy = pol; A:save() end
  end
  local ch, v = r.ImGui_Checkbox(ctx, "Give each child its own REAPER config (experimental)", A.cfg.own_config)
  if ch then A.cfg.own_config = v; A:save() end
  self:tip("Off by default. The child gets its own copy of reaper.ini (so it can use another audio device); your license, scripts, plugins and actions are linked in from the normal REAPER folder. Changes made in the child window to other shared files are shared too.")
  self.script_buf = self.script_buf or A.cfg.child_script or ""
  local ch2, s = r.ImGui_InputText(ctx, "Child helper script##script", self.script_buf)
  if ch2 then self.script_buf = s; A.cfg.child_script = s; A:save() end
  if A.cfg.child_script == "" then r.ImGui_TextColored(ctx, COL_WARN, "No helper script set: children will run but cannot be controlled or monitored.") end
end

function UI:draw_policy()
  local ctx = self.ctx
  if not r.ImGui_CollapsingHeader(ctx, "What happens to project-level features on attach") then return end
  for _, row in ipairs(X.POLICY) do
    local col = (row[3] == "done" or row[3] == "glue") and COL_OK or (row[3] == "ignore" and COL_DIM or COL_WARN)
    r.ImGui_TextColored(ctx, col, string.format("%-30s %s", row[1], row[2]))
  end
end

function UI:draw()
  local A, ctx = self.A, self.ctx
  self:draw_top()
  self:draw_projects()
  self:draw_pending()
  r.ImGui_Spacing(ctx)
  if A.err then r.ImGui_TextColored(ctx, COL_BAD, A.err)
  elseif A.msg then r.ImGui_TextColored(ctx, COL_OK, A.msg) end
  self:draw_settings()
  self:draw_policy()
end

-- pushes the accent colours; returns how many were pushed (an unknown colour name in an old ReaImGui is skipped, not fatal)
local function push_theme(ctx)
  local n = 0
  for _, c in ipairs(THEME) do
    local get = r["ImGui_Col_" .. c[1]]
    if get then r.ImGui_PushStyleColor(ctx, get(), c[2]); n = n + 1 end
  end
  return n
end

function UI:frame()
  local ctx = self.ctx
  local pushed = push_theme(ctx)
  r.ImGui_SetNextWindowSize(ctx, 900, 520, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, self.title, true)
  if visible then
    local ok, e = pcall(self.draw, self)
    if not ok then self.A.err = "UI error: " .. tostring(e) end
    r.ImGui_End(ctx)
  end
  r.ImGui_PopStyleColor(ctx, pushed)       -- also when the window is collapsed: the colour stack must stay balanced
  return open
end

return UI
