#!/usr/bin/env bash
# Tiered cleanup of targets.conf. Dry-run unless --apply. Tier 3 is never deleted.
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'EOF'
Usage: clean.sh [options]
  --tier N               highest tier to act on (1 or 2, default 1)
  --apply                actually delete (default is a dry run)
  --only id1,id2         only these target ids
  --skip id1,id2         skip these target ids
  --if-free-below SIZE   exit without doing anything unless free space < SIZE (e.g. 50G)
  --quarantine           move to quarantine instead of deleting (undo with: disk-jockey quarantine restore)
  --no-quarantine        delete directly even when quarantine is on
  -q, --quiet            no output except errors
EOF
}

max_tier=1 apply=0 only="" skip="" threshold="" quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) max_tier="$2"; shift ;;
    --apply) apply=1 ;;
    --only) only=",$2,"; shift ;;
    --skip) skip=",$2,"; shift ;;
    --if-free-below) threshold="$2"; shift ;;
    --quarantine) export RD_QUARANTINE=1 ;;
    --no-quarantine) export RD_QUARANTINE=0 ;;
    -q | --quiet) quiet=1 ;;
    -h | --help) usage; exit 0 ;;
    *) log "unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done
if [ "$max_tier" -gt 2 ]; then
  log "Tier 3 is report-only. Capping at tier 2."
  max_tier=2
fi

say() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }

before=$(free_kb)
if [ -n "$threshold" ] && [ "$before" -ge "$(to_kb "$threshold")" ]; then
  say "Free $(human "$before") >= $threshold. Nothing to do."
  exit 0
fi

mode=DRY-RUN
[ "$apply" = 1 ] && mode=APPLY
mc="$C_C"
[ "$apply" = 1 ] && mc="$C_P"
say "${C_B}${mc}[$mode]$C_0 $(date '+%Y-%m-%d %H:%M') tiers <= $max_tier, free $(human "$before")"
quar=0
if q_enabled; then
  quar=1
  say "${C_DIM}Quarantine on: items move to $(tilde "$RD_QDIR") for $(q_days)d instead of being deleted.$C_0"
fi
if [ "$apply" = 1 ]; then
  purged=$(q_purge_expired)
  [ -n "$purged" ] && say "$purged"
fi

planned=0 failures=0 kept=0 skipped_cmd=0
while IFS='|' read -r tier id os paths action busy note; do
  [ "$tier" -le "$max_tier" ] || continue
  [ -n "$only" ] && case "$only" in *",$id,"*) ;; *) continue ;; esac
  [ -n "$skip" ] && case "$skip" in *",$id,"*) continue ;; esac
  [ "$action" = report ] && continue

  case "$action" in
    cmd:*)
      [ "${RD_NO_CMD:-}" = 1 ] && continue
      c="${action#cmd:}"
      tool_ready "${c%% *}" || continue
      # A tool's own clean command can't be undone.
      if [ "$quar" = 1 ]; then skipped_cmd=$((skipped_cmd + 1)); continue; fi
      if is_busy "$busy"; then say "  ${C_Y}skip$C_0  $id ${C_DIM}(busy: $RD_BUSY_BY matches '$busy')$C_0"; continue; fi
      kb=$(expand_paths "$paths" | size_kb)
      planned=$((planned + kb))
      say "  ${C_C}run$C_0   $id: $c  $C_DIM(~$(human "$kb"))$C_0"
      if [ "$apply" = 1 ]; then
        if ! eval "$c" </dev/null >/dev/null 2>&1; then
          say "        ${C_R}failed:$C_0 $c"
          failures=$((failures + 1))
        fi
      fi
      ;;
    *)
      matches=$(target_matches "$paths" "$action")
      [ -n "$matches" ] || continue
      if is_busy "$busy"; then say "  ${C_Y}skip$C_0  $id ${C_DIM}(busy: $RD_BUSY_BY matches '$busy')$C_0"; continue; fi
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        if ! safe_to_delete "$m"; then
          say "  ${C_M}guard$C_0 $(tilde "$m") ${C_DIM}(protected path or symlink, skipped)$C_0"
          continue
        fi
        kb=$(printf '%s\n' "$m" | size_kb)
        planned=$((planned + kb))
        verb="${C_P}rm$C_0   "
        [ "$quar" = 1 ] && verb="${C_M}hold$C_0 "
        say "  $verb $C_B$(human "$kb")$C_0  $(tilde "$m")  ${C_DIM}[$id]$C_0"
        if [ "$apply" = 1 ] && ! remove_path "$m" "clean:$id" "$kb"; then
          if [ -n "${RD_Q_ERR:-}" ]; then
            say "        ${C_Y}kept:$C_0 $RD_Q_ERR"
            kept=$((kept + 1)); planned=$((planned - kb))
          else
            say "        ${C_R}failed:$C_0 $(tilde "$m")"
            failures=$((failures + 1))
          fi
        fi
      done <<EOF
$matches
EOF
      ;;
  esac
done < <(each_target)

[ "$skipped_cmd" -gt 0 ] && say "${C_DIM}Skipped $skipped_cmd tool-run cleanup(s) (npm, brew, ...): they can't be undone. Add --no-quarantine to include them.$C_0"
if [ "$quar" = 1 ]; then
  if [ "$apply" = 1 ]; then
    say "${C_B}${C_M}Moved $(human "$planned") to quarantine.$C_0 Space returns when it's purged: after $(q_days)d, or now with disk-jockey quarantine purge --all."
    say "${C_DIM}Undo: disk-jockey quarantine restore --last (or list, then restore ID).$C_0"
    [ "$failures" -gt 0 ] && exit 1
  else
    say "${C_B}${C_G}Would move ~$(human "$planned") to quarantine.$C_0 Re-run with --apply."
  fi
  exit 0
fi
if [ "$apply" = 1 ]; then
  after=$(free_kb)
  freed=$((after - before))
  say "${C_B}${C_G}Freed $(human "$freed")$C_0 (estimated $(human "$planned")). Free now $(human "$after")."
  if is_mac && [ "$freed" -lt $((planned / 2)) ]; then
    say "${C_Y}Less than expected:$C_0 APFS snapshots or purgeable space may be holding it. Check: tmutil listlocalsnapshots /"
  fi
  [ "$failures" -gt 0 ] && exit 1
else
  say "${C_B}${C_G}Would reclaim ~$(human "$planned").$C_0 Re-run with --apply to delete."
fi
exit 0
