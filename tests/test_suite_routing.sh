#!/bin/bash

# Test the suite-routing contract in config.sh: resolve_publish_targets(),
# is_valid_suite(), and the VALID_TRACKS/VALID_DISTROS/ALL_SUITES arrays.
#
# config.sh reads /etc/os-release and composes VERSION_SUFFIX at load time,
# which fails on a non-Debian host. To test the routing helpers in isolation
# this extracts the distro table block and the two function bodies with sed,
# then evals them. Pure bash, no reprepro/gpg/apt needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

CONFIG_SH="${PROJECT_ROOT}/config.sh"

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

assert_succeeds() {
    local description="$1"
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Command unexpectedly failed: $*"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_fails() {
    local description="$1"
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        echo "  FAIL: ${description}"
        echo "    Command unexpectedly succeeded: $*"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

# ============================================
# Extract the routing helpers from config.sh
# ============================================

extract_fn() {
    local fn="$1"
    sed -n "/^${fn}()/,/^}/p" "${CONFIG_SH}"
}

load_routing() {
    if ! grep -q "^resolve_publish_targets()" "${CONFIG_SH}"; then
        echo "FATAL: resolve_publish_targets() not found in config.sh"
        return 1
    fi
    if ! grep -q "^is_valid_suite()" "${CONFIG_SH}"; then
        echo "FATAL: is_valid_suite() not found in config.sh"
        return 1
    fi
    eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${CONFIG_SH}")"
    eval "$(extract_fn resolve_publish_targets)"
    eval "$(extract_fn is_valid_suite)"
}

echo ""
echo "========================================"
echo "Test: resolve_publish_targets / is_valid_suite"
echo "========================================"
echo ""

if ! load_routing; then
    echo ""
    echo "RESULT: ALL TESTS FAILED (routing helpers not found)"
    exit 1
fi

# ----- distro table -----

echo "Test 1: distro table and derived suite list"
assert_equals "VALID_TRACKS" "stable v5 nightly" "${VALID_TRACKS[*]}"
assert_equals "VALID_DISTROS" "bookworm trixie" "${VALID_DISTROS[*]}"
assert_equals "VALID_ARCHES (amd64 only)" "amd64" "${VALID_ARCHES[*]}"
assert_equals "bookworm VERSION_ID" "12" "${DISTRO_VERSION_IDS[bookworm]}"
assert_equals "trixie VERSION_ID" "13" "${DISTRO_VERSION_IDS[trixie]}"
assert_equals "ALL_SUITES derived from tracks x distros" \
    "stable-bookworm v5-bookworm nightly-bookworm stable-trixie v5-trixie nightly-trixie" \
    "${ALL_SUITES[*]}"
for d in "${VALID_DISTROS[@]}"; do
    assert_succeeds "image defined for ${d}" test -n "${DISTRO_IMAGES[${d}]:-}"
done

# ----- resolve_publish_targets -----

echo ""
echo "Test 2: every (track, distro) pair resolves to exactly '<track>-<distro>'"
for t in "${VALID_TRACKS[@]}"; do
    for d in "${VALID_DISTROS[@]}"; do
        result="$(resolve_publish_targets "${t}" "${d}")"
        assert_equals "${t} ${d} -> single target, no bare alias" "${t}-${d}" "${result}"
    done
done

echo ""
echo "Test 3: invalid track / distro rejected (non-zero exit)"
assert_fails "track 'beta' rejected" resolve_publish_targets beta bookworm
assert_fails "distro 'sid' rejected" resolve_publish_targets stable sid
assert_fails "VERSION_ID '12' is not a suite label" resolve_publish_targets stable 12
assert_fails "unsupported release 'bullseye' rejected" resolve_publish_targets stable bullseye
assert_fails "empty distro rejected" resolve_publish_targets stable ""

# ----- is_valid_suite -----

echo ""
echo "Test 4: is_valid_suite whitelist enforcement"
for v in "${ALL_SUITES[@]}"; do
    assert_succeeds "is_valid_suite ${v} ok" is_valid_suite "${v}"
done
for bare in stable v5 nightly; do
    assert_fails "is_valid_suite bare '${bare}' rejected (no aliases)" is_valid_suite "${bare}"
done
assert_fails "is_valid_suite 'stable-bullseye' rejected" is_valid_suite stable-bullseye
assert_fails "is_valid_suite 'stable-sid' rejected" is_valid_suite stable-sid
assert_fails "is_valid_suite bogus rejected" is_valid_suite bogus

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
