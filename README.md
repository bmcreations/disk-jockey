<p align="center">
  <img src="assets/hero.svg" alt="disk-jockey: spins down your simulators, drops your stale tracks, keeps the dance floor clear" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS%20%7C%20Linux-111?style=flat-square&logo=apple&logoColor=white" alt="macOS and Linux">
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="bash 3.2+">
  <img src="https://img.shields.io/badge/Claude-skill-D97757?style=flat-square" alt="Claude skill">
  <img src="https://img.shields.io/badge/tests-43%20passing-3FB950?style=flat-square" alt="43 tests passing">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT license">
</p>

<p align="center">
  <b>Disk hygiene for the agentic era.</b><br>
  Finds what is really eating your drive, then removes only what is provably safe.
</p>

---

## Why this exists

AI agents work in parallel. Each task gets its own git worktree with its own full Gradle or Xcode build. Test runs clone simulators. Daemons, emulators and simulators stay up until memory spills into swap, and swap lives on the same disk.

On one real 1TB machine, free space went from **79G to 2.5G in twenty minutes**. The cause wasn't `~/Library/Caches`:

- **17G of swap** from booted simulators, emulators and idle daemons (kernel_task had written 643GB)
- **37 forgotten agent worktrees** nested in `repo/.claude/worktrees/`, about 1 to 6G each
- **A staged macOS update** whose snapshots pinned every block deleted since

A generic "clear your caches" script finds none of that. disk-jockey checks for it first.

## Quick start

```bash
git clone https://github.com/bmcreations/disk-jockey ~/.claude/skills/disk-jockey
```

Then tell your agent *"my disk is full"*, or drive it yourself:

```bash
~/.claude/skills/disk-jockey/scripts/dj.sh
```

`dj.sh` walks you through four steps: preflight fixes, pick categories, review worktrees, apply. Prefer individual commands?

```bash
cd ~/.claude/skills/disk-jockey
scripts/preflight.sh          # memory, swap and snapshots, before touching files
scripts/scan.sh               # where the space is, by tier
scripts/worktrees.sh ~/dev    # stale agent worktrees
scripts/clean.sh              # dry run; add --apply to act
```

## See it work

**Interactive mode.** Pick categories by number. Safe caches are preselected, rebuild-cost items are one more press, and report-only data can't be selected at all.

<p align="center"><img src="assets/dj.svg" alt="dj.sh category picker showing safe, rebuild and keep sizes per category" width="85%"></p>

**Step one is always: is it really files?**

<p align="center"><img src="assets/preflight.svg" alt="preflight.sh output showing 2.5G free, load 287, 17G swap, booted simulators and staged OS update snapshots" width="100%"></p>

**Then the usual biggest win: agent worktrees.** Merged and clean ones go. Anything dirty, unpushed, recently touched or in use by a running agent stays.

<p align="center"><img src="assets/worktrees.svg" alt="worktrees.sh audit listing removable, review, active, in-use and stale worktrees" width="100%"></p>

## How it works

<p align="center"><img src="assets/pipeline.svg" alt="Pipeline: preflight, scan, worktrees, clean, sweep, then prevent with a schedule and guard hook" width="100%"></p>

| Script | What it does |
|---|---|
| `dj.sh` | Interactive mode for humans: one-key preflight fixes, category picker, worktree and sweep prompts, before/after summary |
| `preflight.sh` | Free space, load, swap, booted simulators, emulators, idle Gradle/Kotlin daemons, active builds, agent count, APFS snapshots, uptime |
| `scan.sh` | Sizes 60+ known targets across Xcode, simulators, Android, Gradle, Kotlin/Native, Node, Python, Go, Rust, Homebrew, Docker and Playwright |
| `worktrees.sh` | Audits every linked worktree, nested ones included. Detects squash-merged PRs with `gh` |
| `clean.sh` | Tiered cleanup with the tools' own commands where they exist (`simctl`, `brew cleanup`, `pnpm store prune`) |
| `sweep.sh` | `build/`, `.gradle`, `node_modules`, `target/`, `.build` in projects idle for N days |
| `schedule.sh` | Daily tier-1 cleanup, only when free space drops below a threshold (launchd or systemd) |
| `disk-guard.sh` | One-line low-disk warning for agent SessionStart hooks |

## Safe by default

| Tier | What | Behavior |
|:---:|---|---|
| **1** | Pure caches: DerivedData, XCTest clones, build caches, package caches | `clean.sh --apply` |
| **2** | Costs a re-download or rebuild: Gradle dependencies, DeviceSupport, Maven, Cargo | Opt in with `--tier 2` |
| **3** | Holds real data: Xcode archives (dSYMs), AVDs, simulators, agent transcripts, models | Reported, **never deleted** |

- **Dry run first**, every script. Nothing is deleted without `--apply`.
- **Protected paths** can't be deleted, nor any folder containing them: `debug.keystore`, `gradle.properties` (signing secrets), `.ssh`, Keychains, provisioning profiles, agent settings.
- **Busy checks.** A target is skipped while a process using it runs (`xcodebuild`, `GradleDaemon`, `qemu-system`).
- **Symlinks** are never followed or deleted.
- **Color** only on an interactive terminal. Agents reading through a pipe get plain text. `NO_COLOR=1` turns it off, `FORCE_COLOR=1` forces it.
- **Worktrees** are removed only via `git worktree remove`, which itself refuses dirty trees. Branches are kept.
- **Sweep** deletes a build folder only next to its build file, and never anything git tracks.

## Keep the floor clear

```bash
scripts/schedule.sh install --threshold 50G
```

Warn agents before heavy work. In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/skills/disk-jockey/scripts/disk-guard.sh 20G" } ] }
    ]
  }
}
```

<details>
<summary><b>FAQ</b></summary>

**Why not just `rm -rf ~/Library/Developer/Xcode/DerivedData`?**
That's tier 1 here too. But if swap or a staged OS update is what's filling the disk, the space comes back within hours. `preflight.sh` tells you which problem you have.

**Will it delete my work?**
Not through the scripts. Uncommitted or unpushed worktrees are reported as `REVIEW` and left alone. Tier 3 is report-only. Every deletion path is covered by `tests/run.sh`.

**Does it need sudo?**
No. Deleting Time Machine local snapshots does, and the script prints that command for you rather than running it.

**Running in a sandbox VM with your home mounted?**
Run the scripts natively instead. Worktree `.git` files contain host paths, and `du` over a mount is very slow.

</details>

## Add a target

Every target is one line in [`targets.conf`](targets.conf):

```
tier|id|os|paths|action|busy|note
1|xctest-devices|mac|~/Library/Developer/XCTestDevices/*|rm|xcodebuild|Simulator clones from parallel test runs
```

Actions are `rm`, `stale:DAYS`, `cmd:COMMAND` and `report`. Run `bash tests/run.sh` before opening a PR. It builds a throwaway home with worktrees, protected files and caches, and checks every guard.

## License

[MIT](LICENSE)
