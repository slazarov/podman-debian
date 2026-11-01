#!/bin/bash

# Strict Mode - Exit on error, undefined vars, pipe failures
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

# Download Rustup for detected architecture
wget "https://static.rust-lang.org/rustup/dist/${RUSTUP_ARCH}/rustup-init" -O rustup-init
chmod +x rustup-init

./rustup-init -y --default-toolchain "${RUST_VERSION:-stable}"

# Install sccache for Rust build caching (optional)
if [[ "${SCCACHE_ENABLED:-false}" == "true" ]]; then
    step_start "Installing sccache v${SCCACHE_VERSION}"

    sccache_url="https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-${SCCACHE_ARCH}.tar.gz"
    wget "${sccache_url}" -O sccache.tar.gz

    # Check the tarball before unpacking it: against SCCACHE_SHA256 when set
    # (pinned in config.sh for the default version), else against the
    # .sha256 file upstream publishes next to the tarball.
    sccache_expected="${SCCACHE_SHA256:-}"
    if [[ -z "${sccache_expected}" ]]; then
        wget "${sccache_url}.sha256" -O sccache.tar.gz.sha256
        sccache_expected="$(awk '{print $1; exit}' sccache.tar.gz.sha256)"
        rm -f sccache.tar.gz.sha256
    fi
    sccache_actual="$(sha256sum sccache.tar.gz | awk '{print $1}')"
    if [[ ! "${sccache_expected}" =~ ^[0-9a-f]{64}$ || "${sccache_actual}" != "${sccache_expected}" ]]; then
        echo "ERROR: sccache download checksum mismatch (expected '${sccache_expected}', got '${sccache_actual}')" >&2
        rm -f sccache.tar.gz
        exit 1
    fi
    echo "  sccache tarball checksum OK (${sccache_actual})"

    tar -xzf sccache.tar.gz
    cp "sccache-v${SCCACHE_VERSION}-${SCCACHE_ARCH}/sccache" /usr/local/bin/sccache
    chmod +x /usr/local/bin/sccache
    rm -rf sccache.tar.gz "sccache-v${SCCACHE_VERSION}-${SCCACHE_ARCH}"

    # Create cache directory
    mkdir -p "${SCCACHE_DIR}"

    echo "  sccache installed: $(sccache --version)"
    step_done
fi
