package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Rpp = require("NPRpp")
local X = require("NPXform")
local Snap = require("NPSnap")
local Merge = require("NPMerge")
local F = require("fixture")

local G = { drums = "{AAAAAAAA-0000-0000-0000-00000000000A}", kick = "{AAAAAAAA-0000-0000-0000-00000000000B}",
            snare = "{AAAAAAAA-0000-0000-0000-00000000000C}", bass = "{AAAAAAAA-0000-0000-0000-00000000000D}",
            i_kick1 = "{BBBBBBBB-0000-0000-0000-000000000001}", i_kick2 = "{BBBBBBBB-0000-0000-0000-000000000002}",
            i_snare = "{BBBBBBBB-0000-0000-0000-000000000003}", i_midi = "{BBBBBBBB-0000-0000-0000-000000000004}",
            m1 = "{11111111-0000-0000-0000-000000000001}", m2 = "{11111111-0000-0000-0000-000000000002}" }

local function view_of(text) return assert(X.read_project(text)) end
local function model_of(text) return Snap.build(view_of(text)) end

-- what the parent holds: child content pushed through forward, edited in parent space, pulled back through backward
local function parent_side(text, edit)
  local view = view_of(text)
  local ctx = { offset = 10, projoffs = view.projoffs, media_dir = "/proj/child", tempo = view.tempo }
  local pseudo = Rpp.clone(view.master)
  X.forward(pseudo, ctx)
  local folder = X.make_folder("{FFFFFFFF-0000-0000-0000-000000000000}", "PROJECT", pseudo)
  for _, t in ipairs(view.tracks) do X.forward(t, ctx) end
  local markers = X.shift_markers(view.markers, ctx.offset + ctx.projoffs)
  local P = { tracks = view.tracks, folder = folder, markers = markers, ctx = ctx }
  if edit then edit(P) end
  for _, t in ipairs(P.tracks) do X.backward(t, ctx) end
  return Snap.build({ tracks = P.tracks, master = X.pseudo_from_folder(P.folder, ctx),
                      markers = X.shift_markers(P.markers, -(ctx.offset + ctx.projoffs)) })
end

local function find_track(P, guid) for _, t in ipairs(P.tracks) do if t.args[1] == guid then return t end end end
local function find_item(P, iguid)
  for _, t in ipairs(P.tracks) do
    for _, it in ipairs(Rpp.blocks(t, "ITEM")) do
      if Rpp.tok(Rpp.leaf(it, "IGUID"))[2] == iguid then return it, t end
    end
  end
end
local function render_texts(model) local r = Snap.render(model); local out = {} for i, t in ipairs(r.tracks) do out[i] = Rpp.serialize(t) end return out, r end

--------------------------------------------------------------------------------
-- 1. snapshot / render is lossless
--------------------------------------------------------------------------------
local base_text = F.child_rpp()
local base = model_of(base_text)
local orig = view_of(base_text)
local texts = render_texts(base)
T.eq(#texts, 4, "render gives 4 tracks")
for i = 1, 4 do T.eq(texts[i], Rpp.serialize(orig.tracks[i]), "track " .. i .. " renders identically to the source") end
T.eq(base.tracks[G.kick].vals["@parent"], G.drums, "Kick is inside Drums")
T.eq(base.tracks[G.snare].vals["@parent"], G.drums, "Snare is inside Drums")
T.eq(base.tracks[G.bass].vals["@parent"], "", "Bass is top level")
T.eq(base.items[G.i_kick1].vals["@track"], G.kick, "item knows its track")
T.ok(base.tracks[G.bass].vals["AUXRECV:" .. G.kick], "send keyed by source track guid, not index")

-- the forward/backward pipeline with no edits is invisible
local same = parent_side(base_text)
local res0 = Merge.run(base, same, model_of(base_text))
T.eq(#res0.conflicts, 0, "no edits: no conflicts")
local t0 = render_texts(res0.model)
for i = 1, 4 do T.eq(t0[i], Rpp.serialize(orig.tracks[i]), "no edits: track " .. i .. " unchanged after fw/bw + merge") end
T.eq(#res0.log, 0, "no edits: empty log")

--------------------------------------------------------------------------------
-- 2. non-overlapping edits on both sides are combined
--------------------------------------------------------------------------------
local P2 = parent_side(base_text, function(P)
  local it = find_item(P, G.i_kick1)
  Rpp.set_leaf(it, "POSITION", 12.5)      -- parent space: was 9.5 -> child space 2.5
end)
local child_text = base_text:gsub("NAME Snare", "NAME Snare-renamed")
local res2 = Merge.run(base, P2, model_of(child_text))
T.eq(#res2.conflicts, 0, "disjoint edits: no conflicts")
local r2 = Snap.render(res2.model)
T.ok(Rpp.serialize(r2.tracks[3]):find("NAME Snare-renamed", 1, true), "child rename arrives")
local k = find_item({ tracks = r2.tracks }, G.i_kick1)
T.eq(Rpp.tok(Rpp.leaf(k, "POSITION"))[2], "4.5", "parent move arrives, in child space (12.5 - 8)")
local s2 = Merge.summary(res2)
T.eq(s2.child_change, 1, "log: 1 child change")
T.eq(s2.parent_change, 1, "log: 1 parent change")

--------------------------------------------------------------------------------
-- 3. same field, different values -> conflict, choosable
--------------------------------------------------------------------------------
local P3 = parent_side(base_text, function(P) Rpp.set_leaf(find_item(P, G.i_kick1), "POSITION", 20) end)   -- child space 12
local child3 = base_text:gsub("POSITION 1%.5", "POSITION 7")
local res3 = Merge.run(base, P3, model_of(child3))
T.eq(#res3.conflicts, 1, "same field: one conflict")
local cf = res3.conflicts[1]
T.eq(cf.kind, "field", "field conflict")
T.eq(cf.key, "POSITION", "on POSITION")
T.eq(cf.id, G.i_kick1, "on the kick item")
T.ok(Merge.describe(res3, cf):find("POSITION"), "describe mentions the key")
local function kick_pos(res) local k = find_item({ tracks = Snap.render(res.model).tracks }, G.i_kick1); return Rpp.tok(Rpp.leaf(k, "POSITION"))[2] end
T.eq(kick_pos(res3), "12", "default: parent wins")
Merge.choose(res3, 1, "child")
T.eq(kick_pos(res3), "7", "choose child")
Merge.choose(res3, 1, "parent")
T.eq(kick_pos(res3), "12", "choose parent again")
T.eq(kick_pos(Merge.run(base, P3, model_of(child3), { policy = "child" })), "7", "policy=child resolves up front")
T.eq(#Merge.run(base, P3, model_of(child3), { policy = "parent" }).conflicts, 1, "policy=parent still lists it")

-- identical change on both sides is not a conflict
local P3b = parent_side(base_text, function(P) Rpp.set_leaf(find_item(P, G.i_kick1), "POSITION", 15) end)   -- child 7
T.eq(#Merge.run(base, P3b, model_of(child3)).conflicts, 0, "same change on both sides: no conflict")

--------------------------------------------------------------------------------
-- 4. additions on both sides
--------------------------------------------------------------------------------
local child4 = base_text:gsub("\n>%s*$", [[

  <TRACK {CCCCCCCC-0000-0000-0000-000000000001}
    NAME ChildNew
    ISBUS 0 0
  >
>
]])
local P4 = parent_side(base_text, function(P)
  local snare = find_track(P, G.snare)
  local it = Rpp.clone(find_item(P, G.i_snare))
  Rpp.set_leaf(it, "IGUID", "{BBBBBBBB-0000-0000-0000-0000000000FF}")
  Rpp.set_leaf(it, "POSITION", 15)
  snare.items[#snare.items + 1] = it
end)
local res4 = Merge.run(base, P4, model_of(child4))
T.eq(#res4.conflicts, 0, "additions: no conflicts")
local r4 = Snap.render(res4.model)
T.eq(#r4.tracks, 5, "child-added track present")
T.eq(r4.tracks[5].args[1], "{CCCCCCCC-0000-0000-0000-000000000001}", "at the end, where the child put it")
T.eq(#Rpp.blocks(r4.tracks[3], "ITEM"), 2, "parent-added item present")

--------------------------------------------------------------------------------
-- 5. deletions
--------------------------------------------------------------------------------
local P5 = parent_side(base_text, function(P)
  for i, t in ipairs(P.tracks) do if t.args[1] == G.bass then table.remove(P.tracks, i); break end end
end)
local res5 = Merge.run(base, P5, model_of(base_text))
T.eq(#res5.conflicts, 0, "parent deletes, child untouched: clean")
T.eq(#Snap.render(res5.model).tracks, 3, "track deleted")
T.eq(res5.model.items[G.i_midi], nil, "its items are gone too")

local child5 = base_text:gsub("NAME Bass", "NAME BassEdited")
local res5b = Merge.run(base, P5, model_of(child5))
T.eq(#res5b.conflicts, 1, "delete vs edit: conflict")
T.eq(res5b.conflicts[1].kind, "delete_edit", "kind")
T.eq(res5b.conflicts[1].deleted_side, "parent", "parent deleted")
T.eq(#Snap.render(res5b.model).tracks, 4, "default keeps the edited track")
Merge.choose(res5b, 1, "parent")
T.eq(#Snap.render(res5b.model).tracks, 3, "choosing the deleter deletes")
T.eq(res5b.model.items[G.i_midi], nil, "and its items are dropped, reported")
T.ok(#res5b.log > 0, "log has the orphan entries")
Merge.choose(res5b, 1, "child")
T.eq(#Snap.render(res5b.model).tracks, 4, "and back")
T.ok(res5b.model.items[G.i_midi] ~= nil, "items back")

--------------------------------------------------------------------------------
-- 6. order
--------------------------------------------------------------------------------
local P6 = parent_side(base_text, function(P)
  -- move Bass first
  for i, t in ipairs(P.tracks) do if t.args[1] == G.bass then table.remove(P.tracks, i); table.insert(P.tracks, 1, t); break end end
end)
local res6 = Merge.run(base, P6, model_of(child4))
T.eq(#res6.conflicts, 0, "parent reorders, child adds: no conflict")
local o6 = Snap.render(res6.model).flat
T.eq(o6[1], G.bass, "parent's order kept")
T.eq(o6[2], "{CCCCCCCC-0000-0000-0000-000000000001}", "child's new track goes after its predecessor (Bass), wherever the parent moved it")
-- only the child reorders -> child's order wins
local child6 = base_text:gsub("(  <TRACK {AAAAAAAA%-0000%-0000%-0000%-00000000000D}.-\n  >\n)", ""):gsub("(  <TRACK {AAAAAAAA%-0000%-0000%-0000%-00000000000A})", function(a) return a end)
-- both reorder differently -> conflict
local P6b = parent_side(base_text, function(P)
  for i, t in ipairs(P.tracks) do if t.args[1] == G.bass then table.remove(P.tracks, i); table.insert(P.tracks, 1, t); break end end
end)
local mc = model_of(base_text)
-- child moves Drums group to the end: order Bass first is impossible here, so build the child model by hand
local cm = Snap.build(view_of(base_text))
cm.order = { G.bass, G.drums, G.kick, G.snare }
cm.tracks[G.bass].vals["@parent"] = ""
local resc = Merge.run(base, parent_side(base_text), cm)
T.eq(#resc.conflicts, 0, "only the child reordered: no conflict")
T.eq(Snap.render(resc.model).flat[1], G.bass, "child's order wins when the parent kept the base order")

--------------------------------------------------------------------------------
-- 7. folder structure follows @parent
--------------------------------------------------------------------------------
local cm7 = Snap.build(view_of(base_text))
cm7.tracks[G.kick].vals["@parent"] = ""          -- child pulls Kick out of the Drums folder
cm7.order = { G.drums, G.snare, G.kick, G.bass }
local res7 = Merge.run(base, parent_side(base_text), cm7)
local r7 = Snap.render(res7.model)
local function isbus(t) return Rpp.leaf(t, "ISBUS").raw end
T.eq(#res7.conflicts, 0, "reparent: no conflict")
T.eq(isbus(r7.tracks[1]), "ISBUS 1 1", "Drums still a folder")
T.eq(isbus(r7.tracks[2]), "ISBUS 2 -1", "Snare now closes it")
T.eq(isbus(r7.tracks[3]), "ISBUS 0 0", "Kick is top level")
-- inside a PROJECT folder the last track also closes the PROJECT
local r7b = Snap.render(res7.model, { end_level = -1 })
T.eq(isbus(r7b.tracks[4]), "ISBUS 2 -1", "last track closes the PROJECT folder")
local r7c = Snap.render(base, { end_level = -1 })
T.eq(isbus(r7c.tracks[3]), "ISBUS 2 -1", "unchanged: Snare still just closes Drums")
T.eq(isbus(r7c.tracks[4]), "ISBUS 2 -1", "Bass closes PROJECT")

--------------------------------------------------------------------------------
-- 8. sends survive index shifts
--------------------------------------------------------------------------------
local r8 = Snap.render(base, { index_base = 20 })
T.ok(Rpp.serialize(r8.tracks[4]):find("AUXRECV 21 ", 1, true), "send re-indexed for a PROJECT that starts at track 20")
local cm8 = Snap.build(view_of(base_text))
table.insert(cm8.order, 1, "{DDDDDDDD-0000-0000-0000-000000000001}")
cm8.tracks["{DDDDDDDD-0000-0000-0000-000000000001}"] = { id = "{DDDDDDDD-0000-0000-0000-000000000001}", keys = { "NAME", "@parent" }, vals = { NAME = "NAME New", ["@parent"] = "" } }
cm8.item_order["{DDDDDDDD-0000-0000-0000-000000000001}"] = {}
local res8 = Merge.run(base, parent_side(base_text), cm8)
local r8b = Snap.render(res8.model)
T.ok(Rpp.serialize(r8b.tracks[5]):find("AUXRECV 2 ", 1, true), "a track inserted above shifts the send index, not the target")

--------------------------------------------------------------------------------
-- 9. markers and master
--------------------------------------------------------------------------------
local P9 = parent_side(base_text, function(P)
  P.markers[1].pos = P.markers[1].pos + 1                       -- move "Intro"
  Rpp.set_leaf(P.folder, "VOLPAN", 0.25, 0.1, -1, -1, 1)        -- master volume on the PROJECT track
end)
local child9 = base_text:gsub('"Verse"', '"Chorus"')
local res9 = Merge.run(base, P9, model_of(child9))
T.eq(#res9.conflicts, 0, "markers/master: no conflicts")
local r9 = Snap.render(res9.model)
T.eq(r9.markers[1].pos, 2, "marker move arrives (child space)")
T.eq(r9.markers[2].name, "Chorus", "marker rename arrives")
T.ok(r9.markers[2].isrgn and r9.markers[2].rgnend == 8, "region stays a region")
T.eq(Rpp.leaf(r9.master, "VOLPAN").raw, "VOLPAN 0.25 0.1 -1 -1 1", "master volume arrives")
-- full project text
local root, rr = Snap.to_project(res9.model, view_of(base_text).root)
local text = Rpp.serialize(root)
T.ok(text:find("MASTER_VOLUME 0.25 0.1 -1 -1 1", 1, true), "project text: master volume")
T.ok(text:find("TEMPO 100 4 4", 1, true) and text:find("PROJOFFS -2", 1, true), "project text: untouched skeleton kept")
local again = X.read_project(text)
T.eq(#again.tracks, 4, "project text re-parses with 4 tracks")
T.eq(#again.markers, 2, "and 2 markers")

--------------------------------------------------------------------------------
-- 10. item moved to another track
--------------------------------------------------------------------------------
local P10 = parent_side(base_text, function(P)
  local it, from = find_item(P, G.i_snare)
  Rpp.remove(from, it)
  local to = find_track(P, G.bass)
  to.items[#to.items + 1] = it
end)
local res10 = Merge.run(base, P10, model_of(base_text))
local r10 = Snap.render(res10.model)
T.eq(#Rpp.blocks(r10.tracks[3], "ITEM"), 0, "snare lost its item")
T.eq(#Rpp.blocks(r10.tracks[4], "ITEM"), 3, "bass gained it")

T.done("test_merge")
