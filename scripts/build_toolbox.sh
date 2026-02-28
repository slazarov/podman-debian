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

git_clone_update https://github.com/containers/toolbox.git toolbox
cd "${BUILD_ROOT}/toolbox"
git_checkout "${TOOLBOX_TAG}"

# Log Component
log_component "toolbox"

# Change into "src" Subfolder
# This might need to be enabled/disabled (possibly depending on Version of meson being used) if meson complains about the Folder Structure
# cd src

# Must Patch 1.22.6 -> 1.23 in /usr/src/podman/podman/go.mod
sed -Ei "s|^go 1.22.6$|go 1.23|" go.mod

# Build using Meson
#meson setup builddir && cd builddir
#meson compile
#meson test

meson --prefix /usr/local --buildtype=plain builddir
# cd buildir
meson compile -C builddir
meson test -C builddir
DESTDIR=/usr/local meson install -C builddir


# Copy to Target Folder

