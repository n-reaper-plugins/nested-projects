#!/usr/bin/env bash
# NestedProjects installer - macOS first (bash 3.2 compatible). Also works with --portable on any OS.
#
#   ./install_mac.sh                      install into ~/Library/Application Support/REAPER
#   ./install_mac.sh --portable DIR       install into a portable REAPER folder
#   ./install_mac.sh --no-register        do not touch reaper-kb.ini (add the action by hand)
#   ./install_mac.sh --src DIR            folder containing NestedProjects.lua (default: next to this script, or ./dist)
#   ./install_mac.sh --uninstall          remove exactly what this script added
#
# Nothing here modifies your projects. reaper-kb.ini is only edited while REAPER is closed, and is backed up first.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
RES=""; SRC=""; DO_REGISTER=1; DO_UNINSTALL=0

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --portable)    [ $# -ge 2 ] || die "--portable needs a folder"; RES="$2"; shift 2 ;;
    --src)         [ $# -ge 2 ] || die "--src needs a folder"; SRC="$2"; shift 2 ;;
    --no-register) DO_REGISTER=0; shift ;;
    --uninstall)   DO_UNINSTALL=1; shift ;;
    -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

if [ -z "$RES" ]; then
  case "$(uname -s)" in
    Darwin) RES="$HOME/Library/Application Support/REAPER" ;;
    *)      RES="$HOME/.config/REAPER" ;;
  esac
fi
[ -d "$RES" ] || die "REAPER resource folder not found: $RES
Start REAPER once so it creates it, or pass --portable <folder>."

SCRIPT_DIR="$RES/Scripts/NestedProjects"
MAIN="$SCRIPT_DIR/NestedProjects.lua"
CHILD="$SCRIPT_DIR/NestedProjectsChild.lua"
KB="$RES/reaper-kb.ini"

reaper_running() {
  if command -v pgrep >/dev/null 2>&1; then pgrep -x REAPER >/dev/null 2>&1 || pgrep -x reaper >/dev/null 2>&1
  else return 0; fi
}
sha1() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else printf '%s' "$1" | sha1sum | cut -d' ' -f1; fi
}
backup_kb() { [ -f "$KB" ] || return 0; cp "$KB" "$KB.nestedprojects-backup-$(date +%Y%m%d-%H%M%S)"; }
kb_remove() {
  [ -f "$KB" ] || return 0
  grep -qF -e "$MAIN" -e "$CHILD" "$KB" 2>/dev/null || return 0
  backup_kb
  grep -vF -e "$MAIN" -e "$CHILD" "$KB" > "$KB.tmp.$$" || true
  mv "$KB.tmp.$$" "$KB"
}

if [ "$DO_UNINSTALL" = 1 ]; then
  say "Uninstalling NestedProjects from: $RES"
  if reaper_running; then warn "REAPER seems to be running. Close it first so reaper-kb.ini can be cleaned; skipping that part."
  else kb_remove; say "  removed action registration (if it existed)"; fi
  rm -f "$MAIN" "$CHILD"
  rmdir "$SCRIPT_DIR" 2>/dev/null || true
  say "Done. Your projects and the PROJECTS/ folders next to them are untouched; PROJECT tracks stay as ordinary folder tracks."
  exit 0
fi

if [ -z "$SRC" ]; then
  if   [ -f "$HERE/NestedProjects.lua" ];      then SRC="$HERE"
  elif [ -f "$HERE/dist/NestedProjects.lua" ]; then SRC="$HERE/dist"
  else die "NestedProjects.lua not found next to this script. Use --src <folder>."; fi
fi
[ -f "$SRC/NestedProjects.lua" ] && [ -f "$SRC/NestedProjectsChild.lua" ] || die "$SRC must contain NestedProjects.lua AND NestedProjectsChild.lua"

VERSION="$(sed -n 's/^-- @version[[:space:]]*//p' "$SRC/NestedProjects.lua" | head -n 1)"
say "Installing NestedProjects ${VERSION:-?} into: $RES"
mkdir -p "$SCRIPT_DIR"
cp "$SRC/NestedProjects.lua" "$MAIN"
cp "$SRC/NestedProjectsChild.lua" "$CHILD"
say "  scripts -> $SCRIPT_DIR  (keep the two files together)"

if [ "$(uname -s)" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$SCRIPT_DIR" 2>/dev/null || true
  say "  removed download quarantine flag"
fi

if ls "$RES/UserPlugins" 2>/dev/null | grep -i 'imgui' >/dev/null 2>&1; then say "  ReaImGui: found"
else
  warn "ReaImGui was not found in $RES/UserPlugins."
  say  "  The window needs it: in REAPER open Extensions > ReaPack > Browse packages, search 'ReaImGui', install, restart."
fi

REGISTERED=0
if [ "$DO_REGISTER" = 1 ]; then
  if reaper_running; then warn "REAPER seems to be running - not editing reaper-kb.ini."
  elif [ ! -f "$KB" ]; then warn "$KB does not exist yet (start and close REAPER once)."
  else
    kb_remove; backup_kb
    ID="RS$(sha1 "$MAIN")"
    printf 'SCR 4 0 %s "Script: NestedProjects.lua" "%s"\n' "$ID" "$MAIN" >> "$KB"
    CID="RS$(sha1 "$CHILD")"
    printf 'SCR 4 0 %s "Script: NestedProjectsChild.lua" "%s"\n' "$CID" "$CHILD" >> "$KB"
    REGISTERED=1
    say "  actions -> 'Script: NestedProjects.lua' and 'Script: NestedProjectsChild.lua' (backup of reaper-kb.ini kept next to it)"
    say "             the second one is only a fallback: run it inside a child REAPER whose helper did not start by itself"
  fi
fi

say ""
if [ "$REGISTERED" = 1 ]; then
  say "Next: start REAPER, Actions > Show action list, search 'NestedProjects', run 'Script: NestedProjects.lua'."
else
  say "Next: in REAPER open Actions > Show action list > New action > Load ReaScript..., choose"
  say "      $MAIN"
  say "      then run it."
fi
say "Uninstall any time with: $0 --uninstall"
