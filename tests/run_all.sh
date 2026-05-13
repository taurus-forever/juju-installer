#!/bin/sh
# Run all test files and aggregate results.
# Run: sh tests/run_all.sh
set -eu

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0
FAILED_FILES=""

for test_file in "${TEST_DIR}"/test_*.sh; do
    [ -f "$test_file" ] || continue
    echo "========================================"
    echo "Running $(basename "$test_file")"
    echo "========================================"

    outfile=$(mktemp)
    set +e
    sh "$test_file" >"$outfile" 2>&1
    rc=$?
    set -e

    cat "$outfile"
    results=$(grep '^=== Results:' "$outfile" | tail -1)
    rm -f "$outfile"

    if [ -n "$results" ]; then
        passed=$(echo "$results" | sed 's/.*: \([0-9]*\)\/.*/\1/')
        total=$(echo "$results" | sed 's|.*/\([0-9]*\) passed.*|\1|')
        failed=$(echo "$results" | sed 's/.*, \([0-9]*\) failed.*/\1/')
        TOTAL_PASS=$((TOTAL_PASS + passed))
        TOTAL_FAIL=$((TOTAL_FAIL + failed))
        TOTAL_TESTS=$((TOTAL_TESTS + total))
    fi

    if [ "$rc" -ne 0 ]; then
        FAILED_FILES="${FAILED_FILES} $(basename "$test_file")"
    fi
    echo ""
done

echo "========================================"
echo "TOTAL: ${TOTAL_PASS}/${TOTAL_TESTS} passed, ${TOTAL_FAIL} failed"
if [ -n "$FAILED_FILES" ]; then
    echo "Failed files:${FAILED_FILES}"
fi
echo "========================================"
[ "$TOTAL_FAIL" -eq 0 ] || exit 1
