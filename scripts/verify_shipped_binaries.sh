#!/bin/bash

# Abort on Error
set -euo pipefail

# verify_shipped_binaries.sh — packaging-completeness guardrail.
#
# Every packaging/nfpm/*.yaml cherry-picks explicit binary paths; nothing globs
# a whole bindir. So when an upstream project adds a new binary (as passt did
# with `pesto`), it is silently dropped from our .deb until a human notices.
# This check closes that gap: it diffs the binaries the build STAGED into
# DESTDIR against the binaries our manifests actually PACKAGE, and warns on any
# staged-but-unpackaged binary.
#
# It is deliberately NON-FATAL. A new upstream binary is a heads-up to update a
# manifest (and CLAUDE.local.md), not a reason to fail a build — package_all.sh
# invokes it with `|| true`. Run standalone the same way:
#
#   DESTDIR=/root/podman-staging ./scripts/verify_shipped_binaries.sh
#
# Matching is by install DESTINATION (manifest `dst:`), not by src glob, so a
# symlink entry like podmansh (src: podman) is still recognized as packaged.
# Only the binary trees are walked (usr/bin, usr/libexec/podman); man pages,
# completions, and config trees are out of scope.

# ---------------------------------------------------------------------------
# Bootstrap: locate the repo root and source config + functions (house style).
# ---------------------------------------------------------------------------
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}")
fi

# shellcheck source=/dev/null
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing (mirrors package_all.sh house style).
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# COMPONENT_BINARIES — used only to annotate a warning with the owning
# component; matching itself is manifest-driven.
source "${toolpath}/scripts/component_maps.sh"

NFPM_DIR="${toolpath}/packaging/nfpm"

# DESTDIR-relative binary trees to audit.
WALK_DIRS=("usr/bin" "usr/libexec/podman")

# Binaries that are staged-but-unpackaged BY DESIGN — suppress warnings for
# these. Keep this list and its rationale in sync with CLAUDE.local.md.
#   - *.avx2: x86_64 fast-path variants; packaged conditionally by
#     package_all.sh (appended to the rendered config), so they are absent from
#     the raw manifest `dst:` scan but ARE shipped on amd64. NOTE: because they
#     are allowlisted on every arch, this check cannot confirm the amd64 append
#     actually fired — that is covered by the render smoke in verify_depends.sh
#     and the `dpkg-deb -c` step in the packaging test gate, not here.
#   - qrap: deprecated (QEMU >= 7.2 has native AF_UNIX); not staged today.
#   - netavark-connection-tester: a test helper upstream itself does not
#     install; not staged today.
KNOWN_UNPACKAGED=(
    "usr/bin/passt.avx2"
    "usr/bin/pasta.avx2"
    "usr/bin/qrap"
    "usr/bin/netavark-connection-tester"
)

# ---------------------------------------------------------------------------
# Pure helper (unit-tested on any host by tests/test_verify_shipped_binaries.sh).
# Prints every line of $1 (staged, DESTDIR-relative paths) that is not present
# as an exact line in $2 (covered = manifest dst paths + allowlist). Both args
# are newline-separated; blank lines are ignored.
# ---------------------------------------------------------------------------
uncovered_binaries() {
    local staged="$1" covered="$2" line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        if ! grep -qxF -- "${line}" <<<"${covered}"; then
            printf '%s\n' "${line}"
        fi
    done <<<"${staged}"
}

# Reverse-lookup: which component ships a given DESTDIR-relative path (best
# effort, for the warning annotation only).
component_for() {
    local target="$1" comp rel
    for comp in "${!COMPONENT_BINARIES[@]}"; do
        for rel in ${COMPONENT_BINARIES[$comp]}; do
            [[ "${rel}" == "${target}" ]] && { printf '%s' "${comp}"; return 0; }
        done
    done
    printf 'unknown'
}

# ---------------------------------------------------------------------------
# Prerequisites.
# ---------------------------------------------------------------------------
if [[ -z "${DESTDIR:-}" || ! -d "${DESTDIR}" ]]; then
    echo "ERROR: DESTDIR must point at a populated staging tree (got '${DESTDIR:-<unset>}')." >&2
    echo "  Run the build scripts with DESTDIR set before running verify_shipped_binaries.sh." >&2
    exit 1
fi

echo ""
echo "========================================"
echo ">>> verify_shipped_binaries.sh — packaging-completeness guardrail"
echo "========================================"
echo "DESTDIR: ${DESTDIR}"
echo ""

# ---------------------------------------------------------------------------
# Covered set: every manifest `dst:` under the audited trees, plus the
# by-design allowlist. Normalize: strip quotes, leading '/', trailing '/'.
# ---------------------------------------------------------------------------
# NOTE: matching is exact-line, so a directory-style dst (trailing '/', e.g. a
# future `type: tree` under usr/libexec/podman) would NOT cover the individual
# files staged beneath it. No such dst targets the audited trees today; revisit
# this normalization if one is added.
covered="$(
    grep -rhE '^[[:space:]]*dst:[[:space:]]' "${NFPM_DIR}"/*.yaml 2>/dev/null |
        sed -E 's/^[[:space:]]*dst:[[:space:]]*//; s/"//g; s/^\///; s/\/$//' |
        grep -E '^(usr/bin|usr/libexec/podman)/' || true
)"
covered+=$'\n'"$(printf '%s\n' "${KNOWN_UNPACKAGED[@]}")"

# ---------------------------------------------------------------------------
# Staged set: files and symlinks actually present in the audited trees.
# ---------------------------------------------------------------------------
staged=""
for d in "${WALK_DIRS[@]}"; do
    [[ -d "${DESTDIR}/${d}" ]] || continue
    while IFS= read -r f; do
        staged+="${f#"${DESTDIR}/"}"$'\n'
    done < <(find "${DESTDIR}/${d}" -mindepth 1 \( -type f -o -type l \) 2>/dev/null | sort)
done

# ---------------------------------------------------------------------------
# Diff + report.
# ---------------------------------------------------------------------------
uncovered="$(uncovered_binaries "${staged}" "${covered}")"

if [[ -z "${uncovered}" ]]; then
    staged_count="$(grep -cve '^[[:space:]]*$' <<<"${staged}" || true)"
    echo "OK: all ${staged_count} staged binaries under ${WALK_DIRS[*]} are packaged or allowlisted."
    # Machine-detectable marker so CI can assert the guardrail ran and its verdict
    # (the caller swallows the exit code with `|| true`, by design — non-fatal).
    echo "GUARDRAIL_RESULT: OK"
    echo ""
    exit 0
fi

uncovered_count="$(grep -cve '^[[:space:]]*$' <<<"${uncovered}" || true)"
echo "One or more staged binaries are NOT packaged by any manifest:" >&2
while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    echo "  GUARDRAIL WARN: ${path} staged but not packaged (component $(component_for "${path}"))" >&2
done <<<"${uncovered}"
echo "" >&2
echo "  If this is a NEW upstream binary, add it to the component's manifest" >&2
echo "  (packaging/nfpm/*.yaml) or, if intentionally skipped, to KNOWN_UNPACKAGED" >&2
echo "  here and the ledger in CLAUDE.local.md. Non-fatal — packaging continues." >&2
echo "" >&2
# Machine-detectable marker: CI can `grep -q 'GUARDRAIL_RESULT: WARN'` to fail a
# job or open a heads-up even though this script itself stays non-fatal.
echo "GUARDRAIL_RESULT: WARN (${uncovered_count} unpackaged)"
exit 0
