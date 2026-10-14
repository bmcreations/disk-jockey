#!/usr/bin/env bash
# Delete regenerable build outputs (node_modules, build/, .gradle/, DerivedData, target/, ...) in projects idle for N days.
. "$(dirname "$0")/lib.sh"
# Read-only git calls must not take index.lock (agents may be using the same repo).
export GIT_OPTIONAL_LOCKS=0

usage() {
  cat <<'EOF'
Usage: sweep.sh [options] [root ...]
  --days N     a project is idle when it has no commit and no git index change in N days (default 14)
  --depth N    how deep to look for projects under each root (default 5)
  --apply      delete (default is a dry run)
Guards: only deletes a directory when its build-file sibling exists (build/ next to build.gradle, target/ next to
Cargo.toml, ...), never deletes anything git tracks (committed Pods/ stay), skips projects a process is working in.
EOF
}

days=14 depth=5 apply=0
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="$2"; shift ;;
    --depth) depth="$2"; shift ;;
    --apply) apply=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) log "unknown argument: $1"; usage; exit 2 ;;
    *) roots+=("$1") ;;
  esac
  shift
done
if [ "${#roots[@]}" -eq 0 ]; then
  while IFS= read -r r; do roots+=("$r"); done < <(default_roots)
fi
if [ "${#roots[@]}" -eq 0 ]; then
  log "No project roots found. Pass directories or set RD_ROOTS."
  exit 2
fi
have git || { log "git not found"; exit 2; }

cwds=$(process_cwds)
now=$(date +%s)
total=0

# Projects: repos found under the roots, plus every linked worktree git knows about for them.
# Agent worktrees often sit deep inside a repo (e.g. repo/.claude/worktrees/NAME), beyond --depth.
find_projects() {
  local r repo
  for r in "${roots[@]}"; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth "$depth" \( -name node_modules -o -name build -o -name .build -o -name DerivedData -o -name Pods -o -name target \) -prune \
      -o -name .git -prune -print 2>/dev/null
  done | sed 's#/\.git$##' | sort -u | while IFS= read -r repo; do
    printf '%s\n' "$repo"
    [ -d "$repo/.git" ] && git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
  done | sort -u
}

has_sibling() { # dir pattern...
  local d="$1" p
  shift
  for p in "$@"; do
    set -- "$d"/$p
    [ -e "$1" ] && return 0
  done
  return 1
}

is_artifact() { # path
  local d name
  d=$(dirname "$1"); name=$(basename "$1")
  case "$name" in
    build | .gradle | .cxx | .kotlin) has_sibling "$d" 'build.gradle*' 'settings.gradle*' ;;
    .build) has_sibling "$d" Package.swift ;;
    Pods) has_sibling "$d" Podfile ;;
    target) has_sibling "$d" Cargo.toml pom.xml ;;
    .venv) has_sibling "$d" pyproject.toml requirements.txt setup.py ;;
    node_modules | .next | .turbo | .nuxt | .expo | .svelte-kit) has_sibling "$d" package.json ;;
    DerivedData) return 0 ;;
    *) return 1 ;;
  esac
}

printf '%s%-8s %s%s\n' "$C_DIM" SIZE PATH "$C_0"
while IFS= read -r proj; do
  [ -n "$proj" ] || continue
  last=$(git -C "$proj" log -1 --format=%ct 2>/dev/null)
  [ -n "$last" ] || last=0
  [ $(((now - last) / 86400)) -lt "$days" ] && continue
  idx=$(git -C "$proj" rev-parse --git-path index 2>/dev/null)
  case "$idx" in /*) ;; *) idx="$proj/$idx" ;; esac
  [ -n "$(find "$idx" -mtime "-$days" -print 2>/dev/null)" ] && continue
  dir_in_use "$proj" "$cwds" && continue
  proj_top=$(git -C "$proj" rev-parse --show-toplevel 2>/dev/null)

  while IFS= read -r a; do
    [ -n "$a" ] || continue
    is_artifact "$a" || continue
    # Nested repos/worktrees are swept as their own project, with their own idle and tracked-file checks.
    owner=$(git -C "$(dirname "$a")" rev-parse --show-toplevel 2>/dev/null)
    [ "$owner" = "$proj_top" ] || continue
    rel="${a#"$proj"/}"
    [ -n "$(git -C "$proj" ls-files -- "$rel" 2>/dev/null | head -n 1)" ] && continue
    safe_to_delete "$a" || continue
    kb=$(printf '%s\n' "$a" | size_kb)
    [ "$kb" -gt 0 ] || continue
    total=$((total + kb))
    printf '%s %s\n' "$(paint "$C_B" 8 "$(human "$kb")")" "$(tilde "$a")"
    [ "$apply" = 1 ] && rm -rf -- "$a"
  done < <(find "$proj" -mindepth 1 -name .git -prune -o -type d \( -name node_modules -o -name build -o -name .gradle \
    -o -name .cxx -o -name .kotlin -o -name DerivedData -o -name .build -o -name Pods -o -name target -o -name .next \
    -o -name .turbo -o -name .nuxt -o -name .expo -o -name .svelte-kit -o -name .venv \) -prune -print 2>/dev/null)
done < <(find_projects)

echo
if [ "$apply" = 1 ]; then
  echo "$C_B${C_G}Removed $(human "$total")$C_0 of build outputs from projects idle >= ${days}d."
else
  echo "$C_B${C_G}Would remove $(human "$total")$C_0 from projects idle >= ${days}d. Re-run with --apply."
fi
