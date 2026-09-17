#!/usr/bin/env bash
# New PascalCase folder in shared/Features OR server/Features -> full trio (no overwrite).
# Delete shared folder -> remove server Feature + Controller.
# Server folders that already existed when the watcher started are left alone (server-only).
# Names starting with _ or . are ignored.
# bash 3.2 compatible (macOS /bin/bash).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${ROOT:-}" ]; then
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

SHARED="$ROOT/src/shared/Features"
SERVER="$ROOT/src/server/Features"
CONTROLLERS="$ROOT/src/client/Client/Controllers"

KNOWN_SHARED="${KNOWN_SHARED:-}"
KNOWN_SERVER="${KNOWN_SERVER:-}"

is_feature_name() {
  local name="$1"
  [ -n "$name" ] || return 1
  case "$name" in
    .*|_*) return 1 ;;
  esac
  echo "$name" | grep -qE '^[A-Za-z][A-Za-z0-9]*$'
}

set_has() {
  local set_val="$1"
  local name="$2"
  [ -n "$set_val" ] || return 1
  printf '%s\n' "$set_val" | grep -qxF "$name"
}

set_add() {
  local set_val="$1"
  local name="$2"
  if set_has "$set_val" "$name"; then
    printf '%s' "$set_val"
  elif [ -z "$set_val" ]; then
    printf '%s' "$name"
  else
    printf '%s\n%s' "$set_val" "$name"
  fi
}

set_remove() {
  local set_val="$1"
  local name="$2"
  local out="" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$name" ] && continue
    if [ -z "$out" ]; then
      out="$line"
    else
      out="$out
$line"
    fi
  done <<EOF
$set_val
EOF
  printf '%s' "$out"
}

get_feature_names() {
  local dir="$1"
  local names="" base
  [ -d "$dir" ] || return 0
  for path in "$dir"/*; do
    [ -d "$path" ] || continue
    base="$(basename "$path")"
    if is_feature_name "$base"; then
      if [ -n "$names" ]; then
        names="$names
$base"
      else
        names="$base"
      fi
    fi
  done
  printf '%s' "$names"
}

write_if_missing() {
  local path="$1"
  local contents="$2"
  [ -e "$path" ] && return 0
  mkdir -p "$(dirname "$path")"
  printf '%s' "$contents" > "$path"
  echo "add  ${path#$ROOT/}"
}

sync_feature() {
  local name="$1"
  is_feature_name "$name" || return 0
  local shared_feat="$SHARED/$name"
  local server_feat="$SERVER/$name"
  local controller="$CONTROLLERS/${name}Controller"
  mkdir -p "$shared_feat" "$server_feat" "$controller"
  write_if_missing "$shared_feat/init.luau" "-- Config/data for ${name}. Numbers must be unique to THIS game.
local ${name} = {}

return ${name}
"
  write_if_missing "$server_feat/${name}Service.luau" "local ${name}Service = {}

function ${name}Service:Init()
end

function ${name}Service:Start()
end

return ${name}Service
"
  write_if_missing "$server_feat/init.server.luau" "local ${name}Service = require(script.${name}Service)

${name}Service:Init()
${name}Service:Start()
"
  write_if_missing "$controller/init.luau" "local ${name}Controller = {}

function ${name}Controller:Init(_janitor)
end

function ${name}Controller:Start()
end

return ${name}Controller
"
}

remove_feature_copies() {
  local name="$1"
  is_feature_name "$name" || return 0
  local server_feat="$SERVER/$name"
  local controller="$CONTROLLERS/${name}Controller"
  if [ -e "$server_feat" ]; then
    rm -rf "$server_feat"
    echo "del  src/server/Features/$name"
  fi
  if [ -e "$controller" ]; then
    rm -rf "$controller"
    echo "del  src/client/Client/Controllers/${name}Controller"
  fi
}

feature_tick() {
  local shared_now server_now name
  shared_now="$(get_feature_names "$SHARED")"
  server_now="$(get_feature_names "$SERVER")"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! set_has "$shared_now" "$name"; then
      remove_feature_copies "$name"
      KNOWN_SHARED="$(set_remove "$KNOWN_SHARED" "$name")"
      KNOWN_SERVER="$(set_remove "$KNOWN_SERVER" "$name")"
    fi
  done <<EOF
$KNOWN_SHARED
EOF

  # Re-scan after deletes so a just-removed server folder is not treated as a new feature.
  server_now="$(get_feature_names "$SERVER")"
  shared_now="$(get_feature_names "$SHARED")"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! set_has "$server_now" "$name" && ! set_has "$shared_now" "$name"; then
      KNOWN_SERVER="$(set_remove "$KNOWN_SERVER" "$name")"
    fi
  done <<EOF
$KNOWN_SERVER
EOF

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    sync_feature "$name"
    KNOWN_SHARED="$(set_add "$KNOWN_SHARED" "$name")"
    KNOWN_SERVER="$(set_add "$KNOWN_SERVER" "$name")"
  done <<EOF
$shared_now
EOF

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! set_has "$KNOWN_SERVER" "$name" && ! set_has "$KNOWN_SHARED" "$name"; then
      sync_feature "$name"
      KNOWN_SHARED="$(set_add "$KNOWN_SHARED" "$name")"
    fi
    KNOWN_SERVER="$(set_add "$KNOWN_SERVER" "$name")"
  done <<EOF
$server_now
EOF
}

mkdir -p "$SHARED" "$SERVER" "$CONTROLLERS"

if [ -z "$KNOWN_SHARED" ]; then
  KNOWN_SHARED="$(get_feature_names "$SHARED")"
fi
if [ -z "$KNOWN_SERVER" ]; then
  KNOWN_SERVER="$(get_feature_names "$SERVER")"
fi

if [ "${GENTREE_WATCH_LIB:-}" = "1" ]; then
  echo "watching $SHARED and $SERVER"
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
  fi
  exit 0
fi

echo "watching $SHARED and $SERVER  (Ctrl+C to stop)"
while true; do
  feature_tick
  sleep 1
done
