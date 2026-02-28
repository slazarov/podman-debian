#!/bin/bash

# Abort on Error
set -e

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Download Rustup for detected architecture
wget "https://static.rust-lang.org/rustup/dist/${RUSTUP_ARCH}/rustup-init" -O rustup-init
chmod +x rustup-init

./rustup-init -y
