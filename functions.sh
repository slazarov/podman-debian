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

# Load Configuration
source "${toolpath}/config.sh"

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
           git clone "${lrepository}" "${lfolder}"
        fi
    fi
}

git_checkout() {
    # Input Parameters
    local ltag=${1-""}

    if [[ -n "${ltag}" ]]
    then
       git checkout "${ltag}"
       export GIT_CHECKED_OUT_TAG="${ltag}"
    else
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
