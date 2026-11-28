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

# Unreachable-remote cases must not sleep between git remote retries.
export GIT_REMOTE_RETRY_DELAY=0

# Fixed "now" and relative tag ages (days -> epoch offsets). SOAK is 3 days.
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
    tag_repo "${PODMAN}" v6.0.2   2   # < 3 days: not soaked
    tag_repo "${PODMAN}" v6.1.0   1   # < 3 days: not soaked
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
export STABLE_SOAK_DAYS=3
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

echo "=== pasta (passt release tags YYYY_MM_DD.<sha>) ==="
PASTA_TAGS=$'2025_12_31.aaaaaaa\n2026_10_02.cba3570\n2026_09_25.df90211\nv1.0\nsomething-else'
assert_equals "pasta: newest release date first" \
    "2026_10_02.cba3570" "$(printf '%s\n' "${PASTA_TAGS}" | _rank_upstream_tags pasta | head -n1)"
assert_equals "pasta: year boundary sorts by date" \
    "2025_12_31.aaaaaaa" "$(printf '%s\n' "${PASTA_TAGS}" | _rank_upstream_tags pasta | tail -n1)"
assert_equals "pasta: non-release tags are ignored" \
    "3" "$(printf '%s\n' "${PASTA_TAGS}" | _rank_upstream_tags pasta | wc -l | tr -d ' ')"
assert_equals "pasta tag -> package version" "20261002" "$(pasta_version_from_tag 2026_10_02.cba3570)"
assert_equals "8-digit date passes through" "20261101" "$(pasta_version_from_tag 20261101)"
assert_equals "non-passt tag rejected" "rejected" "$(pasta_version_from_tag v1.2 2>/dev/null || echo rejected)"

echo "=== soak window (resolve_component, NOW fixed) ==="
assert_equals "series=6 soak=3 -> v6.0.1 (skips fresh 6.0.2/6.1.0, never 7.x)" \
    "v6.0.1" "$(PODMAN_SERIES=6 STABLE_SOAK_DAYS=3 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"
assert_equals "series=6 soak=0 -> v6.1.0 (age ignored)" \
    "v6.1.0" "$(PODMAN_SERIES=6 STABLE_SOAK_DAYS=0 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"
assert_equals "float soak=3 -> v7.0.0 (highest soaked overall)" \
    "v7.0.0" "$(PODMAN_SERIES='' STABLE_SOAK_DAYS=3 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"
# Own fixture: a 5-day-old tag is soaked under the default 3, not under 7.
SOAKDEF="${TEST_TMPDIR}/soakdef"; git init -q "${SOAKDEF}"
tag_repo "${SOAKDEF}" v1.0.0 20
tag_repo "${SOAKDEF}" v1.1.0  5
assert_equals "STABLE_SOAK_DAYS unset -> defaults to 3 (5-day-old v1.1.0 adopted, not v1.0.0)" \
    "v1.1.0" "$( unset STABLE_SOAK_DAYS; PODMAN_SERIES=1 resolve_component podman PODMAN_TAG PODMAN_SERIES "file://${SOAKDEF}" )"
assert_equals "soak=2 -> a 2-day-old tag counts as soaked (boundary is inclusive)" \
    "v6.0.2" "$(PODMAN_SERIES=6.0 STABLE_SOAK_DAYS=2 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"

echo "=== upstream URLs ==="
assert_equals "resolver resolves passt over https" \
    "pasta|PASTA_TAG|PASTA_SERIES|https://passt.top/passt" \
    "$(printf '%s\n' "${COMPONENT_ROWS[@]}" | grep '^pasta|')"
assert_equals "build_pasta.sh clones passt over https" "1" \
    "$(grep -c 'git_clone_update https://passt.top/passt passt' "${PROJECT_ROOT}/scripts/build_pasta.sh")"
assert_equals "no plaintext git:// passt URL anywhere in scripts" "0" \
    "$(grep -rlF "git:/""/passt.top" "${PROJECT_ROOT}/scripts" "${PROJECT_ROOT}/functions.sh" "${PROJECT_ROOT}/config.sh" | wc -l | tr -d ' ')"

echo "=== exact freeze bypasses soak ==="
assert_equals "PODMAN_TAG=v6.0.2 -> verbatim despite being unsoaked" \
    "v6.0.2" "$(PODMAN_TAG=v6.0.2 PODMAN_SERIES=6 STABLE_SOAK_DAYS=3 resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}")"
# The freeze must also announce itself on stderr (ambient-env foot-gun guard).
_freeze_err="$(PODMAN_TAG=v6.0.2 PODMAN_SERIES=6 STABLE_SOAK_DAYS=3 \
    resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" 2>&1 >/dev/null)"
assert_equals "exact freeze emits a stderr NOTE naming the var + value" \
    "1" "$(printf '%s\n' "${_freeze_err}" | grep -c 'NOTE podman: using exact PODMAN_TAG=v6.0.2' || true)"
assert_equals "exact freeze still yields the frozen tag on stdout" \
    "v6.0.2" "$(PODMAN_TAG=v6.0.2 PODMAN_SERIES=6 STABLE_SOAK_DAYS=3 \
        resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" 2>/dev/null)"

echo "=== hold on empty/absent series ==="
_hold_rc=0
( export PODMAN_SERIES=9 STABLE_SOAK_DAYS=3
  resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" ) >/dev/null 2>&1 || _hold_rc=$?
assert_equals "series=9 (no such series) -> HOLD (rc=1)" "1" "${_hold_rc}"

echo "=== v5 vs stable coupling (netavark 1.x vs 2.x) ==="
assert_equals "v5 track: netavark series=1 -> v1.17.2 (never 2.x)" \
    "v1.17.2" "$(NETAVARK_SERIES=1 STABLE_SOAK_DAYS=3 resolve_component netavark NETAVARK_TAG NETAVARK_SERIES "${N}")"
assert_equals "stable track: netavark series=2 -> v2.0.0" \
    "v2.0.0" "$(NETAVARK_SERIES=2 STABLE_SOAK_DAYS=3 resolve_component netavark NETAVARK_TAG NETAVARK_SERIES "${N}")"

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
( export PODMAN_SERIES=9 STABLE_SOAK_DAYS=3
  resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" ) >/dev/null 2>&1 || _det_rc=$?
assert_equals "reachable + no series match -> deterministic hold (rc=1)" "1" "${_det_rc}"
_unc_rc=0
( export STABLE_SOAK_DAYS=3
  resolve_component podman PODMAN_TAG PODMAN_SERIES "file://${TEST_TMPDIR}/does-not-exist" ) >/dev/null 2>&1 || _unc_rc=$?
assert_equals "unreachable remote -> uncertain hold (rc=2)" "2" "${_unc_rc}"

echo "=== malformed *_SERIES is rejected as uncertain (surfaced, not silent) ==="
_bad_rc=0
( export PODMAN_SERIES="6 ; rm -rf /" STABLE_SOAK_DAYS=3
  resolve_component podman PODMAN_TAG PODMAN_SERIES "${P}" ) >/dev/null 2>&1 || _bad_rc=$?
assert_equals "malformed series -> rc=2 (uncertain/surfaced)" "2" "${_bad_rc}"

echo "=== git remote calls retry transient failures ==="
# git shim: fails the first N remote calls (ls-remote/fetch, counted in a file),
# then runs the real git. Local calls (init, log) always pass through.
_RETRY_COUNT="${TEST_TMPDIR}/git-calls"
_flaky_git() {
    local lfail="$1"; shift
    [[ " $* " == *" ls-remote "* || " $* " == *" fetch "* ]] || { command git "$@"; return; }
    local ln; ln=$(( $(cat "${_RETRY_COUNT}" 2>/dev/null || echo 0) + 1 ))
    echo "${ln}" > "${_RETRY_COUNT}"
    [[ "${ln}" -gt "${lfail}" ]] || return 128
    command git "$@"
}
rm -f "${_RETRY_COUNT}"
assert_equals "list_upstream_tags: two dropped ls-remote calls -> still lists tags, no duplicates" \
    "v6.0.2 v6.0.1 v6.0.0" "$( git() { _flaky_git 2 "$@"; }; list_upstream_tags "${P}" podman 6.0 | tr '\n' ' ' | sed 's/ $//' )"
rm -f "${_RETRY_COUNT}"
assert_equals "_git_remote_retry: a dropped call leaves a retry note on stderr, not stdout" \
    "1 0" "$( git() { _flaky_git 1 "$@"; }; _err=$(_git_remote_retry ls-remote --tags "${P}" 2>&1 >/dev/null); _out=$(rm -f "${_RETRY_COUNT}"; _git_remote_retry ls-remote --tags "${P}" 2>/dev/null); echo "$(grep -c 'retrying git ls-remote' <<< "${_err}") $(grep -c 'retrying' <<< "${_out}")" )"
rm -f "${_RETRY_COUNT}"
assert_equals "tag_commit_epoch: two dropped fetches -> still returns the commit date" \
    "$(day 40)" "$( git() { _flaky_git 2 "$@"; }; tag_commit_epoch "${P}" v6.0.1 )"
rm -f "${_RETRY_COUNT}"
assert_equals "_git_remote_retry: persistent failure -> fails after GIT_REMOTE_ATTEMPTS tries" \
    "rc=128 calls=3" "$( git() { _flaky_git 99 "$@"; }; GIT_REMOTE_ATTEMPTS=3 _git_remote_retry ls-remote "${P}" >/dev/null 2>&1; echo "rc=$? calls=$(cat "${_RETRY_COUNT}")" )"

echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ ${FAIL_COUNT} -eq 0 ]] || exit 1
