---
name: disk-jockey
description: Diagnose and safely reclaim disk space on developer machines filled by AI agents, worktrees, builds, simulators, emulators and toolchain caches (Xcode, Android/Gradle, Node, Docker, Python, Rust, Go). Use when disk is low or filling fast, builds fail with "No space left on device", kernel_task shows huge disk writes, or the user asks to clean up storage.
---

# disk-jockey

Spins down your simulators, drops your stale tracks, keeps the dance floor clear.

Agentic workflows fill disks in new ways: one git worktree per task, each with a full build; parallel test runs cloning simulators; daemons and simulators left running until memory spills into swap. This skill finds the real cause first, then deletes only what is provably safe.

All scripts are in `scripts/`, read-only by default, and need only bash 3.2+ (stock macOS) and standard tools.

## Safety contract

- **Never delete without a dry run shown to the user first.** Every script defaults to a dry run; `--apply` acts.
- **Get confirmation before `--apply`**, unless the user explicitly said to go ahead for that tier.
- **Tier 3 is never deleted by you.** Show the size and give the user the command.
- **Never hand-roll `rm -rf`** for something the scripts don't cover. Add a line to `targets.conf` instead so it gets the guards: protected paths, symlink refusal, busy-process skip.
- **Never `git worktree remove --force` or delete branches** unless the user names the worktree or branch and accepts losing its uncommitted changes.
- **Respect the user's quarantine setting.** Check `scripts/quarantine.sh status` before `--apply`. If it's on, cleanup moves items aside instead of deleting them, which frees no space until they're purged. When the disk is critically low and quarantine is on, say so and ask before using `--no-quarantine` or `quarantine purge`; never change the setting yourself.
- Protected regardless of config: `~/.android/debug.keystore`, `~/.gradle/gradle.properties` (signing secrets), `~/.ssh`, `~/.gnupg`, Keychains, provisioning profiles, agent settings and skills (`~/.claude/skills`, `~/.agents/skills`). Directories containing them are protected too.

## Interactive mode is for humans

`scripts/dj.sh` is a guided, colorful version of this whole workflow for a person at a terminal. It refuses to run without one. When the user wants to drive cleanup themselves, tell them to run `disk-jockey` in their own terminal (installed by `install.sh`), or `scripts/dj.sh` from this skill's folder (usually `~/.agents/skills/disk-jockey`). As an agent, use the individual scripts below; their output is plain text when piped.

If the user wants specific REVIEW worktrees removed, show the uncommitted and local-commit counts from `worktrees.sh`, get explicit confirmation for each, then run `worktrees.sh --apply --select PATH [--select PATH ...]`. That discards their uncommitted changes and keeps their commits on their branches. A detached worktree with local commits is always refused, since no branch would keep those commits.

## Workflow

### 1. Pre-flight: is it really files?
```bash
scripts/preflight.sh
```
Checks free space, load average, swap, booted simulators, emulators, idle Gradle/Kotlin daemons, active builds, agent process count, APFS snapshots and uptime.

**Resolve WARN rows about memory or snapshots before deleting anything.** Deleting caches does not help if swap refills the disk.
- Huge `kernel_task` disk writes in Activity Monitor are swap. Fix: `xcrun simctl shutdown all` (keeps simulator data), close idle emulators, `pkill -f GradleDaemon; pkill -f KotlinCompileDaemon` when no build runs, then reboot to delete the swap files.
- `os-update-snapshots`: a staged macOS update pins every block deleted since it was staged. Installing the update releases it. `tmutil deletelocalsnapshots` does not remove these.
- `btrfs-snapshots`, `zfs-snapshots`, `lvm-snapshots` (Linux): snapshots keep deleted blocks allocated. Show the user the listing command from the advice column; deleting snapshots needs their decision and usually `sudo`.
- `docker-reclaimable`, `podman-reclaimable`: what the engine itself says it can free. Container storage is invisible to `du`.
- `timemachine-snapshots`: `sudo tmutil deletelocalsnapshots /` (backups on the external drive are unaffected).

- `memory-pressure` WARN and the `mem:*` INFO rows: which group holds the RAM (simulators, emulators, Claude sessions, the Claude app, Gradle/Kotlin daemons). On a machine running several agent sessions, this is usually the real problem, not disk. Offer the session hooks (step 7).

Ask before stopping simulators, emulators or daemons. An agent may be mid-test.

### 2. Measure
```bash
scripts/scan.sh          # human table, sorted by size, grouped by tier
scripts/scan.sh --tsv    # for parsing
```
Tells you where space is in known caches. If known targets add up to far less than used space, look at project folders (steps 3 and 4) and tier 3 items.

### 3. Agent worktrees (usually the biggest win)
```bash
scripts/worktrees.sh [root ...]              # audit
scripts/worktrees.sh --apply [root ...]      # remove REMOVABLE only
```
Finds every linked worktree of every repo under the roots, including ones nested inside repos (e.g. `repo/.claude/worktrees/NAME`). States:

| State | Meaning | Action |
|---|---|---|
| REMOVABLE | Clean, no commits that exist only locally (or its PR is merged, checked with `gh`), idle, no process inside | Removed by `--apply` via `git worktree remove` (refuses dirty trees) |
| REVIEW | Uncommitted changes or local-only commits | Show the user the counts. Never auto-removed |
| ACTIVE | Files changed in the last `--idle-days` (default 3) | Leave |
| IN-USE | A process (agent, shell, daemon) has its cwd inside | Leave |
| LOCKED | `git worktree lock`ed | Leave |
| STALE-REF | Directory gone, git still lists it | `--apply` prunes the entry |

Roots default to `~/code ~/dev ~/src ~/Projects ~/Developer ~/workspace ~/repos ~/git ~/work` and IDE project folders, or `RD_ROOTS="a:b"`. Removing a worktree keeps its branch, so committed work survives. Worktrees that tools keep elsewhere (`~/.codex/worktrees`, `~/.cursor/worktrees`, Conductor workspaces) are found through their main repo.

**After your own PR merges** (you opened it from a worktree, and the user or `gh pr view` says it's merged), clean up without waiting for the idle period:
```bash
cd <main checkout> && scripts/worktrees.sh --merged --apply
```
`--merged` acts only on clean worktrees whose PR is merged (via `gh`) or whose branch is merged into main or `origin/HEAD`. It scopes to the repo you're in. Run it from the main checkout: from inside the worktree it reports IN-USE and does nothing. This is safe to do without asking when the worktree is one you created for that PR; for other merged worktrees, show the dry run first.

### Undo (opt-in quarantine)
```bash
scripts/quarantine.sh status | list
scripts/quarantine.sh restore --last | ID | ORIGINAL_PATH
scripts/quarantine.sh purge [--all]
```
Off by default. When the user wants a way back, offer `--quarantine` on `clean.sh`, `sweep.sh` or `worktrees.sh` for one run, or `quarantine.sh on --days N` to make it the default (their call). Worktrees are moved with `git worktree move`, so a quarantined REVIEW worktree keeps its uncommitted changes and restore re-registers it. Tool-run cleanups are skipped while it's on (they can't be undone). Items older than the retention are purged on the next `--apply`.

### 4. Tiered cache cleanup
```bash
scripts/clean.sh                        # dry run, tier 1
scripts/clean.sh --apply                # tier 1: pure caches
scripts/clean.sh --tier 2               # dry run incl. re-download/rebuild cost
scripts/clean.sh --apply --tier 2 --only gradle-modules,xcode-device-support
```
Targets running tools are skipped automatically (busy check). Tool-managed caches are cleaned with the tool's own command (`npm cache clean`, `pnpm store prune`, `brew cleanup`, `xcrun simctl delete unavailable`, `docker builder prune`). Tier 2 items: ask per target, stating the cost (e.g. "next build re-downloads ~4G of dependencies").

### Orphaned build folders (always safe)
```bash
scripts/clean.sh --orphans            # dry run
scripts/clean.sh --orphans --apply
```
Xcode DerivedData and XcodeBuildMCP workspaces whose recorded project no longer exists (deleted worktrees). Safe to run without asking once the user has asked for cleanup: nothing whose project still exists, or that records no project, is touched. The session hooks and the daily schedule run it automatically.

### 5. Build outputs in idle projects
```bash
scripts/sweep.sh [--days 14] [root ...]
scripts/sweep.sh --apply
```
Deletes `build/`, `.gradle/`, `.cxx/`, `.kotlin/`, `node_modules`, `.next`, `target/`, `.build`, `Pods/`, `.venv`, project-local `DerivedData` in projects and worktrees with no commit and no git activity for N days. A directory is only deleted when its build-file sibling exists (e.g. `build/` next to `build.gradle*`), never when git tracks it (committed `Pods/` stay), and never while a process works in that project.

### 6. Verify
Compare free space before and after. If much less was freed than expected on macOS, re-run `preflight.sh`: snapshots or swap are holding it.

### 7. Prevent (offer once the disk is healthy)
- **Autopilot (offer first):** `scripts/autopilot.sh on --target 80G --floor 20G` installs a per-user background job that keeps free space above the target without anyone running disk-jockey: build folders of deleted projects and merged worktrees always, then idle build output oldest first while space is short, and a notification when only the user can fix the rest. Never tier 2/3, REVIEW worktrees or anything in use. `scripts/autopilot.sh run --dry-run` shows a pass. Ask before turning it on; it acts on its own afterwards.
- **Scheduled cleanup:** `scripts/schedule.sh install --threshold 50G` runs tier 1 daily, only when free space drops below the threshold (launchd on macOS, systemd user timer on Linux, Task Scheduler on Windows).
- **Session hooks:** `scripts/hooks.sh print` shows a Claude Code `settings.json` snippet. PreToolUse caps booted devices across all sessions (default 2 simulators, 1 emulator; `hooks.sh limit` changes it) and warns agents before builds under memory pressure. SessionStart records which simulators and emulators are running and warns on low disk or memory pressure; when the last agent session exits, SessionEnd shuts down what was booted since (nothing while another session runs). Show the user the snippet; don't edit their `settings.json` without consent. Other agents can call `hooks.sh session-start --session ID` and `session-end --session ID`.
- **Worktree hygiene:** add a line to the project's `CLAUDE.md` / `AGENTS.md`: "After a PR from a worktree merges, run `disk-jockey worktrees --merged --apply` from the main checkout."
- **Per-task cleanup:** without the hooks, at the end of a task shut down simulators the task booted (`xcrun simctl shutdown UDID`), close emulators it started, and stop Gradle daemons when no build runs.
- **Transcript retention:** agent transcripts (`~/.claude/projects`) grow without limit unless retention is configured. Point the user to their agent's retention setting.

## Failure modes to tell the user about

- **Device cap denials.** With the hooks installed, a boot over the cap is denied with a list of booted devices. Reuse one of those by UDID. When loupe is running, the list marks each device free, claimed or hands off: pick a free one, claim it with the curl the message gives (it carries your session id), and never drive one another session claimed. Don't try to get around the cap (other boot commands, killing other sessions' devices); ask the user to raise it or free a device.

- **Swap refills the disk.** Cleanup without fixing memory pressure buys hours, not days.
- **Snapshots hide freed space.** Deleted files stay on disk until APFS snapshots are thinned or the staged update installs.
- **Agent scratch in /tmp.** `claude-scratch` clears Claude Code session scratchpads (`/private/tmp/claude-UID/PROJECT/SESSION` on macOS, `/tmp/...` on Linux) untouched for 3 days, yours only. A session resumed after that loses its scratch files, never its transcript.
- **Quarantine holds space.** Moving to quarantine frees nothing until a purge. Items on a different disk than `~/.disk-jockey` are left in place rather than copied. A quarantined worktree still has its branch checked out, so that branch can't be checked out elsewhere until it's restored or purged.
- **Session hooks shut down devices the user booted mid-session too** (everything booted after the first session started). Simulators keep their data; emulators save quickboot state.
- **Rebuild cost.** Clearing DerivedData, Gradle caches or `build/` makes the next build cold. Don't do it right before a demo or release build.
- **`Xcode/Archives` holds dSYMs.** Deleting them breaks crash symbolication for shipped builds. Tier 3 for that reason.
- **AVD and simulator deletion loses app state** (logins, test data). Only quickboot snapshots are tier 1.
- **No way to see process working directories** (no `/proc`, `lsof` missing or failing): `worktrees.sh --apply` and `sweep.sh --apply` exit with code 3 instead of guessing. Tell the user to install `lsof`; only set `RD_SKIP_INUSE_CHECK=1` if they explicitly accept that a running agent's worktree could be deleted.
- **Windows:** run everything in Git Bash, not PowerShell or cmd. Native programs' working folders aren't visible to `/proc`, so `--apply` test-renames each folder first and skips it if Windows says it's in use (expect a few false "in use" skips while antivirus scans; they're safe). WSL and Docker Desktop `.vhdx` disks only shrink when compacted: tell the user to prune inside them first, then follow the advice in scan's note. Pagefile, hibernation file, restore points and Windows Update cleanup need an admin terminal: give the user the command, don't try to elevate.
- **Running in a VM with a mounted home** (some agent sandboxes): worktree `.git` files hold host paths, so git fails there, and mounts make `du` very slow. Run these scripts natively on the host.
- **Scheduled runs can't see `~/Documents`, `~/Desktop` or iCloud folders** on macOS without Full Disk Access. Install the skill elsewhere, e.g. `~/.agents/skills/disk-jockey`.

## Extending

Add lines to `targets.conf` (format documented at its top). Run `bash tests/run.sh` after changes; it builds a fake home and checks every guard.
