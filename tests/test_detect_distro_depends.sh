#!/bin/bash

# Test detect_architecture(), detect_distro_version_id(),
# distro_label_for_version_id() and detect_runtime_depends() in functions.sh.
#
# detect_runtime_depends needs ldd + dpkg-query (a Debian host). Where those
# are missing, the dpkg-dependent assertions are skipped; the rest (distro
# and architecture detection, the non-executable guard) run everywhere.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# ============================================
# Test Framework
# ============================================

PASS_COUNT=0
FAIL_COUNT=0

assert_equals() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected: ${expected}"
        echo "    Got: ${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Asserts the given command exits 0 (in a clean subshell so set -e in the
# function body doesn't abort the test runner).
assert_succeeds() {
    local description="$1"
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Command unexpectedly failed: $*"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Asserts the given command exits non-zero.
assert_fails() {
    local description="$1"
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        echo "  FAIL: ${description}"
        echo "    Command unexpectedly succeeded: $*"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
}

# ============================================
# Source the functions under test
# ============================================
# functions.sh sources config.sh at its tail, which reads /etc/os-release and
# composes VERSION_SUFFIX. To test the helpers in isolation this extracts the
# function bodies (sed: from 'name()' to the first closing '}' at col 0) and
# the distro table block from config.sh.

FUNCTIONS_SH="${PROJECT_ROOT}/functions.sh"
CONFIG_SH="${PROJECT_ROOT}/config.sh"

extract_fn() {
    local fn="$1"
    sed -n "/^${fn}()/,/^}/p" "${FUNCTIONS_SH}"
}

load_functions() {
    local fn
    for fn in detect_architecture detect_distro_version_id distro_label_for_version_id detect_runtime_depends; do
        if ! grep -q "^${fn}()" "${FUNCTIONS_SH}"; then
            echo "FATAL: ${fn}() not found in functions.sh"
            return 1
        fi
        eval "$(extract_fn "${fn}")"
    done
    eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${CONFIG_SH}")"
}

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMPDIR}"' EXIT

# write_os_release <name> <content> -- fixture /etc/os-release file.
write_os_release() {
    printf '%s\n' "$2" > "${TEST_TMPDIR}/$1"
    echo "${TEST_TMPDIR}/$1"
}

# Run detection in a clean subshell with DISTRO set to $1.
distro_with() {
    local override="$1"
    ( unset DISTRO; export DISTRO="${override}"; detect_distro_version_id )
}

# Run detection in a clean subshell from an os-release fixture (no DISTRO).
distro_from_file() {
    local file="$1"
    ( unset DISTRO; export OS_RELEASE_FILE="${file}"; detect_distro_version_id )
}

# Run detect_architecture with uname -m faked to $1.
arch_with() {
    local machine="$1"
    ( uname() { echo "${machine}"; }; detect_architecture )
}

echo ""
echo "========================================"
echo "Test: distro / architecture detection, detect_runtime_depends"
echo "========================================"
echo ""

if ! load_functions; then
    echo ""
    echo "RESULT: ALL TESTS FAILED (functions not found)"
    exit 1
fi

# ----- detect_distro_version_id: /etc/os-release -----

echo "Test 1: Debian os-release is detected"
f="$(write_os_release trixie 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION_CODENAME=trixie
ID=debian')"
assert_equals "VERSION_ID=13 -> 13" "13" "$(distro_from_file "${f}")"
assert_equals "13 -> label trixie" "trixie" "$(distro_label_for_version_id 13)"
f="$(write_os_release bookworm 'ID=debian
VERSION_ID="12"
VERSION_CODENAME=bookworm')"
assert_equals "VERSION_ID=12 -> 12" "12" "$(distro_from_file "${f}")"
assert_equals "12 -> label bookworm" "bookworm" "$(distro_label_for_version_id 12)"

echo ""
echo "Test 2: DISTRO override by codename or VERSION_ID"
assert_equals "DISTRO=bookworm -> 12" "12" "$(distro_with bookworm)"
assert_equals "DISTRO=12 -> 12" "12" "$(distro_with 12)"
assert_equals "DISTRO=trixie -> 13" "13" "$(distro_with trixie)"
assert_equals "DISTRO=13 -> 13" "13" "$(distro_with 13)"
f="$(write_os_release ubuntu-for-override 'ID=ubuntu
VERSION_ID="24.04"')"
assert_equals "DISTRO wins over os-release" "12" \
    "$( ( export DISTRO=bookworm OS_RELEASE_FILE="${f}"; detect_distro_version_id ) )"

echo ""
echo "Test 3: unsupported distributions and releases are rejected"
f="$(write_os_release ubuntu 'ID=ubuntu
VERSION_ID="24.04"
VERSION_CODENAME=noble')"
assert_fails "Ubuntu os-release rejected" distro_from_file "${f}"
f="$(write_os_release sid 'PRETTY_NAME="Debian GNU/Linux trixie/sid"
ID=debian')"
assert_fails "Debian sid (no VERSION_ID) rejected" distro_from_file "${f}"
f="$(write_os_release unknown 'ID=fedora
VERSION_ID="41"')"
assert_fails "unknown ID rejected" distro_from_file "${f}"
f="$(write_os_release noid 'VERSION_ID="12"')"
assert_fails "os-release without ID rejected" distro_from_file "${f}"
f="$(write_os_release old 'ID=debian
VERSION_ID="11"')"
assert_fails "Debian 11 (unsupported release) rejected" distro_from_file "${f}"
assert_fails "missing os-release rejected" distro_from_file "${TEST_TMPDIR}/does-not-exist"
assert_fails "DISTRO=sid rejected" distro_with sid
assert_fails "DISTRO=11 rejected" distro_with 11
assert_fails "DISTRO=24.04 rejected" distro_with 24.04
assert_fails "DISTRO=noble rejected" distro_with noble
assert_fails "injection-shaped DISTRO rejected" distro_with "12; rm"
assert_fails "unknown VERSION_ID has no label" distro_label_for_version_id 11
if msg="$(distro_from_file "$(write_os_release ubuntu2 'ID=ubuntu
VERSION_ID="24.04"')" 2>&1)"; then
    assert_equals "Ubuntu rejection exits non-zero" "non-zero" "zero"
else
    assert_succeeds "Ubuntu rejection names the distribution" grep -q "unsupported distribution 'ubuntu'" <<< "${msg}"
fi

echo ""
echo "Test 4: architecture detection is amd64 only"
assert_equals "x86_64 -> amd64" "amd64" "$(arch_with x86_64)"
assert_fails "aarch64 rejected" arch_with aarch64
assert_fails "arm64 rejected" arch_with arm64
assert_fails "armv7l rejected" arch_with armv7l

echo ""
echo "Test 5: detect_runtime_depends hard-fails on a non-executable path"
assert_fails "non-executable binary path errors" \
    detect_runtime_depends "/nonexistent/definitely/not/a/binary"

# ----- detect_runtime_depends (dpkg-dependent) -----

echo ""
echo "Test 6: detect_runtime_depends on a real ELF binary (dpkg host only)"
if command -v dpkg-query &>/dev/null && command -v ldd &>/dev/null; then
    # Pick a guaranteed-present dynamically-linked ELF binary.
    target="/bin/cat"
    [[ -x "${target}" ]] || target="$(command -v cat)"
    result="$(detect_runtime_depends "${target}")"
    # Base packages must be excluded.
    if echo "${result}" | grep -qx "libc6"; then
        echo "  FAIL: libc6 should be excluded from output"
        echo "    Got: ${result}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        echo "  PASS: libc6 excluded from detected depends"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
else
    echo "  SKIP: dpkg-query/ldd not available (non-Debian host)"
fi

echo ""
echo "Test 6b: owner recorded under /lib, as in bookworm's dpkg database"
if command -v ldd &>/dev/null && command -v objdump &>/dev/null; then
    # bookworm's dpkg database lists libc6's files under /lib even though
    # /lib is a symlink to /usr/lib, so a lookup of the realpath finds no
    # owner. This stub answers only for /lib paths.
    _lib_only_result="$(
        dpkg-query() {
            if [[ "$2" == /lib/* ]]; then
                printf 'libfake-lib-only:amd64: %s\n' "$2"
                return 0
            fi
            echo "dpkg-query: no path found matching pattern $2" >&2
            return 1
        }
        detect_runtime_depends "$(command -v cat)"
    )" || _lib_only_result="FAILED"
    assert_equals "owner found via the /lib path" "libfake-lib-only" "${_lib_only_result}"
else
    echo "  SKIP: ldd/objdump not available"
fi

# ============================================
# Tests 7-9: DT_NEEDED semantics (dpkg host + objdump + gcc only)
#   7: a static binary yields an empty dep set and exit 0 (not a hard-fail)
#   8: direct DT_NEEDED only: libsystemd0's own deps (libgcrypt20 etc.) must
#      not appear (guards against a return to the full ldd closure)
#   9: the dynamic-loader pseudo-entry (ld-linux*.so) is skipped
# ============================================

echo ""
echo "Tests 7-9: DT_NEEDED behavioral regression coverage (dpkg host only)"

if ! command -v dpkg-query &>/dev/null || ! command -v ldd &>/dev/null || ! command -v objdump &>/dev/null; then
    echo "  SKIP: dpkg-query / ldd / objdump not available (non-Debian host)"
else
    # All three tests need a temporary build directory; it lives under
    # TEST_TMPDIR, which the EXIT trap removes.
    _tmp_dir="${TEST_TMPDIR}/build"
    mkdir -p "${_tmp_dir}"

    # ---- Fixture A: statically-linked binary (behavior 3) ----
    echo ""
    echo "Test 7: statically-linked binary -> empty dep set, exit 0"

    _fixture_a="${_tmp_dir}/static_hello"
    _static_ok=false
    if command -v gcc &>/dev/null; then
        cat > "${_tmp_dir}/hello.c" <<'EOF_C'
int main(void) { return 0; }
EOF_C
        if gcc -static "${_tmp_dir}/hello.c" -o "${_fixture_a}" 2>/dev/null; then
            _static_ok=true
        fi
    fi

    if [[ "${_static_ok}" == "true" ]]; then
        # The function must exit 0 and produce NO output.
        _static_result="$(detect_runtime_depends "${_fixture_a}")"
        _static_exit=0
        detect_runtime_depends "${_fixture_a}" >/dev/null 2>&1 || _static_exit=$?
        if [[ "${_static_exit}" -ne 0 ]]; then
            echo "  FAIL: static binary caused hard-fail (exit ${_static_exit}); expected exit 0 with empty output"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        elif [[ -n "${_static_result}" ]]; then
            echo "  FAIL: static binary produced non-empty dep set: ${_static_result}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "  PASS: static binary -> empty dep set, exit 0"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
    else
        echo "  SKIP: gcc -static not available or libc6-dev static libs absent"
    fi

    # ---- Fixture B: dynamic binary linked to libsystemd (behaviors 1+2) ----
    echo ""
    echo "Test 8: direct DT_NEEDED only — transitive-closure deps of libsystemd0 must NOT appear"

    _fixture_b="${_tmp_dir}/dyn_systemd"
    _systemd_ok=false
    if command -v gcc &>/dev/null; then
        cat > "${_tmp_dir}/systemd_hello.c" <<'EOF_C'
#include <systemd/sd-daemon.h>
int main(void) { sd_notify(0, "READY=1"); return 0; }
EOF_C
        if gcc "${_tmp_dir}/systemd_hello.c" -lsystemd -o "${_fixture_b}" 2>/dev/null; then
            _systemd_ok=true
        fi
    fi

    if [[ "${_systemd_ok}" == "true" ]]; then
        _dyn_result="$(detect_runtime_depends "${_fixture_b}")"

        # MUST contain libsystemd0 (the direct dep).
        if ! printf '%s\n' "${_dyn_result}" | grep -qx "libsystemd0"; then
            echo "  FAIL: libsystemd0 not found in output for -lsystemd binary"
            echo "    Got: ${_dyn_result}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "  PASS: libsystemd0 present in dep set"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi

        # Must NOT contain any of libsystemd0's own transitive deps — these are
        # the false-positive packages that the old ldd-closure detector injected
        # (the direct-DT_NEEDED detector must not re-introduce them).
        # A regression back to transitive-closure logic would re-introduce them.
        _transitive_extras=( liblz4-1 liblzma5 libzstd1 libgcrypt20 libgpg-error0 )
        _found_transitive=()
        for _t in "${_transitive_extras[@]}"; do
            if printf '%s\n' "${_dyn_result}" | grep -qx "${_t}"; then
                _found_transitive+=( "${_t}" )
            fi
        done

        if [[ "${#_found_transitive[@]}" -gt 0 ]]; then
            echo "  FAIL: transitive deps of libsystemd0 found — detector regressed to full ldd closure"
            echo "    Unexpected: ${_found_transitive[*]}"
            echo "    Full output: ${_dyn_result}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "  PASS: no transitive deps of libsystemd0 in output (direct DT_NEEDED only)"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi

        # Test 9: dynamic-loader pseudo-entry skip.
        echo ""
        echo "Test 9: dynamic-loader pseudo-entry (ld-linux*.so) not in dep output"
        if printf '%s\n' "${_dyn_result}" | grep -qE '^ld(-linux|\.so|-)'; then
            echo "  FAIL: dynamic loader entry leaked into dep output: $(printf '%s\n' "${_dyn_result}" | grep -E '^ld(-linux|\.so|-)')"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        else
            echo "  PASS: dynamic-loader pseudo-entry absent from dep output"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
    else
        echo "  SKIP: libsystemd-dev not available for gcc -lsystemd (install libsystemd-dev to enable)"
        echo "  NOTE: falling back to /bin/ls as a known dynamic binary without transitive extras"
        echo ""
        echo "Test 8 (fallback): /bin/ls direct DT_NEEDED only — libc6 excluded, no spurious transitive deps"
        _fallback_bin="/bin/ls"
        [[ -x "${_fallback_bin}" ]] || _fallback_bin="$(command -v ls)"
        if [[ -x "${_fallback_bin}" ]]; then
            _fallback_result="$(detect_runtime_depends "${_fallback_bin}")"
            # libc6 must not appear (always excluded)
            if printf '%s\n' "${_fallback_result}" | grep -qx "libc6"; then
                echo "  FAIL: libc6 present in output (should be excluded)"
                echo "    Got: ${_fallback_result}"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            else
                echo "  PASS: libc6 excluded; dep output: $(printf '%s' "${_fallback_result}" | tr '\n' ' ')"
                PASS_COUNT=$((PASS_COUNT + 1))
            fi

            echo ""
            echo "Test 9 (fallback): dynamic-loader pseudo-entry (ld-linux*.so) not in /bin/ls dep output"
            if printf '%s\n' "${_fallback_result}" | grep -qE '^ld(-linux|\.so|-)'; then
                echo "  FAIL: dynamic loader entry leaked into dep output: $(printf '%s\n' "${_fallback_result}" | grep -E '^ld(-linux|\.so|-)')"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            else
                echo "  PASS: dynamic-loader pseudo-entry absent from dep output"
                PASS_COUNT=$((PASS_COUNT + 1))
            fi
        else
            echo "  SKIP: /bin/ls not available"
        fi
    fi
fi

# ============================================
# Summary
# ============================================

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi
exit 0
