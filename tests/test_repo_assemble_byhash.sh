#!/bin/bash

# Integration harness: real reprepro/gpg assemble of the multi-suite
# repository, by-hash + re-sign post-processing, and the no-clobber property.
#
# It checks:
#   - Acquire-By-Hash: yes in every populated suite's Release, a
#     by-hash/<ALGO>/<hash> copy adjacent to each index, and a valid GPG
#     signature chain (InRelease clearsign + Release.gpg detached) AFTER the
#     by-hash mutation re-signs Release.
#   - No-clobber: publishing one suite leaves another populated suite's
#     Packages index byte-identical.
#   - An empty suite (stable-trixie with zero packages) still exports a signed
#     Release that verifies.
#   - Which hash algorithms reprepro actually emitted, with by-hash present
#     for at least the strongest one.
#   - A publish for one distro leaves the other distro's signed suite
#     byte-identical (it is served verbatim, never re-signed).
#   - A failing `gpg --clearsign` or detached sign makes
#     add_byhash_and_resign return non-zero (no masked signing failure).
#
# Needs reprepro, gpg and dpkg-deb. Where they are missing the harness prints
# SKIP and exits 0, like the dpkg-dependent checks in
# tests/test_detect_distro_depends.sh. With REQUIRE_INTEGRATION_DEPS=1 (CI) a
# missing tool fails the test instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=tests/lib/mock_http.sh
source "${SCRIPT_DIR}/lib/mock_http.sh"

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

assert_file_exists() {
    local description="$1"
    local path="$2"
    if [[ -f "${path}" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Missing file: ${path}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Asserts the given command exits 0 (clean subshell so set -e in callee bodies
# does not abort the runner).
assert_succeeds() {
    local description="$1"
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Command unexpectedly failed: $*"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_grep() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -q "${pattern}" "${file}" 2>/dev/null; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Pattern not found: ${pattern}"
        echo "    In file: ${file}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo ""
echo "========================================"
echo "Test: repo assemble + by-hash + no-clobber (integration)"
echo "========================================"
echo ""

# ============================================
# Platform skip (hosts without reprepro/dpkg-deb)
# ============================================

if ! command -v reprepro &>/dev/null \
   || ! command -v gpg &>/dev/null \
   || ! command -v dpkg-deb &>/dev/null \
   || ! command -v sha256sum &>/dev/null; then
    echo "  SKIP: reprepro/gpg/dpkg-deb/sha256sum not all available."
    require_integration_deps "reprepro/gpg/dpkg-deb/sha256sum"
    echo "  NOTE: this integration harness needs a Debian-based host with:"
    echo "          sudo apt-get update && sudo apt-get install -y reprepro"
    echo ""
    echo "========================================"
    echo "Results: 0 passed, 0 failed (SKIPPED on this host)"
    echo "========================================"
    exit 0
fi

# ============================================
# Isolated fixture: throwaway GNUPGHOME + temp output dirs (no host mutation)
# ============================================

# Scripts that source config.sh read DISTRO instead of the host's
# /etc/os-release, so the harness also runs on non-Debian hosts.
export DISTRO=bookworm

TMP_ROOT="$(mktemp -d)"
export GNUPGHOME="${TMP_ROOT}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
# Cleanup everything (key material + assembled trees) on exit. gpg-agent spawned
# under the throwaway GNUPGHOME is killed so the temp dir can be removed cleanly.
trap 'gpgconf --homedir "${GNUPGHOME}" --kill all >/dev/null 2>&1 || true; rm -rf "${TMP_ROOT}"' EXIT

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
    # Fallback to RSA in case the gpg build lacks ed25519 batch support.
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
# Trust the key ultimately to avoid signing/verify warnings.
TEST_KEY_FPR="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
echo "${TEST_KEY_FPR}:6:" | gpg --batch --import-ownertrust >/dev/null 2>&1
echo "  key: ${TEST_KEY_FPR}"
echo ""

# ============================================
# Build tiny fixture .deb files (two distinct packages, bookworm-suffixed version)
# ============================================
#
# build_fixture_deb <pkgname> <version> <arch> <out-dir>
build_fixture_deb() {
    local lpkg="$1" lver="$2" larch="$3" lout="$4"
    local lstage="${TMP_ROOT}/stage-${lpkg}-${larch}"
    rm -rf "${lstage}"
    mkdir -p "${lstage}/DEBIAN" "${lstage}/usr/share/doc/${lpkg}"
    cat > "${lstage}/DEBIAN/control" <<EOF_CTL
Package: ${lpkg}
Version: ${lver}
Architecture: ${larch}
Maintainer: Repo Test <repo-test@example.invalid>
Section: admin
Priority: optional
Description: Fixture package ${lpkg} for the repo assemble harness
 Not a real package; used only to exercise reprepro includedeb + by-hash.
EOF_CTL
    echo "fixture ${lpkg} ${lver}" > "${lstage}/usr/share/doc/${lpkg}/README"
    mkdir -p "${lout}"
    dpkg-deb --build --root-owner-group "${lstage}" \
        "${lout}/${lpkg}_${lver}_${larch}.deb" >/dev/null
}

# The versions carry the per-distro suffix the project uses (~deb12.podman1).
STABLE_DEB_DIR="${TMP_ROOT}/debs-stable"
V5_DEB_DIR="${TMP_ROOT}/debs-v5"
echo ">>> Building fixture .deb packages..."
build_fixture_deb "podman-suite" "5.0.0~deb12.podman1" "amd64" "${STABLE_DEB_DIR}"
build_fixture_deb "conmon-suite" "2.1.0~deb12.podman1" "amd64" "${V5_DEB_DIR}"
echo "  stable debs: $(find "${STABLE_DEB_DIR}" -name '*.deb' | wc -l | tr -d ' ')"
echo "  v5 debs:     $(find "${V5_DEB_DIR}" -name '*.deb' | wc -l | tr -d ' ')"
echo ""

# ============================================
# Assemble: repo_manage.sh + add_byhash_and_resign
# ============================================
#
# Assemble directly via repo_manage.sh (the assemble core ci_publish.sh
# invokes), then source repo_byhash.sh and apply add_byhash_and_resign per
# suite. This keeps the checks focused on assemble + by-hash + signatures
# without driving the full ci_publish.sh against a mock URL.

OUT="${TMP_ROOT}/out"
mkdir -p "${OUT}"

# repo_manage.sh signs with the keyring key (no GPG_PRIVATE_KEY env); the
# throwaway key in GNUPGHOME is the only secret key present.
echo ">>> Assembling stable-bookworm..."
"${PROJECT_ROOT}/scripts/repo_manage.sh" stable bookworm "${STABLE_DEB_DIR}" "${OUT}" >/dev/null

echo ">>> Assembling v5-bookworm..."
"${PROJECT_ROOT}/scripts/repo_manage.sh" v5 bookworm "${V5_DEB_DIR}" "${OUT}" >/dev/null

# Empty-but-signed suite: reprepro export with no packages. repo_manage.sh
# requires .deb files, so export the empty suite directly. repo_manage.sh
# removes conf/ after each run, so restore it first.
echo ">>> Exporting empty-but-signed stable-trixie..."
mkdir -p "${OUT}/conf"
cp "${PROJECT_ROOT}/packaging/repo/conf/distributions" "${OUT}/conf/"
cp "${PROJECT_ROOT}/packaging/repo/conf/options" "${OUT}/conf/"
reprepro -b "${OUT}" export stable-trixie >/dev/null
rm -rf "${OUT}/db" "${OUT}/conf"

# Apply by-hash + re-sign to every populated/exported suite (ci_publish.sh Step 4b).
echo ">>> Applying add_byhash_and_resign per suite..."
# shellcheck source=/dev/null
source "${PROJECT_ROOT}/scripts/repo_byhash.sh"
ASSEMBLED_SUITES=(stable-bookworm v5-bookworm stable-trixie)
for suite in "${ASSEMBLED_SUITES[@]}"; do
    if [[ -f "${OUT}/dists/${suite}/Release" ]]; then
        add_byhash_and_resign "${suite}" "${OUT}"
    fi
done
echo ""

# ============================================
# Assertions
# ============================================

# Populated suites we expect to carry real Packages content.
POPULATED_SUITES=(stable-bookworm v5-bookworm)
ARCHES=(amd64)

echo "Test group A: Acquire-By-Hash on every populated suite"
echo ""
for suite in "${POPULATED_SUITES[@]}"; do
    rel="${OUT}/dists/${suite}/Release"
    assert_file_exists "Release exists for ${suite}" "${rel}"
    assert_grep "Acquire-By-Hash: yes present in ${suite} Release" \
        '^Acquire-By-Hash: yes' "${rel}"
done

echo ""
echo "Test group B: by-hash copy adjacent to each Packages index (strongest algo)"
echo ""
# Record which checksum algorithms reprepro emitted in a sample Release.
SAMPLE_REL="${OUT}/dists/stable-bookworm/Release"
echo "  reprepro emitted checksum sections in stable-bookworm Release:"
grep -E '^(MD5Sum|SHA1|SHA256|SHA512):' "${SAMPLE_REL}" | sed 's/^/    /' || true
# SHA256 is the strongest universally-emitted algo (SHA512 is optional).
STRONG_ALGO="SHA256"
if grep -q '^SHA512:' "${SAMPLE_REL}"; then
    STRONG_ALGO="SHA512"
fi
echo "  strongest-available algo asserted: ${STRONG_ALGO}"
STRONG_CMD="$(echo "${STRONG_ALGO}" | tr '[:upper:]' '[:lower:]')sum"
echo ""

for suite in "${POPULATED_SUITES[@]}"; do
    for arch in "${ARCHES[@]}"; do
        idx="${OUT}/dists/${suite}/main/binary-${arch}/Packages"
        if [[ -f "${idx}" ]]; then
            h="$(${STRONG_CMD} "${idx}" | awk '{print $1}')"
            bh="${OUT}/dists/${suite}/main/binary-${arch}/by-hash/${STRONG_ALGO}/${h}"
            assert_file_exists "by-hash/${STRONG_ALGO} for ${suite} ${arch} Packages" "${bh}"
            # The by-hash copy must be byte-identical to the served index.
            if [[ -f "${bh}" ]]; then
                assert_equals "by-hash copy byte-identical to ${suite} ${arch} Packages" \
                    "$(${STRONG_CMD} "${idx}" | awk '{print $1}')" \
                    "$(${STRONG_CMD} "${bh}" | awk '{print $1}')"
            fi
        fi
    done
done

echo ""
echo "Test group C: GPG signature chain valid AFTER by-hash re-sign"
echo ""
for suite in "${POPULATED_SUITES[@]}"; do
    dist="${OUT}/dists/${suite}"
    assert_file_exists "InRelease exists for ${suite}" "${dist}/InRelease"
    assert_file_exists "Release.gpg exists for ${suite}" "${dist}/Release.gpg"
    assert_succeeds "gpg --verify InRelease for ${suite}" \
        gpg --verify "${dist}/InRelease"
    assert_succeeds "gpg --verify Release.gpg Release for ${suite}" \
        gpg --verify "${dist}/Release.gpg" "${dist}/Release"
done

echo ""
echo "Test group D: no-clobber across suites on a single-suite publish"
echo ""
# Capture v5-bookworm's Packages hashes, then re-publish ONLY stable-bookworm
# with the v5 tree in place. v5-bookworm must remain byte-identical.
declare -A V5_BEFORE
NOCLOBBER_OK=true
for arch in "${ARCHES[@]}"; do
    v5_idx="${OUT}/dists/v5-bookworm/main/binary-${arch}/Packages"
    if [[ -f "${v5_idx}" ]]; then
        V5_BEFORE["${arch}"]="$(${STRONG_CMD} "${v5_idx}" | awk '{print $1}')"
    fi
done

# Re-publish stable-bookworm only (fresh debs). reprepro's per-suite export and
# the preserved pool mean v5-bookworm's dists/ index is not touched.
"${PROJECT_ROOT}/scripts/repo_manage.sh" stable bookworm "${STABLE_DEB_DIR}" "${OUT}" >/dev/null
add_byhash_and_resign "stable-bookworm" "${OUT}"

for arch in "${ARCHES[@]}"; do
    v5_idx="${OUT}/dists/v5-bookworm/main/binary-${arch}/Packages"
    if [[ -f "${v5_idx}" ]]; then
        after="$(${STRONG_CMD} "${v5_idx}" | awk '{print $1}')"
        assert_equals "v5-bookworm ${arch} Packages byte-identical after stable-bookworm-only publish" \
            "${V5_BEFORE["${arch}"]}" "${after}"
        [[ "${V5_BEFORE["${arch}"]}" == "${after}" ]] || NOCLOBBER_OK=false
    fi
done
# v5-bookworm signature must still verify (untouched, still valid).
assert_succeeds "v5-bookworm InRelease still verifies after stable-only publish" \
    gpg --verify "${OUT}/dists/v5-bookworm/InRelease"

echo ""
echo "Test group E: empty-but-signed stable-trixie"
echo ""
SEMPTY="${OUT}/dists/stable-trixie"
assert_file_exists "stable-trixie Release exists (empty-but-signed)" "${SEMPTY}/Release"
assert_file_exists "stable-trixie InRelease exists" "${SEMPTY}/InRelease"
assert_succeeds "gpg --verify InRelease for empty stable-trixie" \
    gpg --verify "${SEMPTY}/InRelease"
assert_succeeds "gpg --verify Release.gpg Release for empty stable-trixie" \
    gpg --verify "${SEMPTY}/Release.gpg" "${SEMPTY}/Release"
assert_grep "Acquire-By-Hash: yes present in empty stable-trixie Release" \
    '^Acquire-By-Hash: yes' "${SEMPTY}/Release"

echo ""
echo "Test group F: pipefail isolation regression for add_byhash_and_resign"
echo ""
# The whole harness runs under `set -euo pipefail`. A listed index file that
# has been deleted takes the `[[ -f "${src}" ]] || continue` skip path; that
# must not abort the function AFTER the destructive `rm -f InRelease
# Release.gpg` but BEFORE the re-sign, which would publish a half-signed
# suite. We prove the helper survives that condition and still produces a
# verifiable signature chain, and that it leaves the caller's shell options
# alone.

# F-1 / F-2: delete one index file that stable-bookworm's Release lists under
# SHA256:, then re-run add_byhash_and_resign and assert it returns 0 and the
# suite stays validly signed (proving the signature rm is always followed by a
# re-sign even when a pipe head hits a missing file).
F_DIST="${OUT}/dists/stable-bookworm"
# Pick a Packages index that exists and is referenced in Release's SHA256 block.
F_VICTIM=""
for arch in "${ARCHES[@]}"; do
    cand="${F_DIST}/main/binary-${arch}/Packages"
    if [[ -f "${cand}" ]]; then
        F_VICTIM="${cand}"
        break
    fi
done
if [[ -n "${F_VICTIM}" ]]; then
    rm -f "${F_VICTIM}"
    # Under set -euo pipefail: if the helper aborted mid-function the harness
    # would die here and never reach the assertions. Reaching them proves
    # non-abort (F-2).
    assert_succeeds "add_byhash_and_resign survives a deleted listed index (F-1/F-2)" \
        add_byhash_and_resign "stable-bookworm" "${OUT}"
    assert_file_exists "stable-bookworm InRelease exists after deleted-index re-run (F-2)" \
        "${F_DIST}/InRelease"
    assert_file_exists "stable-bookworm Release.gpg exists after deleted-index re-run (F-2)" \
        "${F_DIST}/Release.gpg"
    assert_succeeds "gpg --verify InRelease for stable-bookworm after deleted index (F-1)" \
        gpg --verify "${F_DIST}/InRelease"
    assert_succeeds "gpg --verify Release.gpg Release for stable-bookworm after deleted index (F-2)" \
        gpg --verify "${F_DIST}/Release.gpg" "${F_DIST}/Release"
else
    echo "  SKIP: no stable-bookworm Packages index found to delete (F-1/F-2)"
fi

# F-3: the caller's shell options must be identical before and after the call.
OPTS_BEFORE="$(set +o)"
add_byhash_and_resign "v5-bookworm" "${OUT}"
OPTS_AFTER="$(set +o)"
assert_equals "caller shell options unchanged across add_byhash_and_resign (F-3)" \
    "${OPTS_BEFORE}" "${OPTS_AFTER}"

echo ""
echo "Test group G: a trixie publish leaves the bookworm suite untouched"
echo ""
# A trixie publish targets only stable-trixie. stable-bookworm is a NON-target
# and ci_publish.sh serves it verbatim: its already-signed dists/ tree is left
# exactly as it was, not re-included, re-exported or re-signed. Re-signing an
# unchanged suite would regenerate its Release Date and signature, reopening
# the Acquire-By-Hash CDN hash-mismatch window.
#
# The harness drives the direct-assemble core (repo_manage.sh + per-suite
# add_byhash_and_resign) rather than full ci_publish.sh, so it models the
# trixie publish as: build/update ONLY stable-trixie, then
# add_byhash_and_resign on stable-trixie ONLY, never on stable-bookworm.

STABLE_TRIXIE_DEB_DIR="${TMP_ROOT}/debs-stable-trixie"
build_fixture_deb "podman-suite" "5.0.0~deb13.podman1" "amd64" "${STABLE_TRIXIE_DEB_DIR}"

# Setup: capture stable-bookworm's currently-signed state.
G_OTHER="${OUT}/dists/stable-bookworm"
G_DATE_BEFORE="$(grep '^Date:' "${G_OTHER}/Release" || true)"
G_INRELEASE_BEFORE="$(${STRONG_CMD} "${G_OTHER}/InRelease" | awk '{print $1}')"
G_RELEASEGPG_BEFORE="$(${STRONG_CMD} "${G_OTHER}/Release.gpg" | awk '{print $1}')"

# Action: the trixie publish.
"${PROJECT_ROOT}/scripts/repo_manage.sh" stable trixie "${STABLE_TRIXIE_DEB_DIR}" "${OUT}" >/dev/null
add_byhash_and_resign "stable-trixie" "${OUT}"

# G-1: stable-bookworm Release Date + InRelease + Release.gpg are
# byte-identical before vs after the trixie publish (it was NOT re-signed).
G_DATE_AFTER="$(grep '^Date:' "${G_OTHER}/Release" || true)"
G_INRELEASE_AFTER="$(${STRONG_CMD} "${G_OTHER}/InRelease" | awk '{print $1}')"
G_RELEASEGPG_AFTER="$(${STRONG_CMD} "${G_OTHER}/Release.gpg" | awk '{print $1}')"
assert_equals "stable-bookworm Release Date unchanged across a trixie publish (G-1)" \
    "${G_DATE_BEFORE}" "${G_DATE_AFTER}"
assert_equals "stable-bookworm InRelease byte-identical across a trixie publish (G-1)" \
    "${G_INRELEASE_BEFORE}" "${G_INRELEASE_AFTER}"
assert_equals "stable-bookworm Release.gpg byte-identical across a trixie publish (G-1)" \
    "${G_RELEASEGPG_BEFORE}" "${G_RELEASEGPG_AFTER}"

# G-2: the preserved signature still verifies after the trixie publish.
assert_succeeds "stable-bookworm InRelease still verifies after trixie publish (G-2)" \
    gpg --verify "${G_OTHER}/InRelease"
assert_succeeds "stable-bookworm Release.gpg Release still verifies after trixie publish (G-2)" \
    gpg --verify "${G_OTHER}/Release.gpg" "${G_OTHER}/Release"

# G-3: the stable-trixie target IS freshly (re-)signed and carries Acquire-By-Hash.
G_TARGET="${OUT}/dists/stable-trixie"
assert_file_exists "stable-trixie Release exists after trixie publish (G-3)" \
    "${G_TARGET}/Release"
assert_grep "Acquire-By-Hash: yes present in stable-trixie Release (G-3)" \
    '^Acquire-By-Hash: yes' "${G_TARGET}/Release"
assert_succeeds "gpg --verify InRelease for stable-trixie target (G-3)" \
    gpg --verify "${G_TARGET}/InRelease"

echo ""
echo "Test group H: a failing signature step is reported, never masked"
echo ""
# A gpg on PATH that fails one signing mode and passes everything else
# through to the real gpg. add_byhash_and_resign must return non-zero and
# must not leave a stale or partial signature behind.
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

for mode in clearsign detach; do
    rc=0
    PATH="${SHIM_DIR}:${PATH}" FAIL_GPG_MODE="${mode}" \
        add_byhash_and_resign "v5-bookworm" "${OUT}" >/dev/null 2>&1 || rc=$?
    assert_equals "add_byhash_and_resign returns non-zero when ${mode} signing fails (H-1)" \
        "1" "${rc}"
done
assert_equals "no Release.gpg left behind after a failed detached sign (H-2)" "no" \
    "$([[ -f "${OUT}/dists/v5-bookworm/Release.gpg" ]] && echo yes || echo no)"
# The real gpg signs again cleanly afterwards.
assert_succeeds "add_byhash_and_resign succeeds again with the real gpg (H-3)" \
    add_byhash_and_resign "v5-bookworm" "${OUT}"

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
