#!/bin/bash

# Abort on Error
set -euo pipefail

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
if [ -n "${HOME:-}" ] && [ -f "$HOME/.cargo/env" ]; then
    . "$HOME/.cargo/env"
fi
#export PATH="CUSTOMPATH:$PATH"

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# Change Folder to Build Root
cd "${BUILD_ROOT}" || exit

# Initialize build logging
log_build_output "netavark"

step_start "Cloning repository"
git_clone_update https://github.com/containers/netavark netavark
cd "${BUILD_ROOT}/netavark"
step_done

step_start "Checking out tag"
git_checkout "${NETAVARK_TAG}"
step_done

step_start "Logging version"
log_component "netavark"
step_done

step_start "Configuring Cargo optimization"
# Set parallel jobs for cargo (uses NPROC by default)
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$NPROC}"

# Enable sccache for Rust build caching when configured
if [[ "${SCCACHE_ENABLED:-false}" == "true" ]] && command -v sccache &>/dev/null; then
    export RUSTC_WRAPPER=sccache
    echo "  sccache enabled for Rust compilation"
fi

# Enable mold linker for faster Rust linking when configured
if [[ "${MOLD_ENABLED:-false}" == "true" ]] && command -v mold &>/dev/null; then
    # Use project-level cargo config to avoid conflicts with sccache RUSTC_WRAPPER
    mkdir -p .cargo
    cat > .cargo/config.toml << 'TOML'
[target.'cfg(target_os = "linux")']
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
TOML
    echo "  mold linker enabled for Rust compilation"
fi
step_done

step_start "Building"
run_logged make
step_done

step_start "Installing"
cp bin/netavark /usr/local/bin/netavark
cp bin/netavark-dhcp-proxy-client /usr/local/bin/netavark-dhcp-proxy-client
step_done
