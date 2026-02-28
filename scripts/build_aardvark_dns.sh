#!/bin/bash

# Strict Mode - Exit on error, undefined vars, pipe failures
set -euo pipefail

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
[[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
#export PATH="CUSTOMPATH:$PATH"

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# Change Folder to Build Root
cd "${BUILD_ROOT}" || exit

git_clone_update https://github.com/containers/aardvark-dns aardvark-dns
cd "${BUILD_ROOT}/aardvark-dns"
git_checkout "${AARDVARK_DNS_TAG}"

# Log Component
log_component "aardvark-dns"

# Build
make

#make BUILDTAGS="selinux seccomp apparmor systemd" PREFIX=/usr
#make BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr
#sudo make install

cp bin/aardvark-dns /usr/local/bin/aardvark-dns
