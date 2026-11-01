#!/bin/bash

# CI-specific multi-suite APT repository publisher
# Builds a complete reprepro repository containing ALL suites:
# the newly-built suite from fresh .deb artifacts AND the other
# suites' packages imported from the live GitHub Pages repository.

# Abort on Error
set -euo pipefail

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}"); fi

# The distro argument doubles as the DISTRO override for config.sh, so the
# publish host's own /etc/os-release is never read (the CI publish job runs on
# a GitHub-hosted runner, not on Debian). config.sh rejects an unsupported
# value before anything else happens.
if [[ $# -ge 2 ]]; then
    export DISTRO="$2"
fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Load the post-export Acquire-By-Hash helper. Sourced (not executed), so it
# only defines add_byhash_and_resign; it relies on repo_manage.sh having
# imported the GPG key earlier in the publish.
source "${toolpath}/scripts/repo_byhash.sh"

# Load the landing-page generator (defines generate_index_html).
source "${toolpath}/scripts/index_html.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# ============================================
# Usage and Argument Parsing
# ============================================

usage() {
    echo "Usage: $(basename "$0") <track> <distro> <deb-directory> <repo-url> <output-directory>"
    echo ""
    echo "  track            Release track being published: 'stable', 'v5', or 'nightly'"
    echo "  distro           Target distro: one of ${VALID_DISTROS[*]}"
    echo "  deb-directory    Path containing freshly built .deb files for this track"
    echo "  repo-url         Live repository URL (e.g., https://slazarov.github.io/podman-debian)"
    echo "  output-directory Where to create the final multi-suite repository"
    echo ""
    echo "  The (track, distro) pair is resolved to its publish target, the"
    echo "  '<track>-<distro>' suite, via resolve_publish_targets (config.sh)."
    echo ""
    echo "Environment variables:"
    echo "  GPG_PRIVATE_KEY  If set, imports this GPG key before signing (for CI)"
    echo ""
    echo "This script:"
    echo "  1. Mirrors down the untouched suites' packages from the live repository"
    echo "  2. Builds the published target suite(s) from fresh .debs via repo_manage.sh"
    echo "  3. Re-includes the mirrored suites and exports each suite per-suite"
    echo "  4. Applies Acquire-By-Hash + re-sign to every rebuilt suite"
    echo "  5. Produces a complete repository with every suite in ALL_SUITES (${#ALL_SUITES[@]})"
    exit 1
}

if [[ $# -lt 5 ]]; then
    usage
fi

TRACK="$1"
DISTRO="$2"
DEB_DIR="$3"
REPO_URL="$4"
OUTPUT_DIR="$5"

REPO_CONF="${toolpath}/packaging/repo"

# ============================================
# Validate Arguments
# ============================================

echo ""
echo "========================================"
echo ">>> CI Multi-Suite Repository Publisher"
echo "========================================"
echo ""

# Resolve the publish targets via the routing helper in config.sh. This
# validates track and distro and yields the '<track>-<distro>' suite.
mapfile -t PUBLISH_TARGETS < <(resolve_publish_targets "${TRACK}" "${DISTRO}")
# resolve_publish_targets runs in a subshell; its non-zero exit on bad input
# cannot abort us directly, so an invalid pair yields zero targets.
if [[ ${#PUBLISH_TARGETS[@]} -eq 0 ]]; then
    echo "ERROR: could not resolve publish targets for track='${TRACK}' distro='${DISTRO}'." >&2
    exit 1
fi

# Validate deb directory exists
if [[ ! -d "${DEB_DIR}" ]]; then
    echo "ERROR: deb-directory does not exist: ${DEB_DIR}" >&2
    exit 1
fi

# Validate deb directory contains .deb files
deb_count=$(find "${DEB_DIR}" -maxdepth 1 -name "*.deb" -type f | wc -l)
if [[ "${deb_count}" -eq 0 ]]; then
    echo "ERROR: No .deb files found in: ${DEB_DIR}" >&2
    exit 1
fi

# ============================================
# Step 1: Determine the OTHER (untouched) suites
# ============================================

# ALL_SUITES comes from config.sh; do not redeclare it. OTHER_SUITES is every
# member of ALL_SUITES that is not a publish target. The untouched suites are
# mirrored unchanged from the live repo, so publishing one suite never
# clobbers another.
OTHER_SUITES=()
for s in "${ALL_SUITES[@]}"; do
    is_target=false
    for t in "${PUBLISH_TARGETS[@]}"; do
        if [[ "$s" == "$t" ]]; then
            is_target=true
            break
        fi
    done
    if [[ "${is_target}" != "true" ]]; then
        OTHER_SUITES+=("$s")
    fi
done

echo "Track:          ${TRACK}"
echo "Distro:         ${DISTRO}"
echo "Publish targets:${PUBLISH_TARGETS[*]} (${deb_count} new packages)"
echo "Other suites:   ${OTHER_SUITES[*]} (will mirror from live repo)"
echo "Live repo:      ${REPO_URL}"
echo "Output dir:     ${OUTPUT_DIR}"
echo ""

# ============================================
# Step 2: Mirror other suites' metadata + .deb files from the live repo
# ============================================
#
# Non-target suites whose live dists/<suite>/ tree already exists are served
# VERBATIM. We copy the live `dists/<suite>/` metadata tree
# (Release, InRelease, Release.gpg, per-arch Packages/Release, by-hash/) and the
# pool entries it references straight into ${OUTPUT_DIR} with their ORIGINAL
# signatures, then exclude the suite from the re-includedeb/re-export loop
# (Step 4) and the by-hash + re-sign loop (Step 4b). Re-exporting an unchanged
# suite would regenerate its Release Date + signature even though its package
# content is identical, reopening the Acquire-By-Hash CDN hash-mismatch window
# this bolt-on exists to prevent. Serving the tree verbatim keeps the suite's
# Release Date / InRelease / Release.gpg byte-identical.
#
# VERBATIM_SUITES holds the non-target suites successfully mirrored verbatim
# (every non-target suite with a live tree). When a live tree 404s (first
# deploy, or a suite never published) the verbatim copy no-ops cleanly and the
# suite stays empty.

declare -A OTHER_SUITE_DEBS_DIRS
declare -A OTHER_SUITE_COUNTS
declare -A IS_VERBATIM
VERBATIM_SUITES=()
# Every non-target suite that HAD a live tree this run (preserved in place, served
# verbatim, or demoted+re-exported). Each MUST still have a Release after assembly;
# a vanished one means the re-export path silently dropped a published suite (a
# regression that would 404 the suite for clients). Checked before the integrity gate.
MIRRORED_SUITES=()
total_other_count=0

# mirror_suite_verbatim <suite> [repo-url] [output-dir] — reconstruct the live
# dists/<suite>/ metadata tree byte-identically from the signed Release's own
# file manifest and place it into the output repo, preserving the original
# signatures. repo-url / output-dir default to the caller's REPO_URL /
# OUTPUT_DIR globals (overridable so tests can drive the function directly).
# Returns 0 if the live tree existed and was reconstructed verbatim, 1
# otherwise (first deploy / not published / CDN integrity mismatch). Never
# aborts the caller.
#
# GitHub Pages serves no directory listings, so a recursive crawl cannot
# enumerate the tree. The signed Release already lists every index it
# checksums, so fetch that manifest explicitly: top-level signed metadata
# verbatim, every listed index verified against its signed hash, and the
# adjacent by-hash/<ALGO>/<hash> copies reconstructed locally — by-hash files
# are byte-identical copies of the canonical indexes by definition (same
# parser and layout as add_byhash_and_resign, repo_byhash.sh). No crawling,
# no URL-shape dependency.
mirror_suite_verbatim() {
    local lsuite="$1"
    local lrepo_url="${2:-${REPO_URL}}"
    local loutdir="${3:-${OUTPUT_DIR}}"
    local lbase="${lrepo_url}/dists/${lsuite}"

    local lmirror
    lmirror=$(mktemp -d)
    local ldist="${lmirror}/dists/${lsuite}"
    mkdir -p "${ldist}"

    # The signed Release is both the existence probe and the file manifest. A
    # fetch failure means first deploy or suite not yet published: no-op.
    if ! curl -sfL -o "${ldist}/Release" "${lbase}/Release" 2>/dev/null; then
        rm -rf "${lmirror}"
        return 1
    fi

    # The signatures must arrive verbatim — without them the suite cannot be
    # served unchanged, so fall back to the re-export path.
    local lf
    for lf in InRelease Release.gpg; do
        if ! curl -sfL -o "${ldist}/${lf}" "${lbase}/${lf}" 2>/dev/null; then
            echo "  WARNING: ${lsuite}: live ${lf} missing — not serving verbatim" >&2
            rm -rf "${lmirror}"
            return 1
        fi
    done

    # Fetch every checksummed index the Release lists (same "<hash> <size>
    # <relpath>" section parser as repo_byhash.sh), verify it against the
    # signed hash, and reconstruct the adjacent by-hash copy. `tr` instead of
    # ${algo,,} so the function stays runnable under macOS bash 3.2 in tests.
    local algo hash relpath src bhdir cmd rh
    for algo in SHA256 SHA512; do
        cmd="$(echo "${algo}" | tr '[:upper:]' '[:lower:]')sum"
        while read -r hash relpath; do
            [[ -n "${relpath}" ]] || continue
            src="${ldist}/${relpath}"
            if [[ ! -f "${src}" ]]; then
                mkdir -p "$(dirname "${src}")"
                # A listed-but-missing index means the live tree is incomplete
                # and cannot be reproduced verbatim.
                if ! curl -sfL -o "${src}" "${lbase}/${relpath}" 2>/dev/null; then
                    echo "  WARNING: ${lsuite}: listed index ${relpath} missing from live tree — not serving verbatim" >&2
                    rm -rf "${lmirror}"
                    return 1
                fi
            fi
            # Integrity: fetched bytes must match the signed manifest, or a
            # mid-deploy CDN race handed us a stale index — abort verbatim and
            # let the re-export path regenerate the suite consistently.
            if command -v "${cmd}" >/dev/null 2>&1; then
                rh="$(${cmd} "${src}" | awk '{print $1}')"
                if [[ "${rh}" != "${hash}" ]]; then
                    echo "  WARNING: ${lsuite}: ${relpath} does not match signed ${algo} hash — not serving verbatim" >&2
                    rm -rf "${lmirror}"
                    return 1
                fi
            fi
            bhdir="$(dirname "${src}")/by-hash/${algo}"
            mkdir -p "${bhdir}"
            cp -f "${src}" "${bhdir}/${hash}"
        done < <(awk -v a="${algo}:" '$0==a{f=1;next} /^[A-Za-z0-9-]+:/{f=0} f{print $1, $3}' "${ldist}/Release")
    done

    # by-hash copies of the served Release itself (parity with the live tree,
    # which carries them from add_byhash_and_resign step 3).
    for algo in SHA256 SHA512; do
        cmd="$(echo "${algo}" | tr '[:upper:]' '[:lower:]')sum"
        command -v "${cmd}" >/dev/null 2>&1 || continue
        rh="$(${cmd} "${ldist}/Release" | awk '{print $1}')"
        mkdir -p "${ldist}/by-hash/${algo}"
        cp -f "${ldist}/Release" "${ldist}/by-hash/${algo}/${rh}"
    done

    # Place the verbatim dists/<suite>/ tree into the output unchanged. Staged
    # under mktemp so a mid-fetch failure never leaves a partial tree behind.
    mkdir -p "${loutdir}/dists"
    rm -rf "${loutdir}/dists/${lsuite}"
    cp -a "${ldist}" "${loutdir}/dists/${lsuite}"
    rm -rf "${lmirror}"
    return 0
}

for other_suite in "${OTHER_SUITES[@]}"; do
    # Cross-pass no-clobber (multi-distro publish): when several distros publish
    # sequentially into ONE accumulating OUTPUT_DIR, a suite already materialized
    # by an EARLIER pass must be preserved, not re-mirrored from the live repo.
    # That suite is either a freshly built target of a prior pass (e.g.
    # stable-bookworm, built on the bookworm pass and now an "other suite" on
    # the trixie pass) or a verbatim mirror an earlier pass already placed
    # (v5-*/nightly-*). In both cases the live tree is STALE relative to what
    # this run just built, so re-mirroring would overwrite the fresh packages
    # with the old ones: the cross-distro clobber that would freeze
    # stable-bookworm at an old podman version while stable-trixie advances. Serve the in-place tree verbatim
    # (it already carries the correct content, pool entries, by-hash and signature)
    # and skip both the live mirror and the live deb re-download for it.
    if [[ -f "${OUTPUT_DIR}/dists/${other_suite}/Release" ]]; then
        echo ">>> '${other_suite}' already published by an earlier distro pass — preserving in place (no live mirror)"
        IS_VERBATIM["${other_suite}"]=true
        VERBATIM_SUITES+=("${other_suite}")
        MIRRORED_SUITES+=("${other_suite}")
        # Empty placeholder dir so the Step 4 / cleanup loops over OTHER_SUITES
        # stay safe under `set -u`; count 0 keeps it out of the re-include gate.
        OTHER_SUITE_DEBS_DIRS["${other_suite}"]=$(mktemp -d)
        OTHER_SUITE_COUNTS["${other_suite}"]=0
        continue
    fi

    echo ">>> Mirroring existing '${other_suite}' suite from live repo..."

    # Try to serve this non-target suite's signed dists/ tree verbatim.
    if mirror_suite_verbatim "${other_suite}"; then
        IS_VERBATIM["${other_suite}"]=true
        VERBATIM_SUITES+=("${other_suite}")
        MIRRORED_SUITES+=("${other_suite}")
        echo ">>> Mirrored '${other_suite}' dists/ tree verbatim (original signature preserved)"
    else
        IS_VERBATIM["${other_suite}"]=false
        echo ">>> No live tree for '${other_suite}' (first deploy / not published) — nothing to mirror"
    fi

    other_dir=$(mktemp -d)
    OTHER_SUITE_DEBS_DIRS["${other_suite}"]="${other_dir}"
    suite_count=0

    # Per-suite integrity state for the verbatim path (INTEGRITY / heal). A suite
    # may be served with its ORIGINAL signed index ONLY if every pool .deb that
    # index references still matches the index's Size + SHA256. If the shared pool
    # was mutated out from under a previously-signed index — the "File has
    # unexpected size" bug, where a non-reproducible rebuild in another track's
    # publish overwrote a .deb of an already-published version — the stale index
    # MUST NOT be served. verbatim_mismatch flips true and the suite is demoted to
    # the re-export path so reprepro regenerates its index from the ACTUAL pool
    # bytes and re-signs it (Step 4 / 4b).
    verbatim_mismatch=false
    verbatim_pool_paths=()

    for arch in "${VALID_ARCHES[@]}"; do
        packages_url="${REPO_URL}/dists/${other_suite}/main/binary-${arch}/Packages"
        echo "  Fetching: ${packages_url}"

        packages_content=$(curl -sfL "${packages_url}" 2>/dev/null || true)

        if [[ -z "${packages_content}" ]]; then
            echo "  No Packages file for ${other_suite}/binary-${arch} (first deploy or not published)"
            continue
        fi

        # Parse one (Filename, Size, SHA256) triple per stanza. We download the
        # referenced .deb files for two reasons: (a) for a verbatim-mirrored suite,
        # the pool entries its served index references must exist under
        # ${OUTPUT_DIR}/pool/ so apt can fetch them — AND must match the index's
        # checksums, verified below; (b) for a non-verbatim suite (no live tree to
        # copy, or a demoted one) the debs feed the re-includedeb path (Step 4).
        while read -r filename size sha256; do
            [[ -n "${filename}" ]] || continue
            deb_url="${REPO_URL}/${filename}"
            deb_basename=$(basename "${filename}")

            # For a verbatim-mirrored suite, place the pool entry at the exact
            # path its Packages index references (Filename:) so apt resolves it.
            if [[ "${IS_VERBATIM["${other_suite}"]}" == "true" ]]; then
                pool_dest="${OUTPUT_DIR}/${filename}"
                if [[ ! -f "${pool_dest}" ]]; then
                    mkdir -p "$(dirname "${pool_dest}")"
                    if curl -sfL -o "${pool_dest}" "${deb_url}"; then
                        suite_count=$((suite_count + 1))
                    else
                        echo "  WARNING: Failed to download pool entry ${deb_basename}" >&2
                        rm -f "${pool_dest}"
                        # A referenced-but-unfetchable pool entry means the live
                        # suite is already inconsistent — heal it via re-export.
                        verbatim_mismatch=true
                        continue
                    fi
                fi
                # INTEGRITY: the served index must not lie about the pool bytes.
                actual_size=$(wc -c < "${pool_dest}" | tr -d '[:space:]')
                if [[ -n "${size}" && "${size}" != "${actual_size}" ]]; then
                    echo "  MISMATCH: ${other_suite}/${deb_basename} size ${actual_size} != index ${size}" >&2
                    verbatim_mismatch=true
                elif [[ -n "${sha256}" ]] && command -v sha256sum >/dev/null 2>&1; then
                    actual_sha=$(sha256sum "${pool_dest}" | awk '{print $1}')
                    if [[ "${sha256}" != "${actual_sha}" ]]; then
                        echo "  MISMATCH: ${other_suite}/${deb_basename} sha256 differs from index" >&2
                        verbatim_mismatch=true
                    fi
                fi
                verbatim_pool_paths+=("${pool_dest}")
                continue
            fi

            # Skip if already downloaded (same package may appear in both arch indices)
            if [[ -f "${other_dir}/${deb_basename}" ]]; then
                continue
            fi

            echo "  Downloading: ${deb_basename}"
            if curl -sfL -o "${other_dir}/${deb_basename}" "${deb_url}"; then
                suite_count=$((suite_count + 1))
            else
                echo "  WARNING: Failed to download ${deb_basename}, skipping" >&2
                rm -f "${other_dir}/${deb_basename}"
            fi
        done <<< "$(printf '%s\n' "${packages_content}" | awk '
            /^Filename:/ { fn=$2 }
            /^Size:/     { sz=$2 }
            /^SHA256:/   { sha=$2 }
            /^[[:space:]]*$/ { if (fn!="") print fn, sz, sha; fn=""; sz=""; sha="" }
            END { if (fn!="") print fn, sz, sha }')"
    done

    # HEAL: a verbatim suite whose published pool no longer matches its published
    # index cannot be served verbatim (that is exactly what ships the "unexpected
    # size" failure to clients). Demote it to the re-export path — regenerate its
    # index from the real pool bytes (reprepro includedeb + export in Step 4) and
    # re-sign it (Step 4b), reconciling the divergence in the same publish.
    if [[ "${IS_VERBATIM["${other_suite}"]}" == "true" && "${verbatim_mismatch}" == "true" ]]; then
        echo ">>> HEAL: '${other_suite}' signed index disagrees with the live pool — regenerating from pool (re-export, not verbatim)"
        IS_VERBATIM["${other_suite}"]=false
        # Drop the stale verbatim dists/ tree so reprepro can regenerate it.
        rm -rf "${OUTPUT_DIR}/dists/${other_suite}"
        # Feed the already-downloaded pool .debs into the re-export input dir.
        for pp in "${verbatim_pool_paths[@]}"; do
            [[ -f "${pp}" ]] || continue
            bn=$(basename "${pp}")
            [[ -f "${other_dir}/${bn}" ]] || cp "${pp}" "${other_dir}/${bn}"
        done
        # Re-derive suite_count from what is ACTUALLY staged for re-export. In the
        # verbatim path suite_count only counts fresh downloads, so a demoted suite
        # whose pool .debs were already present (placed by an earlier suite that
        # shares the same pool paths, e.g. two tracks shipping the same skopeo)
        # would carry suite_count=0 and be SKIPPED by the
        # Step 4 `-eq 0` gate, dropping the suite from the repo entirely. Count the
        # debs now in other_dir so the re-include actually runs.
        suite_count=$(find "${other_dir}" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
    fi

    OTHER_SUITE_COUNTS["${other_suite}"]=${suite_count}
    # Verbatim-mirrored suites are NOT counted toward total_other_count: that
    # counter gates the re-includedeb/re-export loop (Step 4), which must never
    # run for a suite we are serving verbatim. A demoted (healed) suite is now
    # non-verbatim, so it counts and Step 4 re-exports it from the pool.
    if [[ "${IS_VERBATIM["${other_suite}"]}" != "true" ]]; then
        total_other_count=$((total_other_count + suite_count))
    fi
    echo ">>> Processed ${suite_count} packages for '${other_suite}' suite"
    echo ""
done

# ============================================
# Step 3: Build current suite with repo_manage.sh
# ============================================

echo ">>> Building target suite(s) [${PUBLISH_TARGETS[*]}] with repo_manage.sh..."
echo ""

# POOL IMMUTABILITY (root-cause fix for the "unexpected size" bug). reprepro
# shares ONE pool across all suites, keyed by (source, version, arch) — the same
# .deb filename maps to the same pool path regardless of track. When two tracks
# ship the SAME version of a slow-moving component (e.g. skopeo/crun/pasta shared
# by the stable 6.x and v5 5.x lines), a freshly-compiled — and non-reproducible —
# rebuild of that version would OVERWRITE the shared pool .deb that another suite's
# already-signed index still checksums, desyncing that suite's metadata from the
# pool. An identical filename means an identical (source, version, arch), which in
# apt's model MUST be identical bytes; so if the pool already carries this exact
# package (placed by a verbatim mirror of an already-published suite in Step 2),
# adopt those published bytes instead of overwriting them. Done on a staged copy
# so the input artifact dir is never mutated.
canonicalize_debs_against_pool() {
    local lstage="$1" lout="$2"
    local ldeb lbase lpub
    [[ -d "${lout}/pool" ]] || return 0
    for ldeb in "${lstage}"/*.deb; do
        [[ -f "${ldeb}" ]] || continue
        lbase="$(basename "${ldeb}")"
        lpub="$(find "${lout}/pool" -type f -name "${lbase}" 2>/dev/null | head -1)"
        if [[ -n "${lpub}" ]] && ! cmp -s "${lpub}" "${ldeb}"; then
            echo "  pool-immutable: adopting already-published ${lbase} (keeps every suite's index in sync)"
            cp -f "${lpub}" "${ldeb}"
        fi
    done
}

STAGED_DEB_DIR="$(mktemp -d)"
cp "${DEB_DIR}"/*.deb "${STAGED_DEB_DIR}/"
canonicalize_debs_against_pool "${STAGED_DEB_DIR}" "${OUTPUT_DIR}"

# repo_manage.sh resolves the same (track, distro) into PUBLISH_TARGETS and
# feeds the (canonicalized) fresh .debs into the target suite itself.
"${toolpath}/scripts/repo_manage.sh" "${TRACK}" "${DISTRO}" "${STAGED_DEB_DIR}" "${OUTPUT_DIR}"
rm -rf "${STAGED_DEB_DIR}"

echo ""

# ============================================
# Step 4: Add other suites' packages (if any were downloaded)
# ============================================

if [[ ${total_other_count} -gt 0 ]]; then
    echo ">>> Adding other suites' packages to repository..."
    echo ""

    # Rebuild conf/ (repo_manage.sh cleans it up after running)
    mkdir -p "${OUTPUT_DIR}/conf"
    cp "${REPO_CONF}/conf/distributions" "${OUTPUT_DIR}/conf/"
    cp "${REPO_CONF}/conf/options" "${OUTPUT_DIR}/conf/"

    for other_suite in "${OTHER_SUITES[@]}"; do
        # A verbatim-mirrored suite is served as-is (its signed dists/ tree
        # was copied in Step 2). Never re-includedeb + re-export it — that would
        # regenerate its Release Date + signature on byte-identical content.
        if [[ "${IS_VERBATIM["${other_suite}"]:-false}" == "true" ]]; then
            echo ">>> '${other_suite}' served verbatim — skipping re-includedeb/re-export"
            continue
        fi

        suite_count=${OTHER_SUITE_COUNTS["${other_suite}"]}
        if [[ ${suite_count} -eq 0 ]]; then
            echo ">>> No packages for '${other_suite}' suite (first deploy or not published)"
            continue
        fi

        echo ">>> Adding '${other_suite}' suite packages..."
        other_added=0
        for deb_file in "${OTHER_SUITE_DEBS_DIRS["${other_suite}"]}"/*.deb; do
            if [[ -f "${deb_file}" ]]; then
                echo "  Adding: $(basename "${deb_file}")"
                reprepro -Vb "${OUTPUT_DIR}" includedeb "${other_suite}" "${deb_file}"
                other_added=$((other_added + 1))
            fi
        done
        echo ">>> Added ${other_added} packages to '${other_suite}' suite"

        # Export only this suite (not all — exporting all would clobber the current
        # suite's Packages file since the fresh db doesn't know about it)
        echo ">>> Exporting metadata for '${other_suite}' suite..."
        reprepro -b "${OUTPUT_DIR}" export "${other_suite}"
        echo ""
    done

    # Clean up reprepro internals
    rm -rf "${OUTPUT_DIR}/db" "${OUTPUT_DIR}/conf"
    echo ">>> Cleaned up reprepro internals"
    echo ""
else
    echo ">>> No packages for other suites (first deploy or no live repo)"
    echo ">>> Only the target suite(s) [${PUBLISH_TARGETS[*]}] will be published"
    echo ""
fi

# ============================================
# Step 4b: Acquire-By-Hash + re-sign every exported suite
# ============================================
# Run AFTER all exports (target suites via repo_manage.sh, other suites in the
# re-include loop) but BEFORE temp-dir cleanup. add_byhash_and_resign reads the
# exported dists/ tree and re-signs in place; the GPG key is already in the
# keyring from repo_manage.sh's import. Suites without a Release (none materialized
# yet) are a no-op inside the helper, but we guard here too for clear logging.

echo ">>> Applying Acquire-By-Hash + re-sign to all exported suites..."
for suite in "${ALL_SUITES[@]}"; do
    # Verbatim-mirrored suites already carry their original by-hash dirs
    # and signature from the live repo — re-signing them would defeat the
    # verbatim preservation (new Release Date + signature on unchanged content).
    if [[ "${IS_VERBATIM["${suite}"]:-false}" == "true" ]]; then
        echo "  preserved verbatim (no re-sign): ${suite}"
        continue
    fi
    if [[ -f "${OUTPUT_DIR}/dists/${suite}/Release" ]]; then
        echo "  by-hash + re-sign: ${suite}"
        add_byhash_and_resign "${suite}" "${OUTPUT_DIR}"
    fi
done
echo ">>> Acquire-By-Hash post-processing complete"
echo ""

# ============================================
# Step 4b2: No-drop gate — every mirrored suite must survive assembly
# ============================================
# A suite that HAD a live tree this run (preserved, verbatim, or demoted+healed)
# must still exist after assembly. If one vanished, the re-export path dropped a
# published suite — it would 404 for clients (worse than the stale index it was
# healing). Fail loudly rather than deploy a repo missing a suite. (The integrity
# gate below only inspects suites that EXIST, so it cannot catch a missing one.)
for s in "${MIRRORED_SUITES[@]}"; do
    if [[ ! -f "${OUTPUT_DIR}/dists/${s}/Release" ]]; then
        echo "ERROR: mirrored suite '${s}' vanished from the output — heal/re-export dropped it. Refusing to publish." >&2
        exit 1
    fi
done

# ============================================
# Step 4c: Integrity gate — index must match the pool it advertises
# ============================================
# The publish is only valid if every suite's signed metadata is internally
# consistent with the pool it was assembled over. This is the guardrail against
# the shared-pool overwrite class of bug (a suite's index advertising a Size/
# SHA256 that no longer matches the .deb in pool/). It runs over the FULL
# accumulating repo-output after this pass's exports + re-signs, so a mismatch
# aborts ci_publish (set -e) before anything is uploaded to Pages.
echo ">>> Verifying repository integrity (index <-> pool, Release <-> index)..."
"${toolpath}/scripts/verify_repo_integrity.sh" "${OUTPUT_DIR}"
echo ""

# Clean up all temp dirs
for other_suite in "${OTHER_SUITES[@]}"; do
    rm -rf "${OTHER_SUITE_DEBS_DIRS["${other_suite}"]}"
done

# ============================================
# Step 5: Generate index.html landing page
# ============================================

echo ">>> Generating index.html landing page..."
generate_index_html "${OUTPUT_DIR}" "${REPO_URL}"
echo ">>> index.html generated"
echo ""

# ============================================
# Step 6: Summary
# ============================================

echo "========================================"
echo ">>> CI Repository Build Complete"
echo "========================================"
echo ""
echo "Published:      ${PUBLISH_TARGETS[*]} (${deb_count} packages from build)"
for other_suite in "${OTHER_SUITES[@]}"; do
    echo "Mirrored suite: ${other_suite} (${OTHER_SUITE_COUNTS["${other_suite}"]} packages from live repo)"
done
echo "Suite universe: ${ALL_SUITES[*]}"
echo "Output:         ${OUTPUT_DIR}"
echo ""

# List contents to confirm structure
echo "Repository structure:"
echo "----------------------------------------"
for suite_name in "${PUBLISH_TARGETS[@]}" "${OTHER_SUITES[@]}"; do
    if [[ -d "${OUTPUT_DIR}/dists/${suite_name}" ]]; then
        echo "  dists/${suite_name}/"
        for f in "${OUTPUT_DIR}/dists/${suite_name}"/*; do
            if [[ -f "${f}" ]]; then
                echo "    $(basename "${f}")"
            elif [[ -d "${f}" ]]; then
                echo "    $(basename "${f}")/"
            fi
        done
    fi
done
if [[ -d "${OUTPUT_DIR}/pool" ]]; then
    echo "  pool/"
fi
if [[ -f "${OUTPUT_DIR}/podman-debian.gpg" ]]; then
    echo "  podman-debian.gpg"
fi
echo "----------------------------------------"
