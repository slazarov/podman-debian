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
