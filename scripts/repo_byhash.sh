#!/bin/bash

# Abort on Error
set -euo pipefail

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}"); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# ============================================
# Post-export Acquire-By-Hash support
# ============================================
#
# reprepro has no native Acquire-By-Hash support (Debian bug #820660), and
# GitHub Pages' CDN can serve a stale index alongside a fresh Release mid-deploy,
# producing apt hash-sum mismatches. After `reprepro export <suite>`, this helper:
#   1. materializes by-hash/<ALGO>/<hash> copies of every checksummed index
#      ADJACENT to that index, plus a by-hash copy of Release,
#   2. injects `Acquire-By-Hash: yes` into the suite's Release idempotently, and
#   3. re-signs InRelease (clearsign) + Release.gpg (detached). This is required
#      because editing Release after export invalidates reprepro's signatures.
#
# This helper does NOT re-import the GPG key; it relies on repo_manage.sh having
# already imported it into the keyring earlier in the publish.
#
# Every step checks its own result and the function returns 1 on the first
# failure, after it has printed the reason. It does not change the caller's
# shell options and installs no traps, so it behaves the same inside an `if`
# or `||` (where bash turns errexit off) as on its own. Callers must stop on
# a non-zero return: a suite whose Release was edited but not re-signed is
# unusable for apt.
#
# A listed index that does not exist on disk is skipped here (there is
# nothing to copy). verify_repo_integrity.sh fails the publish on it later.

# add_byhash_and_resign <suite> <output-dir>
#   lsuite : suite name (e.g. "stable-bookworm")
#   lrepo  : the OUTPUT_DIR repo root (contains dists/, pool/)
add_byhash_and_resign() {
    local lsuite="$1" lrepo="$2"          # lrepo = OUTPUT_DIR
    local ldist="${lrepo}/dists/${lsuite}"
    local lrelease="${ldist}/Release"
    local algo hash relpath src bhdir cmd rh lentries

    # Empty-but-signed suites still have a Release; guard anyway.
    [[ -f "${lrelease}" ]] || return 0

    # 1) by-hash for every checksummed index (SHA256, plus SHA512 if present).
    #    reprepro lists files under a "<Algo>:" section as "<hash> <size> <relpath>".
    #    The awk parser turns on at the "<Algo>:" header, stops at the next
    #    "^[A-Za-z0-9-]+:" header, and emits "<hash> <relpath>" pairs in between.
    for algo in SHA256 SHA512; do
        if ! lentries="$(awk -v a="${algo}:" '$0==a{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $1, $3}' "${lrelease}")"; then
            echo "ERROR: ${lsuite}: could not read the ${algo} list in Release" >&2
            return 1
        fi
        while read -r hash relpath; do
            [[ -n "${relpath}" ]] || continue
            src="${ldist}/${relpath}"
            [[ -f "${src}" ]] || continue
            bhdir="$(dirname "${src}")/by-hash/${algo}"
            if ! mkdir -p "${bhdir}" || ! cp -f "${src}" "${bhdir}/${hash}"; then
                echo "ERROR: ${lsuite}: could not write ${bhdir}/${hash}" >&2
                return 1
            fi
        done <<< "${lentries}"
    done

    # 2) inject Acquire-By-Hash idempotently. Field order in a deb822 Release is
    #    not significant, so inserting after the Suite: line is safe.
    if ! grep -q '^Acquire-By-Hash:' "${lrelease}"; then
        if ! sed -i '/^Suite:/a Acquire-By-Hash: yes' "${lrelease}" \
            || ! grep -q '^Acquire-By-Hash: yes' "${lrelease}"; then
            echo "ERROR: ${lsuite}: could not add Acquire-By-Hash to Release" >&2
            return 1
        fi
    fi

    # 3) by-hash for the Release file itself, computed AFTER injection so the
    #    by-hash Release stays byte-identical to the served Release.
    for algo in SHA256 SHA512; do
        cmd="${algo,,}sum"
        command -v "${cmd}" >/dev/null || continue
        rh="$("${cmd}" "${lrelease}" | awk '{print $1}')"
        if [[ -z "${rh}" ]] || ! mkdir -p "${ldist}/by-hash/${algo}" \
            || ! cp -f "${lrelease}" "${ldist}/by-hash/${algo}/${rh}"; then
            echo "ERROR: ${lsuite}: could not write the ${algo} by-hash copy of Release" >&2
            return 1
        fi
    done

    # 4) re-sign and check the new signatures (resign_release below).
    resign_release "${lsuite}" "${lrepo}"
}

# resign_release <suite> <output-dir>
#   Signs the suite's Release, unchanged, with the key in the keyring: drops the
#   old InRelease and Release.gpg, writes new ones, and checks that both verify
#   and that InRelease signs exactly the Release on disk. Returns 1 on the first
#   failure. Release itself and every index stay byte-identical, so a suite
#   served verbatim can be moved to a new signing key without changing what
#   by-hash points at.
resign_release() {
    local lsuite="$1" lrepo="$2"
    local ldist="${lrepo}/dists/${lsuite}"
    local lrelease="${ldist}/Release"

    if [[ ! -f "${lrelease}" ]]; then
        echo "ERROR: ${lsuite}: no Release to sign" >&2
        return 1
    fi
    if ! rm -f "${ldist}/InRelease" "${ldist}/Release.gpg"; then
        echo "ERROR: ${lsuite}: could not remove the old signatures" >&2
        return 1
    fi
    if ! gpg --batch --yes --clearsign -o "${ldist}/InRelease" "${lrelease}"; then
        echo "ERROR: ${lsuite}: gpg --clearsign failed; InRelease not written" >&2
        rm -f "${ldist}/InRelease"
        return 1
    fi
    if ! gpg --batch --yes -abs -o "${ldist}/Release.gpg" "${lrelease}"; then
        echo "ERROR: ${lsuite}: gpg detached signing failed; Release.gpg not written" >&2
        rm -f "${ldist}/Release.gpg"
        return 1
    fi

    # Check what was just written: both signatures verify, and the text
    # InRelease signs is exactly the Release on disk.
    if ! gpg --batch --quiet --verify "${ldist}/InRelease" 2>/dev/null; then
        echo "ERROR: ${lsuite}: the new InRelease does not verify" >&2
        return 1
    fi
    if ! gpg --batch --quiet --verify "${ldist}/Release.gpg" "${lrelease}" 2>/dev/null; then
        echo "ERROR: ${lsuite}: the new Release.gpg does not verify against Release" >&2
        return 1
    fi
    if ! gpg --batch --quiet --decrypt "${ldist}/InRelease" 2>/dev/null | cmp -s - "${lrelease}"; then
        echo "ERROR: ${lsuite}: the text signed in InRelease differs from Release" >&2
        return 1
    fi
    return 0
}

# release_signed_with <suite> <output-dir> <public-keyring>
#   Returns 0 when the suite's InRelease and Release.gpg both verify with gpgv
#   against <public-keyring> (binary or ASCII-armored), 1 otherwise, including
#   when a signature file is missing. Used to find verbatim suites that are
#   still signed with a retired key. gpgv gets a home directory of its own so
#   the caller's keyring plays no part.
release_signed_with() {
    local lsuite="$1" lrepo="$2" lkeyring="$3"
    local ldist="${lrepo}/dists/${lsuite}"
    local lhome lkr lrc=0

    [[ -f "${ldist}/InRelease" && -f "${ldist}/Release.gpg" && -f "${ldist}/Release" ]] || return 1
    lhome="$(mktemp -d)" || return 1
    chmod 700 "${lhome}"
    lkr="${lhome}/keyring.gpg"
    if LC_ALL=C grep -q -- '-----BEGIN PGP' "${lkeyring}"; then
        gpg --batch --homedir "${lhome}" --dearmor -o "${lkr}" "${lkeyring}" 2>/dev/null || lrc=1
    else
        cp "${lkeyring}" "${lkr}" || lrc=1
    fi
    if [[ "${lrc}" -eq 0 ]]; then
        gpgv --homedir "${lhome}" --keyring "${lkr}" "${ldist}/InRelease" >/dev/null 2>&1 \
            && gpgv --homedir "${lhome}" --keyring "${lkr}" "${ldist}/Release.gpg" "${ldist}/Release" >/dev/null 2>&1 \
            || lrc=1
    fi
    rm -rf "${lhome}"
    return "${lrc}"
}

# ============================================
# Sourceable vs standalone entrypoint
# ============================================
# When sourced, only define the function and return. When executed directly with
# two args (<suite> <output-dir>), run the helper — useful for VM verification.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -ne 2 ]]; then
        echo "Usage: $(basename "$0") <suite> <output-dir>" >&2
        exit 1
    fi
    add_byhash_and_resign "$1" "$2"
fi
