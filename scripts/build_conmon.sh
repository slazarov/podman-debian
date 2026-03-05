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
step_done

step_start "Building"
run_logged make -j "$NPROC" GCFLAGS="${GO_GCFLAGS}" LDFLAGS="${GO_LDFLAGS}"
step_done

step_start "Installing"
# Use install.bin to install only the binary (skip docs target which requires go-md2man).
# conmon v2.2.1+ removed the conditional go-md2man guard, making `make install` fail
# when go-md2man is not yet built. Man pages are handled separately by install_container-manpages.sh.
if [[ -n "${DESTDIR:-}" ]]; then
    run_logged make install.bin PREFIX=/usr DESTDIR="${DESTDIR}"
else
    run_logged sudo make install.bin PREFIX=/usr
fi
step_done
