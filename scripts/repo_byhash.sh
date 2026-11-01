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

# add_byhash_and_resign <suite> <output-dir>
#   lsuite : suite name (e.g. "stable-bookworm")
#   lrepo  : the OUTPUT_DIR repo root (contains dists/, pool/)
add_byhash_and_resign() {
    local lsuite="$1" lrepo="$2"          # lrepo = OUTPUT_DIR
    local ldist="${lrepo}/dists/${lsuite}"
    local lrelease="${ldist}/Release"

    # Pipefail isolation: this helper is sourced under the caller's
    # `set -euo pipefail` (ci_publish.sh). A benign non-zero pipe head
    # inside the by-hash loops (a missing listed index file, a transient awk/cp
    # error) must NOT abort the function after `rm -f InRelease Release.gpg`
    # (line below) but before the re-sign — that would publish a half-signed
    # (effectively unsigned) suite to GitHub Pages. Save the caller's exact
    # option set, drop errexit + pipefail locally, and install a single RETURN
    # trap as the sole restore point so the caller's options are restored on
    # EVERY return path (early `return 0`, normal end-of-function). The function
    # itself never re-enables `set -e`/`pipefail`.
    local _saved_opts; _saved_opts="$(set +o)"
    set +e +o pipefail
    trap 'eval "${_saved_opts}"' RETURN

    # Declared once here so the `for algo` loops below do not re-declare
    # `cmd`/`rh` on each iteration.
    local cmd rh

    # Empty-but-signed suites still have a Release; guard anyway. The RETURN trap
    # restores the caller's options even on this early return.
    [[ -f "${lrelease}" ]] || return 0

    # 1) by-hash for every checksummed index (strongest algo: SHA256, +SHA512 if present).
    #    reprepro lists files under a "<Algo>:" section as "<hash> <size> <relpath>".
    #    The awk parser turns on at the "<Algo>:" header, stops at the next
    #    "^[A-Za-z0-9-]+:" header, and emits "<hash> <relpath>" pairs in between.
    local algo
    for algo in SHA256 SHA512; do
        awk -v a="${algo}:" '$0==a{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $1, $3}' "${lrelease}" \
        | while read -r hash relpath; do
            local src="${ldist}/${relpath}"
            # Skip relpaths whose source file does not exist (defensively handles
            # algos reprepro may not emit).
            [[ -f "${src}" ]] || continue
            local bhdir
            bhdir="$(dirname "${src}")/by-hash/${algo}"
            mkdir -p "${bhdir}"
            cp -f "${src}" "${bhdir}/${hash}"
        done
    done

    # 2) inject Acquire-By-Hash idempotently. Field order in a deb822 Release is
    #    not significant, so inserting after the Suite: line is safe.
    grep -q '^Acquire-By-Hash:' "${lrelease}" \
        || sed -i '/^Suite:/a Acquire-By-Hash: yes' "${lrelease}"

    # 3) by-hash for the Release file itself, computed AFTER injection so the
    #    by-hash Release stays byte-identical to the served Release.
    for algo in SHA256 SHA512; do
        cmd="${algo,,}sum"
        command -v "${cmd}" >/dev/null || continue
        rh="$(${cmd} "${lrelease}" | awk '{print $1}')"
        mkdir -p "${ldist}/by-hash/${algo}"
        cp -f "${lrelease}" "${ldist}/by-hash/${algo}/${rh}"
    done

    # 4) re-sign (key already in keyring): drop the stale signatures, then
    #    regenerate the inline (InRelease) and detached (Release.gpg) signatures.
    rm -f "${ldist}/InRelease" "${ldist}/Release.gpg"
    gpg --batch --yes --clearsign -o "${ldist}/InRelease"   "${lrelease}"
    gpg --batch --yes -abs        -o "${ldist}/Release.gpg" "${lrelease}"
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
