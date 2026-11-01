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
# Any mismatch fails the whole publish (exit 1) BEFORE the Pages upload, so an
# internally-inconsistent repository can never reach clients. This is the
# short guardrail, extended to also cover Release.
#
# Portable: pure bash + awk + sha256sum (or `shasum -a 256`) + `wc -c`. Runs on
# the CI runner, Debian hosts and macOS (for the unit test).

set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <repo-root>" >&2
    echo "" >&2
    echo "  <repo-root>  Assembled repository root (contains dists/ and pool/)." >&2
    exit 2
}

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

        # One (Filename, Size, SHA256) triple per stanza.
        while read -r filename size sha256; do
            [[ -n "${filename}" ]] || continue
            CHECK_COUNT=$((CHECK_COUNT + 1))
            pool_file="${REPO_ROOT}/${filename}"
            if [[ ! -f "${pool_file}" ]]; then
                fail "${suite}: index references ${filename} but it is missing from pool/"
                continue
            fi
            act_size="$(_fsize "${pool_file}")"
            if [[ -n "${size}" && "${act_size}" != "${size}" ]]; then
                fail "${suite}: ${filename} pool size ${act_size} != index Size ${size}"
                continue
            fi
            if [[ -n "${sha256}" ]]; then
                act_hash="$(_sha256 "${pool_file}")"
                if [[ "${act_hash}" != "${sha256}" ]]; then
                    fail "${suite}: ${filename} pool sha256 != index SHA256"
                fi
            fi
        done < <(awk '
            /^Filename:/ { fn=$2 }
            /^Size:/     { sz=$2 }
            /^SHA256:/   { sha=$2 }
            /^[[:space:]]*$/ { if (fn!="") print fn, sz, sha; fn=""; sz=""; sha="" }
            END { if (fn!="") print fn, sz, sha }' "${pkgs}")
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
echo ">>> OK: ${CHECK_COUNT} checks passed; every suite's index matches Release and pool"
echo "========================================"
exit 0
