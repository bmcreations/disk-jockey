#!/bin/bash
# Reproduce the picker scenario from the tests and trace internal state.
set -u
S="$(cd "$(dirname "$0")/../scripts" && pwd)"
T=$(mktemp -d); export HOME="$T/home" RD_ROOTS="$T/none" RD_NO_CMD=1 RD_IGNORE_CTIME=1
blob() { mkdir -p "$1"; head -c 200000 /dev/zero >"$1/blob"; }
blob "$HOME/.gradle/caches/build-cache-1"; blob "$HOME/.gradle/caches/modules-2"
blob "$HOME/.cache/JetBrains/IdeaIC2023.1"; touch -t 202601010000 "$HOME/.cache/JetBrains/IdeaIC2023.1/blob" "$HOME/.cache/JetBrains/IdeaIC2023.1"
echo "bash $BASH_VERSION"
printf '2\nq\n' | RD_ALLOW_PIPE=1 RD_MENU=numbers RD_DEBUG_PICKER=1 NO_COLOR=1 bash "$S/dj.sh" 2>&1 | grep -E 'DEBUG|\[[ x+]\] +(Android|IDEs)' | tail -8
