#!/bin/bash
# Pre-flight Validation Script for Podman Rootless Installation
# Validates system requirements before build operations begin

# Strict Mode
set -euo pipefail

# Determine toolpath if not set (standalone execution support)
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}")
fi

# ============================================
# Color Definitions for Output
# ============================================

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# ============================================
# Counter Variables
# ============================================

ERRORS=0
WARNINGS=0

# ============================================
# Output Helper Functions
# ============================================

preflight_error() {
    # Arguments: code, message, current, required, fix
    local code="$1"
    local message="$2"
    local current="$3"
    local required="$4"
    local fix="$5"

    echo -e "${RED}[ERROR] ${code}: ${message}${NC}" >&2
    echo -e "  Current:   ${current}" >&2
    echo -e "  Required:  ${required}" >&2
    echo -e "  Fix:       ${fix}" >&2
    echo "" >&2

    ((ERRORS++))
}

preflight_warn() {
    # Arguments: code, message, impact, fix
    local code="$1"
    local message="$2"
    local impact="$3"
    local fix="$4"

    echo -e "${YELLOW}[WARN] ${code}: ${message}${NC}"
    echo -e "  Impact:    ${impact}"
    echo -e "  Fix:       ${fix}"
    echo ""

    ((WARNINGS++))
}

preflight_ok() {
    # Arguments: code, message
    local code="$1"
    local message="$2"

    echo -e "${GREEN}[OK] ${code}: ${message}${NC}"
}

# ============================================
# Individual Check Functions
# ============================================

check_cgroups_v2() {
    # Check if cgroups v2 is available
    # Returns: 0 if available, 1 otherwise

    # Check for cgroup.controllers file (indicates cgroups v2)
    if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
        return 0
    fi

    # Alternative: check using findmnt
    if findmnt -t cgroup2 /sys/fs/cgroup >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

check_subuid_configured() {
    # Check if user has subuid configuration
    # Arguments: user
    # Returns: 0 if configured, 1 otherwise

    local user="$1"

    if grep -q "^${user}:" /etc/subuid 2>/dev/null; then
        return 0
    fi

    return 1
}

check_subgid_configured() {
    # Check if user has subgid configuration
    # Arguments: user
    # Returns: 0 if configured, 1 otherwise

    local user="$1"

    if grep -q "^${user}:" /etc/subgid 2>/dev/null; then
        return 0
    fi

    return 1
}

check_fuse_support() {
    # Check if FUSE kernel support is available
    # Returns: 0 if available, 1 otherwise

    # Check for /dev/fuse character device with read permission
    if [[ -c /dev/fuse ]] && [[ -r /dev/fuse ]]; then
        return 0
    fi

    return 1
}

check_kernel_version() {
    # Check if current kernel version meets minimum requirement
    # Arguments: required_version (e.g., "5.11")
    # Returns: 0 if current >= required, 1 otherwise

    local required="$1"
    local current

    # Get current kernel version (strip everything after first hyphen)
    current=$(uname -r | cut -d'-' -f1)

    # Compare versions using sort -V
    # If current >= required, the sort order will have required first or equal
    local sorted
    sorted=$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1)

    if [[ "$sorted" == "$required" ]] || [[ "$current" == "$required" ]]; then
        return 0
    fi

    return 1
}

check_noexec_mount() {
    # Check if a path allows execution (no noexec mount option)
    # Arguments: path
    # Returns: 0 if execution allowed, 1 if noexec detected

    local path="$1"

    # Get mount options for the path
    local options
    options=$(findmnt -T "$path" -o OPTIONS -n 2>/dev/null)

    if [[ "$options" == *noexec* ]]; then
        return 1
    fi

    return 0
}

get_mount_info() {
    # Get detailed mount information for a path (for error messages)
    # Arguments: path
    # Returns: mount info string

    local path="$1"

    findmnt -T "$path" 2>/dev/null || echo "Unknown mount"
}

# ============================================
# Main Validation Runner
# ============================================

run_preflight_checks() {
    local start_time end_time duration

    echo "========================================"
    echo "Pre-flight Validation"
    echo "========================================"
    echo ""

    start_time=$(date +%s)

    # VAL-01: cgroups v2 (ERROR - required for rootless)
    if check_cgroups_v2; then
        preflight_ok "VAL-01" "cgroups v2 available"
    else
        preflight_error "VAL-01" \
            "cgroups v2 is not available" \
            "cgroups v1 or legacy hierarchy" \
            "cgroups v2 for rootless Podman" \
            "Add systemd.unified_cgroup_hierarchy=1 to kernel cmdline and reboot"
    fi

    # VAL-02: subuid/subgid (WARNING - rootless won't work but rootful may)
    local current_user
    current_user=$(whoami)

    # Skip subuid/subgid check for root user
    if [[ $EUID -eq 0 ]]; then
        preflight_ok "VAL-02" "Running as root - subuid/subgid not required"
    elif check_subuid_configured "$current_user" && check_subgid_configured "$current_user"; then
        preflight_ok "VAL-02" "subuid/subgid configured for ${current_user}"
    else
        preflight_warn "VAL-02" \
            "subuid/subgid not configured for user '${current_user}'" \
            "Rootless mode will not function" \
            "sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${current_user}"
    fi

    # VAL-03: FUSE support (ERROR - required for fuse-overlayfs)
    if check_fuse_support; then
        preflight_ok "VAL-03" "FUSE kernel support available"
    else
        preflight_error "VAL-03" \
            "FUSE kernel support not available" \
            "/dev/fuse not found or not accessible" \
            "FUSE for fuse-overlayfs (rootless storage)" \
            "Install fuse3 package or enable FUSE in kernel config"
    fi

    # VAL-04: Minimum kernel version (WARNING - works with fuse-overlayfs on older)
    local kernel_version
    kernel_version=$(uname -r | cut -d'-' -f1)
    if check_kernel_version "5.11"; then
        preflight_ok "VAL-04" "Kernel version ${kernel_version} (>= 5.11)"
    else
        # Check absolute minimum (4.18 for fuse-overlayfs in userns)
        if check_kernel_version "4.18"; then
            preflight_warn "VAL-04" \
                "Kernel version ${kernel_version} is below recommended 5.11" \
                "Native overlay may not work; fuse-overlayfs required" \
                "Upgrade kernel to 5.11+ for native rootless overlay support"
        else
            preflight_error "VAL-04" \
                "Kernel version ${kernel_version} is below minimum 4.18" \
                "Kernel ${kernel_version}" \
                "Kernel 4.18+ for fuse-overlayfs in user namespace" \
                "Upgrade kernel to 4.18 or later"
        fi
    fi

    # VAL-05: noexec mounts (ERROR - builds will fail)
    local noexec_paths=()
    local check_paths=("/tmp" "${HOME:-/home}")

    # Also check TMPDIR if set
    if [[ -n "${TMPDIR:-}" ]]; then
        check_paths+=("$TMPDIR")
    fi

    for path in "${check_paths[@]}"; do
        if ! check_noexec_mount "$path"; then
            noexec_paths+=("$path")
        fi
    done

    if [[ ${#noexec_paths[@]} -eq 0 ]]; then
        preflight_ok "VAL-05" "No noexec mounts on critical paths"
    else
        preflight_error "VAL-05" \
            "noexec mount detected on: ${noexec_paths[*]}" \
            "$(get_mount_info "${noexec_paths[0]}")" \
            "Executable permission for build processes" \
            "Remove noexec from mount options in /etc/fstab, or set TMPDIR to a different location"
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    echo "========================================"
    echo "Validation Complete (${duration}s)"
    echo "  Errors:   ${ERRORS}"
    echo "  Warnings: ${WARNINGS}"
    echo "========================================"

    # Exit behavior
    if [[ $ERRORS -gt 0 ]]; then
        echo ""
        echo "Please fix the errors above before continuing installation."
        return 1
    fi

    if [[ $WARNINGS -gt 0 ]]; then
        echo ""
        echo "Warnings detected. Installation may continue but some features may not work."
    fi

    return 0
}

# ============================================
# Standalone Execution Support
# ============================================

# Allow standalone execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_preflight_checks
    exit $?
fi
