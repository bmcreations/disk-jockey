# Regenerates assets/preflight.svg and assets/worktrees.svg. Usage: python3 assets/make-terminals.py assets
import sys, html
C = dict(t="#C9D1D9", d="#8B949E", g="#3FB950", y="#E3B341", r="#FF7B72", c="#79C0FF", m="#D2A8FF", p="#FF4D8D", w="#F0F6FC")
FONT = 'ui-monospace, SFMono-Regular, Menlo, Consolas, "DejaVu Sans Mono", monospace'
def render(path, title, lines, width=1000, desc=""):
    lh, top = 23, 70
    h = top + lh * len(lines) + 26
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {h}" width="{width}" height="{h}" role="img" aria-labelledby="t d">',
           f'<title id="t">{html.escape(title)}</title><desc id="d">{html.escape(desc)}</desc>',
           f'<style>text{{font:14.5px {FONT};white-space:pre}}</style>',
           f'<rect width="{width}" height="{h}" rx="14" fill="#0D1117" stroke="#30363D"/>',
           f'<path d="M0 14 a14 14 0 0 1 14 -14 h{width-28} a14 14 0 0 1 14 14 v26 h-{width} z" fill="#161B22"/>',
           '<circle cx="24" cy="20" r="6.5" fill="#FF5F57"/><circle cx="46" cy="20" r="6.5" fill="#FEBC2E"/><circle cx="68" cy="20" r="6.5" fill="#28C840"/>',
           f'<text x="{width/2}" y="25" text-anchor="middle" fill="#8B949E" style="font-size:13px">{html.escape(title)}</text>']
    for i, segs in enumerate(lines):
        y = top + i * lh
        prose = bool(segs) and segs[0] == "P"
        if prose: segs = segs[1:]
        col, parts = 0, []
        for c, s in segs:
            txt = s.rstrip(' ')
            if txt:
                fw = ' font-weight="700"' if c in "rgyp" else ''
                xa = '' if (prose and parts) else f' x="{22 + col * 8.7:.1f}"'
                parts.append(f'<tspan{xa} fill="{C[c]}"{fw}>{html.escape(s if prose else txt)}</tspan>')
            col += len(s)
        spans = ''.join(parts)
        out.append(f'<text x="22" y="{y}" xml:space="preserve" font-family="{html.escape(FONT)}" font-size="14.5">{spans}</text>')
    out.append('</svg>')
    open(path, 'w').write('\n'.join(out))

A = sys.argv[1]
def row(level, item, value, advice=""):
    col = {"WARN": "y", "OK": "g", "INFO": "c"}[level]
    return [(col, f"{level:<5} "), ("t", f"{item:<22} "), ("w", f"{value:<18} "), ("d", advice)]

render(f"{A}/preflight.svg", "preflight.sh", [
    [("p", "$ "), ("t", "scripts/preflight.sh")],
    [],
    row("WARN", "free-space", "2.5G (0%)", "Below 20G or 10%: builds, simulators and swap start failing."),
    row("WARN", "load", "287 on 16 cores", "Processes are stalled (usually on disk I/O from swapping)."),
    row("WARN", "swap", "17.0G", "Swap files live on the same disk. Close sims/emulators/daemons."),
    row("WARN", "booted-simulators", "6", "xcrun simctl shutdown all (keeps their data)."),
    row("WARN", "android-emulators", "2", "Close emulators you are not using."),
    row("OK", "jvm-daemons", "gradle 1, kotlin 0"),
    row("INFO", "agent-processes", "12", "Concurrent agent sessions."),
    row("WARN", "os-update-snapshots", "3", "A macOS update is staged. Its snapshots pin deleted blocks."),
    row("OK", "uptime", "4d"),
    [],
    ["P", ("y", "7 warning(s). "), ("t", "Resolve memory and snapshot warnings first: deleting files")],
    [("t", "will not stop swap from refilling the disk.")],
], desc="Example preflight output on a full 1TB machine: 2.5G free, load 287, 17G of swap, booted simulators and a staged OS update.")

def wt(state, size, branch, path, detail=""):
    col = {"REMOVABLE": "g", "REVIEW": "y", "ACTIVE": "c", "IN-USE": "m", "STALE-REF": "d"}[state]
    return [(col, f"{state:<10} "), ("w", f"{size:<7} "), ("t", f"{branch:<24} "), ("d", f"{path:<20} "), ("d", detail)]

render(f"{A}/worktrees.svg", "worktrees.sh", [
    [("p", "$ "), ("t", "scripts/worktrees.sh ~/dev")],
    [],
    [("d", f"{'STATE':<10} "), ("d", f"{'SIZE':<7} "), ("d", f"{'BRANCH':<24} "), ("d", f"{'WORKTREE':<20} "), ("d", "DETAIL")],
    wt("REMOVABLE", "3.4G", "feat/composer-drop", "composer-drop"),
    wt("REMOVABLE", "2.9G", "fix/push-copy", "push-copy"),
    wt("REMOVABLE", "1.9G", "chore/emoji-cleanup", "emoji-cleanup", "PR #812 merged; local commits were squashed upstream"),
    wt("REVIEW", "1.6G", "feat/price-explainer", "price-explainer", "4 uncommitted, 0 commit(s) not on any remote or main"),
    wt("REVIEW", "1.1G", "fix/link-dialog", "link-dialog", "0 uncommitted, 1 commit(s) not on any remote or main"),
    wt("ACTIVE", "3.6G", "feat/text-format", "text-format", "files changed < 3d ago"),
    wt("IN-USE", "5.8G", "fix/error-triage", "error-triage", "process cwd inside"),
    wt("STALE-REF", "-", "agent/spike", "spike", "(registered, directory missing)"),
    [],
    ["P", ("t", "37 linked worktree(s). "), ("g", "Removable: 31.2G.")],
    [("d", "Dry run. Re-run with --apply to remove REMOVABLE and prune STALE-REF.")],
], width=1080, desc="Example worktree audit: clean merged worktrees are removable; dirty, unpushed, active and in-use ones are kept.")
print("ok")


def djrow(cur, mark, cat, safe, reb, keep):
    mc = {"[x]": "g", "[+]": "y", "[ ]": "d"}[mark]
    ptr = [("p", "  > ")] if cur else [("t", "    ")]
    name = ("w", f"{cat:<21}") if cur else ("t", f"{cat:<21}")
    return ptr + [(mc, f"{mark} "), name, ("g", f"{safe:<10}"), ("y", f"{reb:<10}"), ("d", keep)]

render(f"{A}/dj.svg", "dj.sh", [
    [("p", "$ "), ("t", "scripts/dj.sh")],
    [],
    ["P", ("p", "2/4  "), ("w", "Pick what to clear")],
    [],
    [("d", "  Report only (never deleted): Agents 15.0G")],
    [],
    [("d", f"{'':<8}"), ("d", f"{'CATEGORY':<21}"), ("d", f"{'SAFE':<10}"), ("d", f"{'REBUILD':<10}"), ("d", "KEEP")],
    djrow(False, "[x]", "Xcode & Simulators", "41.2G", "16.0G", "51.4G"),
    djrow(True, "[+]", "Android & JVM", "9.8G", "27.0G", "51.0G"),
    djrow(False, "[x]", "JavaScript", "2.9G", "-", "-"),
    djrow(False, "[ ]", "Python & ML", "1.1G", "-", "18.2G"),
    djrow(False, "[x]", "Homebrew", "tool", "-", "-"),
    [],
    ["P", ("t", "  Selected: "), ("g", "80.9G")],
    [("d", "  [x] safe caches  [+] also rebuild-cost items  [ ] skip")],
    [("d", "  up/down move   space toggle   left/right less/more")],
    [("d", "  a all safe   r all + rebuild   n none   enter continue   q quit")],
], width=900, desc="Interactive mode: arrow keys move, space toggles each category between skip, safe caches, and safe plus rebuild-cost items.")
