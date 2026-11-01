#!/bin/bash

# Test the CI build-matrix and publish-gating contract by parsing
# .github/workflows/build-packages.yml and running scripts/ci_matrix.sh.
# Asserts:
#   - the build matrix is generated from config.sh (scripts/ci_matrix.sh ->
#     resolve-track output -> fromJSON), one cell per VALID_DISTROS entry
#   - every cell runs in its distro's Debian container on an amd64 runner
#   - fail-fast: false under the build strategy
#   - distro-dimensioned Go cache key and artifact name
#   - the publish job downloads each distro's artifact into its own directory
#     (no merge), publishes every distro from config.sh, and refuses to deploy
#     when nothing was published
#   - the job containers come only from the matrix, the bootstrap leaves the
#     image's apt sources alone, and there is no arm64 in the workflows
#
# Prefers python3 + PyYAML for structural checks and falls back to grep when
# PyYAML is unavailable. The grep path strips comment lines so workflow
# comments cannot satisfy a check. Pure bash + optional python3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/build-packages.yml"
LINT_WORKFLOW="${PROJECT_ROOT}/.github/workflows/lint.yml"

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

# assert_contains <description> <haystack> <needle>
assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected to contain: ${needle}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# assert_true <description> <0-or-1>  (1 == condition holds)
assert_true() {
    local description="$1"
    local cond="$2"
    if [[ "${cond}" == "1" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo ""
echo "========================================"
echo "Test: CI build-matrix + publish-gating contract"
echo "========================================"
echo ""

if [[ ! -f "${WORKFLOW}" ]]; then
    echo "FAIL: workflow file not found at ${WORKFLOW}"
    exit 1
fi

NOCOMMENT="$(grep -v '^[[:space:]]*#' "${WORKFLOW}")"
NOCOMMENT_ALL="$(cat "${WORKFLOW}" "${LINT_WORKFLOW}" | grep -v '^[[:space:]]*#')"

# ============================================
# scripts/ci_matrix.sh output
# ============================================

echo "--- scripts/ci_matrix.sh ---"
MATRIX_JSON="$(bash "${PROJECT_ROOT}/scripts/ci_matrix.sh")"
expected_json="["
sep=""
for d in "${VALID_DISTROS[@]}"; do
    expected_json+="${sep}{\"distro\":\"${d}\",\"container\":\"${DISTRO_IMAGES[${d}]}\"}"
    sep=","
done
expected_json+="]"
assert_equals "matrix JSON has one cell per distro with its image" "${expected_json}" "${MATRIX_JSON}"
if command -v python3 &>/dev/null; then
    r="$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); print("1" if all(set(c)=={"distro","container"} for c in m) and len(m)>0 else "0")' "${MATRIX_JSON}")"
    assert_true "matrix JSON parses and every cell has distro+container only" "${r}"
fi
for d in "${VALID_DISTROS[@]}"; do
    assert_contains "image for ${d} is a Debian image" "${DISTRO_IMAGES[${d}]}" "debian:${d}"
done

# ============================================
# Workflow text (comments stripped)
# ============================================

echo ""
echo "--- workflow text (comments stripped) ---"
assert_contains "resolve-track runs scripts/ci_matrix.sh" "${NOCOMMENT}" "./scripts/ci_matrix.sh"
assert_contains "resolve-track exposes a matrix output" "${NOCOMMENT}" "matrix: \${{ steps.matrix.outputs.matrix }}"
assert_contains "build matrix comes from resolve-track" "${NOCOMMENT}" "include: \${{ fromJSON(needs.resolve-track.outputs.matrix) }}"
assert_contains "build runs in the matrix container" "${NOCOMMENT}" "container: \${{ matrix.container }}"
assert_contains "fail-fast: false present" "${NOCOMMENT}" "fail-fast: false"
assert_contains "Go cache key has matrix.distro" "${NOCOMMENT}" "key: go-\${{ matrix.distro }}-"
assert_contains "artifact name has matrix.distro" "${NOCOMMENT}" "name: debs-\${{ matrix.distro }}"
assert_contains "DISTRO override is the matrix distro" "${NOCOMMENT}" "DISTRO=\${{ matrix.distro }}"
assert_contains "build checks version ordering" "${NOCOMMENT}" "./scripts/verify_versions.sh"
assert_contains "publish downloads debs-* artifacts" "${NOCOMMENT}" "pattern: debs-*"
assert_true "publish never merges artifacts across distros" \
    "$(printf '%s\n' "${NOCOMMENT}" | grep -q 'merge-multiple: true' && echo 0 || echo 1)"
assert_contains "publish loops over VALID_DISTROS" "${NOCOMMENT}" 'publish_distro "${distro}" "artifacts/debs-${distro}"'
assert_contains "publish refuses to deploy when nothing published" "${NOCOMMENT}" 'refusing to deploy'
assert_contains "smoke test runs per distro" "${NOCOMMENT}" './scripts/smoke_repo_install.sh "${distro}"'
assert_contains "ci_publish.sh invoked" "${NOCOMMENT}" "ci_publish.sh"

runs_on="$(printf '%s\n' "${NOCOMMENT}" | grep -E '^[[:space:]]*runs-on:' | sed 's/.*runs-on:[[:space:]]*//' | sort -u | tr '\n' ' ')"
assert_equals "every job runs on one GitHub-hosted runner label" "1" \
    "$(printf '%s\n' "${runs_on}" | wc -w | tr -d ' ')"
containers="$(printf '%s\n' "${NOCOMMENT_ALL}" | grep -E '^[[:space:]]*container:' | sed 's/.*container:[[:space:]]*//' | sort -u)"
assert_equals "the only job container is the matrix container" "\${{ matrix.container }}" "${containers}"
assert_true "no apt sources rewriting (no mirror swaps)" \
    "$(printf '%s\n' "${NOCOMMENT_ALL}" | grep -qE 'sed -i[^|]*sources|sources\.list' && echo 0 || echo 1)"
assert_true "no arm64 / arm runners anywhere" \
    "$(printf '%s\n' "${NOCOMMENT_ALL}" | grep -qiE 'arm64|aarch64|-arm\b' && echo 0 || echo 1)"
assert_true "no hard-coded distro labels in the build workflow" \
    "$(printf '%s\n' "${NOCOMMENT}" | grep -qE 'bookworm|trixie' && echo 0 || echo 1)"

ncron="$(printf '%s\n' "${NOCOMMENT}" | grep -cE "cron: '30 [456] \* \* \*'")"
assert_equals "three schedule crons (30 4/5/6)" "3" "${ncron}"
assert_contains "dispatch build_track offers v5" "${NOCOMMENT}" "- v5"

# ============================================
# Structural checks via PyYAML (when available)
# ============================================

if python3 -c 'import yaml' 2>/dev/null; then
    echo ""
    echo "--- Python/PyYAML structural assertions ---"
    py() { python3 -c "$1" "${WORKFLOW}"; }

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d['jobs']
ok = (set(j) == {'resolve-track','check-changes','check-republish','build','publish'}
      and j['build']['strategy']['fail-fast'] is False
      and 'resolve-track' in j['build']['needs']
      and j['publish']['needs'] == ['resolve-track','build'])
print('1' if ok else '0')
")
    assert_true "py: job set, fail-fast and needs" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get('on', d.get(True))
crons = {c['cron'] for c in on['schedule']}
opts = on['workflow_dispatch']['inputs']['build_track']['options']
print('1' if {'30 4 * * *','30 5 * * *','30 6 * * *'} <= crons and opts == ['stable','v5','nightly'] else '0')
")
    assert_true "py: crons and dispatch options" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
cc = str(d['jobs']['check-changes']['if'])
cr = str(d['jobs']['check-republish']['if'])
ok = (\"github.event.schedule == '30 4 * * *'\" in cc
      and 'resolve-track' in str(d['jobs']['check-republish'].get('needs', []))
      and \"outputs.track == 'stable'\" in cr and \"outputs.track == 'v5'\" in cr)
print('1' if ok else '0')
")
    assert_true "py: check-changes is nightly-cron-only; check-republish gates stable/v5" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['publish']['steps']
dl = [s for s in steps if 'download-artifact' in str(s.get('uses',''))]
ok = len(dl) == 1 and dl[0]['with'].get('pattern') == 'debs-*' and not dl[0]['with'].get('merge-multiple', False)
print('1' if ok else '0')
")
    assert_true "py: one per-artifact download, no merge" "${r}"
else
    echo ""
    echo "  SKIP: PyYAML not available (grep checks above still ran)"
fi

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
