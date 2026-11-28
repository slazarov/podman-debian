#!/bin/bash

# Prevent recursive sourcing (not exported — child processes must source independently)
[[ -n "${_FUNCTIONS_SH_SOURCED:-}" ]] && return 0
_FUNCTIONS_SH_SOURCED=1

# Determine toolpath if not set already
relativepath="./" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# ============================================
# Architecture Detection
# ============================================

detect_architecture() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64)
            echo "amd64"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $arch" >&2
            echo "Supported: x86_64 (amd64)" >&2
            exit 1
            ;;
    esac
}

# ============================================
# Distro Identity Detection
# ============================================

# Print the Debian VERSION_ID (12, 13, ...) of the release being built for.
#
# Resolution order:
#   1. ${DISTRO}, if set. It may be a codename from VALID_DISTROS ("bookworm")
#      or its VERSION_ID ("12"). /etc/os-release is not read.
#   2. ${OS_RELEASE_FILE:-/etc/os-release}. ID must be "debian" and VERSION_ID
#      must be set. Debian testing and unstable have no VERSION_ID and are
#      rejected.
#   3. Otherwise fail. There is no silent fallback.
#
# The value is only ever compared against the VALID_DISTROS /
# DISTRO_VERSION_IDS table from config.sh, so a malformed DISTRO or
# VERSION_ID cannot reach the version string or the .deb filename.
detect_distro_version_id() {
    local lvalue
    local lid
    local llabel
    local los_release="${OS_RELEASE_FILE:-/etc/os-release}"

    if [[ -n "${DISTRO:-}" ]]; then
        lvalue="${DISTRO}"
    elif [[ -r "${los_release}" ]]; then
        # Read in a subshell so ID and VERSION_ID do not leak into the caller.
        # shellcheck disable=SC1090
        lid="$( . "${los_release}" && printf '%s' "${ID:-}" )"
        if [[ "${lid}" != "debian" ]]; then
            echo "ERROR: unsupported distribution '${lid:-unknown}' in ${los_release}. This pipeline builds for Debian only." >&2
            return 1
        fi
        # shellcheck disable=SC1090
        lvalue="$( . "${los_release}" && printf '%s' "${VERSION_ID:-}" )"
        if [[ -z "${lvalue}" ]]; then
            echo "ERROR: ${los_release} has no VERSION_ID (Debian testing or unstable?). Set DISTRO to one of: ${VALID_DISTROS[*]}" >&2
            return 1
        fi
    else
        echo "ERROR: cannot determine distro: DISTRO is not set and ${los_release} is unreadable" >&2
        return 1
    fi

    for llabel in "${VALID_DISTROS[@]}"; do
        if [[ "${lvalue}" == "${llabel}" || "${lvalue}" == "${DISTRO_VERSION_IDS[${llabel}]}" ]]; then
            echo "${DISTRO_VERSION_IDS[${llabel}]}"
            return 0
        fi
    done

    local lsupported=""
    for llabel in "${VALID_DISTROS[@]}"; do
        lsupported+=" ${llabel} (${DISTRO_VERSION_IDS[${llabel}]})"
    done
    echo "ERROR: unsupported Debian release '${lvalue}'. Supported:${lsupported}" >&2
    return 1
}

# Print the codename label (bookworm, trixie) for a Debian VERSION_ID.
distro_label_for_version_id() {
    local lversion_id="$1"
    local llabel

    for llabel in "${VALID_DISTROS[@]}"; do
        if [[ "${DISTRO_VERSION_IDS[${llabel}]}" == "${lversion_id}" ]]; then
            echo "${llabel}"
            return 0
        fi
    done

    echo "ERROR: no distro label for VERSION_ID '${lversion_id}'" >&2
    return 1
}

# ============================================
# Runtime Dependency Detection
# ============================================

# Map a set of freshly-built ELF binaries to the Debian packages that own
# their resolved shared libraries. The crun JSON-parser variant falls out of
# the host package database with no soname special case.
#
# Args: one or more absolute paths to ELF binaries (typically under DESTDIR).
# Output: sorted, unique owning package names, one per line.
#
# Behavior (dpkg-shlibdeps semantics — DIRECT DT_NEEDED only):
#   - Each binary must be executable, else hard-fail.
#   - Deps are derived from the binary's DIRECT DT_NEEDED sonames
#     (`objdump -p` NEEDED lines), NOT from the full `ldd` transitive closure.
#     This mirrors Debian policy / dpkg-shlibdeps: a package declares Depends
#     for the libraries it directly links, and each dependency package declares
#     ITS OWN transitive deps. Walking the full ldd closure over-reports the
#     deps-of-deps (e.g. gpgme -> libassuan0/libgpg-error0, libsystemd0 ->
#     libgcrypt20/liblz4-1/liblzma5/libzstd1).
#   - Each direct NEEDED soname is resolved to the absolute on-disk object THIS
#     binary loads via the per-binary `ldd` match (soname => /path), so the
#     resolved path is multiarch-correct. linux-vdso and the ld-linux loader
#     have no resolved path and are skipped.
#   - A direct NEEDED soname that does not resolve to a path at all is a
#     hard-fail: an unresolvable NEEDED entry is a real breakage.
#   - Each resolved path is realpath-normalized (ldd may report a symlink)
#     before dpkg-query -S, whose owning package is taken with the
#     :arch multiarch qualifier stripped (awk -F:).
#   - Any resolved .so with no owning package aborts the build.
#   - The always-present base packages libc6 and libgcc-s1 are excluded.
#   - No soname->package mapping is hardcoded: the package name
#     comes only from dpkg-query -S against the host dpkg DB, so the crun JSON
#     parser dep still falls out automatically with no special case.
#
# Security: only ever invoked on in-tree, freshly-built binaries, never on
# untrusted input.
detect_runtime_depends() {
    local -A pkgs=()
    local bin soname lib pkg ex resolved dpkg_out ldd_out
    # Base packages present on every Debian system, never declared.
    local -a EXCLUDE=( libc6 libgcc-s1 )

    for bin in "$@"; do
        if [[ ! -x "${bin}" ]]; then
            echo "ERROR: binary not found or not executable: ${bin}" >&2
            return 1
        fi

        # Capture this binary's ldd resolution map ONCE (soname => /path). Run
        # OUTSIDE a pipeline so its exit status is testable under the caller's
        # `set -euo pipefail` and the soname->path matching below is a
        # pure-bash lookup against this exact binary's resolution. ldd exits
        # non-zero (and prints "not a dynamic executable") for a STATICALLY
        # linked binary (e.g. fuse-overlayfs / catatonit built static) — that
        # is a legitimate zero-dependency case, NOT a breakage, so skip it with
        # an empty dep set rather than hard-failing.
        ldd_out="$(ldd "${bin}" 2>&1)" || true
        if printf '%s\n' "${ldd_out}" | grep -q 'not a dynamic executable'; then
            continue
        fi

        # Enumerate the binary's DIRECT DT_NEEDED sonames only (dpkg-shlibdeps
        # semantics) — NOT the full ldd transitive closure. objdump -p prints
        # one `  NEEDED  <soname>` line per direct dependency.
        while read -r soname; do
            [[ -n "${soname}" ]] || continue

            # Skip the dynamic-loader pseudo-entry: objdump lists ld-linux*.so /
            # ld-*.so.* as NEEDED, but ldd prints it WITHOUT a `=> /path` form
            # (it is shown as a bare absolute path). It is owned by libc6 (an
            # EXCLUDE), so dropping it changes no result while avoiding a false
            # "did not resolve" hard-fail. Mirrors the loader skip of the old
            # ldd-closure walk.
            case "${soname}" in
                ld-linux*.so*|ld.so*|ld-*.so.*) continue ;;
            esac

            # Resolve THIS direct soname to the absolute object the binary loads,
            # by matching the soname (field 1) against its `=> /path` (field 3)
            # in this binary's own ldd output. Skip the linux-vdso / ld-linux
            # loader pseudo-entries (no resolved path), exactly as before.
            lib="$(printf '%s\n' "${ldd_out}" | awk -v s="${soname}" '$1==s && $2=="=>" {print $3; exit}')"
            if [[ -z "${lib}" || ! -e "${lib}" ]]; then
                echo "ERROR: direct NEEDED soname '${soname}' did not resolve to an on-disk path for ${bin}" >&2
                echo "  (an unresolved NEEDED entry is a real link breakage and is not skipped)" >&2
                return 1
            fi

            resolved="$(realpath "${lib}")"
            # Run dpkg-query OUTSIDE a pipeline so its exit status is testable
            # and its stderr is preserved for the error message below. Under
            # the caller's `set -euo pipefail`, a pipeline failure here could
            # otherwise abort with an opaque ERR-trap message before the
            # explicit guard below ever runs.
            #
            # bookworm is usr-merged on disk, but its dpkg database still
            # records many libraries under /lib (libc6 owns
            # /lib/x86_64-linux-gnu/libc.so.6, not the /usr/lib path realpath
            # returns). trixie moved those records to /usr. So if the resolved
            # path has no owner, also try the path ldd printed and the same
            # paths with the /usr prefix added or removed.
            local lcandidate lfound=0
            local -a lcandidates=( "${resolved}" "${lib}" )
            for lcandidate in "${resolved}" "${lib}"; do
                if [[ "${lcandidate}" == /usr/* ]]; then
                    lcandidates+=( "${lcandidate#/usr}" )
                else
                    lcandidates+=( "/usr${lcandidate}" )
                fi
            done
            for lcandidate in "${lcandidates[@]}"; do
                if dpkg_out="$(dpkg-query -S "${lcandidate}" 2>&1)"; then
                    lfound=1
                    break
                fi
            done
            if [[ "${lfound}" -eq 0 ]]; then
                echo "ERROR: no owning package for ${lib} -> ${resolved} (linked by ${bin})" >&2
                echo "  dpkg-query: ${dpkg_out}" >&2
                return 1
            fi
            # Take the FIRST real line first, then split on ':' to read
            # the package field. dpkg-query -S can emit diversion records
            # ("diversion by X from: /path") and multi-owner lines; filtering
            # diversion lines and applying head BEFORE awk avoids returning a
            # bogus "diversion by X" as a package name.
            pkg="$(printf '%s\n' "${dpkg_out}" | grep -v '^diversion ' | head -n1 | awk -F: '{print $1}')"
            if [[ -z "${pkg}" ]]; then
                echo "ERROR: could not parse owning package for ${lib} -> ${resolved} (linked by ${bin}); dpkg-query said: ${dpkg_out}" >&2
                return 1
            fi
            pkgs["${pkg}"]=1
        done < <(objdump -p "${bin}" 2>/dev/null | awk '/NEEDED/{print $2}')
    done

    # Emit deduped, minus exclusions, sorted.
    local out=""
    for pkg in "${!pkgs[@]}"; do
        local skip=0
        for ex in "${EXCLUDE[@]}"; do
            [[ "${pkg}" == "${ex}" ]] && skip=1
        done
        [[ "${skip}" -eq 0 ]] && out+="${pkg}"$'\n'
    done
    printf '%s' "${out}" | sort -u
}

# ============================================
# Binary Stripping (packaging stage)
# ============================================
# Debian's dh_strip equivalent, run once over the whole DESTDIR staging tree by
# scripts/package_all.sh before nFPM. Debug symbols are dropped, not split: no
# -dbgsym packages. Stripping centrally covers every component (Go, C, Rust,
# meson) regardless of each upstream build system's own strip knobs.
#
# Only ELF executables / PIEs / shared objects (ELF Type EXEC or DYN) are
# touched. Non-ELF files, ELF relocatables (.o, BPF objects), ar archives (.a)
# and symlinks are left byte-identical. "Stripped" means no .symtab and no
# .debug_* / .zdebug_* section in `readelf -S`.

# _elf_is_strippable <file> -> 0 if <file> is an ELF EXEC or DYN object.
_elf_is_strippable() {
    local lfile="$1"
    local lmagic lheader ltype
    [[ -f "${lfile}" && ! -L "${lfile}" ]] || return 1
    lmagic="$(LC_ALL=C head -c 4 "${lfile}" 2> /dev/null | LC_ALL=C tr -d '\0')" || return 1
    [[ "${lmagic}" == $'\x7fELF' ]] || return 1
    # Capture first, then parse: piping readelf into an early-exiting reader
    # would SIGPIPE it and, under pipefail, misreport the result.
    lheader="$(LC_ALL=C readelf -h "${lfile}" 2> /dev/null)" || return 1
    ltype="$(awk '$1 == "Type:" {print $2; exit}' <<< "${lheader}")"
    [[ "${ltype}" == "EXEC" || "${ltype}" == "DYN" ]]
}

# _elf_has_symbols <file> -> 0 if it still has .symtab or debug sections,
# 1 if it is stripped, 2 if readelf cannot read its section headers.
_elf_has_symbols() {
    local lfile="$1"
    local lsections
    lsections="$(LC_ALL=C readelf -S -W "${lfile}" 2> /dev/null)" || return 2
    if grep -Eq '[[:space:]]\.(symtab|z?debug_[^[:space:]]*)([[:space:]]|$)' <<< "${lsections}"; then
        return 0
    fi
    return 1
}

# copy_staging_tree <src> <dest> -> copy the staging tree <src> into <dest>
# (created if missing) so packaging can strip it without write access to
# <src>. Modes, timestamps and symlinks are kept (symlinks are copied, not
# followed); ownership is not, since a non-root packager cannot chown and
# nFPM sets file owners itself. Directories in the copy get owner write so
# strip can create its temporary file next to each binary; file modes are
# left exactly as staged, because nFPM packages them.
copy_staging_tree() {
    local lsrc="$1" ldest="$2"
    if [[ ! -d "${lsrc}" ]]; then
        echo "ERROR: copy_staging_tree: not a directory: ${lsrc}" >&2
        return 1
    fi
    if ! mkdir -p "${ldest}"; then
        echo "ERROR: copy_staging_tree: cannot create ${ldest}" >&2
        return 1
    fi
    if ! cp -R -P --preserve=mode,timestamps,links "${lsrc}/." "${ldest}/"; then
        echo "ERROR: could not copy staging tree ${lsrc} to ${ldest}" >&2
        return 1
    fi
    if ! find "${ldest}" -type d ! -perm -u=w -exec chmod u+w {} +; then
        echo "ERROR: could not make directories under ${ldest} writable" >&2
        return 1
    fi
}

# strip_staged_binaries <dir> -> strip --strip-unneeded every unstripped ELF
# EXEC/DYN file under <dir>, in place. Symlinks are not followed. Returns 1
# (naming the file) on the first strip failure; an empty tree is a no-op.
strip_staged_binaries() {
    local ldir="$1"
    local lfile lrc lmode lcount=0
    if [[ ! -d "${ldir}" ]]; then
        echo "ERROR: strip_staged_binaries: not a directory: ${ldir}" >&2
        return 1
    fi
    while IFS= read -r -d '' lfile; do
        _elf_is_strippable "${lfile}" || continue
        lrc=0
        _elf_has_symbols "${lfile}" || lrc=$?
        [[ "${lrc}" -eq 1 ]] && continue
        # A non-root strip cannot rewrite a file without owner write (e.g.
        # 0555): add it for the strip, then restore the exact staged mode,
        # which nFPM packages.
        lmode=""
        if [[ ! -w "${lfile}" ]]; then
            if ! lmode="$(stat -c %a "${lfile}")" || ! chmod u+w "${lfile}"; then
                echo "ERROR: cannot make ${lfile} writable to strip it" >&2
                return 1
            fi
        fi
        if ! strip --strip-unneeded "${lfile}"; then
            [[ -n "${lmode}" ]] && chmod "${lmode}" "${lfile}"
            echo "ERROR: strip failed: ${lfile}" >&2
            return 1
        fi
        if [[ -n "${lmode}" ]] && ! chmod "${lmode}" "${lfile}"; then
            echo "ERROR: cannot restore mode ${lmode} on ${lfile}" >&2
            return 1
        fi
        lcount=$((lcount + 1))
    done < <(find "${ldir}" -type f -print0 | LC_ALL=C sort -z)
    echo "  Stripped ${lcount} ELF file(s) under ${ldir}"
}

# verify_binaries_stripped <dir> -> 0 if no ELF EXEC/DYN file under <dir>
# still carries .symtab or debug sections; otherwise names each offender on
# stderr and returns 1. An unreadable ELF counts as an offender.
verify_binaries_stripped() {
    local ldir="$1"
    local lfile lrc lbad=0
    if [[ ! -d "${ldir}" ]]; then
        echo "ERROR: verify_binaries_stripped: not a directory: ${ldir}" >&2
        return 1
    fi
    while IFS= read -r -d '' lfile; do
        _elf_is_strippable "${lfile}" || continue
        lrc=0
        _elf_has_symbols "${lfile}" || lrc=$?
        case "${lrc}" in
            1) ;;
            2)
                echo "ERROR: cannot read ELF sections: ${lfile}" >&2
                lbad=$((lbad + 1))
                ;;
            *)
                echo "ERROR: unstripped ELF in staging tree: ${lfile}" >&2
                lbad=$((lbad + 1))
                ;;
        esac
    done < <(find "${ldir}" -type f -print0 | LC_ALL=C sort -z)
    if [[ "${lbad}" -gt 0 ]]; then
        echo "ERROR: ${lbad} staged ELF file(s) are not stripped" >&2
        return 1
    fi
    return 0
}

# ============================================
# .deb Repack (packaging stage)
# ============================================
# nFPM's built-in xz has no level setting and compresses far worse than
# `xz -9`, whose 64 MiB dictionary also dedups code shared between binaries
# (podman / podman-remote). package_all.sh therefore rebuilds every .deb it
# just wrote with dpkg-deb at -9. The repack must not change the package: the
# data listing (mode, owner, size, path, link target), the control fields and
# every control member are compared before the original is replaced.

# _deb_listing <deb> -> normalized `dpkg-deb -c` listing: mode, owner, size,
# path and link target (no timestamps), sorted by path. The root entry "./" is
# dropped (nFPM omits it, dpkg-deb -b always writes it; it is checked
# separately). Symlink permission bits are reduced to "l": Linux ignores them,
# nFPM stores 0000 and a symlink created on disk is always 0777.
_deb_listing() {
    local ldeb="$1"
    local llisting
    llisting="$(LC_ALL=C dpkg-deb -c "${ldeb}")" || return 1
    awk 'NF == 0 {next}
    {
        mode = $1
        if (substr(mode, 1, 1) == "l") mode = "l"
        path = $6
        for (i = 7; i <= NF; i++) path = path " " $i
        if (path == "./") next
        print path "\t" mode "\t" $2 "\t" $3
    }' <<< "${llisting}" | LC_ALL=C sort
}

# _repack_deb_same <old> <new> -> 0 when <new> has the same contents and
# control as <old> and a 0755 root/root root directory; else names the
# difference on stderr and returns 1.
_repack_deb_same() {
    local lold="$1" lnew="$2"
    local lold_list lnew_list lold_fields lnew_fields lctrl lrc lraw lroot
    lold_list="$(_deb_listing "${lold}")" || return 1
    lnew_list="$(_deb_listing "${lnew}")" || return 1
    if [[ "${lold_list}" != "${lnew_list}" ]]; then
        echo "ERROR: repacked file listing differs from the original" >&2
        diff <(printf '%s\n' "${lold_list}") <(printf '%s\n' "${lnew_list}") >&2 || true
        return 1
    fi
    lold_fields="$(dpkg-deb -f "${lold}")" || return 1
    lnew_fields="$(dpkg-deb -f "${lnew}")" || return 1
    if [[ "${lold_fields}" != "${lnew_fields}" ]]; then
        echo "ERROR: repacked control fields differ from the original" >&2
        return 1
    fi
    # Every control member (control, conffiles, md5sums, maintainer scripts,
    # anything else), byte for byte.
    lctrl="$(mktemp -d)" || return 1
    lrc=0
    if ! dpkg-deb -e "${lold}" "${lctrl}/old" || ! dpkg-deb -e "${lnew}" "${lctrl}/new"; then
        echo "ERROR: cannot extract control members for comparison" >&2
        lrc=1
    elif ! diff -r "${lctrl}/old" "${lctrl}/new" >&2; then
        echo "ERROR: repacked control members differ from the original" >&2
        lrc=1
    fi
    rm -rf "${lctrl}"
    [[ "${lrc}" -eq 0 ]] || return 1
    # Capture first: an early-exiting awk would SIGPIPE dpkg-deb under pipefail.
    lraw="$(LC_ALL=C dpkg-deb -c "${lnew}")" || return 1
    lroot="$(awk '$6 == "./" {print $1 " " $2; exit}' <<< "${lraw}")"
    if [[ "${lroot}" != "drwxr-xr-x root/root" ]]; then
        echo "ERROR: repacked root directory is '${lroot}', expected 'drwxr-xr-x root/root'" >&2
        return 1
    fi
    return 0
}

# repack_deb_xz9 <deb> -> rebuild <deb> in place with
# `dpkg-deb --root-owner-group -Zxz -z9`, keeping its filename. The package is
# unpacked into a mktemp -d dir, rebuilt beside the original and moved over it
# only after _repack_deb_same passes. A repack that would be larger than the
# original is discarded (success, original kept), so a package never grows.
# On any failure the original is left untouched and 1 is returned, naming
# the file.
repack_deb_xz9() {
    local ldeb="$1"
    local lwork lnew lold_size lnew_size
    if [[ ! -f "${ldeb}" ]]; then
        echo "ERROR: repack_deb_xz9: no such .deb: ${ldeb}" >&2
        return 1
    fi
    lwork="$(mktemp -d)" || return 1
    lnew="${ldeb}.repack.tmp"
    rm -f "${lnew}"
    if ! dpkg-deb -R "${ldeb}" "${lwork}/root"; then
        echo "ERROR: dpkg-deb could not unpack ${ldeb}" >&2
        rm -rf "${lwork}"
        return 1
    fi
    # The root and DEBIAN dirs come from mkdir, so their mode follows the
    # umask; the package root must be 0755 whatever the umask is.
    chmod 0755 "${lwork}/root" "${lwork}/root/DEBIAN"
    if ! dpkg-deb --root-owner-group -Zxz -z9 -b "${lwork}/root" "${lnew}" > /dev/null; then
        echo "ERROR: dpkg-deb could not rebuild ${ldeb}" >&2
        rm -rf "${lwork}" "${lnew}"
        return 1
    fi
    rm -rf "${lwork}"
    if ! _repack_deb_same "${ldeb}" "${lnew}"; then
        echo "ERROR: repack changed the contents of ${ldeb}; original kept" >&2
        rm -f "${lnew}"
        return 1
    fi
    chmod --reference="${ldeb}" "${lnew}"
    lold_size="$(stat -c %s "${ldeb}")"
    lnew_size="$(stat -c %s "${lnew}")"
    # Never grow a package: for a near-empty .deb (podman-suite) the -9
    # stream headers cost more than they save, so keep nFPM's output.
    if [[ "${lnew_size}" -gt "${lold_size}" ]]; then
        rm -f "${lnew}"
        echo "  Kept $(basename "${ldeb}"): repack would grow it (${lold_size} -> ${lnew_size} bytes)"
        return 0
    fi
    mv -f "${lnew}" "${ldeb}"
    echo "  Repacked $(basename "${ldeb}"): ${lold_size} -> ${lnew_size} bytes"
}

# NOTE: config.sh is sourced at the END of this file (after all function definitions)
# This is required because config.sh calls get_required_go_version(), get_required_rust_version(), etc.

# _rank_upstream_tags <component> [series] -- ranking core shared by get_latest_tag,
# list_upstream_tags, and the republish guard. Reads raw tag names on stdin (one per
# line) and prints the matching tags highest-version first.
#
#   <component>  "container-configs" selects the namespaced common/vX.Y.Z tag shape
#                (strip "common/v"); anything else uses the standard [v]X.Y.Z shape
#                (strip a leading "v"), tolerating numeric-only tags like 1.28 / 0.3.
#   [series]     optional anchored dotted-version prefix (e.g. "6", "1.43"): only
#                tags whose numeric version is exactly <series> or begins "<series>."
#                pass, so "6" matches 6.x but never 7.x or 60.x, and "1.43" matches
#                1.43.x but never 1.430.x.
#
# rc/pre-release tags are excluded, matching the historical selection.
_rank_upstream_tags() {
    local lcomponent="$1"
    local lseries="${2:-}"
    local lfilter lstrip lseries_re=""

    if [[ "${lcomponent}" == "container-configs" ]]; then
        lfilter='^common/v[0-9]'
        lstrip='common/v'
    elif [[ "${lcomponent}" == "pasta" ]]; then
        # passt release tags are YYYY_MM_DD.<sha>; version-sort orders them by date.
        lfilter='^[0-9]{4}_[0-9]{2}_[0-9]{2}\.'
        lstrip=''
    else
        lfilter='^v?[0-9]'
        lstrip='v'
    fi

    # Escape dots so a series like "1.43" is a literal prefix, then anchor on a
    # dot-or-end boundary (see docstring). Empty series => no filtering.
    if [[ -n "${lseries}" ]]; then
        lseries_re="^${lseries//./\\.}(\\.|\$)"
    fi

    # Drop real pre-release tags (vX.Y.Z-rcN / X.Y.Z.rcN) only — anchored on a
    # separator so a legitimate tag that merely contains the substring "rc"
    # (e.g. "march-1.0") is NOT excluded.
    grep -Eiv '(-|\.|_)rc[0-9]*' | grep -E "${lfilter}" | while read -r lt; do
        [[ -n "${lt}" ]] || continue
        local lsv="${lt#"${lstrip}"}"
        if [[ -n "${lseries_re}" ]] && ! [[ "${lsv}" =~ ${lseries_re} ]]; then
            continue
        fi
        printf '%s %s\n' "${lsv}" "${lt}"
    done | sort --reverse --version-sort -k1 | awk '{print $2}'
}

# pasta_version_from_tag <tag> -- print the package version for a passt release
# tag. passt tags its releases YYYY_MM_DD.<sha> (2026_10_02.cba3570); the package
# version is the date alone (20261002). An 8-digit date is passed through.
pasta_version_from_tag() {
    local ltag="$1"
    if [[ "${ltag}" =~ ^([0-9]{4})_([0-9]{2})_([0-9]{2})(\..+)?$ ]]; then
        printf '%s%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    elif [[ "${ltag}" =~ ^[0-9]{8}$ ]]; then
        printf '%s\n' "${ltag}"
    else
        echo "ERROR: not a passt release tag: '${ltag}' (want YYYY_MM_DD.<sha>)" >&2
        return 1
    fi
}

get_latest_tag() {
    # Highest stable tag of the currently checked-out repo (the unpinned clone-time
    # fallback in git_checkout). Component-agnostic: the standard [v]X.Y.Z shape.
    git tag --list --sort -creatordate | _rank_upstream_tags "" "" | head -n1
}

# _git_remote_retry <git args...> -- run `git <git args...>` that talks to a remote,
# retrying a failure up to GIT_REMOTE_ATTEMPTS times (default 4), waiting
# GIT_REMOTE_RETRY_DELAY seconds (default 3) times the attempt number in between.
# Smaller upstream hosts (passt.top) drop a single ls-remote or fetch now and
# then; the resolver makes several such calls per component and one dropped call
# used to abort the whole track. A stalled transfer counts as a failure after
# 30s below 1 KB/s instead of hanging. Only the successful attempt's stdout is
# printed; git's stderr is discarded, as the callers did before. Returns git's
# last exit code.
_git_remote_retry() {
    local lattempts="${GIT_REMOTE_ATTEMPTS:-4}"
    local ldelay="${GIT_REMOTE_RETRY_DELAY:-3}"
    local lattempt=1 lrc lout
    while true; do
        # Buffer stdout so a failed attempt's partial output is never emitted.
        lrc=0
        lout=$(git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@" 2>/dev/null) || lrc=$?
        if [[ "${lrc}" -eq 0 ]]; then
            [[ -z "${lout}" ]] || printf '%s\n' "${lout}"
            return 0
        fi
        if [[ "${lattempt}" -ge "${lattempts}" ]]; then
            return "${lrc}"
        fi
        echo "  retrying git $* (rc=${lrc}, attempt ${lattempt} of ${lattempts})" >&2
        sleep $((ldelay * lattempt))
        lattempt=$((lattempt + 1))
    done
}

# list_upstream_tags <repo-url> <component> [series] -- highest-version-first list of
# an upstream repo's tags WITHOUT cloning (over `git ls-remote`), filtered/ranked by
# _rank_upstream_tags. Returns non-zero (and prints nothing) if the remote yields no
# refs. This is the clone-free selection the republish guard and resolver share.
list_upstream_tags() {
    local lurl="$1"
    local lcomponent="$2"
    local lseries="${3:-}"
    local lrefs
    lrefs=$(_git_remote_retry ls-remote --tags --refs "${lurl}" | awk '{print $2}' | sed 's|refs/tags/||') || return 1
    [[ -n "${lrefs}" ]] || return 1
    printf '%s\n' "${lrefs}" | _rank_upstream_tags "${lcomponent}" "${lseries}"
}

# tag_commit_epoch <repo-url> <tag> -- Unix epoch (committer date) of <tag>'s target
# commit, via a shallow single-tag fetch into a throwaway repo. Mirrors the shallow
# fetch git_checkout already uses; needs no GitHub API/token and works for any git
# host and for local file:// fixtures (so the resolver's soak logic is unit-testable
# offline). Prints nothing and returns non-zero on failure.
tag_commit_epoch() {
    local lurl="$1"
    local ltag="$2"
    local ltmp lepoch=""
    ltmp=$(mktemp -d) || return 1
    if git init -q "${ltmp}" 2>/dev/null \
       && _git_remote_retry -C "${ltmp}" fetch -q --depth 1 "${lurl}" tag "${ltag}"; then
        lepoch=$(git -C "${ltmp}" log -1 --format=%ct FETCH_HEAD 2>/dev/null) || lepoch=""
    fi
    rm -rf "${ltmp}"
    [[ -n "${lepoch}" ]] || return 1
    printf '%s\n' "${lepoch}"
}

# parse_buildah_gomod_version -- read go.mod text on stdin, print the required
# buildah RELEASE version WITHOUT a leading v (e.g. 1.43.2), or nothing. Handles
# both module paths: github.com/containers/buildah (podman 5.x) and
# go.podman.io/buildah (podman 6.x). Only a clean X.Y.Z release is emitted: a Go
# pseudo-version (e.g. v1.44.1-0.20260101-abcdef, used when podman tracks buildah
# between releases) is NOT a real git tag, so it is rejected — the caller then
# falls back to the BUILDAH_SERIES cap. Split out so it is unit-testable offline.
parse_buildah_gomod_version() {
    local lver
    lver=$(grep -E '/buildah[[:space:]]+v[0-9]' \
        | grep -v '// indirect' \
        | head -n1 \
        | sed -E 's|.*/buildah[[:space:]]+v([0-9][^[:space:]]*).*|\1|')
    # Reject anything that is not a plain release tag (X.Y.Z).
    [[ "${lver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    printf '%s\n' "${lver}"
}

# get_required_buildah_tag [podman-ref] -- buildah version blessed by podman at the
# given ref, read from podman's go.mod. Prints a v-prefixed tag (e.g. v1.43.2);
# returns non-zero on failure so the caller can fall back to a BUILDAH_SERIES cap.
get_required_buildah_tag() {
    local lref="${1:-main}"
    [[ -n "${lref}" ]] || lref="main"
    local lgomod lver
    lgomod=$(curl -sf "https://raw.githubusercontent.com/containers/podman/${lref}/go.mod" 2>/dev/null) || return 1
    lver=$(printf '%s\n' "${lgomod}" | parse_buildah_gomod_version)
    [[ -n "${lver}" ]] || return 1
    printf 'v%s\n' "${lver}"
}

get_latest_protoc_version() {
    # Return a release version without v; never let an API error become an
    # empty version in the installer's download URL.
    local lresponse ltag
    if ! lresponse=$(curl -fsS --retry 3 --retry-all-errors \
        --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/protocolbuffers/protobuf/releases/latest"); then
        echo "ERROR: Could not fetch latest protoc release" >&2
        return 1
    fi
    ltag=$(printf '%s\n' "${lresponse}" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    if [[ ! "${ltag}" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "ERROR: Latest protoc release has a missing or invalid tag_name" >&2
        return 1
    fi
    printf '%s\n' "${ltag#v}"
}

get_latest_go_version() {
    # Fetch latest Go version from go.dev JSON API
    # Returns version WITHOUT go prefix (e.g., "1.26.0" not "go1.26.0")
    local latest_version
    latest_version=$(curl -s "https://go.dev/dl/?mode=json" | grep -m1 '"version"' | sed 's/.*"version": *"\([^"]*\)".*/\1/')
    # Strip go prefix if present (version is "go1.26.0", we want "1.26.0")
    echo "${latest_version#go}"
}

get_required_go_version() {
    # Auto-detect Go version from Podman's go.mod (upstream source of truth)
    # Parameter: optional git ref (tag like "v5.8.0" or empty for "main")
    # Returns version WITHOUT go prefix (e.g., "1.24.2")
    # Prefers "toolchain goX.Y.Z" (exact), falls back to "go X.Y.Z" (minimum)
    local ref="${1:-main}"
    [[ -z "$ref" ]] && ref="main"

    local go_mod
    go_mod=$(curl -sf "https://raw.githubusercontent.com/containers/podman/${ref}/go.mod" 2>/dev/null) || true

    if [[ -n "$go_mod" ]]; then
        # Prefer toolchain directive (exact version, e.g., "toolchain go1.24.2")
        local toolchain_ver
        toolchain_ver=$(echo "$go_mod" | grep -m1 '^toolchain ' | sed 's/^toolchain go//')

        if [[ -n "$toolchain_ver" ]]; then
            echo "  Auto-detected Go version from go.mod (toolchain): ${toolchain_ver}" >&2
            echo "$toolchain_ver"
            return
        fi

        # Fall back to go directive (minimum version, e.g., "go 1.24")
        local go_ver
        go_ver=$(echo "$go_mod" | grep -m1 '^go ' | sed 's/^go //')

        if [[ -n "$go_ver" ]]; then
            # go directive may be "1.24" (no patch) — append .0 if needed
            if [[ "$go_ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
                go_ver="${go_ver}.0"
            fi
            echo "  Auto-detected Go version from go.mod (minimum): ${go_ver}" >&2
            echo "$go_ver"
            return
        fi
    fi

    # Fallback: use latest Go version
    echo "  WARNING: Could not fetch go.mod from containers/podman@${ref}, falling back to latest Go version" >&2
    get_latest_go_version
}

get_required_rust_version() {
    # Upstream HEAD can lock dependencies that require a newer compiler than
    # Netavark declares. Use rustup's stable channel for nightly builds.
    if [[ "${NIGHTLY_BUILD:-false}" == "true" && -z "${1:-}" ]]; then
        printf '%s\n' stable
        return
    fi

    # Auto-detect Rust MSRV from Netavark's Cargo.toml (upstream source of truth)
    # Parameter: optional git ref (tag like "v1.17.2" or empty for "main")
    # Returns version like "1.86" or "stable"
    local ref="${1:-main}"
    [[ -z "$ref" ]] && ref="main"

    local cargo_toml
    cargo_toml=$(curl -sf "https://raw.githubusercontent.com/containers/netavark/${ref}/Cargo.toml" 2>/dev/null) || true

    if [[ -n "$cargo_toml" ]]; then
        # Parse rust-version = "X.Y" from [package] section
        local rust_ver
        rust_ver=$(echo "$cargo_toml" | grep -m1 '^rust-version' | sed 's/.*= *"\([^"]*\)".*/\1/')

        if [[ -n "$rust_ver" ]]; then
            echo "  Auto-detected Rust MSRV from Cargo.toml: ${rust_ver}" >&2
            echo "$rust_ver"
            return
        fi
    fi

    # Fallback: use stable
    echo "  WARNING: Could not fetch Cargo.toml from containers/netavark@${ref}, falling back to stable Rust" >&2
    echo "stable"
}

git_clone_update() {
    # Input Parameters
    local lrepository="$1"
    local lfolder="$2"

    if [ -z "${lrepository}" ] || [ -z "${lfolder}" ]
    then
        echo "FATAL: You must specify both REPOSITORY GIT URL and TARGET FOLDER"
        exit 1
    else
        if [ -d "${lfolder}" ] && [ -d "${lfolder}/.git" ]
        then
           # Change Working Directly to Target Folder
           cd "${lfolder}"

           # Git Repository has already been cloned
           # Fetch latest Changes
           git fetch --all

           # Also fetch Tags
           git fetch --tags
        else
           # Git Repository has NOT been cloned yet
           # Clone Git Repository
           # Use shallow clone for fresh clones if enabled (reduces network transfer ~95%)
           if [[ "${SHALLOW_CLONE:-true}" == "true" ]]; then
               git clone --depth 1 "${lrepository}" "${lfolder}"
           else
               git clone "${lrepository}" "${lfolder}"
           fi
        fi
    fi
}

git_checkout() {
    # Input Parameters
    local ltag=${1-""}

    if [[ "${NIGHTLY_BUILD:-false}" == "true" && -z "${ltag}" ]]; then
       # Nightly mode: stay on default branch HEAD (no tag checkout)
       # This builds from the latest upstream commits for bleeding-edge packages
       local default_branch
       default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') || true
       default_branch="${default_branch:-main}"
       git checkout "${default_branch}"
       git pull origin "${default_branch}" || true
       export GIT_CHECKED_OUT_TAG="nightly"
    elif [[ -n "${ltag}" ]]
    then
       # For shallow clones, the tag may not be available locally - fetch it
       if ! git rev-parse "${ltag}" &>/dev/null; then
           git fetch --depth 1 origin tag "${ltag}"
       fi
       git checkout "${ltag}"
       export GIT_CHECKED_OUT_TAG="${ltag}"
    else
       # No tag specified - need all tags to find latest
       if [[ "${SHALLOW_CLONE:-true}" == "true" ]]; then
           git fetch --tags
       fi
       local latest_tag
       latest_tag=$(get_latest_tag)
       git checkout "${latest_tag}"
       export GIT_CHECKED_OUT_TAG="${latest_tag}"
    fi

}

log_component() {
    # Input Arguments
    local lcomponent="$1"

    # Generate Timestamp
    local ltimestamp
    ltimestamp=$(date +"%Y%m%d")

    # If Command Exists, save Version
    local loldversion=""
    if [[ -n $(command -v "${lcomponent}") ]]
    then
        loldversion=$("${lcomponent}" --version 2>/dev/null | awk '{print $NF}') || true
    fi

    # New Version can be determined by the Checked out Branch
    local lnewversion
    lnewversion="${GIT_CHECKED_OUT_TAG}"

    # Create Log Folder if not existing yet
    mkdir -p "${toolpath}/log"

    # Log Message to File
    if [[ -z "${loldversion}" ]]
    then
        echo "Install ${lcomponent} with Version ${lnewversion}" >> "${toolpath}/log/${ltimestamp}.log"
    else
        echo "Update ${lcomponent} from Version ${loldversion} to Version ${lnewversion}" >> "${toolpath}/log/${ltimestamp}.log"
    fi
}


remove_if_user_installed() {
    # Input Arguments
    local lfile="$1"

    # If dpkg does not own the file, it was installed from source: delete it.
    if ! dpkg --search "${lfile}" >/dev/null 2>&1
    then
        rm -f "${lfile}"
    fi
}

# ============================================
# Build Artifact Cleanup
# ============================================

cleanup_build_artifacts() {
    echo "Cleaning up build artifacts..."

    # Remove downloaded archives if build directories exist
    if [ -d "${BUILD_ROOT}/aardvark-dns" ]; then
        rm -f "${toolpath}/build/go*.linux-${ARCH}.tar.gz"
        rm -f "${toolpath}/build/protoc*-linux-${ARCH}.zip"
        rm -f "${toolpath}/build/rustup-init.sh"
    fi

    # Clean up other temporary build files
    find "${BUILD_ROOT}" -name "*.tar.*" -type f -delete 2>/dev/null || true
    find "${BUILD_ROOT}" -name "*.zip" -type f -delete 2>/dev/null || true

    echo "Cleanup completed"
}

# ============================================
# Error Handling
# ============================================

error_handler() {
    local exit_code=$1
    local line_number=$2
    local script_name="${3##*/}"  # basename

    echo "" >&2
    echo "========================================" >&2
    echo "ERROR: Installation Failed" >&2
    echo "========================================" >&2
    echo "  Script:    ${script_name}" >&2
    echo "  Line:      ${line_number}" >&2
    echo "  Exit Code: ${exit_code}" >&2
    echo "========================================" >&2
    echo "" >&2
    echo "To debug, run: bash -x ${script_name}" >&2
    echo "" >&2

    exit "${exit_code}"
}

# ============================================
# Progress Tracking
# ============================================

# Format elapsed seconds to human-readable (MM:SS or HH:MM:SS)
format_duration() {
    local seconds=$1
    if [[ $seconds -ge 3600 ]]; then
        printf "%dh %dm %ds" $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
    elif [[ $seconds -ge 60 ]]; then
        printf "%dm %ds" $((seconds/60)) $((seconds%60))
    else
        printf "%ds" $seconds
    fi
}

# Track script timing (called by run_script in setup.sh)
declare -g _SCRIPT_START=0

script_start() {
    export _SCRIPT_START=$(date +%s)
}

# script_done <name> [start-epoch] -- print the elapsed time since start-epoch,
# or since script_start when no start time is given.
script_done() {
    local script_name="$1"
    local start="${2:-${_SCRIPT_START}}"
    local end=$(date +%s)
    local elapsed=$((end - start))
    echo ">>> Completed: ${script_name} in $(format_duration $elapsed)"
}

# Step-level progress (called within build scripts)
declare -g _STEP_NAME=""
declare -g _STEP_START=0

step_start() {
    local step_name="$1"
    export _STEP_NAME="$step_name"
    export _STEP_START=$(date +%s)
    echo "  ${step_name}..."
}

step_done() {
    local step_end=$(date +%s)
    local elapsed=$((step_end - _STEP_START))
    echo "  Done: ${_STEP_NAME} ($(format_duration $elapsed))"
}

# Build output logging
declare -g BUILD_LOG=""

log_build_output() {
    # Initializes log file for a component's build output
    # Usage: log_build_output "component_name"
    local component="$1"
    BUILD_LOG="${toolpath}/log/build_${component}.log"

    # Ensure log directory exists
    mkdir -p "$(dirname "$BUILD_LOG")"

    # Initialize log file with header
    {
        echo "==========================================="
        echo "Build Log: ${component}"
        echo "Started: $(date)"
        echo "==========================================="
    } > "$BUILD_LOG"
}

run_logged() {
    # Runs command with output going to log file (suppresses console output on success).
    # On failure, dumps the last 40 lines of the log to stderr for CI visibility.
    # Usage: run_logged make [args...]
    local rc=0
    "$@" >> "$BUILD_LOG" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "========================================" >&2
        echo "COMMAND FAILED: $*" >&2
        echo "EXIT CODE: ${rc}" >&2
        echo "BUILD LOG (last 40 lines):" >&2
        echo "========================================" >&2
        tail -40 "$BUILD_LOG" >&2
        echo "========================================" >&2
        echo "Full log: ${BUILD_LOG}" >&2
        echo "========================================" >&2
        return $rc
    fi
}

# ============================================
# Compiler caches
# ============================================

# enable_rust_compiler_cache -> when SCCACHE_ENABLED=true, export
# RUSTC_WRAPPER=sccache for the cargo build that follows. If sccache is not
# installed, warn and build uncached, or fail when CACHE_STRICT=true.
enable_rust_compiler_cache() {
    [[ "${SCCACHE_ENABLED:-false}" == "true" ]] || return 0
    if command -v sccache &>/dev/null; then
        export RUSTC_WRAPPER=sccache
        echo "  sccache enabled for Rust compilation (${SCCACHE_DIR:-default dir}, max ${SCCACHE_CACHE_SIZE:-default})"
        return 0
    fi
    if [[ "${CACHE_STRICT:-false}" == "true" ]]; then
        echo "ERROR: SCCACHE_ENABLED=true and CACHE_STRICT=true, but sccache is not installed" >&2
        return 1
    fi
    echo "  WARNING: SCCACHE_ENABLED=true but sccache is not installed; building without it" >&2
    return 0
}

# enable_c_compiler_cache -> when CCACHE_ENABLED=true, export CC="ccache gcc"
# for the C build that follows. Same missing-tool rules as above.
enable_c_compiler_cache() {
    [[ "${CCACHE_ENABLED:-false}" == "true" ]] || return 0
    if command -v ccache &>/dev/null; then
        export CC="ccache gcc"
        echo "  ccache enabled for C compilation (${CCACHE_DIR:-default dir}, max ${CCACHE_MAXSIZE:-default})"
        return 0
    fi
    if [[ "${CACHE_STRICT:-false}" == "true" ]]; then
        echo "ERROR: CCACHE_ENABLED=true and CACHE_STRICT=true, but ccache is not installed" >&2
        return 1
    fi
    echo "  WARNING: CCACHE_ENABLED=true but ccache is not installed; building without it" >&2
    return 0
}

# ============================================
# Load Configuration (MUST be after all function definitions)
# ============================================
# This sources config.sh which calls get_required_go_version(), get_required_rust_version(), etc.
# Those functions must be defined BEFORE this line!
#
# SKIP_CONFIG_SOURCE escape hatch: lightweight consumers that need only the
# pure tag-selection helpers below (scripts/resolve_versions.sh and its offline
# unit test) set SKIP_CONFIG_SOURCE=1 so sourcing functions.sh does NOT pull in
# config.sh, whose load-time architecture/distro detection hard-fails off Debian
# (detect_distro_version_id) and whose toolchain auto-detection makes network
# calls. Normal build scripts leave it unset and get config.sh as before.
if [[ -z "${SKIP_CONFIG_SOURCE:-}" ]]; then
    source "${toolpath}/config.sh"
fi
