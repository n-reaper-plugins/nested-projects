#!/usr/bin/env bash
# Run every offline test (needs a Lua 5.3+ interpreter). From the project root.
set -e
LUA="$(command -v lua5.4 || command -v lua5.3 || command -v lua)"
[ -n "$LUA" ] || { echo "no lua found"; exit 1; }
"$LUA" tools/build.lua
for t in test_rpp test_xform test_merge test_mail test_child test_sync test_reaper test_ui test_bundle; do "$LUA" tools/$t.lua; done
echo "ALL TESTS PASSED"
