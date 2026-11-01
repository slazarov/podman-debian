#!/bin/bash

# Regression test: multi-distro publish must NOT clobber an earlier pass.
#
# The publish job runs ci_publish.sh once per distro into ONE accumulating
# output dir (bookworm, then trixie). The failure mode: the trixie pass lists
# stable-bookworm (freshly built to the NEW version by the bookworm pass) as
# an "other suite" and re-mirrors it VERBATIM from the live repo (the OLD
# version), overwriting the fresh indices. Net effect: the first-published
# distro reverts to the previously-published version.
#
# This harness reproduces the two-pass flow end to end:
#   1. Build a "live" repo at an OLD version and serve it over HTTP.
#   2. Run the real ci_publish.sh twice (stable bookworm, then stable trixie)
#      at a NEW version, into one output dir, with REPO_URL pointing at the mock.
#   3. Assert every stable suite ends at the NEW version, in particular
#      stable-bookworm, that every regenerated suite keeps the previous
#      by-hash generation of its indexes, and that the result verifies
#      against the signing key.
#
# Then the failure paths, each against the same live repo:
#   4. A pool .deb that the live server keeps answering with HTTP 503, cuts
#      off mid-transfer, or answers with 404 although the index lists it,
#      stops ci_publish.sh (no suite is published). So does a persistent 503
#      on the live target suite's Packages or Release. One 503 followed by
#      success is retried and the publish goes through.
#   5. A failing `gpg --clearsign` or detached sign stops ci_publish.sh.
#
# Needs reprepro, gpg and dpkg-deb. Where they are missing it prints SKIP and
# exits 0, like tests/test_repo_assemble_byhash.sh (a failure under
# REQUIRE_INTEGRATION_DEPS=1).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=tests/lib/mock_http.sh
source "${SCRIPT_DIR}/lib/mock_http.sh"

# ============================================
# Test framework
# ============================================

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

# ============================================
# Platform skip (hosts without reprepro/dpkg-deb)
# ============================================

if ! command -v reprepro &>/dev/null \
   || ! command -v gpg &>/dev/null \
   || ! command -v gpgv &>/dev/null \
   || ! command -v dpkg-deb &>/dev/null \
   || ! command -v sha256sum &>/dev/null \
   || ! command -v sha512sum &>/dev/null \
   || ! command -v python3 &>/dev/null \
   || ! command -v curl &>/dev/null; then
    echo "  SKIP: reprepro/gpg/gpgv/dpkg-deb/sha256sum/sha512sum/python3/curl not all available."
    require_integration_deps "reprepro/gpg/gpgv/dpkg-deb/sha256sum/sha512sum/python3/curl"
    echo "        This integration harness needs a Debian-based host with:"
    echo "          sudo apt-get update && sudo apt-get install -y reprepro"
    echo ""
    echo "========================================"
    echo "Results: 0 passed, 0 failed (SKIPPED on this host)"
    echo "========================================"
    exit 0
fi

# ============================================
# Isolated fixture: throwaway GNUPGHOME + temp dirs + mock HTTP server
# ============================================

TMP_ROOT="$(mktemp -d)"
export GNUPGHOME="${TMP_ROOT}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
HTTP_PID=""
cleanup() {
    [[ -n "${HTTP_PID}" ]] && kill "${HTTP_PID}" >/dev/null 2>&1 || true
    stop_mock_http
    gpgconf --homedir "${GNUPGHOME}" --kill all >/dev/null 2>&1 || true
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

echo ">>> Generating throwaway GPG signing key in isolated GNUPGHOME..."
cat > "${TMP_ROOT}/keygen" <<'EOF_KEYGEN'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: ecdh
Subkey-Curve: cv25519
Name-Real: Podman Repo Test Key
Name-Email: repo-test@example.invalid
Expire-Date: 0
%commit
EOF_KEYGEN
if ! gpg --batch --gen-key "${TMP_ROOT}/keygen" >/dev/null 2>&1; then
    cat > "${TMP_ROOT}/keygen" <<'EOF_KEYGEN_RSA'
%no-protection
Key-Type: RSA
Key-Length: 3072
Name-Real: Podman Repo Test Key
Name-Email: repo-test@example.invalid
Expire-Date: 0
%commit
EOF_KEYGEN_RSA
    gpg --batch --gen-key "${TMP_ROOT}/keygen" >/dev/null 2>&1
fi
TEST_KEY_FPR="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
echo "${TEST_KEY_FPR}:6:" | gpg --batch --import-ownertrust >/dev/null 2>&1
echo "  key: ${TEST_KEY_FPR}"
# ci_publish.sh checks every signature against REPO_KEYRING; here that is
# the throwaway key, not the project's published one.
export REPO_KEYRING="${TMP_ROOT}/test-key.gpg"
gpg --batch --export "${TEST_KEY_FPR}" > "${REPO_KEYRING}"
export FETCH_RETRY_DELAY=0 FETCH_ATTEMPTS=3
echo ""

# build_fixture_deb <pkg> <version> <arch> <out-dir>
build_fixture_deb() {
    local lpkg="$1" lver="$2" larch="$3" lout="$4"
    local lstage="${TMP_ROOT}/stage-${lpkg}-${lver}-${larch}"
    rm -rf "${lstage}"
    mkdir -p "${lstage}/DEBIAN" "${lstage}/usr/share/doc/${lpkg}"
    cat > "${lstage}/DEBIAN/control" <<EOF_CTL
Package: ${lpkg}
Version: ${lver}
Architecture: ${larch}
Maintainer: Repo Test <repo-test@example.invalid>
Section: admin
Priority: optional
Description: Fixture ${lpkg} for the multi-pass publish harness
 Not a real package; exercises ci_publish.sh's two-pass accumulation.
EOF_CTL
    echo "fixture ${lpkg} ${lver}" > "${lstage}/usr/share/doc/${lpkg}/README"
    mkdir -p "${lout}"
    dpkg-deb --build --root-owner-group "${lstage}" \
        "${lout}/${lpkg}_${lver}_${larch}.deb" >/dev/null
}

# pkg_version <packages-file> <package> -> Version field of first matching stanza
pkg_version() {
    awk -v p="$2" '/^Package:/{cur=$2} /^Version:/{if(cur==p){print $2;exit}}' "$1"
}

# The publish runner is not Debian and has no DISTRO set. Reproduce that:
# every repo_manage.sh / ci_publish.sh call runs with DISTRO unset and an
# Ubuntu os-release, so it only works if the script takes DISTRO from its
# distro argument.
FOREIGN_OS_RELEASE="${TMP_ROOT}/os-release-runner"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "${FOREIGN_OS_RELEASE}"
on_runner() { env -u DISTRO OS_RELEASE_FILE="${FOREIGN_OS_RELEASE}" "$@"; }

PKG="podman-podman"
OLD_BOOKWORM="5.8.0~deb12.podman1"
OLD_TRIXIE="5.8.0~deb13.podman1"
NEW_BOOKWORM="5.8.2~deb12.podman1"
NEW_TRIXIE="5.8.2~deb13.podman1"

# ============================================
# Step 1: Build the "live" repo at the OLD version, serve it over HTTP
# ============================================

echo ">>> Building mock live repo at OLD version (${OLD_BOOKWORM} / ${OLD_TRIXIE})..."
LIVE="${TMP_ROOT}/live"
mkdir -p "${LIVE}"
LIVE_DEBS_BOOKWORM="${TMP_ROOT}/live-debs-bookworm"
LIVE_DEBS_TRIXIE="${TMP_ROOT}/live-debs-trixie"
build_fixture_deb "${PKG}" "${OLD_BOOKWORM}" amd64 "${LIVE_DEBS_BOOKWORM}"
build_fixture_deb "${PKG}" "${OLD_TRIXIE}" amd64 "${LIVE_DEBS_TRIXIE}"

# Assemble live stable-bookworm, then stable-trixie (same path the real
# pipeline uses), and apply by-hash + signatures so mirror_suite_verbatim can
# serve them verbatim.
on_runner "${PROJECT_ROOT}/scripts/repo_manage.sh" stable bookworm "${LIVE_DEBS_BOOKWORM}" "${LIVE}" >/dev/null
on_runner "${PROJECT_ROOT}/scripts/repo_manage.sh" stable trixie "${LIVE_DEBS_TRIXIE}" "${LIVE}" >/dev/null
# Sourcing repo_byhash.sh loads config.sh into this shell, which needs a
# supported distro. Set it only for the source.
# shellcheck source=/dev/null
DISTRO=bookworm source "${PROJECT_ROOT}/scripts/repo_byhash.sh"
unset DISTRO
for s in stable-bookworm stable-trixie; do
    [[ -f "${LIVE}/dists/${s}/Release" ]] && add_byhash_and_resign "${s}" "${LIVE}" >/dev/null
done

# Sanity: the live repo really is at the OLD version before we publish over it.
live_bookworm="$(pkg_version "${LIVE}/dists/stable-bookworm/main/binary-amd64/Packages" "${PKG}")"
assert_equals "live repo seeded at OLD stable-bookworm" "${OLD_BOOKWORM}" "${live_bookworm}"

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${LIVE}" >/dev/null 2>&1 &
HTTP_PID=$!
REPO_URL="http://127.0.0.1:${PORT}"
# Wait until the server answers.
for _ in $(seq 1 50); do
    curl -sf "${REPO_URL}/dists/stable-bookworm/Release" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -sf "${REPO_URL}/dists/stable-bookworm/Release" >/dev/null 2>&1; then
    echo "  FAIL: mock HTTP server never came up at ${REPO_URL}"
    echo "Results: ${PASS_COUNT} passed, $((FAIL_COUNT + 1)) failed"
    exit 1
fi
echo "  serving live repo at ${REPO_URL}"
echo ""

# ============================================
# Step 2: Publish the NEW version via two sequential passes into ONE output dir
# ============================================

echo ">>> Publishing NEW version (${NEW_BOOKWORM} / ${NEW_TRIXIE}): bookworm then trixie..."
NEW_DEBS_BOOKWORM="${TMP_ROOT}/new-debs-bookworm"
NEW_DEBS_TRIXIE="${TMP_ROOT}/new-debs-trixie"
build_fixture_deb "${PKG}" "${NEW_BOOKWORM}" amd64 "${NEW_DEBS_BOOKWORM}"
build_fixture_deb "${PKG}" "${NEW_TRIXIE}" amd64 "${NEW_DEBS_TRIXIE}"

OUT="${TMP_ROOT}/out"
mkdir -p "${OUT}"

run_pass() {
    local distro="$1" debdir="$2" log="$3"
    if ! on_runner bash "${PROJECT_ROOT}/scripts/ci_publish.sh" stable "${distro}" "${debdir}" "${REPO_URL}" "${OUT}" >"${log}" 2>&1; then
        echo "  FAIL: ci_publish.sh stable ${distro} exited non-zero. Tail:"
        tail -20 "${log}" | sed 's/^/      /'
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

run_pass bookworm "${NEW_DEBS_BOOKWORM}" "${TMP_ROOT}/pass1.log" || true
run_pass trixie "${NEW_DEBS_TRIXIE}" "${TMP_ROOT}/pass2.log" || true
echo ""

# ============================================
# Step 3: Assert no clobber: every stable suite ends at the NEW version
# ============================================

echo ">>> Verifying final repository (no clobber of the first pass)..."
got_bookworm="$(pkg_version "${OUT}/dists/stable-bookworm/main/binary-amd64/Packages" "${PKG}" 2>/dev/null || true)"
got_trixie="$(pkg_version "${OUT}/dists/stable-trixie/main/binary-amd64/Packages" "${PKG}" 2>/dev/null || true)"

# The regression assertion: the bookworm pass (published FIRST) must survive
# the trixie pass's mirror-down.
assert_equals "stable-bookworm kept fresh (not clobbered by trixie pass)" "${NEW_BOOKWORM}" "${got_bookworm}"
# Control: the last pass's own suite is fresh too.
assert_equals "stable-trixie published fresh"                             "${NEW_TRIXIE}" "${got_trixie}"
# No bare alias suites are created.
for bare in stable v5 nightly; do
    assert_equals "no bare '${bare}' suite" "absent" "$([[ -e "${OUT}/dists/${bare}" ]] && echo present || echo absent)"
done

# Previous by-hash generation: a client holding the OLD Release asks for the
# OLD Packages by hash. Both regenerated suites must still serve it.
for s in stable-bookworm stable-trixie; do
    old_hash="$(awk '$0=="SHA256:"{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f && $3=="main/binary-amd64/Packages"{print $1}' "${LIVE}/dists/${s}/Release")"
    new_hash="$(awk '$0=="SHA256:"{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f && $3=="main/binary-amd64/Packages"{print $1}' "${OUT}/dists/${s}/Release")"
    assert_equals "${s}: old and new Packages differ (fixture sanity)" "yes" "$([[ "${old_hash}" != "${new_hash}" ]] && echo yes || echo no)"
    assert_equals "${s}: previous Packages kept under by-hash" "yes" \
        "$(cmp -s "${LIVE}/dists/${s}/main/binary-amd64/Packages" "${OUT}/dists/${s}/main/binary-amd64/by-hash/SHA256/${old_hash}" && echo yes || echo no)"
    assert_equals "${s}: new Packages under by-hash" "yes" \
        "$([[ -f "${OUT}/dists/${s}/main/binary-amd64/by-hash/SHA256/${new_hash}" ]] && echo yes || echo no)"
    old_rel="$(sha256sum "${LIVE}/dists/${s}/Release" | awk '{print $1}')"
    assert_equals "${s}: previous Release kept under by-hash" "yes" \
        "$(cmp -s "${LIVE}/dists/${s}/Release" "${OUT}/dists/${s}/by-hash/SHA256/${old_rel}" && echo yes || echo no)"
    # Only those two generations: every by-hash file is listed by the old or
    # the new Release.
    known="$(cat "${LIVE}/dists/${s}/Release" "${OUT}/dists/${s}/Release" \
        | awk '$0=="SHA256:"{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f && $3 ~ /^main\/binary-amd64\//{print $1}' | sort -u)"
    extra="$(find "${OUT}/dists/${s}/main/binary-amd64/by-hash/SHA256" -type f -exec basename {} \; | sort -u \
        | comm -23 - <(printf '%s\n' "${known}"))"
    assert_equals "${s}: by-hash holds only the previous and the new generation" "" "${extra}"
done

rc=0
bash "${PROJECT_ROOT}/scripts/verify_repo_integrity.sh" --keyring "${REPO_KEYRING}" "${OUT}" >/dev/null 2>&1 || rc=$?
assert_equals "assembled repo verifies against the signing key" "0" "${rc}"

# ============================================
# Step 4: Transient and persistent download failures
# ============================================

echo ""
echo ">>> Download failures while mirroring the live repo..."
kill "${HTTP_PID}" >/dev/null 2>&1 || true
HTTP_PID=""
OLD_DEB_PATH="$(awk '/^Filename:/{print $2; exit}' "${LIVE}/dists/stable-trixie/main/binary-amd64/Packages")"

# publish_with_rule <label> <rule> -> runs the bookworm pass (which mirrors
# the trixie suite) against a server with <rule>; prints the exit code.
publish_with_rule() {
    local label="$1" rule="$2"
    local out="${TMP_ROOT}/out-${label}"
    rm -rf "${out}"
    mkdir -p "${out}"
    start_mock_http "${LIVE}" "${TMP_ROOT}/hits-${label}.log" --rule "${rule}" || return 1
    local rc=0
    on_runner bash "${PROJECT_ROOT}/scripts/ci_publish.sh" stable bookworm "${NEW_DEBS_BOOKWORM}" "${MOCK_URL}" "${out}" \
        > "${TMP_ROOT}/${label}.log" 2>&1 || rc=$?
    stop_mock_http
    echo "${rc}"
}

rc="$(publish_with_rule deb503 "/${OLD_DEB_PATH}\$=503")"
assert_equals "pool .deb answering 503 every time stops the publish" "1" "${rc}"
assert_equals "the 503 was retried FETCH_ATTEMPTS times" "3" "$(mock_hits "${TMP_ROOT}/hits-deb503.log" "/${OLD_DEB_PATH}\$")"
assert_equals "no suite published after the 503" "absent" \
    "$([[ -e "${TMP_ROOT}/out-deb503/index.html" ]] && echo present || echo absent)"

rc="$(publish_with_rule debcut "/${OLD_DEB_PATH}\$=truncate")"
assert_equals "pool .deb cut off every time stops the publish" "1" "${rc}"

rc="$(publish_with_rule deb404 "/${OLD_DEB_PATH}\$=404")"
assert_equals "listed pool .deb answering 404 stops the publish (no silently smaller suite)" "1" "${rc}"
assert_equals "the 404 is reported" "yes" \
    "$(grep -q 'the live site does not have it (HTTP 404)' "${TMP_ROOT}/deb404.log" && echo yes || echo no)"

rc="$(publish_with_rule target-packages503 "/dists/stable-bookworm/main/binary-amd64/Packages\$=503")"
assert_equals "live target Packages answering 503 stops the publish" "yes" "$([[ "${rc}" -ne 0 ]] && echo yes || echo no)"

rc="$(publish_with_rule target-release503 "/dists/stable-bookworm/Release\$=503")"
assert_equals "live target Release answering 503 stops the publish" "yes" "$([[ "${rc}" -ne 0 ]] && echo yes || echo no)"

rc="$(publish_with_rule release503 "/dists/stable-trixie/Release\$=503")"
assert_equals "live Release answering 503 stops the publish (not treated as unpublished)" "1" "${rc}"

rc="$(publish_with_rule deb503once "/${OLD_DEB_PATH}\$=503:1")"
assert_equals "one 503 then success is retried and the publish completes" "0" "${rc}"

# ============================================
# Step 5: Signing failures
# ============================================

echo ""
echo ">>> Signing failures..."
REAL_GPG="$(command -v gpg)"
SHIM_DIR="${TMP_ROOT}/gpg-shim"
mkdir -p "${SHIM_DIR}"
cat > "${SHIM_DIR}/gpg" <<EOF_SHIM
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        --clearsign) [[ "\${FAIL_GPG_MODE:-}" == clearsign ]] && exit 2 ;;
        -abs) [[ "\${FAIL_GPG_MODE:-}" == detach ]] && exit 2 ;;
    esac
done
exec "${REAL_GPG}" "\$@"
EOF_SHIM
chmod +x "${SHIM_DIR}/gpg"
start_mock_http "${LIVE}" "${TMP_ROOT}/hits-sign.log"
for mode in clearsign detach; do
    out="${TMP_ROOT}/out-sign-${mode}"
    mkdir -p "${out}"
    rc=0
    PATH="${SHIM_DIR}:${PATH}" FAIL_GPG_MODE="${mode}" on_runner bash "${PROJECT_ROOT}/scripts/ci_publish.sh" \
        stable bookworm "${NEW_DEBS_BOOKWORM}" "${MOCK_URL}" "${out}" > "${TMP_ROOT}/sign-${mode}.log" 2>&1 || rc=$?
    assert_equals "ci_publish.sh exits non-zero when ${mode} signing fails" "yes" "$([[ "${rc}" -ne 0 ]] && echo yes || echo no)"
    assert_equals "the ${mode} failure is reported" "yes" \
        "$(grep -q 'signing failed\|gpg --clearsign failed' "${TMP_ROOT}/sign-${mode}.log" && echo yes || echo no)"
done
stop_mock_http

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"
[[ ${FAIL_COUNT} -eq 0 ]]
