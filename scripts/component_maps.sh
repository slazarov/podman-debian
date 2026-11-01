#!/bin/bash

# Shared component maps — single source of truth for scripts/package_all.sh
# (packaging) and scripts/verify_depends.sh (post-build dependency verification).
# Previously these two associative arrays were declared identically in both
# scripts and kept in sync only by hand/comment discipline; drift would silently
# weaken the verify gate. Source this instead.
#
# Sourced (not executed): guard against re-sourcing, do not set -euo here.

[[ -n "${_COMPONENT_MAPS_SH_SOURCED:-}" ]] && return 0
_COMPONENT_MAPS_SH_SOURCED=1

# ELF binaries each component ships, relative to DESTDIR (space-separated when a
# component ships more than one, e.g. pasta ships both passt and pasta). Runtime
# dependency detection runs over these. Components with no native ELF binary
# (container-configs, toolbox) have no entry — detection is skipped for them.
declare -A COMPONENT_BINARIES=(
    ["podman"]="usr/bin/podman usr/bin/podman-remote"
    ["crun"]="usr/bin/crun"
    ["conmon"]="usr/bin/conmon"
    ["netavark"]="usr/libexec/podman/netavark"
    ["aardvark-dns"]="usr/libexec/podman/aardvark-dns"
    ["pasta"]="usr/bin/passt usr/bin/pasta usr/bin/pesto usr/bin/passt-repair"
    ["fuse-overlayfs"]="usr/bin/fuse-overlayfs"
    ["catatonit"]="usr/bin/catatonit"
    ["buildah"]="usr/bin/buildah"
    ["skopeo"]="usr/bin/skopeo"
)

# Inject-only components: their nFPM YAML has NO literal `depends:` key
# and no static items — the entire depends block is the injected fragment. For
# these the injected fragment must carry its own `depends:` header, emitted only
# when the detected set is non-empty, so a fully-static binary yields no key at
# all (rather than a bare `depends:` with zero items, which parses as null).
# Components NOT listed here (podman/buildah/skopeo) keep their literal
# `depends:` key with static suite deps and receive list items only.
declare -A INJECT_ONLY_DEPENDS=(
    ["crun"]=1
    ["conmon"]=1
    ["pasta"]=1
)
