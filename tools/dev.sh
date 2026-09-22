#!/usr/bin/env bash
# Dev loop: feature watcher (in this window), Blink, sourcemap, wally on change.
# Does not start Rojo serve. Ctrl+C stops everything this script started.
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

disconnect_template_git() {
  [ -f "$ROOT/.keep-git" ] && return 0
  [ -d "$ROOT/.git" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  local origin
  origin="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || return 0
  [ -n "$origin" ] || return 0
  echo "$origin" | grep -qiE 'github\.com[:/]Acidgorgon/MyTemplate-Legacy(\.git)?/?$' || return 0
  echo "Disconnecting from template git ($origin)"
  # Drop the remote first so a locked .git is no longer the template origin.
  git -C "$ROOT" remote remove origin >/dev/null 2>&1 || true
  # Editors may keep .git/cursor open; skip it so a partial delete cannot abort ./dev.
  find "$ROOT/.git" -mindepth 1 -maxdepth 1 ! -name cursor -exec rm -rf {} + 2>/dev/null || true
  rmdir "$ROOT/.git" 2>/dev/null || true
  if [ -f "$ROOT/.git/config" ]; then
    echo "Could not fully remove .git (files in use). Template remote is gone; ./dev will continue."
  else
    echo "This folder is no longer a git repo. Run git init and add your own remote when ready."
  fi
}

file_mtime() {
  if [ "$(uname -s)" = "Darwin" ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

find_tool() {
  command -v "$1" 2>/dev/null || true
}

wally_install() {
  local wally
  wally="$(find_tool wally)"
  if [ -z "$wally" ]; then
    echo "Missing wally. Run rokit install (see rokit.toml)." >&2
    exit 1
  fi
  echo "wally install"
  "$wally" install
}

stop_matching() {
  local pattern="$1"
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$pattern" 2>/dev/null || true
  fi
}

disconnect_template_git

if [ -d "$HOME/.rokit/bin" ]; then
  export PATH="$HOME/.rokit/bin:$PATH"
fi

WATCHER_SCRIPT="$ROOT/tools/watch-features.sh"
if [ ! -f "$WATCHER_SCRIPT" ]; then
  echo "missing $WATCHER_SCRIPT" >&2
  exit 1
fi

echo "dev root: $ROOT"

if [ ! -f "$ROOT/Packages/Janitor.lua" ]; then
  wally_install
else
  echo "Packages already present (edit wally.toml to reinstall)"
fi
last_wally="$(file_mtime "$ROOT/wally.toml")"

stop_matching "events.blink -w"
stop_matching "sourcemap default.project.json"

GENTREE_WATCH_LIB=1
# shellcheck source=watch-features.sh
. "$WATCHER_SCRIPT"

blink_pid=""
sourcemap_pid=""

cleanup() {
  if [ -n "$blink_pid" ]; then
    kill "$blink_pid" 2>/dev/null || true
  fi
  if [ -n "$sourcemap_pid" ]; then
    kill "$sourcemap_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

blink="$(find_tool blink)"
if [ -z "$blink" ]; then
  echo "blink not found, skip"
else
  "$blink" events.blink -w >/dev/null 2>&1 &
  blink_pid=$!
fi

rojo="$(find_tool rojo)"
if [ -z "$rojo" ]; then
  echo "rojo not found, skip sourcemap"
else
  "$rojo" sourcemap default.project.json -o sourcemap.json --watch >/dev/null 2>&1 &
  sourcemap_pid=$!
fi

echo "running: features + blink -w + sourcemap --watch. Ctrl+C to stop."

blink_warned=0
sourcemap_warned=0
while true; do
  feature_tick
  sleep 1
  if [ -n "$blink_pid" ] && [ "$blink_warned" -eq 0 ] && ! kill -0 "$blink_pid" 2>/dev/null; then
    blink_warned=1
    echo "blink exited"
  fi
  if [ -n "$sourcemap_pid" ] && [ "$sourcemap_warned" -eq 0 ] && ! kill -0 "$sourcemap_pid" 2>/dev/null; then
    sourcemap_warned=1
    echo "sourcemap exited"
  fi
  now="$(file_mtime "$ROOT/wally.toml")"
  if [ "$now" -gt "$last_wally" ]; then
    last_wally="$now"
    wally_install
  fi
done
