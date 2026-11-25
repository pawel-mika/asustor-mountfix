#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

failed=0
ran=0

for test_script in tests/test_*.sh; do
    [ -f "$test_script" ] || continue
    ran=$((ran + 1))
    echo "=== Running $test_script ==="
    if bash "$test_script"; then
        echo "--- OK: $test_script ---"
    else
        echo "--- FAIL: $test_script ---" >&2
        failed=$((failed + 1))
    fi
    echo ""
done

echo "Summary: $((ran - failed))/$ran test suites passed."
[ "$failed" -eq 0 ]
