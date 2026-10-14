#!/usr/bin/env bash
# Interactive mode for humans: preflight fixes, pick categories, review worktrees, apply.
# Agents and automation should call scan.sh / clean.sh / worktrees.sh / sweep.sh directly.
. "$(dirname "$0")/lib.sh"
D="$RD_DIR"

if [ ! -t 1 ] && [ -z "${RD_ALLOW_PIPE:-}" ]; then
  log "dj.sh is interactive. For agents and scripts use scan.sh, clean.sh, worktrees.sh and sweep.sh."
  exit 2
fi

CATS=("Xcode & Simulators" "Android & JVM" "IDEs" "JavaScript" "Python & ML" "Go & Rust" "Containers" "Browsers" "Homebrew" "System" "Agents" "Other")

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
printf '\n  %s(%s)%s  %sdisk-jockey%s   %sfree %s%s\n' "$C_P" "o" "$C_0" "$C_B" "$C_0" "$C_DIM" "$(human "$before")" "$C_0"

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

draw() {
  local k=1 c sel=0 total=0
  printf '%s      %-3s  %-20s %-9s %-9s %-9s%s\n' "$C_DIM" "" "CATEGORY" "SAFE" "REBUILD" "KEEP" "$C_0"
  for c in "${shown[@]}"; do
    if [ -z "${ids1[c]}${ids2[c]}" ]; then
      printf '  %2d  %s  %s %s %s %s\n' "$k" "$(paint "$C_DIM" 3 " -")" "$(paint "$C_DIM" 20 "${CATS[c]}")" \
        "$(paint "$C_DIM" 9 -)" "$(paint "$C_DIM" 9 -)" "$(paint "$C_DIM" 9 "$(cell "${t3[c]}" "")")"
    else
      printf '  %2d  %s  %s %s %s %s\n' "$k" "$(mark "${state[c]}")" "$(paint "" 20 "${CATS[c]}")" \
        "$(paint "$C_G" 9 "$(cell "${t1[c]}" "${ids1[c]}")")" "$(paint "$C_Y" 9 "$(cell "${t2[c]}" "${ids2[c]}")")" "$(paint "$C_DIM" 9 "$(cell "${t3[c]}" "")")"
    fi
    [ "${state[c]}" -ge 1 ] && sel=$((sel + t1[c]))
    [ "${state[c]}" -ge 2 ] && sel=$((sel + t2[c]))
    k=$((k + 1))
  done
  total=$sel
  printf '\n  Selected: %s%s%s\n' "$C_B$C_G" "$(human "$total")" "$C_0"
  note "  [x] safe caches   [+] safe + rebuild cost   KEEP is report-only and never deleted"
  note "  Type a number to cycle it, a = all safe, r = all incl. rebuild, n = none, Enter = continue, q = quit"
}

while [ "${#shown[@]}" -gt 0 ]; do
  draw
  printf '  > '
  read -r choice || choice=""
  case "$choice" in
    "") break ;;
    q | Q) echo "Nothing changed."; exit 0 ;;
    a | A) for c in "${shown[@]}"; do [ -n "${ids1[c]}" ] && state[c]=1 || state[c]=0; done ;;
    r | R) for c in "${shown[@]}"; do if [ -n "${ids2[c]}" ]; then state[c]=2; elif [ -n "${ids1[c]}" ]; then state[c]=1; fi; done ;;
    n | N) for c in "${shown[@]}"; do state[c]=0; done ;;
    *)
      for num in $choice; do
        case "$num" in *[!0-9]* | "") continue ;; esac
        [ "$num" -ge 1 ] && [ "$num" -le "${#shown[@]}" ] || continue
        c=${shown[num - 1]}
        [ -z "${ids1[c]}${ids2[c]}" ] && continue
        next=$(((state[c] + 1) % 3))
        [ "$next" = 1 ] && [ -z "${ids1[c]}" ] && next=2
        [ "$next" = 2 ] && [ -z "${ids2[c]}" ] && next=0
        state[c]=$next
      done
      ;;
  esac
  printf '\n'
done

only="" planned=0
for c in "${shown[@]}"; do
  [ "${state[c]}" -ge 1 ] && only="$only${ids1[c]}" && planned=$((planned + t1[c]))
  [ "${state[c]}" -ge 2 ] && only="$only${ids2[c]}" && planned=$((planned + t2[c]))
done
only="${only#,}"

# ---------------------------------------------------------------- 3. worktrees + idle projects
step "3/4" "Agent worktrees and idle projects"
do_wt=0 do_sweep=0
if [ -n "$(default_roots)" ]; then
  wt=$(FORCE_COLOR=${C_0:+1} bash "$D/worktrees.sh" 2>/dev/null)
  printf '%s\n' "$wt" | sed -e '$d'
  removable=$(printf '%s\n' "$wt" | strip_ansi | grep -c '^REMOVABLE')
  if [ "$removable" -gt 0 ]; then
    ask "Remove the $removable REMOVABLE worktree(s)? Branches are kept." && do_wt=1
  else
    note "No worktrees safe to remove."
  fi
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
[ "$do_wt" = 1 ] && echo "  Worktrees: $removable"
[ "$do_sweep" = 1 ] && echo "  Idle project build outputs"
echo
ask "Go?" || { echo "Nothing changed."; exit 0; }

[ -n "$only" ] && bash "$D/clean.sh" --apply --tier 2 --only "$only"
[ "$do_wt" = 1 ] && FORCE_COLOR=${C_0:+1} bash "$D/worktrees.sh" --apply 2>/dev/null | grep -E 'removed|refused|linked'
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
