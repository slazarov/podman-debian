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
log_build_output "conmon"

step_start "Cloning repository"
git_clone_update https://github.com/containers/conmon conmon
cd "${BUILD_ROOT}/conmon"
step_done

step_start "Checking out tag"
git_checkout "${CONMON_TAG}"
step_done

step_start "Logging version"
log_component "conmon"
step_done

step_start "Configuring Go optimization"
# Disable GC during compilation for speed (uses more RAM but ~30% faster)
export GOGC="${GOGC_BUILD:-off}"
export GOCACHE="$(mktemp -d)"
step_done

step_start "Building"
run_logged make -j "$NPROC" GCFLAGS="${GO_GCFLAGS}" LDFLAGS="${GO_LDFLAGS}"
step_done

step_start "Installing"
run_logged sudo make podman
step_done
