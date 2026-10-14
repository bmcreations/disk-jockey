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
say "[$mode] $(date '+%Y-%m-%d %H:%M') tiers <= $max_tier, free $(human "$before")"

planned=0 failures=0
while IFS='|' read -r tier id os paths action busy note; do
  [ "$tier" -le "$max_tier" ] || continue
  [ -n "$only" ] && case "$only" in *",$id,"*) ;; *) continue ;; esac
  [ -n "$skip" ] && case "$skip" in *",$id,"*) continue ;; esac
  [ "$action" = report ] && continue

  case "$action" in
    cmd:*)
      c="${action#cmd:}"
      have "${c%% *}" || continue
      if is_busy "$busy"; then say "  skip  $id (busy: matches '$busy')"; continue; fi
      kb=$(expand_paths "$paths" | size_kb)
      planned=$((planned + kb))
      say "  run   $id: $c  (~$(human "$kb"))"
      if [ "$apply" = 1 ]; then
        if ! eval "$c" </dev/null >/dev/null 2>&1; then
          say "        failed: $c"
          failures=$((failures + 1))
        fi
      fi
      ;;
    *)
      matches=$(target_matches "$paths" "$action")
      [ -n "$matches" ] || continue
      if is_busy "$busy"; then say "  skip  $id (busy: matches '$busy')"; continue; fi
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        if ! safe_to_delete "$m"; then
          say "  guard $m (protected path or symlink, skipped)"
          continue
        fi
        kb=$(printf '%s\n' "$m" | size_kb)
        planned=$((planned + kb))
        say "  rm    $(human "$kb")  $m  [$id]"
        if [ "$apply" = 1 ]; then
          rm -rf -- "$m" 2>/dev/null || { say "        failed: $m"; failures=$((failures + 1)); }
        fi
      done <<EOF
$matches
EOF
      ;;
  esac
done < <(each_target)

if [ "$apply" = 1 ]; then
  after=$(free_kb)
  freed=$((after - before))
  say "Freed $(human "$freed") (estimated $(human "$planned")). Free now $(human "$after")."
  if is_mac && [ "$freed" -lt $((planned / 2)) ]; then
    say "Less than expected: APFS snapshots or purgeable space may be holding it. Check: tmutil listlocalsnapshots /"
  fi
  [ "$failures" -gt 0 ] && exit 1
else
  say "Would reclaim ~$(human "$planned"). Re-run with --apply to delete."
fi
exit 0
