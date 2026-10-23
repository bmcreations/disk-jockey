#!/usr/bin/env bash
# Autopilot: keeps agent-caused disk use in check without anyone running disk-jockey.
#
# A tick runs every 5 minutes from the user's own scheduler (launchd, systemd --user, Task Scheduler).
# Most ticks are one df. Every 30 minutes, or at once when free space falls under the floor, a pass runs:
#   always   build folders whose project is gone, merged worktrees, expired quarantine
#   then, only while free space is under the target, rungs from oldest to newest output:
#            tier-1 caches, build outputs of projects idle 14 days, 7 days, build caches unused for 2 days,
#            projects idle 3 days
# It never deletes tier 2 or 3, REVIEW worktrees, or anything a running process is using. When the
# rungs run out and space is still short, it says why in a notification, at most every 6 hours.
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: autopilot.sh [command] [options]
  on [--target SIZE] [--floor SIZE] [--interval MIN]
                 install the background job (defaults: keep 80G free, emergency under 20G, pass every 30 min)
  off            remove it
  status         settings, last pass, what it did
  run [--dry-run] [--emergency]
                 one pass now (what the job runs)
  tick           the job's 5-minute check: a pass when one is due or space is under the floor

Settings live in ~/.disk-jockey/config (autopilot_target, autopilot_floor, autopilot_interval,
autopilot_worktrees=on|off, autopilot_on_battery=off|on, autopilot_notify=on|off).
EOF
}

LOG="$RD_STATE/autopilot.log"
LOCK="$RD_STATE/autopilot.lock"
LABEL="dev.disk-jockey.autopilot"

target_kb() { to_kb "$(rd_conf autopilot_target 80G)"; }
floor_kb() { to_kb "$(rd_conf autopilot_floor 20G)"; }
interval_min() { rd_conf autopilot_interval 30; }
alog() { mkdir -p "$RD_STATE" && printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

# Held in quarantine, KB. Moving something there frees nothing, so the ladder counts it separately.
held_kb() {
  local d s t=0
  [ -d "$RD_QDIR" ] || { echo 0; return; }
  for d in "$RD_QDIR"/*; do
    [ -f "$d/meta" ] || continue
    s=$(q_meta "$d" kb)
    t=$((t + ${s:-0}))
  done
  echo "$t"
}

on_battery() {
  if is_mac; then
    pmset -g batt 2>/dev/null | grep -q "discharging"
  elif is_linux; then
    grep -qx Discharging /sys/class/power_supply/*/status 2>/dev/null
  else
    return 1
  fi
}

notify() { # key message: at most once per 6 hours per key
  local key="$1" msg="$2" stamp="$RD_STATE/notified.$1"
  [ "$(rd_conf autopilot_notify on)" = off ] && return 0
  [ -n "$(find "$stamp" -mmin -360 2>/dev/null)" ] && return 0
  touch "$stamp"
  alog "notify: $msg"
  if is_mac && have osascript; then
    osascript -e "display notification \"$(printf '%s' "$msg" | sed 's/["\\]/ /g')\" with title \"disk-jockey\"" >/dev/null 2>&1
  elif have notify-send; then
    notify-send "disk-jockey" "$msg" >/dev/null 2>&1
  fi
  return 0
}

# One pass at a time. A lock left by a process that died is taken over.
take_lock() {
  mkdir -p "$RD_STATE"
  if mkdir "$LOCK" 2>/dev/null; then echo $$ >"$LOCK/pid"; return 0; fi
  local p
  p=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"
}

pass() { # dry emergency
  local dry="$1" emergency="$2" free target floor held0 held1 freed apply="--apply"
  [ "$dry" = 1 ] && apply=""
  target=$(target_kb) floor=$(floor_kb)
  free=$(free_kb)
  local start_free="$free" did=""
  say() { [ "$dry" = 1 ] && echo "$*"; alog "$*"; }
  say "pass${emergency:+ (emergency)}: free $(human "$free"), target $(human "$target"), floor $(human "$floor")$([ "$dry" = 1 ] && echo ', dry run')"

  # Always: safe whatever the free space.
  bash "$RD_DIR/clean.sh" --orphans $apply -q >/dev/null 2>&1
  if [ "$(rd_conf autopilot_worktrees on)" = on ]; then
    local wargs="--merged --no-fetch"
    # Fetching every repo every half hour is noise; every 6 hours is enough to see merges.
    if [ -z "$(find "$RD_STATE/autopilot.fetched" -mmin -360 2>/dev/null)" ]; then
      wargs="--merged"
      [ "$dry" = 1 ] || touch "$RD_STATE/autopilot.fetched"
    fi
    # Explicit roots: --merged alone scopes to the repo the working directory is in (a dotfiles home?).
    local roots=()
    while IFS= read -r r; do [ -n "$r" ] && roots+=("$r"); done < <(default_roots)
    # shellcheck disable=SC2086  # flags
    [ "${#roots[@]}" -gt 0 ] && bash "$RD_DIR/worktrees.sh" $wargs $apply "${roots[@]}" </dev/null >/dev/null 2>&1
  fi
  free=$(free_kb)
  [ "$free" -gt "$start_free" ] && did="$did orphans/worktrees +$(human $((free - start_free)))"

  # Emergency with quarantine on: the undo buffer goes first, oldest first, until above the floor.
  if [ "$free" -lt "$floor" ] && [ -d "$RD_QDIR" ] && [ "$dry" = 0 ]; then
    local d
    for d in $(ls -1 "$RD_QDIR" 2>/dev/null | sort); do
      [ "$(free_kb)" -lt "$floor" ] || break
      [ -f "$RD_QDIR/$d/meta" ] && q_purge_item "$RD_QDIR/$d" && say "  purged quarantined $d (below floor)"
    done
    free=$(free_kb)
  fi

  # The ladder, oldest output first, only while short of the target.
  local rung label
  for rung in \
    "tier-1 caches|clean.sh --tier 1 -q" \
    "projects idle 14d|sweep.sh --days 14" \
    "projects idle 7d|sweep.sh --days 7" \
    "build caches unused 2d|clean.sh --tier 1 --stale-days 2 -q" \
    "projects idle 3d|sweep.sh --days 3"; do
    [ "$free" -lt "$target" ] || break
    if [ "$dry" = 0 ] && [ -z "$emergency" ] && [ "$(rd_conf autopilot_on_battery off)" = off ] && on_battery; then
      say "  on battery: rungs wait for power (free $(human "$free"))"
      break
    fi
    label="${rung%%|*}"
    held0=$(held_kb)
    # shellcheck disable=SC2086  # the rung's flags
    if [ "$dry" = 1 ]; then
      echo "  would run: $label"
      continue
    fi
    local run="${rung#*|}"
    # shellcheck disable=SC2086  # the rung's own flags, split on purpose
    bash "$RD_DIR/${run%% *}" ${run#* } --apply </dev/null >/dev/null 2>&1
    held1=$(held_kb)
    freed=$(($(free_kb) - free))
    say "  $label: freed $(human $((freed > 0 ? freed : 0)))$([ "$held1" -gt "$held0" ] && echo ", moved $(human $((held1 - held0))) to quarantine")"
    # Quarantined bytes count towards the target here, or every pass would climb the whole ladder.
    free=$(($(free_kb) + held1 - held0))
  done

  free=$(free_kb)
  say "done: free $(human "$free") (was $(human "$start_free"))"
  [ "$dry" = 1 ] && return 0
  if [ "$free" -lt "$target" ]; then
    # Out of safe rungs. Say what's left, from preflight's view.
    local why
    why=$(bash "$RD_DIR/preflight.sh" --tsv 2>/dev/null | awk -F'\t' '$1=="WARN" && $2!="free-space" {printf "%s%s %s", (n++ ? "; " : ""), $2, $3}')
    local rev
    rev=$(cd "$RD_STATE" && bash "$RD_DIR/worktrees.sh" --tsv </dev/null 2>/dev/null | awk -F'\t' '$1=="REVIEW" {k+=$2; n++} END{if (n) printf "%d REVIEW worktree(s) %d", n, k}')
    [ -n "$rev" ] && why="${why:+$why; }$(printf '%s' "$rev" | awk '{kb=$NF; $NF=""; printf "%s%.1fG", $0, kb/1048576}')"
    if [ "$free" -lt "$floor" ]; then
      notify floor "Only $(human "$free") free and nothing safe left to clear.${why:+ $why.} Run disk-jockey to review."
    else
      notify target "$(human "$free") free, under your $(human "$target") target after safe cleanup.${why:+ $why.}"
    fi
  fi
  date +%s >"$RD_STATE/autopilot.last"
}

install_job() {
  local tick="$RD_DIR/autopilot.sh"
  if is_mac; then
    case "$RD_DIR" in
      "$HOME"/Documents/* | "$HOME"/Desktop/* | "$HOME"/Downloads/* | "$HOME/Library/Mobile Documents"/*)
        log "Warning: launchd jobs can't read scripts in Documents/Desktop/Downloads/iCloud without Full Disk Access." ;;
    esac
    local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$RD_STATE"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$tick</string><string>tick</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$PATH</string></dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$RD_STATE/autopilot.out</string>
  <key>StandardErrorPath</key><string>$RD_STATE/autopilot.out</string>
  <key>LowPriorityIO</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$plist"
  elif is_win; then
    have schtasks || { log "schtasks not found."; return 1; }
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    mkdir -p "$RD_STATE"
    local runner="$RD_STATE/autopilot-run.sh"
    printf '#!/usr/bin/env bash\n"%s" tick >>"%s" 2>&1\n' "$tick" "$RD_STATE/autopilot.out" >"$runner"
    schtasks /Create /F /SC MINUTE /MO 5 /TN disk-jockey-autopilot \
      /TR "conhost.exe --headless \"$(cygpath -w "$(command -v bash)")\" -l \"$(cygpath -m "$runner")\"" >/dev/null
  else
    have systemctl || { log "systemctl not found. Add to crontab instead: */5 * * * * \"$tick\" tick"; return 1; }
    local u="$HOME/.config/systemd/user"
    mkdir -p "$u"
    printf '[Unit]\nDescription=disk-jockey autopilot\n\n[Service]\nType=oneshot\nEnvironment=PATH=%s\nExecStart=/bin/bash "%s" tick\nNice=10\nIOSchedulingClass=idle\n' "$PATH" "$tick" >"$u/disk-jockey-autopilot.service"
    printf '[Unit]\nDescription=disk-jockey autopilot every 5 minutes\n\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\n\n[Install]\nWantedBy=timers.target\n' >"$u/disk-jockey-autopilot.timer"
    systemctl --user daemon-reload && systemctl --user enable --now disk-jockey-autopilot.timer >/dev/null 2>&1
  fi
}

remove_job() {
  if is_mac; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  elif is_win; then
    MSYS_NO_PATHCONV=1 schtasks /Delete /F /TN disk-jockey-autopilot >/dev/null 2>&1
    rm -f "$RD_STATE/autopilot-run.sh"
  else
    systemctl --user disable --now disk-jockey-autopilot.timer >/dev/null 2>&1
    rm -f "$HOME/.config/systemd/user/disk-jockey-autopilot.service" "$HOME/.config/systemd/user/disk-jockey-autopilot.timer"
    systemctl --user daemon-reload >/dev/null 2>&1
  fi
  return 0
}

cmd="${1:-status}"
[ $# -gt 0 ] && shift
dry=0 emergency=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) to_kb "$2" | grep -qE '^[0-9]+$' || { log "--target: size like 80G"; exit 2; }; rd_conf_set autopilot_target "$2"; shift ;;
    --floor) to_kb "$2" | grep -qE '^[0-9]+$' || { log "--floor: size like 20G"; exit 2; }; rd_conf_set autopilot_floor "$2"; shift ;;
    --interval) case "$2" in '' | *[!0-9]*) log "--interval: minutes"; exit 2 ;; esac; rd_conf_set autopilot_interval "$2"; shift ;;
    --dry-run) dry=1 ;;
    --emergency) emergency=1 ;;
    -h | --help) usage; exit 0 ;;
    *) log "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

case "$cmd" in
  -h | --help | help) usage ;;
  on)
    [ "$(floor_kb)" -lt "$(target_kb)" ] || { log "The floor must be below the target."; exit 2; }
    rd_conf_set autopilot on
    if install_job; then
      echo "Autopilot on: keeps $(rd_conf autopilot_target 80G) free, acts at once under $(rd_conf autopilot_floor 20G), passes every $(interval_min) min."
      echo "Always clears build folders of deleted projects and merged worktrees. Never touches tier 2/3, REVIEW worktrees or anything in use."
      echo "Log: $(tilde "$LOG"). Try a dry pass: disk-jockey autopilot run --dry-run"
    else
      log "Couldn't install the background job."; exit 1
    fi
    ;;
  off)
    rd_conf_set autopilot off
    remove_job
    echo "Autopilot off."
    ;;
  status)
    st=$(rd_conf autopilot off)
    echo "Autopilot: $st (keep $(rd_conf autopilot_target 80G) free, floor $(rd_conf autopilot_floor 20G), every $(interval_min) min)"
    echo "Free now: $(human "$(free_kb)")"
    if [ -f "$RD_STATE/autopilot.last" ]; then
      echo "Last pass: $((($(date +%s) - $(cat "$RD_STATE/autopilot.last")) / 60)) min ago"
    else
      echo "Last pass: never"
    fi
    if is_mac && [ "$st" = on ] && ! [ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
      echo "${C_Y}The background job is missing; run: disk-jockey autopilot on$C_0"
    fi
    [ -f "$LOG" ] && { echo "Recent:"; tail -n 8 "$LOG" | sed 's/^/  /'; }
    ;;
  run)
    take_lock || { echo "A pass is already running."; exit 0; }
    trap 'rm -rf "$LOCK"' EXIT
    pass "$dry" "$emergency"
    ;;
  tick)
    [ "$(rd_conf autopilot off)" = on ] || exit 0
    # Devices whose owning agent session died without releasing them.
    reap_devices | while IFS= read -r l; do alog "$l"; done
    free=$(free_kb)
    if [ "$free" -lt "$(floor_kb)" ]; then
      due=1 emergency=1
    else
      last=$(cat "$RD_STATE/autopilot.last" 2>/dev/null || echo 0)
      due=0
      [ $(($(date +%s) - last)) -ge $(($(interval_min) * 60)) ] && due=1
    fi
    [ "$due" = 1 ] || exit 0
    take_lock || exit 0
    trap 'rm -rf "$LOCK"' EXIT
    pass 0 "$emergency"
    # Keep the log small.
    if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 1048576 ]; then tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
    ;;
  *) log "unknown command: $cmd"; usage >&2; exit 2 ;;
esac
