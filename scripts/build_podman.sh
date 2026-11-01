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
log_build_output "podman"

# Fix for cloud-init where HOME is not set
export HOME="${HOME:-/root}"

export PATH="$GOPATH:$PATH"

step_start "Cloning repository"
git_clone_update https://github.com/containers/podman.git podman
cd "${BUILD_ROOT}/podman"
step_done

step_start "Checking out tag"
git_checkout "${PODMAN_TAG}"
step_done

step_start "Logging version"
log_component "podman"
step_done

step_start "Configuring Go optimization"
# Disable GC during compilation for speed (uses more RAM but ~30% faster)
export GOGC="${GOGC_BUILD:-off}"
step_done

step_start "Building"
run_logged make -j "$NPROC" GO="$GOPATH/go" GCFLAGS="${GO_GCFLAGS}" LDFLAGS="${GO_LDFLAGS}" BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr
step_done

step_start "Installing"
if [[ -n "${DESTDIR:-}" ]]; then
    run_logged make GO="$GOPATH/go" install PREFIX=/usr DESTDIR="${DESTDIR}"
    run_logged make GO="$GOPATH/go" install.completions PREFIX=/usr DESTDIR="${DESTDIR}"
else
    run_logged sudo make GO="$GOPATH/go" install PREFIX=/usr
    run_logged sudo make GO="$GOPATH/go" install.completions PREFIX=/usr
fi
step_done
