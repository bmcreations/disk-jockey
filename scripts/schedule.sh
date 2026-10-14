#!/usr/bin/env bash
# Install a daily job that runs tier-1 cleanup only when free space drops below a threshold.
# Usage: schedule.sh install [--threshold 50G] [--tier 1] [--hour 12]
#        schedule.sh uninstall | status
. "$(dirname "$0")/lib.sh"

cmd="${1:-status}"
shift || true
threshold=50G tier=1 hour=12
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold) threshold="$2"; shift ;;
    --tier) tier="$2"; shift ;;
    --hour) hour="$2"; shift ;;
    *) log "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

label="dev.disk-jockey.daily"
clean="$RD_DIR/clean.sh"
args="--tier $tier --apply --if-free-below $threshold"

if is_mac; then
  case "$RD_DIR" in
    "$HOME"/Documents/* | "$HOME"/Desktop/* | "$HOME"/Downloads/* | "$HOME/Library/Mobile Documents"/*)
      log "Warning: launchd jobs cannot read scripts in Documents/Desktop/Downloads/iCloud without Full Disk Access."
      log "Move the skill (e.g. ~/.claude/skills/disk-jockey) before installing."
      ;;
  esac
  plist="$HOME/Library/LaunchAgents/$label.plist"
  logf="$HOME/Library/Logs/disk-jockey.log"
  case "$cmd" in
    install)
      mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
      # launchd starts with a bare PATH; capture the current one so brew/npm/docker/xcrun are found.
      cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>"$clean" $args</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$PATH</string></dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$hour</integer><key>Minute</key><integer>7</integer></dict>
  <key>StandardOutPath</key><string>$logf</string>
  <key>StandardErrorPath</key><string>$logf</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
EOF
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
      launchctl bootstrap "gui/$(id -u)" "$plist" && echo "Installed $label: daily at $hour:07, cleans tier <= $tier when free < $threshold. Log: $logf"
      ;;
    uninstall)
      launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
      rm -f "$plist" && echo "Removed $label."
      ;;
    status)
      if [ -f "$plist" ]; then echo "Installed: $plist"; tail -n 5 "$logf" 2>/dev/null; else echo "Not installed."; fi
      ;;
    *) log "Usage: schedule.sh install|uninstall|status"; exit 2 ;;
  esac
else
  have systemctl || { log "systemctl not found. Add to crontab instead: 7 $hour * * * \"$clean\" $args"; exit 2; }
  unit_dir="$HOME/.config/systemd/user"
  case "$cmd" in
    install)
      mkdir -p "$unit_dir"
      cat >"$unit_dir/disk-jockey.service" <<EOF
[Unit]
Description=disk-jockey tier $tier cleanup when free < $threshold

[Service]
Type=oneshot
Environment=PATH=$PATH
ExecStart=/bin/bash -c '"$clean" $args'
Nice=10
IOSchedulingClass=idle
EOF
      cat >"$unit_dir/disk-jockey.timer" <<EOF
[Unit]
Description=Daily disk-jockey check

[Timer]
OnCalendar=*-*-* $hour:07:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
      systemctl --user daemon-reload && systemctl --user enable --now disk-jockey.timer &&
        echo "Installed disk-jockey.timer: daily at $hour:07. Logs: journalctl --user -u disk-jockey"
      ;;
    uninstall)
      systemctl --user disable --now disk-jockey.timer 2>/dev/null
      rm -f "$unit_dir/disk-jockey.service" "$unit_dir/disk-jockey.timer"
      systemctl --user daemon-reload
      echo "Removed disk-jockey.timer."
      ;;
    status) systemctl --user list-timers disk-jockey.timer --no-pager 2>/dev/null || echo "Not installed." ;;
    *) log "Usage: schedule.sh install|uninstall|status"; exit 2 ;;
  esac
fi
