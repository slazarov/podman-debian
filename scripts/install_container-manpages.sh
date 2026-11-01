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
#   - common/docs/*.5.md        (containers.conf, Containerfile, ...)
#   - image/docs/*.5.md         (containers-registries.conf, ...)
#   - storage/docs/containers-storage.conf.5.md (1 man page)
#   - common/docs/links/.containerignore.5      (1 symlink/alias)
# The exact page count varies with the container-libs tag, so verification
# compares the staged files against the installed count, not a fixed number.

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

step_start "Installing man pages to ${DESTDIR:-}/usr/share/man/man5/"
mkdir -p "${DESTDIR:-}"/usr/share/man/man5

installed=0

# Install all generated .5 files from common/docs/
for man_file in "${BUILD_ROOT}/container-libs/common/docs/"*.5; do
    [[ -f "$man_file" ]] || continue
    install -m 0644 "$man_file" "${DESTDIR:-}"/usr/share/man/man5/
    installed=$((installed + 1))
done

# Install all generated .5 files from image/docs/
for man_file in "${BUILD_ROOT}/container-libs/image/docs/"*.5; do
    [[ -f "$man_file" ]] || continue
    install -m 0644 "$man_file" "${DESTDIR:-}"/usr/share/man/man5/
    installed=$((installed + 1))
done

# Install containers-storage.conf.5 from storage/docs/
if [[ -f "${BUILD_ROOT}/container-libs/storage/docs/containers-storage.conf.5" ]]; then
    install -m 0644 "${BUILD_ROOT}/container-libs/storage/docs/containers-storage.conf.5" "${DESTDIR:-}"/usr/share/man/man5/
    installed=$((installed + 1))
fi

# Install .containerignore.5 alias from common/docs/links/
if [[ -f "${BUILD_ROOT}/container-libs/common/docs/links/.containerignore.5" ]]; then
    install -m 0644 "${BUILD_ROOT}/container-libs/common/docs/links/.containerignore.5" "${DESTDIR:-}"/usr/share/man/man5/
    installed=$((installed + 1))
fi

echo "  Installed ${installed} man pages to ${DESTDIR:-}/usr/share/man/man5/"
step_done

step_start "Verifying installed man pages"
# containers*.5 (no hyphen) also matches containers.conf.5, which the previous
# containers-*.5 glob silently missed
verify_count=$(ls -1 "${DESTDIR:-}"/usr/share/man/man5/containers*.5 "${DESTDIR:-}"/usr/share/man/man5/Containerfile.5 "${DESTDIR:-}"/usr/share/man/man5/containerignore.5 "${DESTDIR:-}"/usr/share/man/man5/.containerignore.5 2>/dev/null | wc -l)
echo "  Found ${verify_count} container-libs man pages in ${DESTDIR:-}/usr/share/man/man5/"

if [[ ${verify_count} -lt ${installed} ]]; then
    echo "WARNING: Expected at least ${installed} man pages, found ${verify_count}" >&2
fi
step_done
