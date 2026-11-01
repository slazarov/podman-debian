#!/bin/bash

# test_resolve_versions.sh — offline unit tests for scripts/resolve_versions.sh
# (version resolution precedence, series capping, soak window, buildah go.mod
# parsing, and hold-on-uncertainty).
#
# Fully offline: it builds throwaway local git repos with tags at controlled
# commit dates (GIT_COMMITTER_DATE="@<epoch>") and resolves against file:// URLs,
# injecting STABLE_NOW_EPOCH so soak math is deterministic. SKIP_CONFIG_SOURCE=1
# keeps config.sh (distro detection, which fails off Debian, and network
# toolchain detection) out.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
TEST_TMPDIR=""

PASS_COUNT=0
FAIL_COUNT=0

assert_equals() {
    local description="$1" expected="$2" actual="$3"
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

cleanup() { [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"; }
trap cleanup EXIT

# Fixed "now" and relative tag ages (days -> epoch offsets). SOAK is 7 days.
NOW_EPOCH=2000000000
day() { echo $(( NOW_EPOCH - ($1 * 86400) )); }   # epoch $1 days before NOW

# tag_repo <dir> <tag> <days-old> [file-content] — commit + tag at a controlled date.
tag_repo() {
    local dir="$1" tag="$2" days="$3" content="${4:-$2}"
    local epoch; epoch=$(day "${days}")
    echo "${content}" > "${dir}/f"
    git -C "${dir}" add -A
    GIT_COMMITTER_DATE="@${epoch} +0000" GIT_AUTHOR_DATE="@${epoch} +0000" \
        git -C "${dir}" commit -q -m "${tag}"
    git -C "${dir}" tag "${tag}"
}

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

    # podman: 5.x + 6.x + a wrong-major 7.x; 6.0.2/6.1.0 are too fresh to soak.
    PODMAN="${TEST_TMPDIR}/podman"; git init -q "${PODMAN}"
    tag_repo "${PODMAN}" v5.8.5 100
    tag_repo "${PODMAN}" v6.0.0  90
    tag_repo "${PODMAN}" v6.0.1  40
    tag_repo "${PODMAN}" v6.0.2   3   # < 7 days: not soaked
    tag_repo "${PODMAN}" v6.1.0   1   # < 7 days: not soaked
    tag_repo "${PODMAN}" v7.0.0  30
    tag_repo "${PODMAN}" v6.0.0-rc1 95

    # netavark: 1.x (podman 5) and 2.0 (podman 6), both soaked.
    NETAVARK="${TEST_TMPDIR}/netavark"; git init -q "${NETAVARK}"
    tag_repo "${NETAVARK}" v1.17.1 60
    tag_repo "${NETAVARK}" v1.17.2 50
    tag_repo "${NETAVARK}" v2.0.0  40

    # container-libs: namespaced common/v* (plus image/storage noise).
    CLIBS="${TEST_TMPDIR}/container-libs"; git init -q "${CLIBS}"
    tag_repo "${CLIBS}" common/v0.67.1 60
    tag_repo "${CLIBS}" common/v0.68.0 50
    tag_repo "${CLIBS}" common/v0.68.1 40
    tag_repo "${CLIBS}" image/v0.65.0  45
    tag_repo "${CLIBS}" storage/v0.70.0 45
}

setup

# Source the resolver (BASH_SOURCE guard prevents main from running; sets
# SKIP_CONFIG_SOURCE and toolpath before sourcing functions.sh).
export STABLE_NOW_EPOCH="${NOW_EPOCH}"
export STABLE_SOAK_DAYS=7
# shellcheck source=../scripts/resolve_versions.sh
source "${PROJECT_ROOT}/scripts/resolve_versions.sh"

P="file://${PODMAN}"
N="file://${NETAVARK}"
C="file://${CLIBS}"

echo "=== _rank_upstream_tags (ranking + series + rc exclusion) ==="
assert_equals "float picks highest overall" \
    "v7.0.0" "$(list_upstream_tags "${P}" podman | head -n1)"
assert_equals "major cap 6 -> highest 6.x, never 7.x" \
    "v6.1.0" "$(list_upstream_tags "${P}" podman 6 | head -n1)"
assert_equals "major cap 6 excludes 7.x entirely" \
    "0" "$(list_upstream_tags "${P}" podman 6 | grep -c '^v7' || true)"
assert_equals "rc tags are excluded" \
    "0" "$(list_upstream_tags "${P}" podman | grep -c 'rc' || true)"
assert_equals "namespaced series 0 -> highest common/v0.*" \
    "common/v0.68.1" "$(list_upstream_tags "${C}" container-configs 0 | head -n1)"
assert_equals "namespaced ignores image/storage" \
    "0" "$(list_upstream_tags "${C}" container-configs 0 | grep -cE '^(image|storage)/' || true)"

echo "=== soak window (resolve_component, NOW fixed) ==="
assert_equals "series=6 soak=7 -> v6.0.1 (skips fresh 6.0.2/6.1.0, never 7.x)" \
    "v6.0.1" "$(PODMAN_SERIES=6 STABLE_SOAK_DAYS=7 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"
assert_equals "series=6 soak=0 -> v6.1.0 (age ignored)" \
    "v6.1.0" "$(PODMAN_SERIES=6 STABLE_SOAK_DAYS=0 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"
assert_equals "float soak=7 -> v7.0.0 (highest soaked overall)" \
    "v7.0.0" "$(PODMAN_SERIES='' STABLE_SOAK_DAYS=7 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"

echo "=== exact freeze bypasses soak ==="
assert_equals "PODMAN_TAG=v6.0.2 -> verbatim despite being unsoaked" \
    "v6.0.2" "$(PODMAN_TAG=v6.0.2 PODMAN_SERIES=6 STABLE_SOAK_DAYS=7 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"
# The freeze must also announce itself on stderr (ambient-env foot-gun guard).
_freeze_err="$(PODMAN_TAG=v6.0.2 PODMAN_SERIES=6 STABLE_SOAK_DAYS=7 \
    resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" 2>&1 >/dev/null)"
assert_equals "exact freeze emits a stderr NOTE naming the var + value" \
    "1" "$(printf '%s\n' "${_freeze_err}" | grep -c 'NOTE podman: using exact PODMAN_TAG=v6.0.2' || true)"
assert_equals "exact freeze still yields the frozen tag on stdout" \
    "v6.0.2" "$(PODMAN_TAG=v6.0.2 PODMAN_SERIES=6 STABLE_SOAK_DAYS=7 \
        resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" 2>/dev/null)"

echo "=== hold on empty/absent series ==="
_hold_rc=0
( export PODMAN_SERIES=9 STABLE_SOAK_DAYS=7
  resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" ) >/dev/null 2>&1 || _hold_rc=$?
assert_equals "series=9 (no such series) -> HOLD (rc=1)" "1" "${_hold_rc}"

echo "=== v5 vs stable coupling (netavark 1.x vs 2.x) ==="
assert_equals "v5 track: netavark series=1 -> v1.17.2 (never 2.x)" \
    "v1.17.2" "$(NETAVARK_SERIES=1 STABLE_SOAK_DAYS=7 resolve_component netavark NETAVARK_TAG NETAVARK_SERIES "${N}")"
assert_equals "stable track: netavark series=2 -> v2.0.0" \
    "v2.0.0" "$(NETAVARK_SERIES=2 STABLE_SOAK_DAYS=7 resolve_component netavark NETAVARK_TAG NETAVARK_SERIES "${N}")"

echo "=== buildah go.mod parser (both module paths) ==="
assert_equals "podman 5.x path: github.com/containers/buildah v1.43.2" \
    "1.43.2" "$(printf '\tgithub.com/containers/buildah v1.43.2\n' | parse_buildah_gomod_version)"
assert_equals "podman 6.x path: go.podman.io/buildah v1.44.0" \
    "1.44.0" "$(printf '\tgo.podman.io/buildah v1.44.0\n' | parse_buildah_gomod_version)"
assert_equals "ignores an indirect buildah require" \
    "1.44.0" "$(printf '\tgo.podman.io/buildah v1.44.0\n\tgithub.com/x/buildah v9.9.9 // indirect\n' | parse_buildah_gomod_version)"
assert_equals "rejects a Go pseudo-version (falls back to series)" \
    "" "$(printf '\tgo.podman.io/buildah v1.44.1-0.20260101120000-abcdef123456\n' | parse_buildah_gomod_version)"

echo "=== pre-release exclusion is anchored (does not drop substring 'rc') ==="
assert_equals "real -rcN pre-release excluded" \
    "v2.0.0" "$(printf 'v2.0.0\nv2.0.0-rc1\n' | _rank_upstream_tags '' '' | head -n1)"
assert_equals "tag with 'rc' as a mere substring is kept and ranks" \
    "v2.0.1-arch" "$(printf 'v2.0.0\nv2.0.1-arch\n' | _rank_upstream_tags '' '' | head -n1)"

echo "=== hold cause: deterministic (rc=1) vs uncertain (rc=2) ==="
_det_rc=0
( export PODMAN_SERIES=9 STABLE_SOAK_DAYS=7
  resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" ) >/dev/null 2>&1 || _det_rc=$?
assert_equals "reachable + no series match -> deterministic hold (rc=1)" "1" "${_det_rc}"
_unc_rc=0
( export STABLE_SOAK_DAYS=7
  resolve_component podman PODMAN_TAG PODMAN_SERIES "file://${TEST_TMPDIR}/does-not-exist" ) >/dev/null 2>&1 || _unc_rc=$?
assert_equals "unreachable remote -> uncertain hold (rc=2)" "2" "${_unc_rc}"

echo "=== malformed *_SERIES is rejected as uncertain (surfaced, not silent) ==="
_bad_rc=0
( export PODMAN_SERIES="6 ; rm -rf /" STABLE_SOAK_DAYS=7
  resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" ) >/dev/null 2>&1 || _bad_rc=$?
assert_equals "malformed series -> rc=2 (uncertain/surfaced)" "2" "${_bad_rc}"

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ ${FAIL_COUNT} -eq 0 ]] || exit 1
