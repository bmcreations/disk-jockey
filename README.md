# disk-jockey

Spins down your simulators, drops your stale tracks, and keeps the dance floor clear.

A skill (and plain shell scripts) for keeping developer machines from filling up in the agentic era.

AI agents work in parallel: one git worktree per task, each with a full Gradle or Xcode build; test runs that clone simulators; daemons, emulators and simulators left running until memory spills into swap. A 1TB drive can go from fine to full in days, and most of what fills it is either regenerable or already merged.

disk-jockey finds the actual cause, then deletes only what is provably safe, with a dry run first every time.

## What it handles

| Problem | Script |
|---|---|
| Disk filling with no new files (swap, booted simulators, idle daemons, APFS / OS-update snapshots) | `preflight.sh` |
| Known caches: Xcode, simulators, XCTest clones, Gradle, Android, Kotlin/Native, npm/pnpm/yarn/bun, pip/uv, Go, Cargo, Homebrew, Docker, Playwright | `scan.sh`, `clean.sh` |
| Agent worktrees left behind after the PR merged, including ones nested in `repo/.claude/worktrees/` | `worktrees.sh` |
| `build/`, `node_modules`, `.gradle`, `target/`, `.build` in idle projects | `sweep.sh` |
| Keeping it from happening again | `schedule.sh`, `disk-guard.sh` |

macOS and Linux. Bash 3.2+, no dependencies (`gh` optional, for detecting squash-merged PRs).

## Install

**As a Claude Code skill:**
```bash
git clone https://github.com/bmcreations/disk-jockey ~/.claude/skills/disk-jockey
```
Then ask your agent something like "my disk is full" or "clean up storage".

**As a claude.ai skill:** zip the folder and upload it as a custom skill.

**Without an agent:** run the scripts directly.

## Quick start

```bash
cd ~/.claude/skills/disk-jockey
scripts/preflight.sh            # is it memory/snapshots, or files?
scripts/scan.sh                 # where is the space, by tier
scripts/worktrees.sh            # stale agent worktrees
scripts/clean.sh                # dry run of tier 1 caches
scripts/clean.sh --apply        # do it
```

## Safety model

- **Dry run by default.** Nothing is deleted without `--apply`.
- **Tiers.** 1: pure caches. 2: costs a re-download or rebuild, opt in with `--tier 2`. 3: report only, never deleted (Xcode archives with dSYMs, AVDs, simulators with data, agent transcripts, models).
- **Protected paths.** `~/.android/debug.keystore`, `~/.gradle/gradle.properties`, `~/.ssh`, `~/.gnupg`, Keychains, provisioning profiles, agent settings, and any directory containing them. Add more with `RD_PROTECT="path1:path2"`.
- **Busy checks.** A target is skipped while a process that uses it is running (`xcodebuild`, `GradleDaemon`, `qemu-system`, ...).
- **Symlinks are never followed or deleted.**
- **Worktrees.** Removed only through `git worktree remove` (which itself refuses dirty trees), only when clean, with no local-only commits, idle, and with no process inside. Branches are kept.
- **Sweep.** Deletes a build dir only when its build file sibling exists, and never anything git tracks.

## Keep it healthy

```bash
scripts/schedule.sh install --threshold 50G   # daily tier-1 cleanup, only below 50G free
scripts/schedule.sh status
scripts/schedule.sh uninstall
```

Warn agents before heavy work with a SessionStart hook in `~/.claude/settings.json`:
```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/skills/disk-jockey/scripts/disk-guard.sh 20G" } ] }
    ]
  }
}
```

## Extending

Every target is one line in `targets.conf`:
```
tier|id|os|paths|action|busy|note
1|xctest-devices|mac|~/Library/Developer/XCTestDevices/*|rm|xcodebuild|Simulator clones from parallel test runs
```
Actions: `rm`, `stale:DAYS`, `cmd:COMMAND`, `report`. Run `bash tests/run.sh` before opening a PR; it builds a throwaway home with worktrees, protected files and caches and checks every guard.

## License

MIT
