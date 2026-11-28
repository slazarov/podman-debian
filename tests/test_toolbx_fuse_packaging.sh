#!/bin/bash

# test_toolbx_fuse_packaging.sh - podman-toolbx's /run/host setup and
# podman-fuse-overlayfs's fuse3 dependency.
#
# toolbox is linked with its dynamic loader under /run/host, so it can only
# start on the host once /run/host links to /. Upstream's
# tmpfiles.d/toolbox.conf creates that link; podman-toolbx ships it and its
# postinst applies it. fuse-overlayfs is a static binary that runs
# fusermount3 (package fuse3), which library detection cannot see.
#
# Checks the nFPM configs, the render allowlists in package_all.sh and
# verify_depends.sh, and the postinst's behavior against a stub
# systemd-tmpfiles. When nfpm and dpkg-deb are installed, it also builds
# both packages from a fixture staging tree and inspects the result.
#
# Run via `bash tests/test_toolbx_fuse_packaging.sh`.

set -euo pipefail

PASS=0
FAIL=0

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NFPM_DIR="${PROJECT_ROOT}/packaging/nfpm"
POSTINST="${NFPM_DIR}/scripts/toolbx-postinst.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1" >&2
    FAIL=$((FAIL + 1))
}

check() {
    local label="$1"
    shift
    if "$@"; then pass "${label}"; else fail "${label}"; fi
}

# Render a component YAML the way package_all.sh does.
render() {
    local lcomponent="$1" lout="$2"
    VERSION="1.0~deb13.podman1" ARCH=amd64 DESTDIR="${WORK}/destdir" \
        DETECTED_DEPENDS="" NFPM_DIR="${NFPM_DIR}" \
        envsubst '${VERSION} ${ARCH} ${DESTDIR} ${DETECTED_DEPENDS} ${NFPM_DIR}' \
        < "${NFPM_DIR}/${lcomponent}.yaml" > "${lout}"
}

echo "=== nFPM configs ==="
render toolbox "${WORK}/toolbox.yaml"
render fuse-overlayfs "${WORK}/fuse-overlayfs.yaml"

toolbox_rendered="$(cat "${WORK}/toolbox.yaml")"
check "toolbox.yaml ships /usr/lib/tmpfiles.d/toolbox.conf" \
    grep -q '^    dst: /usr/lib/tmpfiles.d/toolbox.conf$' <<< "${toolbox_rendered}"
check "toolbox.yaml takes toolbox.conf from the staging tree" \
    grep -qF "src: \"${WORK}/destdir/usr/lib/tmpfiles.d/toolbox.conf\"" <<< "${toolbox_rendered}"
check "toolbox.yaml's postinstall renders to the absolute script path" \
    grep -qF "postinstall: \"${POSTINST}\"" <<< "${toolbox_rendered}"
check "no unrendered \${...} is left in toolbox.yaml" \
    test "$(grep -c '\${' <<< "${toolbox_rendered}" || true)" -eq 0

fuse_deps="$(awk '/^depends:/{f=1;next} f&&/^[^[:space:]#]/{f=0} f&&/^[[:space:]]*-[[:space:]]/{print $2}' "${WORK}/fuse-overlayfs.yaml")"
check "fuse-overlayfs.yaml Depends fuse3" grep -qx fuse3 <<< "${fuse_deps}"
check "fuse-overlayfs.yaml keeps the detected-libraries slot" \
    grep -q '^\${DETECTED_DEPENDS}$' "${NFPM_DIR}/fuse-overlayfs.yaml"

echo "=== render allowlists ==="
for script in scripts/package_all.sh scripts/verify_depends.sh; do
    check "${script} allowlists \${NFPM_DIR} for envsubst" \
        grep -qF "envsubst '\${VERSION} \${ARCH} \${DESTDIR} \${DETECTED_DEPENDS} \${NFPM_DIR}'" "${PROJECT_ROOT}/${script}"
    check "${script} exports NFPM_DIR before rendering" \
        grep -qE '^[[:space:]]*export NFPM_DIR$' "${PROJECT_ROOT}/${script}"
done

echo "=== postinst ==="
check "postinst is executable" test -x "${POSTINST}"
check "postinst starts with #!/bin/sh" test "$(head -n1 "${POSTINST}")" == "#!/bin/sh"
check "postinst parses under sh -n" sh -n "${POSTINST}"

STUB="${WORK}/stub"
mkdir -p "${STUB}"
cat > "${STUB}/systemd-tmpfiles" << 'EOF'
#!/bin/sh
echo "$*" >> "${TMPFILES_LOG}"
exit "${TMPFILES_RC:-0}"
EOF
chmod +x "${STUB}/systemd-tmpfiles"
export TMPFILES_LOG="${WORK}/tmpfiles.log"

# run_postinst <arg> [env...] -> "<rc>|<logged calls>"
run_postinst() {
    local larg="$1" lrc=0
    shift
    rm -f "${TMPFILES_LOG}"
    env PATH="${STUB}:/usr/bin:/bin" "$@" sh "${POSTINST}" "${larg}" > /dev/null 2>&1 || lrc=$?
    echo "${lrc}|$(cat "${TMPFILES_LOG}" 2> /dev/null || true)"
}

check "configure -> systemd-tmpfiles --create toolbox.conf" \
    test "$(run_postinst configure)" == "0|--create toolbox.conf"
check "configure with DPKG_ROOT -> passes --root" \
    test "$(run_postinst configure DPKG_ROOT=/target)" == "0|--root=/target --create toolbox.conf"
check "abort-upgrade -> reapplies toolbox.conf" \
    test "$(run_postinst abort-upgrade)" == "0|--create toolbox.conf"
check "a failing systemd-tmpfiles does not fail the install" \
    test "$(run_postinst configure TMPFILES_RC=1)" == "0|--create toolbox.conf"
check "unknown action -> no call, exit 0" test "$(run_postinst triggered)" == "0|"
NOTMP="${WORK}/no-tmpfiles"
mkdir -p "${NOTMP}"
for tool in sh cat; do ln -s "$(command -v "${tool}")" "${NOTMP}/${tool}"; done
check "no systemd-tmpfiles on the host -> exit 0" \
    test "$(env PATH="${NOTMP}" sh "${POSTINST}" configure > /dev/null 2>&1 && echo ok)" == "ok"

echo "=== built packages (nfpm) ==="
if command -v nfpm > /dev/null 2>&1 && command -v dpkg-deb > /dev/null 2>&1; then
    D="${WORK}/destdir"
    mkdir -p "${D}/usr/bin" "${D}/usr/share/man/man1" "${D}/usr/share/bash-completion/completions" \
        "${D}/usr/lib/tmpfiles.d" "${D}/usr/share/toolbox"
    printf '#!/bin/sh\n' > "${D}/usr/bin/toolbox"
    printf '#!/bin/sh\n' > "${D}/usr/bin/fuse-overlayfs"
    : > "${D}/usr/share/man/man1/toolbox.1"
    : > "${D}/usr/share/bash-completion/completions/toolbox"
    : > "${D}/usr/share/toolbox/toolbox.sh"
    printf 'd /run/media 0755 root root - -\nL /run/host  -    -    -    - ../\n' > "${D}/usr/lib/tmpfiles.d/toolbox.conf"
    mkdir -p "${WORK}/out"
    nfpm pkg --config "${WORK}/toolbox.yaml" --packager deb --target "${WORK}/out/" > /dev/null
    nfpm pkg --config "${WORK}/fuse-overlayfs.yaml" --packager deb --target "${WORK}/out/" > /dev/null
    tdeb="$(ls "${WORK}"/out/podman-toolbx_*.deb)"
    fdeb="$(ls "${WORK}"/out/podman-fuse-overlayfs_*.deb)"
    check "podman-toolbx contains /usr/lib/tmpfiles.d/toolbox.conf" \
        grep -q ' ./usr/lib/tmpfiles.d/toolbox.conf$' <<< "$(dpkg-deb -c "${tdeb}")"
    dpkg-deb -e "${tdeb}" "${WORK}/ctl"
    check "podman-toolbx postinst is the packaged script" cmp -s "${WORK}/ctl/postinst" "${POSTINST}"
    check "podman-fuse-overlayfs Depends: fuse3" test "$(dpkg-deb -f "${fdeb}" Depends)" == "fuse3"
else
    echo "SKIP: nfpm or dpkg-deb not installed"
fi

echo "Results: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
