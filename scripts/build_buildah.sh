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
log_build_output "buildah"

# Fix for cloud-init where HOME is not set
export HOME="${HOME:-/root}"

export PATH="$GOPATH:$PATH"

step_start "Cloning repository"
git_clone_update https://github.com/containers/buildah.git buildah
cd "${BUILD_ROOT}/buildah"
step_done

step_start "Checking out tag"
git_checkout "${BUILDAH_TAG}"
step_done

step_start "Logging version"
log_component "buildah"
step_done

step_start "Configuring Go optimization"
# Disable GC during compilation for speed (uses more RAM but ~30% faster)
export GOGC="${GOGC_BUILD:-off}"
step_done

step_start "Building"
# Build only the buildah binary (not the default 'all' target).
# The 'all' target includes 'docs' → 'install.tools' which downloads golangci-lint
# via curl — prone to transient HTTP failures (502/503) that break the entire build.
# golangci-lint is a development/lint tool, not needed for packaging.
# Man pages are built separately using go-md2man (see "Building man pages" step).
run_logged make -j "$NPROC" GO="$GOPATH/go" GCFLAGS="${GO_GCFLAGS}" LDFLAGS="${GO_LDFLAGS}" BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr bin/buildah
step_done

step_start "Building man pages"
# Build man pages directly with go-md2man instead of the Makefile's 'docs' target
# (which requires 'install.tools' → golangci-lint download).
# go-md2man is installed to /usr/local/bin by build_go-md2man.sh earlier in setup.sh.
# Sed filters replicate the upstream docs/Makefile transformation pipeline.
man_count=0
if command -v go-md2man &>/dev/null; then
    for md_file in docs/*.1.md; do
        [[ -f "$md_file" ]] || continue
        out_file="${md_file%.md}"
        sed -e 's/\((buildah[^)]*\.md\(#.*\)\?)\)//g' \
            -e 's/\[\(buildah[^]]*\)\]/\1/g' \
            -e 's/\[\([^]]*\)](http[^)]\+)/\1/g' \
            -e 's;<\(/\)\?\(a\|a\s\+[^>]*\|sup\)>;;g' \
            -e 's/\\$/  /g' "$md_file" | \
            go-md2man -in /dev/stdin -out "$out_file"
        man_count=$((man_count + 1))
    done
    echo "  Built ${man_count} man pages"
else
    echo "  WARNING: go-md2man not found, skipping man page generation"
fi
step_done

step_start "Installing"
if [[ -n "${DESTDIR:-}" ]]; then
    # Install binary and man pages manually.
    # Avoids 'make install' which calls 'make -C docs install' (benign but
    # unnecessary indirection through the upstream Makefile's install target).
    install -d -m 755 "${DESTDIR}/usr/bin"
    install -m 755 bin/buildah "${DESTDIR}/usr/bin/buildah"

    # Install man pages (non-fatal — skipped if go-md2man was unavailable)
    for man_file in docs/buildah*.1 docs/links/buildah*.1; do
        [[ -f "$man_file" ]] || continue
        install -d -m 755 "${DESTDIR}/usr/share/man/man1" 2>/dev/null || true
        install -m 0644 "$man_file" "${DESTDIR}/usr/share/man/man1/"
    done

    # Install bash completions (safe — no install.tools dependency)
    run_logged make GO="$GOPATH/go" install.completions PREFIX=/usr DESTDIR="${DESTDIR}"
else
    sudo install -d -m 755 /usr/bin
    sudo install -m 755 bin/buildah /usr/bin/buildah

    for man_file in docs/buildah*.1 docs/links/buildah*.1; do
        [[ -f "$man_file" ]] || continue
        sudo install -d -m 755 /usr/share/man/man1 2>/dev/null || true
        sudo install -m 0644 "$man_file" /usr/share/man/man1/
    done

    run_logged sudo make GO="$GOPATH/go" install.completions PREFIX=/usr
fi
step_done
