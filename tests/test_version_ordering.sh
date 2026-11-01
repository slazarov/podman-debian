#!/bin/bash

# Test the version-suffix ordering contract: run scripts/verify_versions.sh
# (dpkg --compare-versions over literal fixtures) and check that config.sh
# and package_all.sh still build versions in the form those fixtures assume.
#
# The dpkg part is skipped on hosts without dpkg; the form checks run
# everywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo ""
echo "========================================"
echo "Test: version suffix ordering"
echo "========================================"
echo ""

echo "Test 1: config.sh composes ~deb{VERSION_ID}.podman{N}"
if grep -qF 'export VERSION_SUFFIX="~deb${DISTRO_VERSION_ID}.podman${PACKAGE_REVISION}"' "${PROJECT_ROOT}/config.sh"; then
    pass "VERSION_SUFFIX form"
else
    fail "VERSION_SUFFIX in config.sh is not ~deb\${DISTRO_VERSION_ID}.podman\${PACKAGE_REVISION}"
fi

echo ""
echo "Test 2: nightly versions use the ~~git marker"
if grep -qF '"${base_version}~~git${datestamp}.${short_sha}"' "${PROJECT_ROOT}/scripts/package_all.sh" \
    && grep -qF '"${datestamp}~~git${short_sha}"' "${PROJECT_ROOT}/scripts/package_all.sh"; then
    pass "nightly marker form"
else
    fail "package_all.sh nightly versions do not use ~~git"
fi

echo ""
echo "Test 3: scripts/verify_versions.sh passes (dpkg host only)"
if command -v dpkg &>/dev/null; then
    if output="$(bash "${PROJECT_ROOT}/scripts/verify_versions.sh" 2>&1)"; then
        pass "verify_versions.sh"
    else
        fail "verify_versions.sh"
        printf '%s\n' "${output}" | sed 's/^/    /'
    fi
else
    echo "  SKIP: dpkg not available"
fi

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"

[[ ${FAIL_COUNT} -eq 0 ]]
