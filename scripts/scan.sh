#!/usr/bin/env bash
# Read-only. Reports reclaimable space per target, grouped by tier. Deletes nothing.
# Usage: scan.sh [--tsv]
. "$(dirname "$0")/lib.sh"

fmt=table
[ "${1:-}" = "--tsv" ] && fmt=tsv

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
log "Scanning targets (du over large caches can take a minute)..."

while IFS='|' read -r tier id os paths action busy note; do
  status=ok
  case "$action" in
    cmd:*)
      c="${action#cmd:}"
      have "${c%% *}" || continue
      ;;
  esac
  kb=$(target_matches "$paths" "$action" | size_kb)
  if [ "$kb" -eq 0 ]; then
    case "$action" in cmd:*) [ "$paths" = "-" ] || continue ;; *) continue ;; esac
  fi
  is_busy "$busy" && status=busy
  printf '%s\t%s\t%s\t%s\t%s\n' "$kb" "$tier" "$id" "$status" "$note" >>"$tmp"
done < <(each_target)

free=$(free_kb)
if [ "$fmt" = tsv ]; then
  printf 'free_kb\t%s\n' "$free"
  printf 'kb\ttier\tid\tstatus\tnote\n'
  sort -t$'\t' -k1,1nr "$tmp"
  exit 0
fi

printf 'Free: %s on %s\n\n' "$(human "$free")" "$HOME"
printf '%-4s %-8s %-24s %-6s %s\n' TIER SIZE ID STATUS NOTE
sort -t$'\t' -k1,1nr "$tmp" | while IFS=$'\t' read -r kb tier id status note; do
  sz=$(human "$kb")
  [ "$kb" -eq 0 ] && sz="(tool)"
  printf '%-4s %-8s %-24s %-6s %s\n' "$tier" "$sz" "$id" "$status" "$note"
done

echo
for t in 1 2 3; do
  tot=$(awk -F'\t' -v t="$t" '$2==t{s+=$1} END{print s+0}' "$tmp")
  case $t in
    1) label="tier 1 (safe caches)" ;;
    2) label="tier 2 (re-download/rebuild cost)" ;;
    3) label="tier 3 (report only, human decides)" ;;
  esac
  printf '%-38s %s\n' "$label" "$(human "$tot")"
done

echo
echo "Free space dropping on its own, or less freed than expected? Run preflight.sh (swap, simulators, snapshots)."
echo "Next: worktrees.sh (agent worktrees) and sweep.sh (build outputs in idle projects)."
