#!/bin/bash

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

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# ============================================
# Usage and Argument Parsing
# ============================================

usage() {
    echo "Usage: $(basename "$0") <track> <distro> <deb-directory> [output-directory]"
    echo ""
    echo "  track            Release track: 'stable', 'v5', or 'nightly'"
    echo "  distro           Target distro: one of ${VALID_DISTROS[*]}"
    echo "  deb-directory    Path containing .deb files to add"
    echo "  output-directory Where to create the repository (default: \${toolpath}/repo-output)"
    echo ""
    echo "  The (track, distro) pair is resolved to its publish target, the"
    echo "  '<track>-<distro>' suite, via resolve_publish_targets (config.sh)."
    echo ""
    echo "Environment variables:"
    echo "  GPG_PRIVATE_KEY  If set, imports this GPG key before signing (for CI)"
    exit 1
}

if [[ $# -lt 3 ]]; then
    usage
fi

TRACK="$1"
DISTRO="$2"
DEB_DIR="$3"
OUTPUT_DIR="${4:-${toolpath}/repo-output}"

REPO_CONF="${toolpath}/packaging/repo"

# ============================================
# Validate Arguments
# ============================================

echo ""
echo "========================================"
echo ">>> APT Repository Manager"
echo "========================================"
echo ""

# Resolve publish targets via the routing helper in config.sh. This validates
# track and distro (exits non-zero on bad input) and yields the
# '<track>-<distro>' suite.
mapfile -t PUBLISH_TARGETS < <(resolve_publish_targets "${TRACK}" "${DISTRO}")
# resolve_publish_targets runs in a subshell (process substitution), so its
# non-zero exit on a bad track/distro cannot abort us directly; an invalid pair
# yields zero targets. Treat that as a hard error (its stderr message already
# explains which value was rejected).
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

echo "Track:      ${TRACK}"
echo "Distro:     ${DISTRO}"
echo "Targets:    ${PUBLISH_TARGETS[*]}"
echo "DEB dir:    ${DEB_DIR} (${deb_count} packages)"
echo "Output dir: ${OUTPUT_DIR}"
echo ""

# ============================================
# GPG Key Import (CI Support)
# ============================================

if [[ -n "${GPG_PRIVATE_KEY:-}" ]]; then
    echo ">>> Importing GPG private key from environment..."
    # Try base64-encoded first (recommended for CI), then raw ASCII-armored
    if echo "${GPG_PRIVATE_KEY}" | base64 -d 2>/dev/null | gpg --batch --import 2>/dev/null; then
        echo "  (imported from base64-encoded key)"
    elif printf '%s' "${GPG_PRIVATE_KEY}" | gpg --batch --import; then
        echo "  (imported from ASCII-armored key)"
    else
        echo "ERROR: Failed to import GPG key. Store secret as:" >&2
        echo "  gpg --export-secret-keys --armor KEY_ID | base64 -w0" >&2
        exit 1
    fi

    # Set ownertrust to ultimate to avoid "not ultimately trusted" warnings
    GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
    echo "${GPG_KEY_ID}:6:" | gpg --batch --import-ownertrust

    echo ">>> GPG key imported: ${GPG_KEY_ID}"
    echo ""
else
    # Verify at least one secret key exists in the keyring
    if ! gpg --list-secret-keys --with-colons 2>/dev/null | grep -q "^sec:"; then
        echo "ERROR: No GPG secret key found in keyring." >&2
        echo "  Either set GPG_PRIVATE_KEY environment variable (for CI)" >&2
        echo "  or import a key manually: gpg --import <private-key-file>" >&2
        exit 1
    fi
    echo ">>> Using existing GPG key from keyring"
    echo ""
fi

# ============================================
# Prepare Reprepro Base Directory
# ============================================

echo ">>> Preparing repository structure..."

mkdir -p "${OUTPUT_DIR}/conf"
cp "${REPO_CONF}/conf/distributions" "${OUTPUT_DIR}/conf/"
cp "${REPO_CONF}/conf/options" "${OUTPUT_DIR}/conf/"

echo ">>> Configuration copied to ${OUTPUT_DIR}/conf/"
echo ""

# ============================================
# Add Packages via Reprepro
# ============================================

echo ">>> Adding packages to target suites: ${PUBLISH_TARGETS[*]}..."
echo ""

package_count=0

# One fresh .deb set, fed into every target suite. reprepro's shared pool
# dedups an identical .deb across suites, so no special handling is needed.
for deb_file in "${DEB_DIR}"/*.deb; do
    if [[ -f "${deb_file}" ]]; then
        echo "  Adding: $(basename "${deb_file}")"
        for target in "${PUBLISH_TARGETS[@]}"; do
            reprepro -Vb "${OUTPUT_DIR}" includedeb "${target}" "${deb_file}"
        done
        package_count=$((package_count + 1))
    fi
done

echo ""
echo ">>> Added ${package_count} packages to ${#PUBLISH_TARGETS[@]} target suite(s)"
echo ""

# ============================================
# Export Metadata (Generates InRelease + Release.gpg)
# ============================================

echo ">>> Exporting repository metadata (per target suite)..."
# Export each populated target explicitly. A bare `reprepro export` would also
# emit empty indexes for the other configured distributions, risking clobbering
# of suites this run did not populate.
for target in "${PUBLISH_TARGETS[@]}"; do
    reprepro -b "${OUTPUT_DIR}" export "${target}"
done
echo ">>> Metadata exported (InRelease + Release.gpg) for: ${PUBLISH_TARGETS[*]}"
echo ""

# ============================================
# Copy Public GPG Key to Repository Root
# ============================================

echo ">>> Publishing GPG public key..."

if [[ -f "${REPO_CONF}/pubkey.gpg" ]]; then
    cp "${REPO_CONF}/pubkey.gpg" "${OUTPUT_DIR}/podman-debian.gpg"
    echo ">>> Copied pubkey.gpg from packaging/repo/"
else
    # Export from keyring
    GPG_KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
    gpg --export "${GPG_KEY_ID}" > "${OUTPUT_DIR}/podman-debian.gpg"
    echo ">>> Exported public key from keyring: ${GPG_KEY_ID}"
fi

echo ""

# ============================================
# Cleanup Reprepro Internals
# ============================================

echo ">>> Cleaning up reprepro internals..."
rm -rf "${OUTPUT_DIR}/db"
rm -rf "${OUTPUT_DIR}/conf"
echo ">>> Removed db/ and conf/ (not needed for serving)"
echo ""

# ============================================
# Summary
# ============================================

echo "========================================"
echo ">>> Repository Build Complete"
echo "========================================"
echo ""
echo "Track:          ${TRACK}"
echo "Distro:         ${DISTRO}"
echo "Target suites:  ${PUBLISH_TARGETS[*]}"
echo "Packages added: ${package_count}"
echo "Output:         ${OUTPUT_DIR}"
echo ""

# List contents to confirm structure
echo "Repository structure:"
echo "----------------------------------------"
for target in "${PUBLISH_TARGETS[@]}"; do
    if [[ -d "${OUTPUT_DIR}/dists/${target}" ]]; then
        echo "  dists/${target}/"
        for f in "${OUTPUT_DIR}/dists/${target}"/*; do
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
