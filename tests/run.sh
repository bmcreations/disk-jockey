#!/usr/bin/env bash
# Self-contained tests. Builds a fake $HOME with caches, protected files and git worktrees,
# then checks every guard. Never touches your real home. Usage: bash tests/run.sh
set -u
S="$(cd "$(dirname "$0")/../scripts" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# RD_NO_CMD: tool-managed targets (npm, xcrun, docker, ...) act outside $HOME, so tests never run them.
export HOME="$T/home" RD_ROOTS="$T/home/code" RD_GH=0 RD_NO_CMD=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE=2026-01-01T10:00:00 GIT_COMMITTER_DATE=2026-01-01T10:00:00
mkdir -p "$HOME"
pass=0 fail=0
ok() {
  if eval "$2"; then
    pass=$((pass + 1)); echo "  ok    $1"
  else
    fail=$((fail + 1)); echo "  FAIL  $1"
    # Surface failures as annotations in GitHub Actions.
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      # Annotations are one line: join the debug output with " | ".
      echo "::error title=test failed::$1${3:+ :: $(printf '%s' "$3" | tr '\n' '|' | cut -c1-900)}"
    fi
  fi
}
blob() { mkdir -p "$1"; head -c "${2:-200000}" /dev/zero >"$1/blob"; }
# Portable "N days ago" timestamp for touch -t (GNU date or BSD date).
ago() { date -d "$1 days ago" +%Y%m%d%H%M 2>/dev/null || date -v-"$1"d +%Y%m%d%H%M; }
backdate() { # days path...  (sets mtime/atime on each path, not following symlinks)
  local t; t=$(ago "$1"); shift
  touch -t "$t" "$@" 2>/dev/null
}
is_windows_host() { case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac; return 1; }
is_linux_host() { [ "$(uname -s)" = Linux ]; }
BROKEN="$T/broken"; mkdir -p "$BROKEN"; printf '#!/bin/sh\nexit 1\n' >"$BROKEN/lsof"; chmod +x "$BROKEN/lsof"
have_lsof() { command -v lsof >/dev/null 2>&1; }
g() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

echo "== fixtures"
blob "$HOME/.gradle/caches/build-cache-1"
blob "$HOME/.gradle/caches/7.6/x"; find "$HOME/.gradle/caches/7.6" -exec touch -t "$(ago 60)" {} +
blob "$HOME/.gradle/caches/9.7.1/x"
echo "signing.password=secret" >"$HOME/.gradle/gradle.properties"
blob "$HOME/.android/cache"; head -c 2000 /dev/zero >"$HOME/.android/debug.keystore"
blob "$HOME/.android/avd/Pixel.avd/snapshots/default_boot"
blob "$HOME/.android/avd/Pixel.avd/data"
blob "$HOME/.claude/projects"
mkdir -p "$HOME/elsewhere" "$HOME/.bun/install"; ln -s "$HOME/elsewhere" "$HOME/.bun/install/cache"
# Git Bash copies instead of linking unless MSYS=winsymlinks:nativestrict; skip symlink checks then.
has_symlinks=0; [ -L "$HOME/.bun/install/cache" ] && has_symlinks=1
# Old mtimes but freshly extracted (ctime now): must NOT count as stale.
blob "$HOME/.cache/ms-playwright/chromium-new"; backdate 90 "$HOME/.cache/ms-playwright/chromium-new/blob"

R="$HOME/code"; mkdir -p "$R"; cd "$R" || exit 1
g init --bare origin.git; g clone origin.git app; cd app || exit 1
echo x >settings.gradle.kts; mkdir -p app Pods/Lib; echo x >app/build.gradle.kts; echo committed >Pods/Lib/f; touch Podfile
printf 'build/\n.gradle/\n.claude/\n' >.gitignore
g add -A; g commit -m init; g push origin main
W=.claude/worktrees
g worktree add $W/done -b agent/done
g worktree add $W/dirty -b agent/dirty; echo wip >$W/dirty/new.txt
g worktree add $W/unpushed -b agent/unpushed; (cd $W/unpushed && echo z >z && g add z && g commit -m local)
g worktree add "$R/gone" -b agent/gone; rm -rf "$R/gone"
for w in "done" dirty unpushed; do blob "$W/$w/app/build" 300000; done
blob app/build 300000; blob .gradle 100000
find "$R" -exec touch -t "$(ago 30)" {} + 2>/dev/null
cd "$T" || exit 1

echo "== code health"
# Every helper a script calls (snake_case names) must be defined in it or lib.sh. shellcheck can't see this.
undefined=$(cd "$S" && for f in *.sh; do
  defined=$(cat lib.sh "$f" | sed -n 's/^[[:space:]]*\([a-z][a-z0-9]*_[a-z0-9_]*\)() *{.*/\1/p' | sort -u)
  # snake_case words in command position: line start, after ; | & ( $( && ||, or after "if/while/until/!".
  sed 's/#.*$//' "$f" | grep -oE '(^|[;|&(]|\$\(|\bif|\bwhile|\buntil|!)[[:space:]]*[a-z][a-z0-9]*_[a-z0-9_]*([[:space:]]|$|\))' |
    grep -oE '[a-z][a-z0-9]*_[a-z0-9_]*' | sort -u | while IFS= read -r fn; do
      # Variables ($((x_kb + ..)), x_kb=) and find -name arguments aren't calls.
      grep -qE "(^|[^a-z0-9_])$fn=|-name $fn" "$f" && continue
      printf '%s\n' "$defined" | grep -qx "$fn" || command -v "$fn" >/dev/null 2>&1 || echo "$f:$fn"
    done
done)
ok "no undefined helper functions" '[ -z "$undefined" ]' "$undefined"

echo "== clean.sh"
out=$(bash "$S/clean.sh" --tier 2 --skip docker-build-cache,docker-dangling,pip-cache,npm-cache,pnpm-store,yarn-cache,uv-cache,go-build-cache,go-mod-cache,brew-cleanup 2>&1)
ok "dry run deletes nothing" '[ -d "$HOME/.gradle/caches/build-cache-1" ]'
# ctime can't be backdated in a test, so check mtime-staleness with ctime ignored.
out2=$(RD_IGNORE_CTIME=1 bash "$S/clean.sh" --only gradle-old-versions 2>&1)
ok "dry run lists stale gradle 7.6" 'echo "$out2" | grep -q "caches/7.6"' "$out2 || $(find "$HOME/.gradle/caches/7.6" -exec ls -ld --time-style=+%F {} + 2>&1)"
ok "recent gradle 9.7.1 not listed" '! echo "$out" | grep -q "caches/9.7.1"'
[ "$has_symlinks" = 1 ] && ok "symlinked cache guarded" 'echo "$out" | grep -q "guard .*bun/install/cache"'
ok "freshly extracted browser not stale" '! echo "$out" | grep -q chromium-new'
applied=$(bash "$S/clean.sh" --apply --skip docker-build-cache,pip-cache,npm-cache,pnpm-store,yarn-cache,uv-cache,go-build-cache,brew-cleanup 2>&1)
ok "tier 1 apply removed build cache" '[ ! -e "$HOME/.gradle/caches/build-cache-1" ]'
ok "tier 1 apply removed AVD snapshots" '[ ! -e "$HOME/.android/avd/Pixel.avd/snapshots" ]' "$(echo "$applied" | grep -i 'avd\|skip\|fail')"
ok "AVD data kept" '[ -e "$HOME/.android/avd/Pixel.avd/data" ]'
ok "debug.keystore kept" '[ -f "$HOME/.android/debug.keystore" ]'
ok "gradle.properties kept" '[ -f "$HOME/.gradle/gradle.properties" ]'
ok "tier 2 untouched at tier 1" '[ -d "$HOME/.gradle/caches/9.7.1" ]'
ok "tier 3 agent transcripts kept" '[ -d "$HOME/.claude/projects" ]'
[ "$has_symlinks" = 1 ] && ok "symlink target kept" '[ -d "$HOME/elsewhere" ]'
ok "--if-free-below skips when space is fine" 'bash "$S/clean.sh" --apply --if-free-below 1K | grep -q "Nothing to do"'

echo "== worktrees.sh"
out=$(bash "$S/worktrees.sh" "$R" 2>&1)
ok "clean pushed worktree REMOVABLE" 'echo "$out" | grep -q "^REMOVABLE .*worktrees/done"'
ok "dirty worktree REVIEW" 'echo "$out" | grep -q "^REVIEW .*worktrees/dirty"'
ok "unpushed worktree REVIEW" 'echo "$out" | grep -q "^REVIEW .*worktrees/unpushed"'
ok "deleted worktree STALE-REF" 'echo "$out" | grep -q "^STALE-REF .*gone"'
(cd "$R/app/$W/done" && exec sleep 15) &
sleep 1
ok "worktree with a process inside is IN-USE" 'bash "$S/worktrees.sh" "$R" 2>&1 | grep -q "^IN-USE .*worktrees/done"'
kill %1 2>/dev/null; wait 2>/dev/null
(cd "$R/app/$W/done" && exec sleep 15) &
sleep 1
ok "IN-USE detected via lsof when /proc is unavailable" '! lsof -v >/dev/null 2>&1 || RD_TEST_NO_PROC=1 bash "$S/worktrees.sh" "$R" 2>&1 | grep -q "^IN-USE .*worktrees/done"'
kill %1 2>/dev/null; wait 2>/dev/null
ok "apply refused when processes can't be inspected" '! RD_TEST_NO_PROC=1 RD_TEST_NO_LSOF=1 bash "$S/worktrees.sh" --apply "$R" >/dev/null 2>&1 && [ -e "$R/app/$W/done" ]'
ok "broken lsof counts as unknown, not as nothing in use" '! RD_TEST_NO_PROC=1 PATH="$BROKEN:$PATH" bash "$S/worktrees.sh" --apply "$R" >/dev/null 2>&1 && [ -e "$R/app/$W/done" ]'
ok "dry run still works without process inspection" 'RD_TEST_NO_PROC=1 RD_TEST_NO_LSOF=1 bash "$S/worktrees.sh" "$R" 2>/dev/null | grep -q REMOVABLE'
bash "$S/worktrees.sh" --apply "$R" >/dev/null 2>&1
ok "apply removed REMOVABLE" '[ ! -e "$R/app/$W/done" ]'
ok "apply kept dirty" '[ -f "$R/app/$W/dirty/new.txt" ]'
ok "apply kept unpushed" '[ -f "$R/app/$W/unpushed/z" ]'
ok "apply pruned stale ref" '! git -C "$R/app" worktree list | grep -q gone'

echo "== sweep.sh"
find "$R" -exec touch -t "$(ago 30)" {} + 2>/dev/null
bash "$S/sweep.sh" --apply "$R" >/dev/null 2>&1
ok "main repo build/ removed" '[ ! -e "$R/app/app/build" ]'
ok "main repo .gradle removed" '[ ! -e "$R/app/.gradle" ]'
ok "nested worktree build/ removed" '[ ! -e "$R/app/$W/dirty/app/build" ]'
ok "committed Pods in main repo kept" '[ -f "$R/app/Pods/Lib/f" ]'
ok "committed Pods in nested worktree kept" '[ -f "$R/app/$W/dirty/Pods/Lib/f" ]'
ok "uncommitted work in worktree kept" '[ -f "$R/app/$W/dirty/new.txt" ]'

echo "== preflight.sh / disk-guard.sh"
ok "preflight runs" 'bash "$S/preflight.sh" >/dev/null 2>&1'
ok "guard warns under threshold" 'bash "$S/disk-guard.sh" 999999G | grep -q "LOW DISK"'
ok "guard silent above threshold" '[ -z "$(bash "$S/disk-guard.sh" 1K)" ]'

echo "== linux probes (fake tools)"
FB="$T/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\necho btrfs\n' >"$FB/findmnt"
printf '#!/bin/sh\nexit 0\n' >"$FB/snapper"
printf '#!/bin/sh\ncase "$1" in info) exit 0;; system) printf "%%s\\n" "3.2GB (60%%)" "1.5GB" "800MB (100%%)" "2.5GB";; esac\n' >"$FB/docker"
printf '#!/bin/sh\nprintf "  -wi-ao----\\n  swi-a-s---\\n"\n' >"$FB/lvs"
chmod +x "$FB"/*
pf=$(PATH="$FB:$PATH" bash "$S/preflight.sh" 2>&1)
if is_linux_host; then
  ok "btrfs with snapper reported" 'echo "$pf" | grep -q "btrfs-snapshots"'
  ok "LVM snapshot counted" 'echo "$pf" | grep -q "^WARN  lvm-snapshots .* 1 "'
fi
ok "docker reclaimable summed (8.0G)" 'echo "$pf" | grep -q "docker-reclaimable .*8.0G"'
ok "docker targets skipped when daemon is down" '! PATH="$FB:$PATH" DOCKER_DOWN=1 bash -c "printf \"#!/bin/sh\\nexit 1\\n\" >\"$FB/docker\"; bash \"$S/preflight.sh\"" | grep -q docker-reclaimable'

if is_windows_host; then
  echo "== windows"
  export LOCALAPPDATA; LOCALAPPDATA=$(cygpath -w "$HOME/AppData/Local")
  mkdir -p "$HOME/AppData/Local/CrashDumps"
  echo dump >"$HOME/AppData/Local/CrashDumps/app.old.dmp"; backdate 30 "$HOME/AppData/Local/CrashDumps/app.old.dmp"
  echo dump >"$HOME/AppData/Local/CrashDumps/app.new.dmp"
  # Windows sets ctime at creation and it can't be backdated, so judge test files by mtime.
  RD_IGNORE_CTIME=1 bash "$S/clean.sh" --apply --only win-crashdumps >/dev/null 2>&1
  ok "%LOCALAPPDATA% target: old crash dump removed" '[ ! -e "$HOME/AppData/Local/CrashDumps/app.old.dmp" ]'
  ok "%LOCALAPPDATA% target: recent crash dump kept" '[ -e "$HOME/AppData/Local/CrashDumps/app.new.dmp" ]'
  ok "git paths normalized (no C:/ in audit)" '! bash "$S/worktrees.sh" "$R" 2>/dev/null | grep -q "[A-Za-z]:/"'
  # A native program (cmd.exe) working inside a worktree: invisible to /proc, caught by the rename probe.
  (cd "$R/app" && g worktree add .claude/worktrees/native -b agent/native)
  find "$R/app/.claude/worktrees/native" -exec touch -t "$(ago 30)" {} + 2>/dev/null
  MSYS_NO_PATHCONV=1 cmd.exe /c "cd /d $(cygpath -w "$R/app/.claude/worktrees/native") && ping -n 25 127.0.0.1 >nul" &
  sleep 3
  out=$(bash "$S/worktrees.sh" --apply "$R" 2>&1)
  ok "native process in worktree: reported IN-USE" 'echo "$out" | grep -q "^IN-USE .*worktrees/native"'
  ok "native process in worktree: kept" '[ -d "$R/app/.claude/worktrees/native" ]'
  ok "probe restored the folder name" '! ls "$R/app/.claude/worktrees" | grep -q dj-probe'
  taskkill //F //IM ping.exe >/dev/null 2>&1; wait 2>/dev/null
fi

echo "== colors"
esc=$(printf '\033[')
ok "plain text when piped" '! bash "$S/preflight.sh" | grep -qF "$esc"'
ok "FORCE_COLOR adds color" 'FORCE_COLOR=1 bash "$S/preflight.sh" | grep -qF "$esc"'
ok "FORCE_COLOR works with TERM=dumb" 'TERM=dumb FORCE_COLOR=1 bash "$S/preflight.sh" | grep -qF "$esc"'
ok "NO_COLOR wins over FORCE_COLOR" '! NO_COLOR=1 FORCE_COLOR=1 bash "$S/preflight.sh" | grep -qF "$esc"'
strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
ok "columns stay aligned with color" '[ "$(FORCE_COLOR=1 bash "$S/preflight.sh" | strip_ansi | head -1)" = "$(bash "$S/preflight.sh" | head -1)" ]'

echo "== dj.sh (interactive)"
blob "$HOME/.gradle/caches/build-cache-1"
blob "$HOME/.gradle/caches/modules-2"
(cd "$R/app" && g worktree add .claude/worktrees/dj -b agent/dj)
blob "$R/app/app/build"   # ensures the sweep prompt appears, so the scripted answers stay in order
find "$R" -exec touch -t "$(ago 30)" {} + 2>/dev/null
ok "refuses to run without a terminal" '! bash "$S/dj.sh" </dev/null >/dev/null 2>&1'
printf 'q\n' | RD_ALLOW_PIPE=1 bash "$S/dj.sh" >/dev/null 2>&1
ok "q quits without changes" '[ -d "$HOME/.gradle/caches/build-cache-1" ] && [ -d "$R/app/.claude/worktrees/dj" ]'
# Enter = accept preselected safe caches, y = remove worktrees, n = skip sweep, y = go, n = no schedule
printf '\ny\nn\ny\nn\n' | RD_ALLOW_PIPE=1 bash "$S/dj.sh" >/dev/null 2>&1
ok "preselected safe cache cleared" '[ ! -e "$HOME/.gradle/caches/build-cache-1" ]'
ok "rebuild-cost cache kept unless chosen" '[ -d "$HOME/.gradle/caches/modules-2" ]'
ok "confirmed worktree removed" '[ ! -e "$R/app/.claude/worktrees/dj" ]'
ok "dirty worktree still kept" '[ -f "$R/app/$W/dirty/new.txt" ]'
ok "keystore still kept" '[ -f "$HOME/.android/debug.keystore" ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
