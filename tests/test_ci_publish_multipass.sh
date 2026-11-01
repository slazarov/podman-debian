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
#      stable-bookworm.
#
# Needs reprepro, gpg and dpkg-deb. Where they are missing it prints SKIP and
# exits 0, like tests/test_repo_assemble_byhash.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

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
   || ! command -v dpkg-deb &>/dev/null \
   || ! command -v sha256sum &>/dev/null \
   || ! command -v sha512sum &>/dev/null \
   || ! command -v python3 &>/dev/null \
   || ! command -v curl &>/dev/null; then
    echo "  SKIP: reprepro/gpg/dpkg-deb/sha256sum/sha512sum/python3/curl not all available."
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

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"
[[ ${FAIL_COUNT} -eq 0 ]]
