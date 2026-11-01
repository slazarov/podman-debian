#!/bin/bash

# Unit test for scripts/verify_repo_integrity.sh — the publish integrity gate.
#
# Builds a minimal hand-assembled repository (no reprepro/gpg needed) with a
# correct signed-style Release + Packages + pool .deb, asserts the guard PASSES,
# then injects each failure mode the guard exists to catch and asserts it FAILS:
#   - index <-> pool  : the pool .deb bytes no longer match the index Size/SHA256
#                       (the "File has unexpected size" shared-pool overwrite bug);
#   - index <-> pool  : the index references a Filename missing from pool/;
#   - Release <-> index: Packages tampered after Release was written.
#
# Pure bash + awk + sha256sum/shasum + gzip; runs anywhere those exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
GUARD="${PROJECT_ROOT}/scripts/verify_repo_integrity.sh"

PASS_COUNT=0
FAIL_COUNT=0

# assert_exit <description> <expected-code> <cmd...>
assert_exit() {
    local description="$1" expected="$2"; shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" == "${expected}" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected exit ${expected}, got ${rc}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "  SKIP: neither sha256sum nor shasum available."
    echo "Results: 0 passed, 0 failed (SKIPPED on this host)"
    exit 0
fi

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
_fsize() { wc -c < "$1" | tr -d '[:space:]'; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

SUITE="stable-bookworm"
FILENAME="pool/main/p/podman-skopeo/podman-skopeo_1.23.0~deb12.podman1_amd64.deb"

# build_repo <root> — assemble a self-consistent one-package, one-suite repo.
build_repo() {
    local root="$1"
    local pool="${root}/${FILENAME}"
    local dist="${root}/dists/${SUITE}"
    local pkgs="${dist}/main/binary-amd64/Packages"
    mkdir -p "$(dirname "${pool}")" "$(dirname "${pkgs}")"

    # A deterministic "deb" (content is irrelevant to the guard; only bytes matter).
    printf 'fake skopeo deb payload — canonical published bytes\n' > "${pool}"
    local psize phash
    psize="$(_fsize "${pool}")"
    phash="$(_sha256 "${pool}")"

    cat > "${pkgs}" <<EOF
Package: podman-skopeo
Version: 1.23.0~deb12.podman1
Architecture: amd64
Filename: ${FILENAME}
Size: ${psize}
SHA256: ${phash}
Description: fixture
EOF
    gzip -kf "${pkgs}"   # Packages.gz (byte-identical decompression)

    # Release listing SHA256 of the two indexes it covers.
    local isize ihash gsize ghash
    isize="$(_fsize "${pkgs}")"; ihash="$(_sha256 "${pkgs}")"
    gsize="$(_fsize "${pkgs}.gz")"; ghash="$(_sha256 "${pkgs}.gz")"
    cat > "${dist}/Release" <<EOF
Origin: podman-debian
Suite: ${SUITE}
Acquire-By-Hash: yes
Components: main
Architectures: amd64
SHA256:
 ${ihash} ${isize} main/binary-amd64/Packages
 ${ghash} ${gsize} main/binary-amd64/Packages.gz
EOF
}

echo "Test 1: a self-consistent repository passes the guard"
GOOD="${TMP}/good"
build_repo "${GOOD}"
assert_exit "consistent repo exits 0" 0 bash "${GUARD}" "${GOOD}"

echo ""
echo "Test 2: pool .deb mutated (size/hash) after signing — the 'unexpected size' bug"
BAD1="${TMP}/bad-pool-bytes"
build_repo "${BAD1}"
# Overwrite the pool .deb with byte-different content of the SAME version (exactly
# what a non-reproducible rebuild in another track's publish did to the shared pool).
printf 'fake skopeo deb payload — a DIFFERENT non-reproducible rebuild!!\n' > "${BAD1}/${FILENAME}"
assert_exit "index<->pool size/sha mismatch exits 1" 1 bash "${GUARD}" "${BAD1}"

echo ""
echo "Test 3: index references a pool file that is missing"
BAD2="${TMP}/bad-missing-pool"
build_repo "${BAD2}"
rm -f "${BAD2}/${FILENAME}"
assert_exit "missing pool entry exits 1" 1 bash "${GUARD}" "${BAD2}"

echo ""
echo "Test 4: Packages tampered after Release was signed (Release<->index)"
BAD3="${TMP}/bad-stale-release"
build_repo "${BAD3}"
# Append to Packages WITHOUT updating Release's SHA256 — Release now lies.
echo "# tampered after signing" >> "${BAD3}/dists/${SUITE}/main/binary-amd64/Packages"
assert_exit "stale Release vs index exits 1" 1 bash "${GUARD}" "${BAD3}"

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"
[[ ${FAIL_COUNT} -eq 0 ]]
