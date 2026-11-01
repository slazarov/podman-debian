#!/bin/bash

# Test the Release-section parser used by scripts/repo_byhash.sh.
#
# This is a pure-bash/awk parse test. It does NOT invoke reprepro, gpg, or apt,
# so it runs everywhere. It pins the exact awk
# one-liner from repo_byhash.sh against a literal reprepro-style Release fixture
# and proves section-boundary correctness: the SHA256 parse must stop at the
# SHA512 header and must not bleed MD5Sum/SHA512 lines into its result.
#
# Full by-hash materialization + `gpg --verify InRelease` against a real
# reprepro export is covered by tests/test_repo_assemble_byhash.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

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

# ============================================
# Parser under test
# ============================================
# This is the EXACT awk parser embedded in scripts/repo_byhash.sh. Kept here as
# a verbatim copy so the test exercises the same logic that runs in production;
# the acceptance criterion is that this string matches repo_byhash.sh.
parse_section() {
    local algo="$1" release="$2"
    awk -v a="${algo}:" '$0==a{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $1, $3}' "${release}"
}

# Guard: the parser this test pins must still exist verbatim in repo_byhash.sh.
REPO_BYHASH="${PROJECT_ROOT}/scripts/repo_byhash.sh"
if ! grep -qF "awk -v a=\"\${algo}:\" '\$0==a{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print \$1, \$3}'" "${REPO_BYHASH}"; then
    echo "FATAL: the awk parser in test_byhash_parse.sh no longer matches scripts/repo_byhash.sh" >&2
    exit 1
fi

# ============================================
# Literal reprepro-style Release fixture
# ============================================

FIXTURE="$(mktemp)"
trap 'rm -f "${FIXTURE}"' EXIT

# Fake but realistic-length hashes: 32 hex for MD5, 64 for SHA256, 128 for SHA512.
MD5_PKG="0123456789abcdef0123456789abcdef"
MD5_PKGGZ="fedcba9876543210fedcba9876543210"

SHA256_PKG="1111111111111111111111111111111111111111111111111111111111111111"
SHA256_PKGGZ="2222222222222222222222222222222222222222222222222222222222222222"
SHA256_REL="3333333333333333333333333333333333333333333333333333333333333333"

SHA512_PKG="44444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444444"
SHA512_PKGGZ="55555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555555"

cat > "${FIXTURE}" <<EOF
Origin: podman-debian
Label: Podman Debian
Suite: stable-bookworm
Codename: stable-bookworm
Date: Thu, 05 Jun 2026 12:00:00 UTC
Architectures: amd64
Components: main
Description: Podman built from source for Debian 12 (bookworm), Podman 6.x releases
MD5Sum:
 ${MD5_PKG} 12345 main/binary-amd64/Packages
 ${MD5_PKGGZ} 4567 main/binary-amd64/Packages.gz
SHA256:
 ${SHA256_PKG} 12345 main/binary-amd64/Packages
 ${SHA256_PKGGZ} 4567 main/binary-amd64/Packages.gz
 ${SHA256_REL} 890 main/binary-amd64/Release
SHA512:
 ${SHA512_PKG} 12345 main/binary-amd64/Packages
 ${SHA512_PKGGZ} 4567 main/binary-amd64/Packages.gz
EOF

# ============================================
# Tests
# ============================================

echo "Test 1: SHA256 section parse — exact (hash, relpath) pairs"

sha256_out="$(parse_section SHA256 "${FIXTURE}")"

assert_equals "SHA256 yields exactly 3 lines (stops at SHA512 header)" \
    "3" "$(printf '%s\n' "${sha256_out}" | grep -c .)"

assert_equals "SHA256 first pair = Packages hash + relpath" \
    "${SHA256_PKG} main/binary-amd64/Packages" \
    "$(printf '%s\n' "${sha256_out}" | sed -n '1p')"

assert_equals "SHA256 last pair = binary-amd64 Release (last line before SHA512 header)" \
    "${SHA256_REL} main/binary-amd64/Release" \
    "$(printf '%s\n' "${sha256_out}" | sed -n '3p')"

echo ""
echo "Test 2: SHA256 parse does NOT bleed other sections"

# A known SHA512 hash must be absent from the SHA256 result (boundary stop).
if printf '%s\n' "${sha256_out}" | grep -q "${SHA512_PKG}"; then
    echo "  FAIL: SHA512 hash leaked into SHA256 result"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo "  PASS: SHA512 hash absent from SHA256 result"
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# A known MD5 hash must be absent too (header line itself is not included).
if printf '%s\n' "${sha256_out}" | grep -q "${MD5_PKG}"; then
    echo "  FAIL: MD5Sum hash leaked into SHA256 result"
    FAIL_COUNT=$((FAIL_COUNT + 1))
else
    echo "  PASS: MD5Sum hash absent from SHA256 result"
    PASS_COUNT=$((PASS_COUNT + 1))
fi

echo ""
echo "Test 3: SHA512 section parse"

sha512_out="$(parse_section SHA512 "${FIXTURE}")"

assert_equals "SHA512 yields exactly 2 lines" \
    "2" "$(printf '%s\n' "${sha512_out}" | grep -c .)"

assert_equals "SHA512 first pair = Packages hash + relpath" \
    "${SHA512_PKG} main/binary-amd64/Packages" \
    "$(printf '%s\n' "${sha512_out}" | sed -n '1p')"

assert_equals "SHA512 second pair = Packages.gz hash + relpath" \
    "${SHA512_PKGGZ} main/binary-amd64/Packages.gz" \
    "$(printf '%s\n' "${sha512_out}" | sed -n '2p')"

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
