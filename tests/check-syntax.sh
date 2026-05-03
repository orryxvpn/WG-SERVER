#!/usr/bin/env bash
# check-syntax.sh — run `bash -n` on every shell script in the repo.
set -euo pipefail

cd "$(dirname "$0")/.."

shopt -s globstar nullglob
files=( setup.sh uninstall.sh lib/*.sh tests/*.sh )

fail=0
for f in "${files[@]}"; do
    if bash -n "$f"; then
        printf 'OK  %s\n' "$f"
    else
        printf 'FAIL %s\n' "$f" >&2
        fail=1
    fi
done

exit "$fail"
