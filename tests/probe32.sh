#!/bin/bash
# Probe bash 3.2 behavior of the dj.sh state helpers.
echo "bash $BASH_VERSION"
state=(0 1 1 0); ids1=("" "a" "b" ""); ids2=("" "x" "" "")
allowed() {
  case "$2" in
    0) return 0 ;;
    1) [ -n "${ids1[$1]}" ] ;;
    2) [ -n "${ids2[$1]}" ] ;;
    *) return 1 ;;
  esac
}
step_state() { # c dir wrap  (current dj.sh version)
  local c="$1" s="${state[$1]}" i
  for i in 1 2 3; do
    s=$((s + $2))
    if [ "$3" = 1 ]; then
      s=$(( (s + 3) % 3 ))
    elif [ "$s" -lt 0 ] || [ "$s" -gt 2 ]; then
      return
    fi
    allowed "$c" "$s" && break
  done
  state[c]=$s
}
r() { echo "$1: state=(${state[*]})"; }
r start
step_state 2 1 1; r "A step_state 2 (expect 0 1 0 0)"
state=(0 1 1 0)
step_state 1 1 1; r "B step_state 1 (expect 0 2 1 0)"
state=(0 1 1 0)
f1() { local c="$1" s="${state[$1]}" i; echo "  inside: c=$c s=$s"; }
f1 2
f2() { local c="$1"; local s="${state[$1]}"; echo "  split locals: c=$c s=$s"; }
f2 2
f3() { local c="$1" s; s="${state[$1]}"; state[c]=9; }
state=(0 1 1 0); f3 2; r "C state[c]=9 with c=2 (expect 0 1 9 0)"
f4() { local x="$1"; state[$x]=9; }
state=(0 1 1 0); f4 2; r "D state[\$x]=9 (expect 0 1 9 0)"
f5() { local c="$1" s="${state[$1]}" i; for i in 1 2 3; do :; done; state[c]=7; }
state=(0 1 1 0); f5 2; r "E after for-i loop state[c]=7 (expect 0 1 7 0)"
f6() { local c="$1" s="${state[$1]}" i; allowed "$c" 0; state[c]=6; }
state=(0 1 1 0); f6 2; r "F after allowed() state[c]=6 (expect 0 1 6 0)"
f7() { local c="$1" s="${state[$1]}" i; s=$((s + 1)); state[c]=$s; }
state=(0 1 1 0); f7 2; r "G arithmetic then state[c] (expect 0 1 2 0)"
