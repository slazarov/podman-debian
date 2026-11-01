#!/bin/bash

# resolve_versions.sh -- materialize concrete component *_TAG values for an
# auto-updating release track from a policy file (versions-stable.env / versions-v5.env).
#
# Usage:
#   ./scripts/resolve_versions.sh versions-stable.env   # prints `export <C>_TAG="..."`
#   eval "$(./scripts/resolve_versions.sh versions-v5.env)"
#
# Resolution precedence per component (highest priority first):
#   1. <C>_TAG   set  -> freeze verbatim (escape hatch); soak NOT applied.
#   2. buildah only, no BUILDAH_TAG -> derive the podman-blessed version from podman's
#      go.mod at the resolved PODMAN_TAG (get_required_buildah_tag); soak NOT applied
#      (the pairing is already blessed by an soaked podman). Falls back to 3/4.
#   3. <C>_SERIES set -> highest upstream tag in that anchored dotted-version series
#      (e.g. "6" -> 6.x, "1.43" -> 1.43.x) that has SOAKED.
#   4. neither -> float to the highest SOAKED stable tag.
#
# Soak: a non-frozen/non-derived tag is only adopted once its target commit is at
# least STABLE_SOAK_DAYS old (default 7). Candidates are walked highest->lowest and
# the first soaked one wins. If nothing in a series/float has soaked yet, or the
# remote is unreachable, that component HOLDS: the resolver exits non-zero and emits
# NO partial environment, so a scheduled build treats the run as skip (fail-closed).
#
# Injectable STABLE_NOW_EPOCH overrides "now" for deterministic offline tests.
#
# Only the pure tag-selection helpers from functions.sh are needed, so config.sh
# (distro detection, which fails off Debian, and network toolchain detection) is
# skipped via SKIP_CONFIG_SOURCE. This keeps the resolver light and
# unit-testable on any host.

# Toolpath bootstrap (scripts/ -> repo root is ../). Set BEFORE sourcing functions.sh
# so functions.sh does not re-derive it (avoids the macOS realpath quirk).
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)
    toolpath=$(cd "${scriptpath}/${relativepath}" && pwd)
fi

export SKIP_CONFIG_SOURCE=1
# shellcheck source=functions.sh
source "${toolpath}/functions.sh"

# Component table: name | *_TAG var | *_SERIES var | upstream repo URL.
# Emit order = this order. container-configs is the only namespaced component (its
# tags are common/vX.Y.Z and its tag var is CONTAINER_LIBS_TAG -- the documented
# triple naming mismatch). pasta (date-versioned HEAD) and sccache/protoc (build
# tools, pinned exactly in the policy file) are intentionally ABSENT.
# go-md2man is ALSO intentionally ABSENT: it is build-only man-page tooling with no
# packaging/nfpm/*md2man* package and no entry in check_republish_needed.sh's compare
# set, so resolving it here would let an unreachable cpuguy83/go-md2man remote HOLD
# the whole track without ever gating a release. build_go-md2man.sh:36 does
# git_checkout "${GOMD2MAN_TAG}" and, with GOMD2MAN_TAG unset (config.sh default),
# falls through to get_latest_tag -- it floats at build time, exactly as before, and
# now no longer blocks stable/v5 resolution. This also keeps the resolver's and the
# guard's component sets reconciled (neither lists go-md2man).
COMPONENT_ROWS=(
    "podman|PODMAN_TAG|PODMAN_SERIES|https://github.com/containers/podman.git"
    "buildah|BUILDAH_TAG|BUILDAH_SERIES|https://github.com/containers/buildah.git"
    "crun|CRUN_TAG|CRUN_SERIES|https://github.com/containers/crun.git"
    "conmon|CONMON_TAG|CONMON_SERIES|https://github.com/containers/conmon.git"
    "netavark|NETAVARK_TAG|NETAVARK_SERIES|https://github.com/containers/netavark.git"
    "aardvark-dns|AARDVARK_DNS_TAG|AARDVARK_DNS_SERIES|https://github.com/containers/aardvark-dns.git"
    "skopeo|SKOPEO_TAG|SKOPEO_SERIES|https://github.com/containers/skopeo.git"
    "toolbox|TOOLBOX_TAG|TOOLBOX_SERIES|https://github.com/containers/toolbox.git"
    "fuse-overlayfs|FUSE_OVERLAYFS_TAG|FUSE_OVERLAYFS_SERIES|https://github.com/containers/fuse-overlayfs.git"
    "catatonit|CATATONIT_TAG|CATATONIT_SERIES|https://github.com/openSUSE/catatonit.git"
    "container-configs|CONTAINER_LIBS_TAG|CONTAINER_LIBS_SERIES|https://github.com/containers/container-libs.git"
)

# _resolver_now_epoch -- "now" in Unix seconds, overridable for tests.
_resolver_now_epoch() {
    if [[ -n "${STABLE_NOW_EPOCH:-}" ]]; then
        printf '%s\n' "${STABLE_NOW_EPOCH}"
    else
        date -u +%s
    fi
}

# A HOLD has two distinct causes that must be told apart downstream:
#   * DETERMINISTIC (return 1) — upstream was reachable but nothing qualifies yet
#     (no tag in the series, or every candidate is still inside the soak window).
#     There is genuinely nothing to build; the guard skips quietly, the build
#     step exits 0.
#   * UNCERTAIN (return 2) — upstream was unreachable, or a candidate's date could
#     not be fetched. We do NOT know the real answer; per the guard's "never skip
#     a needed build" contract this must build (guard skip=false), and a build-time
#     occurrence fails loudly.
# resolve_all aggregates these into its own exit codes: 0 ok, 3 deterministic, 1 uncertain.

# _soak_ok <url> <tag> -- 0 = soaked (>= STABLE_SOAK_DAYS old); 1 = reachable but
# too fresh (deterministic); 2 = date could not be fetched (uncertain).
_soak_ok() {
    local lurl="$1"
    local ltag="$2"
    local lsoak="${STABLE_SOAK_DAYS:-7}"
    if [[ "${lsoak}" -le 0 ]]; then
        return 0
    fi
    local lepoch lnow lage
    if ! lepoch=$(tag_commit_epoch "${lurl}" "${ltag}"); then
        return 2
    fi
    lnow=$(_resolver_now_epoch)
    lage=$(( (lnow - lepoch) / 86400 )) || true
    if [[ "${lage}" -ge "${lsoak}" ]]; then
        return 0
    fi
    return 1
}

# _pick_soaked <url> <component> [series] -- highest-version candidate that has
# soaked. Prints the tag + return 0; 1 = reachable but nothing soaked yet
# (deterministic); 2 = uncertain (remote unreachable, or a candidate's date could
# not be fetched — we hold rather than silently adopt an OLDER tag).
_pick_soaked() {
    local lurl="$1"
    local lcomp="$2"
    local lseries="${3:-}"
    local lcandidates lt lrc
    if ! lcandidates=$(list_upstream_tags "${lurl}" "${lcomp}" "${lseries}"); then
        return 2
    fi
    [[ -n "${lcandidates}" ]] || return 1
    while IFS= read -r lt; do
        [[ -n "${lt}" ]] || continue
        _soak_ok "${lurl}" "${lt}" && lrc=0 || lrc=$?
        if [[ "${lrc}" -eq 0 ]]; then
            printf '%s\n' "${lt}"
            return 0
        fi
        if [[ "${lrc}" -eq 2 ]]; then
            return 2
        fi
        # lrc == 1 (too fresh) -> try the next-older candidate
    done <<< "${lcandidates}"
    return 1
}

# resolve_component <component> <tag-var> <series-var> <url> -- print the resolved
# tag + return 0; 1 = deterministic hold; 2 = uncertain hold. Depends on
# RESOLVED_PODMAN_TAG being exported before buildah is resolved (podman is row 1).
resolve_component() {
    local lcomp="$1"
    local ltagvar="$2"
    local lseriesvar="$3"
    local lurl="$4"
    local lexact="${!ltagvar:-}"
    local lseries="${!lseriesvar:-}"
    local ltag lrc

    # 1) Exact freeze -- verbatim, no soak. Trim, and ignore a whitespace-only value
    # so a stray " " never becomes a bogus frozen tag.
    lexact="${lexact#"${lexact%%[![:space:]]*}"}"; lexact="${lexact%"${lexact##*[![:space:]]}"}"
    if [[ -n "${lexact}" ]]; then
        # Surface the freeze so it is never silent -- whether it is a deliberate
        # policy pin or a leftover exported var in a local `eval "$(...)"` run,
        # an ambient *_TAG here overrides all series/soak policy.
        echo "  NOTE ${lcomp}: using exact ${ltagvar}=${lexact} (overrides series/soak policy)" >&2
        printf '%s\n' "${lexact}"
        return 0
    fi

    # Validate an author-set series (policy typo protection): dotted numeric only.
    if [[ -n "${lseries}" ]]; then
        lseries="${lseries#"${lseries%%[![:space:]]*}"}"; lseries="${lseries%"${lseries##*[![:space:]]}"}"
        if [[ ! "${lseries}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo "  ERROR ${lcomp}: malformed ${lseriesvar}='${!lseriesvar}' (want dotted numeric like 6 or 1.43)" >&2
            return 2
        fi
    fi

    # 2) Buildah derivation from podman's go.mod (podman-blessed pairing, no soak),
    # CLAMPED to BUILDAH_SERIES when set: a derived value outside the series falls
    # back to the series cap, so buildah can never cross the compatibility boundary.
    if [[ "${lcomp}" == "buildah" && -n "${RESOLVED_PODMAN_TAG:-}" ]]; then
        if ltag=$(get_required_buildah_tag "${RESOLVED_PODMAN_TAG}"); then
            if [[ -z "${lseries}" || "${ltag#v}" =~ ^${lseries//./\\.}(\.|$) ]]; then
                printf '%s\n' "${ltag}"
                return 0
            fi
            echo "  WARN buildah: derived ${ltag} is outside BUILDAH_SERIES='${lseries}'; using the series cap" >&2
        else
            echo "  WARN buildah: could not derive from podman ${RESOLVED_PODMAN_TAG} go.mod; using BUILDAH_SERIES/float" >&2
        fi
    fi

    # 3) Series cap (soaked).
    if [[ -n "${lseries}" ]]; then
        ltag=$(_pick_soaked "${lurl}" "${lcomp}" "${lseries}") && lrc=0 || lrc=$?
        if [[ "${lrc}" -eq 0 ]]; then printf '%s\n' "${ltag}"; return 0; fi
        if [[ "${lrc}" -eq 2 ]]; then
            echo "  HOLD ${lcomp}: series '${lseries}' unresolved (upstream unreachable)" >&2; return 2
        fi
        echo "  HOLD ${lcomp}: no tag in series '${lseries}' has soaked ${STABLE_SOAK_DAYS:-7}d" >&2
        return 1
    fi

    # 4) Float (soaked).
    ltag=$(_pick_soaked "${lurl}" "${lcomp}") && lrc=0 || lrc=$?
    if [[ "${lrc}" -eq 0 ]]; then printf '%s\n' "${ltag}"; return 0; fi
    if [[ "${lrc}" -eq 2 ]]; then
        echo "  HOLD ${lcomp}: unresolved (upstream unreachable)" >&2; return 2
    fi
    echo "  HOLD ${lcomp}: no soaked tag found" >&2
    return 1
}

# resolve_all [policy-file] -- source the policy (if given), resolve every component,
# print `export <C>_TAG="..."` on stdout. Exit codes: 0 ok; 3 held with only
# deterministic causes (nothing soaked yet — quiet no-op downstream); 1 held with
# at least one uncertainty (upstream unreachable — build to be safe). Never emits a
# partial environment.
resolve_all() {
    local lpolicy="${1:-}"
    if [[ -n "${lpolicy}" ]]; then
        if [[ ! -f "${lpolicy}" ]]; then
            echo "ERROR: policy file not found: ${lpolicy}" >&2
            return 1
        fi
        # shellcheck disable=SC1090
        source "${lpolicy}"
    fi

    STABLE_SOAK_DAYS="${STABLE_SOAK_DAYS:-7}"
    if [[ ! "${STABLE_SOAK_DAYS}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: STABLE_SOAK_DAYS='${STABLE_SOAK_DAYS}' must be a non-negative integer" >&2
        return 1
    fi
    echo ">>> Resolving versions (soak=${STABLE_SOAK_DAYS}d)${lpolicy:+ from ${lpolicy}}" >&2

    local lrow lcomp ltagvar lseriesvar lurl ltag lrc
    local -a lexports=()
    local lheld_det=0 lheld_unc=0

    for lrow in "${COMPONENT_ROWS[@]}"; do
        IFS='|' read -r lcomp ltagvar lseriesvar lurl <<< "${lrow}"
        ltag=$(resolve_component "${lcomp}" "${ltagvar}" "${lseriesvar}" "${lurl}") && lrc=0 || lrc=$?
        if [[ "${lrc}" -eq 0 ]]; then
            lexports+=("export ${ltagvar}=\"${ltag}\"")
            if [[ "${lcomp}" == "podman" ]]; then
                export RESOLVED_PODMAN_TAG="${ltag}"
            fi
            echo "  ${lcomp} -> ${ltag}" >&2
        elif [[ "${lrc}" -eq 2 ]]; then
            lheld_unc=1
        else
            lheld_det=1
        fi
    done

    if [[ "${lheld_unc}" -ne 0 ]]; then
        echo "ERROR: held with upstream uncertainty; not emitting a partial environment" >&2
        return 1
    fi
    if [[ "${lheld_det}" -ne 0 ]]; then
        echo "ERROR: held — no soaked target yet (upstream reachable); nothing to build" >&2
        return 3
    fi

    # Pass through exact build-tool pins from the policy (toolchain, not components).
    if [[ -n "${PROTOC_VERSION:-}" ]]; then
        lexports+=("export PROTOC_VERSION=\"${PROTOC_VERSION}\"")
    fi
    if [[ -n "${PROTOC_TAG:-}" ]]; then
        lexports+=("export PROTOC_TAG=\"${PROTOC_TAG}\"")
    fi

    printf '%s\n' "${lexports[@]}"
}

# Strict mode + ERR trap for UNEXPECTED failures are installed ONLY when executed
# directly (sourcing for unit tests must not flip the caller's options or arm the
# trap). resolve_all runs on the left of `&& / ||`, so its CONTROLLED non-zero exit
# codes (1/3) propagate cleanly without tripping the ERR trap or set -e.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR
    resolve_all "$@" && exit 0 || exit $?
fi
