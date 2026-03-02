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
log_build_output "toolbox"

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="$GOPATH:$PATH"

step_start "Cloning repository"
git_clone_update https://github.com/containers/toolbox.git toolbox
cd "${BUILD_ROOT}/toolbox"
step_done

step_start "Checking out tag"
git_checkout "${TOOLBOX_TAG}"
step_done

step_start "Logging version"
log_component "toolbox"
step_done

step_start "Applying pre-build fixes"
[[ -f go.mod ]] && sed -Ei "s|^go 1.22.6$|go 1.23|" go.mod
step_done

step_start "Configuring"
run_logged meson --prefix /usr/local --buildtype=plain builddir
step_done

step_start "Building"
run_logged meson compile -C builddir
step_done

step_start "Testing"
run_logged meson test -C builddir
step_done

step_start "Installing"
run_logged DESTDIR=/usr/local meson install -C builddir
step_done
