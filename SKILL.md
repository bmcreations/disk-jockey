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
- Protected regardless of config: `~/.android/debug.keystore`, `~/.gradle/gradle.properties` (signing secrets), `~/.ssh`, `~/.gnupg`, Keychains, provisioning profiles, agent settings and skills. Directories containing them are protected too.

## Interactive mode is for humans

`scripts/dj.sh` is a guided, colorful version of this whole workflow for a person at a terminal. It refuses to run without one. When the user wants to drive cleanup themselves, tell them to run `~/.claude/skills/disk-jockey/scripts/dj.sh` in their own terminal. As an agent, use the individual scripts below; their output is plain text when piped.

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

Roots default to `~/code ~/dev ~/src ~/Projects ~/Developer ~/workspace ~/repos ~/git ~/work` and IDE project folders, or `RD_ROOTS="a:b"`. Removing a worktree keeps its branch, so committed work survives.

### 4. Tiered cache cleanup
```bash
scripts/clean.sh                        # dry run, tier 1
scripts/clean.sh --apply                # tier 1: pure caches
scripts/clean.sh --tier 2               # dry run incl. re-download/rebuild cost
scripts/clean.sh --apply --tier 2 --only gradle-modules,xcode-device-support
```
Targets running tools are skipped automatically (busy check). Tool-managed caches are cleaned with the tool's own command (`npm cache clean`, `pnpm store prune`, `brew cleanup`, `xcrun simctl delete unavailable`, `docker builder prune`). Tier 2 items: ask per target, stating the cost (e.g. "next build re-downloads ~4G of dependencies").

### 5. Build outputs in idle projects
```bash
scripts/sweep.sh [--days 14] [root ...]
scripts/sweep.sh --apply
```
Deletes `build/`, `.gradle/`, `.cxx/`, `.kotlin/`, `node_modules`, `.next`, `target/`, `.build`, `Pods/`, `.venv`, project-local `DerivedData` in projects and worktrees with no commit and no git activity for N days. A directory is only deleted when its build-file sibling exists (e.g. `build/` next to `build.gradle*`), never when git tracks it (committed `Pods/` stay), and never while a process works in that project.

### 6. Verify
Compare free space before and after. If much less was freed than expected on macOS, re-run `preflight.sh`: snapshots or swap are holding it.

### 7. Prevent (offer once the disk is healthy)
- **Scheduled cleanup:** `scripts/schedule.sh install --threshold 50G` runs tier 1 daily, only when free space drops below the threshold (launchd on macOS, systemd user timer on Linux).
- **Agent guard:** `scripts/disk-guard.sh 20G` prints a warning when space is low; wire it into an agent SessionStart hook so agents see it before heavy work.
- **Worktree hygiene:** remove a worktree when its PR is merged; run `worktrees.sh` weekly.
- **Per-task cleanup:** at the end of a task, `xcrun simctl shutdown all` for simulators the task booted, close emulators it started, and stop Gradle daemons.
- **Transcript retention:** agent transcripts (`~/.claude/projects`) grow without limit unless retention is configured. Point the user to their agent's retention setting.

## Failure modes to tell the user about

- **Swap refills the disk.** Cleanup without fixing memory pressure buys hours, not days.
- **Snapshots hide freed space.** Deleted files stay on disk until APFS snapshots are thinned or the staged update installs.
- **Rebuild cost.** Clearing DerivedData, Gradle caches or `build/` makes the next build cold. Don't do it right before a demo or release build.
- **`Xcode/Archives` holds dSYMs.** Deleting them breaks crash symbolication for shipped builds. Tier 3 for that reason.
- **AVD and simulator deletion loses app state** (logins, test data). Only quickboot snapshots are tier 1.
- **No way to see process working directories** (no `/proc`, `lsof` missing or failing): `worktrees.sh --apply` and `sweep.sh --apply` exit with code 3 instead of guessing. Tell the user to install `lsof`; only set `RD_SKIP_INUSE_CHECK=1` if they explicitly accept that a running agent's worktree could be deleted.
- **Running in a VM with a mounted home** (some agent sandboxes): worktree `.git` files hold host paths, so git fails there, and mounts make `du` very slow. Run these scripts natively on the host.
- **Scheduled runs can't see `~/Documents`, `~/Desktop` or iCloud folders** on macOS without Full Disk Access. Install the skill elsewhere, e.g. `~/.claude/skills/disk-jockey`.

## Extending

Add lines to `targets.conf` (format documented at its top). Run `bash tests/run.sh` after changes; it builds a fake home and checks every guard.
