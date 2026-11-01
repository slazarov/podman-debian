#!/bin/bash

# Tests for scripts/check_republish_needed.sh pure helpers
# (extract_base, get_pkg_version). Network-dependent resolution and the
# main() decision flow are exercised in CI, not here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
TEST_TMPDIR=""

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
        echo "    Got:      ${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

cleanup() {
    [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"
}
trap cleanup EXIT

# Source the helpers (BASH_SOURCE guard prevents main from running).
# shellcheck disable=SC1091
source "${PROJECT_ROOT}/scripts/check_republish_needed.sh"

echo "=== extract_base ==="
assert_equals "v-prefixed tag strips v"            "5.8.2"  "$(extract_base 'v5.8.2' 'podman')"
assert_equals "numeric-only tag unchanged (crun)"  "1.28"   "$(extract_base '1.28' 'crun')"
assert_equals "numeric-only tag unchanged (toolbox)" "0.3"  "$(extract_base '0.3' 'toolbox')"
assert_equals "namespaced container-libs tag"      "0.67.1" "$(extract_base 'common/v0.67.1' 'container-configs')"
assert_equals "catatonit v-prefixed"               "0.2.1"  "$(extract_base 'v0.2.1' 'catatonit')"
assert_equals "pasta release tag -> date"          "20261002" "$(extract_base '2026_10_02.cba3570' 'pasta')"

echo "=== get_pkg_version ==="
TEST_TMPDIR="$(mktemp -d)"
PKGFILE="${TEST_TMPDIR}/Packages"
cat > "${PKGFILE}" <<'EOF'
Package: podman-crun
Version: 1.28~deb12.podman1
Architecture: amd64

Package: podman-podman
Version: 5.8.2~deb12.podman1
Architecture: amd64

Package: podman-buildah
Version: 1.43.1~deb12.podman1
Architecture: amd64
EOF

assert_equals "finds podman version"          "5.8.2~deb12.podman1" "$(get_pkg_version "${PKGFILE}" 'podman-podman')"
assert_equals "finds crun version (first stanza)" "1.28~deb12.podman1" "$(get_pkg_version "${PKGFILE}" 'podman-crun')"
assert_equals "absent package -> empty"       ""                          "$(get_pkg_version "${PKGFILE}" 'podman-missing')"
# Guard against substring false-positives (podman vs podman-podman).
assert_equals "exact package match only"      ""                          "$(get_pkg_version "${PKGFILE}" 'podman')"

echo "=== distro table ==="
assert_equals "distros come from config.sh" "bookworm trixie" "${VALID_DISTROS[*]}"
assert_equals "bookworm VERSION_ID" "12" "${DISTRO_VERSION_IDS[bookworm]}"
assert_equals "trixie VERSION_ID" "13" "${DISTRO_VERSION_IDS[trixie]}"
assert_equals "default repo URL" "https://slazarov.github.io/podman-debian" "${REPO_URL_DEFAULT}"

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"
[[ ${FAIL_COUNT} -eq 0 ]]
