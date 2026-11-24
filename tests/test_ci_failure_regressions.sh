#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "${TEST_TMPDIR}"' EXIT
SKIP_CONFIG_SOURCE=1 source "${PROJECT_ROOT}/functions.sh"

# Exercise release detection without network or loading config.sh.
curl() {
    printf '%s\n' "$*" > "${TEST_TMPDIR}/curl-args"
    printf '%s\n' "${MOCK_RESPONSE}"
    return "${MOCK_STATUS}"
}
MOCK_STATUS=0
for version in 34.0 3.20.3; do
    MOCK_RESPONSE="{\"tag_name\": \"v${version}\"}"
    [[ "$(get_latest_protoc_version)" == "${version}" ]]
done
for MOCK_RESPONSE in '' '{"message":"API rate limit exceeded"}' '{"tag_name":"v"}' '{"tag_name":"v34.0-rc1"}'; do
    if get_latest_protoc_version > "${TEST_TMPDIR}/version" 2>/dev/null; then
        echo "FAIL: accepted missing or invalid protoc version" >&2
        exit 1
    fi
    [[ ! -s "${TEST_TMPDIR}/version" ]]
done
MOCK_STATUS=22
MOCK_RESPONSE='{"tag_name":"v34.0"}'
if get_latest_protoc_version > "${TEST_TMPDIR}/version" 2>/dev/null; then
    echo "FAIL: accepted failed release lookup" >&2
    exit 1
fi
[[ ! -s "${TEST_TMPDIR}/version" ]]
grep -q -- '--retry 3 --retry-all-errors' "${TEST_TMPDIR}/curl-args"
echo "PASS: protoc success, invalid metadata, HTTP failures and retry options"

# The assignment in config must preserve failure instead of export masking it.
if (
    unset PROTOC_VERSION PROTOC_TAG
    export ARCH=amd64 DISTRO=trixie GOVERSION=1.26.8 RUST_VERSION=1.90.0
    export GOCACHE="${TEST_TMPDIR}/go-build" GOMODCACHE="${TEST_TMPDIR}/go-mod"
    source "${PROJECT_ROOT}/config.sh" > "${TEST_TMPDIR}/config-failure" 2>&1
    echo continued > "${TEST_TMPDIR}/continued"
); then
    echo "FAIL: config ignored failed protoc lookup" >&2
    exit 1
fi
[[ ! -e "${TEST_TMPDIR}/continued" ]]
grep -q 'ERROR: Set PROTOC_VERSION explicitly' "${TEST_TMPDIR}/config-failure"
(
    unset PROTOC_TAG
    export ARCH=amd64 DISTRO=trixie GOVERSION=1.26.8 RUST_VERSION=1.90.0 PROTOC_VERSION=34.0
    export GOCACHE="${TEST_TMPDIR}/go-build" GOMODCACHE="${TEST_TMPDIR}/go-mod"
    source "${PROJECT_ROOT}/config.sh" > /dev/null
    [[ "${PROTOC_TAG}" == v34.0 ]]
)
(
    export ARCH=amd64 DISTRO=trixie GOVERSION=1.26.8 RUST_VERSION=1.90.0
    export GOCACHE="${TEST_TMPDIR}/go-build" GOMODCACHE="${TEST_TMPDIR}/go-mod"
    unset PROTOC_VERSION PROTOC_TAG
    MOCK_STATUS=0
    MOCK_RESPONSE='{"tag_name":"v34.0"}'
    source "${PROJECT_ROOT}/config.sh" > /dev/null
    [[ "${PROTOC_VERSION}" == 34.0 && "${PROTOC_TAG}" == v34.0 ]]
    bash -c '[[ "${PROTOC_VERSION}" == 34.0 ]]'
)
(
    export ARCH=amd64 DISTRO=trixie GOVERSION=1.26.8 RUST_VERSION=1.90.0
    export GOCACHE="${TEST_TMPDIR}/go-build" GOMODCACHE="${TEST_TMPDIR}/go-mod"
    export PROTOC_VERSION=34.0 PROTOC_TAG=custom-tag
    source "${PROJECT_ROOT}/config.sh" > /dev/null
    [[ "${PROTOC_TAG}" == custom-tag ]]
)
echo "PASS: config stops on lookup failure and preserves explicit overrides"

# The failing Netavark revision still declared 1.88 when its lockfile began
# requiring 1.89. Exercise CI's actual build-environment step and local config.
(
    unset NIGHTLY_BUILD RUST_VERSION
    export MOCK_STATUS=0 MOCK_RESPONSE='rust-version = "1.88"' TEST_TMPDIR
    export -f curl
    [[ "$(NIGHTLY_BUILD=true get_required_rust_version v2.0.0)" == 1.88 ]]

    awk '
        /- name: Prepare the build environment/ { found=1; next }
        found && /^      - / { exit }
        found && /^        run: \|/ { body=1; next }
        body { sub(/^          /, ""); print }
    ' "${PROJECT_ROOT}/.github/workflows/build-packages.yml" > "${TEST_TMPDIR}/build-env.sh"
    [[ -s "${TEST_TMPDIR}/build-env.sh" ]]
    cd "${PROJECT_ROOT}"
    export RUNNER_TEMP="${TEST_TMPDIR}" GITHUB_OUTPUT="${TEST_TMPDIR}/build-outputs"
    source scripts/ci_helpers.sh
    printf -v RESOLVED_ENV 'export %s="v2.0.0"\n' "${RESOLVED_ENV_REQUIRED_KEYS[@]}"
    for track in stable v5; do
        : > "${GITHUB_OUTPUT}"
        TRACK="${track}" RESOLVED_ENV="${RESOLVED_ENV}" bash "${TEST_TMPDIR}/build-env.sh" > /dev/null
        grep -qx 'RUST_VERSION=1.88' "${RUNNER_TEMP}/build-env"
        grep -qx 'rust=1.88' "${GITHUB_OUTPUT}"
        grep -q '/containers/netavark/v2.0.0/Cargo.toml' "${TEST_TMPDIR}/curl-args"
        rm "${TEST_TMPDIR}/curl-args"
    done
    : > "${GITHUB_OUTPUT}"
    TRACK=nightly bash "${TEST_TMPDIR}/build-env.sh" > /dev/null
    grep -qx 'NIGHTLY_BUILD=true' "${TEST_TMPDIR}/build-env"
    grep -qx 'SHALLOW_CLONE=false' "${TEST_TMPDIR}/build-env"
    grep -qx 'RUST_VERSION=stable' "${TEST_TMPDIR}/build-env"
    grep -qx 'rust=stable' "${TEST_TMPDIR}/build-outputs"

    export NIGHTLY_BUILD=true ARCH=amd64 DISTRO=trixie GOVERSION=1.26.8 PROTOC_VERSION=34.0
    export GOCACHE="${TEST_TMPDIR}/go-build" GOMODCACHE="${TEST_TMPDIR}/go-mod"
    (
        source "${PROJECT_ROOT}/config.sh" > /dev/null
        [[ "${RUST_VERSION}" == stable ]]
    )
    (
        export RUST_VERSION=1.90.0
        source "${PROJECT_ROOT}/config.sh" > /dev/null
        [[ "${RUST_VERSION}" == 1.90.0 ]]
    )
    [[ ! -e "${TEST_TMPDIR}/curl-args" ]]
)
echo "PASS: nightly CI and local setup use stable Rust by default"

# Extract the actual workflow block, so the regression executes CI's code.
awk '
    /- name: Download build artifacts/ { found=1; next }
    found && /^      - / { exit }
    found && /^        run: \|/ { body=1; next }
    body { sub(/^          /, ""); print }
' "${PROJECT_ROOT}/.github/workflows/build-packages.yml" > "${TEST_TMPDIR}/download.sh"
[[ -s "${TEST_TMPDIR}/download.sh" ]]
mkdir -p "${TEST_TMPDIR}/bin"
cat > "${TEST_TMPDIR}/bin/gh" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$1" == run && "$2" == download && "$3" == 123 && "$4" == --name && "$6" == --dir ]]
[[ "$7" == "artifacts/$5" ]]
printf '%s\n' "$5" >> "${RUNNER_TEMP}/downloads"
[[ "$5" != "${FAIL_ARTIFACT:-}" ]] || exit 1
mkdir -p "$7"
case "$5" in
    debs-*) touch "$7/package.deb" ;;
    nightly-revs-*) echo revision > "$7/revisions.txt" ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "${TEST_TMPDIR}/bin/gh"
export PATH="${TEST_TMPDIR}/bin:${PATH}"
export RUNNER_TEMP="${TEST_TMPDIR}" GITHUB_RUN_ID=123

for TRACK in stable nightly; do
    export TRACK
    for cells in 'bookworm success\ntrixie failure' 'bookworm failure\ntrixie success' 'bookworm success\ntrixie success'; do
        WORK_DIR=$(mktemp -d "${TEST_TMPDIR}/case.XXXXXX")
        printf '%b\n' "${cells}" > "${RUNNER_TEMP}/cells.txt"
        : > "${RUNNER_TEMP}/downloads"
        (cd "${WORK_DIR}" && bash "${TEST_TMPDIR}/download.sh")
        while read -r distro conclusion; do
            if [[ "${conclusion}" == success ]]; then
                [[ -f "${WORK_DIR}/artifacts/debs-${distro}/package.deb" ]]
                if [[ "${TRACK}" == nightly ]]; then
                    [[ -s "${WORK_DIR}/artifacts/nightly-revs-${distro}/revisions.txt" ]]
                else
                    [[ ! -d "${WORK_DIR}/artifacts/nightly-revs-${distro}" ]]
                fi
            else
                [[ ! -d "${WORK_DIR}/artifacts/debs-${distro}" ]]
            fi
        done < "${RUNNER_TEMP}/cells.txt"
    done
done
echo "PASS: single and multiple successful distros preserve artifact directories"

printf 'bookworm success\ntrixie success\n' > "${RUNNER_TEMP}/cells.txt"
for FAIL_ARTIFACT in debs-bookworm nightly-revs-bookworm; do
    export FAIL_ARTIFACT
    : > "${RUNNER_TEMP}/downloads"
    if (cd "${WORK_DIR}" && bash "${TEST_TMPDIR}/download.sh"); then
        echo "FAIL: ignored artifact download error" >&2
        exit 1
    fi
    if grep -q trixie "${RUNNER_TEMP}/downloads"; then
        echo "FAIL: continued after download error" >&2
        exit 1
    fi
done
echo "PASS: package and revision download failures stop publishing"
