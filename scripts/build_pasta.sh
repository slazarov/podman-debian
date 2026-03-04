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

# Change Folder to Build Root
cd "${BUILD_ROOT}" || exit

# Initialize build logging
log_build_output "pasta"

step_start "Cloning repository"
git_clone_update git://passt.top/passt passt
cd "${BUILD_ROOT}/passt"
git fetch --all
git fetch --tags
git pull
step_done

step_start "Saving version"
export GIT_CHECKED_OUT_TAG=$(date +"%Y%m%d")
step_done

step_start "Logging version"
log_component "pasta"
step_done

step_start "Configuring ccache"
# Enable ccache for C build caching when configured
if [[ "${CCACHE_ENABLED:-false}" == "true" ]] && command -v ccache &>/dev/null; then
    export CC="ccache gcc"
    echo "  ccache enabled for C compilation"
fi
step_done

step_start "Building"
run_logged make -j "$NPROC"
step_done

step_start "Installing"
# Kill current running Processes (ignore errors)
shopt -qo errexit
current_error_setting=$?
set +e
ps aux | grep pasta | grep -v "bash" | awk '{print $2}' | xargs -r -n 1 kill -9 || true
if [ ${current_error_setting} -eq 0 ]; then set -e; fi

# Copy new Executable to Destination Folder
cp passt /usr/local/bin/
[[ -f passt.avx2 ]] && cp passt.avx2 /usr/local/bin/
cp pasta /usr/local/bin/
[[ -f pasta.avx2 ]] && cp pasta.avx2 /usr/local/bin/

# Remove Files that shouldn't have been previously installed
rm -f /usr/local/bin/passt.1
rm -f /usr/local/bin/passt.c
rm -f /usr/local/bin/passt.h
rm -f /usr/local/bin/pasta.1
rm -f /usr/local/bin/pasta.c
rm -f /usr/local/bin/pasta.h
step_done
