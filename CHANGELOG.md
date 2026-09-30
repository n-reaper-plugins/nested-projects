# Changelog

## 0.1.3
* **Transport following** (new): a detached child follows the parent's play / stop / seek / playrate. State-based messages
  (idempotent, a lost one is repaired by the next), latency compensation, drift correction above 60 ms, waits when the parent is
  before the child's start, re-syncs by itself when a child comes back. *Follow* checkbox per child, drift shown in ms.
  Before this version the child had only manual buttons, so it never ran in sync with the parent.
* Fix: *Go to cursor* sent the parent's cursor time unchanged; it now converts to the child's time (attach offset + start offset).
* Colour scheme: accent kept at hue 262 deg (#4700C2) but with ImGui's default saturation / brightness / translucency, much lighter.
* New `spikes/spike_5_transport_offset.lua`.

## 0.1.2
* Fix: a child started with the "own REAPER config" option came up like a fresh install on another machine (no license, no scripts).
  REAPER uses the folder of `-cfgfile` as its resource folder. The private config folder (`.link/cfg/`) now gets its own
  `reaper.ini` plus links to everything else in the real resource folder; on Windows the license and action files are copied.
* The setting was saved as ON by 0.1.0 and survived 0.1.1: it is stored under a new name now, so it starts OFF for everybody.
* Accent colour is now #4700C2 (hover/active/frame shades adjusted to match).

## 0.1.1
* Child launch made observable and more robust (a child that showed "starting..." forever on macOS):
  * the helper writes `boot.json` the moment it runs, so "REAPER opened but our script did not start" (`helper not started`) is told apart from "helper up";
  * launch output goes to `.link/launch.log`, helper errors to `.link/helper.log` (they were swallowed before) and both are shown in the window;
  * *Copy launch command* button; installer also registers `Script: NestedProjectsChild.lua` as a manual fallback inside the child;
  * REAPER executable is looked up among the usual macOS locations instead of assumed;
  * the helper keeps looking for its folder for 20 s (the project may still be loading), uses a monotonic clock, ignores an empty instance id;
  * `-cfgfile` (own config) is now opt-in, off by default.
* UI: "Make PROJECT from selected folder" on its own row; purple accent colour scheme (17 style colours, push/pop balanced also when collapsed).
* `@author _n_plugins` in both script headers.

## 0.1.0 - prototype
* Phase 0: four spike scripts + checklist (`spikes/`).
* Phase 1: attach / detach / make-project, working copy in `PROJECTS/<name>/`, base snapshot, offset + project start offset,
  timebase, media paths, MIDI tempo bake, master -> PROJECT track, markers and regions.
* Phase 2: three-way merge with per-conflict choice, dry-run (nothing written until Apply), shadow detach.
* Phase 3: launch second REAPER (own config), file mailbox (play / stop / locate / save / quit), heartbeat health.
* Phase 4 (partly): interrupted-operation journal, recovery planner (relaunch / reattach / pull / locate file), orphan detection in the child.
* Not started: Phase 5 show-control layer.
