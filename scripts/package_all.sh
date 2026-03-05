#!/bin/bash

# Abort on Error
set -euo pipefail

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# ============================================
# Configuration
# ============================================

NFPM_DIR="${toolpath}/packaging/nfpm"
OUTPUT_DIR="${toolpath}/output"

# Version suffix for all packages (~ ensures official packages upgrade over ours)
VERSION_SUFFIX="~podman1"

# ============================================
# Version Extraction
# ============================================

extract_version() {
    local tag="$1"
    local component="$2"

    case "$component" in
        pasta)
            # Date-based: already numeric (e.g., 20250302)
            echo "${tag}"
            ;;
        container-configs)
            # Namespaced tag: common/v0.67.0 -> 0.67.0
            echo "${tag}" | sed 's|^.*/v||'
            ;;
        *)
            # Standard: strip v prefix (v5.5.2 -> 5.5.2)
            echo "${tag#v}"
            ;;
    esac
}

# ============================================
# Prerequisite Validation
# ============================================

echo ""
echo "========================================"
echo ">>> Podman Debian Package Builder"
echo "========================================"
echo ""

# Check DESTDIR is set and exists
if [[ -z "${DESTDIR:-}" ]]; then
    echo "ERROR: DESTDIR environment variable is not set." >&2
    echo "  DESTDIR must point to a populated staging tree." >&2
    echo "  Example: export DESTDIR=/tmp/podman-staging" >&2
    exit 1
fi

if [[ ! -d "${DESTDIR}" ]]; then
    echo "ERROR: DESTDIR directory does not exist: ${DESTDIR}" >&2
    echo "  Run build scripts with DESTDIR set to populate the staging tree first." >&2
    exit 1
fi

# Check nfpm is available
if ! command -v nfpm &>/dev/null; then
    echo "ERROR: nfpm is not installed or not in PATH." >&2
    echo "  Install with: go install github.com/goreleaser/nfpm/v2/cmd/nfpm@v2.45.0" >&2
    exit 1
fi

# Check nFPM config directory exists with YAML files
if [[ ! -d "${NFPM_DIR}" ]]; then
    echo "ERROR: nFPM config directory not found: ${NFPM_DIR}" >&2
    exit 1
fi

yaml_count=$(find "${NFPM_DIR}" -name "*.yaml" -type f | wc -l)
if [[ "${yaml_count}" -eq 0 ]]; then
    echo "ERROR: No YAML config files found in ${NFPM_DIR}" >&2
    exit 1
fi

echo "DESTDIR:    ${DESTDIR}"
echo "ARCH:       ${ARCH}"
echo "nFPM dir:   ${NFPM_DIR}"
echo "Output dir: ${OUTPUT_DIR}"
echo ""

# ============================================
# Component Definitions
# ============================================

# Ordered list of components to package
COMPONENTS=(
    "podman"
    "crun"
    "conmon"
    "netavark"
    "aardvark-dns"
    "pasta"
    "fuse-overlayfs"
    "catatonit"
    "buildah"
    "skopeo"
    "toolbox"
    "container-configs"
)

# Component-to-tag mapping
# Tags are sourced from config.sh environment variables
declare -A COMPONENT_TAGS=(
    ["podman"]="${PODMAN_TAG}"
    ["crun"]="${CRUN_TAG}"
    ["conmon"]="${CONMON_TAG}"
    ["netavark"]="${NETAVARK_TAG}"
    ["aardvark-dns"]="${AARDVARK_DNS_TAG}"
    ["pasta"]=""
    ["fuse-overlayfs"]="${FUSE_OVERLAYFS_TAG}"
    ["catatonit"]="${CATATONIT_TAG}"
    ["buildah"]="${BUILDAH_TAG}"
    ["skopeo"]="${SKOPEO_TAG}"
    ["toolbox"]="${TOOLBOX_TAG}"
    ["container-configs"]="${CONTAINER_LIBS_TAG}"
)

# ============================================
# Create Output Directory
# ============================================

mkdir -p "${OUTPUT_DIR}"

# ============================================
# Package Components
# ============================================

package_count=0

for component in "${COMPONENTS[@]}"; do
    # Get tag for this component
    local_tag="${COMPONENT_TAGS[${component}]}"

    # Special case: pasta uses date-based version
    if [[ "${component}" == "pasta" ]]; then
        local_tag="$(date +"%Y%m%d")"
    fi

    # Validate tag is not empty
    if [[ -z "${local_tag}" ]]; then
        echo "ERROR: No version tag found for component: ${component}" >&2
        echo "  Ensure the corresponding *_TAG variable is set in config.sh or environment." >&2
        exit 1
    fi

    # Extract clean version and append suffix
    local_version="$(extract_version "${local_tag}" "${component}")${VERSION_SUFFIX}"

    echo ">>> Packaging: podman-${component} (${local_version})"

    # Export variables for nFPM env var substitution
    export VERSION="${local_version}"
    export ARCH="${ARCH}"
    export DESTDIR="${DESTDIR}"

    # Invoke nFPM
    nfpm pkg \
        --config "${NFPM_DIR}/${component}.yaml" \
        --target "${OUTPUT_DIR}" \
        --packager deb

    echo ">>> Done: podman-${component}"
    echo ""

    package_count=$((package_count + 1))
done

# ============================================
# Package Meta-Package (podman-suite)
# ============================================

# Use podman's version for the suite meta-package
suite_tag="${COMPONENT_TAGS["podman"]}"
suite_version="$(extract_version "${suite_tag}" "podman")${VERSION_SUFFIX}"

echo ">>> Packaging: podman-suite (${suite_version})"

export VERSION="${suite_version}"
export ARCH="${ARCH}"
export DESTDIR="${DESTDIR}"

nfpm pkg \
    --config "${NFPM_DIR}/suite.yaml" \
    --target "${OUTPUT_DIR}" \
    --packager deb

echo ">>> Done: podman-suite"
echo ""

package_count=$((package_count + 1))

# ============================================
# Summary
# ============================================

echo "========================================"
echo ">>> Packaging Complete"
echo "========================================"
echo ""
echo "Packages built: ${package_count}"
echo "Output directory: ${OUTPUT_DIR}"
echo ""

# List all .deb files with sizes
echo "Generated .deb files:"
echo "----------------------------------------"
for deb_file in "${OUTPUT_DIR}"/*.deb; do
    if [[ -f "${deb_file}" ]]; then
        file_size=$(du -h "${deb_file}" | cut -f1)
        file_name=$(basename "${deb_file}")
        echo "  ${file_name}  (${file_size})"
    fi
done
echo "----------------------------------------"
echo ""
echo "Total .deb files: $(find "${OUTPUT_DIR}" -name "*.deb" -type f | wc -l)"
