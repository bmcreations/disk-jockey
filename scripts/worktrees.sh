#!/usr/bin/env bash
# Audit git worktrees (the ones agents leave behind). Removes only clean, idle, fully-pushed ones, and only with --apply.
. "$(dirname "$0")/lib.sh"
# Read-only git calls must not take index.lock (agents may be using the same repo).
export GIT_OPTIONAL_LOCKS=0

usage() {
  cat <<'EOF'
Usage: worktrees.sh [options] [root ...]
  --idle-days N              worktrees with files changed in the last N days count as ACTIVE (default 3)
  --depth N                  how deep to look for repos under each root (default 5)
  --apply                    remove REMOVABLE worktrees and prune STALE-REF entries
  --merged                   only worktrees whose branch is merged (PR merged on GitHub via gh, or branch
                             merged into the main checkout or origin's default branch). Ignores --idle-days,
                             so it's safe to run right after a merge. Without roots, scopes to the repo you're in.
  --no-fetch                 with --merged, don't `git fetch` first
  --delete-merged-branches   with --apply, also delete the worktree's branch (`git branch -d`; `-D` only when
                             gh confirms the PR was merged, since squash merges look unmerged to git)
  --select PATH              act only on these worktrees (repeatable). A selected REVIEW worktree is
                             removed too, discarding its uncommitted changes; its commits stay on its branch.
                             IN-USE, LOCKED and ACTIVE worktrees are never removed.
  --quarantine               move worktrees to quarantine (git worktree move) instead of removing them;
                             uncommitted changes survive and `disk-jockey quarantine restore` puts them back
  --no-quarantine            remove directly even when quarantine is on
  --tsv                      machine-readable: state, KB, branch, path, uncommitted, local commits, detail
Roots default to ~/code ~/dev ~/src ~/Projects ~/Developer ... or $RD_ROOTS (colon-separated).

States
  REMOVABLE  clean, no unpushed commits (or its PR is merged, checked with gh), idle, no process inside
  MERGED     (--merged) clean and its branch is merged: removed by --apply
  UNMERGED   (--merged) no merge found yet: left alone
  REVIEW     uncommitted changes or commits that exist nowhere else. Never auto-removed.
  ACTIVE     files changed recently
  IN-USE     a process (agent, shell, daemon) has its cwd inside
  LOCKED     `git worktree lock`ed
  STALE-REF  directory is gone; git still has the entry (prune is safe)

Agents: after your PR merges, run from the main checkout (not from inside the worktree):
  disk-jockey worktrees --merged --apply
EOF
}

idle_days=3 depth=5 apply=0 del_branches=0 tsv=0 merged_mode=0 fetch=1
roots=() selects=()
while [ $# -gt 0 ]; do
  case "$1" in
    --idle-days) idle_days="$2"; shift ;;
    --depth) depth="$2"; shift ;;
    --apply) apply=1 ;;
    --merged) merged_mode=1 ;;
    --no-fetch) fetch=0 ;;
    --delete-merged-branches) del_branches=1 ;;
    --select) selects+=("$(norm_path "$2")"); shift ;;
    --quarantine) export RD_QUARANTINE=1 ;;
    --no-quarantine) export RD_QUARANTINE=0 ;;
    --tsv) tsv=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) log "unknown argument: $1"; usage; exit 2 ;;
    *) roots+=("$1") ;;
  esac
  shift
done
have git || { log "git not found"; exit 2; }

# --merged from inside a repo: that repo only (the agent's own project).
if [ "${#roots[@]}" -eq 0 ] && [ "$merged_mode" = 1 ]; then
  main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$main" ] && roots+=("$(norm_path "$main")")
fi
if [ "${#roots[@]}" -eq 0 ]; then
  while IFS= read -r r; do roots+=("$r"); done < <(default_roots)
fi
if [ "${#roots[@]}" -eq 0 ]; then
  log "No project roots found. Pass directories or set RD_ROOTS."
  exit 2
fi

cwds=""
load_cwds "$apply"
here=$(pwd -P 2>/dev/null)
quar=0
q_enabled && quar=1
if [ "$apply" = 1 ] && [ "$tsv" = 0 ]; then
  q_purge_expired
fi
removable_kb=0 count=0 held=0

find_repos() {
  local r
  for r in "${roots[@]}"; do
    [ -d "$r" ] || continue
    find "$r" -maxdepth "$depth" \( -name node_modules -o -name build -o -name .build -o -name DerivedData -o -name Pods \) -prune \
      -o -type d -name .git -prune -print 2>/dev/null
  done | sed 's#/\.git$##' | while IFS= read -r r; do norm_path "$r"; echo; done | sort -u | grep -vF "$RD_QDIR/"
}

recently_touched() {
  local hit
  hit=$(find "$1" \( -name node_modules -o -name .git \) -prune -o -type f -mtime "-$idle_days" -print -quit 2>/dev/null)
  [ -n "$hit" ]
}

is_selected() {
  local p
  for p in "${selects[@]}"; do [ "$p" = "$1" ] && return 0; done
  return 1
}

# Evidence that BRANCH was merged, printed as a short phrase; nothing if none.
merge_evidence() { # repo wt branch main_head
  local repo="$1" wt="$2" branch="$3" main_head="$4" pr tip base
  if [ "${RD_GH:-1}" = 1 ] && have gh; then
    pr=$(cd "$wt" && gh pr list --head "$branch" --state merged --json number --jq '.[0].number' 2>/dev/null)
    if [ -n "$pr" ]; then echo "PR #$pr merged"; return; fi
  fi
  tip=$(git -C "$repo" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null) || return 0
  # A branch nobody committed to is trivially "contained" in main. Require that it moved at least once.
  [ "$(git -C "$repo" reflog show "refs/heads/$branch" -- 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] || return 0
  for base in "$main_head" "$(git -C "$repo" rev-parse -q --verify refs/remotes/origin/HEAD 2>/dev/null)"; do
    [ -n "$base" ] && [ "$base" != "$tip" ] || continue
    if git -C "$repo" merge-base --is-ancestor "$tip" "$base" 2>/dev/null; then echo "branch merged"; return; fi
  done
}

report() { # state size branch path detail
  [ "$tsv" = 1 ] && return 0
  local sc=""
  case "$1" in
    REMOVABLE | MERGED) sc="$C_B$C_G" ;; REVIEW) sc="$C_B$C_Y" ;; ACTIVE) sc="$C_C" ;; IN-USE) sc="$C_M" ;;
    LOCKED | STALE-REF | UNMERGED) sc="$C_DIM" ;; STATE) sc="$C_DIM" ;;
  esac
  if [ "$1" = STATE ]; then
    printf '%s%-10s %-8s %-28s %s  %s%s\n' "$C_DIM" "$1" "$2" "$3" "$4" "$5" "$C_0"
  else
    printf '%s %s %s %s  %s\n' "$(paint "$sc" 10 "$1")" "$(paint "$C_B" 8 "$2")" "$(paint "" 28 "$3")" "$C_DIM$(tilde "$4")$C_0" "$5"
  fi
}

say_act() { [ "$tsv" = 1 ] || echo "           $*"; }

handle() { # repo wt head branch locked prunable main_head
  local repo="$1" wt="$2" head="$3" branch="$4" locked="$5" prunable="$6" main_head="$7"
  local state detail="" dirty uniq kb sz merged=""
  count=$((count + 1))
  if [ "$prunable" = 1 ] || [ ! -d "$wt" ]; then
    report STALE-REF "-" "$branch" "$wt" "(registered in $repo, directory missing)"
    [ "$apply" = 1 ] && git -C "$repo" worktree prune
    return
  fi
  kb=$(printf '%s\n' "$wt" | size_kb)
  sz=$(human "$kb")
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  uniq=$(git -C "$wt" rev-list --count HEAD --not --remotes "$main_head" 2>/dev/null || echo "?")
  local pr=""
  if [ "$merged_mode" = 1 ]; then
    [ "$branch" != "(detached)" ] && merged=$(merge_evidence "$repo" "$wt" "$branch" "$main_head")
  elif [ "$uniq" != 0 ] && [ "$dirty" = 0 ] && [ "$branch" != "(detached)" ] && [ "${RD_GH:-1}" = 1 ] && have gh; then
    # Squash-merged PRs: the local commits exist nowhere else, but their content is upstream.
    pr=$(cd "$wt" && gh pr list --head "$branch" --state merged --json number --jq '.[0].number' 2>/dev/null)
    [ -n "$pr" ] && uniq=0
  fi
  if [ "$locked" = 1 ]; then
    state=LOCKED
  elif dir_in_use "$wt" "$cwds"; then
    state=IN-USE; detail="process cwd inside"
    case "$here" in "$wt" | "$wt"/*) detail="you're running this from inside it; cd to the main checkout ($(tilde "$repo"))" ;; esac
  elif [ "$merged_mode" = 1 ]; then
    if [ -z "$merged" ]; then
      state=UNMERGED; detail="no merged PR or merge into main found"
    elif [ "$dirty" != 0 ]; then
      state=REVIEW; detail="$merged, but $dirty uncommitted change(s)"
    elif [ "$apply" = 1 ] && is_win && ! win_dir_free "$wt"; then
      state=IN-USE; detail="Windows reports a program has it open"
    else
      state=MERGED; detail="$merged"
      removable_kb=$((removable_kb + kb))
    fi
  elif [ "$dirty" != 0 ] || [ "$uniq" != 0 ]; then
    state=REVIEW; detail="$dirty uncommitted, $uniq commit(s) not on any remote or main"
  elif recently_touched "$wt"; then
    state=ACTIVE; detail="files changed < ${idle_days}d ago"
  elif [ "$apply" = 1 ] && is_win && ! win_dir_free "$wt"; then
    state=IN-USE; detail="Windows reports a program has it open"
  else
    state=REMOVABLE
    [ -n "$pr" ] && detail="PR #$pr merged; local commits were squashed upstream"
    removable_kb=$((removable_kb + kb))
  fi
  report "$state" "$sz" "$branch" "$wt" "$detail"
  [ "$tsv" = 1 ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$kb" "$branch" "$wt" "$dirty" "$uniq" "$detail"

  # What --apply acts on: REMOVABLE (or MERGED) by default; with --select, exactly the selected ones.
  local act=0 force=""
  if [ "${#selects[@]}" -gt 0 ]; then
    if is_selected "$wt"; then
      case "$state" in
        REMOVABLE | MERGED) act=1 ;;
        REVIEW)
          if [ "$branch" = "(detached)" ] && [ "$uniq" != 0 ]; then
            # No branch holds these commits; removing the worktree would orphan them.
            [ "$apply" = 1 ] && say_act "${C_Y}detached with $uniq local commit(s) on no branch, left in place$C_0"
          else
            act=1; force="--force"
          fi
          ;;
        *) [ "$apply" = 1 ] && say_act "${C_Y}selected but $state, left in place$C_0" ;;
      esac
    fi
  elif [ "$state" = REMOVABLE ] || [ "$state" = MERGED ]; then
    act=1
  fi
  # Windows: REVIEW worktrees skipped the earlier probe; check before forcing.
  if [ "$apply" = 1 ] && [ "$act" = 1 ] && [ -n "$force" ] && is_win && ! win_dir_free "$wt"; then
    say_act "${C_Y}Windows reports a program has it open, left in place$C_0"
    act=0
  fi
  [ "$apply" = 1 ] && [ "$act" = 1 ] || return 0

  if [ "$quar" = 1 ]; then
    # Moved, not removed: git keeps the registration, uncommitted changes survive, restore is a move back.
    if q_move "$wt" "worktrees" worktree "$repo" "$branch" "$kb"; then
      held=$((held + kb))
      if [ -n "$force" ]; then
        say_act "${C_M}quarantined$C_0 ${C_DIM}with its $dirty uncommitted change(s); undo: disk-jockey quarantine restore $RD_Q_ID$C_0"
      else
        say_act "${C_M}quarantined$C_0 ${C_DIM}undo: disk-jockey quarantine restore $RD_Q_ID$C_0"
      fi
      [ "$del_branches" = 1 ] && say_act "${C_DIM}branch $branch kept: the quarantined worktree still has it checked out$C_0"
    else
      say_act "${C_Y}left in place:$C_0 $RD_Q_ERR ${C_DIM}(--no-quarantine removes it instead)$C_0"
    fi
    return 0
  fi

  # shellcheck disable=SC2086  # $force is empty or one flag
  if git -C "$repo" worktree remove $force "$wt" 2>/dev/null; then
    if [ -n "$force" ]; then
      say_act "${C_G}removed$C_0 ${C_DIM}($dirty uncommitted change(s) discarded; commits kept on $branch)$C_0"
    else
      say_act "${C_G}removed$C_0"
    fi
    if [ "$del_branches" = 1 ] && [ "$branch" != "(detached)" ]; then
      local how=-d
      case "$merged$detail" in *"PR #"*) how=-D ;; esac
      if git -C "$repo" branch "$how" "$branch" >/dev/null 2>&1; then
        say_act "${C_G}deleted merged branch$C_0 $branch"
      else
        say_act "${C_DIM}branch $branch kept (git doesn't consider it merged)$C_0"
      fi
    fi
  else
    say_act "${C_Y}git refused to remove it (left in place)$C_0"
  fi
}

audit_repo() {
  local repo="$1" line wt="" head="" branch="" locked=0 prunable=0 first=1 main_head=""
  if [ "$merged_mode" = 1 ] && [ "$fetch" = 1 ]; then
    # Never wait on a password or passphrase prompt (autopilot runs with nobody watching).
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=10}" \
      git -C "$repo" fetch -q origin >/dev/null 2>&1 </dev/null
  fi
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt=$(norm_path "${line#worktree }") ;;
      "HEAD "*) head="${line#HEAD }" ;;
      "branch "*) branch="${line#branch refs/heads/}" ;;
      detached) branch="(detached)" ;;
      locked*) locked=1 ;;
      prunable*) prunable=1 ;;
      "")
        if [ -n "$wt" ]; then
          if [ "$first" = 1 ]; then
            main_head="$head"; first=0
          else
            case "$wt" in
              "$RD_QDIR"/*) ;; # held in quarantine: managed by `disk-jockey quarantine`
              *) handle "$repo" "$wt" "$head" "$branch" "$locked" "$prunable" "$main_head" ;;
            esac
          fi
        fi
        wt="" head="" branch="" locked=0 prunable=0
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null; echo)
}

report STATE SIZE BRANCH PATH DETAIL
[ "$tsv" = 1 ] && printf 'state\tkb\tbranch\tpath\tuncommitted\tlocal_commits\tdetail\n'
while IFS= read -r repo; do
  [ -n "$repo" ] && audit_repo "$repo"
done < <(find_repos)

[ "$tsv" = 1 ] && exit 0
echo
label=Removable
[ "$merged_mode" = 1 ] && label=Merged
echo "$count linked worktree(s). $C_B$C_G$label: $(human "$removable_kb").$C_0"
if [ "$apply" = 1 ]; then
  [ "$held" -gt 0 ] && echo "${C_M}Moved $(human "$held") to quarantine.$C_0 Space returns when purged (disk-jockey quarantine purge --all)."
else
  what="REMOVABLE"
  [ "$merged_mode" = 1 ] && what="MERGED"
  if [ "$quar" = 1 ]; then
    echo "${C_DIM}Dry run. Re-run with --apply to move $what worktrees to quarantine (quarantine is on).$C_0"
  else
    echo "${C_DIM}Dry run. Re-run with --apply to remove $what and prune STALE-REF.$C_0"
  fi
fi
