#!/bin/bash

# Non-Interactive Mode - MUST be set before ANY apt commands
export DEBIAN_FRONTEND=noninteractive

# Abort on Error
# set -e

# Determine toolpath if not set already
relativepath="./" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Install Requirements
source "${toolpath}/scripts/install_dependencies.sh"

# Install RUST
source "${toolpath}/scripts/install_rust.sh"

# Install other Dependencies
source "${toolpath}/scripts/install_dependencies.sh"

# Install Protoc
source "${toolpath}/scripts/install_protoc.sh"

# Install Go
source "${toolpath}/scripts/install_go.sh"

# Build AardVark DNS
source "${toolpath}/scripts/build_aardvark_dns.sh"

# Build Buildah
source "${toolpath}/scripts/build_buildah.sh"

# Build Catatonit
source "${toolpath}/scripts/build_catatonit.sh"

# Build Conmon
source "${toolpath}/scripts/build_conmon.sh"

# Build CRUN
source "${toolpath}/scripts/build_crun.sh"

# Build Fuse-OverlayFS
source "${toolpath}/scripts/build_fuse-overlayfs.sh"

# Build Go-MD2Man
source "${toolpath}/scripts/build_go-md2man.sh"

# Build Netavark
source "${toolpath}/scripts/build_netavark.sh"

# Build Pasta
source "${toolpath}/scripts/build_pasta.sh"

# Build Podman
source "${toolpath}/scripts/build_podman.sh"

# Build RUNC
source "${toolpath}/scripts/build_runc.sh"

# Build Skopeo
source "${toolpath}/scripts/build_skopeo.sh"

# Build Slirp4NetNS
source "${toolpath}/scripts/build_slirp4netns.sh"

# Build Toolbox
source "${toolpath}/scripts/build_toolbox.sh"
