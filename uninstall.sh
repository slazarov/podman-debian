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

# ============================================
# Manual File Cleanup
# ============================================

# Remove podman man pages (glob pattern)
for f in /usr/share/man/man1/podman*; do
    safe_rm_file "$f" "man page"
done 2>/dev/null || true

safe_rm_file "/usr/share/man/man5/quadlet.5" "man page"
safe_rm_file "/usr/share/man/man5/podman-systemd.unit.5" "man page"
safe_rm_file "/usr/share/man/man7/podman-rootless.7" "man page"
safe_rm_file "/usr/share/man/man7/podman-troubleshooting.7" "man page"

# Remove directories
safe_rm_dir "/var/lib/cni" "cni state"
safe_rm_dir "/usr/local/share/toolbox" "toolbox share"
safe_rm_file "/usr/local/share/zsh/site-functions/_toolbox" "zsh completion"

# Remove empty parent directories (using rmdir with ignore)
rmdir --ignore-fail-on-non-empty /usr/local/share/zsh/site-functions 2>/dev/null || true
rmdir --ignore-fail-on-non-empty /usr/local/share/zsh 2>/dev/null || true

# Remove local man pages (glob patterns)
for f in /usr/local/share/man/man1/buildah*; do
    safe_rm_file "$f" "man page"
done 2>/dev/null || true

for f in /usr/local/share/man/man1/crun*; do
    safe_rm_file "$f" "man page"
done 2>/dev/null || true

for f in /usr/local/share/man/man1/fuse-overlayfs*; do
    safe_rm_file "$f" "man page"
done 2>/dev/null || true

# Remove toolbox files
safe_rm_file "/usr/local/lib/tmpfiles.d/toolbox.conf" "tmpfiles config"
rmdir --ignore-fail-on-non-empty /usr/local/lib/tmpfiles.d 2>/dev/null || true

safe_rm_file "/usr/local/etc/containers/toolbox.conf" "toolbox config"
rmdir --ignore-fail-on-non-empty /usr/local/etc/containers 2>/dev/null || true
rmdir --ignore-fail-on-non-empty /usr/local/etc 2>/dev/null || true

safe_rm_file "/usr/local/bin/toolbox" "binary"
rmdir --ignore-fail-on-non-empty /usr/local/bin 2>/dev/null || true

# Remove podman libexec files
safe_rm_file "/usr/libexec/podman/quadlet" "binary"
safe_rm_file "/usr/libexec/podman/rootlessport" "binary"
safe_rm_dir "/usr/libexec/podman" "podman libexec"

# Remove binaries
safe_rm_file "/usr/local/bin/aardvark-dns" "binary"
safe_rm_file "/usr/local/bin/buildah" "binary"
safe_rm_file "/usr/local/bin/catatonit" "binary"
safe_rm_file "/usr/local/bin/crun" "binary"
safe_rm_file "/usr/local/bin/fuse-overlayfs" "binary"
safe_rm_file "/usr/local/bin/go" "binary"
safe_rm_file "/usr/local/bin/go-md2man" "binary"
safe_rm_file "/usr/local/bin/netavark" "binary"
safe_rm_file "/usr/local/bin/netavark-dhcp-proxy-client" "binary"
safe_rm_file "/usr/local/bin/passt" "binary"
safe_rm_file "/usr/local/bin/passt.avx2" "binary"
safe_rm_file "/usr/local/bin/pasta" "binary"
safe_rm_file "/usr/local/bin/pasta.avx2" "binary"
safe_rm_file "/usr/local/bin/protoc" "binary"
safe_rm_file "/usr/local/bin/sccache" "binary"

# Remove Go installation
safe_rm_dir "/opt/go" "go installation"

# Remove sccache cache
safe_rm_dir "/var/cache/sccache" "sccache cache"

# Remove Go build cache
safe_rm_dir "/var/cache/go-build" "Go build cache"
safe_rm_dir "/var/cache/go-mod" "Go module cache"

# Remove ccache cache
safe_rm_dir "/var/cache/ccache" "ccache cache"

# Remove configuration directories
safe_rm_dir "/etc/cni" "cni config"
safe_rm_dir "/etc/containers" "containers config"

# Remove systemd files (glob pattern)
for f in /usr/lib/systemd/system/podman*; do
    safe_rm_file "$f" "systemd unit"
done 2>/dev/null || true

# Remove package-managed binaries (these use dpkg check)
remove_if_user_installed "/usr/bin/podman"
remove_if_user_installed "/usr/bin/podman-remote"
remove_if_user_installed "/usr/bin/podmansh"

# ============================================
# Summary Output
# ============================================

echo ""
echo "========================================"
echo "Uninstall Summary"
echo "========================================"

if [[ ${#REMOVED[@]} -gt 0 ]]; then
    echo "Removed:"
    for item in "${REMOVED[@]}"; do
        echo "  - $item"
    done
else
    echo "Removed: (nothing)"
fi

echo ""

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "Skipped (not found or no target):"
    for item in "${SKIPPED[@]}"; do
        echo "  - $item"
    done
else
    echo "Skipped: (nothing)"
fi

echo ""
echo "========================================"
echo "Uninstall completed."
echo "========================================"
