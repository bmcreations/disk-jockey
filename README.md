<p align="center">
  <img src="assets/hero.svg" alt="disk-jockey: spins down your simulators, drops your stale tracks, keeps the dance floor clear" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS%20%7C%20Linux%20%7C%20Windows-111?style=flat-square" alt="macOS, Linux and Windows">
  <img src="https://img.shields.io/badge/bash-3.2%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="bash 3.2+">
  <img src="https://img.shields.io/badge/skill-Claude%20Code%20%7C%20Codex%20%7C%20Cursor-D97757?style=flat-square" alt="Agent skill for Claude Code, Codex and Cursor">
  <a href="https://github.com/bmcreations/disk-jockey/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/bmcreations/disk-jockey/ci.yml?branch=main&style=flat-square&label=tests" alt="CI status"></a>
  <a href="https://github.com/bmcreations/disk-jockey/releases/latest"><img src="https://img.shields.io/github/v/release/bmcreations/disk-jockey?style=flat-square&label=release" alt="Latest release"></a>
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
curl -fsSL https://github.com/bmcreations/disk-jockey/releases/latest/download/install.sh | bash
```

That installs the latest release once for every agent and adds a `disk-jockey` command:

- `~/.agents/skills/disk-jockey` is the copy Codex and Cursor read.
- `~/.claude/skills/disk-jockey` links to it for Claude Code (a junction on Windows, so no Developer Mode needed).
- `~/.local/bin/disk-jockey` is the command (`~/bin` in Git Bash). If that folder isn't on your PATH, the installer prints the line to add.

An existing clone in `~/.claude/skills` is moved to the shared location rather than duplicated. Update with `disk-jockey update`; remove with `bash ~/.agents/skills/disk-jockey/install.sh --uninstall`.

Then tell your agent *"my disk is full"*, or drive it yourself:

```bash
disk-jockey                 # interactive: preflight fixes, pick categories, pick worktrees, apply
disk-jockey preflight       # memory, swap and snapshots, before touching files
disk-jockey scan            # where the space is, by tier
disk-jockey worktrees ~/dev # stale agent worktrees
disk-jockey clean           # dry run; add --apply to act
disk-jockey quarantine on   # optional: move instead of delete, with undo
```

Arrow keys move, space toggles, Enter continues. Every command takes `--help`.

<details>
<summary><b>Other ways to install</b></summary>

**Follow `main` instead of releases:**
```bash
curl -fsSL https://raw.githubusercontent.com/bmcreations/disk-jockey/main/install.sh | bash
```

**Manually, without the installer:**
```bash
git clone https://github.com/bmcreations/disk-jockey ~/.agents/skills/disk-jockey
mkdir -p ~/.claude/skills && ln -s ~/.agents/skills/disk-jockey ~/.claude/skills/disk-jockey
```
Then run `~/.agents/skills/disk-jockey/bin/disk-jockey`, or the scripts in `scripts/` directly.

**claude.ai:** download `disk-jockey-vX.Y.Z.zip` from [Releases](https://github.com/bmcreations/disk-jockey/releases/latest) and upload it as a custom skill.

**Pin a version:** `bash install.sh --ref v0.2.0`

</details>

## See it work

**Interactive mode.** Arrow keys and space, like an installer. Safe caches are preselected, rebuild-cost items are one more press (or right arrow), and report-only data can't be selected at all. The worktree step works the same way: REMOVABLE worktrees start selected, and REVIEW ones (uncommitted or unpushed work) can be opted in after typing `yes`. Their commits stay on their branches; only uncommitted changes are discarded.

<p align="center"><img src="assets/dj.svg" alt="dj.sh category picker showing safe, rebuild and keep sizes per category" width="85%"></p>

**Step one is always: is it really files?**

<p align="center"><img src="assets/preflight.svg" alt="preflight.sh output showing 2.5G free, load 287, 17G swap, booted simulators and staged OS update snapshots" width="100%"></p>

**Then the usual biggest win: agent worktrees.** Merged and clean ones go. Anything dirty, unpushed, recently touched or in use by a running agent stays.

<p align="center"><img src="assets/worktrees.svg" alt="worktrees.sh audit listing removable, review, active, in-use and stale worktrees" width="100%"></p>

## How it works

<p align="center"><img src="assets/pipeline.svg" alt="Pipeline: preflight, scan, worktrees, clean, sweep, then prevent with a schedule and guard hook" width="100%"></p>

| Script | What it does |
|---|---|
| `dj.sh` | Interactive mode for humans: one-key preflight fixes, arrow-key pickers for categories and worktrees, before/after summary |
| `preflight.sh` | Free space, load, swap, booted simulators, emulators, idle Gradle/Kotlin daemons, active builds, agent count, APFS snapshots, uptime |
| `scan.sh` | Sizes 90+ known targets across Xcode, simulators, Android, Gradle, Node, Python, Go, Rust, Flutter, Docker, editors, Electron apps, game engines and version managers |
| `worktrees.sh` | Audits every linked worktree, nested ones included. Detects squash-merged PRs with `gh`. `--merged` cleans up right after a merge |
| `clean.sh` | Tiered cleanup with the tools' own commands where they exist (`simctl`, `brew cleanup`, `pnpm store prune`) |
| `sweep.sh` | `build/`, `.gradle`, `node_modules`, `target/`, `.build` in projects idle for N days |
| `schedule.sh` | Daily tier-1 cleanup, only when free space drops below a threshold (launchd or systemd) |
| `quarantine.sh` | Opt-in undo: cleanup moves items aside for N days instead of deleting them |
| `hooks.sh` | Agent session hooks: shut down simulators and emulators that agent sessions booted |
| `disk-guard.sh` | One-line low-disk warning for agent SessionStart hooks |

Each script is also a `disk-jockey` subcommand: `disk-jockey scan`, `disk-jockey worktrees`, and so on (`dj.sh` is plain `disk-jockey`).

## Safe by default

| Tier | What | Behavior |
|:---:|---|---|
| **1** | Pure caches: DerivedData, XCTest clones, build caches, package caches | `clean.sh --apply` |
| **2** | Costs a re-download or rebuild: Gradle dependencies, DeviceSupport, Maven, Cargo | Opt in with `--tier 2` |
| **3** | Holds real data: Xcode archives (dSYMs), AVDs, simulators, agent transcripts, models | Reported, **never deleted** |

- **Dry run first**, every script. Nothing is deleted without `--apply`.
- **Protected paths** can't be deleted, nor any folder containing them: `debug.keystore`, `gradle.properties` (signing secrets), `.ssh`, Keychains, provisioning profiles, agent settings.
- **Busy checks.** A target is skipped while a process using it runs (`xcodebuild`, `GradleDaemon`, `qemu-system`).
- **In-use checks fail safe.** Worktrees and projects with a process inside are skipped (read from `/proc` on Linux and Git Bash, `lsof` on macOS). On Windows, each folder is also test-renamed right before deletion: Windows refuses that while any program has the folder open. If processes can't be inspected at all, `--apply` refuses to run rather than assuming nothing is in use.
- **Only your files.** Deletion happens under your home folder, plus agent scratch two levels inside `/tmp` (Claude Code keeps per-session scratchpads in `/private/tmp/claude-UID` on macOS), and only folders you own that nobody touched for 3 days.
- **Symlinks** are never followed or deleted.
- **Color** only on an interactive terminal. Agents reading through a pipe get plain text. `NO_COLOR=1` turns it off, `FORCE_COLOR=1` forces it.
- **Worktrees** are removed only via `git worktree remove`, which refuses dirty trees. The one exception is a REVIEW worktree you select yourself and confirm by typing `yes`: its uncommitted changes are discarded, its commits stay on its branch. Branches are never deleted.
- **Sweep** deletes a build folder only next to its build file, and never anything git tracks.

## Undo, if you want it

Off by default, because a held item frees no space until it's purged. Turn it on when you'd rather be able to take something back:

```bash
disk-jockey quarantine on --days 7   # clean, sweep and worktrees now move instead of delete
disk-jockey quarantine list
disk-jockey quarantine restore --last
disk-jockey quarantine purge --all   # free the space now
```

Or for a single run: `disk-jockey clean --apply --quarantine`. Worktrees are moved with `git worktree move`, so even a REVIEW worktree's uncommitted changes come back on restore. Items older than the retention are purged on the next `--apply`. Tool-run cleanups (`npm cache clean`, `brew cleanup`) can't be undone, so they're skipped while quarantine is on, and anything on a different disk than `~/.disk-jockey` is left in place rather than copied.

## Keep the floor clear

**Clean up worktrees the moment a PR merges.** The agent that opened the PR knows when it merged. Tell it, or put it in your `CLAUDE.md` / `AGENTS.md`:

```bash
cd <main checkout> && disk-jockey worktrees --merged --apply
```

`--merged` only touches clean worktrees whose PR is merged (checked with `gh`) or whose branch is merged into main, regardless of how recently they were used. Run from inside the worktree itself, it refuses and tells you where to `cd`.

**Shut down simulators and emulators when the agents are done.** `disk-jockey hooks` prints a Claude Code `settings.json` snippet. The first session to start records what's already running; when the last one exits, everything booted since is shut down (simulators keep their data). While any other session is running, nothing is touched. The same hook warns agents when free space is low.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash ~/.agents/skills/disk-jockey/scripts/hooks.sh session-start --guard 20G", "timeout": 10 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "bash ~/.agents/skills/disk-jockey/scripts/hooks.sh session-end", "timeout": 15 } ] }
    ]
  }
}
```

Other agents can call `hooks.sh session-start --session ID` and `session-end --session ID` from their own hooks.

**Daily safety net.** Tier 1 cleanup, only when free space drops below a threshold:

```bash
disk-jockey schedule install --threshold 50G
```

<details>
<summary><b>FAQ</b></summary>

**Why not just `rm -rf ~/Library/Developer/Xcode/DerivedData`?**
That's tier 1 here too. But if swap or a staged OS update is what's filling the disk, the space comes back within hours. `preflight.sh` tells you which problem you have.

**Will it delete my work?**
Not through the scripts. Uncommitted or unpushed worktrees are reported as `REVIEW` and left alone. Tier 3 is report-only. Every deletion path is covered by `tests/run.sh`.

**Does it need sudo?**
No. Deleting Time Machine local snapshots does, and the script prints that command for you rather than running it.

**Which platforms are covered?**
macOS, Linux and Windows, all tested in CI on every push (including macOS's stock bash 3.2 and Linux without `lsof`).

- **Linux:** preflight detects btrfs (Snapper/Timeshift), ZFS and LVM snapshots and asks Docker/Podman what they can reclaim. Scan covers Snap, Flatpak, rootless containers, JetBrains and Android Studio caches, and reports system package caches and logs with the `sudo` command to clear them.
- **Windows:** run the scripts in Git Bash (installed with Git for Windows). Preflight reports pagefile use, `hiberfil.sys`, and the WSL and Docker Desktop virtual disks, which never shrink on their own; scan shows each disk with how to compact it. Scan covers `%LOCALAPPDATA%` caches (npm, pnpm, Yarn, pip, uv, Go, Playwright, JetBrains, Android Studio, Android SDK), temp files, crash dumps and NuGet. `schedule.sh` uses Task Scheduler. Anything that needs an admin terminal is reported with the command, never run.

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
