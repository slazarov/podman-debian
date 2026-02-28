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

# Create m4 directory to fix libtoolize auxiliary directory detection
# Without this, libtoolize puts ltmain.sh in ../.. instead of ./
# because catatonit's configure.ac lacks AC_CONFIG_AUX_DIR
mkdir -p m4

# Build
./autogen.sh
./configure
make
sudo make install
