-- The shipped single files must work without src/ on the path.
package.path = "./tools/?.lua;" .. package.path
local T = require("t")
local Mock = require("mock_reaper")
local Stub = require("imgui_stub")

local function run_script(path, setup)
  package.loaded["NPRpp"] = nil
  local S = Mock.install()
  package.path = "./tools/?.lua;" .. (package.path:gsub("%./src/%?%.lua;", ""))
  for k in pairs(package.loaded) do if k:match("^NP") then package.loaded[k] = nil end end
  for k in pairs(package.preload) do package.preload[k] = nil end
  local st = Stub.install(reaper)
  reaper.ImGui_CreateContext = function() return "ctx" end
  reaper.get_action_context = function() return true, "x", 0, 0 end
  reaper.atexit = function() end
  reaper.defer = function(f) S.deferred = f end
  reaper.MB = function() end
  reaper.SetToggleCommandState = function() end
  reaper.RefreshToolbar2 = function() end
  reaper.OnPlayButton, reaper.OnStopButton, reaper.SetEditCurPos = function() end, function() end, function() end
  reaper.Main_SaveProject, reaper.IsProjectDirty, reaper.Main_OnCommand = function() end, function() return 0 end, function() end
  reaper.GetPlayState, reaper.GetPlayPosition, reaper.GetCursorPosition = function() return 0 end, function() return 0 end, function() return 0 end
  reaper.GetAudioDeviceInfo = function() return true, "Test device" end
  if setup then setup(S) end
  local f = assert(loadfile(path))
  return S, st, f
end

-- main window
do
  local S, st, f = run_script("dist/NestedProjects.lua")
  local ok, err = pcall(f)
  T.ok(ok, "main bundle runs: " .. tostring(err))
  T.ok(S.deferred, "main loop scheduled")
  local ok2, err2 = pcall(S.deferred)
  T.ok(ok2, "one frame draws: " .. tostring(err2))
end

-- child helper without any link folder: waits, then says so
do
  local warned
  local S, st, f = run_script("dist/NestedProjectsChild.lua")
  reaper.MB = function(m) warned = m end
  local ok, err = pcall(f)
  T.ok(ok, "child bundle loads: " .. tostring(err))
  S.deferred(); T.eq(warned, nil, "does not give up at once (the project may still be loading)")
  S.clock = S.clock + 25; S.deferred()
  T.ok(warned and warned:find("not a NestedProjects child"), "gives up with a message after 20 s")
end

-- child helper with the environment set, against a REAL folder: boot marker first, then status, errors into helper.log
do
  local dirp = os.tmpname(); os.remove(dirp); os.execute("mkdir -p " .. dirp)
  local S, st, f = run_script("dist/NestedProjectsChild.lua")
  local env = { NP_LINK_DIR = dirp, NP_ID = "{TEST-ID}" }
  local real = os.getenv
  os.getenv = function(k) return env[k] or real(k) end
  local ok, err = pcall(f)
  T.ok(ok, "child bundle starts with env: " .. tostring(err))
  S.deferred()
  local function slurp(n) local h = io.open(dirp .. "/" .. n, "rb"); if not h then return nil end local s = h:read("*a"); h:close(); return s end
  local boot = slurp("boot.json")
  T.ok(boot and boot:find('"via":"env"', 1, true) and boot:find("{TEST-ID}", 1, true), "boot marker written as the very first thing")
  S.clock = S.clock + 1; S.deferred()
  local status = slurp("status.json")
  T.ok(status and status:find('"state":"running"', 1, true) and status:find("Test device", 1, true), "status written")
  -- an error inside the helper is logged, not swallowed
  reaper.GetPlayState = function() error("boom") end
  S.clock = S.clock + 5; S.deferred()
  T.ok((slurp("helper.log") or ""):find("boom", 1, true), "helper errors reach helper.log")
  -- fallback: no env, marker file next to the project
  os.getenv = real
  os.execute("rm -rf " .. dirp)
end

T.done("test_bundle")
