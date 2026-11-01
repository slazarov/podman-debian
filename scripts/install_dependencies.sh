#!/bin/bash

# Strict Mode - Exit on error, undefined vars, pipe failures
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

# Change Folder to Build Root
cd "${BUILD_ROOT}" || exit

# dependency_packages <distro-label> -- print the build dependencies for a
# supported Debian release, one per line. Kept as a function so the list can
# be checked without installing anything:
#   apt-get install --dry-run $(dependency_packages bookworm)
dependency_packages() {
    local ldistro="$1"

    # Core build dependencies.
    printf '%s\n' \
        gettext-base \
        git \
        iptables \
        libapparmor-dev \
        libassuan-dev \
        libbtrfs-dev \
        libc6-dev \
        libdevmapper-dev \
        libglib2.0-dev \
        libgpgme-dev \
        libgpg-error-dev \
        libprotobuf-dev \
        libprotobuf-c-dev \
        libseccomp-dev \
        libselinux1-dev \
        libsystemd-dev \
        make \
        pkg-config \
        uidmap \
        wget

    # crun
    printf '%s\n' \
        gcc build-essential pkgconf libtool \
        libcap-dev libjson-c-dev libyajl-dev \
        autoconf python3 automake

    # fuse-overlayfs
    printf '%s\n' libfuse3-dev

    # toolbox. bash-completion: toolbox's meson build only generates and
    # installs its bash completions when the bash-completion pkg-config file
    # is present (bare containers do not have it), and
    # packaging/nfpm/toolbox.yaml globs usr/share/bash-completion/completions/toolbox*.
    printf '%s\n' libsubid-dev meson codespell cmake bash-completion

    # systemd.pc (used by meson and the Makefiles to find the unit
    # directories) is in the systemd package on bookworm and was split out
    # into systemd-dev on trixie.
    case "${ldistro}" in
        bookworm) printf '%s\n' systemd ;;
        *) printf '%s\n' systemd-dev ;;
    esac

    # protoc download
    printf '%s\n' unzip ca-certificates curl

    # Optional: ccache for C build caching (when CCACHE_ENABLED=true)
    if [[ "${CCACHE_ENABLED:-false}" == "true" ]]; then
        printf '%s\n' ccache
    fi

    # Optional: mold linker for faster Rust linking (when MOLD_ENABLED=true)
    if [[ "${MOLD_ENABLED:-false}" == "true" ]]; then
        printf '%s\n' mold clang
    fi
}

mapfile -t packages < <(dependency_packages "${DISTRO_LABEL}")
apt-get install -y "${packages[@]}"

if [[ "${CCACHE_ENABLED:-false}" == "true" ]]; then
    mkdir -p "${CCACHE_DIR:-/var/cache/ccache}"
fi
