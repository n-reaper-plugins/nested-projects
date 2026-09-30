package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Rpp = require("NPRpp")
local X = require("NPXform")
local F = require("fixture")

local view = assert(X.read_project(F.child_rpp()))
T.eq(#view.tracks, 4, "4 tracks")
T.eq(view.projoffs, -2, "projoffs")
T.eq(view.tempo.bpm, 100, "tempo bpm")
T.eq(#view.tempo.pts, 2, "tempo pts")
T.eq(view.samplerate, 48000, "samplerate")
T.eq(#view.markers, 2, "marker + region")
T.ok(view.markers[2].isrgn and view.markers[2].pos == 4 and view.markers[2].rgnend == 8, "region span")
T.eq(view.markers[1].guid, "{11111111-0000-0000-0000-000000000001}", "marker guid kept")

-- tempo lookup
T.eq((X.tempo_at(view.tempo, 0)), 100, "tempo at 0")
T.eq((X.tempo_at(view.tempo, 30)), 140, "tempo after last pt")
T.eq((X.tempo_at(nil, 5)), 120, "default tempo")

-- master pseudo track
local m = view.master
T.eq(Rpp.tok(Rpp.leaf(m, "VOLPAN"))[2], "0.5", "master vol -> VOLPAN")
T.ok(Rpp.block(m, "FXCHAIN") ~= nil, "master fx chain found")
T.ok(Rpp.block(m, "VOLENV2") ~= nil, "master vol envelope found")

-- forward
local ctx = { offset = 10, projoffs = view.projoffs, media_dir = "/proj/child", tempo = view.tempo }
local kick = view.tracks[2]
local kick_before = Rpp.serialize(kick)
local st = X.forward(kick, ctx)
local items = Rpp.blocks(kick, "ITEM")
T.eq(Rpp.tok(Rpp.leaf(items[1], "POSITION"))[2], "9.5", "item shifted by offset+projoffs (10-2)")
T.eq(Rpp.tok(Rpp.leaf(items[2], "POSITION"))[2], "13", "second item shifted")
T.eq(Rpp.tok(Rpp.leaf(Rpp.block(items[1], "SOURCE"), "FILE"))[2], "/proj/child/audio/kick.wav", "relative media resolved")
T.eq(Rpp.tok(Rpp.leaf(Rpp.block(items[2], "SOURCE"), "FILE"))[2], "/abs/elsewhere/kick2.wav", "absolute media untouched")
T.eq(Rpp.tok(Rpp.leaf(kick, "BEAT"))[2], "0", "track forced to time")
T.eq(Rpp.tok(Rpp.leaf(items[1], "BEAT"))[2], "0", "beat item forced to time")
T.eq(st.beat, 1, "beat item counted")
T.eq(st.files, 1, "one file resolved")
local env = Rpp.block(kick, "VOLENV2")
local pts = Rpp.leaves(env, "PT")
T.eq(Rpp.tok(pts[1])[2], "10", "envelope point shifted")
T.eq(Rpp.tok(pts[2])[2], "12", "envelope point 2 shifted")
T.eq(Rpp.tok(pts[1])[3], "1", "envelope value untouched")

-- MIDI bake
local bass = view.tracks[4]
local bst = X.forward(bass, ctx)
local bitems = Rpp.blocks(bass, "ITEM")
local src1 = Rpp.block(bitems[1], "SOURCE")
T.eq(Rpp.leaf(src1, "IGNTEMPO").raw, "IGNTEMPO 1 140 4 4", "midi item at 25s baked at tempo 140")
T.eq(src1.items[2].key, "IGNTEMPO", "IGNTEMPO placed after HASDATA")
local src2 = Rpp.block(bitems[2], "SOURCE")
T.eq(Rpp.leaf(src2, "IGNTEMPO").raw, "IGNTEMPO 1 90 3 4", "existing ignore-tempo kept")
T.eq(bst.midi, 1, "one midi source baked")
T.eq(bst.midi_var, 0, "no tempo change inside item")

-- backward restores everything except the owned props (BEAT / IGNTEMPO)
X.backward(kick, ctx)
T.eq(Rpp.serialize(kick), kick_before, "forward+backward is an exact identity")
local bass_before_fw = nil
X.backward(bass, ctx)
T.ok(not Rpp.serialize(bass):find("IGNTEMPO 1 140", 1, true), "our own midi bake removed on the way out")
T.ok(Rpp.serialize(bass):find("IGNTEMPO 1 90 3 4", 1, true), "an original ignore-tempo is kept")
T.eq(Rpp.tok(Rpp.leaf(bitems[1], "POSITION"))[2], "25", "midi item position restored")

-- folder track from master, and back
local pseudo = Rpp.clone(view.master)
X.forward(pseudo, ctx)
local penv = Rpp.leaves(Rpp.block(pseudo, "VOLENV2"), "PT")
T.eq(Rpp.tok(penv[1])[2], "8", "master envelope shifted onto the PROJECT track")
local folder = X.make_folder("{FFFFFFFF-0000-0000-0000-000000000000}", "PROJECT: Intro", pseudo)
T.eq(Rpp.tok(Rpp.leaf(folder, "ISBUS"))[3], "1", "folder opens")
local back = X.pseudo_from_folder(folder, ctx)
T.eq(Rpp.serialize(back), Rpp.serialize(view.master), "master round-trips through the folder track")

-- apply_master into a fresh project root
local root2 = assert(Rpp.parse(Rpp.serialize(Rpp.skeleton())))
X.apply_master(root2, view.master)
T.eq(Rpp.leaf(root2, "MASTER_VOLUME").raw, "MASTER_VOLUME 0.5 0.1 -1 -1 1", "master vol written")
T.ok(Rpp.block(Rpp.block(root2, "MASTERFXLIST"), "FXCHAIN") ~= nil, "master chain written")
local again = X.master_pseudo(root2)
T.eq(Rpp.serialize(again), Rpp.serialize(view.master), "apply_master / master_pseudo round trip")

-- markers
local shifted = X.shift_markers(view.markers, 8)
T.eq(shifted[1].pos, 9, "marker shifted")
T.eq(view.markers[1].pos, 1, "original list untouched")
X.write_markers(root2, view.markers)
local rm = X.read_markers(root2)
T.eq(#rm, 2, "markers written and re-read")
T.ok(rm[2].isrgn and rm[2].rgnend == 8 and rm[2].name == "Verse", "region survives round trip")
T.eq(rm[2].guid, view.markers[2].guid, "marker guid survives")

-- ids
T.eq(X.new_guid("a"), X.new_guid("a"), "guid deterministic")
T.ok(X.new_guid("a") ~= X.new_guid("b"), "guid differs")
T.ok(X.new_guid("a"):match("^{%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x+}$"), "guid shape")

-- report
local rep = X.report(view, { samplerate = 44100 })
T.ok(#rep >= 2, "report lists sample rate + tempo env")
T.done("test_xform")
