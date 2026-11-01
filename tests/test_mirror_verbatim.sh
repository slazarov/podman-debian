#!/bin/bash

# Test mirror_suite_verbatim (scripts/ci_publish.sh), the verbatim mirror of
# a non-target suite, against a file:// repository whose URL carries path
# segments, mimicking the project-pages URL shape
# (https://<owner>.github.io/<repo-name>). A naive `wget -r` mirror with
# `-nH --cut-dirs=0` keeps the path segment, so the tree lands at
# <mirror>/<repo-name>/dists/... instead of <mirror>/dists/....
#
# The function is sed-extracted from ci_publish.sh and eval'd (the same
# pattern test_suite_routing.sh uses for config.sh helpers) because
# ci_publish.sh executes a full publish when run. A grep guard pins the
# extraction against drift.
#
# Pure bash + curl + awk; runs everywhere. Hash-integrity assertions
# (Test groups 4/5) require sha256sum/sha512sum and are skipped with a note
# on hosts without them; CI exercises them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

CI_PUBLISH="${PROJECT_ROOT}/scripts/ci_publish.sh"

# ============================================
# Test Framework
# ============================================

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

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

assert_file_identical() {
    local description="$1"
    local expected_file="$2"
    local actual_file="$3"
    if [[ -f "${actual_file}" ]] && cmp -s "${expected_file}" "${actual_file}"; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    ${actual_file} missing or differs from ${expected_file}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_absent() {
    local description="$1"
    local path="$2"
    if [[ ! -e "${path}" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Unexpectedly exists: ${path}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

skip() {
    echo "  SKIP: $1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

# ============================================
# Extract the function under test from ci_publish.sh
# ============================================

if ! grep -q "^mirror_suite_verbatim()" "${CI_PUBLISH}"; then
    echo "FATAL: mirror_suite_verbatim() not found at column 0 in ci_publish.sh" >&2
    exit 1
fi
eval "$(sed -n '/^mirror_suite_verbatim()/,/^}/p' "${CI_PUBLISH}")"

# ============================================
# Fixture: a live repo under a path-segmented URL
# ============================================
# file://${TMP}/www/podman-debian: the 'www/podman-debian' segments stand in
# for the '<repo-name>' path of a project-pages URL. Hashes in the Release
# manifest are real (sha256sum/sha512sum, or shasum -a N where those are
# missing).

hash_file() {
    local bits="$1" file="$2"
    if command -v "sha${bits}sum" >/dev/null 2>&1; then
        "sha${bits}sum" "${file}" | awk '{print $1}'
    else
        shasum -a "${bits}" "${file}" | awk '{print $1}'
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

SUITE="stable-bookworm"
WWW="${TMP}/www/podman-debian"
LIVE="${WWW}/dists/${SUITE}"
mkdir -p "${LIVE}/main/binary-amd64"

cat > "${LIVE}/main/binary-amd64/Packages" <<'EOF'
Package: podman-podman
Version: 5.5.0~deb12.podman1
Architecture: amd64
Filename: pool/main/p/podman-podman/podman-podman_5.5.0~deb12.podman1_amd64.deb
EOF
cat > "${LIVE}/main/binary-amd64/Release" <<EOF
Archive: ${SUITE}
Suite: ${SUITE}
Component: main
Architecture: amd64
EOF

# Build the signed Release manifest with REAL hashes of the two indexes.
manifest_lines() {
    local bits="$1" relpath h sz
    for relpath in \
        main/binary-amd64/Packages main/binary-amd64/Release; do
        h="$(hash_file "${bits}" "${LIVE}/${relpath}")"
        sz="$(wc -c < "${LIVE}/${relpath}" | tr -d ' ')"
        printf ' %s %s %s\n' "${h}" "${sz}" "${relpath}"
    done
}

{
    cat <<EOF
Origin: podman-debian
Label: Podman Debian
Suite: ${SUITE}
Codename: ${SUITE}
Acquire-By-Hash: yes
Date: Sat, 06 Jun 2026 12:00:00 UTC
Architectures: amd64
Components: main
Description: Podman built from source for Debian 12 (bookworm), Podman 6.x releases
SHA256:
EOF
    manifest_lines 256
    echo "SHA512:"
    manifest_lines 512
} > "${LIVE}/Release"

# Dummy signature bytes — the function serves them verbatim, it does not
# gpg-verify (apt clients do). Byte-identity is the property under test.
printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nfake inline signature over Release\n-----END PGP SIGNATURE-----\n' > "${LIVE}/InRelease"
printf -- '-----BEGIN PGP SIGNATURE-----\nfake detached signature\n-----END PGP SIGNATURE-----\n' > "${LIVE}/Release.gpg"

REPO_URL_TEST="file://${TMP}/www/podman-debian"

SHA256_PKG_AMD64="$(hash_file 256 "${LIVE}/main/binary-amd64/Packages")"
SHA512_PKG_AMD64="$(hash_file 512 "${LIVE}/main/binary-amd64/Packages")"

# ============================================
# Test 1: path-segmented URL lands the tree at <out>/dists/<suite>
# ============================================

echo ""
echo "Test 1: verbatim mirror against path-segmented URL"

OUT1="${TMP}/out1"
rc=0
mirror_suite_verbatim "${SUITE}" "${REPO_URL_TEST}" "${OUT1}" || rc=$?
assert_equals "returns 0 when the live tree exists" "0" "${rc}"

assert_file_identical "Release byte-identical at <out>/dists/${SUITE}/Release" \
    "${LIVE}/Release" "${OUT1}/dists/${SUITE}/Release"
assert_file_identical "InRelease (original signature) byte-identical" \
    "${LIVE}/InRelease" "${OUT1}/dists/${SUITE}/InRelease"
assert_file_identical "Release.gpg (original signature) byte-identical" \
    "${LIVE}/Release.gpg" "${OUT1}/dists/${SUITE}/Release.gpg"
assert_file_identical "amd64 Packages byte-identical" \
    "${LIVE}/main/binary-amd64/Packages" "${OUT1}/dists/${SUITE}/main/binary-amd64/Packages"
assert_file_identical "amd64 Release byte-identical" \
    "${LIVE}/main/binary-amd64/Release" "${OUT1}/dists/${SUITE}/main/binary-amd64/Release"

# A wget-style mirror would nest the tree under the URL's path segment.
assert_absent "no <out>/podman-debian/ nesting (the wget --cut-dirs=0 failure shape)" \
    "${OUT1}/podman-debian"
assert_absent "no <out>/www/ nesting" "${OUT1}/www"

echo ""
echo "Test 2: by-hash copies reconstructed adjacent to each index"

assert_file_identical "by-hash/SHA256/<hash> copy of amd64 Packages" \
    "${LIVE}/main/binary-amd64/Packages" \
    "${OUT1}/dists/${SUITE}/main/binary-amd64/by-hash/SHA256/${SHA256_PKG_AMD64}"
assert_file_identical "by-hash/SHA512/<hash> copy of amd64 Packages" \
    "${LIVE}/main/binary-amd64/Packages" \
    "${OUT1}/dists/${SUITE}/main/binary-amd64/by-hash/SHA512/${SHA512_PKG_AMD64}"

if command -v sha256sum >/dev/null 2>&1; then
    REL_SHA256="$(sha256sum "${LIVE}/Release" | awk '{print $1}')"
    assert_file_identical "by-hash/SHA256/<hash> copy of Release itself" \
        "${LIVE}/Release" "${OUT1}/dists/${SUITE}/by-hash/SHA256/${REL_SHA256}"
else
    skip "Release self by-hash check (sha256sum not available on this host)"
fi

# ============================================
# Test 3: first deploy / unpublished suite returns 1, output untouched
# ============================================

echo ""
echo "Test 3: unpublished suite (404 / first deploy)"

OUT3="${TMP}/out3"
rc=0
mirror_suite_verbatim "v5-bookworm" "${REPO_URL_TEST}" "${OUT3}" || rc=$?
assert_equals "returns 1 when the live Release does not exist" "1" "${rc}"
assert_absent "no partial tree placed in output" "${OUT3}/dists/v5-bookworm"

# ============================================
# Test 4: listed-but-missing index returns 1, output untouched
# ============================================

echo ""
echo "Test 4: listed index missing from live tree"

BROKEN1="${TMP}/broken1/podman-debian"
mkdir -p "${BROKEN1}"
cp -R "${WWW}/dists" "${BROKEN1}/dists"
rm "${BROKEN1}/dists/${SUITE}/main/binary-amd64/Release"
OUT4="${TMP}/out4"
rc=0
mirror_suite_verbatim "${SUITE}" "file://${TMP}/broken1/podman-debian" "${OUT4}" || rc=$?
assert_equals "returns 1 when a listed index 404s" "1" "${rc}"
assert_absent "no partial tree placed in output" "${OUT4}/dists/${SUITE}"

# ============================================
# Test 5: hash mismatch (stale CDN index) returns 1, output untouched
# ============================================

echo ""
echo "Test 5: live index does not match the signed Release hash"

if command -v sha256sum >/dev/null 2>&1 || command -v sha512sum >/dev/null 2>&1; then
    BROKEN2="${TMP}/broken2/podman-debian"
    mkdir -p "${BROKEN2}"
    cp -R "${WWW}/dists" "${BROKEN2}/dists"
    echo "tampered: stale CDN bytes" >> "${BROKEN2}/dists/${SUITE}/main/binary-amd64/Packages"
    OUT5="${TMP}/out5"
    rc=0
    mirror_suite_verbatim "${SUITE}" "file://${TMP}/broken2/podman-debian" "${OUT5}" || rc=$?
    assert_equals "returns 1 on signed-hash mismatch" "1" "${rc}"
    assert_absent "no mismatched tree placed in output" "${OUT5}/dists/${SUITE}"
else
    skip "hash-mismatch check (sha256sum/sha512sum not available on this host)"
fi

# ============================================
# Test 6: missing signature file returns 1
# ============================================

echo ""
echo "Test 6: live tree without InRelease cannot be served verbatim"

BROKEN3="${TMP}/broken3/podman-debian"
mkdir -p "${BROKEN3}"
cp -R "${WWW}/dists" "${BROKEN3}/dists"
rm "${BROKEN3}/dists/${SUITE}/InRelease"
OUT6="${TMP}/out6"
rc=0
mirror_suite_verbatim "${SUITE}" "file://${TMP}/broken3/podman-debian" "${OUT6}" || rc=$?
assert_equals "returns 1 when InRelease is missing" "1" "${rc}"
assert_absent "no unsigned tree placed in output" "${OUT6}/dists/${SUITE}"

# ============================================
# Summary
# ============================================

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
echo "========================================"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi
exit 0
