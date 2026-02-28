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

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="$GOPATH:$PATH"


git_clone_update https://github.com/rootless-containers/slirp4netns.git slirp4netns
cd "${BUILD_ROOT}/slirp4netns"
git_checkout "${SLIRP4NETNS_TAG}"

# Log Component
log_component "slirp4netns"

# Build
./autogen.sh
./configure --prefix=/usr/local
make
sudo make install


####make BUILDTAGS="selinux seccomp apparmor"

####sudo cp slirp4netns /usr/local/bin/slirp4netns
