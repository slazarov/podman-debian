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

# ============================================
# Install Container-Libs Man Pages
# ============================================
# Builds and installs section 5 man pages from container-libs source:
#   - common/docs/*.5.md        (4 man pages)
#   - image/docs/*.5.md         (10 man pages)
#   - storage/docs/containers-storage.conf.5.md (1 man page)
#   - common/docs/links/.containerignore.5      (1 symlink/alias)
# Total: 15 man pages + 1 alias = 16 installed files

step_start "Building man pages from container-libs source"
count=0

for md_file in \
    "${BUILD_ROOT}/container-libs/common/docs/"*.5.md \
    "${BUILD_ROOT}/container-libs/image/docs/"*.5.md \
    "${BUILD_ROOT}/container-libs/storage/docs/"containers-storage.conf.5.md; do
    [[ -f "$md_file" ]] || continue
    go-md2man -in "$md_file" -out "${md_file%.md}"
    count=$((count + 1))
done

echo "  Built ${count} man pages"
step_done

step_start "Installing man pages to /usr/share/man/man5/"
mkdir -p /usr/share/man/man5

installed=0

# Install all generated .5 files from common/docs/
for man_file in "${BUILD_ROOT}/container-libs/common/docs/"*.5; do
    [[ -f "$man_file" ]] || continue
    install -m 0644 "$man_file" /usr/share/man/man5/
    installed=$((installed + 1))
done

# Install all generated .5 files from image/docs/
for man_file in "${BUILD_ROOT}/container-libs/image/docs/"*.5; do
    [[ -f "$man_file" ]] || continue
    install -m 0644 "$man_file" /usr/share/man/man5/
    installed=$((installed + 1))
done

# Install containers-storage.conf.5 from storage/docs/
if [[ -f "${BUILD_ROOT}/container-libs/storage/docs/containers-storage.conf.5" ]]; then
    install -m 0644 "${BUILD_ROOT}/container-libs/storage/docs/containers-storage.conf.5" /usr/share/man/man5/
    installed=$((installed + 1))
fi

# Install .containerignore.5 alias from common/docs/links/
if [[ -f "${BUILD_ROOT}/container-libs/common/docs/links/.containerignore.5" ]]; then
    install -m 0644 "${BUILD_ROOT}/container-libs/common/docs/links/.containerignore.5" /usr/share/man/man5/
    installed=$((installed + 1))
fi

echo "  Installed ${installed} man pages to /usr/share/man/man5/"
step_done

step_start "Verifying installed man pages"
verify_count=$(ls -1 /usr/share/man/man5/containers-*.5 /usr/share/man/man5/Containerfile.5 /usr/share/man/man5/containerignore.5 /usr/share/man/man5/.containerignore.5 2>/dev/null | wc -l)
echo "  Found ${verify_count} container-libs man pages in /usr/share/man/man5/"

if [[ ${verify_count} -lt 15 ]]; then
    echo "WARNING: Expected at least 15 man pages, found ${verify_count}" >&2
fi
step_done
