#!/bin/bash

# Abort on Error
set -euo pipefail

# smoke_install.sh - apt-install locally built .debs inside a clean container
# of the distro they were built for, to prove their system-library Depends
# resolve from that distro's archive.
#
# Usage: smoke_install.sh <distro-label>
#   distro-label   one of VALID_DISTROS in config.sh (bookworm, trixie)
#
# `apt-get install` of a local .deb makes apt pull the .deb's declared Depends
# from the distro archive. If a dependency name is wrong for that release
# (for example libgpgme11 on trixie, where it is libgpgme11t64), apt cannot
# satisfy it and fails. That failure is the test signal. A clean install plus
# a working `skopeo --version` is the pass.
#
# It shells out to a container runtime (docker or podman), so it runs the same
# in CI and on any machine with a runtime. There is no silent skip: if no
# runtime or no built .deb is present, the script fails.
#
# Overrides:
#   SMOKE_RUNTIME=docker|podman   force the container runtime (validated)
#   SMOKE_IMAGE=<image[:tag]>      force the base image (default: the
#                                  distro's entry in DISTRO_IMAGES)
#   OUTPUT_DIR=<dir>               directory holding the .debs (default output/)

# ---------------------------------------------------------------------------
# Locate repo root and load the distro table from config.sh without running
# the rest of config.sh (it detects the host distro and makes network calls).
# ---------------------------------------------------------------------------
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}" 2>/dev/null \
        || (cd "${scriptpath}/${relativepath}" && pwd))
fi
eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${toolpath}/config.sh")"
OUTPUT_DIR="${OUTPUT_DIR:-${toolpath}/output}"

# ---------------------------------------------------------------------------
# 1. Validate the distro label. It selects the image and the filename glob.
# ---------------------------------------------------------------------------
DISTRO_LABEL="${1:-}"
# Exact match against the list. The label is not used as an array subscript
# until it has passed this check.
label_ok=false
for valid_distro in "${VALID_DISTROS[@]}"; do
    [[ "${DISTRO_LABEL}" == "${valid_distro}" ]] && label_ok=true
done
if [[ "${label_ok}" != "true" ]]; then
    echo "Usage: $0 <distro-label>   (one of: ${VALID_DISTROS[*]})" >&2
    exit 1
fi
VERSION_ID="${DISTRO_VERSION_IDS[${DISTRO_LABEL}]}"

echo ""
echo "========================================"
echo ">>> smoke_install.sh: apt-install proof for ${DISTRO_LABEL}"
echo "========================================"

# ---------------------------------------------------------------------------
# 2. Select and validate the container runtime. The value is used as a
#    command, so anything other than docker or podman is rejected. Without an
#    override, prefer docker, else podman.
# ---------------------------------------------------------------------------
RUNTIME=""
if [[ -n "${SMOKE_RUNTIME:-}" ]]; then
    case "${SMOKE_RUNTIME}" in
        docker|podman)
            if ! command -v "${SMOKE_RUNTIME}" &>/dev/null; then
                echo "ERROR: SMOKE_RUNTIME='${SMOKE_RUNTIME}' requested but '${SMOKE_RUNTIME}' is not on PATH." >&2
                exit 1
            fi
            RUNTIME="${SMOKE_RUNTIME}"
            ;;
        *)
            echo "ERROR: SMOKE_RUNTIME must be exactly 'docker' or 'podman' (got '${SMOKE_RUNTIME}')." >&2
            exit 1
            ;;
    esac
elif command -v docker &>/dev/null; then
    RUNTIME="docker"
elif command -v podman &>/dev/null; then
    RUNTIME="podman"
else
    echo "ERROR: no container runtime found. Install docker or podman." >&2
    exit 1
fi
echo "Container runtime: ${RUNTIME}"

# ---------------------------------------------------------------------------
# 3. Select the base image. An explicit SMOKE_IMAGE override wins and is
#    checked against a conservative image-name pattern, since it is passed to
#    the runtime.
# ---------------------------------------------------------------------------
IMAGE="${SMOKE_IMAGE:-${DISTRO_IMAGES[${DISTRO_LABEL}]}}"
if [[ ! "${IMAGE}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]]; then
    echo "ERROR: image '${IMAGE}' is not a valid image name." >&2
    exit 1
fi
if ! "${RUNTIME}" pull "${IMAGE}"; then
    echo "ERROR: could not pull ${IMAGE}. Set SMOKE_IMAGE to a reachable image." >&2
    exit 1
fi
echo "Base image: ${IMAGE}"

# ---------------------------------------------------------------------------
# 4. Confirm the .debs for this distro exist. The glob includes the
#    ~deb{VERSION_ID} suffix so a .deb built for another release is never
#    tested by mistake. skopeo is the main proof (it links libgpgme and
#    libsubid, whose package names differ between releases); podman is a
#    second, best-effort proof.
# ---------------------------------------------------------------------------
if [[ ! -d "${OUTPUT_DIR}" ]]; then
    echo "ERROR: output directory not found: ${OUTPUT_DIR}" >&2
    echo "  Build the ${DISTRO_LABEL} packages first (DISTRO=${DISTRO_LABEL} ./scripts/package_all.sh)." >&2
    exit 1
fi

DEB_GLOB_SUFFIX="*~deb${VERSION_ID}.podman*_*.deb"
shopt -s nullglob
# shellcheck disable=SC2206
skopeo_debs=( "${OUTPUT_DIR}"/podman-skopeo_${DEB_GLOB_SUFFIX} )
# shellcheck disable=SC2206
configs_debs=( "${OUTPUT_DIR}"/podman-container-configs_${DEB_GLOB_SUFFIX} )
# shellcheck disable=SC2206
podman_debs=( "${OUTPUT_DIR}"/podman-podman_${DEB_GLOB_SUFFIX} )
shopt -u nullglob

if [[ "${#skopeo_debs[@]}" -eq 0 || "${#configs_debs[@]}" -eq 0 ]]; then
    echo "ERROR: podman-skopeo and podman-container-configs .debs for ${DISTRO_LABEL} (~deb${VERSION_ID}) not found in ${OUTPUT_DIR}." >&2
    echo "  Build the ${DISTRO_LABEL} packages first (DISTRO=${DISTRO_LABEL} ./scripts/package_all.sh)." >&2
    exit 1
fi
skopeo_deb="$(basename "${skopeo_debs[0]}")"
configs_deb="$(basename "${configs_debs[0]}")"
podman_deb=""
if [[ "${#podman_debs[@]}" -gt 0 ]]; then
    podman_deb="$(basename "${podman_debs[0]}")"
fi
echo "skopeo .deb:  ${skopeo_deb}"
echo "configs .deb: ${configs_deb}"
echo "podman .deb:  ${podman_deb:-<not built>}"

# ---------------------------------------------------------------------------
# 5. Install inside a throwaway container with output/ mounted at /out.
#    skopeo.yaml depends on podman-container-configs, which is not in the
#    Debian archive, so both local .debs go into one apt-get call and apt
#    needs the archive only for the system libraries. This install has no
#    `|| true`: a wrong system dependency name must fail the run.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Installing skopeo (and podman if present) inside ${IMAGE} via ${RUNTIME}"
echo "----------------------------------------"

"${RUNTIME}" run --rm \
    -v "${OUTPUT_DIR}:/out:ro" \
    -e DEBIAN_FRONTEND=noninteractive \
    -e SKOPEO_DEB="${skopeo_deb}" \
    -e CONFIGS_DEB="${configs_deb}" \
    -e PODMAN_DEB="${podman_deb}" \
    "${IMAGE}" \
    bash -c '
        set -euo pipefail
        apt-get update

        echo ">>> apt-get install /out/${CONFIGS_DEB} /out/${SKOPEO_DEB}"
        apt-get install -y "/out/${CONFIGS_DEB}" "/out/${SKOPEO_DEB}"

        # podman depends on other podman-* packages that are not in the
        # archive, so this install is best-effort. The skopeo install above
        # is the proof.
        if [ -n "${PODMAN_DEB}" ]; then
            echo ">>> apt-get install /out/${PODMAN_DEB}"
            apt-get install -y "/out/${PODMAN_DEB}" || \
                echo "NOTE: podman install did not complete (sibling podman-* deps are not in the archive); the skopeo result stands." >&2
        fi

        command -v skopeo
        skopeo --version
        echo ">>> SMOKE PASS: skopeo installed and runs"
    '

echo ""
echo "========================================"
echo ">>> smoke_install.sh: PASS"
echo "========================================"
echo "  ${DISTRO_LABEL} .debs apt-installed cleanly on ${IMAGE}."
echo ""
exit 0
