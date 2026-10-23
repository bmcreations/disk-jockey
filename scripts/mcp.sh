#!/usr/bin/env bash
# disk-jockey MCP server (stdio, one JSON-RPC message per line). Bash, so each session's copy is ~3 MB.
# Gives agents a way to coordinate what the hooks and autopilot can only infer:
#   acquire_simulator / acquire_emulator  a free booted device, recorded as this session's (boots a simulator
#                                         within the cap when none is free)
#   release_device                        give it back, shutting it down
#   disk_status                           free space, memory pressure, who holds which device
#   worktree_done                         clean up worktrees whose PR merged
#   cleanup_orphans                       delete build folders whose project is gone
# Register: claude mcp add --scope user disk-jockey -- bash ~/.agents/skills/disk-jockey/scripts/mcp.sh
. "$(dirname "$0")/lib.sh"

case "${1:-}" in -h | --help)
  echo "Usage: mcp.sh   MCP server on stdin/stdout. Register with:"
  echo "  claude mcp add --scope user disk-jockey -- bash $(tilde "$RD_DIR/mcp.sh")"
  exit 0 ;;
esac

PROTO_DEFAULT="2025-06-18"
ME=$(proc_owner)

reply() { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
fail() { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$1" "$2" "$(json_str "$3")"; }
text_result() { # id text [isError]
  printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}],"isError":%s}}\n' \
    "$1" "$(json_str "$2")" "${3:-false}"
}
# Flat string field anywhere in the message (tool arguments are flat).
field() { printf '%s' "$MSG" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }
flag() { printf '%s' "$MSG" | grep -Eq "\"$1\"[[:space:]]*:[[:space:]]*$2"; }

TOOL_NAMES="acquire_simulator acquire_emulator release_device disk_status worktree_done cleanup_orphans"
TOOLS='[
{"name":"acquire_simulator","description":"Get an iOS simulator for this session instead of booting your own. Returns a booted simulator no other agent session holds (or boots one, within the machine-wide cap), and records it as yours so others skip it. Use its UDID for xcodebuild -destination id=UDID or XcodeBuildMCP simulatorId. Call release_device when done.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Device name to prefer, e.g. iPhone 16 Pro (substring match)"},"udid":{"type":"string","description":"A specific simulator UDID"}}}},
{"name":"acquire_emulator","description":"Get a running Android emulator no other agent session holds, and record it as yours. Does not boot one: if none is free it says so. Use the serial with adb -s SERIAL. Call release_device when done.","inputSchema":{"type":"object","properties":{"serial":{"type":"string","description":"A specific serial, e.g. emulator-5554"}}}},
{"name":"release_device","description":"Give back a simulator or emulator this session acquired. Shuts it down unless shutdown is false.","inputSchema":{"type":"object","properties":{"device":{"type":"string","description":"Simulator UDID or emulator serial"},"shutdown":{"type":"boolean","description":"Default true"}},"required":["device"]}},
{"name":"disk_status","description":"Free disk space, autopilot target and floor, memory pressure, and which booted simulators/emulators each agent session holds. Check before heavy builds or before booting devices.","inputSchema":{"type":"object","properties":{}}},
{"name":"worktree_done","description":"After a PR from a git worktree merges: remove that repo'\''s worktrees whose PR or branch is merged and that have nothing uncommitted. Your shell must not be inside the worktree being removed (it is reported IN-USE).","inputSchema":{"type":"object","properties":{"repo":{"type":"string","description":"Absolute path of the repo or any of its worktrees"}},"required":["repo"]}},
{"name":"cleanup_orphans","description":"Delete build folders (Xcode DerivedData, XcodeBuildMCP workspaces) whose project no longer exists. Always safe.","inputSchema":{"type":"object","properties":{}}}
]'

booted_sims() { # "UDID<TAB>NAME"
  have xcrun || return 0
  xcrun simctl list devices booted 2>/dev/null | sed -n 's/^ *\(.*[^ ]\) *(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\2\t\1/p'
}
shutdown_sims() { # "UDID<TAB>NAME" of available, shut-down iOS simulators
  have xcrun || return 0
  xcrun simctl list devices available 2>/dev/null | awk '/^-- / { ios = ($0 ~ /iOS/) } ios' |
    sed -n 's/^ *\(.*[^ ]\) *(\([0-9A-Fa-f-]\{36\}\)) (Shutdown).*/\2\t\1/p'
}
emulators() { have adb && adb devices 2>/dev/null | awk '$1 ~ /^emulator-[0-9]+$/ && $2 == "device" {print $1}'; }

# Who holds a device: "" (free), "me", or a description. Dead owners are dropped first.
holder() { # device-id (sim:UDID | emu:SERIAL)
  local o
  o=$(dev_owner "$1")
  if [ -n "$o" ] && ! owner_alive "$o"; then dev_release "$1"; o=""; fi
  if [ -n "$o" ]; then
    [ "$o" = "$ME" ] && { echo me; return; }
    echo "another session (${o#* } pid ${o%% *})"
    return
  fi
  echo ""
}

# free / yours / held by ... (a function, not a case inside $( ), which bash 3.2 can't parse)
holder_word() {
  local h
  h=$(holder "$1")
  if [ -z "$h" ]; then echo free; elif [ "$h" = me ]; then echo yours; else echo "held by $h"; fi
}

do_acquire_sim() {
  local want_udid want_name max booted n line u nm h pick="" pname=""
  want_udid=$(field udid) want_name=$(field name)
  max=$(rd_conf max_simulators 2)
  booted=$(booted_sims)
  n=$(printf '%s' "$booted" | grep -c .)
  while IFS=$'\t' read -r u nm; do
    [ -n "$u" ] || continue
    [ -n "$want_udid" ] && [ "$u" != "$want_udid" ] && continue
    [ -n "$want_name" ] && case "$nm" in (*"$want_name"*) ;; (*) continue ;; esac
    h=$(holder "sim:$u")
    if [ "$h" = me ] || [ -z "$h" ]; then pick="$u" pname="$nm"; break; fi
    [ -n "$want_udid" ] && { echo "ERR Simulator $nm ($u) is held by $h. Pick another or ask the user."; return; }
  done <<EOF
$booted
EOF
  if [ -z "$pick" ]; then
    if [ "$max" != 0 ] && [ "$n" -ge "$max" ]; then
      echo "ERR $n simulators are booted (cap $max) and none is free for you$([ -n "$want_name" ] && echo " matching '$want_name'"). Held: $(printf '%s\n' "$booted" | while IFS=$'\t' read -r u nm; do [ -n "$u" ] && printf '%s (%s): held by %s; ' "$nm" "$u" "$(holder "sim:$u")"; done)Ask the user to free one or raise the cap (disk-jockey hooks limit --simulators N)."
      return
    fi
    line=$(shutdown_sims | while IFS=$'\t' read -r u nm; do
      [ -n "$want_udid" ] && [ "$u" != "$want_udid" ] && continue
      [ -n "$want_name" ] && case "$nm" in (*"$want_name"*) ;; (*) continue ;; esac
      printf '%s\t%s\n' "$u" "$nm"
    done | head -n 1)
    [ -n "$line" ] || { echo "ERR No shut-down iOS simulator matches$([ -n "$want_name" ] && echo " '$want_name'")$([ -n "$want_udid" ] && echo " $want_udid"). Create one in Xcode or pick another name."; return; }
    pick="${line%%$'\t'*}" pname="${line#*$'\t'}"
    xcrun simctl boot "$pick" >/dev/null 2>&1 || { echo "ERR simctl could not boot $pname ($pick)."; return; }
    xcrun simctl bootstatus "$pick" -b >/dev/null 2>&1
    dev_claim "sim:$pick"
    echo "OK Booted $pname ($pick) and recorded it as yours. Use -destination id=$pick (or simulatorId $pick). Call release_device with $pick when done."
    return
  fi
  dev_claim "sim:$pick"
  echo "OK Use $pname ($pick): already booted, now recorded as yours. Use -destination id=$pick (or simulatorId $pick). Call release_device with $pick when done."
}

do_acquire_emu() {
  local want s h
  want=$(field serial)
  for s in $(emulators); do
    [ -n "$want" ] && [ "$s" != "$want" ] && continue
    h=$(holder "emu:$s")
    if [ -z "$h" ] || [ "$h" = me ]; then
      dev_claim "emu:$s"
      echo "OK Use $s (adb -s $s), recorded as yours. Call release_device with $s when done."
      return
    fi
    [ -n "$want" ] && { echo "ERR $s is held by $h."; return; }
  done
  echo "ERR No running emulator is free$([ -n "$want" ] && echo " ($want)"). Start one (emulator -avd NAME; the device cap applies) or ask the user."
}

do_release() {
  local d id o
  d=$(field device)
  [ -n "$d" ] || { echo "ERR device is required"; return; }
  case "$d" in emulator-*) id="emu:$d" ;; *) id="sim:$d" ;; esac
  o=$(dev_owner "$id")
  if [ -n "$o" ] && [ "$o" != "$ME" ] && owner_alive "$o"; then
    echo "ERR $d is held by another session (${o#* } pid ${o%% *}), not yours."
    return
  fi
  dev_release "$id"
  if flag shutdown false; then
    echo "OK Released $d (left running)."
  else
    dev_shutdown "$id"
    echo "OK Released and shut down $d."
  fi
}

do_status() {
  local free lvl pct swap u nm s out
  free=$(free_kb)
  read -r lvl pct swap < <(mem_state)
  out="Free: $(human "$free") (autopilot $(rd_conf autopilot off): target $(rd_conf autopilot_target 80G), floor $(rd_conf autopilot_floor 20G))
Memory pressure: $lvl (${pct}% free, $(human "${swap:-0}") swap)
Device cap: $(rd_conf max_simulators 2) simulators, $(rd_conf max_emulators 1) emulator"
  while IFS=$'\t' read -r u nm; do
    [ -n "$u" ] || continue
    out="$out
Simulator $nm ($u): $(holder_word "sim:$u")"
  done < <(booted_sims)
  for s in $(emulators); do
    out="$out
Emulator $s: $(holder_word "emu:$s")"
  done
  echo "OK $out"
}

do_worktree_done() {
  local repo main out
  repo=$(field repo)
  [ -d "$repo" ] || { echo "ERR repo must be an existing path"; return; }
  main=$(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$main" ] || { echo "ERR $repo is not in a git repository"; return; }
  out=$(cd "$RD_STATE" 2>/dev/null || cd /; NO_COLOR=1 bash "$RD_DIR/worktrees.sh" --merged --apply "$main" 2>&1)
  echo "OK $out"
}

do_orphans() {
  local out
  out=$(NO_COLOR=1 bash "$RD_DIR/clean.sh" --orphans --apply 2>&1 | tail -n 15)
  echo "OK $out"
}

mkdir -p "$RD_STATE" 2>/dev/null
while IFS= read -r MSG || [ -n "$MSG" ]; do
  [ -n "$MSG" ] || continue
  method=$(field method)
  # The envelope's id: the first "id" key (tool arguments never use that name).
  id=$(printf '%s' "$MSG" | awk '{ i = index($0, "\"id\""); if (!i) exit; s = substr($0, i + 4); sub(/^[[:space:]]*:[[:space:]]*/, "", s);
    if (substr(s, 1, 1) == "\"") { match(s, /^"[^"]*"/); print substr(s, RSTART, RLENGTH) } else { match(s, /^-?[0-9]+/); print substr(s, RSTART, RLENGTH) } }')
  case "$method" in
    initialize)
      proto=$(field protocolVersion)
      reply "$id" "{\"protocolVersion\":\"${proto:-$PROTO_DEFAULT}\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"disk-jockey\",\"version\":\"$RD_VERSION\"},\"instructions\":\"$(json_str "Coordinate simulators and emulators across agent sessions: acquire_simulator before booting one, release_device when done. After your PR merges, worktree_done. Check disk_status before heavy builds.")\"}"
      ;;
    notifications/* | "") ;; # notifications get no reply
    ping) reply "$id" "{}" ;;
    tools/list) reply "$id" "{\"tools\":$(printf '%s' "$TOOLS" | tr -d '\n')}" ;;
    tools/call)
      tool=$(field name)
      # "name" may also be an argument (acquire_simulator's); the tool name comes first in params.
      tool=$(printf '%s' "$MSG" | sed -n 's/.*"params"[[:space:]]*:[[:space:]]*{[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      if [ -z "$tool" ]; then
        for t in $TOOL_NAMES; do
          printf '%s' "$MSG" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$t\"" && { tool="$t"; break; }
        done
      fi
      # Drop the tool name so field name finds the argument.
      MSG=$(printf '%s' "$MSG" | sed "s/\"name\"[[:space:]]*:[[:space:]]*\"$tool\"//")
      case "$tool" in
        "acquire_simulator") r=$(do_acquire_sim) ;;
        "acquire_emulator") r=$(do_acquire_emu) ;;
        "release_device") r=$(do_release) ;;
        "disk_status") r=$(do_status) ;;
        "worktree_done") r=$(do_worktree_done) ;;
        "cleanup_orphans") r=$(do_orphans) ;;
        *) fail "$id" -32602 "unknown tool: $tool"; continue ;;
      esac
      case "$r" in
        OK\ *) text_result "$id" "${r#OK }" false ;;
        *) text_result "$id" "${r#ERR }" true ;;
      esac
      ;;
    *) [ -n "$id" ] && fail "$id" -32601 "method not found: $method" ;;
  esac
done
