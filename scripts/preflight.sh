#!/usr/bin/env bash
# Read-only health check to run BEFORE deleting anything.
# Disk that "fills by itself" is often memory (swap) or snapshots, not files. Deleting caches won't fix those.
# Usage: preflight.sh [--tsv]
. "$(dirname "$0")/lib.sh"

tsv=0
[ "${1:-}" = "--tsv" ] && tsv=1
warns=0

row() { # level item value advice
  [ "$1" = WARN ] && warns=$((warns + 1))
  if [ "$tsv" = 1 ]; then
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
  else
    local lc="$C_G"
    case "$1" in WARN) lc="$C_Y" ;; INFO) lc="$C_C" ;; esac
    printf '%s %s %s %s\n' "$(paint "$C_B$lc" 5 "$1")" "$(paint "" 22 "$2")" "$(paint "$C_B" 18 "$3")" "$C_DIM$4$C_0"
  fi
}

[ "$tsv" = 1 ] && printf 'level\titem\tvalue\tadvice\n'

# --- Free space
free=$(free_kb)
total=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $2}')
pct=$((free * 100 / (total > 0 ? total : 1)))
if [ "$free" -lt $((20 * 1024 * 1024)) ] || [ "$pct" -lt 10 ]; then
  row WARN free-space "$(human "$free") (${pct}%)" "Below 20G or 10%: builds, simulators and swap start failing. Stop agents before cleanup."
else
  row OK free-space "$(human "$free") (${pct}%)" ""
fi

# --- CPU load
if is_mac; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null)
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
else
  cores=$(nproc 2>/dev/null)
  load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
fi
if [ -n "$load" ] && [ -n "$cores" ]; then
  if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c * 4)}'; then
    row WARN load "$load on $cores cores" "Processes are stalled (usually on disk I/O from swapping). Fix memory first."
  else
    row OK load "$load on $cores cores" ""
  fi
fi

# --- Swap (kernel_task's huge 'bytes written' in Activity Monitor is mostly this)
if is_mac; then
  swap_used=$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  swap_kb=$(awk -v m="${swap_used:-0}" 'BEGIN{printf "%d", m * 1024}')
else
  swap_kb=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print t-f}' /proc/meminfo 2>/dev/null)
fi
if [ "${swap_kb:-0}" -gt $((8 * 1024 * 1024)) ]; then
  row WARN swap "$(human "$swap_kb")" "Swap files live on the same disk and grow under memory pressure. Close sims/emulators/daemons; reboot to reclaim."
else
  row OK swap "$(human "${swap_kb:-0}")" ""
fi

# --- Memory consumers agents tend to leave behind
if is_mac && have xcrun; then
  booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c '(Booted)')
  if [ "${booted:-0}" -gt 1 ]; then
    row WARN booted-simulators "$booted" "Each booted simulator runs dozens of processes. xcrun simctl shutdown all (keeps their data)."
  else
    row OK booted-simulators "${booted:-0}" ""
  fi
fi
emus=$(count_procs 'qemu-system')
[ "$emus" -gt 1 ] && row WARN android-emulators "$emus" "Close emulators you are not using." || row OK android-emulators "$emus" ""
gd=$(count_procs 'GradleDaemon')
kd=$(count_procs 'KotlinCompileDaemon')
if [ $((gd + kd)) -gt 3 ]; then
  row WARN jvm-daemons "gradle $gd, kotlin $kd" "Parallel agents spawn extra daemons that idle for hours. pkill -f GradleDaemon; pkill -f KotlinCompileDaemon (when no build is running)."
else
  row OK jvm-daemons "gradle $gd, kotlin $kd" ""
fi
builds=$(($(count_procs 'xcodebuild') + $(count_procs 'GradleWrapperMain')))
row INFO active-builds "$builds" "Running builds. Targets they use are skipped by clean.sh; don't hand-delete build dirs now."
agents=$(($(count_procs '(^|/)claude( |$)') + $(count_procs '(^|/)codex( |$)')))
row INFO agent-processes "$agents" "Concurrent agent sessions. More agents = more worktrees, builds, simulators."

# --- Snapshots pin deleted data
if is_mac && have tmutil; then
  snaps=$(tmutil listlocalsnapshots / 2>/dev/null)
  tm=$(printf '%s\n' "$snaps" | grep -c 'com.apple.TimeMachine')
  osu=$(printf '%s\n' "$snaps" | grep -c 'com.apple.os.update')
  if [ "$osu" -gt 0 ]; then
    row WARN os-update-snapshots "$osu" "A macOS update is staged. Its snapshots pin every block deleted since. Install the update (reboot) to release them."
  fi
  if [ "$tm" -gt 0 ]; then
    row WARN timemachine-snapshots "$tm" "Local Time Machine snapshots pin deleted data. sudo tmutil deletelocalsnapshots / (backups on the TM drive are unaffected)."
  fi
  [ "$osu" -eq 0 ] && [ "$tm" -eq 0 ] && row OK snapshots 0 ""
fi

# --- Uptime: swap and temp only fully clear on reboot
if is_mac; then
  # Format: { sec = 1791990000, usec = 123 } ... ; anchor on "{ sec" so usec isn't matched.
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9]*\),.*/\1/p')
else
  boot=$(($(date +%s) - $(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)))
fi
if [ -n "$boot" ]; then
  days=$((($(date +%s) - boot) / 86400))
  [ "$days" -ge 7 ] && row WARN uptime "${days}d" "Reboot clears swap files and temp folders." || row OK uptime "${days}d" ""
fi

if [ "$tsv" = 0 ]; then
  echo
  if [ "$warns" -gt 0 ]; then
    echo "$C_B$C_Y$warns warning(s).$C_0 Resolve memory and snapshot warnings first: deleting files will not stop swap from refilling the disk."
  else
    echo "${C_G}No runaway processes or snapshots.$C_0 Continue with scan.sh."
  fi
fi
exit 0
