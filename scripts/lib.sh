#!/usr/bin/env bash
# Shared helpers for disk-jockey. Bash 3.2 compatible (stock macOS bash).

RD_OS="${RD_FORCE_OS:-$(uname -s)}"
RD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD_TARGETS="${RD_TARGETS:-$RD_DIR/../targets.conf}"
RD_VERSION="$(cat "$RD_DIR/../VERSION" 2>/dev/null || echo dev)"

# Defined first: everything below may run at load time.
have() { command -v "$1" >/dev/null 2>&1; }
log() { printf '%s\n' "$*" >&2; }

is_mac() { [ "$RD_OS" = "Darwin" ]; }
is_win() { case "$RD_OS" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac; return 1; }
is_linux() { ! is_mac && ! is_win; }

# Windows has several spellings of one folder (C:/Users/x/AppData/Local/Temp/a, /c/Users/..., /tmp/a).
# Round-trip through the Windows long form (-l expands 8.3 names like RUNNER~1) so every path compares
# in one canonical POSIX form.
# Elsewhere, resolve symlinks (macOS /var -> /private/var, a symlinked ~/dev) so git's physical paths match.
norm_path() {
  if is_win && have cygpath; then
    cygpath -u "$(cygpath -m -l "$1")"
  elif [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}
# $HOME in the same canonical form, so "is this under home" checks agree with normalized paths.
HOME=$(norm_path "$HOME")
export HOME
# Our own state: config, quarantine, session records.
RD_STATE="${RD_STATE:-$HOME/.disk-jockey}"
[ -d "$RD_STATE" ] && RD_STATE=$(norm_path "$RD_STATE")
RD_QDIR="$RD_STATE/quarantine"

# Per-run scratch dir (process lists, Windows facts). Old ones are swept on each run.
RD_TMP="${TMPDIR:-/tmp}/disk-jockey-$(id -u 2>/dev/null || echo 0)"
mkdir -p "$RD_TMP" 2>/dev/null
find "$RD_TMP" -type f -mmin +60 -exec rm -f {} + 2>/dev/null
# PIDs are reused (quickly on Windows): never inherit a cache file from an earlier process.
rm -f "$RD_TMP/procs.$$" "$RD_TMP/facts.$$" 2>/dev/null

# Colors: on for an interactive terminal only, so agents reading through a pipe get plain text.
# NO_COLOR=1 turns them off, FORCE_COLOR=1 forces them on. Truecolor when the terminal advertises it.
C_0='' C_B='' C_DIM='' C_G='' C_Y='' C_R='' C_C='' C_M='' C_P=''
# Order: NO_COLOR wins, then FORCE_COLOR (even on TERM=dumb), then an interactive non-dumb terminal.
if [ -z "${NO_COLOR:-}" ] && { [ -n "${FORCE_COLOR:-}" ] || { [ -t 1 ] && [ "${TERM:-}" != dumb ]; }; }; then
  _e=$'\033['
  C_0="${_e}0m" C_B="${_e}1m"
  case "${COLORTERM:-}" in
    truecolor | 24bit)
      C_DIM="${_e}38;2;139;148;158m" C_G="${_e}38;2;63;185;80m" C_Y="${_e}38;2;227;179;65m"
      C_R="${_e}38;2;255;123;114m" C_C="${_e}38;2;121;192;255m" C_M="${_e}38;2;210;168;255m" C_P="${_e}38;2;255;77;141m"
      ;;
    *)
      C_DIM="${_e}2m" C_G="${_e}32m" C_Y="${_e}33m" C_R="${_e}31m" C_C="${_e}36m" C_M="${_e}35m" C_P="${_e}95m"
      ;;
  esac
fi

# Display form of a path: $HOME shown as ~.
# shellcheck disable=SC2088  # literal ~ is intended for display
tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# paint COLOR WIDTH TEXT: pad first, then color, so escape codes never break column alignment.
paint() {
  if [ -n "$1" ]; then printf '%s%-*s%s' "$1" "$2" "$3" "$C_0"; else printf '%-*s' "$2" "$3"; fi
}

# KB -> "1.2G"
human() {
  awk -v k="${1:-0}" 'BEGIN{u="KMGTP";i=1;while(k>=1024&&i<5){k/=1024;i++}
    if(i==1)printf "%dK",k; else printf "%.1f%s",k,substr(u,i,1)}'
}

# "50G" | "500M" | "1T" | raw KB -> KB
to_kb() {
  local v="$1" n
  n="${v%[KkMmGgTt]}"
  case "$v" in
    *[Tt]) echo $((n * 1024 * 1024 * 1024)) ;;
    *[Gg]) echo $((n * 1024 * 1024)) ;;
    *[Mm]) echo $((n * 1024)) ;;
    *[Kk]) echo "$n" ;;
    *) echo "$v" ;;
  esac
}

free_kb() {
  # Tests: RD_TEST_FREE_FILE holds a number of KB (rewritable mid-run).
  if [ -n "${RD_TEST_FREE_FILE:-}" ] && [ -f "$RD_TEST_FREE_FILE" ]; then cat "$RD_TEST_FREE_FILE"; return; fi
  df -Pk "${1:-$HOME}" 2>/dev/null | awk 'NR==2{print $4}'
}

# Sum `du -sk` over newline-separated paths on stdin.
size_kb() {
  local t=0 p s
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$p" ] || continue
    s=$(du -sk "$p" 2>/dev/null | tail -n 1 | awk '{print $1}')
    t=$((t + ${s:-0}))
  done
  echo "$t"
}

# Filesystem type holding PATH (apfs, btrfs, ext4, zfs, ...).
fs_type() {
  if is_mac; then
    diskutil info "$(df -P "$1" | awk 'NR==2{print $1}')" 2>/dev/null | awk -F: '/Type \(Bundle\)/{gsub(/ /,"",$2); print $2}'
  elif have findmnt; then
    findmnt -n -o FSTYPE -T "$1" 2>/dev/null
  else
    stat -f -c %T "$1" 2>/dev/null
  fi
}

# 0 if the tool behind a cmd: target can run now (installed, and for docker, daemon reachable).
tool_ready() {
  have "$1" || return 1
  case "$1" in
    docker) docker info >/dev/null 2>&1 ;;
    podman) podman info >/dev/null 2>&1 ;;
  esac
}

# Expand a comma-separated path field (~ and globs, spaces allowed). Prints existing matches.
expand_paths() {
  local field="$1" part m old_ifs="$IFS"
  [ -z "$field" ] && return 0
  [ "$field" = "-" ] && return 0
  IFS=','
  set -f
  # shellcheck disable=SC2206  # intentional split on IFS=, with globbing off
  local parts=($field)
  set +f
  IFS=$'\n'
  for part in "${parts[@]}"; do
    part="${part#"${part%%[![:space:]]*}"}"
    case "$part" in
      *%*%*)
        # %LOCALAPPDATA%/... style (Windows only). Unset variables drop the path.
        is_win || continue
        local var val
        var="${part#*%}"
        var="${var%%%*}"
        val=$(printenv "$var" 2>/dev/null)
        [ -n "$val" ] || continue
        val=$(norm_path "$val")
        part="${part/"%$var%"/$val}"
        ;;
    esac
    part="${part/#\~/$HOME}"
    for m in $part; do
      if [ -e "$m" ] || [ -L "$m" ]; then printf '%s\n' "$m"; fi
    done
  done
  IFS="$old_ifs"
}

# 0 if nothing under PATH was modified or installed in the last DAYS days.
# ctime matters: extracted archives (toolchains, browsers) keep old mtimes but get a fresh ctime.
is_stale() {
  local hit
  if [ "${RD_IGNORE_CTIME:-0}" = 1 ]; then
    hit=$(find "$1" -mtime "-$2" -print -quit 2>/dev/null)
  else
    hit=$(find "$1" \( -mtime "-$2" -o -ctime "-$2" \) -print -quit 2>/dev/null)
  fi
  [ -z "$hit" ]
}

# Paths that must never be deleted, nor any directory that contains them.
rd_protected() {
  cat <<EOF
$HOME
$HOME/.android/debug.keystore
$HOME/.android/adbkey
$HOME/.android/adbkey.pub
$HOME/.ssh
$HOME/.gnupg
$HOME/.aws
$HOME/.kube
$HOME/.config
$HOME/.netrc
$HOME/.npmrc
$HOME/.gradle/gradle.properties
$HOME/.gradle/init.d
$HOME/.m2/settings.xml
$HOME/.m2/settings-security.xml
$HOME/Library/Keychains
$HOME/Library/MobileDevice
$HOME/.claude/settings.json
$HOME/.claude/CLAUDE.md
$HOME/.claude/skills
$HOME/.agents/skills
$HOME/Documents
$HOME/Desktop
$RD_STATE
EOF
  if [ -n "${RD_PROTECT:-}" ]; then printf '%s\n' "$RD_PROTECT" | tr ':' '\n'; fi
}

# Temp roots where agents keep scratch space (Claude Code: /tmp/claude-UID, /private/tmp on macOS).
rd_tmp_roots() {
  local r
  for r in /tmp /private/tmp /var/tmp ${TMPDIR:+"${TMPDIR%/}"}; do
    [ -d "$r" ] || continue
    printf '%s\n' "$r"
    printf '%s\n' "$(norm_path "$r")" # canonical spelling too (/var -> /private/var, Windows long paths)
  done
}

# 0 if PATH is at least two levels inside a temp root and owned by this user (shared /tmp holds
# other users' files and system sockets; the temp folder itself and its top level are never touched).
safe_tmp() {
  local p="$1" r
  [ -O "$p" ] || return 1
  while IFS= read -r r; do
    case "$r" in /?*) ;; *) continue ;; esac # never an empty or relative root
    case "$p" in "$r"/?*/?*) return 0 ;; esac
  done < <(rd_tmp_roots)
  return 1
}

# 0 if PATH may be deleted: under $HOME (or an owned temp subfolder), not a symlink, not protected,
# not a parent of protected.
safe_to_delete() {
  local p="$1" q
  case "$p" in */../* | */.. | */./* | */.) return 1 ;; esac
  [ -L "$p" ] && return 1
  # Compare in the canonical form the protected list uses: a path reached through a symlinked
  # folder (/tmp, /var, a linked ~/dev) must not slip past it.
  p="$(norm_path "$(dirname "$p")")/$(basename "$p")"
  case "$p" in "$HOME"/?*) ;; *) safe_tmp "$p" || return 1 ;; esac
  while IFS= read -r q; do
    [ -z "$q" ] && continue
    [ "$p" = "$q" ] && return 1
    case "$q" in "$p"/*) return 1 ;; esac
  done < <(rd_protected)
  return 0
}

# ---- Quarantine: opt-in undo. Off unless `disk-jockey quarantine on`, --quarantine, or RD_QUARANTINE=1.
# Items are moved (a rename, same disk only) to $RD_QDIR/<id>/data with a meta file beside them,
# and deleted for real when purged: after quarantine_days, or by `disk-jockey quarantine purge`.

rd_conf() { # key default
  local v=""
  [ -f "$RD_STATE/config" ] && v=$(sed -n "s/^$1=//p" "$RD_STATE/config" | tail -n 1)
  printf '%s' "${v:-$2}"
}
rd_conf_set() { # key value
  mkdir -p "$RD_STATE" || return 1
  local f="$RD_STATE/config"
  { [ -f "$f" ] && grep -v "^$1=" "$f"; printf '%s=%s\n' "$1" "$2"; } >"$f.$$" && mv "$f.$$" "$f"
}
q_enabled() {
  case "${RD_QUARANTINE:-}" in 1) return 0 ;; 0) return 1 ;; esac
  [ "$(rd_conf quarantine off)" = on ]
}
q_days() { rd_conf quarantine_days 7; }
q_meta() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n 1; } # item-dir key

# Device a path lives on. A move to another device is a copy, which needs the free space we lack.
dev_of() {
  if is_win; then norm_path "$1" | cut -d/ -f2; return; fi
  stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null
}

# q_move PATH SOURCE [KIND REPO BRANCH KB]. KIND is dir or worktree (moved with git worktree move,
# so git keeps tracking it and uncommitted changes survive). Sets RD_Q_ID, or RD_Q_ERR on failure.
q_move() {
  local p="$1" src="$2" kind="${3:-dir}" repo="${4:-}" branch="${5:-}" kb="${6:-}" d err
  RD_Q_ID="" RD_Q_ERR=""
  mkdir -p "$RD_QDIR" 2>/dev/null || { RD_Q_ERR="can't create $(tilde "$RD_QDIR")"; return 1; }
  if [ "$(dev_of "$p")" != "$(dev_of "$RD_QDIR")" ]; then
    RD_Q_ERR="on a different disk than $(tilde "$RD_QDIR"), so moving would copy it"
    return 1
  fi
  [ -n "$kb" ] || kb=$(printf '%s\n' "$p" | size_kb)
  RD_Q_ID="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
  d="$RD_QDIR/$RD_Q_ID"
  mkdir "$d" 2>/dev/null || { RD_Q_ERR="can't create $(tilde "$d")"; return 1; }
  printf 'path=%s\nkind=%s\nsource=%s\nrepo=%s\nbranch=%s\nkb=%s\ntime=%s\n' \
    "$p" "$kind" "$src" "$repo" "$branch" "$kb" "$(date +%s)" >"$d/meta"
  if [ "$kind" = worktree ]; then
    err=$(git -C "$repo" worktree move "$p" "$d/data" 2>&1)
  else
    err=$(mv -- "$p" "$d/data" 2>&1)
  fi
  if [ $? -ne 0 ] || [ ! -e "$d/data" ]; then
    rm -rf -- "$d"
    RD_Q_ERR=$(printf '%s' "${err:-move failed}" | head -n 1 | sed 's/^fatal: //')
    RD_Q_ID=""
    return 1
  fi
}

# Delete PATH, or quarantine it when that's on. Sets RD_REMOVED to deleted or quarantined.
remove_path() { # path source [kb]
  RD_REMOVED=""
  if q_enabled; then
    q_move "$1" "$2" dir "" "" "${3:-}" || return 1
    RD_REMOVED=quarantined
    return 0
  fi
  rm -rf -- "$1" 2>/dev/null || return 1
  RD_REMOVED=deleted
}

q_purge_item() { # item-dir
  local d="$1" kind repo
  kind=$(q_meta "$d" kind) repo=$(q_meta "$d" repo)
  if [ "$kind" = worktree ] && [ -n "$repo" ] && [ -d "$repo" ] && [ -e "$d/data" ]; then
    git -C "$repo" worktree remove --force "$d/data" >/dev/null 2>&1
  fi
  rm -rf -- "$d" 2>/dev/null
  # Bazel-style read-only trees: make writable and retry.
  [ -e "$d" ] && chmod -R u+w "$d" 2>/dev/null && rm -rf -- "$d" 2>/dev/null
  [ "$kind" = worktree ] && [ -n "$repo" ] && [ -d "$repo" ] && git -C "$repo" worktree prune 2>/dev/null
  [ ! -e "$d" ]
}

# Purge items older than the retention. Prints a line only when something was purged.
q_purge_expired() {
  [ -d "$RD_QDIR" ] || return 0
  local days now d t s n=0 kb=0
  days=$(q_days) now=$(date +%s)
  for d in "$RD_QDIR"/*; do
    [ -f "$d/meta" ] || continue
    t=$(q_meta "$d" time)
    [ $(((now - ${t:-0}) / 86400)) -ge "$days" ] || continue
    s=$(q_meta "$d" kb)
    kb=$((kb + ${s:-0}))
    q_purge_item "$d" && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && echo "Purged $n quarantined item(s) older than ${days}d ($(human "$kb"))."
  return 0
}

# Windows has no pgrep: one PowerShell call lists "PID Name CommandLine", cached for the run.
# Built before any matching, and our own helpers are dropped, so the search never sees itself.
win_procs() {
  local f="$RD_TMP/procs.$$"
  if [ ! -s "$f" ]; then
    powershell.exe -NoProfile -NonInteractive -Command \
      'Get-CimInstance Win32_Process | ForEach-Object { "{0} {1} {2}" -f $_.ProcessId, $_.Name, $_.CommandLine }' \
      2>/dev/null | tr -d '\r' |
      grep -Ev '^[0-9]+ (grep|powershell|awk|sed|head|tr|cat)\.exe ' >"$f"
  fi
  cat "$f"
}

# Windows facts in one PowerShell call, as key=value lines (cached for the run).
win_fact() { # key
  local f="$RD_TMP/facts.$$"
  if [ ! -s "$f" ]; then
    powershell.exe -NoProfile -NonInteractive -Command '
      $ErrorActionPreference = "SilentlyContinue"
      $l = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
      if ($l -ne $null) { "cpu_load_pct=" + [int]$l }
      "cpu_cores=" + (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
      $h = Get-Item -Force ($env:SystemDrive + "\hiberfil.sys")
      if ($h) { "hiberfil_kb=" + [int64]($h.Length / 1024) }
      $o = Get-CimInstance Win32_OperatingSystem
      if ($o) { "mem_free_pct=" + [int]($o.FreePhysicalMemory * 100 / $o.TotalVisibleMemorySize) }
      $p = Get-Item -Force ($env:SystemDrive + "\pagefile.sys")
      if ($p) { "pagefile_kb=" + [int64]($p.Length / 1024) }
    ' 2>/dev/null | tr -d '\r' >"$f"
  fi
  sed -n "s/^$1=//p" "$f" | head -n 1
}

# Swap (pagefile on Windows) in use, KB.
swap_used_kb() {
  if is_mac; then
    sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p' | awk '{printf "%d", $1 * 1024}'
  elif [ -r /proc/meminfo ]; then
    awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print t-f}' /proc/meminfo
  else
    echo 0
  fi
}

# Memory pressure as "LEVEL FREE_PCT SWAP_KB", LEVEL one of ok, warn, critical.
# macOS: the kernel's own pressure level (what Activity Monitor's graph shows), plus memory_pressure's free %.
# Linux: MemAvailable and PSI stall time. Low free % or heavy swap raise the level anywhere.
# RD_TEST_MEM="LEVEL PCT [SWAP_KB]" overrides (tests).
mem_state() {
  if [ -n "${RD_TEST_MEM:-}" ]; then
    set -- $RD_TEST_MEM
    echo "$1 $2 ${3:-0}"
    return
  fi
  local lvl=ok pct="" swap psi
  swap=$(swap_used_kb)
  if is_mac; then
    case "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in 2) lvl=warn ;; 4) lvl=critical ;; esac
    pct=$(memory_pressure -Q 2>/dev/null | sed -n 's/.*free percentage: *\([0-9]*\)%.*/\1/p')
  elif is_win; then
    pct=$(win_fact mem_free_pct)
  elif [ -r /proc/meminfo ]; then
    pct=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if (t > 0) printf "%d", a * 100 / t}' /proc/meminfo)
    # PSI: share of the last 10s in which some task waited on memory.
    psi=$(awk '/^some/{for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) {sub("avg10=", "", $i); printf "%d", $i}}' /proc/pressure/memory 2>/dev/null)
    if [ -n "$psi" ]; then
      if [ "$psi" -ge 30 ]; then lvl=critical; elif [ "$psi" -ge 10 ]; then lvl=warn; fi
    fi
  fi
  if [ -n "$pct" ]; then
    if [ "$pct" -lt 5 ]; then lvl=critical; elif [ "$pct" -lt 10 ] && [ "$lvl" = ok ]; then lvl=warn; fi
  fi
  [ "$lvl" = ok ] && [ "${swap:-0}" -gt $((8 * 1024 * 1024)) ] && lvl=warn
  echo "$lvl ${pct:-?} ${swap:-0}"
}

# Resident memory and CPU by group of agent-era processes: "GROUP KB CPU% COUNT" lines.
# RSS double-counts shared pages, so treat totals as an upper bound. Not available on Windows.
mem_groups() {
  is_win && return 0
  ps -A -o rss= -o pcpu= -o args= 2>/dev/null | awk '
    { rss = $1; cpu = $2; $1 = ""; $2 = ""; a = $0; sub(/^ +/, "", a)
      cmd = a; sub(/ .*/, "", cmd); n = split(cmd, parts, "/"); base = parts[n]
      g = ""
      if (base ~ /^(awk|gawk|mawk|ps|grep|sed)$/) next # this pipeline, whose args contain the patterns
      if (a ~ /Claude\.app\/Contents/) g = "claude-app"
      else if (base == "claude" || a ~ /claude-code\/cli\.js/) g = "claude-sessions"
      else if (a ~ /qemu-system|\/emulator\/emulator/) g = "emulators"
      else if (a ~ /CoreSimulator|launchd_sim|Simulator\.app/) g = "simulators"
      else if (a ~ /GradleDaemon|KotlinCompileDaemon|GradleWrapperMain|kotlin-daemon/) g = "jvm-daemons"
      else if (base ~ /^(xcodebuild|swift-frontend|XCBBuildService|clang)$/) g = "xcode-builds"
      if (g != "") { kb[g] += rss; c[g] += cpu; k[g]++ }
    }
    END { for (g in kb) printf "%s %d %d %d\n", g, kb[g], c[g], k[g] }'
}

# A string as a JSON string body (no surrounding quotes).
json_str() {
  printf '%s' "$1" | awk 'BEGIN{ORS=""} { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); if (NR > 1) printf "\\n"; print }'
}

# ---- Device ownership: which agent process holds which simulator/emulator (the MCP server's acquire).
# A record is $RD_STATE/devices/<sim:UDID|emu:SERIAL> holding "PID NAME" of the owning agent process.
# RD_AGENT_PID="PID NAME" overrides the lookup (tests, other agents).

# The agent behind this process: the nearest ancestor that isn't a shell.
proc_owner() {
  if [ -n "${RD_AGENT_PID:-}" ]; then echo "$RD_AGENT_PID"; return; fi
  is_win && return 0
  local p=$PPID c i=0
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$i" -lt 4 ]; do
    c=$(ps -o comm= -p "$p" 2>/dev/null | sed 's#.*/##; s/^-//')
    case "$c" in "" | sh | bash | zsh | dash | fish | env) ;; *) echo "$p $c"; return ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    i=$((i + 1))
  done
}
# 0 while "PID NAME" is still that process. Unknown (no pid, Windows) counts as alive: never reaped.
owner_alive() {
  local pid="${1%% *}" name="${1#* }"
  [ -n "$pid" ] && [ "$pid" != "$1" ] || return 0
  is_win && return 0
  [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##; s/^-//')" = "$name" ]
}
dev_dir() { echo "$RD_STATE/devices"; }
dev_owner() { cat "$(dev_dir)/$1" 2>/dev/null; }
dev_claim() { mkdir -p "$(dev_dir)" && proc_owner >"$(dev_dir)/$1"; }
dev_release() { rm -f "$(dev_dir)/$1"; }
# One acquirer at a time, machine-wide: choosing a device and recording the claim happen under this lock,
# so two sessions can't both be handed the last free one. Waits up to $1 seconds (default 15).
# A lock whose holder died, or that is older than a minute (holder died before writing its pid), is taken over.
dev_lock() {
  local d i=0 tries p
  d="$(dev_dir).lock"
  tries=$((${1:-15} * 5))
  mkdir -p "$(dev_dir)"
  while ! mkdir "$d" 2>/dev/null; do
    p=$(cat "$d/pid" 2>/dev/null)
    if { [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; } || [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -rf "$d"
      continue
    fi
    i=$((i + 1))
    [ "$i" -ge "$tries" ] && return 1
    sleep 0.2
  done
  echo $$ >"$d/pid"
}
dev_unlock() { rm -rf "$(dev_dir).lock"; }
dev_shutdown() {
  case "$1" in
    sim:*) have xcrun && xcrun simctl shutdown "${1#sim:}" >/dev/null 2>&1 ;;
    emu:*) have adb && adb -s "${1#emu:}" emu kill >/dev/null 2>&1 ;;
  esac
}
# Shut down devices whose owner is gone, or is the given "PID NAME" (a session ending). Prints what it did.
reap_devices() {
  local f id o
  for f in "$(dev_dir)"/*; do
    [ -f "$f" ] || continue
    id=$(basename "$f")
    o=$(cat "$f" 2>/dev/null)
    if [ -n "${1:-}" ] && [ "$o" = "$1" ]; then
      dev_shutdown "$id"; rm -f "$f"; echo "released $id (its session ended)"
    elif ! owner_alive "$o"; then
      dev_shutdown "$id"; rm -f "$f"; echo "released $id (owner ${o:-unknown} gone)"
    fi
  done
}

# Split a comma-separated pattern list into lines.
patterns() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^$/d'; }

# 0 if a process matches any of the comma-separated pgrep -f patterns.
# Sets RD_BUSY_BY to "PID name" of the first match, for messages.
is_busy() {
  RD_BUSY_BY=""
  [ -n "$1" ] && [ "$1" != "-" ] || return 1
  local pat pid
  if is_win; then
    win_procs >/dev/null
    while IFS= read -r pat; do
      RD_BUSY_BY=$(grep -E -- "$pat" "$RD_TMP/procs.$$" | head -n 1 | awk '{print $1" "$2}')
      [ -n "$RD_BUSY_BY" ] && return 0
    done < <(patterns "$1")
    return 1
  fi
  [ -n "${RD_ANCESTORS:-}" ] || RD_ANCESTORS=" $(rd_ancestors) "
  while IFS= read -r pat; do
    for pid in $(pgrep -f -- "$pat" 2>/dev/null); do
      # Ignore this script and the shell/agent that launched it (their command lines may contain the pattern).
      case "$RD_ANCESTORS" in *" $pid "*) continue ;; esac
      RD_BUSY_BY="$pid $(ps -o comm= -p "$pid" 2>/dev/null | head -n 1 | sed 's#.*/##')"
      return 0
    done
  done < <(patterns "$1")
  return 1
}

# Number of processes matching a pgrep -f pattern, excluding this script's ancestors.
count_procs() {
  local pid n=0
  if is_win; then
    win_procs >/dev/null
    grep -Ec -- "$1" "$RD_TMP/procs.$$"
    return 0
  fi
  [ -n "${RD_ANCESTORS:-}" ] || RD_ANCESTORS=" $(rd_ancestors) "
  for pid in $(pgrep -f -- "$1" 2>/dev/null); do
    case "$RD_ANCESTORS" in *" $pid "*) continue ;; esac
    n=$((n + 1))
  done
  echo "$n"
}

# PIDs of this process and its ancestors.
rd_ancestors() {
  local p=$$ out=""
  while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    out="$out $p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  echo "$out"
}

# Emit targets.conf rows applicable to this OS: tier|id|os|paths|action|busy|note
each_target() {
  grep -v '^[[:space:]]*#' "$RD_TARGETS" | grep -v '^[[:space:]]*$' |
    while IFS='|' read -r tier id os paths action busy note; do
      case "$os" in
        any) ;;
        mac) is_mac || continue ;;
        linux) is_linux || continue ;;
        win) is_win || continue ;;
        *) continue ;;
      esac
      printf '%s|%s|%s|%s|%s|%s|%s\n' "$tier" "$id" "$os" "$paths" "$action" "$busy" "$note"
    done
}

# ---- Orphans: build output that records which project it was built from, and whose project is gone.
# Agents create a worktree per task and delete it afterwards; Xcode's DerivedData and XcodeBuildMCP's
# per-workspace folders for it stay forever. Deciding needs no idle-time guess: the source path is recorded.

# One key from a plist (XML or binary). plutil on macOS; a sed fallback reads XML elsewhere (tests).
plist_get() { # file key
  if have plutil; then
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
  else
    tr -d '\n' <"$1" | sed -n "s:.*<key>$2</key>[[:space:]]*<string>\([^<]*\)</string>.*:\1:p" |
      sed 's/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'"'"'/g; s/&amp;/\&/g'
  fi
}
# First 12 hex characters of sha256(text), XcodeBuildMCP's workspace hash.
sha12() {
  if have shasum; then printf '%s' "$1" | shasum -a 256 | cut -c1-12
  elif have sha256sum; then printf '%s' "$1" | sha256sum | cut -c1-12
  fi
}
# Source paths a build folder records: Xcode's info.plist WorkspacePath (the folder itself, or each
# project folder inside an XcodeBuildMCP workspace's DerivedData) and XcodeBuildMCP's daemon workspaceRoot.
orphan_refs() {
  local d="$1" f
  for f in "$d/info.plist" "$d"/DerivedData/info.plist "$d"/DerivedData/*/info.plist; do
    [ -f "$f" ] && plist_get "$f" WorkspacePath && echo
  done
  f="$d/state/daemon/daemon.json"
  [ -f "$f" ] && { tr -d '\n' <"$f" | sed -n 's/.*"workspaceRoot"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'; echo; }
  return 0
}
# 0 only when the folder records at least one source path and every one of them is gone.
# Unknown (nothing recorded), a path on an unmounted volume, or a folder written in the last 2 minutes
# all count as live.
is_orphan() {
  local d="$1" r a key hash any=0
  [ -d "$d" ] && [ ! -L "$d" ] || return 1
  [ -n "$(find "$d" -maxdepth 1 -mmin -2 -print -quit 2>/dev/null)" ] && return 1
  key=$(basename "$d")
  hash=""
  case "$key" in *-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) hash="${key##*-}" ;; esac
  while IFS= read -r r || [ -n "$r" ]; do
    [ -n "$r" ] || continue
    case "$r" in /*) ;; *) continue ;; esac
    any=1
    [ -e "$r" ] && return 1
    case "$r" in /Volumes/*/*) a="${r#/Volumes/}"; [ -d "/Volumes/${a%%/*}" ] || return 1 ;; esac
    # XcodeBuildMCP keys a workspace by sha256 of its root: a root that still exists (the project
    # inside was renamed or moved) keeps the workspace.
    if [ -n "$hash" ]; then
      a="$r"
      while [ "$a" != / ] && [ -n "$a" ]; do
        a=$(dirname "$a")
        [ "$(sha12 "$a")" = "$hash" ] && [ -d "$a" ] && return 1
      done
    fi
  done < <(orphan_refs "$d")
  [ "$any" = 1 ]
}

# Paths a target would delete (stale:N keeps stale matches, orphan keeps orphans).
# With RD_SEEN set to a file, a path already claimed by an earlier target in this run is skipped,
# so overlapping rows (orphaned DerivedData and stale DerivedData) never count or act twice.
target_matches() {
  local paths="$1" action="$2" m days
  case "$action" in
    stale:*)
      days="${action#stale:}"
      # RD_STALE_MAX tightens every stale:N to at most that many days (autopilot's deeper rungs).
      if [ -n "${RD_STALE_MAX:-}" ] && [ "$RD_STALE_MAX" -lt "$days" ]; then days="$RD_STALE_MAX"; fi
      expand_paths "$paths" | while IFS= read -r m; do
        is_stale "$m" "$days" && printf '%s\n' "$m"
      done
      ;;
    orphan)
      expand_paths "$paths" | while IFS= read -r m; do
        is_orphan "$m" && printf '%s\n' "$m"
      done
      ;;
    *) expand_paths "$paths" ;;
  esac | if [ -n "${RD_SEEN:-}" ]; then
    while IFS= read -r m; do
      grep -qxF -- "$m" "$RD_SEEN" 2>/dev/null && continue
      printf '%s\n' "$m" >>"$RD_SEEN"
      printf '%s\n' "$m"
    done
  else
    cat
  fi
}

# Default project roots (override with RD_ROOTS="dir1:dir2").
default_roots() {
  local d
  if [ -n "${RD_ROOTS:-}" ]; then
    printf '%s\n' "$RD_ROOTS" | tr ':' '\n'
    return
  fi
  for d in code dev src Projects projects Developer workspace repos git work \
    AndroidStudioProjects StudioProjects IdeaProjects; do
    [ -d "$HOME/$d" ] && printf '%s\n' "$HOME/$d"
  done
}

# Current working directories of the user's processes (agents, shells, daemons).
# Linux reads /proc directly (fast, no dependency); elsewhere lsof.
# Returns 3 when no method is available, so callers can refuse to delete instead of assuming "not in use".
process_cwds() {
  if [ -z "${RD_TEST_NO_PROC:-}" ] && [ -d /proc/self ] && [ -e /proc/self/cwd ]; then
    local d
    for d in /proc/[0-9]*/cwd; do
      if is_win; then norm_path "$(readlink "$d" 2>/dev/null)"; echo; else readlink "$d" 2>/dev/null; fi
    done | sed '/^$/d' | sort -u
    return 0
  fi
  if [ -z "${RD_TEST_NO_LSOF:-}" ] && have lsof; then
    # lsof exits 1 when it can't read some processes, so judge by output: none at all means it failed.
    local out
    out=$(lsof -nP -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  return 3
}

# Sets $cwds for a script, or stops --apply when processes can't be inspected.
# RD_SKIP_INUSE_CHECK=1 overrides (the user accepts the risk).
load_cwds() { # apply-flag
  # Windows: /proc only sees Git Bash processes. Native apps are caught by win_dir_free() at --apply.
  cwds=$(process_cwds)
  if [ $? -eq 3 ]; then
    cwds=""
    if [ "$1" = 1 ] && [ "${RD_SKIP_INUSE_CHECK:-}" != 1 ]; then
      log "Can't check which folders running processes are using (no /proc and no lsof)."
      log "Install lsof, or set RD_SKIP_INUSE_CHECK=1 to delete without that check."
      exit 3
    fi
    log "Note: no /proc or lsof, so IN-USE detection is off for this run."
  fi
}

# 0 if any process has its cwd at or under DIR. Pass cwds list as $2.
dir_in_use() {
  printf '%s\n' "$2" | awk -v w="$1" '$0==w || index($0, w"/")==1 {f=1} END{exit !f}'
}

# Windows refuses to rename a folder while any process has it (or anything inside) open or as its
# working directory. Renaming there and back is a no-admin, no-dependency in-use test.
# Retries because antivirus and indexers briefly hold files; a false "in use" only means "skip".
win_dir_free() {
  local d="$1" tmp="$1.dj-probe.$$" i
  for i in 1 2 3; do
    if mv -- "$d" "$tmp" 2>/dev/null; then
      if mv -- "$tmp" "$d" 2>/dev/null; then return 0; fi
      log "WARNING: renamed $d to $tmp while checking it and could not rename it back. Rename it manually."
      return 1
    fi
    sleep 1
  done
  return 1
}


# Category used by the interactive mode, derived from the target id.
category_of() {
  case "$1" in
    xcode-* | xcodebuildmcp-* | xctest-* | sim-* | simulators | coresim-* | swift* | cocoapods-*) echo "Xcode & Simulators" ;;
    android-studio-* | jetbrains-* | vscode-* | cursor-*) echo "IDEs" ;;
    android-* | avd-* | gradle-* | kotlin-* | konan-* | maven-*) echo "Android & JVM" ;;
    npm-* | pnpm-* | yarn-* | bun-* | deno-*) echo "JavaScript" ;;
    pip-* | uv-* | conda-* | poetry-* | ml-models) echo "Python & ML" ;;
    go-* | cargo-* | rustup-*) echo "Go & Rust" ;;
    pub-* | flutter-* | version-managers | bazel* | nix-*) echo "Toolchains" ;;
    unity-* | unreal-*) echo "Game engines" ;;
    slack-* | discord-* | electron-*) echo "Desktop apps" ;;
    playwright-* | puppeteer-* | selenium-* | maestro-*) echo "Browsers & testing" ;;
    brew-*) echo "Homebrew" ;;
    agent-state | claude-*) echo "Agents" ;;
    docker-* | podman-*) echo "Containers" ;;
    snap-* | flatpak-* | journal* | apt-* | dnf-* | pacman-* | thumbnails | win-* | wsl-*) echo "System" ;;
    nuget-*) echo ".NET" ;;
    *) echo "Other" ;;
  esac
}

strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
