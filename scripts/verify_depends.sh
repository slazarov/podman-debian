#!/bin/bash

# Abort on Error
set -euo pipefail

# verify_depends.sh - check the ldd/dpkg-query dependency detector on a real
# build host, plus a render-and-parse check of the ${DETECTED_DEPENDS}
# injection into the nFPM YAMLs.
#
# Run it on a Debian host or container with:
#   - a populated DESTDIR staging tree (the freshly-built component binaries),
#   - dpkg / dpkg-query, ldd, realpath, envsubst, and nfpm on PATH.
#
# It sources functions.sh (which tail-sources config.sh) to reuse the exact
# detect_runtime_depends() the build uses, and replicates package_all.sh's
# COMPONENT_BINARIES map and envsubst render so the validation exercises the
# real injection path, not a parallel reimplementation.
#
# Parts:
#   A. Detector baseline: run detect_runtime_depends on every component's
#      binaries, print the detected set, and assert it equals the known
#      library set for the distro under test (bookworm or trixie). Library
#      package names differ between the two (trixie has the 64-bit time_t
#      "t64" renames and a newer libsubid), so each has its own baseline.
#   B. Render-and-parse: render each component YAML via envsubst and confirm
#      `nfpm pkg` parses it for every supported distro, checking the
#      empty-deps and mixed-static-deps cases.

# ---------------------------------------------------------------------------
# Bootstrap: locate the repo root and source the real detector + config.
# ---------------------------------------------------------------------------
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}")
fi

# functions.sh tail-sources config.sh, which exports ARCH, DISTRO_VERSION_ID,
# DISTRO_LABEL and VERSION_SUFFIX (DISTRO override, else /etc/os-release).
# detect_runtime_depends comes from functions.sh.
# shellcheck source=/dev/null
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing (mirrors package_all.sh house style).
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

NFPM_DIR="${toolpath}/packaging/nfpm"

# The host's distro: its package database answers dpkg-query -S, so the
# baseline in Part A must be this one.
HOST_DISTRO_LABEL="${DISTRO_LABEL}"

echo ""
echo "========================================"
echo ">>> verify_depends.sh: detector baseline + render/parse"
echo "========================================"
echo "DISTRO:            ${HOST_DISTRO_LABEL} (${DISTRO_VERSION_ID})"
echo "DESTDIR:           ${DESTDIR:-<unset>}"
echo "ARCH:              ${ARCH:-<unset>}"
echo ""

# ---------------------------------------------------------------------------
# Prerequisites — fail loud, never silently skip (this is a proof gate).
# ---------------------------------------------------------------------------
if [[ -z "${DESTDIR:-}" || ! -d "${DESTDIR}" ]]; then
    echo "ERROR: DESTDIR must point at a populated staging tree (got '${DESTDIR:-<unset>}')." >&2
    echo "  Run the build scripts with DESTDIR set before running verify_depends.sh." >&2
    exit 1
fi
for tool in dpkg-query ldd realpath envsubst nfpm; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "ERROR: required tool '${tool}' not found on PATH — verify_depends.sh must run on a Debian build host." >&2
        exit 1
    fi
done

# Component maps (COMPONENT_BINARIES, INJECT_ONLY_DEPENDS) — shared with
# scripts/package_all.sh so the packaging and verification paths cannot drift.
source "${toolpath}/scripts/component_maps.sh"

# ---------------------------------------------------------------------------
# Expected system-library depends per distro and component.
#
# The detected set must equal the baseline (functional equivalence, not
# string order). A name detected that is not in the baseline, or a baseline
# name that is not detected, is a FAIL, so a wrong detected set cannot pass.
# crun links exactly one JSON parser, chosen by the build host; the _ALT map
# accepts either.
#
# fuse-overlayfs and catatonit are usually linked statically and have no
# baseline; their detected set is printed for the record.
# ---------------------------------------------------------------------------
declare -A BASELINE=(
    ["bookworm:podman"]="libgpgme11 libseccomp2"
    ["bookworm:buildah"]="libgpgme11 libseccomp2"
    ["bookworm:skopeo"]="libgpgme11 libsubid4"
    ["bookworm:crun"]="libseccomp2 libsystemd0 libcap2"
    ["bookworm:conmon"]="libglib2.0-0 libsystemd0"
    ["trixie:podman"]="libgpgme11t64 libseccomp2"
    ["trixie:buildah"]="libgpgme11t64 libseccomp2"
    ["trixie:skopeo"]="libgpgme11t64 libsubid5"
    ["trixie:crun"]="libseccomp2 libsystemd0 libcap2"
    ["trixie:conmon"]="libglib2.0-0t64 libsystemd0"
)
declare -A BASELINE_ALT=(
    ["bookworm:crun"]="libjson-c5 libyajl2"
    ["trixie:crun"]="libjson-c5 libyajl2"
)

# Helper: is $1 present in the space-separated list $2 ?
in_list() {
    local needle="$1" hay="$2" item
    for item in ${hay}; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Part A: detected set must equal the baseline for this distro.
# ---------------------------------------------------------------------------
echo ">>> Part A: detector baseline (${HOST_DISTRO_LABEL})"
echo "----------------------------------------"

partA_fail=0
# Stable component ordering for deterministic output.
for component in podman crun conmon netavark aardvark-dns pasta fuse-overlayfs catatonit buildah skopeo; do
    [[ -v "COMPONENT_BINARIES[$component]" ]] || continue

    component_bins=()
    for rel_bin in ${COMPONENT_BINARIES[$component]}; do
        component_bins+=("${DESTDIR}/${rel_bin}")
    done

    # Run the real detector (no '|| true': an unmapped soname aborts).
    detected="$(detect_runtime_depends "${component_bins[@]}" | tr '\n' ' ')"
    detected="${detected% }"
    echo "  ${component}: detected = [${detected}]"

    key="${HOST_DISTRO_LABEL}:${component}"
    if [[ ! -v "BASELINE[$key]" ]]; then
        echo "    (no baseline for ${component}; detected set recorded only)"
        continue
    fi

    baseline="${BASELINE[$key]}"
    alt="${BASELINE_ALT[$key]:-}"

    # Per-component failure flag, so a later passing component still prints
    # its PASS line after an earlier one failed.
    comp_fail=0

    # Every detected name must be in the baseline or the accepted alternatives.
    for name in ${detected}; do
        if in_list "${name}" "${baseline}"; then
            continue
        fi
        if [[ -n "${alt}" ]] && in_list "${name}" "${alt}"; then
            continue
        fi
        echo "    FAIL: ${component} detected unexpected dep '${name}' not in the ${HOST_DISTRO_LABEL} baseline [${baseline}${alt:+ | alt: ${alt}}]" >&2
        comp_fail=1
    done

    # Every baseline name must be detected, else a dependency was silently
    # dropped.
    for name in ${baseline}; do
        if ! in_list "${name}" "${detected}"; then
            echo "    FAIL: ${component} is missing expected baseline dep '${name}' (detected: [${detected}])" >&2
            comp_fail=1
        fi
    done

    # crun must link exactly one of the accepted JSON parsers.
    if [[ -n "${alt}" ]]; then
        found_alt=0
        for name in ${alt}; do
            in_list "${name}" "${detected}" && found_alt=$((found_alt + 1))
        done
        if [[ "${found_alt}" -ne 1 ]]; then
            echo "    FAIL: ${component} must link exactly one JSON parser from [${alt}] (detected: [${detected}])" >&2
            comp_fail=1
        fi
    fi

    if [[ "${comp_fail}" -eq 0 ]]; then
        echo "    PASS: ${component} detected set equals the ${HOST_DISTRO_LABEL} baseline"
    else
        partA_fail=1
    fi
done

if [[ "${partA_fail}" -ne 0 ]]; then
    echo "" >&2
    echo "FAIL: Part A: ${HOST_DISTRO_LABEL} detected set diverged from its baseline (see above)." >&2
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Part B: render-and-parse every nFPM YAML for every supported distro.
# Replicates package_all.sh's envsubst render per component and lets `nfpm pkg`
# parse it. Covers the mixed-static-deps case (podman/buildah/skopeo carry
# literal podman-* deps + the injected block) and the inject-only case
# (crun/conmon/pasta) and the no-binary case (container-configs/toolbox).
# ---------------------------------------------------------------------------
echo ">>> Part B: render-and-parse every nFPM YAML (${VALID_DISTROS[*]})"
echo "----------------------------------------"

tmp_render_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_render_dir}"; error_handler $? $LINENO "$BASH_SOURCE"' ERR

# All component YAMLs in NFPM_DIR (suite.yaml has no ${DETECTED_DEPENDS} but
# still must render; we render it too for completeness).
render_one() {
    local yaml="$1" comp="$2" detected_fragment="$3"
    local rendered="${tmp_render_dir}/nfpm-${comp}.yaml"

    # Mirror package_all.sh: export the same four vars and allowlist them.
    export VERSION="0.0.0~deb${DISTRO_VERSION_ID}.podman1"
    export ARCH="${ARCH}"
    export DESTDIR="${DESTDIR}"
    export DETECTED_DEPENDS="${detected_fragment}"

    envsubst '${VERSION} ${ARCH} ${DESTDIR} ${DETECTED_DEPENDS}' < "${yaml}" > "${rendered}"

    # `nfpm pkg` parses+validates the config; a YAML error or garbled depends
    # block makes it exit non-zero. Target a throwaway dir.
    if ! nfpm pkg --config "${rendered}" --packager deb --target "${tmp_render_dir}" >/dev/null 2>"${tmp_render_dir}/nfpm.err"; then
        echo "    FAIL: nfpm rejected rendered ${comp}.yaml (DISTRO=${DISTRO_VERSION_ID})" >&2
        sed 's/^/      /' "${tmp_render_dir}/nfpm.err" >&2
        return 1
    fi

    # Assert the rendered depends block is well-formed: if the source YAML has a
    # `depends:` key, it must not be empty/garbled (no dangling `- ` or a
    # `depends:` immediately followed by a non-list line).
    if grep -q '^depends:' "${rendered}"; then
        # Collect the indented list items under depends:.
        local dep_lines
        dep_lines="$(awk '/^depends:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]]*-[[:space:]]*[^[:space:]]/{print}' "${rendered}")"
        if [[ -z "${dep_lines}" ]]; then
            echo "    FAIL: ${comp}.yaml has a depends: key but no well-formed list items after render (DISTRO=${DISTRO_VERSION_ID})" >&2
            return 1
        fi
    fi
    echo "    PASS: ${comp}.yaml renders + parses (DISTRO=${DISTRO_VERSION_ID})"
    return 0
}

partB_fail=0
for distro_under_test in "${VALID_DISTROS[@]}"; do
    DISTRO_VERSION_ID="${DISTRO_VERSION_IDS[${distro_under_test}]}"
    echo "  -- DISTRO=${DISTRO_VERSION_ID} --"
    for yaml in "${NFPM_DIR}"/*.yaml; do
        comp="$(basename "${yaml}" .yaml)"

        # Compute the injected fragment exactly as package_all.sh does: real
        # detection for components with binaries, empty otherwise. Detection is
        # distro-independent here (the binaries and package database are the
        # build host's), so this renders the shape for every distro version
        # string. The depends names come from the host, which Part A checks.
        if [[ -v "COMPONENT_BINARIES[$comp]" ]]; then
            cbins=()
            for rel_bin in ${COMPONENT_BINARIES[$comp]}; do
                cbins+=("${DESTDIR}/${rel_bin}")
            done
            detected_items="$(detect_runtime_depends "${cbins[@]}" | sed 's/^/  - /')"
            # Inject-only YAMLs get a self-contained depends: block
            # (header + items) only when non-empty; others get items only.
            if [[ -v "INJECT_ONLY_DEPENDS[$comp]" ]]; then
                if [[ -n "${detected_items}" ]]; then
                    fragment="depends:"$'\n'"${detected_items}"
                else
                    fragment=""
                fi
            else
                fragment="${detected_items}"
            fi
        else
            fragment=""
        fi

        if ! render_one "${yaml}" "${comp}" "${fragment}"; then
            partB_fail=1
        fi
    done
done

rm -rf "${tmp_render_dir}"
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

if [[ "${partB_fail}" -ne 0 ]]; then
    echo "" >&2
    echo "FAIL: Part B — one or more nFPM YAMLs failed to render+parse (see above)." >&2
    exit 1
fi
echo ""

echo "========================================"
echo ">>> verify_depends.sh: ALL CHECKS PASSED"
echo "========================================"
echo "  - Part A: ${HOST_DISTRO_LABEL} detected set equals its baseline"
echo "  - Part B: every nFPM YAML renders + parses for ${VALID_DISTROS[*]}"
echo ""
exit 0
