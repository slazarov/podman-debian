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

# Download Protoc for detected architecture
wget "https://github.com/protocolbuffers/protobuf/releases/download/${PROTOC_TAG}/protoc-${PROTOC_VERSION}-linux-${PROTOC_ARCH}.zip" -O protoc.zip

# Extract
mkdir -p "${PROTOC_ROOT_FOLDER}/${PROTOC_VERSION}"
unzip protoc.zip -d "${PROTOC_ROOT_FOLDER}/${PROTOC_VERSION}"

# Required Fix otherwise go complains about 1.22.6 vs 1.23 mismatch
export PATH="${PROTOC_PATH}:${PATH}"

if [[ ! -L /usr/local/bin/protoc ]]
then
    ln -s ${PROTOC_PATH} /usr/local/bin/protoc
fi

