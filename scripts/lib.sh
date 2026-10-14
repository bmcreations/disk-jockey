#!/usr/bin/env bash
# Shared helpers for disk-jockey. Bash 3.2 compatible (stock macOS bash).

RD_OS="$(uname -s)"
RD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD_TARGETS="${RD_TARGETS:-$RD_DIR/../targets.conf}"

is_mac() { [ "$RD_OS" = "Darwin" ]; }
have() { command -v "$1" >/dev/null 2>&1; }
log() { printf '%s\n' "$*" >&2; }

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

# 0 if a process matches any of the comma-separated pgrep -f patterns.
is_busy() {
  [ -n "$1" ] && [ "$1" != "-" ] || return 1
  local IFS=',' pat pid
  [ -n "${RD_ANCESTORS:-}" ] || RD_ANCESTORS=" $(rd_ancestors) "
  for pat in $1; do
    for pid in $(pgrep -f -- "$pat" 2>/dev/null); do
      # Ignore this script and the shell/agent that launched it (their command lines may contain the pattern).
      case "$RD_ANCESTORS" in *" $pid "*) continue ;; esac
      return 0
    done
  done
  return 1
}

# Number of processes matching a pgrep -f pattern, excluding this script's ancestors.
count_procs() {
  local pid n=0
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
        linux) is_mac && continue ;;
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
process_cwds() {
  have lsof || return 0
  lsof -nP -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}

# 0 if any process has its cwd at or under DIR. Pass cwds list as $2.
dir_in_use() {
  printf '%s\n' "$2" | awk -v w="$1" '$0==w || index($0, w"/")==1 {f=1} END{exit !f}'
}
