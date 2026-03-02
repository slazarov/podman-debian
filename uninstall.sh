#!/bin/bash

# Non-Interactive Mode - MUST be set before ANY apt commands
export DEBIAN_FRONTEND=noninteractive

# Strict Mode - Exit on error, undefined vars, pipe failures
set -euo pipefail

# Determine toolpath if not set already
relativepath="./" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# ============================================
# Uninstall Tracking
# ============================================

declare -a REMOVED=()
declare -a SKIPPED=()

# Safe directory removal with tracking
safe_rm_dir() {
    local dir="$1"
    local description="$2"
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        REMOVED+=("$description: $dir")
    else
        SKIPPED+=("$description: $dir (not found)")
    fi
}

# Safe file removal with tracking
safe_rm_file() {
    local file="$1"
    local description="$2"
    if [[ -f "$file" ]]; then
        rm -f "$file"
        REMOVED+=("$description: $file")
    else
        SKIPPED+=("$description: $file (not found)")
    fi
}

# Safe make uninstall with tracking
safe_make_uninstall() {
    local dir="$1"
    local component="$2"
    if [[ -d "$dir" ]]; then
        cd "$dir" || true
        if make uninstall 2>/dev/null; then
            REMOVED+=("make uninstall: $component")
        else
            SKIPPED+=("make uninstall: $component (no target or failed)")
        fi
    else
        SKIPPED+=("build directory: $dir ($component)")
    fi
}

# Uninstall AardvarkDNS
safe_make_uninstall "${BUILD_ROOT}/aardvark-dns" "aardvark-dns"

# Uninstall Buildah
safe_make_uninstall "${BUILD_ROOT}/buildah" "buildah"

# Uninstall Catatonit
safe_make_uninstall "${BUILD_ROOT}/catatonit" "catatonit"

# Uninstall CRUN
safe_make_uninstall "${BUILD_ROOT}/crun" "crun"

# Uninstall Fuse-OverlayFS
safe_make_uninstall "${BUILD_ROOT}/fuse-overlayfs" "fuse-overlayfs"

# Uninstall Netavark
safe_make_uninstall "${BUILD_ROOT}/netavark" "netavark"

# Uninstall Pasta
safe_make_uninstall "${BUILD_ROOT}/passt" "passt"

# Uninstall Podman
safe_make_uninstall "${BUILD_ROOT}/podman" "podman"

# Uninstall slirp4netns
safe_make_uninstall "${BUILD_ROOT}/slirp4netns" "slirp4netns"

# Uninstall RUNC
safe_make_uninstall "${BUILD_ROOT}/runc" "runc"

# Perform the remaining of the Uninstall manually
rm -f /usr/share/man/man1/podman*
rm -f /usr/share/man/man5/quadlet.5
rm -f /usr/share/man/man5/podman-systemd.unit.5
rm -f /usr/share/man/man7/podman-rootless.7
rm -f /usr/share/man/man7/podman-troubleshooting.7
rm -rf /var/lib/cni
rm -rf /usr/local/share/toolbox
rm -rf /usr/local/share/zsh/site-functions/_toolbox
rmdir --ignore-fail-on-non-empty /usr/local/share/zsh/site-functions
rmdir --ignore-fail-on-non-empty /usr/local/share/zsh
rm -f /usr/local/share/man/man1/buildah*
rm -f /usr/local/share/man/man1/crun*
rm -f /usr/local/share/man/man1/fuse-overlayfs*
rm -f /usr/local/share/man/man1/slirp4netns*
rm -f /usr/local/bin/runc

rm -f /usr/local/lib/tmpfiles.d/toolbox.conf
rmdir --ignore-fail-on-non-empty /usr/local/lib/tmpfiles.d
rm -f /usr/local/etc/containers/toolbox.conf
rmdir --ignore-fail-on-non-empty /usr/local/etc/containers
rmdir --ignore-fail-on-non-empty /usr/local/etc

rm -f /usr/local/bin/toolbox
rmdir --ignore-fail-on-non-empty /usr/local/bin

rm -f /usr/libexec/podman/quadlet
rm -f /usr/libexec/podman/rootlessport
rm -rf /usr/libexec/podman

rm -f /usr/local/bin/aardvark-dns
rm -f /usr/local/bin/buildah
rm -f /usr/local/bin/catatonit
rm -f /usr/local/bin/crun
rm -f /usr/local/bin/fuse-overlayfs
rm -f /usr/local/bin/go
rm -f /usr/local/bin/go-md2man
rm -f /usr/local/bin/netavark
rm -f /usr/local/bin/netavark-dhcp-proxy-client
rm -f /usr/local/bin/passt
rm -f /usr/local/bin/passt.avx2
rm -f /usr/local/bin/pasta
rm -f /usr/local/bin/pasta.avx2
rm -f /usr/local/bin/protoc
rm -f /usr/local/bin/runc

rm -rf /opt/go/*

rm -rf /etc/cni

rm -rf /etc/containers

rm -f /usr/lib/systemd/system/podman*

remove_if_user_installed "/usr/bin/podman"
remove_if_user_installed "/usr/bin/podman-remote"
remove_if_user_installed "/usr/bin/podmansh"
