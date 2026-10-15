#!/usr/bin/env bash
# disk-jockey installer: one shared copy for every agent, plus a `disk-jockey` command.
#
#   curl -fsSL https://raw.githubusercontent.com/bmcreations/disk-jockey/main/install.sh | bash
#   bash install.sh [--ref TAG|BRANCH] [--bin DIR] [--no-link] [--uninstall]
#
# Layout
#   ~/.agents/skills/disk-jockey      the git clone (Codex and Cursor read ~/.agents/skills)
#   ~/.claude/skills/disk-jockey      link to it (Claude Code); a junction on Windows
#   ~/.local/bin/disk-jockey          small wrapper script (~/bin on Git Bash when that's on PATH)
#
# Environment overrides: DJ_REPO (git URL), DJ_DIR (clone dir), DJ_BIN (wrapper dir).
set -eu

REPO="${DJ_REPO:-https://github.com/bmcreations/disk-jockey}"
DIR="${DJ_DIR:-$HOME/.agents/skills/disk-jockey}"
CLAUDE_LINK="$HOME/.claude/skills/disk-jockey"
BIN="${DJ_BIN:-}"
REF=""
LINK=1
UNINSTALL=0

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
is_win() { case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) return 0 ;; esac; return 1; }
on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; esac; return 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift ;;
    --bin) BIN="$2"; shift ;;
    --no-link) LINK=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

if [ -z "$BIN" ]; then
  BIN="$HOME/.local/bin"
  # Git Bash puts ~/bin on PATH by default; ~/.local/bin usually isn't.
  if is_win && ! on_path "$BIN" && on_path "$HOME/bin"; then BIN="$HOME/bin"; fi
fi
WRAPPER="$BIN/disk-jockey"

# A link (or Windows junction) pointing at the clone?
links_to_clone() {
  [ -e "$1" ] || return 1
  [ "$(cd -P "$1" 2>/dev/null && pwd)" = "$(cd -P "$DIR" 2>/dev/null && pwd)" ]
}

if [ "$UNINSTALL" = 1 ]; then
  if [ -f "$WRAPPER" ] && grep -q 'disk-jockey installer' "$WRAPPER" 2>/dev/null; then
    rm -f "$WRAPPER" && say "Removed $WRAPPER"
  fi
  if [ -L "$CLAUDE_LINK" ]; then
    rm -f "$CLAUDE_LINK" && say "Removed link $CLAUDE_LINK"
  elif is_win && links_to_clone "$CLAUDE_LINK"; then
    cmd.exe //c rmdir "$(cygpath -w "$CLAUDE_LINK")" >/dev/null 2>&1 && say "Removed junction $CLAUDE_LINK"
  fi
  say "Kept the skill files at $DIR (delete that folder to remove disk-jockey completely)."
  say "A scheduled cleanup, if you set one up, stays until: disk-jockey schedule uninstall (run that first)."
  exit 0
fi

command -v git >/dev/null 2>&1 || die "git is required (on Windows, install Git for Windows and run this in Git Bash)."

# --- 1. The clone -------------------------------------------------------------------------
# Earlier installs cloned straight into ~/.claude/skills. Move a clean one into the shared place.
if [ ! -e "$DIR" ] && [ -d "$CLAUDE_LINK/.git" ] && [ ! -L "$CLAUDE_LINK" ]; then
  if [ -z "$(git -C "$CLAUDE_LINK" status --porcelain 2>/dev/null)" ]; then
    mkdir -p "$(dirname "$DIR")"
    mv "$CLAUDE_LINK" "$DIR" && say "Moved your existing copy from $CLAUDE_LINK to $DIR"
  else
    warn "$CLAUDE_LINK has local changes; leaving it alone and installing a separate copy at $DIR."
  fi
fi

if [ -d "$DIR/.git" ]; then
  [ -z "$(git -C "$DIR" status --porcelain 2>/dev/null)" ] || die "$DIR has local changes. Commit or stash them, then re-run."
  say "Updating $DIR"
  git -C "$DIR" fetch -q --tags origin
  if [ -n "$REF" ]; then
    git -C "$DIR" -c advice.detachedHead=false checkout -q "$REF"
  elif git -C "$DIR" symbolic-ref -q HEAD >/dev/null; then
    git -C "$DIR" pull -q --ff-only
  else
    warn "$DIR is pinned to $(git -C "$DIR" describe --tags --always 2>/dev/null); pass --ref main to follow main."
  fi
elif [ -e "$DIR" ]; then
  die "$DIR exists but isn't a git clone. Move it away and re-run."
else
  say "Cloning into $DIR"
  mkdir -p "$(dirname "$DIR")"
  git clone -q "$REPO" "$DIR"
  [ -n "$REF" ] && git -C "$DIR" -c advice.detachedHead=false checkout -q "$REF"
fi
VERSION=$(cat "$DIR/VERSION" 2>/dev/null || echo dev)

# --- 2. Claude Code link -------------------------------------------------------------------
if [ "$LINK" = 1 ]; then
  if links_to_clone "$CLAUDE_LINK"; then
    : # already linked
  elif [ -e "$CLAUDE_LINK" ] || [ -L "$CLAUDE_LINK" ]; then
    warn "$CLAUDE_LINK already exists and isn't a link to $DIR; left as is."
  else
    mkdir -p "$(dirname "$CLAUDE_LINK")"
    if is_win; then
      # Symlinks become copies in Git Bash without Developer Mode; a junction needs no special rights.
      cmd.exe //c mklink //J "$(cygpath -w "$CLAUDE_LINK")" "$(cygpath -w "$DIR")" >/dev/null ||
        warn "Couldn't create a junction at $CLAUDE_LINK; Claude Code won't see the skill until you link it."
    else
      ln -s "$DIR" "$CLAUDE_LINK"
    fi
    links_to_clone "$CLAUDE_LINK" && say "Linked $CLAUDE_LINK -> $DIR"
  fi
fi

# --- 3. Command wrapper --------------------------------------------------------------------
# A wrapper instead of a symlink: works on Windows, and the scripts always find their own folder.
mkdir -p "$BIN"
if [ -e "$WRAPPER" ] && ! grep -q 'disk-jockey installer' "$WRAPPER" 2>/dev/null; then
  die "$WRAPPER exists and wasn't created by this installer. Remove it or pass --bin DIR."
fi
cat >"$WRAPPER" <<EOF
#!/usr/bin/env bash
# Generated by the disk-jockey installer. Re-run install.sh to change it.
exec bash "$DIR/bin/disk-jockey" "\$@"
EOF
chmod +x "$WRAPPER"
say "Installed the disk-jockey command at $WRAPPER"

say ""
say "disk-jockey $VERSION is ready."
if on_path "$BIN"; then
  say "Run: disk-jockey"
else
  # shellcheck disable=SC2088  # shown to the user as typed; not expanded here
  case "${SHELL:-}" in
    */zsh) rc="~/.zshrc" ;;
    */fish) rc="" ;;
    *) rc="~/.bashrc" ;;
  esac
  say "$BIN isn't on your PATH yet. Add it, then open a new terminal:"
  if [ -n "$rc" ]; then
    # shellcheck disable=SC2016  # printed for the user to run; $PATH must stay literal
    say "  echo 'export PATH=\"$BIN:\$PATH\"' >> $rc"
  else
    say "  fish_add_path $BIN"
  fi
  say "Or run it directly: $WRAPPER"
fi
