#!/usr/bin/env bash
# Self-contained tests. Builds a fake $HOME with caches, protected files and git worktrees,
# then checks every guard. Never touches your real home. Usage: bash tests/run.sh
set -u
S="$(cd "$(dirname "$0")/../scripts" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" RD_ROOTS="$T/home/code" RD_GH=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE=2026-01-01T10:00:00 GIT_COMMITTER_DATE=2026-01-01T10:00:00
mkdir -p "$HOME"
pass=0 fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FAIL  $1"; fi; }
blob() { mkdir -p "$1"; head -c "${2:-200000}" /dev/zero >"$1/blob"; }
age() { touch -h -d "$1 days ago" "$2"; }
g() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

echo "== fixtures"
blob "$HOME/.gradle/caches/build-cache-1"
blob "$HOME/.gradle/caches/7.6/x"; find "$HOME/.gradle/caches/7.6" -exec touch -d '60 days ago' {} +
blob "$HOME/.gradle/caches/9.7.1/x"
echo "signing.password=secret" >"$HOME/.gradle/gradle.properties"
blob "$HOME/.android/cache"; head -c 2000 /dev/zero >"$HOME/.android/debug.keystore"
blob "$HOME/.android/avd/Pixel.avd/snapshots/default_boot"
blob "$HOME/.android/avd/Pixel.avd/data"
blob "$HOME/.claude/projects"
mkdir -p "$HOME/elsewhere" "$HOME/.bun/install"; ln -s "$HOME/elsewhere" "$HOME/.bun/install/cache"
# Old mtimes but freshly extracted (ctime now): must NOT count as stale.
blob "$HOME/.cache/ms-playwright/chromium-new"; touch -d '90 days ago' "$HOME/.cache/ms-playwright/chromium-new/blob"

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
find "$R" -exec touch -h -d '30 days ago' {} + 2>/dev/null
cd "$T" || exit 1

echo "== clean.sh"
out=$(bash "$S/clean.sh" --tier 2 --skip docker-build-cache,docker-dangling,pip-cache,npm-cache,pnpm-store,yarn-cache,uv-cache,go-build-cache,go-mod-cache,brew-cleanup 2>&1)
ok "dry run deletes nothing" '[ -d "$HOME/.gradle/caches/build-cache-1" ]'
# ctime can't be backdated in a test, so check mtime-staleness with ctime ignored.
out2=$(RD_IGNORE_CTIME=1 bash "$S/clean.sh" --only gradle-old-versions 2>&1)
ok "dry run lists stale gradle 7.6" 'echo "$out2" | grep -q "caches/7.6"'
ok "recent gradle 9.7.1 not listed" '! echo "$out" | grep -q "caches/9.7.1"'
ok "symlinked cache guarded" 'echo "$out" | grep -q "guard .*bun/install/cache"'
ok "freshly extracted browser not stale" '! echo "$out" | grep -q chromium-new'
bash "$S/clean.sh" --apply --skip docker-build-cache,pip-cache,npm-cache,pnpm-store,yarn-cache,uv-cache,go-build-cache,brew-cleanup >/dev/null 2>&1
ok "tier 1 apply removed build cache" '[ ! -e "$HOME/.gradle/caches/build-cache-1" ]'
ok "tier 1 apply removed AVD snapshots" '[ ! -e "$HOME/.android/avd/Pixel.avd/snapshots" ]'
ok "AVD data kept" '[ -e "$HOME/.android/avd/Pixel.avd/data" ]'
ok "debug.keystore kept" '[ -f "$HOME/.android/debug.keystore" ]'
ok "gradle.properties kept" '[ -f "$HOME/.gradle/gradle.properties" ]'
ok "tier 2 untouched at tier 1" '[ -d "$HOME/.gradle/caches/9.7.1" ]'
ok "tier 3 agent transcripts kept" '[ -d "$HOME/.claude/projects" ]'
ok "symlink target kept" '[ -d "$HOME/elsewhere" ]'
ok "--if-free-below skips when space is fine" 'bash "$S/clean.sh" --apply --if-free-below 1K | grep -q "Nothing to do"'

echo "== worktrees.sh"
out=$(bash "$S/worktrees.sh" "$R" 2>&1)
ok "clean pushed worktree REMOVABLE" 'echo "$out" | grep -q "^REMOVABLE .*worktrees/done"'
ok "dirty worktree REVIEW" 'echo "$out" | grep -q "^REVIEW .*worktrees/dirty"'
ok "unpushed worktree REVIEW" 'echo "$out" | grep -q "^REVIEW .*worktrees/unpushed"'
ok "deleted worktree STALE-REF" 'echo "$out" | grep -q "^STALE-REF .*gone"'
(cd "$R/app/$W/done" && sleep 15) &
sleep 1
ok "worktree with a process inside is IN-USE" 'bash "$S/worktrees.sh" "$R" 2>&1 | grep -q "^IN-USE .*worktrees/done"'
kill %1 2>/dev/null; wait 2>/dev/null
bash "$S/worktrees.sh" --apply "$R" >/dev/null 2>&1
ok "apply removed REMOVABLE" '[ ! -e "$R/app/$W/done" ]'
ok "apply kept dirty" '[ -f "$R/app/$W/dirty/new.txt" ]'
ok "apply kept unpushed" '[ -f "$R/app/$W/unpushed/z" ]'
ok "apply pruned stale ref" '! git -C "$R/app" worktree list | grep -q gone'

echo "== sweep.sh"
find "$R" -exec touch -h -d '30 days ago' {} + 2>/dev/null
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

echo "== colors"
esc=$(printf '\033[')
ok "plain text when piped" '! bash "$S/preflight.sh" | grep -qF "$esc"'
ok "FORCE_COLOR adds color" 'FORCE_COLOR=1 bash "$S/preflight.sh" | grep -qF "$esc"'
ok "NO_COLOR wins over FORCE_COLOR" '! NO_COLOR=1 FORCE_COLOR=1 bash "$S/preflight.sh" | grep -qF "$esc"'
strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
ok "columns stay aligned with color" '[ "$(FORCE_COLOR=1 bash "$S/preflight.sh" | strip_ansi | head -1)" = "$(bash "$S/preflight.sh" | head -1)" ]'

echo "== dj.sh (interactive)"
blob "$HOME/.gradle/caches/build-cache-1"
blob "$HOME/.gradle/caches/modules-2"
(cd "$R/app" && g worktree add .claude/worktrees/dj -b agent/dj)
blob "$R/app/app/build"   # ensures the sweep prompt appears, so the scripted answers stay in order
find "$R" -exec touch -h -d '30 days ago' {} + 2>/dev/null
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
