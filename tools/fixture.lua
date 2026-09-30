-- Sample projects for the offline tests. Structure is written from memory of the .rpp format; the real thing
-- is checked in the Phase 0 spikes (spikes/spike_rpp_dump.lua).
local F = {}

function F.child_rpp(opts)
  opts = opts or {}
  local kick_pos = opts.kick_pos or "1.5"
  return string.format([[
<REAPER_PROJECT 0.1 "7.0/macOS-arm64" 1700000000
  RIPPLE 0 0
  SAMPLERATE 48000 0 0
  TEMPO 100 4 4
  PROJOFFS -2 0 0
  MASTER_VOLUME 0.5 0.1 -1 -1 1
  <MASTERFXLIST
    <FXCHAIN
      SHOW 0
      <VST "VST: ReaComp (Cockos)" reacomp.vst 0 "" 1919247213 ""
        bWNvcuhpc3M=
      >
    >
  >
  <VOLENV2
    ACT 1 -1
    PT 0 1 0
    PT 10 0.5 0
  >
  <TEMPOENVEX
    ACT 1 -1
    PT 0 100 1 0
    PT 20 140 1 0
  >
  MARKER 1 1 "Intro" 0 0 1 B {11111111-0000-0000-0000-000000000001} 0
  MARKER 2 4 "Verse" 1 0 1 R {11111111-0000-0000-0000-000000000002} 0
  MARKER 2 8 "" 1 0 1 R {11111111-0000-0000-0000-000000000002} 0
  <TRACK {AAAAAAAA-0000-0000-0000-00000000000A}
    NAME Drums
    BEAT -1
    ISBUS 1 1
    VOLPAN 1 0 -1 -1 1
  >
  <TRACK {AAAAAAAA-0000-0000-0000-00000000000B}
    NAME Kick
    BEAT 1
    ISBUS 0 0
    VOLPAN 1 0 -1 -1 1
    <VOLENV2
      ACT 1 -1
      PT 2 1 0
      PT 4 0.8 0
    >
    <ITEM
      POSITION %s
      LENGTH 2
      IGUID {BBBBBBBB-0000-0000-0000-000000000001}
      NAME kick.wav
      BEAT 1
      <SOURCE WAVE
        FILE "audio/kick.wav"
      >
    >
    <ITEM
      POSITION 5
      LENGTH 2
      IGUID {BBBBBBBB-0000-0000-0000-000000000002}
      NAME kick.wav
      <SOURCE WAVE
        FILE "/abs/elsewhere/kick2.wav"
      >
    >
  >
  <TRACK {AAAAAAAA-0000-0000-0000-00000000000C}
    NAME Snare
    ISBUS 2 -1
    VOLPAN 0.8 0 -1 -1 1
    <ITEM
      POSITION 3
      LENGTH 1
      IGUID {BBBBBBBB-0000-0000-0000-000000000003}
      <SOURCE WAVE
        FILE "audio/snare.wav"
      >
    >
  >
  <TRACK {AAAAAAAA-0000-0000-0000-00000000000D}
    NAME Bass
    ISBUS 0 0
    VOLPAN 1 0 -1 -1 1
    AUXRECV 1 0 1 0 0 0 0 0 -1 0 -1 ""
    <ITEM
      POSITION 25
      LENGTH 4
      IGUID {BBBBBBBB-0000-0000-0000-000000000004}
      <SOURCE MIDI
        HASDATA 1 960 QN
        E 0 90 3c 60
      >
    >
    <ITEM
      POSITION 1
      LENGTH 2
      IGUID {BBBBBBBB-0000-0000-0000-000000000005}
      <SOURCE MIDI
        HASDATA 1 960 QN
        IGNTEMPO 1 90 3 4
        E 0 90 3c 60
      >
    >
  >
>
]], kick_pos)
end

return F
