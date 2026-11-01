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
#   - Release shape: no Codename, no SHA256 section, an architecture's
#     Packages not listed, a Packages stanza without Size or SHA256.
#   - Signatures (--keyring, needs gpg): a valid signed repo and an empty
#     signed suite pass; an InRelease whose text differs from Release, a
#     signature from a key other than the published one, and a missing
#     Release.gpg fail.
#
# Pure bash + awk + sha256sum/shasum + gzip; the signature cases also need
# gpg and gpgv.

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
Codename: ${SUITE}
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
echo "Test 5: Release without Codename"
BAD4="${TMP}/bad-no-codename"
build_repo "${BAD4}"
sed -i.bak '/^Codename:/d' "${BAD4}/dists/${SUITE}/Release"
rm -f "${BAD4}/dists/${SUITE}/Release.bak"
assert_exit "missing Codename exits 1" 1 bash "${GUARD}" "${BAD4}"

echo ""
echo "Test 6: Release without a SHA256 section"
BAD5="${TMP}/bad-no-sha256"
build_repo "${BAD5}"
awk '/^SHA256:/{exit} {print}' "${BAD5}/dists/${SUITE}/Release" > "${BAD5}/R" && mv "${BAD5}/R" "${BAD5}/dists/${SUITE}/Release"
assert_exit "missing SHA256 section exits 1" 1 bash "${GUARD}" "${BAD5}"

echo ""
echo "Test 7: an architecture the Release declares has no Packages listed"
BAD6="${TMP}/bad-arch-unlisted"
build_repo "${BAD6}"
sed -i.bak 's/^Architectures: amd64$/Architectures: amd64 i386/' "${BAD6}/dists/${SUITE}/Release"
rm -f "${BAD6}/dists/${SUITE}/Release.bak"
assert_exit "declared architecture without Packages exits 1" 1 bash "${GUARD}" "${BAD6}"

echo ""
echo "Test 8: Packages stanza without Size/SHA256 (Release re-hashed to match)"
BAD7="${TMP}/bad-no-size"
build_repo "${BAD7}"
pkgs7="${BAD7}/dists/${SUITE}/main/binary-amd64/Packages"
sed -i.bak '/^Size:/d;/^SHA256:/d' "${pkgs7}"
rm -f "${pkgs7}.bak"
gzip -kf "${pkgs7}"
# Rewrite Release so only the stanza problem remains.
awk '/^SHA256:/{exit} {print}' "${BAD7}/dists/${SUITE}/Release" > "${BAD7}/R"
{
    cat "${BAD7}/R"
    echo "SHA256:"
    echo " $(_sha256 "${pkgs7}") $(_fsize "${pkgs7}") main/binary-amd64/Packages"
    echo " $(_sha256 "${pkgs7}.gz") $(_fsize "${pkgs7}.gz") main/binary-amd64/Packages.gz"
} > "${BAD7}/dists/${SUITE}/Release"
rm -f "${BAD7}/R"
assert_exit "stanza without Size/SHA256 exits 1" 1 bash "${GUARD}" "${BAD7}"

# ============================================
# Signatures (--keyring)
# ============================================

echo ""
if command -v gpg >/dev/null 2>&1 && command -v gpgv >/dev/null 2>&1; then
    export GNUPGHOME="${TMP}/gnupg"
    mkdir -p "${GNUPGHOME}"
    chmod 700 "${GNUPGHOME}"
    gen_key() {
        cat > "${TMP}/keygen" <<EOF_KEYGEN
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: $1
Name-Email: $2
Expire-Date: 0
%commit
EOF_KEYGEN
        gpg --batch --gen-key "${TMP}/keygen" >/dev/null 2>&1
    }
    gen_key "Published Key" published@example.invalid
    gen_key "Other Key" other@example.invalid
    gpg --batch --export published@example.invalid > "${TMP}/published.gpg"
    gpg --batch --armor --export published@example.invalid > "${TMP}/published.asc"

    # sign_suite <dist-dir> <signer> -> InRelease + Release.gpg
    sign_suite() {
        gpg --batch --yes -u "$2" --clearsign -o "$1/InRelease" "$1/Release"
        gpg --batch --yes -u "$2" -abs -o "$1/Release.gpg" "$1/Release"
    }

    echo "Test 9: signed by the published key"
    SIG="${TMP}/signed"
    build_repo "${SIG}"
    sign_suite "${SIG}/dists/${SUITE}" published@example.invalid
    assert_exit "valid signatures pass (binary keyring)" 0 bash "${GUARD}" --keyring "${TMP}/published.gpg" "${SIG}"
    assert_exit "valid signatures pass (armored keyring)" 0 bash "${GUARD}" --keyring "${TMP}/published.asc" "${SIG}"
    assert_exit "missing keyring file exits 2" 2 bash "${GUARD}" --keyring "${TMP}/nope.gpg" "${SIG}"

    echo ""
    echo "Test 10: empty signed suite"
    EMPTY="${TMP}/empty"
    EDIST="${EMPTY}/dists/${SUITE}"
    mkdir -p "${EDIST}/main/binary-amd64"
    : > "${EDIST}/main/binary-amd64/Packages"
    gzip -kf "${EDIST}/main/binary-amd64/Packages"
    cat > "${EDIST}/Release" <<EOF
Origin: podman-debian
Suite: ${SUITE}
Codename: ${SUITE}
Components: main
Architectures: amd64
SHA256:
 $(_sha256 "${EDIST}/main/binary-amd64/Packages") 0 main/binary-amd64/Packages
 $(_sha256 "${EDIST}/main/binary-amd64/Packages.gz") $(_fsize "${EDIST}/main/binary-amd64/Packages.gz") main/binary-amd64/Packages.gz
EOF
    sign_suite "${EDIST}" published@example.invalid
    assert_exit "empty signed suite passes" 0 bash "${GUARD}" --keyring "${TMP}/published.gpg" "${EMPTY}"

    echo ""
    echo "Test 11: InRelease signs a different text than Release"
    BADSIG1="${TMP}/badsig-payload"
    build_repo "${BADSIG1}"
    sign_suite "${BADSIG1}/dists/${SUITE}" published@example.invalid
    # Change Release after signing and re-sign only Release.gpg, so the
    # detached signature is valid but InRelease carries the old text.
    sed -i.bak 's/^Origin: podman-debian$/Origin: podman-debian-changed/' "${BADSIG1}/dists/${SUITE}/Release"
    rm -f "${BADSIG1}/dists/${SUITE}/Release.bak"
    gpg --batch --yes -u published@example.invalid -abs -o "${BADSIG1}/dists/${SUITE}/Release.gpg" "${BADSIG1}/dists/${SUITE}/Release"
    assert_exit "InRelease != Release exits 1" 1 bash "${GUARD}" --keyring "${TMP}/published.gpg" "${BADSIG1}"

    echo ""
    echo "Test 12: signed by a key other than the published one"
    BADSIG2="${TMP}/badsig-key"
    build_repo "${BADSIG2}"
    sign_suite "${BADSIG2}/dists/${SUITE}" other@example.invalid
    assert_exit "foreign signature exits 1" 1 bash "${GUARD}" --keyring "${TMP}/published.gpg" "${BADSIG2}"
    assert_exit "foreign signature is not checked without --keyring" 0 bash "${GUARD}" "${BADSIG2}"

    echo ""
    echo "Test 13: Release.gpg missing"
    BADSIG3="${TMP}/badsig-missing"
    build_repo "${BADSIG3}"
    sign_suite "${BADSIG3}/dists/${SUITE}" published@example.invalid
    rm -f "${BADSIG3}/dists/${SUITE}/Release.gpg"
    assert_exit "missing Release.gpg exits 1" 1 bash "${GUARD}" --keyring "${TMP}/published.gpg" "${BADSIG3}"
    gpgconf --kill all >/dev/null 2>&1 || true
else
    echo "  SKIP: gpg/gpgv not available; signature checks not exercised."
    if [[ "${REQUIRE_INTEGRATION_DEPS:-0}" == "1" ]]; then
        echo "  FAIL: REQUIRE_INTEGRATION_DEPS=1 but gpg/gpgv is missing."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"
[[ ${FAIL_COUNT} -eq 0 ]]
