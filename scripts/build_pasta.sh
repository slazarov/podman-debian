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

# Use GitHub mirror when official passt.top is unavailable
# Official: https://passt.top/passt (sometimes returns 504)
# Mirror: https://github.com/AkihiroSuda/passt-mirror
git_clone_update https://github.com/AkihiroSuda/passt-mirror passt
cd "${BUILD_ROOT}/passt"
git fetch --all
git fetch --tags
git pull

# Save Version
export GIT_CHECKED_OUT_TAG=$(date +"%Y%m%d")

# Log Component
log_component "pasta"

# Build
make

# Kill current running Processes
# Save current Error Setting
shopt -qo errexit
current_error_setting=$?

# Avoid stopping on Errors
set +e

# Kill processes (exclude this own Script)
ps aux | grep pasta | grep -v "bash" | awk '{print $2}' | xargs -r -n 1 kill -9 || true

# Set exit on Error if required
if [ ${current_error_setting} -eq 0 ]
then
    set -e
fi

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
