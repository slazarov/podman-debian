#!/bin/bash

# Test that packaging/repo/conf/distributions declares exactly one reprepro
# distribution per suite in ALL_SUITES (config.sh): {track}-{distro} for every
# track and Debian release, with no bare track aliases.
#
# Pure parse assertions over static files. No reprepro, gpg or apt needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

DISTRIBUTIONS="${PROJECT_ROOT}/packaging/repo/conf/distributions"

# Distro table and ALL_SUITES from config.sh.
eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${PROJECT_ROOT}/config.sh")"

# ============================================
# Test Framework
# ============================================

PASS_COUNT=0
FAIL_COUNT=0

assert_equals() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected: ${expected}"
        echo "    Got: ${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_contains_line() {
    local description="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s\n' "${haystack}" | grep -qx "${needle}"; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Missing line: ${needle}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_absent() {
    local description="$1"
    local token="$2"
    if grep -q "${token}" "${DISTRIBUTIONS}"; then
        echo "  FAIL: ${description}"
        echo "    Unexpected token present: ${token}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

echo ""
echo "========================================"
echo "Test: conf/distributions suite parse"
echo "========================================"
echo ""

if [[ ! -f "${DISTRIBUTIONS}" ]]; then
    echo "FATAL: distributions file not found: ${DISTRIBUTIONS}"
    echo ""
    echo "RESULT: ALL TESTS FAILED (config not found)"
    exit 1
fi

expected_count="${#ALL_SUITES[@]}"

echo "Test 1: one Suite and one Codename line per suite in ALL_SUITES"
suite_count="$(grep -c '^Suite:' "${DISTRIBUTIONS}")"
codename_count="$(grep -c '^Codename:' "${DISTRIBUTIONS}")"
assert_equals "${expected_count} Suite: lines" "${expected_count}" "${suite_count}"
assert_equals "${expected_count} Codename: lines" "${expected_count}" "${codename_count}"
assert_equals "ALL_SUITES has 6 suites (3 tracks x 2 distros)" "6" "${expected_count}"

echo ""
echo "Test 2: every stanza is signed"
signwith_count="$(grep -c '^SignWith: yes$' "${DISTRIBUTIONS}")"
assert_equals "${expected_count} SignWith: yes lines" "${expected_count}" "${signwith_count}"

echo ""
echo "Test 3: Suite == Codename for every stanza"
suites="$(grep '^Suite:' "${DISTRIBUTIONS}" | sed 's/^Suite: //')"
codenames="$(grep '^Codename:' "${DISTRIBUTIONS}" | sed 's/^Codename: //')"
assert_equals "Suite list equals Codename list" "${suites}" "${codenames}"

echo ""
echo "Test 4: the suite set equals ALL_SUITES"
suite_lines="$(grep '^Suite:' "${DISTRIBUTIONS}")"
for v in "${ALL_SUITES[@]}"; do
    assert_contains_line "suite '${v}' present" "Suite: ${v}" "${suite_lines}"
done
assert_equals "sorted suite set matches ALL_SUITES" \
    "$(printf '%s\n' "${ALL_SUITES[@]}" | sort)" \
    "$(printf '%s\n' "${suites}" | sort)"

echo ""
echo "Test 5: no bare track aliases"
for t in "${VALID_TRACKS[@]}"; do
    assert_absent "no bare 'Suite: ${t}' alias" "^Suite: ${t}\$"
done
assert_absent "no DEPRECATED alias descriptions" "DEPRECATED"

echo ""
echo "Test 6: amd64 only, Debian metadata"
arch_lines="$(grep '^Architectures:' "${DISTRIBUTIONS}" | sort -u)"
assert_equals "every stanza is Architectures: amd64" "Architectures: amd64" "${arch_lines}"
assert_equals "Origin is podman-debian" "Origin: podman-debian" "$(grep '^Origin:' "${DISTRIBUTIONS}" | sort -u)"
assert_equals "Label is Podman Debian" "Label: Podman Debian" "$(grep '^Label:' "${DISTRIBUTIONS}" | sort -u)"

echo ""
echo "Test 7: no createsymlinks token (real distributions only)"
assert_absent "createsymlinks absent" "createsymlinks"

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
