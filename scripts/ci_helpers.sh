#!/bin/bash

# ci_helpers.sh - small shared helpers for the CI publish pipeline.
#
# Sourceable from any script or workflow step. It does not load config.sh,
# so it works on the GitHub-hosted runner as well as in the Debian build
# containers, and the unit tests can call every function directly
# (tests/test_ci_helpers.sh).
#
# Functions return explicit codes instead of relying on `set -e`, because
# callers often run them inside `if` or `||`, where bash turns errexit off.
#
#   fetch_url                  download with retries and an absent/error split
#   validate_resolved_env      check the resolver output before anyone sources it
#   resolved_env_pairs         print KEY=VALUE pairs from a validated file
#   resolve_track_versions     run the resolver once and map its exit code to hold
#   nightly_record_revisions   list the upstream commits a nightly cell built
#   nightly_detect_changes     compare upstream HEADs against the checkpoint
#   nightly_merge_revisions    fold built revisions into the checkpoint
#   published_distros          pick the distros whose build cell succeeded
#   wait_for_propagation       wait until the live site serves the new InRelease
#   probe_live_suite           decide whether the smoke upgrade scenario can run
#   check_upgraded_versions    check installed packages against the assembled index
#   compiler_cache_report      print sccache/ccache statistics and check use

[[ -n "${_CI_HELPERS_SH_SOURCED:-}" ]] && return 0
_CI_HELPERS_SH_SOURCED=1

# ============================================
# fetch_url
# ============================================
#
# fetch_url <url> <dest>
#
# Downloads <url> into <dest> and tells "the file does not exist" apart from
# "the download did not work":
#
#   0  HTTP 200, the complete body is in <dest>
#   4  HTTP 404 or 410, the file is absent (nothing is written)
#   1  anything else after the retries ran out (nothing is written)
#
# curl errors (DNS, connect, TLS, a body shorter than its Content-Length)
# and HTTP 408, 429 and 5xx are retried up to FETCH_ATTEMPTS times, waiting
# FETCH_RETRY_DELAY seconds times the attempt number in between. Other HTTP
# codes fail at once. The body lands in a temporary file first, so <dest>
# never holds a partial download.
#
# Each request carries a throwaway query string and a no-cache header, so a
# CDN edge does not hand back a copy cached before the last deploy. GitHub
# Pages ignores the query string when it picks the file.
#
# file:// URLs are read straight from disk (the unit tests use them): a
# missing file is absent, anything unreadable is an error.
fetch_url() {
    local lurl="$1"
    local ldest="$2"
    local lattempts="${FETCH_ATTEMPTS:-4}"
    local ldelay="${FETCH_RETRY_DELAY:-2}"
    local lmax_time="${FETCH_MAX_TIME:-300}"

    if [[ -z "${lurl}" || -z "${ldest}" ]]; then
        echo "ERROR: fetch_url needs <url> <dest>" >&2
        return 1
    fi

    if [[ "${lurl}" == file://* ]]; then
        local lpath="${lurl#file://}"
        if [[ -f "${lpath}" ]]; then
            if cp "${lpath}" "${ldest}"; then
                return 0
            fi
            echo "ERROR: could not copy ${lpath}" >&2
            rm -f "${ldest}"
            return 1
        fi
        if [[ -e "${lpath}" ]]; then
            echo "ERROR: ${lpath} exists but is not a regular file" >&2
            return 1
        fi
        return 4
    fi

    local ltmp="${ldest}.part.$$"
    local lsep="?"
    [[ "${lurl}" == *\?* ]] && lsep="&"

    local lerr="${ldest}.err.$$"
    local lattempt=1 lrc lcode lreason
    while true; do
        lrc=0
        lcode="$(curl -sS -L \
            --connect-timeout 20 \
            --max-time "${lmax_time}" \
            -H 'Cache-Control: no-cache' \
            -o "${ltmp}" \
            -w '%{http_code}' \
            "${lurl}${lsep}nocache=$(date +%s)${RANDOM}" 2>"${lerr}")" || lrc=$?

        if [[ "${lrc}" -eq 0 ]]; then
            case "${lcode}" in
                200)
                    rm -f "${lerr}"
                    if mv -f "${ltmp}" "${ldest}"; then
                        return 0
                    fi
                    echo "ERROR: could not move the download into ${ldest}" >&2
                    rm -f "${ltmp}"
                    return 1
                    ;;
                404 | 410)
                    rm -f "${ltmp}" "${lerr}"
                    return 4
                    ;;
                408 | 429 | 5??)
                    lreason="HTTP ${lcode}"
                    ;;
                *)
                    rm -f "${ltmp}" "${lerr}"
                    echo "ERROR: ${lurl} returned HTTP ${lcode}" >&2
                    return 1
                    ;;
            esac
        else
            # Keep curl's own message (DNS, TLS, partial transfer, ...).
            lreason="curl exit ${lrc}: $(tr '\n' ' ' < "${lerr}" 2>/dev/null | sed 's/[[:space:]]*$//')"
        fi

        rm -f "${ltmp}" "${lerr}"
        if [[ "${lattempt}" -ge "${lattempts}" ]]; then
            echo "ERROR: ${lurl} failed after ${lattempt} attempt(s) (${lreason})" >&2
            return 1
        fi
        echo "  retrying ${lurl} (${lreason}, attempt ${lattempt} of ${lattempts})" >&2
        sleep $((ldelay * lattempt))
        lattempt=$((lattempt + 1))
    done
}

# ============================================
# Resolved version environment
# ============================================
#
# resolve_versions.sh prints one `export NAME="value"` line per component.
# The workflow resolves once and hands that text to later jobs, which source
# it or turn it into `env` arguments. Before that happens the text is checked
# line by line: only known names, only plain tag characters, every component
# present exactly once. Anything else is rejected, so a bad resolver run (or
# tampered job output) never reaches a shell.

# Must match the *_TAG column of COMPONENT_ROWS in scripts/resolve_versions.sh
# (tests/test_ci_helpers.sh checks this).
RESOLVED_ENV_REQUIRED_KEYS=(
    PODMAN_TAG BUILDAH_TAG CRUN_TAG CONMON_TAG NETAVARK_TAG AARDVARK_DNS_TAG
    SKOPEO_TAG TOOLBOX_TAG FUSE_OVERLAYFS_TAG CATATONIT_TAG CONTAINER_LIBS_TAG
    PASTA_TAG
)
# Build-tool pins the resolver passes through when the policy sets them.
RESOLVED_ENV_OPTIONAL_KEYS=(PROTOC_VERSION PROTOC_TAG)

# validate_resolved_env <file> -> 0 when valid, 1 otherwise (reasons on stderr).
validate_resolved_env() {
    local lfile="$1"
    if [[ ! -f "${lfile}" || ! -s "${lfile}" ]]; then
        echo "ERROR: resolved environment '${lfile}' is missing or empty" >&2
        return 1
    fi

    local lline lkey lknown lk lbad=0 lnum=0
    local -A lseen=()
    local lre='^export ([A-Z][A-Z0-9_]*)="([A-Za-z0-9._/+~-]+)"$'
    while IFS= read -r lline || [[ -n "${lline}" ]]; do
        lnum=$((lnum + 1))
        [[ -z "${lline}" ]] && continue
        if [[ ! "${lline}" =~ ${lre} ]]; then
            echo "ERROR: resolved environment line ${lnum} is not a plain export: ${lline}" >&2
            lbad=1
            continue
        fi
        lkey="${BASH_REMATCH[1]}"
        lknown=false
        for lk in "${RESOLVED_ENV_REQUIRED_KEYS[@]}" "${RESOLVED_ENV_OPTIONAL_KEYS[@]}"; do
            [[ "${lk}" == "${lkey}" ]] && lknown=true
        done
        if [[ "${lknown}" != "true" ]]; then
            echo "ERROR: resolved environment line ${lnum} sets unknown name ${lkey}" >&2
            lbad=1
            continue
        fi
        if [[ -n "${lseen[${lkey}]:-}" ]]; then
            echo "ERROR: resolved environment sets ${lkey} twice" >&2
            lbad=1
        fi
        lseen[${lkey}]=1
    done < "${lfile}"

    for lk in "${RESOLVED_ENV_REQUIRED_KEYS[@]}"; do
        if [[ -z "${lseen[${lk}]:-}" ]]; then
            echo "ERROR: resolved environment does not set ${lk}" >&2
            lbad=1
        fi
    done
    [[ "${lbad}" -eq 0 ]]
}

# resolved_env_pairs <file> -> KEY=VALUE lines, after validation. Returns 1
# (and prints nothing) when the file is invalid.
resolved_env_pairs() {
    local lfile="$1"
    validate_resolved_env "${lfile}" || return 1
    sed -n 's/^export \([A-Z][A-Z0-9_]*\)="\(.*\)"$/\1=\2/p' "${lfile}"
}

# resolve_track_versions <track> <policy-dir-or-file> <out-file>
#
# Runs the stable/v5 resolver once and writes its exports to <out-file>.
# <policy-dir-or-file> is a policy file, or a directory holding
# versions-<track>.env. RESOLVER overrides the resolver path (the tests use a
# stub). Prints and returns:
#
#   hold=false, 0   resolved; <out-file> passed validate_resolved_env
#   hold=true,  0   exit code 3, a deterministic hold (nothing soaked yet);
#                   there is nothing to build, which is not an error
#   (nothing),  1   any other resolver failure, or output that fails
#                   validation; the caller must fail
resolve_track_versions() {
    local ltrack="$1" lpolicy="$2" lout="$3"
    local lresolver="${RESOLVER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve_versions.sh}"
    local lrc=0

    case "${ltrack}" in
        stable | v5) ;;
        *)
            echo "ERROR: resolve_track_versions: track must be stable or v5 (got '${ltrack}')" >&2
            return 1
            ;;
    esac
    [[ -d "${lpolicy}" ]] && lpolicy="${lpolicy}/versions-${ltrack}.env"
    if [[ ! -f "${lpolicy}" ]]; then
        echo "ERROR: policy file '${lpolicy}' not found" >&2
        return 1
    fi

    "${lresolver}" "${lpolicy}" > "${lout}" || lrc=$?
    if [[ "${lrc}" -eq 3 ]]; then
        echo "Resolver hold for ${ltrack}: no soaked release yet; nothing to build." >&2
        : > "${lout}"
        echo "hold=true"
        return 0
    elif [[ "${lrc}" -ne 0 ]]; then
        echo "ERROR: resolver failed for ${ltrack} (rc=${lrc})" >&2
        return 1
    fi
    if ! validate_resolved_env "${lout}"; then
        echo "ERROR: resolver output for ${ltrack} is invalid" >&2
        return 1
    fi
    echo "hold=false"
}

# ============================================
# Nightly revision checkpoint
# ============================================
#
# The nightly cron skips its build when nothing changed upstream. It compares
# each component's upstream HEAD with a checkpoint of the commits that were
# built AND deployed, per distro. The checkpoint has one line per distro and
# component:
#
#   <distro> <component> <40-hex commit>
#
# A build cell records what it actually compiled (nightly_record_revisions).
# The publish job folds the records of the distros it deployed into the
# checkpoint (nightly_merge_revisions) and saves it only after the deploy
# and the propagation check succeeded. A distro whose cell failed keeps its
# old entries, so the next nightly rebuilds it.

# component | clone directory under build/ | upstream repository
NIGHTLY_SOURCES=(
    "podman|podman|https://github.com/containers/podman.git"
    "buildah|buildah|https://github.com/containers/buildah.git"
    "crun|crun|https://github.com/containers/crun.git"
    "conmon|conmon|https://github.com/containers/conmon.git"
    "netavark|netavark|https://github.com/containers/netavark.git"
    "aardvark-dns|aardvark-dns|https://github.com/containers/aardvark-dns.git"
    "skopeo|skopeo|https://github.com/containers/skopeo.git"
    "fuse-overlayfs|fuse-overlayfs|https://github.com/containers/fuse-overlayfs.git"
    "catatonit|catatonit|https://github.com/openSUSE/catatonit.git"
    "container-libs|container-libs|https://github.com/containers/container-libs.git"
    "pasta|passt|https://passt.top/passt"
    "go-md2man|go-md2man|https://github.com/cpuguy83/go-md2man.git"
    "toolbox|toolbox|https://github.com/containers/toolbox.git"
)

_NIGHTLY_LINE_RE='^[a-z0-9]+ [a-z0-9-]+ [0-9a-f]{40}$'

# nightly_remote_head <url> -> the commit upstream HEAD points at. Returns 1
# when the remote cannot be read. Tests replace this function.
nightly_remote_head() {
    local lurl="$1" lout
    lout="$(git ls-remote "${lurl}" HEAD 2>/dev/null)" || return 1
    lout="$(printf '%s\n' "${lout}" | awk 'NR==1 {print $1}')"
    [[ "${lout}" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s\n' "${lout}"
}

# nightly_record_revisions <build-root> <distro> -> checkpoint lines for every
# component cloned under <build-root>. Returns 1 if a clone is missing or its
# HEAD cannot be read, so a partial record is never produced.
nightly_record_revisions() {
    local lroot="$1" ldistro="$2"
    local lrow lcomp ldir lurl lsha
    local -a lrecords=()
    if [[ ! "${ldistro}" =~ ^[a-z0-9]+$ ]]; then
        echo "ERROR: invalid distro '${ldistro}'" >&2
        return 1
    fi
    for lrow in "${NIGHTLY_SOURCES[@]}"; do
        IFS='|' read -r lcomp ldir lurl <<< "${lrow}"
        if [[ ! -d "${lroot}/${ldir}/.git" ]]; then
            echo "ERROR: no clone of ${lcomp} at ${lroot}/${ldir}" >&2
            return 1
        fi
        if ! lsha="$(git -c safe.directory='*' -C "${lroot}/${ldir}" rev-parse HEAD 2>/dev/null)" \
            || [[ ! "${lsha}" =~ ^[0-9a-f]{40}$ ]]; then
            echo "ERROR: could not read the ${lcomp} commit in ${lroot}/${ldir}" >&2
            return 1
        fi
        lrecords+=("${ldistro} ${lcomp} ${lsha}")
    done
    printf '%s\n' "${lrecords[@]}"
}

# nightly_detect_changes <checkpoint-file> <distro>... -> prints skip=true when
# every component's upstream HEAD matches the checkpoint for every distro,
# skip=false otherwise. A missing checkpoint or an unreadable remote counts
# as a change, so doubt always leads to a build. Details go to stderr.
nightly_detect_changes() {
    local lcheckpoint="$1"
    shift
    local -a ldistros=("$@")
    local lrow lcomp ldir lurl lhead lold ldistro lchanged=false

    if [[ ${#ldistros[@]} -eq 0 ]]; then
        echo "ERROR: nightly_detect_changes needs at least one distro" >&2
        return 1
    fi
    if [[ ! -s "${lcheckpoint}" ]]; then
        echo "No nightly checkpoint yet; building." >&2
        echo "skip=false"
        return 0
    fi

    for lrow in "${NIGHTLY_SOURCES[@]}"; do
        IFS='|' read -r lcomp ldir lurl <<< "${lrow}"
        if ! lhead="$(nightly_remote_head "${lurl}")"; then
            echo "  ${lcomp}: upstream HEAD unreadable; treating as changed" >&2
            lchanged=true
            continue
        fi
        for ldistro in "${ldistros[@]}"; do
            lold="$(awk -v d="${ldistro}" -v c="${lcomp}" '$1 == d && $2 == c {print $3}' "${lcheckpoint}" | tail -n 1)"
            if [[ "${lold}" != "${lhead}" ]]; then
                echo "  ${ldistro}/${lcomp}: ${lold:-<none>} -> ${lhead}" >&2
                lchanged=true
            fi
        done
    done

    if [[ "${lchanged}" == "true" ]]; then
        echo "skip=false"
    else
        echo "No upstream changes since the last deployed nightly." >&2
        echo "skip=true"
    fi
}

# nightly_merge_revisions <checkpoint-in> <checkpoint-out> <revisions-file>...
# Writes the old checkpoint with every (distro, component) entry from the
# revisions files replacing the old one. <checkpoint-in> may be missing.
# Malformed lines in a revisions file fail the merge (return 1); malformed
# lines in the old checkpoint are dropped with a warning.
nightly_merge_revisions() {
    local lin="$1" lout="$2"
    shift 2
    local lf lline
    if [[ $# -eq 0 ]]; then
        echo "ERROR: nightly_merge_revisions needs at least one revisions file" >&2
        return 1
    fi
    for lf in "$@"; do
        if [[ ! -s "${lf}" ]]; then
            echo "ERROR: revisions file '${lf}' is missing or empty" >&2
            return 1
        fi
        while IFS= read -r lline || [[ -n "${lline}" ]]; do
            if [[ ! "${lline}" =~ ${_NIGHTLY_LINE_RE} ]]; then
                echo "ERROR: malformed revision line in ${lf}: ${lline}" >&2
                return 1
            fi
        done < "${lf}"
    done

    local lold=""
    if [[ -f "${lin}" ]]; then
        while IFS= read -r lline || [[ -n "${lline}" ]]; do
            [[ -z "${lline}" ]] && continue
            if [[ "${lline}" =~ ${_NIGHTLY_LINE_RE} ]]; then
                lold+="${lline}"$'\n'
            else
                echo "WARNING: dropping malformed checkpoint line: ${lline}" >&2
            fi
        done < "${lin}"
    fi

    local lmerged
    lmerged="$({ printf '%s' "${lold}"; cat "$@"; } | awk '
        { key = $1 " " $2; val[key] = $3; if (!(key in seen)) { seen[key] = 1; order[++n] = key } }
        END { for (i = 1; i <= n; i++) print order[i], val[order[i]] }' | sort)" || return 1
    printf '%s\n' "${lmerged}" > "${lout}" || return 1
}

# ============================================
# Build cell selection for the publish job
# ============================================
#
# published_distros <conclusions-file> <artifacts-dir> <require-revisions> <distro>...
#
# <conclusions-file> holds "<distro> <conclusion>" lines, read from the
# GitHub API for this run's build cells. A distro is published only when its
# cell concluded "success". A requested distro with no line at all means the
# job list is incomplete, so the function returns 1 rather than dropping it;
# failure, cancelled or skipped only warns. Such a cell must have left its artifacts behind
# (<artifacts-dir>/debs-<distro>/*.deb, plus
# <artifacts-dir>/nightly-revs-<distro>/revisions.txt when
# <require-revisions> is "true"); if they are missing, the download did not
# work and the function returns 1 rather than quietly dropping the distro.
# Prints the selected distros, one per line.
published_distros() {
    local lconclusions="$1" lartifacts="$2" lrequire_revs="$3"
    shift 3
    local ldistro lconclusion ldebs
    local -a lselected=()

    if [[ ! -f "${lconclusions}" ]]; then
        echo "ERROR: build cell conclusions file '${lconclusions}' not found" >&2
        return 1
    fi
    for ldistro in "$@"; do
        lconclusion="$(awk -v d="${ldistro}" '$1 == d {print $2}' "${lconclusions}" | tail -n 1)"
        if [[ -z "${lconclusion}" ]]; then
            echo "ERROR: no build cell conclusion found for ${ldistro}" >&2
            return 1
        fi
        if [[ "${lconclusion}" != "success" ]]; then
            echo "WARNING: build cell for ${ldistro} concluded '${lconclusion:-unknown}'; not publishing it" >&2
            continue
        fi
        ldebs="$({ find "${lartifacts}/debs-${ldistro}" -maxdepth 1 -name '*.deb' -type f 2>/dev/null || true; } | wc -l | tr -d '[:space:]')"
        if [[ "${ldebs}" -eq 0 ]]; then
            echo "ERROR: build cell for ${ldistro} succeeded but no .deb files were downloaded" >&2
            return 1
        fi
        if [[ "${lrequire_revs}" == "true" && ! -s "${lartifacts}/nightly-revs-${ldistro}/revisions.txt" ]]; then
            echo "ERROR: build cell for ${ldistro} succeeded but its nightly revisions were not downloaded" >&2
            return 1
        fi
        lselected+=("${ldistro}")
    done
    [[ ${#lselected[@]} -gt 0 ]] && printf '%s\n' "${lselected[@]}"
    return 0
}

# ============================================
# Deploy propagation
# ============================================
#
# wait_for_propagation <repo-url> <repo-dir> <suite>...
#
# After a Pages deploy, polls each suite's live InRelease until it is
# byte-identical to the one in <repo-dir>. Up to PROPAGATION_ATTEMPTS polls
# per suite, PROPAGATION_DELAY seconds apart. Returns 1 if a suite never
# matches.
wait_for_propagation() {
    local lurl="$1" lrepo="$2"
    shift 2
    local lattempts="${PROPAGATION_ATTEMPTS:-30}"
    local ldelay="${PROPAGATION_DELAY:-10}"
    local lsuite ltmp lattempt lrc lok
    ltmp="$(mktemp)" || return 1

    for lsuite in "$@"; do
        if [[ ! -f "${lrepo}/dists/${lsuite}/InRelease" ]]; then
            echo "ERROR: ${lrepo}/dists/${lsuite}/InRelease does not exist" >&2
            rm -f "${ltmp}"
            return 1
        fi
        lok=false
        for ((lattempt = 1; lattempt <= lattempts; lattempt++)); do
            lrc=0
            fetch_url "${lurl}/dists/${lsuite}/InRelease" "${ltmp}" || lrc=$?
            if [[ "${lrc}" -eq 0 ]] && cmp -s "${ltmp}" "${lrepo}/dists/${lsuite}/InRelease"; then
                lok=true
                break
            fi
            echo "  ${lsuite}: live InRelease not updated yet (attempt ${lattempt} of ${lattempts})" >&2
            [[ "${lattempt}" -lt "${lattempts}" ]] && sleep "${ldelay}"
        done
        if [[ "${lok}" != "true" ]]; then
            echo "ERROR: ${lsuite} did not propagate to ${lurl}" >&2
            rm -f "${ltmp}"
            return 1
        fi
        echo "  ${lsuite}: live InRelease matches the deployed one" >&2
    done
    rm -f "${ltmp}"
}

# ============================================
# Smoke test: live upgrade probe and upgrade result
# ============================================

# probe_live_suite <live-url> <suite> -> prints "run" when the suite's
# InRelease is published, "skip" when it is absent (HTTP 404/410: the first
# deploy of this suite), and returns 1 on any other failure after
# fetch_url's retries. A failed probe never turns into a skip.
probe_live_suite() {
    local lurl="$1" lsuite="$2" ltmp lrc=0
    ltmp="$(mktemp)" || return 1
    fetch_url "${lurl}/dists/${lsuite}/InRelease" "${ltmp}" || lrc=$?
    rm -f "${ltmp}"
    case "${lrc}" in
        0) echo "run" ;;
        4) echo "skip" ;;
        *)
            echo "ERROR: could not probe ${lurl}/dists/${lsuite}/InRelease" >&2
            return 1
            ;;
    esac
}

# check_upgraded_versions <expected-file> -> after an upgrade, checks the
# installed packages against "<package> <version>" lines from the assembled
# index. Every listed package that is installed must be exactly
# "install ok installed <version>"; podman-suite must be installed. Listed
# packages that are not installed are ignored (podman-suite does not pull
# in everything the suite ships). Returns 1 on any mismatch.
check_upgraded_versions() {
    local lexpected="$1" lpkg lwant lstatus lfailed=0 lchecked=0 lsuite_seen=false
    if [[ ! -s "${lexpected}" ]]; then
        echo "FAIL: expected-versions file '${lexpected}' is missing or empty" >&2
        return 1
    fi
    while read -r lpkg lwant; do
        [[ -n "${lpkg}" ]] || continue
        [[ "${lpkg}" == "podman-suite" ]] && lsuite_seen=true
        lstatus="$(dpkg-query -W -f='${Status} ${Version}' "${lpkg}" 2>/dev/null || true)"
        if [[ -z "${lstatus}" || "${lstatus}" == "unknown ok not-installed"* ]]; then
            if [[ "${lpkg}" == "podman-suite" ]]; then
                echo "FAIL: podman-suite is not installed after the upgrade" >&2
                lfailed=1
            fi
            continue
        fi
        lchecked=$((lchecked + 1))
        if [[ "${lstatus}" != "install ok installed ${lwant}" ]]; then
            echo "FAIL: ${lpkg} is '${lstatus}', expected 'install ok installed ${lwant}'" >&2
            lfailed=1
        fi
    done < "${lexpected}"
    if [[ "${lsuite_seen}" != "true" ]]; then
        echo "FAIL: the expected versions do not list podman-suite" >&2
        lfailed=1
    fi
    [[ "${lfailed}" -eq 0 ]] || return 1
    echo ">>> ${lchecked} packages installed at the assembled versions"
}

# ============================================
# Compiler cache statistics
# ============================================

# sccache_stat <stats-text> <label> -> the number on the "<label>  N" line of
# `sccache --show-stats`, or 0 when the line is missing.
sccache_stat() {
    local ltext="$1" llabel="$2"
    printf '%s\n' "${ltext}" | awk -v l="${llabel}" '
        index($0, l) == 1 { rest = substr($0, length(l) + 1); if (rest ~ /^[[:space:]]+[0-9]+/) { split(rest, f, " "); print f[1]; found = 1; exit } }
        END { if (!found) print 0 }'
}

# ccache_stat <print-stats-text> <key> -> the value of <key> in
# `ccache --print-stats` output (tab separated), or 0 when missing.
ccache_stat() {
    local ltext="$1" lkey="$2"
    printf '%s\n' "${ltext}" | awk -v k="${lkey}" -F '\t' '
        $1 == k { print $2; found = 1; exit }
        END { if (!found) print 0 }'
}

# compiler_cache_report -> prints sccache and ccache statistics for the caches
# in SCCACHE_DIR and CCACHE_DIR and stops the sccache server. When
# SCCACHE_ENABLED / CCACHE_ENABLED is "true", the matching tool must exist
# and must have seen at least one compile request, or the function returns 1:
# an enabled cache that nothing went through means the wrapper was not used.
# The ccache counters must be zeroed before the build (ccache --zero-stats),
# since they are stored in CCACHE_DIR and survive a cache restore.
#
# Writes changed=true to $GITHUB_OUTPUT (when set) if either cache missed,
# that is, added entries this run, else changed=false. CI saves the cache
# only when it changed.
compiler_cache_report() {
    local lfail=0 lstats lreq lhits lmiss lchanged=false

    if [[ "${SCCACHE_ENABLED:-false}" == "true" ]]; then
        if ! command -v sccache >/dev/null 2>&1; then
            echo "ERROR: SCCACHE_ENABLED=true but sccache is not installed" >&2
            lfail=1
        else
            lstats="$(sccache --show-stats 2>&1)" || true
            printf '%s\n' "${lstats}"
            lreq="$(sccache_stat "${lstats}" "Compile requests")"
            lhits="$(sccache_stat "${lstats}" "Cache hits")"
            lmiss="$(sccache_stat "${lstats}" "Cache misses")"
            echo "sccache: ${lreq} compile requests, ${lhits} hits, ${lmiss} misses"
            [[ "${lmiss}" -gt 0 ]] && lchanged=true
            sccache --stop-server >/dev/null 2>&1 || true
            if [[ "${lreq}" -eq 0 ]]; then
                echo "ERROR: sccache saw no compile requests; RUSTC_WRAPPER was not used" >&2
                lfail=1
            fi
        fi
    fi

    if [[ "${CCACHE_ENABLED:-false}" == "true" ]]; then
        if ! command -v ccache >/dev/null 2>&1; then
            echo "ERROR: CCACHE_ENABLED=true but ccache is not installed" >&2
            lfail=1
        else
            ccache --show-stats 2>&1 || true
            lstats="$(ccache --print-stats 2>/dev/null)" || true
            lhits=$(($(ccache_stat "${lstats}" direct_cache_hit) + $(ccache_stat "${lstats}" preprocessed_cache_hit)))
            lmiss="$(ccache_stat "${lstats}" cache_miss)"
            echo "ccache: ${lhits} hits, ${lmiss} misses"
            [[ "${lmiss}" -gt 0 ]] && lchanged=true
            if [[ $((lhits + lmiss)) -eq 0 ]]; then
                echo "ERROR: ccache saw no cacheable compilations; CC was not wrapped" >&2
                lfail=1
            fi
        fi
    fi

    echo "compiler caches changed: ${lchanged}"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "changed=${lchanged}" >> "${GITHUB_OUTPUT}"
    fi
    [[ "${lfail}" -eq 0 ]]
}
