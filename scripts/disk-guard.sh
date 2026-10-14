#!/usr/bin/env bash
# Prints a warning when free space is below a threshold. Always exits 0.
# Meant for agent SessionStart hooks and shell prompts. Usage: disk-guard.sh [SIZE]  (default 20G or $RD_MIN_FREE)
. "$(dirname "$0")/lib.sh"

min="${1:-${RD_MIN_FREE:-20G}}"
f=$(free_kb)
if [ -n "$f" ] && [ "$f" -lt "$(to_kb "$min")" ]; then
  echo "LOW DISK: $(human "$f") free on $HOME (threshold $min). Builds, simulators and new worktrees may fail with 'No space left on device'. Run the disk-jockey skill (scripts/scan.sh) before heavy work."
fi
exit 0
