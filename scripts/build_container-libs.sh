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
log_build_output "container-libs"

# Fix for cloud-init where HOME is not set
export HOME="${HOME:-/root}"

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="$GOPATH:$PATH"

step_start "Cloning repository"
git_clone_update https://github.com/containers/container-libs.git container-libs
cd "${BUILD_ROOT}/container-libs"
step_done

step_start "Checking out tag"
git_checkout "${CONTAINER_LIBS_TAG}"
step_done

step_start "Logging version"
log_component "container-libs"
step_done

step_start "Configuring Go optimization"
# Disable GC during compilation for speed (uses more RAM but ~30% faster)
export GOGC="${GOGC_BUILD:-off}"
step_done

step_start "Building seccomp.json"
# Build only the seccomp.json artifact via Go codegen
# We do NOT need `make all` or `make install` -- only the seccomp profile
run_logged make seccomp.json
step_done

step_start "Verifying artifact"
# Ensure seccomp.json was generated successfully
test -f seccomp.json || { echo "ERROR: seccomp.json was not generated" >&2; exit 1; }
echo "  seccomp.json generated successfully ($(wc -c < seccomp.json) bytes)"
step_done
