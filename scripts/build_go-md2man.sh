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
log_build_output "go-md2man"

# Fix for cloud-init where GOCACHE, XDG_CACHE_HOME, and HOME are not set
export GOCACHE="${GOCACHE:-/tmp/go-build}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp}"
export HOME="${HOME:-/root}"

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="$GOPATH:$PATH"

step_start "Cloning repository"
git_clone_update https://github.com/cpuguy83/go-md2man.git go-md2man
cd "${BUILD_ROOT}/go-md2man"
step_done

step_start "Checking out tag"
git_checkout "${GOMD2MAN_TAG}"
step_done

step_start "Logging version"
log_component "go-md2man"
step_done

step_start "Applying pre-build fixes"
sed -Ei "s|^go 1.22.6$|go 1.23|" go.mod
step_done

step_start "Building"
run_logged make -j "$NPROC"
step_done

step_start "Installing"
cp bin/go-md2man /usr/local/bin
step_done
