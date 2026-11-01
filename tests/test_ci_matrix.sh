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
#   - runs queue instead of cancelling (per-track workflow group, one
#     pages-deploy group for publish), with least-privilege permissions and
#     no persisted checkout credentials
#   - the resolver runs once, in resolve-track; a hold stops the build even
#     with force_rebuild; the nightly checkpoint is only restored before the
#     build and only saved after the deploy and the propagation check
#   - publish selects distros from cell conclusions, downloads strictly, and
#     smoke-tests only what it built
#   - the compiler caches are enabled, keyed and checked
#   - lint installs the integration test tools and makes skips fail
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
assert_contains "publish runs ci_publish.sh per selected distro" "${NOCOMMENT}" '"artifacts/debs-${distro}" "${REPO_URL}" "repo-output"'
assert_contains "publish selects distros from cell conclusions" "${NOCOMMENT}" 'published_distros "${RUNNER_TEMP}/cells.txt" artifacts'
assert_contains "publish reads the latest cell conclusions of the whole run" "${NOCOMMENT}" '/actions/runs/${GITHUB_RUN_ID}/jobs?filter=latest'
assert_contains "build cells are named by distro" "${NOCOMMENT}" 'name: build-${{ matrix.distro }}'
assert_contains "publish refuses to deploy when nothing published" "${NOCOMMENT}" 'refusing to deploy'
assert_contains "smoke test runs per distro" "${NOCOMMENT}" './scripts/smoke_repo_install.sh "${distro}"'
assert_true "publish never continues past a failed download" \
    "$(printf '%s\n' "${NOCOMMENT}" | grep -q 'continue-on-error' && echo 0 || echo 1)"
assert_contains "integrity gate checks signatures" "${NOCOMMENT}" 'verify_repo_integrity.sh --keyring'
assert_contains "propagation is checked after deploy" "${NOCOMMENT}" 'wait_for_propagation "${REPO_URL}"'
assert_equals "the resolver runs exactly once (resolve-track)" "1" \
    "$(printf '%s\n' "${NOCOMMENT}" | grep -c 'resolve_track_versions\|resolve_versions.sh')"
assert_contains "workflow runs queue per track" "${NOCOMMENT}" 'group: build-packages-${{'
assert_contains "publish has its own deploy queue" "${NOCOMMENT}" 'group: pages-deploy'
assert_equals "both concurrency groups use queue: max" "2" \
    "$(printf '%s\n' "${NOCOMMENT}" | grep -cE '^[[:space:]]*queue: max$')"
assert_true "no concurrency group cancels in-progress runs" \
    "$(printf '%s\n' "${NOCOMMENT}" | grep -q 'cancel-in-progress: true' && echo 0 || echo 1)"
assert_equals "every checkout drops its credentials" \
    "$(printf '%s\n' "${NOCOMMENT_ALL}" | grep -c 'actions/checkout@')" \
    "$(printf '%s\n' "${NOCOMMENT_ALL}" | grep -c 'persist-credentials: false')"
assert_contains "compiler cache key" "${NOCOMMENT}" 'key: cc-v1-${{ matrix.distro }}-amd64-${{ steps.track.outputs.track }}-rust${{ steps.env.outputs.rust }}-sccache${{ steps.env.outputs.sccache }}-${{ github.run_id }}'
assert_contains "compiler caches enabled and strict" "${NOCOMMENT}" 'SCCACHE_ENABLED=true CCACHE_ENABLED=true CACHE_STRICT=true'
assert_contains "compiler cache use is checked" "${NOCOMMENT}" 'compiler_cache_report'
assert_contains "ccache counters are zeroed before the build" "${NOCOMMENT}" 'ccache --zero-stats'
assert_contains "compiler cache is saved only when it changed" "${NOCOMMENT}" "if: steps.ccreport.outputs.changed == 'true'"
assert_true "the compiler cache is not saved on every run by actions/cache" \
    "$(printf '%s\n' "${NOCOMMENT}" | grep -B3 '~/.cache/sccache' | grep -q 'uses: actions/cache@' && echo 0 || echo 1)"
assert_contains "build cells record nightly revisions" "${NOCOMMENT}" 'nightly_record_revisions build'
assert_contains "lint installs the integration test tools" "$(grep -v '^[[:space:]]*#' "${LINT_WORKFLOW}")" 'reprepro gnupg gpgv dpkg-dev'
assert_contains "lint makes integration skips fail" "$(grep -v '^[[:space:]]*#' "${LINT_WORKFLOW}")" "REQUIRE_INTEGRATION_DEPS: '1'"
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
debs = [s for s in dl if s['with'].get('pattern') == 'debs-*']
ok = (len(debs) == 1
      and not any(s['with'].get('merge-multiple', False) for s in dl)
      and not any(s.get('continue-on-error') for s in steps))
print('1' if ok else '0')
")
    assert_true "py: one per-artifact debs download, no merge, no continue-on-error" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d['jobs']
wc = d['concurrency']
pc = j['publish']['concurrency']
ok = (d['permissions'] == {'contents': 'read'}
      and j['publish']['permissions'] == {'contents': 'read', 'actions': 'read', 'pages': 'write', 'id-token': 'write'}
      and all('permissions' not in v for k, v in j.items() if k != 'publish')
      and wc.get('queue') == 'max' and wc.get('cancel-in-progress') is False
      and pc == {'group': 'pages-deploy', 'cancel-in-progress': False, 'queue': 'max'})
print('1' if ok else '0')
")
    assert_true "py: least-privilege permissions and queued concurrency" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d['jobs']
rt = j['resolve-track']
cond = [c.strip() for c in str(j['build']['if']).split('&&')]
hold = [c for c in cond if 'hold' in c]
ok = ('hold' in rt['outputs'] and 'resolved_env' in rt['outputs']
      and any('resolve_track_versions' in str(s.get('run', '')) for s in rt['steps'])
      and len(hold) == 1 and 'force_rebuild' not in hold[0] and \"!= 'true'\" in hold[0]
      and \"hold != 'true'\" in str(j['check-republish']['if']))
print('1' if ok else '0')
")
    assert_true "py: resolve once; a hold stops the build even with force_rebuild" "${r}"

    r=$(py "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d['jobs']
cc = [str(s.get('uses', '')) for s in j['check-changes']['steps']]
ps = j['publish']['steps']
idx = lambda pred: next(i for i, s in enumerate(ps) if pred(s))
deploy = idx(lambda s: s.get('id') == 'deployment')
wait = idx(lambda s: 'wait_for_propagation' in str(s.get('run', '')))
save = idx(lambda s: 'actions/cache/save' in str(s.get('uses', '')))
ok = (any('actions/cache/restore' in u for u in cc)
      and not any('actions/cache@' in u or 'actions/cache/save' in u for u in cc)
      and deploy < wait < save
      and ps[save]['with']['path'] == '/tmp/nightly-revisions/checkpoint.txt')
print('1' if ok else '0')
")
    assert_true "py: nightly checkpoint restored before build, saved after deploy + propagation" "${r}"
else
    echo ""
    echo "  SKIP: PyYAML not available (grep checks above still ran)"
    if [[ "${REQUIRE_INTEGRATION_DEPS:-0}" == "1" ]]; then
        echo "  FAIL: REQUIRE_INTEGRATION_DEPS=1 but PyYAML is missing."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
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
