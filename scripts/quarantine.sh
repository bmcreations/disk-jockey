#!/usr/bin/env bash
# Opt-in undo. When on, cleanup moves things here instead of deleting them; they're deleted after the
# retention period or when purged. Moving frees no space until the purge.
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: quarantine.sh [command]
  status                 on or off, retention, what's held (default)
  on [--days N]          move instead of delete from now on (retention default 7 days)
  off                    delete directly again (items already held stay until purged)
  list                   held items, newest first
  restore ID|PATH ...    put items back where they were (worktrees re-register with git)
  restore --last         the most recent item
  restore --all          everything
  purge                  delete items older than the retention
  purge ID ...           delete these now
  purge --all            delete everything held now

One run only: --quarantine or --no-quarantine on clean, sweep and worktrees (or RD_QUARANTINE=1 / 0).
Held items do not free space. Tool-run cleanups (npm cache clean, brew cleanup, ...) can't be undone,
so they're skipped while quarantine is on. Items on a different disk than ~/.disk-jockey are left in place.
USAGE
}

items() { # newest first
  [ -d "$RD_QDIR" ] || return 0
  for d in "$RD_QDIR"/*; do [ -f "$d/meta" ] && printf '%s\n' "$d"; done | sort -r
}

held_summary() {
  local n=0 kb=0 d s
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$((n + 1)); s=$(q_meta "$d" kb); kb=$((kb + ${s:-0}))
  done < <(items)
  echo "$n $kb"
}

ids() { items | while IFS= read -r d; do basename "$d"; done; } # newest first
age_days() { echo $((($(date +%s) - $(q_meta "$1" time)) / 86400)); }

find_item() { # ID | unique ID prefix | original path
  local want="$1" d hit="" n=0 p
  case "$want" in
    /* | ~* | */*)
      # The original is gone, so normalize its parent (symlinked dirs, Windows spellings).
      p="${want/#\~/$HOME}"; p="${p%/}"
      p="$(norm_path "$(dirname "$p")")/$(basename "$p")"
      ;;
    *) p="" ;;
  esac
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$(basename "$d")" = "$want" ]; then printf '%s\n' "$d"; return 0; fi
    case "$(basename "$d")" in "$want"*) hit="$d"; n=$((n + 1)) ;; esac
    if [ -n "$p" ] && [ "$(q_meta "$d" path)" = "$p" ]; then printf '%s\n' "$d"; return 0; fi
  done < <(items)
  [ "$n" = 1 ] && { printf '%s\n' "$hit"; return 0; }
  return 1
}

restore_item() { # item-dir
  local d="$1" path kind repo err
  path=$(q_meta "$d" path) kind=$(q_meta "$d" kind) repo=$(q_meta "$d" repo)
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "  ${C_Y}kept$C_0 $(basename "$d"): $(tilde "$path") exists again; move it away first"
    return 1
  fi
  mkdir -p "$(dirname "$path")" 2>/dev/null
  if [ "$kind" = worktree ]; then
    if [ ! -d "$repo" ]; then
      echo "  ${C_Y}kept$C_0 $(basename "$d"): its repository $(tilde "$repo") is gone"
      return 1
    fi
    err=$(git -C "$repo" worktree move "$d/data" "$path" 2>&1)
  else
    err=$(mv -- "$d/data" "$path" 2>&1)
  fi
  if [ $? -ne 0 ] || [ ! -e "$path" ]; then
    echo "  ${C_R}failed$C_0 $(basename "$d"): ${err:-move failed}"
    return 1
  fi
  rm -rf -- "$d"
  echo "  ${C_G}restored$C_0 $(tilde "$path")"
}

cmd="${1:-status}"
[ $# -gt 0 ] && shift
case "$cmd" in
  -h | --help | help) usage ;;
  status)
    read -r hn hkb < <(held_summary)
    if q_enabled; then
      echo "Quarantine: ${C_B}${C_G}on$C_0 (kept $(q_days) days, then deleted)"
    else
      echo "Quarantine: ${C_B}off$C_0 (cleanup deletes directly; turn on with: disk-jockey quarantine on)"
    fi
    echo "Holding $hn item(s), $(human "$hkb"), in $(tilde "$RD_QDIR")"
    [ "$hn" -gt 0 ] && echo "${C_DIM}That space comes back when they're purged: disk-jockey quarantine purge --all$C_0"
    ;;
  on)
    days=$(q_days)
    if [ "${1:-}" = --days ]; then
      case "${2:-}" in '' | *[!0-9]*) log "--days needs a number"; exit 2 ;; esac
      days="$2"
    fi
    rd_conf_set quarantine on && rd_conf_set quarantine_days "$days" || { log "Couldn't write $RD_STATE/config"; exit 1; }
    echo "Quarantine on. Cleanup now moves items to $(tilde "$RD_QDIR") and deletes them after $days days."
    echo "Moving frees no space until then. Undo with: disk-jockey quarantine restore --last"
    ;;
  off)
    rd_conf_set quarantine off || exit 1
    read -r hn hkb < <(held_summary)
    echo "Quarantine off. Cleanup deletes directly again."
    [ "$hn" -gt 0 ] && echo "Still holding $hn item(s), $(human "$hkb"): disk-jockey quarantine purge --all to free it."
    ;;
  list)
    days=$(q_days) n=0
    printf '%s%-28s %-6s %-8s %-26s %s%s\n' "$C_DIM" ID AGE SIZE SOURCE PATH "$C_0"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      n=$((n + 1))
      printf '%-28s %-6s %s %-26s %s\n' "$(basename "$d")" "$(age_days "$d")d" "$(paint "$C_B" 8 "$(human "$(q_meta "$d" kb)")")" \
        "$(q_meta "$d" source)" "$(tilde "$(q_meta "$d" path)")"
    done < <(items)
    [ "$n" = 0 ] && echo "Nothing held."
    [ "$n" -gt 0 ] && echo "${C_DIM}Items older than ${days}d are deleted on the next cleanup run.$C_0"
    ;;
  restore)
    [ $# -gt 0 ] || { log "restore what? Pass an ID or path from 'disk-jockey quarantine list', --last or --all."; exit 2; }
    fails=0
    case "$1" in
      --all) wants=(); while IFS= read -r i; do wants+=("$i"); done < <(ids) ;;
      --last) wants=(); while IFS= read -r i; do wants+=("$i"); done < <(ids | head -n 1) ;;
      *) wants=("$@") ;;
    esac
    [ "${#wants[@]}" -gt 0 ] || { echo "Nothing held."; exit 0; }
    for want in "${wants[@]}"; do
      d=$(find_item "$want") || { echo "  ${C_Y}not found$C_0 $want"; fails=$((fails + 1)); continue; }
      restore_item "$d" || fails=$((fails + 1))
    done
    [ "$fails" = 0 ]
    ;;
  purge)
    if [ $# -eq 0 ]; then
      out=$(q_purge_expired)
      echo "${out:-Nothing older than $(q_days) days.}"
      exit 0
    fi
    before=$(free_kb)
    wants=("$@")
    if [ "$1" = --all ]; then wants=(); while IFS= read -r i; do wants+=("$i"); done < <(ids); fi
    n=0 fails=0
    for want in "${wants[@]}"; do
      d=$(find_item "$want") || { echo "  ${C_Y}not found$C_0 $want"; fails=$((fails + 1)); continue; }
      if q_purge_item "$d"; then n=$((n + 1)); else echo "  ${C_R}couldn't fully delete$C_0 $(tilde "$d")"; fails=$((fails + 1)); fi
    done
    echo "Purged $n item(s). Freed $(human $(($(free_kb) - before)))."
    [ "$fails" = 0 ]
    ;;
  *) log "unknown command: $cmd"; usage >&2; exit 2 ;;
esac
