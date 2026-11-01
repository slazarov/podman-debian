#!/bin/bash

# test_docs_suites.sh - doc-grep assertions over docs/apt-repository.md.
#
# Asserts that every suite in ALL_SUITES (config.sh) is named, that the
# Signed-By keyring path is the documented one, that no bare track alias is
# documented, and that the CI-internal `trusted=yes` /
# `Trusted: yes` smoke-test shortcut never leaks into the user-facing docs.
#
# Run via `bash tests/test_docs_suites.sh`. CI also runs it in the publish job
# ("Run doc and HTML unit tests").

set -euo pipefail

PASS=0
FAIL=0

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${PROJECT_ROOT}/docs/apt-repository.md"

eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${PROJECT_ROOT}/config.sh")"

assert_contains() {
    local file="$1" pattern="$2" label="$3"
    if grep -qF -- "$pattern" "$file"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label: '$pattern' not found in $file" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_absent_re() {
    local file="$1" pattern="$2" label="$3"
    if grep -qiE -- "$pattern" "$file"; then
        echo "FAIL: $label: /$pattern/ matched in $file" >&2
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $label"
        PASS=$((PASS + 1))
    fi
}

# --- Every suite is documented ---
for suite in "${ALL_SUITES[@]}"; do
    assert_contains "$DOC" "${suite}" "suite ${suite} documented"
done

# --- Keyring path and sources file ---
assert_contains "$DOC" "Signed-By: /etc/apt/keyrings/podman-debian.gpg" "Signed-By keyring path present"
assert_contains "$DOC" "/etc/apt/sources.list.d/podman-debian.sources" "sources file name present"

# --- Only the supported suites ---
assert_absent_re "$DOC" "^Suites: (stable|v5|nightly)$" "no bare track alias in a sources snippet"
documented="$(grep -oE '^Suites: [a-z0-9-]+' "$DOC" | sed 's/^Suites: //' | sort -u)"
for suite in ${documented}; do
    if printf '%s\n' "${ALL_SUITES[@]}" | grep -qx "${suite}"; then
        echo "PASS: snippet suite ${suite} is in ALL_SUITES"
        PASS=$((PASS + 1))
    else
        echo "FAIL: snippet suite ${suite} is not in ALL_SUITES" >&2
        FAIL=$((FAIL + 1))
    fi
done

# --- trusted=yes must not leak into user-facing docs ---
assert_absent_re "$DOC" "trusted=yes|Trusted: yes" "no trusted=yes in user-facing docs"

echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
