package.path = "./src/?.lua;./tools/?.lua;" .. package.path
local T = require("t")
local Rpp = require("NPRpp")

local txt = [[
<REAPER_PROJECT 0.1 "7.0/macOS-arm64" 1700000000
  RIPPLE 0 0
  TEMPO 120 4 4
  <NOTES 0 2
    |hello > world
    |second line
  >
  <TRACK {AAAA-1}
    NAME "My Track"
    ISBUS 1 1
    <FXCHAIN
      SHOW 0
      <VST "VST: Foo (Bar)" foo.vst 0 "" 1234<00> ""
        AAECAwQFBgc=
        AAAA
      >
    >
    <ITEM
      POSITION 1.5
      <SOURCE WAVE
        FILE "a b.wav"
      >
    >
  >
>
]]

local root = assert(Rpp.parse(txt))
T.eq(root.name, "REAPER_PROJECT", "root name")
T.eq(root.args[2], "7.0/macOS-arm64", "quoted arg")
local tr = Rpp.block(root, "TRACK")
T.eq(tr.args[1], "{AAAA-1}", "track guid")
T.eq(Rpp.tok(Rpp.leaf(tr, "NAME"))[2], "My Track", "quoted leaf token")
local notes = Rpp.block(root, "NOTES")
T.eq(#notes.items, 2, "notes lines not mistaken for close")
local vst = Rpp.block(Rpp.block(tr, "FXCHAIN"), "VST")
T.eq(#vst.items, 2, "base64 lines kept")
local s1 = Rpp.serialize(root)
local s2 = Rpp.serialize(Rpp.parse(s1))
T.eq(s1, s2, "serialize is stable")
T.ok(s1:find("|hello > world", 1, true), "notes text intact")
T.ok(s1:find("AAECAwQFBgc=", 1, true), "base64 intact")

T.eq(Rpp.quote("a b"), '"a b"', "quote space")
T.eq(Rpp.quote('say "x"'), "'say \"x\"'", "quote dq")
T.eq(Rpp.quote(""), '""', "quote empty")
T.eq(Rpp.quote("{G}"), "{G}", "guid bare")
T.eq(Rpp.num(1.5), "1.5", "num")
T.eq(Rpp.num(3), "3", "int num")
T.eq(Rpp.new_leaf("NAME", "x y").raw, 'NAME "x y"', "new_leaf")

T.eq(Rpp.parse("<A\r\n  B 1\r\n>\r\n").items[1].raw, "B 1", "crlf")

Rpp.set_leaf(tr, "NAME", "Renamed")
T.eq(Rpp.tok(Rpp.leaf(tr, "NAME"))[2], "Renamed", "set_leaf replace")
local c = Rpp.clone(tr)
Rpp.set_leaf(c, "NAME", "Clone")
T.eq(Rpp.tok(Rpp.leaf(tr, "NAME"))[2], "Renamed", "clone independent")
T.eq(Rpp.normpath("/a/b/../c/./d"), "/a/c/d", "normpath")
T.eq(Rpp.dirname("/a/b/c.rpp"), "/a/b", "dirname")
T.eq(Rpp.join("/a", "b"), "/a/b", "join")
T.ok(Rpp.is_abs("/x") and Rpp.is_abs("C:\\x") and not Rpp.is_abs("x/y"), "is_abs")
local sk = Rpp.serialize(Rpp.skeleton())
T.ok(sk:find("TEMPO 120 4 4", 1, true) and Rpp.parse(sk), "skeleton parses")
T.done("test_rpp")
