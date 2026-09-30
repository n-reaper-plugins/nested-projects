# Phase 0: things only REAPER can answer

Everything else is tested offline (`tools/run_tests.sh`, 368 checks). These four scripts check the guesses that the
offline mock cannot. Run each one from **Actions > Show action list > New action > Load ReaScript...**, then paste
the console output (View > Show console output... or the auto-opened console) back to me.

The scripts need the `src/` folder next to `spikes/` (they load `NPRpp.lua`).

| # | Script | Open the project / select | Question it answers |
|---|--------|---------------------------|---------------------|
| 1 | `spike_1_rpp_dump.lua` | a **saved** project that has tempo changes, markers/regions, master FX, a folder, a send, a MIDI item | Are the keys I assumed real? (`MARKER`, `PROJOFFS`, `MASTERFXLIST`, `ISBUS a b`, `AUXRECV`, `IGNTEMPO`, `BEAT`, `IGUID`, master envelopes) |
| 2 | `spike_2_chunk_roundtrip.lua` | **one track** with items, FX, a send | Does `SetTrackStateChunk` keep GUIDs? Does it wipe `P_EXT`? Does `ISBUS` in a chunk set the folder depth? Is the chunk read back identical? |
| 3 | `spike_3_launch.lua` | anything (macOS) | **Run it twice: without, then with `-cfgfile`.** Does `-newinst <rpp> <script>` open a second REAPER that **runs the script** and sees `NP_LINK_DIR`? Which of the two variants fails? Can the instance use another audio device? |
| 4 | `spike_4_api_probe.lua` | anything | Which API functions exist; what `AddProjectMarker2` returns for a wanted number |
| 5 | `spike_5_transport_offset.lua` | a project with **Project start time = -2 s** (Project settings). Part B: run it in the parent **and** in a child within a few seconds of each other | Do API times include the project start offset (transport sync assumes they do not)? Is `time_precise()` one clock shared by both REAPERs (latency compensation assumes it is; if not it switches itself off)? |

## What I will change depending on the answers

* **Spike 1** wrong about a key → adjust `NPXform` / `NPSnap` (one place each). Unknown keys are already preserved verbatim.
* **Spike 2** says `P_EXT` survives → I can drop the "put the record back" step. Says the GUID is regenerated → I switch
  to matching by `P_EXT`-stored ids. Says `ISBUS` does not set the depth → nothing changes (the glue already sets `I_FOLDERDEPTH` itself).
* **Spike 3** says the script argument is not run → the child helper is started another way (startup script that reads
  `.link/child.json`, which is already written as a fallback). Says two instances fight over the audio device → the
  "own config" copy is not enough and we need to look at aggregate devices / ReaRoute.
* **Spike 5** says the API uses displayed time → the child shift must use only the attach offset (one line in `RA.shift`). Says the clocks differ → nothing to change, the child ignores implausible timestamps, sync then relies on the 1 s drift messages only.
* **Spike 4** marker number differs → one line in `apply_markers`.

## After the spikes: a manual test of the real thing

1. Save a parent project. Run `dist/NestedProjects.lua`. **Attach** a small `.rpp` with an offset of 10 s.
   Look: folder + children, markers at +10 s, items at +10 s, sends still pointing at the right tracks.
2. Press **Sync** twice. Expect "Synced" and no visible change (REAPER adds default lines; the merge must not treat them as edits).
3. Move an item here, rename a track in `PROJECTS/<name>/<name>.rpp` with a text editor, **Sync**. Both edits present.
4. **Detach**. A second REAPER opens. Check its audio device, press Play in the parent window: child plays, parent transport does not.
5. In the child, edit something, save. In the parent press **Reattach**: the child should close by itself and the tracks come back.

6. **Transport**: with *Follow* ticked, press Play in the parent. The child should start within about a quarter of a second and the number in the
   *Child REAPER* column (ms ahead / behind) should stay within roughly +-100 ms. Try: seek while playing, stop, start the parent
   *before* the child's start (child waits, then starts by itself), untick *Follow*.
