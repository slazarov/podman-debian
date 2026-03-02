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
log_build_output "slirp4netns"

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="$GOPATH:$PATH"

step_start "Cloning repository"
git_clone_update https://github.com/rootless-containers/slirp4netns.git slirp4netns
cd "${BUILD_ROOT}/slirp4netns"
step_done

step_start "Checking out tag"
git_checkout "${SLIRP4NETNS_TAG}"
step_done

step_start "Logging version"
log_component "slirp4netns"
step_done

step_start "Running autogen"
./autogen.sh
step_done

step_start "Configuring"
./configure --prefix=/usr/local
step_done

step_start "Building"
run_logged make
step_done

step_start "Installing"
run_logged sudo make install
step_done
