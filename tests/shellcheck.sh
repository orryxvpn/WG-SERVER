#!/usr/bin/env bash
# Lint every shell script in the repo with shellcheck.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v shellcheck >/dev/null 2>&1; then
    printf 'shellcheck не установлен. Установите: apt-get install -y shellcheck\n' >&2
    exit 2
fi

shopt -s globstar nullglob
files=( setup.sh uninstall.sh lib/*.sh tests/*.sh )

# -x: follow source statements; -e SC1091: ignore "can't follow non-constant
# source" (we source via $LIB_DIR/$f computed at runtime).
shellcheck -x -e SC1091 "${files[@]}"
printf 'shellcheck: OK\n'
