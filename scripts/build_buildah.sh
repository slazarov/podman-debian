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

# Fix for cloud-init where GOCACHE, XDG_CACHE_HOME, and HOME are not set
export GOCACHE="${GOCACHE:-/tmp/go-build}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp}"
export HOME="${HOME:-/root}"

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="$GOPATH:$PATH"

git_clone_update https://github.com/containers/buildah.git buildah
cd "${BUILD_ROOT}/buildah"
git_checkout "${BUILDAH_TAG}"

# Log Component
log_component "buildah"

# Must Patch 1.22.6 -> 1.23 in /usr/src/podman/buildah/go.mod
sed -Ei "s|^go 1.22.6$|go 1.23|" go.mod

# Build
#make
#make BUILDTAGS="selinux seccomp apparmor systemd" PREFIX=/usr
make GO="$GOPATH/go" BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr
sudo make GO="$GOPATH/go" install

#buildah --help
