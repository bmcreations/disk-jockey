#!/usr/bin/env bash
# Agent session hooks: when the last agent session exits, shut down the simulators and emulators that were
# booted while sessions ran. Anything already running when the first session started is left alone.
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: hooks.sh [command] [options]
  print                      print the Claude Code settings.json snippet (default)
  session-start [--guard SIZE]
                             record what's running; with --guard, print a warning when free space < SIZE
  session-end                after the last session exits, shut down simulators/emulators booted since
  status                     sessions being tracked and the baseline

Options for session-start/session-end (otherwise read from the hook's JSON on stdin):
  --session ID               session id
  --reason R                 why the session ended (clear and resume hand over to the next session)

How it decides
  - The first session to start records which simulators (xcrun simctl) and emulators (adb) are booted.
  - When the last tracked session exits, devices booted since then are shut down. Simulators keep their
    data; emulators save their quickboot state. Devices you booted yourself during that time go too.
  - If another session is still running, nothing is shut down.
  - No record (hooks added mid-session) means nothing is shut down.
EOF
}

dir="$RD_STATE/sessions"
STALE_MIN=$((48 * 60)) # sessions that never sent session-end stop counting after this
log_line() { mkdir -p "$dir" && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$dir/log"; }

cmd="${1:-print}"
[ $# -gt 0 ] && shift
# Internal: the background half of session-end.
if [ "$cmd" = _stop ]; then
  for d in "$@"; do
    case "$d" in
      sim:*) xcrun simctl shutdown "${d#sim:}" >/dev/null 2>&1 ;;
      emu:*) adb -s "${d#emu:}" emu kill >/dev/null 2>&1 ;;
    esac
  done
  exit 0
fi
sid="" reason="" guard=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) sid="$2"; shift ;;
    --reason) reason="$2"; shift ;;
    --guard) guard="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) log "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

# Hook input is JSON on stdin. No jq dependency: pull flat string fields with sed.
json=""
case "$cmd" in session-start | session-end) [ -t 0 ] || json=$(cat 2>/dev/null) ;; esac
json_field() { printf '%s' "$json" | tr -d '\n' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }
[ -n "$sid" ] || sid=$(json_field session_id)
[ -n "$reason" ] || reason=$(json_field reason)
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')

booted_devices() {
  if have xcrun; then
    xcrun simctl list devices booted 2>/dev/null | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/sim:\1/p'
  fi
  if have adb; then
    adb devices 2>/dev/null | awk '$1 ~ /^emulator-[0-9]+$/ && $2 == "device" {print "emu:" $1}'
  fi
}

# The agent process behind this hook: the nearest ancestor that isn't a shell. Recorded so a crashed
# session (no session-end) stops counting as soon as its process is gone. RD_AGENT_PID="PID NAME" overrides.
agent_pid() {
  if [ -n "${RD_AGENT_PID:-}" ]; then echo "$RD_AGENT_PID"; return; fi
  is_win && return 0 # Git Bash ps can't see native processes; fall back to age
  local p=$PPID c i=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$i" -lt 4 ]; do
    c=$(ps -o comm= -p "$p" 2>/dev/null | sed 's#.*/##; s/^-//')
    case "$c" in "" | sh | bash | zsh | dash | fish | env) ;; *) echo "$p $c"; return ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
}

session_alive() { # record-file
  local pid="" name=""
  read -r pid name <"$1" 2>/dev/null
  if [ -n "$pid" ] && [ -n "$name" ] && ! is_win; then
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##; s/^-//')" = "$name" ]
    return
  fi
  [ -z "$(find "$1" -mmin +"$STALE_MIN" 2>/dev/null)" ] # no process to check: trust it for 48h
}

prune_dead() {
  local f
  for f in "$dir/active"/*; do
    [ -f "$f" ] || continue
    session_alive "$f" || { rm -f "$f"; log_line "dropped $(basename "$f") (process gone)"; }
  done
}

active_count() { find "$dir/active" -type f 2>/dev/null | wc -l | tr -d ' '; }

case "$cmd" in
  -h | --help | help) usage ;;

  print)
    hs="$RD_DIR/hooks.sh"
    case "$hs" in *" "*) run="bash \"$hs\"" ;; *) run="bash $(tilde "$hs")" ;; esac
    cat <<EOF
Add to ~/.claude/settings.json (merge with any "hooks" you already have):

{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$run session-start --guard 20G", "timeout": 10 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$run session-end", "timeout": 15 } ] }
    ]
  }
}

SessionStart records what's running (and warns the agent when free space is under 20G).
SessionEnd shuts down simulators and emulators booted while agents worked, once the last session exits.
Other agents: call "$run session-start" and "$run session-end" with --session ID from their own hooks.
EOF
    ;;

  session-start)
    [ -n "$sid" ] || { log "session-start: no session id (pass --session ID or hook JSON on stdin)"; exit 0; }
    mkdir -p "$dir/active"
    prune_dead
    handed=0
    # /clear and resume end one session and start another right away: carry the record over.
    if [ -f "$dir/handoff" ] && [ -z "$(find "$dir/handoff" -mmin +5 2>/dev/null)" ]; then
      old=$(cat "$dir/handoff")
      rm -f "$dir/active/$old" "$dir/handoff"
      handed=1
    fi
    rm -f "$dir/handoff"
    if [ "$handed" = 0 ] && [ "$(active_count)" = 0 ]; then
      booted_devices >"$dir/baseline"
      log_line "baseline: $(tr '\n' ' ' <"$dir/baseline")"
    fi
    agent_pid >"$dir/active/$sid"
    log_line "start $sid${reason:+ ($reason)}"
    [ -n "$guard" ] && bash "$RD_DIR/disk-guard.sh" "$guard"
    exit 0
    ;;

  session-end)
    [ -n "$sid" ] || { log "session-end: no session id"; exit 0; }
    [ -d "$dir" ] || exit 0
    rm -f "$dir/active/$sid"
    case "$reason" in
      clear | resume)
        echo "$sid" >"$dir/handoff"
        log_line "end $sid ($reason): handing over"
        exit 0
        ;;
    esac
    prune_dead
    n=$(active_count)
    if [ "$n" != 0 ]; then
      log_line "end $sid${reason:+ ($reason)}: $n other session(s) running, leaving devices"
      exit 0
    fi
    if [ ! -f "$dir/baseline" ]; then
      log_line "end $sid: no baseline recorded, leaving devices"
      exit 0
    fi
    stop=$(booted_devices | grep -vxF -f "$dir/baseline")
    rm -f "$dir/baseline"
    if [ -z "$stop" ]; then
      log_line "end $sid: nothing booted during sessions"
      exit 0
    fi
    log_line "end $sid: shutting down $(printf '%s ' $stop)"
    # shellcheck disable=SC2086  # one device id per word
    if [ "${RD_HOOK_SYNC:-}" = 1 ]; then
      bash "$RD_DIR/hooks.sh" _stop $stop
    else
      # Shutting down takes seconds per device; don't hold up the agent's exit.
      nohup bash "$RD_DIR/hooks.sh" _stop $stop >/dev/null 2>&1 &
    fi
    exit 0
    ;;

  status)
    prune_dead 2>/dev/null
    echo "Tracked sessions: $(active_count)"
    for f in "$dir/active"/*; do [ -f "$f" ] && echo "  $(basename "$f")  $(cat "$f")"; done
    if [ -f "$dir/baseline" ]; then
      echo "Running before the first session (left alone): $(tr '\n' ' ' <"$dir/baseline")"
    else
      echo "No baseline recorded."
    fi
    echo "Booted now: $(booted_devices | tr '\n' ' ')"
    [ -f "$dir/log" ] && { echo "Recent:"; tail -n 5 "$dir/log" | sed 's/^/  /'; }
    ;;

  *) log "unknown command: $cmd"; usage >&2; exit 2 ;;
esac
