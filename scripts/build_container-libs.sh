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
# The seccomp.json target lives in common/Makefile, not the repo root
# generate.go writes to common/pkg/seccomp/seccomp.json
run_logged make -C common seccomp.json
step_done

step_start "Verifying artifact"
# Ensure seccomp.json was generated successfully (output path: common/pkg/seccomp/seccomp.json)
SECCOMP_JSON="common/pkg/seccomp/seccomp.json"
test -f "${SECCOMP_JSON}" || { echo "ERROR: seccomp.json was not generated at ${SECCOMP_JSON}" >&2; exit 1; }
echo "  seccomp.json generated successfully ($(wc -c < "${SECCOMP_JSON}") bytes)"
step_done
