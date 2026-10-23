#!/usr/bin/env bash
# Self-contained tests. Builds a fake $HOME with caches, protected files and git worktrees,
# then checks every guard. Never touches your real home. Usage: bash tests/run.sh
set -u
S="$(cd "$(dirname "$0")/../scripts" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# RD_NO_CMD: tool-managed targets (npm, xcrun, docker, ...) act outside $HOME, so tests never run them.
export HOME="$T/home" RD_ROOTS="$T/home/code" RD_GH=0 RD_NO_CMD=1
# Tests never size system folders (/Applications/Xcode*.app, simulator runtimes, /var/lib/...):
# they're report-only, outside $HOME, and on CI Macs they hold hundreds of GB that make every scan slow.
export RD_TARGETS="$T/targets.conf"
awk -F'|' '/^#/ || NF!=7 || $4 !~ /(^|,)\//' "$(dirname "$0")/../targets.conf" >"$RD_TARGETS"
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
      # macOS system commands that aren't on Linux/Windows test hosts.
      case "$fn" in (memory_pressure | vm_stat) continue ;; esac
      printf '%s\n' "$defined" | grep -qx "$fn" || command -v "$fn" >/dev/null 2>&1 || echo "$f:$fn"
    done
done)
# lib.sh runs code at load time; load it as every platform and require silence (catches use-before-define).
FC="$T/fakecygpath"; mkdir -p "$FC"
printf '#!/bin/sh\ncase "$1" in -m) echo "C:/x$2";; -u) echo "/c${2#C:}";; esac\n' >"$FC/cygpath"; chmod +x "$FC/cygpath"
for os in Linux Darwin MINGW64_NT-10.0; do
  load_err=$(PATH="$FC:$PATH" RD_FORCE_OS="$os" bash -c ". '$S/lib.sh'" 2>&1)
  ok "lib.sh loads cleanly as $os" '[ -z "$load_err" ]' "$load_err"
done
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

echo "== temp scratch (Claude Code /tmp/claude-UID)"
SC="$T/scratch/claude-999"
blob "$SC/-proj/old-session/scratchpad"; find "$SC/-proj/old-session" -exec touch -t "$(ago 10)" {} +
blob "$SC/-proj/live-session/scratchpad"
printf '1|scratch-test|any|%s/*/*|stale:3|-|test\n' "$SC" >"$T/scratch.conf"
out=$(RD_TARGETS="$T/scratch.conf" RD_IGNORE_CTIME=1 bash "$S/clean.sh" --apply 2>&1)
ok "stale session scratch in temp removed" '[ ! -e "$SC/-proj/old-session" ]' "$out"
ok "active session scratch kept" '[ -d "$SC/-proj/live-session" ]'
ok "temp root's top level is never deletable" 'bash -c ". \"$S/lib.sh\"; ! safe_to_delete \"$T\" && ! safe_to_delete /tmp && ! safe_to_delete /tmp/x"'
mkdir -p "$T/nest/home"
ok "a temp folder that contains \$HOME is never deletable" 'HOME="$T/nest/home" bash -c ". \"$S/lib.sh\"; ! safe_to_delete \"\$(norm_path \"$T/nest\")\""'
ok "paths with .. are refused" 'bash -c ". \"$S/lib.sh\"; ! safe_to_delete \"\$HOME/..\" && ! safe_to_delete \"\$HOME/x/../..\""'
ok "paths outside home and temp stay off-limits" 'bash -c ". \"$S/lib.sh\"; ! safe_to_delete /usr/local/share"'

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

echo "== worktrees.sh --select (REVIEW opt-in)"
(cd "$R/app" && g worktree add $W/rev -b agent/rev && cd $W/rev && echo wip >wip.txt && echo c >c.txt && g add c.txt && g commit -m local-only)
(cd "$R/app" && g worktree add --detach $W/det && cd $W/det && echo d >d.txt && g add d.txt && g commit -m detached-only)
find "$R/app/$W/rev" "$R/app/$W/det" -exec touch -t "$(ago 30)" {} + 2>/dev/null
rev_commit=$(git -C "$R/app/$W/rev" rev-parse HEAD)
bash "$S/worktrees.sh" --apply "$R" >/dev/null 2>&1
ok "REVIEW kept by plain --apply" '[ -d "$R/app/$W/rev" ]'
out=$(bash "$S/worktrees.sh" --apply --select "$R/app/$W/rev" --select "$R/app/$W/det" "$R" 2>&1)
ok "selected REVIEW removed" '[ ! -e "$R/app/$W/rev" ]' "select=$(bash -c ". '$S/lib.sh'; norm_path '$R/app/$W/rev'") || $out"
ok "its branch and local commit survive" '[ "$(git -C "$R/app" rev-parse agent/rev)" = "$rev_commit" ]'
ok "detached with local commits refused even when selected" '[ -d "$R/app/$W/det" ] && echo "$out" | grep -q "on no branch"' "$out"
ok "unselected REVIEW untouched by --select run" '[ -f "$R/app/$W/dirty/new.txt" ]'

echo "== sweep.sh"
find "$R" -exec touch -t "$(ago 30)" {} + 2>/dev/null
bash "$S/sweep.sh" --apply "$R" >/dev/null 2>&1
ok "main repo build/ removed" '[ ! -e "$R/app/app/build" ]'
ok "main repo .gradle removed" '[ ! -e "$R/app/.gradle" ]'
ok "nested worktree build/ removed" '[ ! -e "$R/app/$W/dirty/app/build" ]'
ok "committed Pods in main repo kept" '[ -f "$R/app/Pods/Lib/f" ]'
ok "committed Pods in nested worktree kept" '[ -f "$R/app/$W/dirty/Pods/Lib/f" ]'
ok "uncommitted work in worktree kept" '[ -f "$R/app/$W/dirty/new.txt" ]'

echo "== quarantine (opt-in undo)"
QD="$HOME/.disk-jockey/quarantine"
qn() { find "$QD" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
ok "off by default" 'bash "$S/quarantine.sh" status | grep -q "Quarantine: off"'
blob "$HOME/.gradle/caches/build-cache-1"
out=$(bash "$S/clean.sh" --apply --quarantine --only gradle-build-cache 2>&1)
ok "--quarantine moves instead of deleting" '[ ! -e "$HOME/.gradle/caches/build-cache-1" ] && [ "$(qn)" = 1 ]' "$out"
ok "summary says space isn't freed yet" 'echo "$out" | grep -q "Moved .* to quarantine"'
ok "list shows the item and its source" 'bash "$S/quarantine.sh" list | grep -q "clean:gradle-build-cache"'
out=$(bash "$S/quarantine.sh" restore --last 2>&1)
ok "restore --last puts it back" '[ -f "$HOME/.gradle/caches/build-cache-1/blob" ] && [ "$(qn)" = 0 ]' "$out"
bash "$S/quarantine.sh" on --days 3 >/dev/null
ok "quarantine on persists" 'bash "$S/quarantine.sh" status | grep -q "on.* (kept 3 days"'
bash "$S/clean.sh" --apply --only gradle-build-cache >/dev/null 2>&1
ok "clean honors the setting" '[ ! -e "$HOME/.gradle/caches/build-cache-1" ] && [ "$(qn)" = 1 ]'
ok "--no-quarantine overrides it" 'blob "$HOME/.gradle/caches/build-cache-1"; bash "$S/clean.sh" --apply --no-quarantine --only gradle-build-cache >/dev/null 2>&1; [ ! -e "$HOME/.gradle/caches/build-cache-1" ] && [ "$(qn)" = 1 ]'
blob "$HOME/.gradle/caches/build-cache-1" 1000
ok "restore won't overwrite a path that exists again" '! bash "$S/quarantine.sh" restore --last >/dev/null 2>&1 && [ "$(qn)" = 1 ]'
rm -rf "$HOME/.gradle/caches/build-cache-1"
item=$(find "$QD" -mindepth 1 -maxdepth 1 -type d | head -n 1)
sed 's/^time=.*/time=1000/' "$item/meta" >"$item/meta.new" && mv "$item/meta.new" "$item/meta"
bash "$S/clean.sh" --apply --only no-such-target >/dev/null 2>&1
ok "expired items purged on the next --apply" '[ ! -e "$item" ]'
ok "the quarantine folder itself is protected" 'bash -c ". \"$S/lib.sh\"; ! safe_to_delete \"$HOME/.disk-jockey\""'
# Worktrees are moved with git, so uncommitted work survives and restore re-registers them.
(cd "$R/app" && g worktree add $W/qrev -b agent/qrev && echo wip >"$W/qrev/wip.txt")
find "$R/app/$W/qrev" -exec touch -t "$(ago 30)" {} + 2>/dev/null
out=$(bash "$S/worktrees.sh" --apply --select "$R/app/$W/qrev" "$R" 2>&1)
ok "selected REVIEW worktree quarantined with its changes" '[ ! -e "$R/app/$W/qrev" ] && [ -n "$(find "$QD" -name wip.txt)" ]' "$out"
ok "quarantined worktree hidden from the audit" '! bash "$S/worktrees.sh" "$R" 2>&1 | grep -q "disk-jockey/quarantine"'
out=$(bash "$S/quarantine.sh" restore "$R/app/$W/qrev" 2>&1)
ok "restore by path brings back the worktree and its changes" '[ -f "$R/app/$W/qrev/wip.txt" ] && git -C "$R/app/$W/qrev" status --porcelain | grep -q wip.txt' "$out"
ok "restored worktree is registered with git again" 'git -C "$R/app" worktree list | grep -q "worktrees/qrev"'
bash "$S/worktrees.sh" --apply --select "$R/app/$W/qrev" "$R" >/dev/null 2>&1
bash "$S/quarantine.sh" purge --all >/dev/null 2>&1
ok "purge --all deletes and unregisters" '[ "$(qn)" = 0 ] && ! git -C "$R/app" worktree list | grep -q qrev'
ok "its branch survives the purge" 'git -C "$R/app" rev-parse -q --verify agent/qrev >/dev/null'
bash "$S/quarantine.sh" off >/dev/null
ok "quarantine off" 'bash "$S/quarantine.sh" status | grep -q "Quarantine: off"'

echo "== orphaned build folders (project gone)"
DD="$HOME/Library/Developer/Xcode/DerivedData"; MW="$HOME/Library/Developer/XcodeBuildMCP/workspaces"
plist() { mkdir -p "$1"; printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>LastAccessedDate</key>\n\t<date>2026-10-01T10:00:00Z</date>\n\t<key>WorkspacePath</key>\n\t<string>%s</string>\n</dict>\n</plist>\n' "$2" >"$1/info.plist"; }
sha() { bash -c '. "$1/lib.sh"; sha12 "$2"' _ "$S" "$1"; }
mkdir -p "$R/app/App.xcodeproj"
plist "$DD/App-live" "$R/app/App.xcodeproj"; blob "$DD/App-live/Build"
plist "$DD/App-gone" "$HOME/code/gone-wt/App.xcodeproj"; blob "$DD/App-gone/Build"
plist "$DD/Amp-gone" "$HOME/code/a&amp;b/App.xcodeproj"; blob "$DD/Amp-gone/Build"
blob "$DD/NoInfo-x/Build"; blob "$DD/ModuleCache.noindex"
plist "$DD/Vol-y" "/Volumes/dj-not-mounted-$$/x/App.xcodeproj"; blob "$DD/Vol-y/Build"
mroot="$R/app/.claude/worktrees/mlive"; mkdir -p "$mroot"
MLIVE="$MW/mlive-$(sha "$mroot")"; plist "$MLIVE/DerivedData/Renamed-aaa" "$mroot/Renamed.xcodeproj"; blob "$MLIVE/DerivedData/Renamed-aaa/Build"
MGONE="$MW/wtgone-$(sha "$HOME/code/wtgone")"; mkdir -p "$MGONE/state/daemon"; printf '{"pid":1,"workspaceRoot":"%s","version":"2.7"}' "$HOME/code/wtgone" >"$MGONE/state/daemon/daemon.json"; blob "$MGONE/test-products/x.xctestproducts"
blob "$MW/empty-123456789abc/logs"
find "$DD" "$MW" -exec touch -t "$(ago 10)" {} + 2>/dev/null
MFRESH="$MW/fresh-$(sha "$HOME/code/fresh")"; plist "$MFRESH/DerivedData/F-1" "$HOME/code/fresh/F.xcodeproj"
dj_mac() { RD_FORCE_OS=Darwin RD_IGNORE_CTIME=1 bash "$S/clean.sh" "$@" 2>&1; }
out=$(dj_mac --orphans)
ok "orphans: deleted worktree's DerivedData listed" 'echo "$out" | grep -q "DerivedData/App-gone"' "$out"
ok "orphans: XcodeBuildMCP workspace of a deleted worktree listed" 'echo "$out" | grep -q "wtgone-"' "$out"
ok "orphans: dry run deletes nothing" '[ -d "$DD/App-gone" ] && [ -d "$MGONE" ]'
ok "orphans: live project's DerivedData not listed" '! echo "$out" | grep -q "App-live"' "$out"
dj_mac --orphans --apply >/dev/null
ok "orphans: removed on --apply" '[ ! -e "$DD/App-gone" ] && [ ! -e "$MGONE" ] && [ ! -e "$DD/Amp-gone" ]'
ok "orphans: live project's DerivedData kept" '[ -d "$DD/App-live" ]'
ok "orphans: folders that record nothing kept" '[ -d "$DD/NoInfo-x" ] && [ -d "$DD/ModuleCache.noindex" ] && [ -d "$MW/empty-123456789abc" ]'
ok "orphans: project on an unmounted volume kept" '[ -d "$DD/Vol-y" ]'
ok "orphans: workspace whose root still exists kept (project renamed)" '[ -d "$MLIVE" ]'
ok "orphans: folder written in the last 2 minutes kept" '[ -d "$MFRESH" ]'
plist "$DD/Dup-gone" "$HOME/code/dup-wt/App.xcodeproj"; blob "$DD/Dup-gone/Build"; find "$DD/Dup-gone" -exec touch -t "$(ago 30)" {} +
out=$(dj_mac --only xcode-deriveddata-orphans,xcode-deriveddata)
ok "an orphan that is also stale is counted once" '[ "$(echo "$out" | grep -c "Dup-gone")" = 1 ]' "$out"
out=$(RD_FORCE_OS=Darwin bash "$S/scan.sh" --tsv 2>/dev/null)
ok "scan reports orphans as their own row" 'echo "$out" | grep -q "xcode-deriveddata-orphans"' "$out"
rm -f "$HOME/.disk-jockey/orphans.last"
echo '{"session_id":"orph1","reason":"other"}' | RD_FORCE_OS=Darwin RD_HOOK_SYNC=1 RD_AGENT_PID="1 none" bash "$S/hooks.sh" session-end
ok "session end sweeps orphans" '[ ! -e "$DD/Dup-gone" ] && [ -d "$DD/App-live" ]' "$(tail -5 "$HOME/.disk-jockey/sessions/log" 2>&1)"
rm -rf "$HOME/Library/Developer" "$HOME/.disk-jockey/orphans.last"

echo "== worktrees.sh --merged (agent-triggered)"
(cd "$R/app" && g worktree add $W/m1 -b agent/m1 && cd $W/m1 && echo m >m.txt && g add m.txt && g commit -m m1 && g push origin agent/m1)
(cd "$R/app" && g merge --no-ff agent/m1 -m "merge m1" && g push origin main)
(cd "$R/app" && g worktree add $W/m2 -b agent/m2 && cd $W/m2 && echo n >n.txt && g add n.txt && g commit -m m2 && g push origin agent/m2)
(cd "$R/app" && g worktree add $W/m3 -b agent/m3)
out=$(cd "$R/app" && bash "$S/worktrees.sh" --merged --no-fetch 2>&1)
ok "merged branch is MERGED though just touched" 'echo "$out" | grep -q "^MERGED .*worktrees/m1"' "$out"
ok "pushed but unmerged branch is UNMERGED" 'echo "$out" | grep -q "^UNMERGED .*worktrees/m2"' "$out"
ok "a new branch nobody committed to isn't merged" 'echo "$out" | grep -q "^UNMERGED .*worktrees/m3"' "$out"
out=$(cd "$R/app/$W/m1" && bash "$S/worktrees.sh" --merged --apply --no-fetch 2>&1)
ok "run from inside the worktree: refused with a hint" '[ -d "$R/app/$W/m1" ] && echo "$out" | grep -q "cd to the main checkout"' "$out"
out=$(cd "$R/app" && bash "$S/worktrees.sh" --merged --apply --no-fetch --delete-merged-branches 2>&1)
ok "--merged --apply removes the merged worktree" '[ ! -e "$R/app/$W/m1" ]' "$out"
ok "--delete-merged-branches deletes its branch" '! git -C "$R/app" rev-parse -q --verify agent/m1 >/dev/null'
ok "unmerged worktrees kept" '[ -d "$R/app/$W/m2" ] && [ -d "$R/app/$W/m3" ]'
(cd "$R/app" && git worktree remove "$W/m2" && git worktree remove "$W/m3") >/dev/null 2>&1

echo "== hooks.sh (session simulators)"
HB="$T/hookbin"; mkdir -p "$HB"; BOOTED="$T/booted"; STOPPED="$T/stopped"; : >"$BOOTED"; : >"$STOPPED"
cat >"$HB/xcrun" <<EOF
#!/bin/sh
case "\$2" in
  list) while read -r u; do echo "    iPhone 16 (\$u) (Booted) "; done <"$BOOTED" ;;
  shutdown) grep -vx "\$3" "$BOOTED" >"$BOOTED.n"; mv "$BOOTED.n" "$BOOTED"; echo "\$3" >>"$STOPPED" ;;
esac
EOF
printf '#!/bin/sh\necho "List of devices attached"\n' >"$HB/adb"
chmod +x "$HB/xcrun" "$HB/adb"
U() { printf '%s1111111-1111-1111-1111-111111111111' "$1"; }
hk() { local who="$1"; shift; PATH="$HB:$PATH" RD_HOOK_SYNC=1 RD_AGENT_PID="$who" bash "$S/hooks.sh" "$@"; }
sleep 300 & P1=$!
sleep 300 & P2=$!
U A >"$BOOTED"; echo >>"$BOOTED"
echo '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | hk "$P1 sleep" session-start
U B >>"$BOOTED"; echo >>"$BOOTED"
echo '{"session_id":"s2","hook_event_name":"SessionStart","source":"startup"}' | hk "$P2 sleep" session-start
echo '{"session_id":"s1","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}' | hk "$P1 sleep" session-end
ok "another session still running: nothing shut down" '[ ! -s "$STOPPED" ]' "$(cat "$HOME/.disk-jockey/sessions/log" 2>&1)"
echo '{"session_id":"s2","hook_event_name":"SessionEnd","reason":"other"}' | hk "$P2 sleep" session-end
ok "last session out: devices booted during sessions shut down" 'grep -qx "$(U B)" "$STOPPED"' "$(cat "$HOME/.disk-jockey/sessions/log" 2>&1)"
ok "devices running before the first session left alone" '! grep -qx "$(U A)" "$STOPPED"'
: >"$STOPPED"
echo '{"session_id":"s3"}' | hk "$P1 sleep" session-start
U C >>"$BOOTED"; echo >>"$BOOTED"
echo '{"session_id":"s4"}' | hk "$P2 sleep" session-start
kill "$P2" 2>/dev/null; wait "$P2" 2>/dev/null
echo '{"session_id":"s3","reason":"logout"}' | hk "$P1 sleep" session-end
if is_windows_host; then
  ok "crashed session: still counted on Windows (age-based), nothing shut down" '[ ! -s "$STOPPED" ]'
  rm -f "$HOME/.disk-jockey/sessions/active/"*; rm -f "$HOME/.disk-jockey/sessions/baseline"
  printf '%s\n' "$(U A)" >"$BOOTED"
else
  ok "a crashed session (process gone) doesn't block cleanup" 'grep -qx "$(U C)" "$STOPPED"' "$(cat "$HOME/.disk-jockey/sessions/log" 2>&1)"
fi
: >"$STOPPED"
echo '{"session_id":"s5","source":"startup"}' | hk "$P1 sleep" session-start
U D >>"$BOOTED"; echo >>"$BOOTED"
echo '{"session_id":"s5","reason":"clear"}' | hk "$P1 sleep" session-end
ok "/clear doesn't shut anything down" '[ ! -s "$STOPPED" ]'
echo '{"session_id":"s6","source":"clear"}' | hk "$P1 sleep" session-start
echo '{"session_id":"s6","reason":"prompt_input_exit"}' | hk "$P1 sleep" session-end
ok "after /clear, exit still shuts down what was booted before it" 'grep -qx "$(U D)" "$STOPPED"' "$(cat "$HOME/.disk-jockey/sessions/log" 2>&1)"
: >"$STOPPED"; U E >>"$BOOTED"; echo >>"$BOOTED"
hk "$P1 sleep" session-end --session never-started </dev/null
ok "no record of a start: nothing shut down" '[ ! -s "$STOPPED" ]'
kill "$P1" 2>/dev/null; wait "$P1" 2>/dev/null
ok "print gives a settings.json snippet" 'bash "$S/hooks.sh" print | grep -q "\"SessionEnd\""'
ok "session-start --guard warns on low disk" 'hk "1 none" session-start --session g1 --guard 999999G </dev/null | grep -q "LOW DISK"'

echo "== hooks.sh pre-tool (device cap, memory pressure)"
EMUS="$T/emus"; : >"$EMUS"
cat >"$HB/adb" <<EOF
#!/bin/sh
if [ "\$1" = devices ]; then echo "List of devices attached"; while read -r e; do printf '%s\tdevice\n' "\$e"; done <"$EMUS"; exit 0; fi
if [ "\$1" = -s ] && [ "\$3" = emu ] && [ "\$4" = avd ]; then echo Pixel_8; echo OK; fi
EOF
chmod +x "$HB/adb"
pt() { # session json-for-tool... ; prints hook output
  local sid="$1"; shift
  printf '{"session_id":"%s","hook_event_name":"PreToolUse",%s}' "$sid" "$1" | PATH="$HB:$PATH" RD_TEST_MEM="${MEM:-ok 60 0}" bash "$S/hooks.sh" pre-tool
}
valid_json() { ! command -v python3 >/dev/null 2>&1 || printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)'; }
bash_call() { printf '"tool_name":"Bash","tool_input":{"command":"%s"}' "$1"; }
printf '%s\n%s\n' "$(U A)" "$(U B)" >"$BOOTED"
out=$(pt p1 "$(bash_call "xcrun simctl boot $(U C)")")
ok "cap reached: booting a third simulator is denied" 'echo "$out" | grep -q "\"permissionDecision\":\"deny\""' "$out"
ok "the denial lists booted devices to reuse" 'echo "$out" | grep -q "$(U A)" && echo "$out" | grep -q "$(U B)"' "$out"
ok "the denial is valid JSON" 'valid_json "$out"' "$out"
out=$(pt p1 "$(bash_call "xcrun simctl boot $(U A)")")
ok "booting an already-booted simulator is allowed" '[ -z "$out" ]' "$out"
out=$(pt p1 "$(bash_call 'xcrun simctl boot \"iPhone 16\"')")
ok "booting an already-booted simulator by name is allowed" '[ -z "$out" ]' "$out"
out=$(pt p1 "\"tool_name\":\"mcp__XcodeBuildMCP__boot_sim\",\"tool_input\":{\"simulatorUuid\":\"$(U C)\"}")
ok "MCP simulator boot over the cap is denied" 'echo "$out" | grep -q deny' "$out"
U A >"$BOOTED"
out=$(pt p1 "$(bash_call "xcrun simctl boot $(U C)")")
ok "under the cap: allowed" '[ -z "$out" ]' "$out"
echo emulator-5554 >"$EMUS"
out=$(pt p1 "$(bash_call 'emulator -avd Pixel_9 -no-window')")
ok "second emulator denied (cap 1)" 'echo "$out" | grep -q deny && echo "$out" | grep -q "Pixel_8 (emulator-5554)"' "$out"
PATH="$HB:$PATH" bash "$S/hooks.sh" limit --emulators 2 >/dev/null
out=$(pt p1 "$(bash_call 'emulator -avd Pixel_9 -no-window')")
ok "raised cap allows it" '[ -z "$out" ]' "$out"
PATH="$HB:$PATH" bash "$S/hooks.sh" limit --emulators 1 >/dev/null
ok "limit rejects non-numbers" '! bash "$S/hooks.sh" limit --simulators lots >/dev/null 2>&1'
out=$(pt p1 "$(bash_call 'ls -la')")
ok "unrelated tool calls produce nothing" '[ -z "$out" ]'
out=$(MEM="critical 4 9000000" pt p2 "$(bash_call './gradlew assembleDebug')")
ok "memory pressure: build gets a warning for the agent" 'echo "$out" | grep -q additionalContext && echo "$out" | grep -q "memory pressure is critical"' "$out"
ok "the warning is valid JSON" 'valid_json "$out"' "$out"
out=$(MEM="critical 4 9000000" pt p2 "$(bash_call './gradlew test')")
ok "warned at most once per 10 minutes per session" '[ -z "$out" ]' "$out"
out=$(MEM="critical 4 9000000" pt p3 "$(bash_call 'xcodebuild test')")
ok "other sessions still get their warning" 'echo "$out" | grep -q additionalContext' "$out"
out=$(pt p4 "$(bash_call './gradlew assembleDebug')")
ok "no pressure: builds pass silently" '[ -z "$out" ]' "$out"
out=$(echo '{"session_id":"p5"}' | PATH="$HB:$PATH" RD_TEST_MEM="warn 8 0" RD_AGENT_PID="1 none" bash "$S/hooks.sh" session-start)
ok "session-start tells the agent about memory pressure" 'echo "$out" | grep -q "memory pressure is warn"' "$out"
# loupe: a fake server behind a fake curl. B is claimed by another session, A is free.
LC="$T/loupe"; mkdir -p "$LC"
cat >"$HB/curl" <<EOF
#!/bin/sh
for a in "\$@"; do u="\$a"; done
case "\$u" in
  */api/claims) cat "$LC/claims.json" ;;
  */api/targets) cat "$LC/targets.json" ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$HB/curl"
printf '[{"target":"sim:%s","agent":"claude","session":"other-session","since":"2026-10-20T09:00:00Z","idleMs":1200}]' "$(U B)" >"$LC/claims.json"
printf '[{"id":"sim:%s","kind":"simulator","label":"iPhone 16","available":true},{"id":"sim:%s","kind":"simulator","label":"iPhone 16","available":true,"claim":{"target":"sim:%s","agent":"claude","session":"other-session","since":"2026-10-20T09:00:00Z","idleMs":1200}},{"id":"avd:Pixel_8","kind":"emulator","serial":"emulator-5554","available":true,"handsOff":true}]' "$(U A)" "$(U B)" "$(U B)" >"$LC/targets.json"
lpt() { LOUPE_TOKEN=x pt "$@"; }
printf '%s\n%s\n' "$(U A)" "$(U B)" >"$BOOTED"
out=$(lpt p6 "$(bash_call "xcrun simctl boot $(U C)")")
ok "loupe: denial steers to the unclaimed simulator" 'echo "$out" | grep -q "$(U A))*: free" && echo "$out" | grep -q "$(U B))*: claimed by claude in another session"' "$out"
ok "loupe: denial says how to claim it, with this session's id" 'echo "$out" | grep -q "X-Loupe-Session: p6" && echo "$out" | grep -q "target=sim:$(U A)"' "$out"
ok "loupe: denial is still valid JSON" 'valid_json "$out"' "$out"
out=$(lpt p6 "$(bash_call "xcrun simctl boot $(U B)")")
ok "loupe: using a booted simulator another session claimed gets a warning" 'echo "$out" | grep -q additionalContext && echo "$out" | grep -q "claimed by claude in another session" && ! echo "$out" | grep -q deny' "$out"
out=$(lpt other-session "$(bash_call "xcrun simctl boot $(U B)")")
ok "loupe: the claiming session itself isn't warned" '[ -z "$out" ]' "$out"
printf '[{"target":"sim:%s","agent":"claude","session":"s1"},{"target":"sim:%s","agent":"codex","session":"s2"}]' "$(U A)" "$(U B)" >"$LC/claims.json"
out=$(lpt p6 "$(bash_call "xcrun simctl boot $(U C)")")
ok "loupe: every booted simulator claimed: denial says to ask the user" 'echo "$out" | grep -q "every one in use" && echo "$out" | grep -q "codex"' "$out"
echo emulator-5554 >"$EMUS"
out=$(lpt p6 "$(bash_call 'emulator -avd Pixel_9')")
ok "loupe: emulators show hands off by serial" 'echo "$out" | grep -q "emulator-5554): hands off"' "$out"
out=$(PATH="$HB:$PATH" RD_TEST_MEM="ok 60 0" bash -c 'printf "{\"session_id\":\"p7\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"xcrun simctl boot %s\"}}" "$1" | bash "$2/hooks.sh" pre-tool' _ "$(U C)" "$S")
ok "no loupe token: plain denial, loupe not consulted" 'echo "$out" | grep -q deny && ! echo "$out" | grep -q "claimed by"' "$out"
: >"$EMUS"; rm -f "$HB/curl"
ok "preflight flags memory pressure" 'RD_TEST_MEM="critical 4 0" bash "$S/preflight.sh" | grep -q "^WARN  memory-pressure"'
if ! is_windows_host; then
  (exec -a qemu-system-fake sleep 30) &
  qp=$!
  sleep 1
  ok "preflight groups memory by kind (emulators)" 'RD_MEM_GROUP_MIN_KB=1 bash "$S/preflight.sh" | grep -q "^INFO  mem:emulators"'
  kill "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
fi

echo "== autopilot"
FREEF="$T/free"; AB="$T/autobin"; NOTE="$T/notified"; mkdir -p "$AB"; : >"$NOTE"
for t in osascript notify-send; do printf '#!/bin/sh\necho "$*" >>"%s"\n' "$NOTE" >"$AB/$t"; done
for t in launchctl systemctl schtasks; do printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$t" "$T/sched.log" >"$AB/$t"; done
chmod +x "$AB"/*
ap() { PATH="$AB:$PATH" RD_TEST_FREE_FILE="$FREEF" bash "$S/autopilot.sh" "$@" 2>&1; }
# An idle project with build output, a tier-1 cache, a tier-2 cache, and the dirty REVIEW worktree from before.
(cd "$R" && g init idleproj && cd idleproj && echo x >settings.gradle && echo 'build/' >.gitignore && g add -A && g commit -m init)
blob "$R/idleproj/build" 300000
find "$R/idleproj" -exec touch -t "$(ago 20)" {} + 2>/dev/null
blob "$HOME/.gradle/caches/build-cache-1"; blob "$HOME/.gradle/caches/modules-2"
echo $((900 * 1024 * 1024)) >"$FREEF"   # 900G free: nothing to do beyond the always-safe steps
out=$(ap run)
ok "autopilot: plenty of space: caches and idle builds left alone" '[ -d "$HOME/.gradle/caches/build-cache-1" ] && [ -d "$R/idleproj/build" ]' "$out"
echo $((1024 * 1024)) >"$FREEF"         # 1G free, under the 80G target, above nothing
out=$(ap run --dry-run)
ok "autopilot: dry run lists the rungs and deletes nothing" 'echo "$out" | grep -q "would run: tier-1 caches" && echo "$out" | grep -q "would run: projects idle 3d" && [ -d "$R/idleproj/build" ]' "$out"
ok "autopilot: dry run sends no notification" '[ ! -s "$NOTE" ]'
out=$(ap run)
ok "autopilot: short of target: tier-1 cache cleared" '[ ! -e "$HOME/.gradle/caches/build-cache-1" ]' "$(tail -12 "$HOME/.disk-jockey/autopilot.log")"
ok "autopilot: short of target: idle project's build output cleared" '[ ! -e "$R/idleproj/build" ]' "$(tail -12 "$HOME/.disk-jockey/autopilot.log")"
ok "autopilot: tier 2 never touched" '[ -d "$HOME/.gradle/caches/modules-2" ]'
ok "autopilot: REVIEW worktree never touched" '[ -f "$R/app/$W/dirty/new.txt" ]'
ok "autopilot: debug keystore never touched" '[ -f "$HOME/.android/debug.keystore" ]'
if ! is_windows_host; then
  ok "autopilot: out of safe rungs: notifies" 'grep -q "disk-jockey\|free" "$NOTE"' "$(cat "$NOTE")"
  n=$(wc -l <"$NOTE"); ap run >/dev/null
  ok "autopilot: notification at most every 6 hours" '[ "$(wc -l <"$NOTE")" = "$n" ]'
fi
ok "autopilot: each pass is logged" 'grep -q "tier-1 caches: freed" "$HOME/.disk-jockey/autopilot.log"'
mkdir -p "$HOME/.disk-jockey/autopilot.lock"; sleep 60 & lp=$!; echo "$lp" >"$HOME/.disk-jockey/autopilot.lock/pid"
ok "autopilot: one pass at a time" 'ap run | grep -q "already running"'
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
ok "autopilot: a lock left by a dead process is taken over" '! ap run | grep -q "already running"'
rm -f "$HOME/.disk-jockey/autopilot.last"
before=$(wc -l <"$HOME/.disk-jockey/autopilot.log")
ap tick >/dev/null
ok "autopilot: tick does nothing while off" '[ "$(wc -l <"$HOME/.disk-jockey/autopilot.log")" = "$before" ]'
out=$(ap on --target 50G --floor 10G)
ok "autopilot: on installs the job and saves settings" 'grep -q "autopilot=on" "$HOME/.disk-jockey/config" && grep -q "autopilot_target=50G" "$HOME/.disk-jockey/config" && [ -s "$T/sched.log" ]' "$out"
ok "autopilot: floor must be below target" '! ap on --target 10G --floor 20G >/dev/null'
ap on --target 50G --floor 10G >/dev/null
echo $((30 * 1024 * 1024)) >"$FREEF"; date +%s >"$HOME/.disk-jockey/autopilot.last"
before=$(wc -l <"$HOME/.disk-jockey/autopilot.log"); ap tick >/dev/null
ok "autopilot: tick skips when a pass isn't due and space is above the floor" '[ "$(wc -l <"$HOME/.disk-jockey/autopilot.log")" = "$before" ]'
echo $((5 * 1024 * 1024)) >"$FREEF"; ap tick >/dev/null
ok "autopilot: under the floor, tick runs an emergency pass at once" 'tail -12 "$HOME/.disk-jockey/autopilot.log" | grep -q "pass (emergency)"'
bash "$S/quarantine.sh" on >/dev/null
blob "$HOME/.gradle/caches/build-cache-1"; bash "$S/clean.sh" --apply --only gradle-build-cache >/dev/null 2>&1
ok "autopilot: (quarantine holds an item)" '[ -n "$(ls "$HOME/.disk-jockey/quarantine")" ]'
ap tick >/dev/null
ok "autopilot: under the floor, quarantine is purged first" '[ -z "$(ls "$HOME/.disk-jockey/quarantine")" ]' "$(tail -8 "$HOME/.disk-jockey/autopilot.log")"
bash "$S/quarantine.sh" off >/dev/null
ok "autopilot: status shows settings and last pass" 'ap status | grep -q "keep 50G free, floor 10G" && ap status | grep -q "Last pass: [0-9]"'
ok "preflight shows autopilot on" 'bash "$S/preflight.sh" | grep -q "^OK    autopilot"'
ap off >/dev/null
ok "autopilot: off removes the job" 'grep -q "autopilot=off" "$HOME/.disk-jockey/config"'
rm -f "$HOME/.disk-jockey/autopilot."* "$HOME/.disk-jockey/notified."*

echo "== mcp.sh (agent device coordination)"
MB="$T/mcpbin"; mkdir -p "$MB"; MBOOT="$T/mboot"; MALL="$T/mall"; : >"$MBOOT"
printf '%s\tiPhone 16 Pro\n%s\tiPhone Duo\n%s\tiPhone SE\n' "$(U A)" "$(U B)" "$(U C)" >"$MALL"
cat >"$MB/xcrun" <<EOF
#!/bin/sh
case "\$2" in
  list) echo "== Devices =="; echo "-- iOS 27.0 --"
    while IFS="	" read -r u n; do st=Shutdown; grep -qx "\$u" "$MBOOT" && st=Booted
      [ "\$4" = booted ] && [ "\$st" != Booted ] && continue; echo "    \$n (\$u) (\$st) "; done <"$MALL" ;;
  boot) echo "\$3" >>"$MBOOT" ;;
  bootstatus) ;;
  shutdown) grep -vx "\$3" "$MBOOT" >"$MBOOT.n"; mv "$MBOOT.n" "$MBOOT" ;;
esac
EOF
printf '#!/bin/sh\n[ "$1" = devices ] && echo "List of devices attached"\n' >"$MB/adb"
chmod +x "$MB"/*
sleep 300 & S1=$!
sleep 300 & S2=$!
sleep 300 & S3=$!
mcp() { # owner-pid json-lines... ; prints one line per reply
  local who="$1"; shift
  printf '%s\n' "$@" | PATH="$MB:$PATH" RD_AGENT_PID="$who sleep" RD_TEST_MEM="ok 60 0" bash "$S/mcp.sh"
}
# No "${3:-{}}": bash 3.2 brace-expands that default around the commas in the arguments.
call() {
  local a='{}'
  [ -n "${3:-}" ] && a="$3"
  printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2" "$a"
}
text_of() { sed -n 's/.*"text":"\(.*\)"}\],"isError".*/\1/p'; }
out=$(mcp "$S1" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2"}}}' '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":"two","method":"tools/list"}')
ok "mcp: notifications get no reply" '[ "$(printf "%s\n" "$out" | grep -c .)" = 2 ]' "$out"
ok "mcp: initialize echoes the protocol version" 'printf "%s\n" "$out" | head -n 1 | grep -q "\"id\":1,.*\"protocolVersion\":\"2025-06-18\""' "$out"
ok "mcp: string ids answered as strings, six tools listed" 'printf "%s\n" "$out" | tail -n 1 | grep -q "\"id\":\"two\"" && [ "$(printf "%s\n" "$out" | tail -n 1 | grep -o "\"inputSchema\"" | wc -l | tr -d " ")" = 6 ]' "$out"
ok "mcp: replies are valid JSON" 'printf "%s\n" "$out" | while IFS= read -r l; do valid_json "$l" || exit 1; done'
out=$(mcp "$S1" "$(call 3 acquire_simulator '{"name":"Duo"}')")
ok "mcp: nothing booted: acquire boots the requested simulator" 'grep -qx "$(U B)" "$MBOOT" && echo "$out" | grep -q "\"isError\":false" && echo "$out" | text_of | grep -q "$(U B)"' "$out"
ok "mcp: and records it as this session's" 'grep -q "^$S1 sleep" "$HOME/.disk-jockey/devices/sim:$(U B)"'
out=$(mcp "$S2" "$(call 4 acquire_simulator)")
ok "mcp: a second session gets a different simulator" 'echo "$out" | text_of | grep -q "Booted iPhone 16 Pro" && ! echo "$out" | text_of | grep -q "$(U B)"' "$out"
out=$(mcp "$S3" "$(call 5 acquire_simulator)")
ok "mcp: at the cap with every simulator held: an error naming the holders" 'echo "$out" | grep -q "\"isError\":true" && echo "$out" | text_of | grep -q "held by another session"' "$out"
out=$(mcp "$S1" "$(call 6 acquire_simulator '{"name":"Duo"}')")
ok "mcp: asking again for your own device returns it" 'echo "$out" | text_of | grep -q "already booted, now recorded as yours"' "$out"
out=$(mcp "$S3" "$(call 7 release_device "{\"device\":\"$(U B)\"}")")
ok "mcp: releasing another session's device is refused" 'echo "$out" | grep -q "\"isError\":true" && grep -qx "$(U B)" "$MBOOT"' "$out"
kill "$S2" 2>/dev/null; wait "$S2" 2>/dev/null
# Git Bash can't see whether a native process is alive, so owners never count as dead on Windows.
is_windows_host && echo "$S3 sleep" >"$HOME/.disk-jockey/devices/sim:$(U A)"
out=$(mcp "$S3" "$(call 8 acquire_simulator)")
is_windows_host || ok "mcp: a device whose owner died is free again" 'echo "$out" | text_of | grep -q "iPhone 16 Pro" && grep -q "^$S3 sleep" "$HOME/.disk-jockey/devices/sim:$(U A)"' "$out"
out=$(mcp "$S1" "$(call 9 disk_status)")
ok "mcp: disk_status shows yours and others'" 'echo "$out" | text_of | grep -q "iPhone Duo ($(U B)): yours" && echo "$out" | text_of | grep -q "iPhone 16 Pro ($(U A)): held by another session"' "$out"
echo '{"session_id":"m1","reason":"prompt_input_exit"}' | PATH="$MB:$PATH" RD_HOOK_SYNC=1 RD_AGENT_PID="$S1 sleep" bash "$S/hooks.sh" session-end
ok "mcp: session end shuts down that session's devices while others run" '! grep -qx "$(U B)" "$MBOOT" && grep -qx "$(U A)" "$MBOOT"' "boot=$(tr '\n' ' ' <"$MBOOT") devs=$(cd "$HOME/.disk-jockey/devices" && for f in *; do printf '%s=%s ' "$f" "$(cat "$f")"; done) S1=$S1 S3=$S3 log=$(tail -3 "$HOME/.disk-jockey/sessions/log" | tr '\n' ' ')"
# Built outside the nested "$( )": bash 3.2 splits an escaped JSON literal with a comma in there.
rel_args=$(printf '{"device":"%s","shutdown":false}' "$(U A)")
out=$(mcp "$S3" "$(call 10 release_device "$rel_args")")
ok "mcp: release with shutdown false leaves it running" '[ ! -e "$HOME/.disk-jockey/devices/sim:$(U A)" ] && grep -qx "$(U A)" "$MBOOT"' "$out"
(cd "$R/app" && g worktree add $W/mcpdone -b agent/mcpdone && cd $W/mcpdone && echo q >q.txt && g add q.txt && g commit -m q && cd "$R/app" && g merge --no-ff agent/mcpdone -m "merge mcpdone")
out=$(mcp "$S3" "$(call 11 worktree_done "{\"repo\":\"$R/app/$W/mcpdone\"}")")
ok "mcp: worktree_done removes the merged worktree" '[ ! -e "$R/app/$W/mcpdone" ] && echo "$out" | text_of | grep -q MERGED' "$out"
ok "mcp: worktree_done leaves REVIEW worktrees" '[ -f "$R/app/$W/dirty/new.txt" ]'
out=$(mcp "$S3" "$(call 12 cleanup_orphans)" '{"jsonrpc":"2.0","id":13,"method":"nope"}')
ok "mcp: cleanup_orphans runs; unknown methods get -32601" 'echo "$out" | head -n 1 | grep -q "\"isError\":false" && echo "$out" | tail -n 1 | grep -q "\"code\":-32601"' "$out"
kill "$S1" "$S3" 2>/dev/null; wait "$S1" "$S3" 2>/dev/null
rm -rf "$HOME/.disk-jockey/devices"

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

echo "== disk-jockey command and install.sh"
REPO_ROOT="$(dirname "$S")"
DJ="$REPO_ROOT/bin/disk-jockey"
ok "command: version matches VERSION" '[ "$(bash "$DJ" --version)" = "disk-jockey $(cat "$REPO_ROOT/VERSION")" ]'
ok "command: unknown subcommand exits 2" 'bash "$DJ" nope >/dev/null 2>&1; [ $? = 2 ]'
ok "command: subcommands reach their script" 'bash "$DJ" clean --help | grep -q "Usage: clean.sh"'
ok "command: every subcommand has --help" 'for c in preflight scan clean worktrees sweep schedule guard dj quarantine hooks autopilot mcp; do bash "$DJ" $c --help 2>/dev/null | grep -q "Usage" || exit 1; done'
if command -v git >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  # Install from a snapshot of the working tree (committed or not) into a throwaway home.
  SRC="$T/src"; mkdir -p "$SRC"
  (cd "$REPO_ROOT" && git ls-files -co --exclude-standard 2>/dev/null | grep -v '^assets/' | tar -cf - -T -) | (cd "$SRC" && tar -xf -)
  (cd "$SRC" && g init && g add -A && g commit -m snapshot)
  IH="$T/ihome"; mkdir -p "$IH"
  inst() { HOME="$IH" DJ_REPO="$SRC" DJ_BIN="$IH/.local/bin" PATH="$PATH" bash "$SRC/install.sh" "$@" 2>&1; }
  out=$(inst)
  ok "install: clone in ~/.agents/skills" '[ -d "$IH/.agents/skills/disk-jockey/.git" ]' "$out"
  ok "install: Claude Code sees the skill" '[ -f "$IH/.claude/skills/disk-jockey/SKILL.md" ]' "$out"
  ok "install: wrapper runs the command" '[ "$(HOME="$IH" bash "$IH/.local/bin/disk-jockey" version)" = "disk-jockey $(cat "$SRC/VERSION")" ]'
  ok "install: PATH hint when bin dir isn't on PATH" 'echo "$out" | grep -q "isn.t on your PATH"'
  out=$(inst)
  ok "install: re-run is idempotent" '[ -d "$IH/.agents/skills/disk-jockey/.git" ] && [ -f "$IH/.claude/skills/disk-jockey/SKILL.md" ]' "$out"
  printf '#!/bin/sh\necho mine\n' >"$IH/.local/bin/disk-jockey"
  ok "install: won't overwrite someone else's disk-jockey" '! inst >/dev/null 2>&1 && grep -q mine "$IH/.local/bin/disk-jockey"'
  rm -f "$IH/.local/bin/disk-jockey"; inst >/dev/null
  # update: on a branch it pulls; pinned to a tag it moves to the newest tag.
  (cd "$SRC" && g tag v0.0.1)
  inst --ref v0.0.1 >/dev/null
  (cd "$SRC" && echo 9.9.9 >VERSION && g commit -am bump && g tag v9.9.9)
  out=$(HOME="$IH" bash "$IH/.local/bin/disk-jockey" update 2>&1)
  ok "update: pinned install moves to the newest release tag" '[ "$(cat "$IH/.agents/skills/disk-jockey/VERSION")" = 9.9.9 ]' "$out"
  out=$(inst --uninstall)
  ok "uninstall: wrapper and link removed, clone kept" '[ ! -e "$IH/.local/bin/disk-jockey" ] && [ ! -e "$IH/.claude/skills/disk-jockey" ] && [ -d "$IH/.agents/skills/disk-jockey" ]' "$out"
  # Legacy layout: a clean clone directly in ~/.claude/skills is moved, not duplicated.
  IH="$T/ihome2"; mkdir -p "$IH/.claude/skills"; git clone -q "$SRC" "$IH/.claude/skills/disk-jockey"
  out=$(inst)
  ok "install: moves an old ~/.claude/skills clone to ~/.agents/skills" '[ -d "$IH/.agents/skills/disk-jockey/.git" ] && [ "$(cd -P "$IH/.claude/skills/disk-jockey" && pwd)" = "$(cd -P "$IH/.agents/skills/disk-jockey" && pwd)" ]' "$out"
  # ...but never moves one with local changes.
  IH="$T/ihome3"; mkdir -p "$IH/.claude/skills"; git clone -q "$SRC" "$IH/.claude/skills/disk-jockey"; echo edit >>"$IH/.claude/skills/disk-jockey/targets.conf"
  out=$(inst)
  ok "install: leaves a modified old clone in place" 'grep -q edit "$IH/.claude/skills/disk-jockey/targets.conf" && [ -d "$IH/.agents/skills/disk-jockey/.git" ]' "$out"
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
# Picker: an IDE cache in a second category gives two selectable rows (Android & JVM, IDEs).
blob "$HOME/.cache/JetBrains/IdeaIC2023.1"; backdate 60 "$HOME/.cache/JetBrains/IdeaIC2023.1/blob" "$HOME/.cache/JetBrains/IdeaIC2023.1"
# Last full screen of picker output, as "mark name" pairs.
picked() { strip_ansi | tr -d '\r' | grep -E '\[[ x+]\] +(Android & JVM|IDEs)' | tail -n 2 | sed -E 's/.*(\[[ x+]\]) +(Android & JVM|IDEs).*/\1 \2/'; }
# Row numbers depend on what else the machine has (macOS lists Xcode report-only data): read them from the table.
table=$(printf 'q\n' | RD_ALLOW_PIPE=1 RD_MENU=numbers RD_IGNORE_CTIME=1 bash "$S/dj.sh" 2>/dev/null | strip_ansi)
row_ides=$(printf '%s\n' "$table" | sed -n 's/^ *\([0-9][0-9]*\) .*IDEs .*/\1/p' | head -n 1)
row_android=$(printf '%s\n' "$table" | sed -n 's/^ *\([0-9][0-9]*\) .*Android & JVM .*/\1/p' | head -n 1)
out=$(printf '%s\nq\n' "$row_ides" | RD_ALLOW_PIPE=1 RD_MENU=numbers RD_IGNORE_CTIME=1 bash "$S/dj.sh" 2>/dev/null | picked)
ok "numbers: typing the IDEs row toggles only IDEs" '[ "$out" = "[x] Android & JVM
[ ] IDEs" ]' "rows: android=$row_android ides=$row_ides || $out"
out=$(printf '%s\nq\n' "$row_android" | RD_ALLOW_PIPE=1 RD_MENU=numbers RD_IGNORE_CTIME=1 bash "$S/dj.sh" 2>/dev/null | picked)
ok "numbers: typing the Android row adds rebuild-cost items" 'echo "$out" | head -n 1 | grep -qF "[+] Android"' "$out"
# Arrow keys: down, space (IDEs off), up, right (Android + rebuild), q.
out=$(printf '\033[B \033[A\033[Cq' | RD_ALLOW_PIPE=1 RD_MENU=arrows RD_IGNORE_CTIME=1 bash "$S/dj.sh" 2>/dev/null | picked)
ok "arrows: down + space + up + right" '[ "$out" = "[+] Android & JVM
[ ] IDEs" ]' "$out"
out=$(printf 'njq' | RD_ALLOW_PIPE=1 RD_MENU=arrows RD_IGNORE_CTIME=1 bash "$S/dj.sh" 2>/dev/null | picked)
ok "arrows: n clears all, j moves" '[ "$out" = "[ ] Android & JVM
[ ] IDEs" ]' "$out"
ok "arrows: q leaves everything in place" '[ -d "$HOME/.cache/JetBrains/IdeaIC2023.1" ] && [ -d "$HOME/.gradle/caches/modules-2" ]'
rm -rf "$HOME/.cache/JetBrains"
# Worktree picker: opt into one REVIEW worktree by its row number; "no" keeps it, "yes" removes it.
(cd "$R/app" && g worktree add $W/rev2 -b agent/rev2 && echo wip >"$W/rev2/wip.txt")
find "$R/app/$W/rev2" -exec touch -t "$(ago 30)" {} + 2>/dev/null
wt_row_of() {
  local p; p=$(bash -c ". '$S/lib.sh'; norm_path '$1'")   # same spelling worktrees.sh prints (matters on Windows)
  NO_COLOR=1 bash "$S/worktrees.sh" --tsv 2>/dev/null | awk -F'\t' -v p="$p" '$1=="REMOVABLE"||$1=="REVIEW"{n++} $4==p{print n; exit}'
}
n=$(wt_row_of "$R/app/$W/rev2")
blob "$R/app/app/build"; backdate 30 "$R/app/app/build/blob" "$R/app/app/build"   # makes the sweep prompt appear
# Keys: n + Enter (no caches), n (no worktrees), rev2's number, Enter, confirmation, sweep n, Go? y, schedule n.
printf 'n\n\nn\n%s\n\nno\nn\ny\nn\n' "$n" | RD_ALLOW_PIPE=1 RD_MENU=numbers bash "$S/dj.sh" >/dev/null 2>&1
ok "picker: found the worktree's row" '[ -n "$n" ]'
ok "picker: REVIEW selection kept when not confirmed" '[ -f "$R/app/$W/rev2/wip.txt" ]'
n=$(wt_row_of "$R/app/$W/rev2")
printf 'n\n\nn\n%s\n\nyes\nn\ny\nn\n' "$n" | RD_ALLOW_PIPE=1 RD_MENU=numbers bash "$S/dj.sh" >/dev/null 2>&1
ok "picker: REVIEW selection removed after typing yes" '[ ! -e "$R/app/$W/rev2" ] && git -C "$R/app" rev-parse -q --verify agent/rev2 >/dev/null'
ok "picker: other REVIEW worktrees untouched" '[ -f "$R/app/$W/dirty/new.txt" ]'
ok "picker: deselected caches and worktrees untouched" '[ -d "$HOME/.gradle/caches/build-cache-1" ] && [ -d "$R/app/$W/dj" ]'
ok "refuses to run without a terminal" '! bash "$S/dj.sh" </dev/null >/dev/null 2>&1'
printf 'q\n' | RD_ALLOW_PIPE=1 bash "$S/dj.sh" >/dev/null 2>&1
ok "q quits without changes" '[ -d "$HOME/.gradle/caches/build-cache-1" ] && [ -d "$R/app/.claude/worktrees/dj" ]'
# Enter = accept preselected safe caches, Enter = accept preselected (REMOVABLE) worktrees,
# n = skip sweep, y = go, n = no schedule
printf '\n\nn\ny\nn\n' | RD_ALLOW_PIPE=1 bash "$S/dj.sh" >/dev/null 2>&1
ok "preselected safe cache cleared" '[ ! -e "$HOME/.gradle/caches/build-cache-1" ]'
ok "rebuild-cost cache kept unless chosen" '[ -d "$HOME/.gradle/caches/modules-2" ]'
ok "confirmed worktree removed" '[ ! -e "$R/app/.claude/worktrees/dj" ]'
ok "dirty worktree still kept" '[ -f "$R/app/$W/dirty/new.txt" ]'
ok "keystore still kept" '[ -f "$HOME/.android/debug.keystore" ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
