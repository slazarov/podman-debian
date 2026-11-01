#!/bin/bash
set -euo pipefail

# ============================================================================
# check_republish_needed.sh
# ============================================================================
# Decides whether a `stable` or `v5` build (manual dispatch or daily cron) would
# produce anything new, by comparing the versions that WOULD be built — resolved by
# scripts/resolve_versions.sh from versions-${track}.env — against what is already
# published in the live APT repository.
#
# Emits `skip=true`  -> every tagged component is already published at the
#                       target version on every distro;
#                       the build+publish is a no-op and can be skipped.
# Emits `skip=false` -> at least one component differs, OR resolution/fetch was
#                       uncertain. ALWAYS the safe default: this guard can only
#                       ever prevent a redundant rebuild, never skip a needed
#                       one. Any error path falls through to skip=false.
#
# Usage:  check_republish_needed.sh <stable|v5> [repo-url]
# Output: writes `skip=<bool>` to stdout and to $GITHUB_OUTPUT when set.
#
# Scope / deliberate exclusions:
#   * `pasta` is NOT compared. build_pasta.sh versions it by `date +%Y%m%d`
#     (it has no upstream tag pin on any track), so it changes every day. A
#     stable/v5 rebuild therefore always yields a fresh pasta even when every
#     pinned component is unchanged. Comparing it would make this guard never
#     fire. pasta still rides along on whatever build a real component change
#     triggers, and the nightly track refreshes it daily.
#   * `nightly` is out of scope: the workflow's `check-changes` job already
#     guards the scheduled nightly run via upstream HEAD SHAs.
#
# Canonical version-string logic lives in scripts/package_all.sh
# (extract_version, VERSION_SUFFIX). The minimal subset needed here is
# reproduced below and pinned by tests/test_check_republish.sh — keep the two
# in sync if package_all.sh's transformation changes.
# ============================================================================

REPO_URL_DEFAULT="${REPO_URL_DEFAULT:-https://slazarov.github.io/podman-debian}"

_check_republish_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PACKAGE_REVISION (the N in ~debNN.podmanN), shared with config.sh.
# shellcheck source=scripts/package_revision.sh
source "${_check_republish_dir}/package_revision.sh"

# VALID_DISTROS, VALID_ARCHES and DISTRO_VERSION_IDS (the NN in ~debNN), read
# from the distro table in config.sh without running the rest of config.sh.
eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${_check_republish_dir}/../config.sh")"

# component | deb package name | resolved *_TAG var | upstream repo (provenance)
# pasta is intentionally absent (see header). container-configs uses the
# namespaced container-libs repo whose tags look like `common/vX.Y.Z`.
COMPONENT_ROWS=(
    "podman|podman-podman|PODMAN_TAG|https://github.com/containers/podman.git"
    "crun|podman-crun|CRUN_TAG|https://github.com/containers/crun.git"
    "conmon|podman-conmon|CONMON_TAG|https://github.com/containers/conmon.git"
    "netavark|podman-netavark|NETAVARK_TAG|https://github.com/containers/netavark.git"
    "aardvark-dns|podman-aardvark-dns|AARDVARK_DNS_TAG|https://github.com/containers/aardvark-dns.git"
    "fuse-overlayfs|podman-fuse-overlayfs|FUSE_OVERLAYFS_TAG|https://github.com/containers/fuse-overlayfs.git"
    "catatonit|podman-catatonit|CATATONIT_TAG|https://github.com/openSUSE/catatonit.git"
    "buildah|podman-buildah|BUILDAH_TAG|https://github.com/containers/buildah.git"
    "skopeo|podman-skopeo|SKOPEO_TAG|https://github.com/containers/skopeo.git"
    "toolbox|podman-toolbx|TOOLBOX_TAG|https://github.com/containers/toolbox.git"
    "container-configs|podman-container-configs|CONTAINER_LIBS_TAG|https://github.com/containers/container-libs.git"
)


# ----------------------------------------------------------------------------
# Helpers (pure — unit-tested via tests/test_check_republish.sh)
# ----------------------------------------------------------------------------

# extract_base <tag> <component> -> upstream base version with no distro suffix.
# Mirrors scripts/package_all.sh:extract_version for the resolved-tag cases.
extract_base() {
    local ltag="$1"
    local lcomponent="$2"
    case "${lcomponent}" in
        container-configs)
            # namespaced tag: common/v0.67.1 -> 0.67.1
            echo "${ltag}" | sed 's|^.*/v||'
            ;;
        *)
            # standard: strip a leading v (v5.8.2 -> 5.8.2; 1.28 -> 1.28)
            echo "${ltag#v}"
            ;;
    esac
}

# get_pkg_version <packages-file> <package-name> -> Version field of the first
# matching stanza, or empty. reprepro keeps one version per package per suite.
get_pkg_version() {
    local lfile="$1"
    local lpkg="$2"
    awk -v p="${lpkg}" '
        /^Package:/ { cur = $2 }
        /^Version:/ { if (cur == p) { print $2; exit } }
    ' "${lfile}"
}

# emit_skip <true|false> [reason] — write the decision and exit 0. The guard
# itself never fails the workflow; an indecisive guard must default to building.
emit_skip() {
    local lvalue="$1"
    local lreason="${2:-}"
    [[ -n "${lreason}" ]] && echo ">>> ${lreason}" >&2
    echo ">>> Decision: skip=${lvalue}" >&2
    echo "skip=${lvalue}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "skip=${lvalue}" >> "${GITHUB_OUTPUT}"
    fi
    exit 0
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    local track="${1:-}"
    local repo_url="${2:-${REPO_URL_DEFAULT}}"

    case "${track}" in
        stable|v5) ;;
        *) emit_skip false "Track '${track}' is not stable/v5, so it is not guarded; build proceeds." ;;
    esac

    echo ">>> Republish guard: track=${track} repo=${repo_url}" >&2

    # Resolve target tags with the SAME resolver the build uses, so the guard's
    # targets are exactly what a build would produce (versions-${track}.env policy).
    # The resolver distinguishes its two HOLD causes by exit code:
    #   3 = deterministic (upstream reachable, nothing soaked yet) -> genuinely
    #       nothing to build -> skip=true (quiet).
    #   other non-zero = uncertain (upstream unreachable) -> we do NOT know, so honor
    #       this guard's "never skip a needed build" contract and build (skip=false).
    local script_dir repo_root policy resolver_out rrc
    script_dir="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"
    repo_root="$(cd "${script_dir}/.." && pwd)"
    policy="${repo_root}/versions-${track}.env"
    if [[ ! -f "${policy}" ]]; then
        emit_skip false "Policy file ${policy} not found; cannot resolve ${track} targets."
    fi
    resolver_out="$( "${script_dir}/resolve_versions.sh" "${policy}" 2>/dev/null )" && rrc=0 || rrc=$?
    if [[ "${rrc}" -eq 3 ]]; then
        emit_skip true "Resolver: no soaked target yet for ${track} (upstream reachable); nothing to build."
    elif [[ "${rrc}" -ne 0 ]]; then
        emit_skip false "Resolver uncertain for ${track} (upstream unreachable); build to be safe."
    fi
    # shellcheck disable=SC1090
    eval "${resolver_out}"

    # Download each distro's published Packages index once.
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" EXIT

    local distro version_id arch suite base_url pkgfile
    for distro in "${VALID_DISTROS[@]}"; do
        suite="${track}-${distro}"
        for arch in "${VALID_ARCHES[@]}"; do
            base_url="${repo_url}/dists/${suite}/main/binary-${arch}/Packages"
            pkgfile="${tmpdir}/${distro}_${arch}.Packages"
            # Prefer the gzipped index; fall back to the uncompressed Packages.
            if ! curl -sfL "${base_url}.gz" 2>/dev/null | gunzip -c > "${pkgfile}" 2>/dev/null \
                || [[ ! -s "${pkgfile}" ]]; then
                if ! curl -sfL "${base_url}" -o "${pkgfile}" 2>/dev/null || [[ ! -s "${pkgfile}" ]]; then
                    emit_skip false "Could not fetch ${base_url}{.gz,} (suite not published yet?). Build to populate it."
                fi
            fi
        done
    done

    # Compare every tagged component (pasta excluded) across all indices.
    local row comp pkg tagvar tag base target published
    for row in "${COMPONENT_ROWS[@]}"; do
        # The 4th column (upstream repo URL) documents provenance but is no longer
        # read here (the resolver owns tag resolution), so it is discarded into `_`.
        IFS='|' read -r comp pkg tagvar _ <<< "${row}"

        # Tag comes from the resolver's materialized environment (eval'd above),
        # the single source of truth shared with the build.
        tag="${!tagvar:-}"
        [[ -z "${tag}" ]] && emit_skip false "Resolved ${tagvar} is empty for ${comp}. Build."

        base=$(extract_base "${tag}" "${comp}")
        [[ -z "${base}" ]] && emit_skip false "Empty base version for ${comp} (tag '${tag}'). Build."

        for distro in "${VALID_DISTROS[@]}"; do
            version_id="${DISTRO_VERSION_IDS[${distro}]}"
            target="${base}~deb${version_id}.podman${PACKAGE_REVISION}"
            for arch in "${VALID_ARCHES[@]}"; do
                pkgfile="${tmpdir}/${distro}_${arch}.Packages"
                published=$(get_pkg_version "${pkgfile}" "${pkg}")
                if [[ "${published}" != "${target}" ]]; then
                    emit_skip false \
                        "${pkg} differs on ${track}-${distro}/${arch}: published='${published:-<absent>}' target='${target}'. Build."
                fi
            done
        done
        echo ">>> ${pkg}: ${base} already published on every distro." >&2
    done

    emit_skip true "All ${#COMPONENT_ROWS[@]} tagged components already published at target versions (pasta excluded)."
}

# Only run when executed directly, so tests can source the helpers.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
