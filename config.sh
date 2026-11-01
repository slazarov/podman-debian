#!/bin/bash

# Prevent recursive sourcing (not exported — child processes must source independently)
[[ -n "${_CONFIG_SH_SOURCED:-}" ]] && return 0
_CONFIG_SH_SOURCED=1

# Determine toolpath if not set already
relativepath="./" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}"); fi

# Source functions (includes detect_architecture)
source "${toolpath}/functions.sh"

# ============================================
# Architecture Detection
# ============================================

# Allow override via environment variable, otherwise detect.
# Only amd64 is built and published.
export ARCH="${ARCH:-$(detect_architecture)}"

case "$ARCH" in
    amd64)
        export GOARCH="amd64"
        export PROTOC_ARCH="x86_64"
        export RUSTUP_ARCH="x86_64-unknown-linux-gnu"
        export SCCACHE_ARCH="x86_64-unknown-linux-musl"
        ;;
    *)
        echo "ERROR: Unsupported ARCH '${ARCH}'. Supported: amd64" >&2
        exit 1
        ;;
esac

echo "Architecture: ${ARCH} (Go: ${GOARCH}, Protoc: ${PROTOC_ARCH}, Rust: ${RUSTUP_ARCH})"

# ============================================
# Supported Distros and Repository Suites
# ============================================

# The one place the supported Debian releases are listed. Each label is the
# release codename and is used in suite names ({track}-{label}), CI artifact
# names and cache keys. DISTRO_VERSION_IDS maps a label to the VERSION_ID in
# /etc/os-release, which also forms the version suffix (~deb12, ~deb13).
# DISTRO_IMAGES maps a label to the container image used for CI builds and
# smoke tests. VALID_ARCHES is the list of architectures whose Packages
# indexes ci_publish.sh mirrors and check_republish_needed.sh compares. The
# CI matrix, packaging/repo/conf/distributions, the index page and the arch
# maps in config.sh hard-code amd64, so adding an architecture means changing
# those too.
#
# Arrays are not exported (bash cannot export arrays). Child scripts source
# config.sh themselves. Standalone scripts (smoke tests, the republish guard)
# and the tests read only this block, with
#   sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' config.sh
# so keep it free of side effects and keep those two lines as they are.
VALID_TRACKS=(stable v5 nightly)
VALID_ARCHES=(amd64)
VALID_DISTROS=(bookworm trixie)
declare -gA DISTRO_VERSION_IDS=([bookworm]=12 [trixie]=13)
declare -gA DISTRO_IMAGES=([bookworm]=docker.io/library/debian:bookworm [trixie]=docker.io/library/debian:trixie)
ALL_SUITES=()
for _distro in "${VALID_DISTROS[@]}"; do
    for _track in "${VALID_TRACKS[@]}"; do
        ALL_SUITES+=("${_track}-${_distro}")
    done
done
unset _distro _track

# is_valid_suite <suite> -- returns 0 if <suite> is one of ALL_SUITES, else
# prints an error to stderr and returns 1.
is_valid_suite() {
    local lsuite="$1"
    local lcandidate
    for lcandidate in "${ALL_SUITES[@]}"; do
        [[ "${lsuite}" == "${lcandidate}" ]] && return 0
    done
    echo "ERROR: Invalid suite '${lsuite}'. Must be one of: ${ALL_SUITES[*]}" >&2
    return 1
}

# resolve_publish_targets <track> <distro> -- prints the reprepro suite that
# a (track, distro) pair publishes to, "<track>-<distro>". Prints an error to
# stderr and returns 1 if the track is not in VALID_TRACKS or the distro is
# not in VALID_DISTROS. The output is one suite per line so callers can read
# it with mapfile.
resolve_publish_targets() {
    local ltrack="$1"
    local ldistro="$2"
    local lvalid
    local lok

    lok=false
    for lvalid in "${VALID_TRACKS[@]}"; do
        [[ "${ltrack}" == "${lvalid}" ]] && lok=true && break
    done
    if [[ "${lok}" != "true" ]]; then
        echo "ERROR: Invalid track '${ltrack}'. Must be one of: ${VALID_TRACKS[*]}" >&2
        return 1
    fi

    lok=false
    for lvalid in "${VALID_DISTROS[@]}"; do
        [[ "${ldistro}" == "${lvalid}" ]] && lok=true && break
    done
    if [[ "${lok}" != "true" ]]; then
        echo "ERROR: Invalid distro '${ldistro}'. Must be one of: ${VALID_DISTROS[*]}" >&2
        return 1
    fi

    printf '%s\n' "${ltrack}-${ldistro}"
}

# ============================================
# Distro Identity and Version Suffix
# ============================================

# detect_distro_version_id honors the DISTRO override (codename or VERSION_ID),
# else reads /etc/os-release, else fails. A detection failure stops config
# loading, the same as an unsupported ARCH. Assign before export so the exit
# status is not masked.
DISTRO_VERSION_ID="$(detect_distro_version_id)" || exit 1
DISTRO_LABEL="$(distro_label_for_version_id "${DISTRO_VERSION_ID}")" || exit 1
export DISTRO_VERSION_ID DISTRO_LABEL

# Version suffix ~deb{VERSION_ID}.podman{N}. The tilde sorts it below the bare
# upstream version, the numeric VERSION_ID orders bookworm < trixie, and N is
# the packaging revision (see scripts/package_revision.sh for when to bump it).
# scripts/verify_versions.sh checks these orderings with dpkg.
source "${toolpath}/scripts/package_revision.sh"
export VERSION_SUFFIX="~deb${DISTRO_VERSION_ID}.podman${PACKAGE_REVISION}"

echo "Distro: Debian ${DISTRO_VERSION_ID} (${DISTRO_LABEL}, version suffix: ${VERSION_SUFFIX})"

# ============================================
# Build Optimization Settings
# ============================================

# Parallel job count for make/cargo builds
# Default: number of CPU cores
export NPROC="${NPROC:-$(nproc)}"

# Shallow clone for git repositories (reduces network transfer ~95%)
# Set to "false" to disable (e.g., for development/debugging)
export SHALLOW_CLONE="${SHALLOW_CLONE:-true}"

# ============================================
# Rust/Cargo Build Optimization
# ============================================

# Parallel job count for cargo builds (defaults to NPROC)
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$NPROC}"

# Optional: Enable sccache for Rust build caching (50-90% rebuild speedup)
# Set to "true" to enable: export SCCACHE_ENABLED=true
export SCCACHE_ENABLED="${SCCACHE_ENABLED:-false}"

# sccache version and cache directory (only used if SCCACHE_ENABLED=true)
export SCCACHE_VERSION="${SCCACHE_VERSION:-0.14.0}"
export SCCACHE_DIR="${SCCACHE_DIR:-/var/cache/sccache}"

# ============================================
# C/C++ Build Optimization
# ============================================

# Optional: Enable ccache for C build caching (30x faster warm-cache rebuilds)
# Set to "true" to enable: export CCACHE_ENABLED=true
export CCACHE_ENABLED="${CCACHE_ENABLED:-false}"

# ccache cache directory and max size (only used if CCACHE_ENABLED=true)
export CCACHE_DIR="${CCACHE_DIR:-/var/cache/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"

# Hash compiler binary content for correct cache invalidation on GCC upgrades
export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"

# ============================================
# Linker Optimization
# ============================================

# Optional: Enable mold linker for Rust builds (5-10x faster linking)
# Set to "true" to enable: export MOLD_ENABLED=true
# Note: Requires clang as linker driver (installed automatically with mold)
export MOLD_ENABLED="${MOLD_ENABLED:-false}"

# ============================================
# Go Build Optimization
# ============================================

# Go compiler optimization flags for faster builds
# -gcflags='-c=16': Parallel compilation within Go compiler (~25% faster)
# -ldflags='-s -w': Strip debug symbols for smaller binaries
# GOGC=off: Disable GC during compilation (~30% faster, uses ~2.5x RAM)
export GO_GCFLAGS="${GO_GCFLAGS:--c=16}"
export GO_LDFLAGS="${GO_LDFLAGS:--s -w}"

# Disable Go GC during compilation for speed (uses more RAM)
# Set to empty string to re-enable: export GOGC_BUILD=""
export GOGC_BUILD="${GOGC_BUILD:-off}"

# Persist Go build cache across component builds (20x faster rebuilds)
# Go components share ~80% of their module graph - cached once, reused by all
export GOCACHE="${GOCACHE:-/var/cache/go-build}"
export GOMODCACHE="${GOMODCACHE:-/var/cache/go-mod}"

# Create cache directories (may fail as non-root if using /var/cache paths;
# the build step runs as root and creates these, packaging step only reads config)
mkdir -p "${GOCACHE}" "${GOMODCACHE}" 2>/dev/null || true

# ============================================
# Build Paths
# ============================================

# Build Root
export BUILD_ROOT="${toolpath}/build"

# Go Root Folder
export GO_ROOT_FOLDER="/opt/go"

# Go Version and Path
#export GOVERSION="1.22.6"
#export GOTAG="go${GOVERSION}"
#export GOPATH="/opt/go/${GOVERSION}/bin"
#export GOROOT="/opt/go/${GOVERSION}"

#export GOVERSION="1.23.3"
#export GOTAG="go${GOVERSION}"
#export GOPATH="/opt/go/${GOVERSION}/bin"
#export GOROOT="/opt/go/${GOVERSION}"

# Auto-detect Go version from Podman's go.mod (source of truth)
if [[ -z "${GOVERSION:-}" ]]; then
    export GOVERSION=$(get_required_go_version "${PODMAN_TAG:-}")
fi
export GOPATH="/opt/go/${GOVERSION}/bin"
export GOROOT="/opt/go/${GOVERSION}"

# Auto-detect Rust version from Netavark's Cargo.toml (source of truth)
if [[ -z "${RUST_VERSION:-}" ]]; then
    export RUST_VERSION=$(get_required_rust_version "${NETAVARK_TAG:-}")
fi

# Podman Version
#export PODMAN_VERSION="5.5.2"
#export PODMAN_TAG="v${PODMAN_VERSION}"
export PODMAN_TAG="${PODMAN_TAG:-}"

# Buildah Version
#export BUILDAH_VERSION="1.40.1"
#export BUILDAH_TAG="v${BUILDAH_VERSION}"
export BUILDAH_TAG="${BUILDAH_TAG:-}"

# Crun Version
#export CRUN_VERSION="1.25.1"
#export CRUN_TAG="${CRUN_VERSION}"
export CRUN_TAG="${CRUN_TAG:-}"

# Conmon Version
#export CONMON_VERSION="2.1.13"
#export CONMON_TAG="v${CONMON_VERSION}"
export CONMON_TAG="${CONMON_TAG:-}"

# Netavark Version
#export NETAVARK_VERSION="1.15.2"
#export NETAVARK_TAG="v${NETAVARK_VERSION}"
export NETAVARK_TAG="${NETAVARK_TAG:-}"

# Aardvark-DNS Version
#export AARDVARK_DNS_VERSION="1.15.0"
#export AARDVARK_DNS_TAG="v${AARDVARK_DNS_VERSION}"
export AARDVARK_DNS_TAG="${AARDVARK_DNS_TAG:-}"

# Skopeo Version
#export SKOPEO_VERSION="1.19.0"
#export SKOPEO_TAG="v${SKOPEO_VERSION}"
export SKOPEO_TAG="${SKOPEO_TAG:-}"

# GoMD2Man Version
#export GOMD2MAN_VERSION="2.0.7"
#export GOMD2MAN_TAG="v${GOMD2MAN_VERSION}"
export GOMD2MAN_TAG="${GOMD2MAN_TAG:-}"

# Toolbox Version
#export TOOLBOX_VERSION="0.1.2"
#export TOOLBOX_TAG="${TOOLBOX_VERSION}"
export TOOLBOX_TAG="${TOOLBOX_TAG:-}"

# Fuse-OverlayFS Version
export FUSE_OVERLAYFS_TAG="${FUSE_OVERLAYFS_TAG:-}"

# Catatonit Version
export CATATONIT_TAG="${CATATONIT_TAG:-}"

# Container-Libs Version (containers-common config files and seccomp.json)
# Note: container-libs uses namespaced tags: common/vX.Y.Z, image/vX.Y.Z, storage/vX.Y.Z
# For seccomp.json builds, use a common/ tag (e.g., common/v0.67.0)
export CONTAINER_LIBS_TAG="${CONTAINER_LIBS_TAG:-}"

# Protoc Version and Path
#export PROTOC_VERSION="33.1"
#export PROTOC_TAG="v${PROTOC_VERSION}"

# Auto-detect latest protoc version if not specified
if [[ -z "${PROTOC_VERSION:-}" ]]; then
    export PROTOC_VERSION=$(get_latest_protoc_version)
fi
# Derive PROTOC_TAG from PROTOC_VERSION if not already set
if [[ -z "${PROTOC_TAG:-}" ]]; then
    export PROTOC_TAG="v${PROTOC_VERSION}"
fi
export PROTOC_ROOT_FOLDER="/opt/protoc"
export PROTOC_PATH="${PROTOC_ROOT_FOLDER}/${PROTOC_VERSION}/bin/protoc"

# Create Build Folder Root
mkdir -p "${BUILD_ROOT}"
