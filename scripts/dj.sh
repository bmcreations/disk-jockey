#!/usr/bin/env bash
# Interactive mode for humans: preflight fixes, pick categories, review worktrees, apply.
# Agents and automation should call scan.sh / clean.sh / worktrees.sh / sweep.sh directly.
. "$(dirname "$0")/lib.sh"
case "${1:-}" in
  -h | --help)
    echo "Usage: dj.sh   interactive: preflight fixes, pick categories and worktrees, apply. Needs a terminal."
    echo "Keys: up/down or j/k move, space toggles, left/right less/more, a/r/n bulk, enter continue, q quit."
    exit 0 ;;
esac
D="$RD_DIR"

if [ ! -t 1 ] && [ -z "${RD_ALLOW_PIPE:-}" ]; then
  log "dj.sh is interactive. For agents and scripts use scan.sh, clean.sh, worktrees.sh and sweep.sh."
  exit 2
fi

CATS=("Xcode & Simulators" "Android & JVM" "IDEs" "JavaScript" "Python & ML" "Go & Rust" "Containers" "Browsers" "Homebrew" ".NET" "System" "Agents" "Other")

ask() { # question default(y|n): 0 for yes
  local a d="${2:-n}" hint="[y/N]"
  [ "$d" = y ] && hint="[Y/n]"
  printf '%s %s%s%s ' "$1" "$C_DIM" "$hint" "$C_0"
  read -r a || a=""
  [ -z "$a" ] && a="$d"
  case "$a" in y | Y | yes | YES) return 0 ;; esac
  return 1
}
step() { printf '\n%s%s%s  %s%s%s\n\n' "$C_B$C_P" "$1" "$C_0" "$C_B" "$2" "$C_0"; }
note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_0"; }

before=$(free_kb)
printf '\n  %s(%s)%s  %sdisk-jockey%s %s%s   free %s%s\n' "$C_P" "o" "$C_0" "$C_B" "$C_0" "$C_DIM" "$RD_VERSION" "$(human "$before")" "$C_0"

# ---------------------------------------------------------------- 1. preflight
step "1/4" "Preflight: is it really files?"
FORCE_COLOR=${C_0:+1} bash "$D/preflight.sh"
pf=$(NO_COLOR=1 bash "$D/preflight.sh" --tsv)
warn() { printf '%s\n' "$pf" | awk -F'\t' -v k="$1" '$1=="WARN" && $2==k {f=1} END{exit !f}'; }
value() { printf '%s\n' "$pf" | awk -F'\t' -v k="$1" '$2==k {print $3}'; }

if warn booted-simulators && have xcrun; then
  ask "Shut down all simulators now? They keep their data." && xcrun simctl shutdown all && printf '%sSimulators shut down.%s\n' "$C_G" "$C_0"
fi
if warn jvm-daemons; then
  if [ "$(value active-builds)" = 0 ]; then
    ask "Stop idle Gradle and Kotlin daemons? They restart on the next build." &&
      { pkill -f GradleDaemon; pkill -f KotlinCompileDaemon; printf '%sDaemons stopped.%s\n' "$C_G" "$C_0"; }
  else
    note "Builds are running, so daemons are left alone."
  fi
fi
reboot_hint=0
warn swap && reboot_hint=1
warn os-update-snapshots && reboot_hint=1

# ---------------------------------------------------------------- 2. categories
step "2/4" "Pick what to clear"
note "Sizing caches..."
rows=$(NO_COLOR=1 bash "$D/scan.sh" --tsv 2>/dev/null | tail -n +3)

n=${#CATS[@]}
t1=() t2=() t3=() ids1=() ids2=() state=()
i=0
while [ $i -lt "$n" ]; do t1[i]=0; t2[i]=0; t3[i]=0; ids1[i]=""; ids2[i]=""; state[i]=0; i=$((i + 1)); done
cat_index() { local k=0; while [ $k -lt "$n" ]; do [ "${CATS[k]}" = "$1" ] && { echo $k; return; }; k=$((k + 1)); done; echo $((n - 1)); }

while IFS=$'\t' read -r kb tier id status _; do
  [ -n "$id" ] || continue
  c=$(cat_index "$(category_of "$id")")
  case "$tier" in
    1) t1[c]=$((t1[c] + kb)); ids1[c]="${ids1[c]},$id" ;;
    2) t2[c]=$((t2[c] + kb)); ids2[c]="${ids2[c]},$id" ;;
    *) t3[c]=$((t3[c] + kb)) ;;
  esac
done <<EOF
$rows
EOF

# Categories with anything to show; safe caches preselected.
shown=()
i=0
while [ $i -lt "$n" ]; do
  if [ $((t1[i] + t2[i] + t3[i])) -gt 0 ] || [ -n "${ids1[i]}${ids2[i]}" ]; then
    shown+=("$i")
    [ -n "${ids1[i]}" ] && state[i]=1
  fi
  i=$((i + 1))
done
if [ "${#shown[@]}" -eq 0 ]; then
  note "No known caches found."
fi

mark() {
  case "$1" in
    0) printf '%s[ ]%s' "$C_DIM" "$C_0" ;;
    1) printf '%s[x]%s' "$C_B$C_G" "$C_0" ;;
    2) printf '%s[+]%s' "$C_B$C_Y" "$C_0" ;;
    *) printf '%s ' '' ;;
  esac
}
cell() { # kb ids -> size, "tool" for tool-managed caches with no measurable size, "-" for nothing
  if [ "$1" -gt 0 ]; then human "$1"; elif [ -n "$2" ]; then printf 'tool'; else printf -- '-'; fi
}

# Allowed states per category: 0 skip, 1 safe caches, 2 safe + rebuild-cost items.
allowed() { # c state -> 0 if that state exists for the category
  case "$2" in
    0) return 0 ;;
    1) [ -n "${ids1[$1]}" ] ;;
    2) [ -n "${ids2[$1]}" ] ;;
    *) return 1 ;;
  esac
}
# Move a category's state. dir=1 forward, -1 back; wrap=1 cycles (space), wrap=0 stops at the ends (arrows).
step_state() { # c dir wrap
  local c="$1" s="${state[$1]}" i
  for i in 1 2 3; do
    s=$((s + $2))
    if [ "$3" = 1 ]; then
      s=$(( (s + 3) % 3 ))
    elif [ "$s" -lt 0 ] || [ "$s" -gt 2 ]; then
      return
    fi
    allowed "$c" "$s" && break
  done
  state[c]=$s
}
set_all() { # safe | rebuild | none
  local c
  for c in "${shown[@]}"; do
    case "$1" in
      none) state[c]=0 ;;
      safe) if allowed "$c" 1; then state[c]=1; else state[c]=0; fi ;;
      rebuild) if allowed "$c" 2; then state[c]=2; elif allowed "$c" 1; then state[c]=1; fi ;;
    esac
  done
}
selected_kb() {
  local c sel=0
  for c in "${shown[@]}"; do
    [ "${state[c]}" -ge 1 ] && sel=$((sel + t1[c]))
    [ "${state[c]}" -ge 2 ] && sel=$((sel + t2[c]))
  done
  echo "$sel"
}

# --- Fallback picker: typed numbers. Used when keys can't be read one at a time (pipes, TERM=dumb).
draw() {
  local k=1 c
  printf '%s      %-3s  %-20s %-9s %-9s %-9s%s\n' "$C_DIM" "" "CATEGORY" "SAFE" "REBUILD" "KEEP" "$C_0"
  for c in "${shown[@]}"; do
    if [ -z "${ids1[c]}${ids2[c]}" ]; then
      printf '  %2d  %s  %s %s %s %s\n' "$k" "$(paint "$C_DIM" 3 " -")" "$(paint "$C_DIM" 20 "${CATS[c]}")" \
        "$(paint "$C_DIM" 9 -)" "$(paint "$C_DIM" 9 -)" "$(paint "$C_DIM" 9 "$(cell "${t3[c]}" "")")"
    else
      printf '  %2d  %s  %s %s %s %s\n' "$k" "$(mark "${state[c]}")" "$(paint "" 20 "${CATS[c]}")" \
        "$(paint "$C_G" 9 "$(cell "${t1[c]}" "${ids1[c]}")")" "$(paint "$C_Y" 9 "$(cell "${t2[c]}" "${ids2[c]}")")" "$(paint "$C_DIM" 9 "$(cell "${t3[c]}" "")")"
    fi
    k=$((k + 1))
  done
  printf '\n  Selected: %s%s%s\n' "$C_B$C_G" "$(human "$(selected_kb)")" "$C_0"
  note "  [x] safe caches   [+] safe + rebuild cost   KEEP is report-only and never deleted"
  note "  Type a number to cycle it, a = all safe, r = all incl. rebuild, n = none, Enter = continue, q = quit"
}
pick_numbers() {
  local choice num c
  while :; do
    draw
    printf '  > '
    read -r choice || choice=""
    case "$choice" in
      "") return 0 ;;
      q | Q) return 1 ;;
      a | A) set_all safe ;;
      r | R) set_all rebuild ;;
      n | N) set_all none ;;
      *)
        for num in $choice; do
          case "$num" in *[!0-9]* | "") continue ;; esac
          [ "$num" -ge 1 ] && [ "$num" -le "${#shown[@]}" ] || continue
          c=${shown[num - 1]}
          [ -z "${ids1[c]}${ids2[c]}" ] && continue
          step_state "$c" 1 1
          [ -n "${RD_DEBUG_PICKER:-}" ] && log "DEBUG num=$num c=$c shown=(${shown[*]}) state=(${state[*]})"
        done
        ;;
    esac
    printf '\n'
  done
}

# --- Default picker: arrow keys + space, redrawn in place (like installer CLIs).
pick_arrows() {
  local rows=() keep="" c cur=0 key rest lines=0 i
  for c in "${shown[@]}"; do
    if [ -n "${ids1[c]}${ids2[c]}" ]; then
      rows+=("$c")
    elif [ "${t3[c]}" -gt 0 ]; then
      keep="$keep${keep:+, }${CATS[c]} $(human "${t3[c]}")"
    fi
  done
  [ "${#rows[@]}" -gt 0 ] || return 0
  printf '\033[?25l'
  trap 'printf "\033[?25h"' EXIT
  trap 'printf "\033[?25h\n"; echo "Nothing changed."; exit 130' INT

  render() {
    [ "$lines" -gt 0 ] && printf '\033[%dA' "$lines"
    lines=0
    printf '\033[2K%s      %-20s %-9s %-9s %s%s\n' "$C_DIM" "CATEGORY" "SAFE" "REBUILD" "KEEP" "$C_0"
    lines=$((lines + 1))
    for i in "${!rows[@]}"; do
      c=${rows[i]}
      local ptr=" " name
      name=$(paint "" 20 "${CATS[c]}")
      if [ "$i" = "$cur" ]; then ptr="${C_P}>${C_0}"; name=$(paint "$C_B" 20 "${CATS[c]}"); fi
      printf '\033[2K  %s %s %s %s %s %s\n' "$ptr" "$(mark "${state[c]}")" "$name" \
        "$(paint "$C_G" 9 "$(cell "${t1[c]}" "${ids1[c]}")")" "$(paint "$C_Y" 9 "$(cell "${t2[c]}" "${ids2[c]}")")" \
        "$(paint "$C_DIM" 9 "$(cell "${t3[c]}" "")")"
      lines=$((lines + 1))
    done
    printf '\033[2K\n'
    printf '\033[2K  Selected: %s%s%s\n' "$C_B$C_G" "$(human "$(selected_kb)")" "$C_0"
    printf '\033[2K  %s[x] safe caches  [+] also rebuild-cost items  [ ] skip%s\n' "$C_DIM" "$C_0"
    printf '\033[2K  %sup/down move   space toggle   left/right less/more%s\n' "$C_DIM" "$C_0"
    printf '\033[2K  %sa all safe   r all + rebuild   n none   enter continue   q quit%s\n' "$C_DIM" "$C_0"
    lines=$((lines + 5))
  }
  if [ -n "$keep" ]; then
    note "  Report only (never deleted): $keep"
    echo
  fi
  render
  while :; do
    IFS= read -rsn1 key || key=q
    case "$key" in
      $'\033')
        rest=""
        IFS= read -rsn2 -t 1 rest
        case "$rest" in
          '[A' | 'OA') [ "$cur" -gt 0 ] && cur=$((cur - 1)) ;;
          '[B' | 'OB') [ "$cur" -lt $((${#rows[@]} - 1)) ] && cur=$((cur + 1)) ;;
          '[C' | 'OC') step_state "${rows[cur]}" 1 0 ;;
          '[D' | 'OD') step_state "${rows[cur]}" -1 0 ;;
        esac
        ;;
      k | K) [ "$cur" -gt 0 ] && cur=$((cur - 1)) ;;
      j | J) [ "$cur" -lt $((${#rows[@]} - 1)) ] && cur=$((cur + 1)) ;;
      l | L) step_state "${rows[cur]}" 1 0 ;;
      h | H) step_state "${rows[cur]}" -1 0 ;;
      ' ' | x | X) step_state "${rows[cur]}" 1 1; [ -n "${RD_DEBUG_PICKER:-}" ] && log "DEBUG space cur=$cur rows=(${rows[*]}) state=(${state[*]})" ;;
      a | A) set_all safe ;;
      r | R) set_all rebuild ;;
      n | N) set_all none ;;
      '' | $'\r') printf '\033[?25h'; return 0 ;;
      q | Q) printf '\033[?25h'; return 1 ;;
    esac
    render
  done
}

[ -n "${RD_DEBUG_PICKER:-}" ] && log "DEBUG built shown=(${shown[*]}) state=(${state[*]}) ids1=(${ids1[*]}) ids2=(${ids2[*]})"
if [ "${#shown[@]}" -gt 0 ]; then
  menu="${RD_MENU:-}"
  if [ -z "$menu" ]; then
    if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then menu=arrows; else menu=numbers; fi
  fi
  if [ "$menu" = arrows ]; then pick_arrows; else pick_numbers; fi || { echo "Nothing changed."; exit 0; }
fi

only="" planned=0
for c in "${shown[@]}"; do
  [ "${state[c]}" -ge 1 ] && only="$only${ids1[c]}" && planned=$((planned + t1[c]))
  [ "${state[c]}" -ge 2 ] && only="$only${ids2[c]}" && planned=$((planned + t2[c]))
done
only="${only#,}"

# ---------------------------------------------------------------- 3. worktrees + idle projects
step "3/4" "Agent worktrees and idle projects"
do_wt=0 do_sweep=0 wt_paths=() wt_review=0
fit() { # text width -> text cut to width (with "~" marker)
  if [ "${#1}" -le "$2" ]; then printf '%s' "$1"; else printf '%s~' "${1:0:$(($2 - 1))}"; fi
}
short_path() { # last two path components
  local p="${1%/}"
  printf '%s/%s' "$(basename "$(dirname "$p")")" "$(basename "$p")"
}

# Worktree rows from worktrees.sh --tsv. Selectable: REMOVABLE (preselected) and REVIEW (opt-in).
w_state=() w_kb=() w_branch=() w_path=() w_dirty=() w_uniq=() w_sel=() w_ok=()
pick_worktrees() {
  local tsv state kb branch path dirty uniq detail n=0 others=""
  tsv=$(NO_COLOR=1 bash "$D/worktrees.sh" --tsv 2>/dev/null | tail -n +2)
  while IFS=$'\t' read -r state kb branch path dirty uniq detail; do
    [ -n "$state" ] || continue
    case "$state" in
      REMOVABLE | REVIEW) ;;
      *) others="$others $state"; continue ;;
    esac
    w_state[n]=$state w_kb[n]=$kb w_branch[n]=$branch w_path[n]=$path w_dirty[n]=$dirty w_uniq[n]=$uniq
    w_ok[n]=1 w_sel[n]=0
    [ "$state" = REMOVABLE ] && w_sel[n]=1
    # Detached worktrees with local commits: removing them would orphan the commits.
    [ "$state" = REVIEW ] && [ "$branch" = "(detached)" ] && [ "$uniq" != 0 ] && w_ok[n]=0
    n=$((n + 1))
  done <<EOF
$tsv
EOF
  local summary=""
  for state in ACTIVE IN-USE LOCKED; do
    local cnt
    cnt=$(printf '%s\n' $others | grep -cx "$state")
    [ "$cnt" -gt 0 ] && summary="$summary${summary:+, }$cnt $(printf '%s' "$state" | tr 'A-Z' 'a-z')"
  done
  if [ "$n" = 0 ]; then
    note "No worktrees to remove${summary:+ ($summary, all kept)}."
    return 0
  fi
  [ -n "$summary" ] && note "  Kept automatically: $summary."

  local cols; cols=$(tput cols 2>/dev/null || echo 100)
  [ "$cols" -gt 140 ] && cols=140
  wt_row() { # index -> row text without pointer/mark
    local k="$1" det
    if [ "${w_state[k]}" = REVIEW ]; then
      det="${w_dirty[k]} uncommitted, ${w_uniq[k]} local commit(s)"
      [ "${w_ok[k]}" = 0 ] && det="detached, ${w_uniq[k]} commit(s) on no branch: kept"
    else
      det=""
    fi
    printf '%s %s %s %s' "$(paint "$C_B" 7 "$(human "${w_kb[k]}")")" \
      "$(paint "$([ "${w_state[k]}" = REVIEW ] && printf '%s' "$C_Y" || printf '%s' "$C_G")" 9 "${w_state[k]}")" \
      "$(paint "" 26 "$(fit "${w_branch[k]}" 26)")" \
      "$C_DIM$(fit "$(short_path "${w_path[k]}")${det:+  $det}" $((cols - 52)))$C_0"
  }
  wt_mark() {
    if [ "${w_ok[$1]}" = 0 ]; then printf '%s - %s' "$C_DIM" "$C_0"
    elif [ "${w_sel[$1]}" = 1 ]; then
      if [ "${w_state[$1]}" = REVIEW ]; then printf '%s[!]%s' "$C_B$C_Y" "$C_0"; else printf '%s[x]%s' "$C_B$C_G" "$C_0"; fi
    else printf '%s[ ]%s' "$C_DIM" "$C_0"; fi
  }
  wt_total() { local k t=0; for k in "${!w_sel[@]}"; do [ "${w_sel[k]}" = 1 ] && t=$((t + w_kb[k])); done; echo "$t"; }
  wt_set() { # removable | none
    local k
    for k in "${!w_sel[@]}"; do
      case "$1" in
        none) w_sel[k]=0 ;;
        removable) if [ "${w_state[k]}" = REMOVABLE ]; then w_sel[k]=1; else w_sel[k]=0; fi ;;
      esac
    done
  }
  wt_toggle() { [ "${w_ok[$1]}" = 1 ] && w_sel[$1]=$((1 - w_sel[$1])); }

  local menu="${RD_MENU:-}"
  if [ -z "$menu" ]; then
    if [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then menu=arrows; else menu=numbers; fi
  fi

  if [ "$menu" = numbers ]; then
    local choice num k
    while :; do
      for k in "${!w_state[@]}"; do printf '  %2d  %s  %s\n' $((k + 1)) "$(wt_mark "$k")" "$(wt_row "$k")"; done
      printf '\n  Selected: %s%s%s\n' "$C_B$C_G" "$(human "$(wt_total)")" "$C_0"
      note "  [x] remove   [!] remove and discard its uncommitted changes   [ ] keep"
      note "  Type numbers to toggle, a = all REMOVABLE, n = none, Enter = continue, q = quit"
      printf '  > '
      read -r choice || choice=""
      case "$choice" in
        "") break ;;
        q | Q) return 1 ;;
        a | A) wt_set removable ;;
        n | N) wt_set none ;;
        *) for num in $choice; do
             case "$num" in *[!0-9]* | "") continue ;; esac
             [ "$num" -ge 1 ] && [ "$num" -le "$n" ] && wt_toggle $((num - 1))
           done ;;
      esac
      printf '\n'
    done
  else
    local cur=0 top=0 key rest lines=0 vis k
    vis=$(( $(tput lines 2>/dev/null || echo 24) - 14 ))
    [ "$vis" -lt 5 ] && vis=5
    [ "$vis" -gt "$n" ] && vis=$n
    printf '\033[?25l'
    trap 'printf "\033[?25h"' EXIT
    wt_render() {
      [ "$lines" -gt 0 ] && printf '\033[%dA' "$lines"
      lines=0
      [ "$cur" -lt "$top" ] && top=$cur
      [ "$cur" -ge $((top + vis)) ] && top=$((cur - vis + 1))
      if [ "$top" -gt 0 ]; then printf '\033[2K  %s  ^ %d more%s\n' "$C_DIM" "$top" "$C_0"; else printf '\033[2K\n'; fi
      lines=1
      for ((k = top; k < top + vis; k++)); do
        local ptr=" "
        [ "$k" = "$cur" ] && ptr="${C_P}>${C_0}"
        printf '\033[2K  %s %s %s\n' "$ptr" "$(wt_mark "$k")" "$(wt_row "$k")"
        lines=$((lines + 1))
      done
      if [ $((top + vis)) -lt "$n" ]; then printf '\033[2K  %s  v %d more%s\n' "$C_DIM" $((n - top - vis)) "$C_0"; else printf '\033[2K\n'; fi
      printf '\033[2K  Selected: %s%s%s\n' "$C_B$C_G" "$(human "$(wt_total)")" "$C_0"
      printf '\033[2K  %s[x] remove   [!] remove, discarding uncommitted changes   [ ] keep%s\n' "$C_DIM" "$C_0"
      printf '\033[2K  %sup/down move   space toggle   a all REMOVABLE   n none   enter continue   q quit%s\n' "$C_DIM" "$C_0"
      lines=$((lines + 4))
    }
    wt_render
    while :; do
      IFS= read -rsn1 key || key=q
      case "$key" in
        $'\033')
          rest=""
          IFS= read -rsn2 -t 1 rest
          case "$rest" in
            '[A' | 'OA') [ "$cur" -gt 0 ] && cur=$((cur - 1)) ;;
            '[B' | 'OB') [ "$cur" -lt $((n - 1)) ] && cur=$((cur + 1)) ;;
          esac
          ;;
        k | K) [ "$cur" -gt 0 ] && cur=$((cur - 1)) ;;
        j | J) [ "$cur" -lt $((n - 1)) ] && cur=$((cur + 1)) ;;
        ' ' | x | X) wt_toggle "$cur" ;;
        a | A) wt_set removable ;;
        n | N) wt_set none ;;
        '' | $'\r') printf '\033[?25h'; break ;;
        q | Q) printf '\033[?25h'; return 1 ;;
      esac
      wt_render
    done
  fi

  # Opting into REVIEW worktrees deletes work that exists only there: confirm explicitly.
  local k reviews=""
  for k in "${!w_sel[@]}"; do
    [ "${w_sel[k]}" = 1 ] && [ "${w_state[k]}" = REVIEW ] &&
      reviews="$reviews    ${w_branch[k]}  (${w_dirty[k]} uncommitted, ${w_uniq[k]} local commit(s))"$'\n'
  done
  if [ -n "$reviews" ]; then
    echo
    printf '  %sThese worktrees have work that exists nowhere else:%s\n%s' "$C_B$C_Y" "$C_0" "$reviews"
    echo "  Uncommitted changes will be permanently deleted. Local commits stay on their branches."
    printf '  Type %syes%s to include them: ' "$C_B" "$C_0"
    local answer; read -r answer || answer=""
    if [ "$answer" != yes ]; then
      for k in "${!w_sel[@]}"; do [ "${w_state[k]}" = REVIEW ] && w_sel[k]=0; done
      note "  Keeping them. REMOVABLE selections stand."
    fi
  fi
  for k in "${!w_sel[@]}"; do
    if [ "${w_sel[k]}" = 1 ]; then
      wt_paths+=("${w_path[k]}")
      [ "${w_state[k]}" = REVIEW ] && wt_review=$((wt_review + 1))
    fi
  done
  [ "${#wt_paths[@]}" -gt 0 ] && do_wt=1
  return 0
}

if [ -n "$(default_roots)" ]; then
  pick_worktrees || { echo "Nothing changed."; exit 0; }
  sw=$(NO_COLOR=1 bash "$D/sweep.sh" 2>/dev/null | tail -1)
  case "$sw" in
    "Would remove 0K"*) note "No build outputs in idle projects." ;;
    *) printf '%s\n' "$sw" | sed 's/ Re-run with --apply\.//'; ask "Clear them?" && do_sweep=1 ;;
  esac
else
  note "No project folders found (set RD_ROOTS=dir1:dir2 to point at yours)."
fi

# ---------------------------------------------------------------- 4. apply
step "4/4" "Apply"
if [ -z "$only" ] && [ "$do_wt" = 0 ] && [ "$do_sweep" = 0 ]; then
  echo "Nothing selected. Nothing changed."
  exit 0
fi
[ -n "$only" ] && echo "  Caches: about $C_B$(human "$planned")$C_0 across $(printf '%s' "$only" | tr ',' '\n' | grep -c .) targets"
if [ "$do_wt" = 1 ]; then
  if [ "$wt_review" -gt 0 ]; then
    echo "  Worktrees: ${#wt_paths[@]} ($wt_review discarding uncommitted changes)"
  else
    echo "  Worktrees: ${#wt_paths[@]}"
  fi
fi
[ "$do_sweep" = 1 ] && echo "  Idle project build outputs"
echo
ask "Go?" || { echo "Nothing changed."; exit 0; }

[ -n "$only" ] && bash "$D/clean.sh" --apply --tier 2 --only "$only"
if [ "$do_wt" = 1 ]; then
  sel_args=()
  for p in "${wt_paths[@]}"; do sel_args+=(--select "$p"); done
  FORCE_COLOR=${C_0:+1} bash "$D/worktrees.sh" --apply "${sel_args[@]}" 2>/dev/null | grep -E 'removed|refused|left in place|linked'
fi
[ "$do_sweep" = 1 ] && FORCE_COLOR=${C_0:+1} bash "$D/sweep.sh" --apply 2>/dev/null | tail -1

after=$(free_kb)
printf '\n  %sFree: %s -> %s (+%s)%s\n' "$C_B$C_G" "$(human "$before")" "$(human "$after")" "$(human $((after - before)))" "$C_0"
[ "$reboot_hint" = 1 ] && note "  Reboot when convenient: it deletes swap files and releases snapshot-pinned space."

if bash "$D/schedule.sh" status 2>/dev/null | grep -qi 'not installed'; then
  echo
  ask "Keep the floor clear with a daily safe-cache cleanup when free space drops below 50G?" &&
    bash "$D/schedule.sh" install --threshold 50G
fi
exit 0
