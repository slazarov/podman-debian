#!/bin/bash

# Tests for scripts/check_republish_needed.sh: the pure helpers
# (extract_base, get_pkg_version) and the decision flow with a resolved-env
# file against a file:// repository, so no resolver or network is involved:
#   - every package (podman-suite included) current on every distro -> skip
#   - one distro stale, or podman-suite alone differs -> build
#   - a distro not published at all -> build
#   - an invalid resolved-env file -> exit 1, not a decision

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

assert_equals "podman-suite follows podman's base" "6.0.1" "$(extract_base 'v6.0.1' 'podman-suite')"

echo "=== decision flow with a resolved-env file ==="
GUARD="${PROJECT_ROOT}/scripts/check_republish_needed.sh"
ENVF="${TEST_TMPDIR}/resolved.env"
cat > "${ENVF}" <<'EOF'
export PODMAN_TAG="v6.0.1"
export BUILDAH_TAG="v1.43.0"
export CRUN_TAG="1.28"
export CONMON_TAG="v2.2.1"
export NETAVARK_TAG="v2.0.0"
export AARDVARK_DNS_TAG="v2.0.0"
export SKOPEO_TAG="v1.23.0"
export TOOLBOX_TAG="0.3"
export FUSE_OVERLAYFS_TAG="v1.16"
export CATATONIT_TAG="v0.2.1"
export CONTAINER_LIBS_TAG="common/v0.67.1"
export PASTA_TAG="2026_10_02.cba3570"
EOF

# write_suite <repo> <distro> [override-pkg override-version] -> a published
# stable-<distro> Packages.gz with every package at its target version.
write_suite() {
    local repo="$1" distro="$2" opkg="${3:-}" over="${4:-}"
    local vid="${DISTRO_VERSION_IDS[${distro}]}"
    local dir="${repo}/dists/stable-${distro}/main/binary-amd64"
    local row comp pkg tagvar tag ver
    mkdir -p "${dir}"
    : > "${dir}/Packages"
    for row in "${COMPONENT_ROWS[@]}"; do
        IFS='|' read -r comp pkg tagvar _ <<< "${row}"
        tag="$(sed -n "s/^export ${tagvar}=\"\(.*\)\"$/\1/p" "${ENVF}")"
        ver="$(extract_base "${tag}" "${comp}")~deb${vid}.podman${PACKAGE_REVISION}"
        [[ "${pkg}" == "${opkg}" ]] && ver="${over}"
        printf 'Package: %s\nVersion: %s\nArchitecture: amd64\n\n' "${pkg}" "${ver}" >> "${dir}/Packages"
    done
    gzip -f "${dir}/Packages"
}

# decide <repo> -> the skip=... line (exit code appended when non-zero)
decide() {
    local out rc=0
    out="$(env -u GITHUB_OUTPUT bash "${GUARD}" stable "file://$1" "${2:-${ENVF}}" 2>/dev/null)" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo "exit ${rc}"
    else
        echo "${out}"
    fi
}

R1="${TEST_TMPDIR}/repo-current"
for d in "${VALID_DISTROS[@]}"; do write_suite "${R1}" "${d}"; done
assert_equals "all current on every distro -> skip" "skip=true" "$(decide "${R1}")"

R2="${TEST_TMPDIR}/repo-trixie-stale"
write_suite "${R2}" bookworm
write_suite "${R2}" trixie podman-podman "6.0.0~deb13.podman${PACKAGE_REVISION}"
assert_equals "bookworm current, trixie stale -> build" "skip=false" "$(decide "${R2}")"

R3="${TEST_TMPDIR}/repo-suite-differs"
for d in "${VALID_DISTROS[@]}"; do write_suite "${R3}" "${d}"; done
write_suite "${R3}" trixie podman-suite "6.0.0~deb13.podman${PACKAGE_REVISION}"
assert_equals "only podman-suite differs -> build" "skip=false" "$(decide "${R3}")"

R4="${TEST_TMPDIR}/repo-trixie-absent"
write_suite "${R4}" bookworm
assert_equals "trixie not published -> build" "skip=false" "$(decide "${R4}")"

BAD="${TEST_TMPDIR}/bad.env"
{ cat "${ENVF}"; echo 'export PODMAN_TAG="v6.0.2"'; } > "${BAD}"
assert_equals "invalid resolved env -> exit 1" "exit 1" "$(decide "${R1}" "${BAD}")"

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"
[[ ${FAIL_COUNT} -eq 0 ]]
