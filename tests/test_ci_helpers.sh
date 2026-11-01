#!/bin/bash

# Tests for scripts/ci_helpers.sh: fetch classification and retries, the
# resolved-environment validator, the nightly revision checkpoint (record,
# detect, merge), build cell selection, deploy propagation and the compiler
# cache statistics parsers.
#
# fetch_url runs against tests/lib/mock_http_server.py, which injects HTTP
# errors and cut-off bodies. Needs python3, curl and git; prints SKIP
# without them (a failure under REQUIRE_INTEGRATION_DEPS=1).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# shellcheck source=tests/lib/mock_http.sh
source "${SCRIPT_DIR}/lib/mock_http.sh"

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

if ! command -v python3 &>/dev/null || ! command -v curl &>/dev/null || ! command -v git &>/dev/null; then
    echo "  SKIP: python3, curl and git are needed."
    require_integration_deps "python3/curl/git"
    echo "Results: 0 passed, 0 failed (SKIPPED on this host)"
    exit 0
fi

# shellcheck source=scripts/ci_helpers.sh
source "${PROJECT_ROOT}/scripts/ci_helpers.sh"

TMP="$(mktemp -d)"
cleanup() {
    stop_mock_http
    rm -rf "${TMP}"
}
trap cleanup EXIT

export FETCH_RETRY_DELAY=0
export FETCH_ATTEMPTS=3

# fetch_rc <url> <dest> -> prints fetch_url's return code
fetch_rc() {
    local rc=0
    fetch_url "$1" "$2" 2>/dev/null || rc=$?
    echo "${rc}"
}

# ============================================
echo "=== fetch_url classification and retries ==="
# ============================================

WWW="${TMP}/www"
mkdir -p "${WWW}/dists/s"
printf 'Release body\n' > "${WWW}/dists/s/Release"
head -c 20000 /dev/urandom > "${WWW}/big.deb"
LOG="${TMP}/hits.log"

start_mock_http "${WWW}" "${LOG}" \
    --rule '/gone$=410' \
    --rule '/always503$=503' \
    --rule '/flaky$=503:2' \
    --rule '/limited$=429:1' \
    --rule '/forbidden$=403' \
    --rule '/cut.deb$=truncate' \
    --rule '/big.deb$=truncate:1'
cp "${WWW}/dists/s/Release" "${WWW}/flaky"
cp "${WWW}/dists/s/Release" "${WWW}/limited"
cp "${WWW}/big.deb" "${WWW}/cut.deb"

D="${TMP}/dl"
mkdir -p "${D}"

assert_equals "200 -> 0" "0" "$(fetch_rc "${MOCK_URL}/dists/s/Release" "${D}/ok")"
assert_equals "200 body written" "Release body" "$(cat "${D}/ok")"
assert_equals "404 -> 4 (absent)" "4" "$(fetch_rc "${MOCK_URL}/dists/missing/Release" "${D}/nf")"
assert_equals "404 writes nothing" "no" "$([[ -e "${D}/nf" ]] && echo yes || echo no)"
assert_equals "410 -> 4 (absent)" "4" "$(fetch_rc "${MOCK_URL}/gone" "${D}/gone")"

assert_equals "503 every time -> 1 (error, not absent)" "1" "$(fetch_rc "${MOCK_URL}/always503" "${D}/e")"
assert_equals "503 retried FETCH_ATTEMPTS times" "3" "$(mock_hits "${LOG}" '/always503$')"
assert_equals "503 writes nothing" "no" "$([[ -e "${D}/e" ]] && echo yes || echo no)"

assert_equals "503 twice then 200 -> 0" "0" "$(fetch_rc "${MOCK_URL}/flaky" "${D}/flaky")"
assert_equals "flaky body is complete" "Release body" "$(cat "${D}/flaky")"
assert_equals "429 once then 200 -> 0" "0" "$(fetch_rc "${MOCK_URL}/limited" "${D}/limited")"
assert_equals "403 -> 1 without retry" "1" "$(fetch_rc "${MOCK_URL}/forbidden" "${D}/f")"
assert_equals "403 asked once" "1" "$(mock_hits "${LOG}" '/forbidden$')"

assert_equals "cut-off body every time -> 1" "1" "$(fetch_rc "${MOCK_URL}/cut.deb" "${D}/cut.deb")"
assert_equals "cut-off body leaves no partial file" "no" "$([[ -e "${D}/cut.deb" ]] && echo yes || echo no)"
assert_equals "cut-off body once, then complete -> 0" "0" "$(fetch_rc "${MOCK_URL}/big.deb" "${D}/big.deb")"
assert_equals "retried download is byte-identical" "yes" "$(cmp -s "${WWW}/big.deb" "${D}/big.deb" && echo yes || echo no)"

GOOD_URL="${MOCK_URL}"
stop_mock_http
assert_equals "connection refused -> 1" "1" "$(fetch_rc "${GOOD_URL}/dists/s/Release" "${D}/refused")"
refused_msg="$(fetch_url "${GOOD_URL}/dists/s/Release" "${D}/refused" 2>&1 >/dev/null | tail -n 1 || true)"
assert_equals "final error carries curl's own message" "yes" \
    "$([[ "${refused_msg}" == ERROR:*"curl exit 7: curl: (7)"* ]] && echo yes || echo no)"

assert_equals "file:// present -> 0" "0" "$(fetch_rc "file://${WWW}/dists/s/Release" "${D}/file-ok")"
assert_equals "file:// missing -> 4" "4" "$(fetch_rc "file://${WWW}/nope" "${D}/file-nf")"

# ============================================
echo "=== validate_resolved_env ==="
# ============================================

GOOD_ENV="${TMP}/good.env"
cat > "${GOOD_ENV}" <<'EOF'
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
export PROTOC_VERSION="29.3"
EOF

vrc() {
    local rc=0
    validate_resolved_env "$1" 2>/dev/null || rc=$?
    echo "${rc}"
}

assert_equals "resolver-shaped output is valid" "0" "$(vrc "${GOOD_ENV}")"
assert_equals "pairs: one KEY=VALUE per export" \
    "PODMAN_TAG=v6.0.1 CONTAINER_LIBS_TAG=common/v0.67.1 PASTA_TAG=2026_10_02.cba3570" \
    "$(resolved_env_pairs "${GOOD_ENV}" | grep -E '^(PODMAN|CONTAINER_LIBS|PASTA)_TAG=' | xargs)"

grep -v '^export SKOPEO_TAG=' "${GOOD_ENV}" > "${TMP}/missing.env"
assert_equals "missing component tag is rejected" "1" "$(vrc "${TMP}/missing.env")"
{ cat "${GOOD_ENV}"; echo 'export LD_PRELOAD="/tmp/x.so"'; } > "${TMP}/unknown.env"
assert_equals "unknown name is rejected" "1" "$(vrc "${TMP}/unknown.env")"
# shellcheck disable=SC2016
{ cat "${GOOD_ENV}"; echo 'export PROTOC_TAG="$(touch /tmp/pwned)"'; } > "${TMP}/inject.env"
assert_equals "command substitution is rejected" "1" "$(vrc "${TMP}/inject.env")"
{ cat "${GOOD_ENV}"; echo 'export PODMAN_TAG="v6.0.2"'; } > "${TMP}/dup.env"
assert_equals "duplicate name is rejected" "1" "$(vrc "${TMP}/dup.env")"
{ cat "${GOOD_ENV}"; echo 'rm -rf /'; } > "${TMP}/cmd.env"
assert_equals "a plain command line is rejected" "1" "$(vrc "${TMP}/cmd.env")"
: > "${TMP}/empty.env"
assert_equals "empty file is rejected" "1" "$(vrc "${TMP}/empty.env")"
assert_equals "missing file is rejected" "1" "$(vrc "${TMP}/does-not-exist.env")"
assert_equals "invalid file yields no pairs" "" "$(resolved_env_pairs "${TMP}/inject.env" 2>/dev/null || true)"

# The required set must be exactly the resolver's *_TAG column.
resolver_keys="$(sed -n '/^COMPONENT_ROWS=(/,/^)/p' "${PROJECT_ROOT}/scripts/resolve_versions.sh" \
    | awk -F'|' 'NF > 1 {print $2}' | sort | xargs)"
helper_keys="$(printf '%s\n' "${RESOLVED_ENV_REQUIRED_KEYS[@]}" | sort | xargs)"
assert_equals "required keys match resolve_versions.sh COMPONENT_ROWS" "${resolver_keys}" "${helper_keys}"

# ============================================
echo "=== nightly checkpoint: record, detect, merge ==="
# ============================================

# A fake build/ tree: one git clone per component.
BUILD="${TMP}/build"
declare -A HEADS=()
declare -A URL_HEADS=()
for row in "${NIGHTLY_SOURCES[@]}"; do
    IFS='|' read -r comp dir url <<< "${row}"
    mkdir -p "${BUILD}/${dir}"
    git -C "${BUILD}/${dir}" init -q
    git -C "${BUILD}/${dir}" -c user.name=t -c user.email=t@example.invalid \
        commit -q --allow-empty -m "${comp}"
    HEADS[${comp}]="$(git -C "${BUILD}/${dir}" rev-parse HEAD)"
    URL_HEADS[${url}]="${HEADS[${comp}]}"
done

REVS_BOOKWORM="${TMP}/revs-bookworm.txt"
nightly_record_revisions "${BUILD}" bookworm > "${REVS_BOOKWORM}"
assert_equals "one record line per component" "${#NIGHTLY_SOURCES[@]}" "$(wc -l < "${REVS_BOOKWORM}" | tr -d ' ')"
assert_equals "record holds the built pasta commit" "bookworm pasta ${HEADS[pasta]}" "$(grep ' pasta ' "${REVS_BOOKWORM}")"

mv "${BUILD}/passt" "${BUILD}/passt.moved"
rc=0
nightly_record_revisions "${BUILD}" bookworm > /dev/null 2>&1 || rc=$?
assert_equals "a missing clone fails the record" "1" "${rc}"
mv "${BUILD}/passt.moved" "${BUILD}/passt"

# Upstream HEADs come from a table instead of the network.
nightly_remote_head() {
    [[ -n "${URL_HEADS[$1]:-}" ]] || return 1
    printf '%s\n' "${URL_HEADS[$1]}"
}

CP="${TMP}/checkpoint.txt"
assert_equals "no checkpoint -> build" "skip=false" "$(nightly_detect_changes "${CP}" bookworm trixie 2>/dev/null)"

# Nightly run 1: bookworm deployed, trixie's cell failed. Only bookworm's
# revisions reach the checkpoint.
nightly_merge_revisions "${CP}" "${CP}.new" "${REVS_BOOKWORM}"
mv "${CP}.new" "${CP}"
assert_equals "checkpoint holds only the deployed distro" "0" "$(grep -c '^trixie ' "${CP}" || true)"
assert_equals "trixie never deployed -> build" "skip=false" "$(nightly_detect_changes "${CP}" bookworm trixie 2>/dev/null)"
assert_equals "bookworm alone is current" "skip=true" "$(nightly_detect_changes "${CP}" bookworm 2>/dev/null)"

# Nightly run 2: both deployed.
nightly_record_revisions "${BUILD}" trixie > "${TMP}/revs-trixie.txt"
nightly_merge_revisions "${CP}" "${CP}.new" "${REVS_BOOKWORM}" "${TMP}/revs-trixie.txt"
mv "${CP}.new" "${CP}"
assert_equals "both distros recorded" "$((2 * ${#NIGHTLY_SOURCES[@]}))" "$(wc -l < "${CP}" | tr -d ' ')"
assert_equals "nothing changed upstream -> skip" "skip=true" "$(nightly_detect_changes "${CP}" bookworm trixie 2>/dev/null)"

# Upstream podman moves on.
podman_url="$(printf '%s\n' "${NIGHTLY_SOURCES[@]}" | awk -F'|' '$1=="podman"{print $3}')"
URL_HEADS[${podman_url}]="1111111111111111111111111111111111111111"
assert_equals "new upstream commit -> build" "skip=false" "$(nightly_detect_changes "${CP}" bookworm trixie 2>/dev/null)"
URL_HEADS[${podman_url}]="${HEADS[podman]}"

unset "URL_HEADS[${podman_url}]"
assert_equals "unreadable upstream -> build" "skip=false" "$(nightly_detect_changes "${CP}" bookworm trixie 2>/dev/null)"
URL_HEADS[${podman_url}]="${HEADS[podman]}"

# Run 3: trixie fails again after a bookworm-only rebuild of podman; trixie's
# old entries must survive the merge untouched.
sed "s/^bookworm podman .*/bookworm podman 2222222222222222222222222222222222222222/" "${REVS_BOOKWORM}" > "${TMP}/revs-bookworm-2.txt"
before_trixie="$(grep '^trixie ' "${CP}")"
nightly_merge_revisions "${CP}" "${CP}.new" "${TMP}/revs-bookworm-2.txt"
assert_equals "deployed distro entry replaced" "bookworm podman 2222222222222222222222222222222222222222" "$(grep '^bookworm podman ' "${CP}.new")"
assert_equals "undeployed distro entries kept" "${before_trixie}" "$(grep '^trixie ' "${CP}.new")"

printf 'bookworm podman not-a-sha\n' > "${TMP}/bad-revs.txt"
rc=0
nightly_merge_revisions "${CP}" "${CP}.bad" "${TMP}/bad-revs.txt" 2>/dev/null || rc=$?
assert_equals "malformed revisions fail the merge" "1" "${rc}"
rc=0
nightly_merge_revisions "${TMP}/no-checkpoint" "${CP}.fresh" "${REVS_BOOKWORM}" || rc=$?
assert_equals "merge without a previous checkpoint works" "0" "${rc}"

# ============================================
echo "=== published_distros ==="
# ============================================

ART="${TMP}/artifacts"
mkdir -p "${ART}/debs-bookworm" "${ART}/debs-trixie" "${ART}/nightly-revs-bookworm"
touch "${ART}/debs-bookworm/a.deb" "${ART}/debs-trixie/a.deb"
cp "${REVS_BOOKWORM}" "${ART}/nightly-revs-bookworm/revisions.txt"

printf 'bookworm success\ntrixie success\n' > "${TMP}/cells-ok"
assert_equals "both cells succeeded" "bookworm trixie" "$(published_distros "${TMP}/cells-ok" "${ART}" false bookworm trixie 2>/dev/null | xargs)"

printf 'bookworm success\ntrixie failure\n' > "${TMP}/cells-trixie-failed"
assert_equals "failed cell is not published" "bookworm" \
    "$(published_distros "${TMP}/cells-trixie-failed" "${ART}" false bookworm trixie 2>/dev/null | xargs)"
assert_equals "nightly: failed cell's revisions are not required" "bookworm" \
    "$(published_distros "${TMP}/cells-trixie-failed" "${ART}" true bookworm trixie 2>/dev/null | xargs)"

rc=0
published_distros "${TMP}/cells-ok" "${ART}" true bookworm trixie > /dev/null 2>&1 || rc=$?
assert_equals "nightly: successful cell without revisions fails" "1" "${rc}"

rm -f "${ART}/debs-trixie/a.deb"
rc=0
published_distros "${TMP}/cells-ok" "${ART}" false bookworm trixie > /dev/null 2>&1 || rc=$?
assert_equals "successful cell whose debs did not download fails" "1" "${rc}"

printf 'bookworm failure\ntrixie cancelled\n' > "${TMP}/cells-none"
assert_equals "no successful cell -> nothing selected" "" \
    "$(published_distros "${TMP}/cells-none" "${ART}" false bookworm trixie 2>/dev/null | xargs)"

printf 'bookworm success\n' > "${TMP}/cells-missing"
rc=0
published_distros "${TMP}/cells-missing" "${ART}" false bookworm trixie > /dev/null 2>&1 || rc=$?
assert_equals "a distro with no conclusion line at all fails" "1" "${rc}"

# ============================================
echo "=== wait_for_propagation ==="
# ============================================

LIVE="${TMP}/live"
OUT="${TMP}/out"
mkdir -p "${LIVE}/dists/nightly-bookworm" "${OUT}/dists/nightly-bookworm"
printf 'signed v2\n' > "${OUT}/dists/nightly-bookworm/InRelease"
printf 'signed v1\n' > "${LIVE}/dists/nightly-bookworm/InRelease"
rc=0
PROPAGATION_ATTEMPTS=2 PROPAGATION_DELAY=0 wait_for_propagation "file://${LIVE}" "${OUT}" nightly-bookworm 2>/dev/null || rc=$?
assert_equals "stale live InRelease -> 1" "1" "${rc}"
cp "${OUT}/dists/nightly-bookworm/InRelease" "${LIVE}/dists/nightly-bookworm/InRelease"
rc=0
PROPAGATION_ATTEMPTS=2 PROPAGATION_DELAY=0 wait_for_propagation "file://${LIVE}" "${OUT}" nightly-bookworm 2>/dev/null || rc=$?
assert_equals "live InRelease matches -> 0" "0" "${rc}"

# ============================================
echo "=== resolve_track_versions (stub resolver) ==="
# ============================================

POLICY_DIR="${TMP}/policy"
mkdir -p "${POLICY_DIR}"
: > "${POLICY_DIR}/versions-stable.env"
: > "${POLICY_DIR}/versions-v5.env"
STUB="${TMP}/stub-resolver.sh"
cat > "${STUB}" <<'EOF'
#!/bin/bash
# Stub resolver: STUB_RC picks the exit code, STUB_OUT the printed exports.
[[ -n "${STUB_OUT:-}" ]] && cat "${STUB_OUT}"
echo "policy=$1" >> "${STUB_LOG}"
exit "${STUB_RC:-0}"
EOF
chmod +x "${STUB}"
export STUB_LOG="${TMP}/stub.log"

# rtv <track> -> "<printed>|<rc>"
rtv() {
    local out rc=0
    out="$(RESOLVER="${STUB}" resolve_track_versions "$1" "${POLICY_DIR}" "${TMP}/rtv.env" 2>/dev/null)" || rc=$?
    echo "${out}|${rc}"
}

assert_equals "rc 0 with valid output -> hold=false" "hold=false|0" "$(STUB_RC=0 STUB_OUT="${GOOD_ENV}" rtv stable)"
assert_equals "rc 0 output written to the out file" "yes" "$(cmp -s "${GOOD_ENV}" "${TMP}/rtv.env" && echo yes || echo no)"
assert_equals "the track's policy file is passed" "policy=${POLICY_DIR}/versions-stable.env" "$(tail -n 1 "${STUB_LOG}")"
assert_equals "rc 3 (deterministic hold) -> hold=true, success" "hold=true|0" "$(STUB_RC=3 rtv v5)"
assert_equals "rc 3 leaves no environment behind" "no" "$([[ -s "${TMP}/rtv.env" ]] && echo yes || echo no)"
assert_equals "rc 1 (uncertain) -> error" "|1" "$(STUB_RC=1 rtv stable)"
assert_equals "rc 2 -> error" "|1" "$(STUB_RC=2 rtv v5)"
assert_equals "rc 0 with invalid output -> error" "|1" "$(STUB_RC=0 STUB_OUT="${TMP}/inject.env" rtv stable)"
assert_equals "rc 0 with empty output -> error" "|1" "$(STUB_RC=0 rtv stable)"
assert_equals "nightly is not a resolved track" "|1" "$(rtv nightly)"
rc=0
STUB_OUT="${GOOD_ENV}" RESOLVER="${STUB}" resolve_track_versions stable "${POLICY_DIR}/versions-stable.env" "${TMP}/rtv.env" >/dev/null 2>&1 || rc=$?
assert_equals "a policy file path works as well as a directory" "0" "${rc}"

# ============================================
echo "=== probe_live_suite ==="
# ============================================

# probe <url> <suite> -> "<printed>|<rc>"
probe() {
    local out rc=0
    out="$(probe_live_suite "$1" "$2" 2>/dev/null)" || rc=$?
    echo "${out}|${rc}"
}

PLIVE="${TMP}/probe-live"
mkdir -p "${PLIVE}/dists/stable-trixie" "${PLIVE}/dists/v5-trixie"
printf 'signed\n' > "${PLIVE}/dists/stable-trixie/InRelease"
printf 'signed\n' > "${PLIVE}/dists/v5-trixie/InRelease"
assert_equals "file:// published -> run" "run|0" "$(probe "file://${PLIVE}" stable-trixie)"
assert_equals "file:// absent -> skip" "skip|0" "$(probe "file://${PLIVE}" nightly-trixie)"

start_mock_http "${PLIVE}" "${TMP}/probe.log" --rule '/dists/v5-trixie/InRelease$=503'
assert_equals "HTTP 200 -> run" "run|0" "$(probe "${MOCK_URL}" stable-trixie)"
assert_equals "HTTP 404 -> skip" "skip|0" "$(probe "${MOCK_URL}" nightly-trixie)"
assert_equals "persistent 503 -> error, not skip" "|1" "$(probe "${MOCK_URL}" v5-trixie)"
assert_equals "the 503 was retried FETCH_ATTEMPTS times" "3" "$(mock_hits "${TMP}/probe.log" '/dists/v5-trixie/InRelease$')"
stop_mock_http

# ============================================
echo "=== check_upgraded_versions (stub dpkg-query) ==="
# ============================================

# A dpkg-query on PATH that answers from STUB_DPKG_DB ("<package>|<status version>").
DPKG_STUB_DIR="${TMP}/dpkg-stub"
mkdir -p "${DPKG_STUB_DIR}"
cat > "${DPKG_STUB_DIR}/dpkg-query" <<'EOF'
#!/bin/bash
pkg="${!#}"
line="$(grep -F "${pkg}|" "${STUB_DPKG_DB}" | head -n 1)"
if [[ -z "${line}" ]]; then
    echo "dpkg-query: no packages found matching ${pkg}" >&2
    exit 1
fi
printf '%s' "${line#*|}"
EOF
chmod +x "${DPKG_STUB_DIR}/dpkg-query"
export STUB_DPKG_DB="${TMP}/dpkg.db"

EXPECTED="${TMP}/expected"
cat > "${EXPECTED}" <<'EOF'
podman-podman 6.0.1~deb13.podman1
podman-suite 6.0.1~deb13.podman1
podman-crun 1.28~deb13.podman1
podman-toolbx 0.3~deb13.podman1
EOF

# cuv -> return code of check_upgraded_versions against STUB_DPKG_DB
cuv() {
    local rc=0
    PATH="${DPKG_STUB_DIR}:${PATH}" check_upgraded_versions "${EXPECTED}" >/dev/null 2>&1 || rc=$?
    echo "${rc}"
}

# podman-toolbx is in the index but not installed: ignored throughout.
cat > "${STUB_DPKG_DB}" <<'EOF'
podman-podman|install ok installed 6.0.1~deb13.podman1
podman-suite|install ok installed 6.0.1~deb13.podman1
podman-crun|install ok installed 1.28~deb13.podman1
EOF
assert_equals "all installed at the assembled version (uninstalled ones ignored) -> pass" "0" "$(cuv)"

sed -i.bak 's/^podman-crun|.*/podman-crun|install ok installed 1.27~deb13.podman1/' "${STUB_DPKG_DB}"
assert_equals "one package at an older version -> fail" "1" "$(cuv)"

sed -i.bak 's/^podman-crun|.*/podman-crun|install ok unpacked 1.28~deb13.podman1/' "${STUB_DPKG_DB}"
assert_equals "one package half-installed (unpacked) -> fail" "1" "$(cuv)"

sed -i.bak 's/^podman-crun|.*/podman-crun|install ok installed 1.28~deb13.podman1/; /^podman-suite|/d' "${STUB_DPKG_DB}"
assert_equals "podman-suite not installed -> fail" "1" "$(cuv)"

printf 'podman-suite|unknown ok not-installed \n' >> "${STUB_DPKG_DB}"
assert_equals "podman-suite known but not-installed -> fail" "1" "$(cuv)"
rm -f "${STUB_DPKG_DB}.bak"

# ============================================
echo "=== compiler_cache_report (stub sccache/ccache) ==="
# ============================================

CC_STUBS="${TMP}/cc-stubs"
NO_TOOLS="${TMP}/no-tools"
mkdir -p "${CC_STUBS}" "${NO_TOOLS}"
cat > "${CC_STUBS}/sccache" <<'EOF'
#!/bin/bash
case "$1" in
    --show-stats) printf 'Compile requests %s\nCache hits %s\nCache misses %s\n' "${S_REQ}" "${S_HIT}" "${S_MISS}" ;;
    --stop-server) ;;
esac
EOF
cat > "${CC_STUBS}/ccache" <<'EOF'
#!/bin/bash
case "$1" in
    --show-stats) echo "stub ccache stats" ;;
    --print-stats) printf 'direct_cache_hit\t%s\npreprocessed_cache_hit\t0\ncache_miss\t%s\n' "${C_HIT}" "${C_MISS}" ;;
esac
EOF
chmod +x "${CC_STUBS}/sccache" "${CC_STUBS}/ccache"
BASE_PATH="/usr/bin:/bin"
GH_OUT="${TMP}/gh-output"

# ccr <path> -> "<rc> <changed=...>"
ccr() {
    local rc=0
    : > "${GH_OUT}"
    PATH="$1" GITHUB_OUTPUT="${GH_OUT}" SCCACHE_ENABLED=true CCACHE_ENABLED=true \
        compiler_cache_report >/dev/null 2>&1 || rc=$?
    echo "${rc} $(cat "${GH_OUT}")"
}

export S_REQ=10 S_HIT=4 S_MISS=6 C_HIT=3 C_MISS=2
assert_equals "requests and misses -> pass, changed=true" "0 changed=true" "$(ccr "${CC_STUBS}:${BASE_PATH}")"
export S_REQ=10 S_HIT=10 S_MISS=0 C_HIT=5 C_MISS=0
assert_equals "all hits -> pass, changed=false" "0 changed=false" "$(ccr "${CC_STUBS}:${BASE_PATH}")"
export S_REQ=0 S_HIT=0 S_MISS=0 C_HIT=5 C_MISS=0
assert_equals "sccache saw no requests -> fail" "1 changed=false" "$(ccr "${CC_STUBS}:${BASE_PATH}")"
export S_REQ=10 S_HIT=10 S_MISS=0 C_HIT=0 C_MISS=0
assert_equals "ccache saw no compilations -> fail" "1 changed=false" "$(ccr "${CC_STUBS}:${BASE_PATH}")"
assert_equals "enabled tools missing -> fail" "1 changed=false" "$(ccr "${NO_TOOLS}:${BASE_PATH}")"
rc=0
PATH="${NO_TOOLS}:${BASE_PATH}" SCCACHE_ENABLED=false CCACHE_ENABLED=false GITHUB_OUTPUT="" \
    compiler_cache_report >/dev/null 2>&1 || rc=$?
assert_equals "disabled caches need no tools" "0" "${rc}"

# ============================================
echo "=== enable_rust_compiler_cache / enable_c_compiler_cache ==="
# ============================================

# ecc <function> <path> <strict> -> "<rc> <exported value or ->"
ecc() {
    (
        unset RUSTC_WRAPPER CC
        export SKIP_CONFIG_SOURCE=1 SCCACHE_ENABLED=true CCACHE_ENABLED=true CACHE_STRICT="$3"
        # shellcheck source=functions.sh
        source "${PROJECT_ROOT}/functions.sh"
        rc=0
        PATH="$2" "$1" >/dev/null 2>&1 || rc=$?
        if [[ "$1" == enable_rust_compiler_cache ]]; then
            echo "${rc} ${RUSTC_WRAPPER:--}"
        else
            echo "${rc} ${CC:--}"
        fi
    )
}

assert_equals "sccache missing, CACHE_STRICT=true -> 1" "1 -" "$(ecc enable_rust_compiler_cache "${NO_TOOLS}:${BASE_PATH}" true)"
assert_equals "sccache missing, CACHE_STRICT=false -> 0, nothing exported" "0 -" "$(ecc enable_rust_compiler_cache "${NO_TOOLS}:${BASE_PATH}" false)"
assert_equals "sccache present -> RUSTC_WRAPPER=sccache" "0 sccache" "$(ecc enable_rust_compiler_cache "${CC_STUBS}:${BASE_PATH}" true)"
assert_equals "ccache missing, CACHE_STRICT=true -> 1" "1 -" "$(ecc enable_c_compiler_cache "${NO_TOOLS}:${BASE_PATH}" true)"
assert_equals "ccache missing, CACHE_STRICT=false -> 0, nothing exported" "0 -" "$(ecc enable_c_compiler_cache "${NO_TOOLS}:${BASE_PATH}" false)"
assert_equals "ccache present -> CC=\"ccache gcc\"" "0 ccache gcc" "$(ecc enable_c_compiler_cache "${CC_STUBS}:${BASE_PATH}" true)"

# ============================================
echo "=== compiler cache statistics parsers ==="
# ============================================

SCCACHE_SAMPLE='Compile requests                     42
Compile requests executed            40
Cache hits                           31
Cache hits (Rust)                    31
Cache misses                          9
Cache hits rate                   77.50 %'
assert_equals "sccache compile requests" "42" "$(sccache_stat "${SCCACHE_SAMPLE}" "Compile requests")"
assert_equals "sccache cache hits" "31" "$(sccache_stat "${SCCACHE_SAMPLE}" "Cache hits")"
assert_equals "sccache cache misses" "9" "$(sccache_stat "${SCCACHE_SAMPLE}" "Cache misses")"
assert_equals "sccache missing label -> 0" "0" "$(sccache_stat "${SCCACHE_SAMPLE}" "Non-cacheable calls")"
CCACHE_SAMPLE="$(printf 'stats_updated_timestamp\t1700000000\ndirect_cache_hit\t12\npreprocessed_cache_hit\t3\ncache_miss\t5\n')"
assert_equals "ccache direct hits" "12" "$(ccache_stat "${CCACHE_SAMPLE}" direct_cache_hit)"
assert_equals "ccache misses" "5" "$(ccache_stat "${CCACHE_SAMPLE}" cache_miss)"
assert_equals "ccache missing key -> 0" "0" "$(ccache_stat "${CCACHE_SAMPLE}" no_such_key)"

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"
[[ ${FAIL_COUNT} -eq 0 ]]
