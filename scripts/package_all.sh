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

# VERSION_SUFFIX comes from config.sh (sourced above):
# ~deb${DISTRO_VERSION_ID}.podman${PACKAGE_REVISION}.

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
# Nightly Version Extraction
# ============================================
# For nightly builds (NIGHTLY_BUILD=true), extract the development version
# directly from source files instead of git tags. Appends ~~git{YYYYMMDD}.{sha}
# so nightly versions sort below tagged releases. The double tilde matters:
# with a single `~git` the nightly would sort above the tagged
# `{base}~deb{N}.podman{R}`, because dpkg compares `git` > `deb` letter by
# letter. `~~` sorts below any `~d...`.
#
# Args: component (string), repo_path (path to cloned repo)
# Output: version string like "5.9.0~~git20260306.abc1234", or "20260306~~gitabc1234" for pasta

extract_version_nightly() {
    local component="$1"
    local repo_path="$2"
    local base_version=""
    local datestamp
    local short_sha

    datestamp=$(date +%Y%m%d)
    short_sha=$(git -C "${repo_path}" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")

    case "${component}" in
        podman)
            base_version=$(grep 'RawVersion.*=' "${repo_path}/version/rawversion/version.go" \
                | sed 's/.*"\(.*\)".*/\1/' | sed 's/-dev//')
            ;;
        buildah)
            base_version=$(grep '^[[:space:]]*Version[[:space:]]*=' "${repo_path}/define/types.go" \
                | sed 's/.*"\(.*\)".*/\1/' | sed 's/-dev//')
            ;;
        skopeo)
            base_version=$(grep 'Version[[:space:]]*=' "${repo_path}/version/version.go" \
                | sed 's/.*"\(.*\)".*/\1/' | sed 's/-dev//')
            ;;
        netavark|aardvark-dns)
            base_version=$(grep '^version[[:space:]]*=' "${repo_path}/Cargo.toml" \
                | sed 's/.*"\(.*\)".*/\1/' | sed 's/-dev//')
            ;;
        conmon)
            base_version=$(cat "${repo_path}/VERSION" | tr -d '[:space:]')
            ;;
        fuse-overlayfs)
            if [[ -f "${repo_path}/Cargo.toml" ]]; then
                base_version=$(grep '^version[[:space:]]*=' "${repo_path}/Cargo.toml" \
                    | sed 's/.*"\(.*\)".*/\1/' | sed 's/-dev//')
            else
                base_version=$(grep 'AC_INIT' "${repo_path}/configure.ac" \
                    | sed 's/^[^[]*\[[^]]*\], *\[\([^]]*\)\].*/\1/' | sed 's/-dev//')
            fi
            ;;
        catatonit)
            base_version=$(grep 'AC_INIT' "${repo_path}/configure.ac" \
                | sed 's/^[^[]*\[[^]]*\], *\[\([^]]*\)\].*/\1/' | sed 's/+dev//')
            ;;
        crun)
            base_version=$(git -C "${repo_path}" describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")
            # Strip v prefix if present
            base_version="${base_version#v}"
            ;;
        toolbox)
            base_version=$(grep "version:" "${repo_path}/meson.build" \
                | head -1 | sed "s/.*version:[[:space:]]*'//" | sed "s/'.*//")
            # Normalize 2-part version to 3-part (e.g., 0.4 -> 0.4.0)
            if [[ "${base_version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                base_version="${base_version}.0"
            fi
            ;;
        container-configs)
            base_version=$(git -C "${repo_path}" tag --list 'common/*' --sort=-version:refname \
                | head -1 | sed 's|common/v||')
            ;;
        pasta)
            # pasta has no semver tags; use datestamp~~git<sha> so nightly versions
            # are always distinct from stable (plain datestamp) even on the same
            # calendar day — prevents reprepro pool collisions when nightly and
            # stable are published in the same CI day with different upstream commits.
            echo "${datestamp}~~git${short_sha}"
            return
            ;;
        *)
            echo "WARNING: Unknown component '${component}' for nightly version extraction" >&2
            base_version="0.0.0"
            ;;
    esac

    # Fallback if extraction failed
    if [[ -z "${base_version}" ]]; then
        base_version="0.0.0"
    fi

    echo "${base_version}~~git${datestamp}.${short_sha}"
}

# ============================================
# Unpinned Build: Auto-Detect Tags from Build Repos
# ============================================
# Fallback for any component whose TAG variable is empty in config.sh (e.g. a
# component left unpinned, or a track that does not materialize every tag).
# The build phase (setup.sh) already cloned repos and checked out a tag, so we
# resolve the empty tag by reading the checked-out tag from each component's
# git repository in BUILD_ROOT. The stable/v5 tracks pre-resolve every tag via
# scripts/resolve_versions.sh, so this path is normally exercised only by nightly.

# Map component names to their build directory names
# (most match 1:1 except these)
declare -A COMPONENT_BUILD_DIRS=(
    ["container-configs"]="container-libs"
    # build_pasta.sh clones passt.top/passt into BUILD_ROOT/passt; without this
    # the nightly ~~git<sha> lookup runs in a nonexistent dir -> "~~gitunknown".
    ["pasta"]="passt"
)

# Tag prefix filters for repos with namespaced tags (e.g., common/v0.67.0)
# Only used as a fallback when git describe can't find a tag at HEAD
declare -A COMPONENT_TAG_PREFIXES=(
    ["container-configs"]="common/"
)

resolve_tag_from_repo() {
    local component="$1"
    local build_dir="${component}"
    # Use override directory name if defined (e.g., container-configs -> container-libs)
    if [[ -v "COMPONENT_BUILD_DIRS[$component]" ]]; then
        build_dir="${COMPONENT_BUILD_DIRS[$component]}"
    fi
    local repo_path="${BUILD_ROOT}/${build_dir}"

    if [[ ! -d "${repo_path}/.git" ]]; then
        echo ""
        return
    fi

    # Read the tag that HEAD points to (set by git_checkout during build)
    local tag
    tag=$(git -C "${repo_path}" describe --tags --exact-match HEAD 2>/dev/null) || true

    if [[ -z "${tag}" ]]; then
        # Fallback: get the most recent tag reachable from HEAD
        tag=$(git -C "${repo_path}" describe --tags --abbrev=0 HEAD 2>/dev/null) || true
    fi

    if [[ -z "${tag}" ]]; then
        # Final fallback: list all tags sorted by version, optionally filtered by prefix
        # Needed for repos with namespaced tags (e.g., common/v0.67.0) or shallow clones
        # where git describe can't reach any tag from HEAD
        local prefix=""
        if [[ -v "COMPONENT_TAG_PREFIXES[$component]" ]]; then
            prefix="${COMPONENT_TAG_PREFIXES[$component]}"
        fi
        tag=$(git -C "${repo_path}" tag --list "${prefix}*" --sort=-version:refname | grep -v rc | head -1) || true
    fi

    echo "${tag}"
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

# Component maps (COMPONENT_BINARIES, INJECT_ONLY_DEPENDS) — shared with
# verify_depends.sh so the packaging and verification paths cannot drift.
source "${toolpath}/scripts/component_maps.sh"

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

    # Unpinned builds: auto-detect tag from build repo when not pre-resolved
    if [[ -z "${local_tag}" ]]; then
        local_tag="$(resolve_tag_from_repo "${component}")"
        if [[ -n "${local_tag}" ]]; then
            echo ">>> Auto-detected tag for ${component}: ${local_tag}"
            # Update the map so the suite meta-package can use it too
            COMPONENT_TAGS["${component}"]="${local_tag}"
        fi
    fi

    # Nightly builds: extract version from source files instead of tags
    if [[ "${NIGHTLY_BUILD:-false}" == "true" ]]; then
        build_dir="${component}"
        if [[ -v "COMPONENT_BUILD_DIRS[$component]" ]]; then
            build_dir="${COMPONENT_BUILD_DIRS[$component]}"
        fi
        local_version="$(extract_version_nightly "${component}" "${BUILD_ROOT}/${build_dir}")${VERSION_SUFFIX}"
    else
        # Validate tag is not empty
        if [[ -z "${local_tag}" ]]; then
            echo "ERROR: No version tag found for component: ${component}" >&2
            echo "  Ensure the corresponding *_TAG variable is set in config.sh or environment," >&2
            echo "  or that the build repo exists at ${BUILD_ROOT}/ with a checked-out tag." >&2
            exit 1
        fi

        # Extract clean version and append suffix
        local_version="$(extract_version "${local_tag}" "${component}")${VERSION_SUFFIX}"
    fi

    echo ">>> Packaging: podman-${component} (${local_version})"

    # Export variables and expand them in nFPM config
    # nFPM doesn't expand env vars in contents.src paths (Go glob is literal),
    # so we pre-process the YAML with envsubst
    export VERSION="${local_version}"
    export ARCH="${ARCH}"
    export DESTDIR="${DESTDIR}"

    # Derive this component's system-library depends from its shipped binaries.
    # detect_runtime_depends prints owning package names one-per-line; sed turns
    # that into a YAML list fragment (each line "  - pkgname", two-space indent).
    # Components with no native ELF binary get an empty fragment. No "|| true":
    # detect_runtime_depends returns 1 on any unmapped lib, which aborts the
    # build under set -euo pipefail + ERR trap.
    #
    # For inject-only components (crun/conmon/pasta) the fragment carries
    # its OWN `depends:` header, emitted only when there is at least one entry,
    # so a fully-static binary (empty detected set) yields no key at all instead
    # of a bare `depends:` with zero items.
    if [[ -v "COMPONENT_BINARIES[$component]" ]]; then
        component_bins=()
        for rel_bin in ${COMPONENT_BINARIES[$component]}; do
            component_bins+=("${DESTDIR}/${rel_bin}")
        done
        detected_items="$(detect_runtime_depends "${component_bins[@]}" | sed 's/^/  - /')"
        if [[ -v "INJECT_ONLY_DEPENDS[$component]" ]]; then
            if [[ -n "${detected_items}" ]]; then
                DETECTED_DEPENDS="depends:"$'\n'"${detected_items}"
            else
                DETECTED_DEPENDS=""
            fi
        else
            DETECTED_DEPENDS="${detected_items}"
        fi
    else
        DETECTED_DEPENDS=""
    fi
    export DETECTED_DEPENDS

    nfpm_config="$(mktemp)"
    envsubst '${VERSION} ${ARCH} ${DESTDIR} ${DETECTED_DEPENDS}' < "${NFPM_DIR}/${component}.yaml" > "${nfpm_config}"

    # pasta ships the AVX2 fast-path variants when the build staged them. They
    # can't be listed in pasta.yaml: nFPM aborts on a src glob that matches
    # zero files, and passt only builds passt.avx2/pasta.avx2 when the
    # compiler supports it. Append them to the rendered config only when
    # present. (Kept in sync with the allowlist in
    # scripts/verify_shipped_binaries.sh, which treats these as expected.)
    #
    # INVARIANT: this appends contents list items to the END of the rendered
    # file, which only lands them under `contents:` because `contents:` is the
    # last top-level key in pasta.yaml. Keep `contents:` last there, or move
    # these items under it explicitly.
    if [[ "${component}" == "pasta" ]]; then
        for avx2_bin in passt.avx2 pasta.avx2; do
            if [[ -f "${DESTDIR}/usr/bin/${avx2_bin}" ]]; then
                {
                    echo "  - src: \"${DESTDIR}/usr/bin/${avx2_bin}\""
                    echo "    dst: /usr/bin/${avx2_bin}"
                    echo "    file_info:"
                    echo "      mode: 0755"
                } >> "${nfpm_config}"
            fi
        done
    fi

    nfpm pkg \
        --config "${nfpm_config}" \
        --target "${OUTPUT_DIR}" \
        --packager deb
    rm -f "${nfpm_config}"

    echo ">>> Done: podman-${component}"
    echo ""

    package_count=$((package_count + 1))
done

# ============================================
# Package Meta-Package (podman-suite)
# ============================================

# Use podman's version for the suite meta-package
if [[ "${NIGHTLY_BUILD:-false}" == "true" ]]; then
    build_dir="podman"
    if [[ -v "COMPONENT_BUILD_DIRS[podman]" ]]; then
        build_dir="${COMPONENT_BUILD_DIRS[podman]}"
    fi
    suite_version="$(extract_version_nightly "podman" "${BUILD_ROOT}/${build_dir}")${VERSION_SUFFIX}"
else
    suite_tag="${COMPONENT_TAGS["podman"]}"
    suite_version="$(extract_version "${suite_tag}" "podman")${VERSION_SUFFIX}"
fi

echo ">>> Packaging: podman-suite (${suite_version})"

export VERSION="${suite_version}"
export ARCH="${ARCH}"
export DESTDIR="${DESTDIR}"

suite_config="$(mktemp)"
envsubst '${VERSION} ${ARCH} ${DESTDIR}' < "${NFPM_DIR}/suite.yaml" > "${suite_config}"

nfpm pkg \
    --config "${suite_config}" \
    --target "${OUTPUT_DIR}" \
    --packager deb
rm -f "${suite_config}"

echo ">>> Done: podman-suite"
echo ""

package_count=$((package_count + 1))

# ============================================
# Packaging-completeness guardrail (non-fatal)
# ============================================
# Warn if the build staged any binary that no manifest packages — the class of
# silent drop that hid passt's `pesto` for so long. Never abort packaging: a new
# upstream binary is a heads-up, not a build failure.
if [[ -x "${toolpath}/scripts/verify_shipped_binaries.sh" ]]; then
    "${toolpath}/scripts/verify_shipped_binaries.sh" || true
fi

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
