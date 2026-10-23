#!/usr/bin/env bash
# Agent session hooks.
#   pre-tool       caps booted simulators/emulators across all sessions, warns agents under memory pressure
#   session-start  records what's running; warns on low disk or memory pressure
#   session-end    when the last session exits, shuts down simulators/emulators booted since the first started

# pre-tool runs before every matched tool call, so bail out before loading anything when the call
# can't be a device boot or a build.
if [ "${1:-}" = pre-tool ]; then
  json=""
  [ -t 0 ] || json=$(cat 2>/dev/null)
  case "$json" in
    *simctl*boot* | *emulator* | *boot_sim* | *build_run_sim* | *launch_sim* | *gradle* | *xcodebuild* | \
      *"swift build"* | *"swift test"* | *"cargo build"* | *build_sim* | *build_device* | *build_macos*) ;;
    *) exit 0 ;;
  esac
fi

. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: hooks.sh [command] [options]
  print                      print the Claude Code settings.json snippet (default)
  pre-tool                   PreToolUse hook: device cap and memory-pressure warning (hook JSON on stdin)
  limit [--simulators N] [--emulators N]
                             show or set the cap on booted devices across all sessions (0 = no cap;
                             defaults 2 simulators, 1 emulator)
  session-start [--guard SIZE]
                             record what's running; with --guard, warn when free space < SIZE.
                             Also warns when memory pressure is high.
  session-end                after the last session exits, shut down simulators/emulators booted since
  status                     sessions, baseline, booted devices, cap and memory pressure

Options for session-start/session-end (otherwise read from the hook's JSON on stdin):
  --session ID               session id
  --reason R                 why the session ended (clear and resume hand over to the next session)

Device cap (pre-tool)
  Booting another simulator (simctl boot, XcodeBuildMCP boot/build-and-run) or emulator (emulator -avd)
  is denied once the cap is reached. The agent is told which devices are booted so it can reuse one.
  Booting a device that's already running is always allowed.

With loupe (its server answering, token found)
  Booted devices are listed as free, claimed by this session, claimed by another session, or hands off,
  and agents are steered to free ones with the curl to claim it. Booting an already-running simulator
  that another session claimed gets a warning. Config: loupe=auto|on|off, loupe_url (default
  https://localhost:18456) in ~/.disk-jockey/config. Nothing is claimed for you.

Memory pressure (pre-tool, session-start)
  Before a build or boot, when macOS (or Linux PSI / free memory) reports pressure, the agent gets a
  note: reuse booted devices, don't start parallel builds. At most once per 10 minutes per session.

Session end
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
sid="" reason="" guard="" set_sims="" set_emus=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session) sid="$2"; shift ;;
    --reason) reason="$2"; shift ;;
    --guard) guard="$2"; shift ;;
    --simulators) set_sims="$2"; shift ;;
    --emulators) set_emus="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) log "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

# Hook input is JSON on stdin. No jq dependency: pull flat string fields with sed.
case "$cmd" in session-start | session-end) json=""; [ -t 0 ] || json=$(cat 2>/dev/null) ;; esac
json="${json:-}"
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

# "NAME (UDID)" per booted simulator.
booted_sims() {
  have xcrun || return 0
  xcrun simctl list devices booted 2>/dev/null | sed -n 's/^ *\(.*[^ ]\) *(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1 (\2)/p'
}
emulator_count() {
  if have adb; then
    adb devices 2>/dev/null | awk '$1 ~ /^emulator-[0-9]+$/ && $2 == "device" {n++} END{print n+0}'
  else
    count_procs 'qemu-system'
  fi
}
emulator_names() {
  have adb || return 0
  local s
  for s in $(adb devices 2>/dev/null | awk '$1 ~ /^emulator-[0-9]+$/ && $2 == "device" {print $1}'); do
    printf '%s (%s)\n' "$(adb -s "$s" emu avd name 2>/dev/null | head -n 1 | tr -d '\r')" "$s"
  done
}

# ---- loupe (github.com/bmc08gt/loupe): agents claim devices there. When its server answers, the cap
# steers agents to devices no other session has claimed. Config: loupe=auto|on|off (auto: only when a
# token is found), loupe_url (default https://localhost:18456). Read-only: nothing here claims anything.
LOUPE_URL_DEFAULT="https://localhost:18456"
loupe_token() {
  local f
  if [ -n "${LOUPE_TOKEN:-}" ]; then printf '%s' "$LOUPE_TOKEN"; return; fi
  for f in "$HOME/Library/Caches/loupe/token" "$HOME/.cache/loupe/token"; do
    [ -r "$f" ] && { tr -d '\r\n' <"$f"; LOUPE_TOKEN_FILE="$f"; return; }
  done
}
loupe_fetch() { # path: prints the body, fails fast (1s) when loupe isn't there
  local mode url tok
  mode=$(rd_conf loupe auto)
  [ "$mode" = off ] && return 1
  have curl || return 1
  url=$(rd_conf loupe_url "$LOUPE_URL_DEFAULT")
  tok=$(loupe_token)
  [ -n "$tok" ] || [ "$mode" = on ] || return 1
  # -k: the server's certificate names its Tailscale host, not localhost.
  if [ -n "$tok" ]; then
    curl -sfk --max-time 1 -H "Authorization: Bearer $tok" "$url$1" 2>/dev/null
  else
    curl -sfk --max-time 1 "$url$1" 2>/dev/null
  fi
}
# Loads LOUPE_MAP: "T <id> <serial|-> <handsOff 0|1>" per target and "C <target> <agent|-> <session|->" per
# claim. Returns 1 when loupe isn't reachable. Flat string fields only, so no JSON parser is needed:
# rows are split where each object starts ("id" and "target" are the first fields of their structs).
loupe_load() {
  local claims targets
  LOUPE_MAP=""
  claims=$(loupe_fetch /api/claims) || return 1
  targets=$(loupe_fetch /api/targets) || targets=""
  LOUPE_MAP=$(
    printf '%s' "$targets" | tr -d '\n' | awk '{ gsub(/\{"id":"/, "\n{\"id\":\""); print }' | awk '
      /^\{"id":"/ { id = $0; sub(/^\{"id":"/, "", id); sub(/".*/, "", id)
        serial = "-"; if (match($0, /"serial":"[^"]*"/)) serial = substr($0, RSTART + 10, RLENGTH - 11)
        print "T", id, serial, ($0 ~ /"handsOff":true/) ? 1 : 0 }'
    printf '%s' "$claims" | tr -d '\n' | awk '{ gsub(/\{"target":"/, "\n{\"target\":\""); print }' | awk '
      /^\{"target":"/ { t = $0; sub(/^\{"target":"/, "", t); sub(/".*/, "", t)
        a = "-"; if (match($0, /"agent":"[^"]*"/)) a = substr($0, RSTART + 9, RLENGTH - 10)
        ss = "-"; if (match($0, /"session":"[^"]*"/)) ss = substr($0, RSTART + 11, RLENGTH - 12)
        gsub(/ /, "_", a); gsub(/ /, "_", ss); print "C", t, a, ss }'
  )
}
# Status of one device in loupe: free, mine, handsoff or claimed:<agent>. ID is sim:<udid> or an adb serial.
loupe_status() {
  printf '%s\n' "$LOUPE_MAP" | awk -v want="$1" -v me="${sid:-}" '
    $1 == "T" && ($2 == want || $3 == want) { ids[$2] = 1; if ($4 == 1) ho = 1 }
    $1 == "C" { c[$2] = $3; cs[$2] = $4 }
    END {
      ids[want] = 1
      if (ho) { print "handsoff"; exit }
      for (i in ids) if (i in c) { if (me != "" && cs[i] == me) print "mine"; else print "claimed:" c[i]; exit }
      print "free"
    }'
}
status_words() { # status
  case "$1" in
    free) echo "free" ;;
    mine) echo "claimed by this session" ;;
    handsoff) echo "hands off (the user reserved it)" ;;
    claimed:*) echo "claimed by ${1#claimed:} in another session" ;;
  esac
}
claim_hint() { # loupe-target-id
  local url tf
  url=$(rd_conf loupe_url "$LOUPE_URL_DEFAULT")
  tf="${LOUPE_TOKEN_FILE:-}"
  if [ -n "$tf" ]; then tf="\$(cat $(tilde "$tf"))"; else tf='$LOUPE_TOKEN'; fi
  printf 'Claim the one you use in loupe so other sessions skip it: curl -sk -X POST -H "Authorization: Bearer %s" -H "X-Loupe-Agent: claude" -H "X-Loupe-Session: %s" "%s/api/claims?target=%s"' \
    "$tf" "${sid:-SESSION}" "$url" "$1"
}

# Memory pressure, cached for 30 s so a burst of tool calls doesn't re-measure each time.
pressure() {
  local f="$RD_STATE/pressure" now line
  now=$(date +%s)
  if [ -z "${RD_TEST_MEM:-}" ] && [ -f "$f" ]; then
    line=$(cat "$f" 2>/dev/null)
    case "$line" in
      *" "*) [ $((now - ${line%% *})) -lt 30 ] && { printf '%s\n' "${line#* }"; return; } ;;
    esac
  fi
  line=$(mem_state)
  [ -z "${RD_TEST_MEM:-}" ] && mkdir -p "$RD_STATE" 2>/dev/null && printf '%s %s\n' "$now" "$line" >"$f"
  printf '%s\n' "$line"
}

pressure_note() { # level pct swap_kb
  local sims emus jvm
  sims=$(booted_sims | wc -l | tr -d ' ')
  emus=$(emulator_count)
  jvm=$(($(count_procs GradleDaemon) + $(count_procs KotlinCompileDaemon)))
  printf 'disk-jockey: memory pressure is %s (%s%% free, %s swap). %s simulator(s) and %s emulator(s) booted, %s Gradle/Kotlin daemon(s). Reuse booted devices instead of booting new ones, avoid starting builds in parallel with other sessions, and if no build is running stop idle daemons (./gradlew --stop).' \
    "$1" "$2" "$(human "$3")" "$sims" "$emus" "$jvm"
}

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

# Build folders whose project is gone (deleted worktrees) are safe to delete whenever: no idle-time
# guess, no other session can need them. Runs in the background, at most every 10 minutes.
sweep_orphans() {
  local stamp="$RD_STATE/orphans.last"
  [ "$(rd_conf orphan_sweep on)" = off ] && return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ] && return 0
  touch "$stamp"
  if [ "${RD_HOOK_SYNC:-}" = 1 ]; then
    bash "$RD_DIR/clean.sh" --orphans --apply -q >>"$dir/log" 2>&1
  else
    nohup bash "$RD_DIR/clean.sh" --orphans --apply -q >>"$dir/log" 2>&1 &
  fi
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
    "PreToolUse": [
      { "matcher": "Bash|mcp__.*", "hooks": [ { "type": "command", "command": "$run pre-tool", "timeout": 5 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$run session-end", "timeout": 15 } ] }
    ]
  }
}

SessionStart records what's running and warns the agent about low disk or memory pressure.
PreToolUse caps booted devices across all sessions ($(rd_conf max_simulators 2) simulators, $(rd_conf max_emulators 1) emulator; change with
  "disk-jockey hooks limit") and warns agents before builds when memory is tight. Unrelated tool calls
  exit immediately; if the hook ever times out, the tool call goes ahead.
SessionEnd shuts down simulators and emulators booted while agents worked, once the last session exits.
Both clear build folders whose project is gone (deleted worktrees' DerivedData and XcodeBuildMCP
  workspaces) in the background, at most every 10 minutes. Off with orphan_sweep=off in ~/.disk-jockey/config.
Other agents: call "$run session-start" and "$run session-end" with --session ID from their own hooks.

Optional, so agents can acquire and release devices explicitly (exact per-session shutdown):
  claude mcp add --scope user disk-jockey -- bash $(tilde "$RD_DIR/mcp.sh")
EOF
    ;;

  limit)
    for v in "$set_sims" "$set_emus"; do
      case "$v" in '' | *[!0-9]*) [ -z "$v" ] || { log "limits are whole numbers (0 = no cap)"; exit 2; } ;; esac
    done
    [ -n "$set_sims" ] && rd_conf_set max_simulators "$set_sims"
    [ -n "$set_emus" ] && rd_conf_set max_emulators "$set_emus"
    s=$(rd_conf max_simulators 2) e=$(rd_conf max_emulators 1)
    echo "Booted device cap across all agent sessions: simulators $([ "$s" = 0 ] && echo 'no cap' || echo "$s"), emulators $([ "$e" = 0 ] && echo 'no cap' || echo "$e")."
    echo "Enforced by the PreToolUse hook (disk-jockey hooks print)."
    ;;

  pre-tool)
    tool=$(json_field tool_name)
    flat=$(printf '%s' "$json" | tr -d '\n')
    kind="" build=0
    case "$tool" in
      Bash)
        printf '%s' "$flat" | grep -Eq 'simctl[[:space:]]+boot([[:space:]]|\\|$)' && kind=sim
        printf '%s' "$flat" | grep -Eq '(^|[[:space:]/";&|(])emulator(\.exe)?[[:space:]]+(-avd[[:space:]]|@)' && kind=emu
        printf '%s' "$flat" | grep -Eq 'gradlew|(^|[[:space:]"])gradle[[:space:]]|xcodebuild|swift[[:space:]]+(build|test)|cargo[[:space:]]+build' && build=1
        ;;
      mcp__*)
        t="${tool##*__}"
        case "$t" in
          *boot_sim* | *build_run_sim* | *launch_sim* | *open_sim* | *start_sim*) kind=sim ;;
          *emulator*) case "$t" in *start* | *launch* | *boot* | *run*) kind=emu ;; esac ;;
        esac
        case "$t" in build_* | *_build | *_build_* | test_*) build=1 ;; esac
        ;;
    esac
    [ -n "$kind" ] || [ "$build" = 1 ] || exit 0

    deny=""
    if [ "$kind" = sim ]; then
      max=$(rd_conf max_simulators 2)
      booted=$(booted_sims)
      n=$(printf '%s' "$booted" | grep -c .)
      # Booting (or building onto) a simulator that's already running adds nothing.
      target=$(printf '%s' "$flat" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' | head -n 1)
      if [ -z "$target" ]; then
        target=$(printf '%s' "$flat" | sed -n 's/.*"simulatorName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$target" ] || target=$(printf '%s' "$flat" | sed -nE 's/.*simctl[[:space:]]+boot[[:space:]]+(\\"|")?([^"\\&;|]+).*/\2/p' | sed 's/[[:space:]]*$//')
      fi
      already=0 hit=""
      if [ -n "$target" ]; then
        hit=$(printf '%s\n' "$booted" | grep -iF -- "($target)" | head -n 1)
        [ -n "$hit" ] || hit=$(printf '%s\n' "$booted" | grep -F -- "$target (" | head -n 1)
        [ -n "$hit" ] && already=1
      fi
      have_loupe=0
      loupe_load && have_loupe=1
      if [ "$already" = 1 ] && [ "$have_loupe" = 1 ]; then
        # Already running, so booting is a no-op, but another session may be using it.
        u=$(printf '%s' "$hit" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\))$/\1/p')
        st=$(loupe_status "sim:$u")
        case "$st" in
          handsoff | claimed:*)
            free=$(printf '%s\n' "$booted" | while IFS= read -r b; do
              bu=$(printf '%s' "$b" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\))$/\1/p')
              [ "$(loupe_status "sim:$bu")" = free ] && echo "  - $b"
            done)
            context="disk-jockey: $hit is $(status_words "$st") (loupe). Driving it will collide with that session.${free:+ Free booted simulators:
$free}"
            ;;
        esac
      fi
      if [ "$already" = 0 ] && [ "$max" != 0 ] && [ "$n" -ge "$max" ]; then
        if [ "$have_loupe" = 1 ]; then
          free="" busy=""
          while IFS= read -r b; do
            [ -n "$b" ] || continue
            bu=$(printf '%s' "$b" | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\))$/\1/p')
            st=$(loupe_status "sim:$bu")
            case "$st" in
              free | mine) free="$free  - $b: $(status_words "$st")
" ;;
              *) busy="$busy  - $b: $(status_words "$st")
" ;;
            esac
          done <<EOF
$booted
EOF
          busy_txt=""
          [ -n "$busy" ] && busy_txt="In use by other sessions, do not drive these:
$busy"
          if [ -n "$free" ]; then
            pick=$(printf '%s' "$free" | head -n 1 | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)).*/\1/p')
            deny="disk-jockey: $n simulators are already booted across your agent sessions (cap $max). Reuse one nobody has claimed, by its UDID, instead of booting another:
$free$busy_txt$(claim_hint "sim:$pick")
If you really need a different device, ask the user to shut one down or raise the cap (disk-jockey hooks limit --simulators N)."
          else
            deny="disk-jockey: $n simulators are already booted (cap $max), and loupe shows every one in use:
$busy
Don't drive those. Ask the user to free one (xcrun simctl shutdown UDID) or raise the cap (disk-jockey hooks limit --simulators N)."
          fi
        else
          list=$(printf '%s\n' "$booted" | sed 's/^/  - /')
          deny="disk-jockey: $n simulators are already booted across your agent sessions (cap $max). Reuse one of these by its UDID instead of booting another:
$list
If you really need a different device, ask the user to shut one down (xcrun simctl shutdown UDID) or raise the cap (disk-jockey hooks limit --simulators N)."
        fi
      fi
    elif [ "$kind" = emu ]; then
      max=$(rd_conf max_emulators 1)
      n=$(emulator_count)
      avd=$(printf '%s' "$flat" | sed -nE 's/.*emulator(\.exe)?[[:space:]]+(-avd[[:space:]]+|@)([A-Za-z0-9._-]+).*/\3/p')
      already=0
      [ -n "$avd" ] && [ "$(count_procs "(-avd |@)$avd( |\$)")" -gt 0 ] && already=1
      if [ "$already" = 0 ] && [ "$max" != 0 ] && [ "$n" -ge "$max" ]; then
        if loupe_load; then
          list=$(emulator_names | while IFS= read -r e; do
            ser=$(printf '%s' "$e" | sed -n 's/.*(\(emulator-[0-9]*\))$/\1/p')
            echo "  - $e: $(status_words "$(loupe_status "$ser")")"
          done)
        else
          list=$(emulator_names | sed 's/^/  - /')
        fi
        deny="disk-jockey: $n Android emulator(s) already running across your agent sessions (cap $max). Use the running one (adb -s SERIAL) instead of starting another:
${list:-  - see adb devices}
If you really need a different one, ask the user to close one or raise the cap (disk-jockey hooks limit --emulators N)."
      fi
    fi

    context="${context:-}"
    note=""
    read -r plvl ppct pswap < <(pressure)
    if [ "${plvl:-ok}" != ok ]; then
      w="$dir/warned-${sid:-anon}"
      if [ -n "$deny" ] || [ -z "$(find "$w" -mmin -10 2>/dev/null)" ]; then
        note=$(pressure_note "$plvl" "$ppct" "${pswap:-0}")
        mkdir -p "$dir" && touch "$w"
      fi
    fi

    if [ -n "$deny" ]; then
      [ -n "$note" ] && deny="$deny

$note"
      log_line "pre-tool ${sid:-?}: denied $kind boot ($tool)"
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$(json_str "$deny")"
    elif [ -n "$note$context" ]; then
      both="$context"
      [ -n "$note" ] && both="${both:+$both

}$note"
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$(json_str "$both")"
    fi
    exit 0
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
    sweep_orphans
    # Devices acquired through the MCP server by sessions that have since died.
    reap_devices | while IFS= read -r l; do log_line "$l"; done
    [ -n "$guard" ] && bash "$RD_DIR/disk-guard.sh" "$guard"
    # Plain stdout from SessionStart becomes context the agent sees.
    read -r plvl ppct pswap < <(pressure)
    if [ "${plvl:-ok}" != ok ]; then
      pressure_note "$plvl" "$ppct" "${pswap:-0}"
      echo
      touch "$dir/warned-$sid"
    fi
    exit 0
    ;;

  session-end)
    [ -n "$sid" ] || { log "session-end: no session id"; exit 0; }
    sweep_orphans
    # Exact ownership first: devices this session acquired through the MCP server go now,
    # whatever other sessions are doing.
    case "$reason" in
      clear | resume) ;;
      *) reap_devices "$(proc_owner)" | while IFS= read -r l; do log_line "end $sid: $l"; done ;;
    esac
    [ -d "$dir" ] || exit 0
    rm -f "$dir/active/$sid" "$dir/warned-$sid"
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
    stop=$(booted_devices | grep -vxF -f "$dir/baseline" | while IFS= read -r d; do
      # A device an agent acquired through the MCP server stays while its owner lives.
      o=$(dev_owner "$d")
      if [ -n "$o" ] && owner_alive "$o"; then continue; fi
      printf '%s\n' "$d"
    done)
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
    echo "Device cap: simulators $(rd_conf max_simulators 2), emulators $(rd_conf max_emulators 1) (0 = no cap)"
    read -r plvl ppct pswap < <(mem_state)
    echo "Memory pressure: $plvl (${ppct}% free, $(human "${pswap:-0}") swap)"
    [ -f "$dir/log" ] && { echo "Recent:"; tail -n 5 "$dir/log" | sed 's/^/  /'; }
    ;;

  *) log "unknown command: $cmd"; usage >&2; exit 2 ;;
esac
