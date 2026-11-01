#!/bin/bash

# Test uncovered_binaries() — the pure set-diff helper at the heart of the
# packaging-completeness guardrail (scripts/verify_shipped_binaries.sh).
#
# The guardrail's DESTDIR walk and manifest parsing need a Debian build host,
# but the diff logic is a pure string function. This sed-extracts just that
# function body (from 'name()' to the first col-0 '}') and evals it, matching
# the extraction pattern used by test_detect_distro_depends.sh, so this test
# runs anywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
GUARDRAIL_SH="${PROJECT_ROOT}/scripts/verify_shipped_binaries.sh"

PASS_COUNT=0
FAIL_COUNT=0

assert_equals() {
    local description="$1" expected="$2" actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected: [${expected}]"
        echo "    Got:      [${actual}]"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ============================================
# Load the function under test
# ============================================

extract_fn() {
    local fn="$1"
    sed -n "/^${fn}()/,/^}/p" "${GUARDRAIL_SH}"
}

echo ""
echo "========================================"
echo "Test: uncovered_binaries (guardrail set-diff)"
echo "========================================"
echo ""

if ! grep -q "^uncovered_binaries()" "${GUARDRAIL_SH}"; then
    echo "FATAL: uncovered_binaries() not found in ${GUARDRAIL_SH}"
    exit 1
fi
eval "$(extract_fn uncovered_binaries)"

# Run in a clean subshell (the function uses set -e-safe grep) and collect output.
run_uncovered() {
    ( uncovered_binaries "$1" "$2" )
}

# ----- fixtures -----
COVERED="usr/bin/passt
usr/bin/pasta
usr/bin/pesto
usr/bin/passt-repair
usr/bin/passt.avx2
usr/bin/pasta.avx2
usr/libexec/podman/quadlet"

echo "Test 1: a staged binary absent from covered is reported"
staged="usr/bin/passt
usr/bin/newthing"
assert_equals "newthing flagged" "usr/bin/newthing" "$(run_uncovered "${staged}" "${COVERED}")"

echo ""
echo "Test 2: fully-covered staged set yields no output"
staged="usr/bin/passt
usr/bin/pasta
usr/bin/pesto"
assert_equals "all covered -> empty" "" "$(run_uncovered "${staged}" "${COVERED}")"

echo ""
echo "Test 3: paths present in the covered set (e.g. avx2 pair) are not flagged"
# NOTE: this exercises exact-line coverage only; the production KNOWN_UNPACKAGED
# allowlist that actually injects avx2 into the covered set is asserted
# structurally in Test 8 below.
staged="usr/bin/passt.avx2
usr/bin/pasta.avx2"
assert_equals "avx2 pair suppressed when covered" "" "$(run_uncovered "${staged}" "${COVERED}")"

echo ""
echo "Test 4: exact-line match — 'passt' does not cover 'passt-repair' as a prefix"
# Regression guard: a substring/prefix match would wrongly suppress a genuinely
# missing 'passt-repair'. Covered here intentionally lacks passt-repair.
covered_no_repair="usr/bin/passt
usr/bin/pasta"
staged="usr/bin/passt-repair"
assert_equals "passt-repair still flagged" "usr/bin/passt-repair" "$(run_uncovered "${staged}" "${covered_no_repair}")"

echo ""
echo "Test 5: blank lines in staged input are ignored"
staged="usr/bin/passt

usr/bin/pesto
"
assert_equals "blank lines ignored -> empty" "" "$(run_uncovered "${staged}" "${COVERED}")"

echo ""
echo "Test 6: multiple uncovered paths are all reported, order preserved"
staged="usr/bin/alpha
usr/bin/passt
usr/bin/omega"
expected="usr/bin/alpha
usr/bin/omega"
assert_equals "alpha+omega flagged" "${expected}" "$(run_uncovered "${staged}" "${COVERED}")"

echo ""
echo "Test 7: empty staged set yields no output"
assert_equals "empty staged -> empty" "" "$(run_uncovered "" "${COVERED}")"

echo ""
echo "Test 8: production KNOWN_UNPACKAGED allowlist still declares the expected entries"
# Structural guard: the pure helper can't see the real allowlist (assembled in
# the script body), so assert its membership directly. Catches a regression that
# silently drops an intentional skip (which would turn into a spurious warning)
# or the avx2 conditional-packaging entries (a spurious warning on amd64).
for expected in usr/bin/passt.avx2 usr/bin/pasta.avx2 usr/bin/qrap usr/bin/netavark-connection-tester; do
    if grep -qF "\"${expected}\"" "${GUARDRAIL_SH}"; then
        echo "  PASS: KNOWN_UNPACKAGED declares ${expected}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: KNOWN_UNPACKAGED missing ${expected}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# ============================================
# Summary
# ============================================
echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi
exit 0
