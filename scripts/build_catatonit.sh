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

git_clone_update https://github.com/openSUSE/catatonit.git catatonit
cd "${BUILD_ROOT}/catatonit"
git_checkout "${CATATONIT_TAG}"

# Log Component
log_component "catatonit"

# Note: The main fix for libtoolize aux directory detection was renaming
# install.sh to setup.sh in the repo root. The file "install.sh" was being
# detected by libtoolize as an autotools auxiliary file (similar to "install-sh"),
# causing it to put ltmain.sh in ../.. instead of ./
# The m4 directory is created as an extra safeguard.
mkdir -p m4

# Build
./autogen.sh
./configure
make
sudo make install
