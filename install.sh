#!/bin/bash

# Non-Interactive Mode - MUST be set before ANY apt commands
export DEBIAN_FRONTEND=noninteractive

# Strict Mode - Exit on error, undefined vars, pipe failures
set -euo pipefail

# Determine toolpath if not set already
relativepath="./" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing (config/functions may not support strict mode)
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# Track installation progress
COMPONENTS_OK=()

# Wrapper function for running sub-scripts with error handling
run_script() {
    local script="$1"
    echo ""
    echo "========================================"
    echo ">>> Starting: ${script}"
    echo "========================================"

    source "${toolpath}/scripts/${script}"

    COMPONENTS_OK+=("${script}")
    echo ">>> Completed: ${script}"
}

# Install Requirements
run_script "install_dependencies.sh"

# Install RUST
run_script "install_rust.sh"

# Install other Dependencies
run_script "install_dependencies.sh"

# Install Protoc
run_script "install_protoc.sh"

# Install Go
run_script "install_go.sh"

# Build AardVark DNS
run_script "build_aardvark_dns.sh"

# Build Buildah
run_script "build_buildah.sh"

# Build Catatonit
run_script "build_catatonit.sh"

# Build Conmon
run_script "build_conmon.sh"

# Build CRUN
run_script "build_crun.sh"

# Build Fuse-OverlayFS
run_script "build_fuse-overlayfs.sh"

# Build Go-MD2Man
run_script "build_go-md2man.sh"

# Build Netavark
run_script "build_netavark.sh"

# Build Pasta
run_script "build_pasta.sh"

# Build Podman
run_script "build_podman.sh"

# Build RUNC
run_script "build_runc.sh"

# Build Skopeo
run_script "build_skopeo.sh"

# Build Slirp4NetNS
run_script "build_slirp4netns.sh"

# Build Toolbox
run_script "build_toolbox.sh"
