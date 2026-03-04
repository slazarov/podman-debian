#!/bin/bash

# Prevent recursive sourcing
[[ -n "${_FUNCTIONS_SH_SOURCED:-}" ]] && return 0
export _FUNCTIONS_SH_SOURCED=1

# Determine toolpath if not set already
relativepath="./" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# ============================================
# Architecture Detection
# ============================================

detect_architecture() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $arch" >&2
            echo "Supported: x86_64 (amd64), aarch64/arm64 (ARM64)" >&2
            exit 1
            ;;
    esac
}

# NOTE: config.sh is sourced at the END of this file (after all function definitions)
# This is required because config.sh calls get_latest_protoc_version() and get_latest_go_version()

get_latest_tag() {
    # Input Parameters
    # ...

    # List all Tags excluding rc Patterns
    # This seems to Fail on 1.14 being latest -> 1.9 being used e.g. on fuse-overlayfs
    # latest=$(git tag --list --sort -tag | grep -v rc | head -n1)

    # This seems to do better
    # latest=$(git tag --list --sort -creatordate | grep -v rc | head -n1)

    # Take the latest highest stable Version release
    # Handle both v-prefixed (v5.5.2) and numeric-only (1.26) tags
    # Sort by version (stripping v prefix for comparison) while preserving original tag name
    latest=$(git tag --list --sort -creatordate | grep -v rc | grep -E '^v?[0-9]' | \
             while read tag; do echo "${tag#v} $tag"; done | \
             sort --reverse --version-sort -k1 | head -n1 | cut -d' ' -f2)

    # Return Result
    echo "${latest}"
}

get_latest_protoc_version() {
    # Fetch latest protoc release from GitHub API
    # Returns version WITHOUT v prefix (e.g., "34.0" not "v34.0")
    local latest_tag
    latest_tag=$(curl -s "https://api.github.com/repos/protocolbuffers/protobuf/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    # Strip v prefix if present (tag_name is "v34.0", we want "34.0")
    echo "${latest_tag#v}"
}

get_latest_go_version() {
    # Fetch latest Go version from go.dev JSON API
    # Returns version WITHOUT go prefix (e.g., "1.26.0" not "go1.26.0")
    local latest_version
    latest_version=$(curl -s "https://go.dev/dl/?mode=json" | grep -m1 '"version"' | sed 's/.*"version": *"\([^"]*\)".*/\1/')
    # Strip go prefix if present (version is "go1.26.0", we want "1.26.0")
    echo "${latest_version#go}"
}

git_clone_update() {
    # Input Parameters
    local lrepository="$1"
    local lfolder="$2"

    if [ -z "${lrepository}" ] || [ -z "${lfolder}" ]
    then
        echo "FATAL: You must specify both REPOSITORY GIT URL and TARGET FOLDER"
        exit 1
    else
        if [ -d "${lfolder}" ] && [ -d "${lfolder}/.git" ]
        then
           # Change Working Directly to Target Folder
           cd "${lfolder}"

           # Git Repository has already been cloned
           # Fetch latest Changes
           git fetch --all

           # Also fetch Tags
           git fetch --tags
        else
           # Git Repository has NOT been cloned yet
           # Clone Git Repository
           # Use shallow clone for fresh clones if enabled (reduces network transfer ~95%)
           if [[ "${SHALLOW_CLONE:-true}" == "true" ]]; then
               git clone --depth 1 "${lrepository}" "${lfolder}"
           else
               git clone "${lrepository}" "${lfolder}"
           fi
        fi
    fi
}

git_checkout() {
    # Input Parameters
    local ltag=${1-""}

    if [[ -n "${ltag}" ]]
    then
       # For shallow clones, the tag may not be available locally - fetch it
       if ! git rev-parse "${ltag}" &>/dev/null; then
           git fetch --depth 1 origin tag "${ltag}"
       fi
       git checkout "${ltag}"
       export GIT_CHECKED_OUT_TAG="${ltag}"
    else
       # No tag specified - need all tags to find latest
       if [[ "${SHALLOW_CLONE:-true}" == "true" ]]; then
           git fetch --tags
       fi
       git checkout $(get_latest_tag)
       export GIT_CHECKED_OUT_TAG=$(get_latest_tag)
    fi

}

log_component() {
    # Input Arguments
    local lcomponent="$1"

    # Generate Timestamp
    local ltimestamp
    ltimestamp=$(date +"%Y%m%d")

    # If Command Exists, save Version
    local loldversion=""
    if [[ -n $(command -v "${lcomponent}") ]]
    then
        loldversion=$("${lcomponent}" --version 2>/dev/null | awk '{print $NF}') || true
    fi

    # New Version can be determined by the Checked out Branch
    local lnewversion
    lnewversion="${GIT_CHECKED_OUT_TAG}"

    # Create Log Folder if not existing yet
    mkdir -p "${toolpath}/log"

    # Log Message to File
    if [[ -z "${loldversion}" ]]
    then
        echo "Install ${lcomponent} with Version ${lnewversion}" >> "${toolpath}/log/${ltimestamp}.log"
    else
        echo "Update ${lcomponent} from Version ${loldversion} to Version ${lnewversion}" >> "${toolpath}/log/${ltimestamp}.log"
    fi
}


remove_if_user_installed() {
    # Input Arguments
    local lfile="$1"

    # Try to see if it was installed using Package Manager
    dpkg --search "${lfile}" 2>&1 > /dev/null

    # If not delete File
    if [[ $? -eq 1 ]]
    then
        rm -f "${lfile}"
    fi
}

# ============================================
# Build Artifact Cleanup
# ============================================

cleanup_build_artifacts() {
    echo "Cleaning up build artifacts..."

    # Remove downloaded archives if build directories exist
    if [ -d "${BUILD_ROOT}/aardvark-dns" ]; then
        rm -f "${toolpath}/build/go*.linux-${ARCH}.tar.gz"
        rm -f "${toolpath}/build/protoc*-linux-${ARCH}.zip"
        rm -f "${toolpath}/build/rustup-init.sh"
    fi

    # Clean up other temporary build files
    find "${BUILD_ROOT}" -name "*.tar.*" -type f -delete 2>/dev/null || true
    find "${BUILD_ROOT}" -name "*.zip" -type f -delete 2>/dev/null || true

    echo "Cleanup completed"
}

# ============================================
# Error Handling
# ============================================

error_handler() {
    local exit_code=$1
    local line_number=$2
    local script_name="${3##*/}"  # basename

    echo "" >&2
    echo "========================================" >&2
    echo "ERROR: Installation Failed" >&2
    echo "========================================" >&2
    echo "  Script:    ${script_name}" >&2
    echo "  Line:      ${line_number}" >&2
    echo "  Exit Code: ${exit_code}" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "To debug, run: bash -x ${script_name}" >&2
    echo "" >&2

    exit "${exit_code}"
}

# ============================================
# Progress Tracking
# ============================================

# Format elapsed seconds to human-readable (MM:SS or HH:MM:SS)
format_duration() {
    local seconds=$1
    if [[ $seconds -ge 3600 ]]; then
        printf "%dh %dm %ds" $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
    elif [[ $seconds -ge 60 ]]; then
        printf "%dm %ds" $((seconds/60)) $((seconds%60))
    else
        printf "%ds" $seconds
    fi
}

# Track script timing (called by run_script in setup.sh)
declare -g _SCRIPT_START=0

script_start() {
    export _SCRIPT_START=$(date +%s)
}

script_done() {
    local script_name="$1"
    local end=$(date +%s)
    local elapsed=$((end - _SCRIPT_START))
    echo ">>> Completed: ${script_name} in $(format_duration $elapsed)"
}

# Step-level progress (called within build scripts)
declare -g _STEP_NAME=""
declare -g _STEP_START=0

step_start() {
    local step_name="$1"
    export _STEP_NAME="$step_name"
    export _STEP_START=$(date +%s)
    echo "  ${step_name}..."
}

step_done() {
    local step_end=$(date +%s)
    local elapsed=$((step_end - _STEP_START))
    echo "  Done: ${_STEP_NAME} ($(format_duration $elapsed))"
}

# Build output logging
declare -g BUILD_LOG=""

log_build_output() {
    # Initializes log file for a component's build output
    # Usage: log_build_output "component_name"
    local component="$1"
    BUILD_LOG="${toolpath}/log/build_${component}.log"

    # Ensure log directory exists
    mkdir -p "$(dirname "$BUILD_LOG")"

    # Initialize log file with header
    {
        echo "==========================================="
        echo "Build Log: ${component}"
        echo "Started: $(date)"
        echo "==========================================="
    } > "$BUILD_LOG"
}

run_logged() {
    # Runs command with output going only to log file (suppresses console output)
    # Usage: run_logged make [args...]
    "$@" >> "$BUILD_LOG" 2>&1
}

# ============================================
# Load Configuration (MUST be after all function definitions)
# ============================================
# This sources config.sh which calls get_latest_protoc_version() and get_latest_go_version()
# Those functions must be defined BEFORE this line!

source "${toolpath}/config.sh"
