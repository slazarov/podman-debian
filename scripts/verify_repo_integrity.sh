#!/bin/bash

# ============================================
# APT repository integrity guard (publish gate)
# ============================================
#
# Parses the assembled repository under <repo-root> and asserts, for EVERY
# published suite, the two consistency properties apt itself enforces at
# `apt-get update` / `apt-get install` time:
#
#   1. Release  <-> index : every file the signed Release lists under its
#      SHA256: section exists on disk and its real size + SHA256 equal the
#      values Release was signed over. (Catches a Release signed over a stale
#      Packages/Packages.gz.)
#   2. index    <-> pool  : every `Filename:` in every binary-*/Packages exists
#      in pool/ and its real size + SHA256 equal the index's `Size:` + `SHA256:`.
#      (Catches the shared-pool overwrite bug: a non-reproducible rebuild of an
#      already-published version replacing the pool .deb out from under another
#      suite's signed index — the "File has unexpected size" apt failure.)
#
#   3. Release itself: it names its Suite and Codename, has a SHA256 section,
#      and lists a Packages index for every component and architecture it
#      declares. Every Packages stanza carries Filename, Size and SHA256 (an
#      entry without them could never be checked, so it fails instead of
#      being skipped).
#
#   4. Signatures (with --keyring): InRelease and Release.gpg both verify with
#      gpgv against the given public keyring (the key clients install), and
#      the text InRelease signs is byte-identical to Release.
#
# Any mismatch fails the whole publish (exit 1) BEFORE the Pages upload, so an
# internally-inconsistent repository can never reach clients.
#
# Portable: bash + awk + sha256sum (or `shasum -a 256`) + `wc -c`, plus gpgv
# for --keyring. Runs on the CI runner, Debian hosts and macOS (for the unit
# test).

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") [--keyring <public-keyring>] <repo-root>" >&2
    echo "" >&2
    echo "  <repo-root>  Assembled repository root (contains dists/ and pool/)." >&2
    echo "  --keyring    Public key file (binary or ASCII-armored) every suite" >&2
    echo "               must be signed with. Without it, signatures are not checked." >&2
    exit 2
}

KEYRING=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keyring)
            [[ $# -ge 2 ]] || usage
            KEYRING="$2"
            shift 2
            ;;
        -*)
            usage
            ;;
        *)
            break
            ;;
    esac
done
[[ $# -eq 1 ]] || usage
REPO_ROOT="$1"

if [[ ! -d "${REPO_ROOT}/dists" ]]; then
    echo "ERROR: no dists/ under '${REPO_ROOT}' — not a repository root." >&2
    exit 2
fi

# sha256 of a file, portable across Linux (sha256sum) and macOS (shasum -a 256).
_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# size of a file in bytes, portable (avoids stat's differing -c/-f flags).
_fsize() {
    wc -c < "$1" | tr -d '[:space:]'
}

MISMATCH_COUNT=0
CHECK_COUNT=0

# gpgv wants a binary keyring given by absolute path, and a home directory
# of its own so it never reads or writes the caller's ~/.gnupg.
GPGV_HOME=""
GPGV_KEYRING=""
cleanup() {
    [[ -n "${GPGV_HOME}" ]] && rm -rf "${GPGV_HOME}"
    return 0
}
trap cleanup EXIT
if [[ -n "${KEYRING}" ]]; then
    if [[ ! -s "${KEYRING}" ]]; then
        echo "ERROR: keyring '${KEYRING}' is missing or empty." >&2
        exit 2
    fi
    if ! command -v gpgv >/dev/null 2>&1; then
        echo "ERROR: --keyring needs gpgv, which is not installed." >&2
        exit 2
    fi
    GPGV_HOME="$(mktemp -d)"
    chmod 700 "${GPGV_HOME}"
    GPGV_KEYRING="${GPGV_HOME}/keyring.gpg"
    if LC_ALL=C grep -q -- '-----BEGIN PGP' "${KEYRING}"; then
        if ! gpg --batch --homedir "${GPGV_HOME}" --dearmor -o "${GPGV_KEYRING}" "${KEYRING}" 2>/dev/null; then
            echo "ERROR: could not dearmor keyring '${KEYRING}'." >&2
            exit 2
        fi
    else
        cp "${KEYRING}" "${GPGV_KEYRING}"
    fi
fi

# gpgv_ok <args...> -> 0 when gpgv accepts the signature.
gpgv_ok() {
    gpgv --homedir "${GPGV_HOME}" --keyring "${GPGV_KEYRING}" "$@" >/dev/null 2>&1
}

fail() {
    echo "  MISMATCH: $1" >&2
    MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
}

echo "========================================"
echo ">>> Repository integrity check: ${REPO_ROOT}"
echo "========================================"

# Enumerate suites (each dists/<suite>/ with a Release).
shopt -s nullglob
for suite_dir in "${REPO_ROOT}/dists"/*/; do
    suite="$(basename "${suite_dir}")"
    release="${suite_dir}Release"
    [[ -f "${release}" ]] || continue
    echo ">>> Suite: ${suite}"

    # ---- Property 3: Release names itself and lists what it declares ---------
    CHECK_COUNT=$((CHECK_COUNT + 1))
    for field in Suite Codename; do
        if ! grep -qE "^${field}: [^[:space:]]" "${release}"; then
            fail "${suite}: Release has no ${field} field"
        fi
    done
    sha256_list="$(awk '$0=="SHA256:"{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $3}' "${release}")"
    if ! grep -qx 'SHA256:' "${release}" || [[ -z "${sha256_list}" ]]; then
        fail "${suite}: Release has no SHA256 section"
    fi
    archs="$(awk -F': ' '$1=="Architectures"{print $2; exit}' "${release}")"
    comps="$(awk -F': ' '$1=="Components"{print $2; exit}' "${release}")"
    if [[ -z "${archs}" || -z "${comps}" ]]; then
        fail "${suite}: Release has no Architectures or Components field"
    fi
    for comp in ${comps}; do
        for arch in ${archs}; do
            [[ "${arch}" == "source" || "${arch}" == "all" ]] && continue
            if ! grep -qxF "${comp}/binary-${arch}/Packages" <<< "${sha256_list}"; then
                fail "${suite}: Release does not list ${comp}/binary-${arch}/Packages"
            fi
        done
    done

    # ---- Property 4: signatures (only with --keyring) --------------------------
    if [[ -n "${GPGV_KEYRING}" ]]; then
        CHECK_COUNT=$((CHECK_COUNT + 1))
        if [[ ! -f "${suite_dir}InRelease" ]]; then
            fail "${suite}: InRelease is missing"
        elif ! gpgv_ok "${suite_dir}InRelease"; then
            fail "${suite}: InRelease does not verify with the published key"
        else
            payload="${GPGV_HOME}/payload"
            rm -f "${payload}"
            if ! gpgv_ok --output "${payload}" "${suite_dir}InRelease" \
                || ! cmp -s "${payload}" "${release}"; then
                fail "${suite}: the text InRelease signs differs from Release"
            fi
        fi
        if [[ ! -f "${suite_dir}Release.gpg" ]]; then
            fail "${suite}: Release.gpg is missing"
        elif ! gpgv_ok "${suite_dir}Release.gpg" "${release}"; then
            fail "${suite}: Release.gpg does not verify Release with the published key"
        fi
    fi

    # ---- Property 1: Release <-> the indexes it lists (SHA256 section) --------
    # reprepro lists each checksummed file as "<sha256> <size> <relpath>" under a
    # "SHA256:" header. Verify every listed path on disk.
    while read -r exp_hash exp_size relpath; do
        [[ -n "${relpath}" ]] || continue
        target="${suite_dir}${relpath}"
        CHECK_COUNT=$((CHECK_COUNT + 1))
        if [[ ! -f "${target}" ]]; then
            fail "${suite}: Release lists ${relpath} but it is missing on disk"
            continue
        fi
        act_size="$(_fsize "${target}")"
        if [[ "${act_size}" != "${exp_size}" ]]; then
            fail "${suite}: ${relpath} size ${act_size} != Release ${exp_size}"
            continue
        fi
        act_hash="$(_sha256 "${target}")"
        if [[ "${act_hash}" != "${exp_hash}" ]]; then
            fail "${suite}: ${relpath} sha256 mismatch vs signed Release"
        fi
    done < <(awk '$0=="SHA256:"{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $1, $2, $3}' "${release}")

    # ---- Property 2: every binary-*/Packages entry <-> its pool .deb ----------
    for pkgs in "${suite_dir}"main/binary-*/Packages; do
        [[ -f "${pkgs}" ]] || continue

        # Packages.gz (if present) must decompress byte-identically to Packages.
        if [[ -f "${pkgs}.gz" ]]; then
            CHECK_COUNT=$((CHECK_COUNT + 1))
            if ! gzip -dc "${pkgs}.gz" 2>/dev/null | cmp -s - "${pkgs}"; then
                fail "${suite}: $(basename "$(dirname "${pkgs}")")/Packages.gz does not match Packages"
            fi
        fi

        # One (Package, Filename, Size, SHA256) record per stanza. A missing
        # field prints as "-" so the columns stay aligned.
        while read -r package filename size sha256; do
            [[ -n "${package}" ]] || continue
            CHECK_COUNT=$((CHECK_COUNT + 1))
            if [[ "${filename}" == "-" || "${size}" == "-" || "${sha256}" == "-" ]]; then
                fail "${suite}: Packages stanza for ${package} lacks Filename, Size or SHA256"
                continue
            fi
            pool_file="${REPO_ROOT}/${filename}"
            if [[ ! -f "${pool_file}" ]]; then
                fail "${suite}: index references ${filename} but it is missing from pool/"
                continue
            fi
            act_size="$(_fsize "${pool_file}")"
            if [[ "${act_size}" != "${size}" ]]; then
                fail "${suite}: ${filename} pool size ${act_size} != index Size ${size}"
                continue
            fi
            act_hash="$(_sha256 "${pool_file}")"
            if [[ "${act_hash}" != "${sha256}" ]]; then
                fail "${suite}: ${filename} pool sha256 != index SHA256"
            fi
        done < <(awk '
            function emit() {
                if (pk != "" || fn != "")
                    print (pk == "" ? "?" : pk), (fn == "" ? "-" : fn), (sz == "" ? "-" : sz), (sha == "" ? "-" : sha)
                pk = ""; fn = ""; sz = ""; sha = ""
            }
            /^Package:/  { pk=$2 }
            /^Filename:/ { fn=$2 }
            /^Size:/     { sz=$2 }
            /^SHA256:/   { sha=$2 }
            /^[[:space:]]*$/ { emit() }
            END { emit() }' "${pkgs}")
    done
done
shopt -u nullglob

echo "========================================"
if [[ ${MISMATCH_COUNT} -gt 0 ]]; then
    echo ">>> FAIL: ${MISMATCH_COUNT} integrity mismatch(es) across ${CHECK_COUNT} checks" >&2
    echo ">>> The signed metadata is out of sync with the pool. Refusing to publish." >&2
    echo "========================================"
    exit 1
fi
if [[ -n "${GPGV_KEYRING}" ]]; then
    echo ">>> OK: ${CHECK_COUNT} checks passed; every suite is signed, and its index matches Release and pool"
else
    echo ">>> OK: ${CHECK_COUNT} checks passed; every suite's index matches Release and pool (signatures not checked)"
fi
echo "========================================"
exit 0
