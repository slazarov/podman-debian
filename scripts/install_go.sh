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

# Create Folders
mkdir -p ${GOROOT}

# Download Go for detected architecture
wget "https://go.dev/dl/${GOTAG}.linux-${GOARCH}.tar.gz" -O go.tar.gz

# Extract
tar -xzf go.tar.gz

# Move to destination (Go tarball extracts to 'go' directory)
rm -rf "${GOROOT}"
mv go "${GOROOT}"
