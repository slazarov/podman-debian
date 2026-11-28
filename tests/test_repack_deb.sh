#!/bin/bash

# Test repack_deb_xz9() (functions.sh): scripts/package_all.sh rebuilds every
# .deb nFPM writes with `dpkg-deb --root-owner-group -Zxz -z9`, because nFPM's
# own xz has no level setting. The repack must keep the filename and must not
# change the package contents or control data.
#
# The fixture .deb is assembled by hand (ar + tar) the way nFPM lays it out:
# control.tar.gz, a data.tar.xz at a low level, root-owned entries and no "./"
# root entry. It holds a 0755 executable, a 0600 file, a conffile and a
# symlink, and is built under a restrictive umask. A fake dpkg-deb on PATH
# injects the two failure rows: a rebuild that changes the contents and a
# rebuild that fails. The helpers are sed-extracted from functions.sh (from
# 'name()' to the first col-0 '}'), because sourcing it pulls in config.sh.
#
# Needs dpkg-deb, ar, tar, xz, gzip. Without them it prints SKIP;
# REQUIRE_INTEGRATION_DEPS=1 turns that skip into a failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
FUNCTIONS_SH="${PROJECT_ROOT}/functions.sh"

# shellcheck source=tests/lib/mock_http.sh
source "${SCRIPT_DIR}/lib/mock_http.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_true() {
    local ldescription="$1"
    shift
    if ("$@") > /dev/null 2>&1; then
        pass "${ldescription}"
    else
        fail "${ldescription}"
    fi
}

assert_false() {
    local ldescription="$1"
    shift
    if ("$@") > /dev/null 2>&1; then
        fail "${ldescription}"
    else
        pass "${ldescription}"
    fi
}

summary() {
    echo ""
    echo "========================================"
    echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    echo "========================================"
    if [[ ${FAIL_COUNT} -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

echo ""
echo "========================================"
echo "Test: repack_deb_xz9 (dpkg-deb -Zxz -z9 repack)"
echo "========================================"
echo ""

REPACK_FNS=(_deb_listing _repack_deb_same repack_deb_xz9)
for fn in "${REPACK_FNS[@]}"; do
    if ! grep -q "^${fn}()" "${FUNCTIONS_SH}"; then
        echo "FATAL: ${fn}() not found in ${FUNCTIONS_SH}"
        exit 1
    fi
    eval "$(sed -n "/^${fn}()/,/^}/p" "${FUNCTIONS_SH}")"
done

missing=""
for tool in dpkg-deb ar tar xz gzip; do
    command -v "${tool}" > /dev/null 2>&1 || missing+=" ${tool}"
done
if [[ -n "${missing}" ]]; then
    echo "  SKIP: repack checks need${missing}"
    require_integration_deps "${missing# }"
    summary
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
REAL_DPKG_DEB="$(command -v dpkg-deb)"

# make_fixture <out.deb> [tiny] -> nFPM-shaped .deb (see header).
make_fixture() {
    local lout="$1" lkind="${2:-}"
    local lsrc="${WORK}/fixture-src"
    rm -rf "${lsrc}"
    mkdir -p "${lsrc}/data/usr/bin" "${lsrc}/data/etc/demo" "${lsrc}/data/usr/share/demo" "${lsrc}/ctrl"
    # Payload: a ~400 KB pseudo-random text block repeated three times. xz -0
    # (256 KiB dictionary) cannot see the repeats, xz -9 (64 MiB) can, as with
    # podman / podman-remote. "tiny" leaves it empty so -9 cannot win.
    if [[ "${lkind}" == "tiny" ]]; then
        : > "${lsrc}/data/usr/share/demo/payload.txt"
    else
        awk 'BEGIN { srand(1); for (i = 0; i < 60000; i++) printf "w%d%s", int(rand() * 5000), (i % 12 == 11 ? "\n" : " ") }' > "${lsrc}/block"
        cat "${lsrc}/block" "${lsrc}/block" "${lsrc}/block" > "${lsrc}/data/usr/share/demo/payload.txt"
        rm -f "${lsrc}/block"
    fi
    printf '#!/bin/sh\necho demo\n' > "${lsrc}/data/usr/bin/demo"
    chmod 0755 "${lsrc}/data/usr/bin/demo"
    printf 'secret=1\n' > "${lsrc}/data/usr/share/demo/private"
    chmod 0600 "${lsrc}/data/usr/share/demo/private"
    printf 'key=value\n' > "${lsrc}/data/etc/demo/demo.conf"
    chmod 0644 "${lsrc}/data/etc/demo/demo.conf" "${lsrc}/data/usr/share/demo/payload.txt"
    ln -s demo "${lsrc}/data/usr/bin/demo-link"
    find "${lsrc}/data" -type d -exec chmod 0755 {} +
    cat > "${lsrc}/ctrl/control" << 'EOF'
Package: podman-demo
Version: 1.0~deb13.podman3
Section: admin
Priority: optional
Architecture: amd64
Maintainer: Test <noreply@example.com>
Installed-Size: 300
Description: repack fixture
EOF
    printf '/etc/demo/demo.conf\n' > "${lsrc}/ctrl/conffiles"
    (cd "${lsrc}/data" && find . -type f ! -path ./etc/demo/demo.conf -printf '%P\n' | LC_ALL=C sort | xargs md5sum) > "${lsrc}/ctrl/md5sums"
    chmod 0644 "${lsrc}/ctrl/"*
    printf '2.0\n' > "${lsrc}/debian-binary"
    # No "./" root entry, like nFPM.
    tar -C "${lsrc}/ctrl" --owner=root:0 --group=root:0 -czf "${lsrc}/control.tar.gz" ./control ./conffiles ./md5sums
    tar -C "${lsrc}/data" --owner=root:0 --group=root:0 -cf - ./etc ./usr | xz -0 > "${lsrc}/data.tar.xz"
    rm -f "${lout}"
    (cd "${lsrc}" && ar rc "${lout}" debian-binary control.tar.gz data.tar.xz)
}

listing_of() { _deb_listing "$1"; }
# control_member <deb> <name> -> contents of one control member.
control_member() {
    local ldir
    ldir="$(mktemp -d)"
    dpkg-deb -e "$1" "${ldir}/c"
    cat "${ldir}/c/$2"
    rm -rf "${ldir}"
}
sum_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { stat -c %s "$1"; }
members_of() { ar t "$1" | tr '\n' ' '; }

# run_repack_with_fake <fake-body> <deb> -> repack with a fake dpkg-deb first
# on PATH. The fake forwards to the real dpkg-deb except where <fake-body>
# intervenes on `-b` (build).
run_repack_with_fake() {
    local lbody="$1" ldeb="$2"
    local lfake="${WORK}/fakebin"
    rm -rf "${lfake}"
    mkdir -p "${lfake}"
    {
        echo '#!/bin/bash'
        echo "REAL='${REAL_DPKG_DEB}'"
        echo 'for a in "$@"; do if [[ "${a}" == "-b" ]]; then building=1; fi; done'
        echo 'if [[ -n "${building:-}" ]]; then'
        printf '%s\n' "${lbody}"
        echo 'fi'
        echo 'exec "${REAL}" "$@"'
    } > "${lfake}/dpkg-deb"
    chmod +x "${lfake}/dpkg-deb"
    env PATH="${lfake}:${PATH}" bash -c "set -euo pipefail; $(declare -f "${REPACK_FNS[@]}"); repack_deb_xz9 '${ldeb}'"
}

for mask in 0002 0027; do
    echo ""
    echo "Test 1 (umask ${mask}): repack keeps filename, contents and control"
    deb="${WORK}/podman-demo_1.0~deb13.podman3_amd64.deb"
    (umask "${mask}" && make_fixture "${deb}")
    before_list="$(listing_of "${deb}")"
    before_ctrl="$(dpkg-deb -f "${deb}")"
    before_conffiles="$(control_member "${deb}" conffiles)"
    before_md5="$(control_member "${deb}" md5sums)"
    before_size="$(size_of "${deb}")"
    before_mode="$(stat -c %a "${deb}")"

    assert_true "repack_deb_xz9 succeeds" bash -c "umask ${mask}; $(declare -f "${REPACK_FNS[@]}"); repack_deb_xz9 '${deb}'"
    assert_true "same filename still present" test -f "${deb}"
    assert_false "no .repack.tmp left behind" test -e "${deb}.repack.tmp"
    assert_true "data member is data.tar.xz" grep -q "data.tar.xz" <<< "$(members_of "${deb}")"
    assert_true "file listing identical (mode, owner, size, path, link target)" test "$(listing_of "${deb}")" == "${before_list}"
    assert_true "control fields identical" test "$(dpkg-deb -f "${deb}")" == "${before_ctrl}"
    assert_true "conffiles identical" test "$(control_member "${deb}" conffiles)" == "${before_conffiles}"
    assert_true "md5sums identical" test "$(control_member "${deb}" md5sums)" == "${before_md5}"
    raw="$(dpkg-deb -c "${deb}")"
    assert_true "root dir is drwxr-xr-x root/root" test "$(awk '$6 == "./" {print $1 " " $2}' <<< "${raw}")" == "drwxr-xr-x root/root"
    assert_true "0600 file kept its mode" grep -q '^-rw------- root/root .* ./usr/share/demo/private$' <<< "${raw}"
    assert_true "0755 file kept its mode" grep -q '^-rwxr-xr-x root/root .* ./usr/bin/demo$' <<< "${raw}"
    assert_true "symlink kept its target" grep -q '^l.* ./usr/bin/demo-link -> demo$' <<< "${raw}"
    assert_true "repacked smaller (${before_size} -> $(size_of "${deb}"))" test "$(size_of "${deb}")" -lt "${before_size}"
    assert_true ".deb file mode unchanged" test "$(stat -c %a "${deb}")" == "${before_mode}"
    assert_true "repacked .deb passes dpkg-deb --info" dpkg-deb --info "${deb}"
done

echo ""
echo "Test 2: a rebuild that changes the contents fails and keeps the original"
deb="${WORK}/podman-demo_1.0~deb13.podman3_amd64.deb"
make_fixture "${deb}"
orig_sum="$(sum_of "${deb}")"
# Drop a file from the tree just before building.
fake_drop='for a in "$@"; do [[ -d "${a}/DEBIAN" ]] && rm -f "${a}/usr/share/demo/private"; done'
out="$(run_repack_with_fake "${fake_drop}" "${deb}" 2>&1)" && rc=0 || rc=$?
assert_true "repack exits non-zero" test "${rc}" -ne 0
assert_true "error names the .deb" grep -qF "${deb}" <<< "${out}"
assert_true "original .deb byte-identical" test "$(sum_of "${deb}")" == "${orig_sum}"
assert_false "no .repack.tmp left behind" test -e "${deb}.repack.tmp"

# Change a control field just before building.
fake_ctrl='for a in "$@"; do [[ -f "${a}/DEBIAN/control" ]] && sed -i "s/^Section: admin/Section: misc/" "${a}/DEBIAN/control"; done'
out="$(run_repack_with_fake "${fake_ctrl}" "${deb}" 2>&1)" && rc=0 || rc=$?
assert_true "changed control field: repack exits non-zero" test "${rc}" -ne 0
assert_true "changed control field: original byte-identical" test "$(sum_of "${deb}")" == "${orig_sum}"

# Make a file executable just before building (mode change).
fake_mode='for a in "$@"; do [[ -d "${a}/DEBIAN" ]] && chmod 0755 "${a}/etc/demo/demo.conf"; done'
out="$(run_repack_with_fake "${fake_mode}" "${deb}" 2>&1)" && rc=0 || rc=$?
assert_true "changed mode: repack exits non-zero" test "${rc}" -ne 0
assert_true "changed mode: original byte-identical" test "$(sum_of "${deb}")" == "${orig_sum}"

# Edit a control member other than control (md5sums) just before building.
fake_member='for a in "$@"; do [[ -f "${a}/DEBIAN/md5sums" ]] && echo "00000000000000000000000000000000  usr/bin/extra" >> "${a}/DEBIAN/md5sums"; done'
out="$(run_repack_with_fake "${fake_member}" "${deb}" 2>&1)" && rc=0 || rc=$?
assert_true "edited md5sums: repack exits non-zero" test "${rc}" -ne 0
assert_true "edited md5sums: original byte-identical" test "$(sum_of "${deb}")" == "${orig_sum}"

# Add a maintainer script just before building.
fake_script='for a in "$@"; do [[ -d "${a}/DEBIAN" ]] && printf "#!/bin/sh\nexit 0\n" > "${a}/DEBIAN/postinst" && chmod 0755 "${a}/DEBIAN/postinst"; done'
out="$(run_repack_with_fake "${fake_script}" "${deb}" 2>&1)" && rc=0 || rc=$?
assert_true "added postinst: repack exits non-zero" test "${rc}" -ne 0
assert_true "added postinst: error reports differing control members" grep -q "control members differ" <<< "${out}"
assert_true "added postinst: original byte-identical" test "$(sum_of "${deb}")" == "${orig_sum}"

echo ""
echo "Test 3: a failing dpkg-deb build fails and keeps the original"
out="$(run_repack_with_fake 'exit 2' "${deb}" 2>&1)" && rc=0 || rc=$?
assert_true "repack exits non-zero" test "${rc}" -ne 0
assert_true "error names the .deb" grep -qF "${deb}" <<< "${out}"
assert_true "original .deb byte-identical" test "$(sum_of "${deb}")" == "${orig_sum}"
assert_false "no .repack.tmp left behind" test -e "${deb}.repack.tmp"

echo ""
echo "Test 4: a repack that would grow the .deb keeps the original"
tiny="${WORK}/podman-tiny_1.0~deb13.podman3_amd64.deb"
make_fixture "${tiny}" tiny
tiny_sum="$(sum_of "${tiny}")"
assert_true "repack_deb_xz9 succeeds" repack_deb_xz9 "${tiny}"
assert_true "original kept byte-identical" test "$(sum_of "${tiny}")" == "${tiny_sum}"
assert_false "no .repack.tmp left behind" test -e "${tiny}.repack.tmp"

echo ""
echo "Test 5: missing input fails"
assert_false "repack of a missing .deb fails" repack_deb_xz9 "${WORK}/does-not-exist.deb"

echo ""
echo "Test 6: package_all.sh build_deb repacks only the .deb nFPM just wrote"
PACKAGE_ALL_SH="${PROJECT_ROOT}/scripts/package_all.sh"
if ! grep -q "^build_deb()" "${PACKAGE_ALL_SH}"; then
    echo "FATAL: build_deb() not found in ${PACKAGE_ALL_SH}"
    exit 1
fi
BUILD_DEB_FN="$(sed -n "/^build_deb()/,/^}/p" "${PACKAGE_ALL_SH}")"
STUB_SRC="${WORK}/stub-src"
mkdir -p "${STUB_SRC}"
make_fixture "${STUB_SRC}/podman-demo_1.0~deb13.podman3_amd64.deb"
cp "${STUB_SRC}/podman-demo_1.0~deb13.podman3_amd64.deb" "${STUB_SRC}/podman-other_1.0~deb13.podman3_amd64.deb"

# run_build_deb <count> <output-dir> -> build_deb with a stub nfpm that copies
# <count> fixture .debs (0, 1 or 2) into its --target dir.
run_build_deb() {
    local lcount="$1" lout="$2"
    local lstub="${WORK}/stubbin"
    rm -rf "${lstub}"
    mkdir -p "${lstub}"
    {
        echo '#!/bin/bash'
        echo 'target=""; prev=""'
        echo 'for a in "$@"; do [[ "${prev}" == "--target" ]] && target="${a}"; prev="${a}"; done'
        echo "src='${STUB_SRC}'"
        echo "count='${lcount}'"
        echo '[[ "${count}" -ge 1 ]] && cp "${src}/podman-demo_1.0~deb13.podman3_amd64.deb" "${target}"'
        echo '[[ "${count}" -ge 2 ]] && cp "${src}/podman-other_1.0~deb13.podman3_amd64.deb" "${target}"'
        echo 'exit 0'
    } > "${lstub}/nfpm"
    chmod +x "${lstub}/nfpm"
    rm -rf "${WORK}/pkgroot"
    mkdir -p "${WORK}/pkgroot"
    env PATH="${lstub}:${PATH}" OUTPUT_DIR="${lout}" PACKAGING_ROOT="${WORK}/pkgroot" bash -c "set -euo pipefail; $(declare -f "${REPACK_FNS[@]}"); ${BUILD_DEB_FN}; build_deb /dev/null"
}

outdir="${WORK}/output"
mkdir -p "${outdir}"
make_fixture "${outdir}/podman-stale_0.9~deb13.podman3_amd64.deb"
stale_sum="$(sum_of "${outdir}/podman-stale_0.9~deb13.podman3_amd64.deb")"
assert_true "build_deb succeeds with one .deb from nFPM" run_build_deb 1 "${outdir}"
landed="${outdir}/podman-demo_1.0~deb13.podman3_amd64.deb"
assert_true "the .deb lands in OUTPUT_DIR" test -f "${landed}"
raw="$(dpkg-deb -c "${landed}")"
assert_true "landed .deb was repacked (carries dpkg-deb's ./ root entry)" grep -q ' \./$' <<< "${raw}"
assert_true "landed .deb has data.tar.xz" grep -q "data.tar.xz" <<< "$(members_of "${landed}")"
assert_true "landed .deb is smaller than nFPM's" test "$(size_of "${landed}")" -lt "$(size_of "${STUB_SRC}/podman-demo_1.0~deb13.podman3_amd64.deb")"
assert_true "stale .deb in OUTPUT_DIR byte-identical" test "$(sum_of "${outdir}/podman-stale_0.9~deb13.podman3_amd64.deb")" == "${stale_sum}"

outdir0="${WORK}/output0"
mkdir -p "${outdir0}"
assert_false "build_deb fails when nFPM writes no .deb" run_build_deb 0 "${outdir0}"
assert_true "nothing reaches OUTPUT_DIR when nFPM writes no .deb" test -z "$(ls -A "${outdir0}")"
outdir2="${WORK}/output2"
mkdir -p "${outdir2}"
assert_false "build_deb fails when nFPM writes two .debs" run_build_deb 2 "${outdir2}"
assert_true "nothing reaches OUTPUT_DIR on failure" test -z "$(ls -A "${outdir2}")"

summary
