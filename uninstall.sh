#!/usr/bin/env bash
# uninstall.sh — convenience wrapper that runs setup.sh in uninstall mode.
#
# Equivalent to running setup.sh and choosing "3) Удалить установку".

set -euo pipefail

self_dir() {
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -f "$src" ]]; then
        ( cd -- "$(dirname -- "$src")" && pwd )
    else
        printf ''
    fi
}

dir="$(self_dir)"
if [[ -n "$dir" && -x "$dir/setup.sh" ]]; then
    # Pipe the uninstall menu choice automatically. setup.sh prompts:
    #   role: 3 (uninstall), then sub-role: 3 (both / unknown).
    # The user still confirms package purge interactively.
    printf '3\n3\n' | exec bash "$dir/setup.sh" "$@"
fi

cat >&2 <<'EOF'
Не удалось найти setup.sh рядом с uninstall.sh.
Запустите вручную:
  sudo bash setup.sh
и выберите пункт 3 (Удалить установку).
EOF
exit 1
