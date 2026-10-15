#!/usr/bin/env bash
# Shared helpers for disk-jockey. Bash 3.2 compatible (stock macOS bash).

RD_OS="${RD_FORCE_OS:-$(uname -s)}"
RD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD_TARGETS="${RD_TARGETS:-$RD_DIR/../targets.conf}"

# Defined first: everything below may run at load time.
have() { command -v "$1" >/dev/null 2>&1; }
log() { printf '%s\n' "$*" >&2; }

is_mac() { [ "$RD_OS" = "Darwin" ]; }
is_win() { case "$RD_OS" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac; return 1; }
is_linux() { ! is_mac && ! is_win; }

# Windows has several spellings of one folder (C:/Users/x/AppData/Local/Temp/a, /c/Users/..., /tmp/a).
# Round-trip through the Windows long form (-l expands 8.3 names like RUNNER~1) so every path compares
# in one canonical POSIX form.
norm_path() {
  if is_win && have cygpath; then cygpath -u "$(cygpath -m -l "$1")"; else printf '%s' "$1"; fi
}
if is_win && have cygpath; then
  HOME=$(norm_path "$HOME")
  export HOME
fi

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

free_kb() { df -Pk "${1:-$HOME}" 2>/dev/null | awk 'NR==2{print $4}'; }

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
$HOME/Documents
$HOME/Desktop
EOF
  if [ -n "${RD_PROTECT:-}" ]; then printf '%s\n' "$RD_PROTECT" | tr ':' '\n'; fi
}

# 0 if PATH may be deleted: under $HOME, not a symlink, not protected, not a parent of protected.
safe_to_delete() {
  local p="$1" q
  case "$p" in "$HOME"/?*) ;; *) return 1 ;; esac
  [ -L "$p" ] && return 1
  while IFS= read -r q; do
    [ -z "$q" ] && continue
    [ "$p" = "$q" ] && return 1
    case "$q" in "$p"/*) return 1 ;; esac
  done < <(rd_protected)
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
      $p = Get-Item -Force ($env:SystemDrive + "\pagefile.sys")
      if ($p) { "pagefile_kb=" + [int64]($p.Length / 1024) }
    ' 2>/dev/null | tr -d '\r' >"$f"
  fi
  sed -n "s/^$1=//p" "$f" | head -n 1
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

# Paths a target would delete (stale:N filters to stale matches only).
target_matches() {
  local paths="$1" action="$2" m days
  case "$action" in
    stale:*)
      days="${action#stale:}"
      expand_paths "$paths" | while IFS= read -r m; do
        is_stale "$m" "$days" && printf '%s\n' "$m"
      done
      ;;
    *) expand_paths "$paths" ;;
  esac
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
    xcode-* | xctest-* | sim-* | simulators | coresim-* | swift* | cocoapods-*) echo "Xcode & Simulators" ;;
    android-studio-* | jetbrains-*) echo "IDEs" ;;
    android-* | avd-* | gradle-* | kotlin-* | konan-* | maven-*) echo "Android & JVM" ;;
    npm-* | pnpm-* | yarn-* | bun-*) echo "JavaScript" ;;
    pip-* | uv-* | ml-models) echo "Python & ML" ;;
    go-* | cargo-*) echo "Go & Rust" ;;
    playwright-* | puppeteer-*) echo "Browsers" ;;
    brew-*) echo "Homebrew" ;;
    agent-state | claude-*) echo "Agents" ;;
    docker-* | podman-*) echo "Containers" ;;
    snap-* | flatpak-* | journal* | apt-* | dnf-* | pacman-* | thumbnails | win-* | wsl-*) echo "System" ;;
    nuget-*) echo ".NET" ;;
    *) echo "Other" ;;
  esac
}

strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
