#!/usr/bin/env bash
# Read-only health check to run BEFORE deleting anything.
# Disk that "fills by itself" is often memory (swap) or snapshots, not files. Deleting caches won't fix those.
# Usage: preflight.sh [--tsv]
. "$(dirname "$0")/lib.sh"

tsv=0
case "${1:-}" in
  --tsv) tsv=1 ;;
  -h | --help) echo "Usage: preflight.sh [--tsv]   read-only: free space, load, swap, simulators, emulators, daemons, snapshots, uptime"; exit 0 ;;
esac
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

# --- CPU load (Windows has no load average; use CPU %)
if is_win; then
  cpu=$(win_fact cpu_load_pct)
  if [ -n "$cpu" ]; then
    if [ "$cpu" -ge 90 ]; then
      row WARN cpu "${cpu}%" "CPU saturated. Often memory pressure: pagefile thrashing from emulators, WSL, Docker or idle daemons."
    else
      row OK cpu "${cpu}%" ""
    fi
  fi
elif is_mac; then
  cores=$(sysctl -n hw.ncpu 2>/dev/null)
  load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
else
  cores=$(nproc 2>/dev/null)
  load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
fi
if ! is_win && [ -n "$load" ] && [ -n "$cores" ]; then
  if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c * 4)}'; then
    row WARN load "$load on $cores cores" "Processes are stalled (usually on disk I/O from swapping). Fix memory first."
  else
    row OK load "$load on $cores cores" ""
  fi
fi

# --- Memory pressure: the usual reason a multi-session machine crawls
read -r mlvl mpct mswap < <(mem_state)
case "$mlvl" in
  critical | warn)
    row WARN memory-pressure "$mlvl (${mpct}% free)" "Apps are being squeezed into compressed memory and swap. Close simulators, emulators and agent sessions you aren't using."
    ;;
  *) row OK memory-pressure "ok (${mpct}% free)" "" ;;
esac
if is_mac; then
  # Compressed memory: RAM spent holding squeezed pages of other apps.
  pages=$(vm_stat 2>/dev/null | sed -n 's/^Pages occupied by compressor: *\([0-9]*\).*/\1/p')
  psize=$(sysctl -n hw.pagesize 2>/dev/null)
  if [ -n "$pages" ] && [ -n "$psize" ]; then
    ckb=$((pages * psize / 1024))
    [ "$ckb" -gt $((4 * 1024 * 1024)) ] && row INFO compressed-memory "$(human "$ckb")" "RAM holding compressed pages of other apps. High values mean memory is oversubscribed."
  fi
fi

# --- Swap (kernel_task's huge 'bytes written' in Activity Monitor is mostly this)
swap_kb="${mswap:-0}"
swap_name=swap
is_win && swap_name=pagefile-used
if [ "${swap_kb:-0}" -gt $((8 * 1024 * 1024)) ]; then
  row WARN "$swap_name" "$(human "$swap_kb")" "Swap/pagefile lives on the same disk and grows under memory pressure. Close sims/emulators/daemons; reboot to reclaim."
else
  row OK "$swap_name" "$(human "${swap_kb:-0}")" ""
fi

# --- Windows: hidden system files and virtual disks that only grow
if is_win; then
  pf=$(win_fact pagefile_kb)
  [ -n "$pf" ] && [ "$pf" -gt $((16 * 1024 * 1024)) ] &&
    row INFO pagefile.sys "$(human "$pf")" "Grows with memory pressure and shrinks after a reboot. Fix memory use first."
  hib=$(win_fact hiberfil_kb)
  [ -n "$hib" ] && [ "$hib" -gt $((4 * 1024 * 1024)) ] &&
    row INFO hiberfil.sys "$(human "$hib")" "Hibernation file. If you never hibernate: powercfg /hibernate off (admin terminal)."
  vhd_kb=0
  while IFS='|' read -r _ id _ paths _ _ _; do
    case "$id" in wsl-disks | docker-desktop-disk) ;; *) continue ;; esac
    vhd_kb=$((vhd_kb + $(expand_paths "$paths" | size_kb)))
  done < <(each_target)
  if [ "$vhd_kb" -gt $((50 * 1024 * 1024)) ]; then
    row WARN virtual-disks "$(human "$vhd_kb")" "WSL/Docker .vhdx files never shrink when you delete inside them. Prune inside, then compact (scan.sh shows each disk and how)."
  elif [ "$vhd_kb" -gt 0 ]; then
    row OK virtual-disks "$(human "$vhd_kb")" ""
  fi
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
# --- Who holds the memory, by group (RSS overcounts shared pages: an upper bound)
min_kb="${RD_MEM_GROUP_MIN_KB:-$((300 * 1024))}"
while read -r g kb cpu n; do
  [ "${kb:-0}" -ge "$min_kb" ] || continue
  case "$g" in
    simulators) adv="Shut down ones not in use (xcrun simctl shutdown UDID). Quitting Simulator.app keeps them booted without windows." ;;
    emulators) adv="Close emulators you aren't using. For tests, start them with -no-window -memory 2048." ;;
    claude-sessions) adv="Each session runs its own builds and devices. Archive idle ones; the device cap hook (disk-jockey hooks) stops duplicates." ;;
    claude-app) adv="High CPU here usually means several sessions streaming at once. Archive idle sessions; restart the app after long runs." ;;
    jvm-daemons) adv="Idle daemons hold memory for 3h by default. org.gradle.daemon.idletimeout=900000 in ~/.gradle/gradle.properties makes it 15 min." ;;
    xcode-builds) adv="Builds running now." ;;
    *) adv="" ;;
  esac
  row INFO "mem:$g" "$(human "$kb"), ${cpu}% cpu" "$n process(es). $adv"
done < <(mem_groups | sort -k2,2nr)

builds=$(($(count_procs 'xcodebuild') + $(count_procs 'GradleWrapperMain')))
row INFO active-builds "$builds" "Running builds. Targets they use are skipped by clean.sh; don't hand-delete build dirs now."
agents=$(($(count_procs '(^|[/\\ "])claude(\.exe)?("| |$)') + $(count_procs '(^|[/\\ "])codex(\.exe)?("| |$)')))
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
elif is_linux; then
  # Linux: copy-on-write filesystems and LVM keep deleted blocks while a snapshot references them.
  fstype=$(fs_type "$HOME")
  snap_found=0
  case "$fstype" in
    btrfs)
      n=""
      for d in /.snapshots /home/.snapshots /timeshift-btrfs/snapshots /run/timeshift/backup/timeshift-btrfs/snapshots; do
        [ -d "$d" ] && [ -r "$d" ] && n=$((${n:-0} + $(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)))
      done
      if [ -n "$n" ] && [ "$n" -gt 0 ]; then
        row WARN btrfs-snapshots "$n" "Snapper/Timeshift snapshots pin deleted data. Review with sudo snapper list (or Timeshift) and delete old ones."
        snap_found=1
      elif have snapper || have timeshift; then
        row INFO btrfs-snapshots "unknown" "btrfs with Snapper/Timeshift: snapshots may pin deleted data. Check with sudo snapper list."
        snap_found=1
      fi
      ;;
    zfs)
      if have zfs; then
        n=$(zfs list -H -t snapshot -o name 2>/dev/null | wc -l | tr -d ' ')
        if [ "${n:-0}" -gt 0 ]; then
          used=$(zfs list -Hp -t snapshot -o used 2>/dev/null | awk '{s+=$1} END{printf "%d", s/1024}')
          row WARN zfs-snapshots "$n ($(human "${used:-0}"))" "ZFS snapshots pin deleted data. zfs list -t snapshot; zfs destroy old ones."
          snap_found=1
        fi
      fi
      ;;
  esac
  if have lvs; then
    n=$(lvs --noheadings -o lv_attr 2>/dev/null | awk '$1 ~ /^s/ {c++} END{print c+0}')
    if [ "${n:-0}" -gt 0 ]; then
      row WARN lvm-snapshots "$n" "LVM snapshots consume space as data changes. sudo lvs; lvremove old ones."
      snap_found=1
    fi
  fi
  [ "$snap_found" = 0 ] && row OK snapshots "0 ($fstype)" ""
fi

# --- Container engines hide space inside their own storage; ask them, since du can't read it.
for eng in docker podman; do
  tool_ready "$eng" || continue
  rec=$("$eng" system df --format '{{.Reclaimable}}' 2>/dev/null | sed -n 's/^\([0-9.]*[kKMGT]*B\).*/\1/p' | awk '
    { v=$1; u=v; gsub(/[0-9.]/,"",u); n=v; gsub(/[^0-9.]/,"",n)
      m=1; if(u~/^k|^K/)m=1; if(u~/^M/)m=1024; if(u~/^G/)m=1048576; if(u~/^T/)m=1073741824; if(u=="B")m=1/1024
      s+=n*m } END{printf "%d", s}')
  if [ "${rec:-0}" -gt $((5 * 1024 * 1024)) ]; then
    row WARN "$eng-reclaimable" "$(human "$rec")" "$eng system df -v shows what. Unused images/build cache: clean.sh --tier 2 --only ${eng}-dangling,${eng}-build-cache"
  elif [ -n "$rec" ]; then
    row OK "$eng-reclaimable" "$(human "${rec:-0}")" ""
  fi
done

# --- Quarantine holds space until purged
if [ -d "$RD_QDIR" ]; then
  qkb=$(printf '%s\n' "$RD_QDIR" | size_kb)
  [ "${qkb:-0}" -gt 0 ] && row INFO quarantine "$(human "$qkb")" "Held for undo, not freed yet. disk-jockey quarantine list; purge --all to free it."
fi

# --- Uptime: swap and temp only fully clear on reboot
if is_mac; then
  # Format: { sec = 1791990000, usec = 123 } ... ; anchor on "{ sec" so usec isn't matched.
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9]*\),.*/\1/p')
else
  boot=$(($(date +%s) - $(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)))
fi
if [ -n "$boot" ]; then
  days=$(( ($(date +%s) - boot) / 86400 ))
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
