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

# Might actually not be needed for build-only (more for Troubleshooting)
# go install golang.org/x/tools/gopls@latest

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="$GOPATH:$PATH"

git_clone_update https://github.com/containers/podman.git podman
cd "${BUILD_ROOT}/podman"
git_checkout "${PODMAN_TAG}"

# Log Component
log_component "podman"

# Must Patch 1.22.6 -> 1.23 in /usr/src/podman/podman/go.mod
sed -Ei "s|^go 1.22.6$|go 1.23|" go.mod

#make BUILDTAGS="selinux seccomp apparmor systemd" PREFIX=/usr
make BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr
sudo make install PREFIX=/usr


# Copy to Target Folder

