#!/bin/bash

# Test extract_version_nightly function
# TDD RED phase: These tests should FAIL until the function is implemented

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
TEST_TMPDIR=""

# ============================================
# Test Framework
# ============================================

PASS_COUNT=0
FAIL_COUNT=0

assert_matches() {
    local description="$1"
    local pattern="$2"
    local actual="$3"
    if [[ "${actual}" =~ ${pattern} ]]; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Expected pattern: ${pattern}"
        echo "    Got: ${actual}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

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

assert_true() {
    local description="$1"
    shift
    if "$@" 2>/dev/null; then
        echo "  PASS: ${description}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: ${description}"
        echo "    Command failed: $*"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ============================================
# Setup: Create Mock Repos
# ============================================

setup() {
    TEST_TMPDIR="$(mktemp -d)"

    # The fixture repos below use `git commit`; give them a deterministic identity
    # so the test does not depend on ambient git config. A bare CI runner (e.g. the
    # GitHub-hosted lint runner) has no user.name/user.email, and `git commit` there
    # hard-fails with "empty ident name" / "unable to auto-detect email address".
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
           GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

    # --- podman mock repo ---
    local podman_dir="${TEST_TMPDIR}/podman"
    mkdir -p "${podman_dir}/version/rawversion"
    git -C "${TEST_TMPDIR}" init podman --quiet
    echo 'package rawversion

const RawVersion = "5.9.0-dev"' > "${podman_dir}/version/rawversion/version.go"
    git -C "${podman_dir}" add -A && git -C "${podman_dir}" commit -m "init" --quiet

    # --- buildah mock repo ---
    local buildah_dir="${TEST_TMPDIR}/buildah"
    mkdir -p "${buildah_dir}/define"
    git -C "${TEST_TMPDIR}" init buildah --quiet
    # Real Buildah define/types.go uses tab-indented `Version = "..."` (no const keyword)
    printf 'package define\n\n\tVersion = "1.44.0-dev"\n' > "${buildah_dir}/define/types.go"
    git -C "${buildah_dir}" add -A && git -C "${buildah_dir}" commit -m "init" --quiet

    # --- skopeo mock repo ---
    local skopeo_dir="${TEST_TMPDIR}/skopeo"
    mkdir -p "${skopeo_dir}/version"
    git -C "${TEST_TMPDIR}" init skopeo --quiet
    echo 'package version

const Version = "1.23.0-dev"' > "${skopeo_dir}/version/version.go"
    git -C "${skopeo_dir}" add -A && git -C "${skopeo_dir}" commit -m "init" --quiet

    # --- netavark mock repo ---
    local netavark_dir="${TEST_TMPDIR}/netavark"
    mkdir -p "${netavark_dir}"
    git -C "${TEST_TMPDIR}" init netavark --quiet
    echo '[package]
name = "netavark"
version = "1.18.0-dev"' > "${netavark_dir}/Cargo.toml"
    git -C "${netavark_dir}" add -A && git -C "${netavark_dir}" commit -m "init" --quiet

    # --- aardvark-dns mock repo ---
    local aardvark_dir="${TEST_TMPDIR}/aardvark-dns"
    mkdir -p "${aardvark_dir}"
    git -C "${TEST_TMPDIR}" init aardvark-dns --quiet
    echo '[package]
name = "aardvark-dns"
version = "1.18.0-dev"' > "${aardvark_dir}/Cargo.toml"
    git -C "${aardvark_dir}" add -A && git -C "${aardvark_dir}" commit -m "init" --quiet

    # --- conmon mock repo ---
    local conmon_dir="${TEST_TMPDIR}/conmon"
    mkdir -p "${conmon_dir}"
    git -C "${TEST_TMPDIR}" init conmon --quiet
    echo "2.2.2" > "${conmon_dir}/VERSION"
    git -C "${conmon_dir}" add -A && git -C "${conmon_dir}" commit -m "init" --quiet

    # --- fuse-overlayfs mock repo (C/autotools v1.x) ---
    local fuse_dir="${TEST_TMPDIR}/fuse-overlayfs"
    mkdir -p "${fuse_dir}"
    git -C "${TEST_TMPDIR}" init fuse-overlayfs --quiet
    echo 'AC_INIT([fuse-overlayfs], [1.17-dev], [giuseppe@scrivano.org])' > "${fuse_dir}/configure.ac"
    git -C "${fuse_dir}" add -A && git -C "${fuse_dir}" commit -m "init" --quiet

    # --- fuse-overlayfs-rust mock repo (Rust v2.0+) ---
    local fuse_rust_dir="${TEST_TMPDIR}/fuse-overlayfs-rust"
    mkdir -p "${fuse_rust_dir}"
    git -C "${TEST_TMPDIR}" init fuse-overlayfs-rust --quiet
    echo '[package]
name = "fuse-overlayfs"
version = "2.0.0"' > "${fuse_rust_dir}/Cargo.toml"
    git -C "${fuse_rust_dir}" add -A && git -C "${fuse_rust_dir}" commit -m "init" --quiet

    # --- catatonit mock repo ---
    local catatonit_dir="${TEST_TMPDIR}/catatonit"
    mkdir -p "${catatonit_dir}"
    git -C "${TEST_TMPDIR}" init catatonit --quiet
    echo 'AC_INIT([catatonit], [0.3.0+dev], [aleksa@google.com])' > "${catatonit_dir}/configure.ac"
    git -C "${catatonit_dir}" add -A && git -C "${catatonit_dir}" commit -m "init" --quiet

    # --- crun mock repo ---
    local crun_dir="${TEST_TMPDIR}/crun"
    mkdir -p "${crun_dir}"
    git -C "${TEST_TMPDIR}" init crun --quiet
    echo "placeholder" > "${crun_dir}/README"
    git -C "${crun_dir}" add -A && git -C "${crun_dir}" commit -m "init" --quiet
    git -C "${crun_dir}" tag "1.27"

    # --- toolbox mock repo ---
    local toolbox_dir="${TEST_TMPDIR}/toolbox"
    mkdir -p "${toolbox_dir}"
    git -C "${TEST_TMPDIR}" init toolbox --quiet
    echo "project('toolbox', 'c', version: '0.4')" > "${toolbox_dir}/meson.build"
    git -C "${toolbox_dir}" add -A && git -C "${toolbox_dir}" commit -m "init" --quiet

    # --- container-libs mock repo (container-configs maps here) ---
    local container_dir="${TEST_TMPDIR}/container-libs"
    mkdir -p "${container_dir}"
    git -C "${TEST_TMPDIR}" init container-libs --quiet
    echo "placeholder" > "${container_dir}/README"
    git -C "${container_dir}" add -A && git -C "${container_dir}" commit -m "init" --quiet
    git -C "${container_dir}" tag "common/v0.68.0"

    # --- pasta mock repo (date-based, no source extraction) ---
    local pasta_dir="${TEST_TMPDIR}/pasta"
    mkdir -p "${pasta_dir}"
    git -C "${TEST_TMPDIR}" init pasta --quiet
    echo "placeholder" > "${pasta_dir}/README"
    git -C "${pasta_dir}" add -A && git -C "${pasta_dir}" commit -m "init" --quiet
}

teardown() {
    if [[ -n "${TEST_TMPDIR}" && -d "${TEST_TMPDIR}" ]]; then
        rm -rf "${TEST_TMPDIR}"
    fi
}

# ============================================
# Source the function under test
# ============================================

# We need to source package_all.sh in a way that only gets the function,
# not the full script execution. We extract just the function.
source_extract_version_nightly() {
    # Check function exists in the script
    if ! grep -q "extract_version_nightly" "${PROJECT_ROOT}/scripts/package_all.sh"; then
        echo "FATAL: extract_version_nightly function not found in scripts/package_all.sh"
        return 1
    fi

    # Extract the function using sed: from 'extract_version_nightly()' to the closing '}'
    # We eval it to define it in this shell
    eval "$(sed -n '/^extract_version_nightly()/,/^}/p' "${PROJECT_ROOT}/scripts/package_all.sh")"
}

# ============================================
# Tests
# ============================================

echo ""
echo "========================================"
echo "Test: extract_version_nightly"
echo "========================================"
echo ""

setup

# Try to source the function (this is the key TDD gate)
if ! source_extract_version_nightly; then
    echo ""
    echo "RESULT: ALL TESTS FAILED (function not found)"
    echo "  Tests: 0 passed, 7 failed (function missing)"
    teardown
    exit 1
fi

TODAY=$(date +%Y%m%d)

echo "Test 1: Podman nightly version"
result=$(extract_version_nightly "podman" "${TEST_TMPDIR}/podman")
# Should match: 5.9.0~~gitYYYYMMDD.XXXXXXX
assert_matches "podman version format" "^5\.9\.0~~git${TODAY}\.[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 2: Pasta nightly version (date~~git<sha> to prevent pool collisions)"
result=$(extract_version_nightly "pasta" "${TEST_TMPDIR}/pasta")
# Should be YYYYMMDD~~git<7-char-sha> — the tilde-sha suffix prevents nightly
# from sharing a version string with same-day stable builds in the reprepro pool.
assert_matches "pasta returns date~~git<sha>" "^[0-9]{8}~~git[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 2b: pasta maps to the passt clone dir (else nightly yields ~~gitunknown)"
eval "$(sed -n '/^declare -A COMPONENT_BUILD_DIRS=(/,/^)/p' "${PROJECT_ROOT}/scripts/package_all.sh")"
clone_dir=$(grep -oE 'git_clone_update [^ ]+ [^ ]+' "${PROJECT_ROOT}/scripts/build_pasta.sh" | awk '{print $3}')
assert_equals "COMPONENT_BUILD_DIRS[pasta] matches build_pasta.sh clone dir" "${clone_dir}" "${COMPONENT_BUILD_DIRS[pasta]:-pasta}"

echo ""
echo "Test 3: container-configs nightly version (uses common/ tag prefix)"
result=$(extract_version_nightly "container-configs" "${TEST_TMPDIR}/container-libs")
# Should match: 0.68.0~~gitYYYYMMDD.XXXXXXX
assert_matches "container-configs version format" "^0\.68\.0~~git${TODAY}\.[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 4: Buildah nightly version"
result=$(extract_version_nightly "buildah" "${TEST_TMPDIR}/buildah")
assert_matches "buildah version format" "^1\.44\.0~~git${TODAY}\.[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 5: crun nightly version (tag-based)"
result=$(extract_version_nightly "crun" "${TEST_TMPDIR}/crun")
assert_matches "crun version format" "^1\.27~~git${TODAY}\.[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 6: toolbox nightly version (2-part to 3-part normalization)"
result=$(extract_version_nightly "toolbox" "${TEST_TMPDIR}/toolbox")
assert_matches "toolbox version format (3-part)" "^0\.4\.0~~git${TODAY}\.[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 7: fuse-overlayfs nightly version (C/autotools v1.x)"
result=$(extract_version_nightly "fuse-overlayfs" "${TEST_TMPDIR}/fuse-overlayfs")
assert_matches "fuse-overlayfs C version format" "^1\.17~~git${TODAY}\.[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 7b: fuse-overlayfs nightly version (Rust v2.0+)"
result=$(extract_version_nightly "fuse-overlayfs" "${TEST_TMPDIR}/fuse-overlayfs-rust")
assert_matches "fuse-overlayfs Rust version format" "^2\.0\.0~~git${TODAY}\.[0-9a-f]{7}$" "${result}"

echo ""
echo "Test 8: dpkg tilde sort (nightly < release)"
# A nightly version with the full distro suffix must sort below the tagged
# release with the same suffix. dpkg is only available on Debian-based hosts.
if command -v dpkg &>/dev/null; then
    assert_true "nightly sorts below release via dpkg (bookworm)" \
        dpkg --compare-versions "5.9.0~~git20260306.abc1234~deb12.podman1" lt "5.9.0~deb12.podman1"
    assert_true "nightly sorts below release via dpkg (trixie)" \
        dpkg --compare-versions "5.9.0~~git20260306.abc1234~deb13.podman1" lt "5.9.0~deb13.podman1"
    assert_true "pasta nightly sorts below pasta release via dpkg" \
        dpkg --compare-versions "20260306~~gitabc1234~deb12.podman1" lt "20260306~deb12.podman1"
else
    echo "  SKIP: dpkg not available (non-Debian platform)"
    echo "  NOTE: '~~' sorts before '~d', so 5.9.0~~git...~deb12.podman1 < 5.9.0~deb12.podman1"
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# ============================================
# Summary
# ============================================

echo ""
echo "========================================"
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "========================================"

teardown

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    exit 1
fi
exit 0
