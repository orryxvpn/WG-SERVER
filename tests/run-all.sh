#!/usr/bin/env bash
# run-all.sh — convenience wrapper that runs every test in tests/.
set -euo pipefail

cd "$(dirname "$0")/.."

bash tests/check-syntax.sh
bash tests/shellcheck.sh
printf '\nAll tests passed.\n'
