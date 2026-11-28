#!/bin/bash

# Test strip_staged_binaries() / verify_binaries_stripped() (functions.sh), the
# packaging-stage strip pass run by scripts/package_all.sh before nFPM, plus the
# nFPM manifest invariants that ship with it (xz compression, pasta.yaml keeps
# `contents:` last).
#
# Fixtures are compiled with `cc -g` (an executable and a shared object, both
# carrying .symtab + .debug_*), alongside a shell script, a relocatable .o, an
# ar archive and a symlink. The helpers are sed-extracted from functions.sh
# (from 'name()' to the first col-0 '}') like test_detect_distro_depends.sh,
# because sourcing functions.sh pulls in config.sh.
#
# Needs cc, strip, readelf (and ar). Without them the ELF checks print SKIP;
# REQUIRE_INTEGRATION_DEPS=1 turns that skip into a failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
FUNCTIONS_SH="${PROJECT_ROOT}/functions.sh"
NFPM_DIR="${PROJECT_ROOT}/packaging/nfpm"

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
echo "Test: nFPM manifests (xz compression, pasta contents: last)"
echo "========================================"
echo ""

manifest_count=0
for manifest in "${NFPM_DIR}"/*.yaml; do
    manifest_count=$((manifest_count + 1))
    lname="$(basename "${manifest}")"
    if awk '/^deb:/{indeb=1; next} /^[^[:space:]#]/{indeb=0} indeb && /^  compression: xz[[:space:]]*$/{found=1} END{exit !found}' "${manifest}"; then
        pass "${lname} declares deb.compression: xz"
    else
        fail "${lname} does not declare deb.compression: xz"
    fi
done
if [[ "${manifest_count}" -ge 1 ]]; then
    pass "${manifest_count} nFPM manifests checked"
else
    fail "no nFPM manifests found in ${NFPM_DIR}"
fi

last_top_key="$(grep -E '^[a-z_]+:' "${NFPM_DIR}/pasta.yaml" | tail -1)"
if [[ "${last_top_key}" == "contents:" ]]; then
    pass "pasta.yaml: contents: is the last top-level key (avx2 append target)"
else
    fail "pasta.yaml: last top-level key is '${last_top_key}', not 'contents:'"
fi

echo ""
echo "========================================"
echo "Test: package_all.sh strips a private copy of DESTDIR"
echo "========================================"
echo ""

PACKAGE_ALL_SH="${PROJECT_ROOT}/scripts/package_all.sh"
copy_line="$(grep -n '^copy_staging_tree "${DESTDIR}" "${PACKAGING_ROOT}/destdir"$' "${PACKAGE_ALL_SH}" | head -n 1 | cut -d: -f1)"
redirect_line="$(grep -n '^DESTDIR="${PACKAGING_ROOT}/destdir"$' "${PACKAGE_ALL_SH}" | head -n 1 | cut -d: -f1)"
strip_line="$(grep -n '^strip_staged_binaries "${DESTDIR}"$' "${PACKAGE_ALL_SH}" | head -n 1 | cut -d: -f1)"
verify_line="$(grep -n '^verify_binaries_stripped "${DESTDIR}"$' "${PACKAGE_ALL_SH}" | head -n 1 | cut -d: -f1)"
components_line="$(grep -n '^COMPONENTS=(' "${PACKAGE_ALL_SH}" | head -n 1 | cut -d: -f1)"
if [[ -n "${copy_line}" && -n "${redirect_line}" && -n "${strip_line}" && -n "${verify_line}" && -n "${components_line}" ]] \
    && [[ "${copy_line}" -lt "${redirect_line}" && "${redirect_line}" -lt "${strip_line}" ]] \
    && [[ "${strip_line}" -lt "${verify_line}" && "${verify_line}" -lt "${components_line}" ]]; then
    pass "package_all.sh copies DESTDIR, re-points DESTDIR at the copy, then strips and verifies before packaging"
else
    fail "package_all.sh does not copy, re-point, strip, verify in that order before packaging"
fi
if grep -q '^export DESTDIR$' "${PACKAGE_ALL_SH}"; then
    pass "package_all.sh exports the re-pointed DESTDIR"
else
    fail "package_all.sh does not export the re-pointed DESTDIR"
fi
for tool in strip readelf dpkg-deb; do
    if grep -q "${tool}:" <<< "$(grep '^for required_tool in' "${PACKAGE_ALL_SH}")"; then
        pass "package_all.sh checks that ${tool} is installed"
    else
        fail "package_all.sh does not check for ${tool}"
    fi
done

# The EXIT trap block, run with an EXIT trap already in place: the private
# copy is removed and the earlier trap still runs.
trap_block="$(sed -n '/^PACKAGING_ROOT="\$(mktemp -d)"$/,/^trap cleanup_packaging_root EXIT$/p' "${PACKAGE_ALL_SH}")"
if [[ -n "${trap_block}" ]]; then
    trap_probe="$(mktemp -d)"
    trap_out="$(bash -c "trap 'echo previous-trap-ran' EXIT
${trap_block}
echo \"\${PACKAGING_ROOT}\" > '${trap_probe}/root'" 2>&1)" || true
    trap_root="$(cat "${trap_probe}/root" 2> /dev/null || true)"
    if [[ "${trap_out}" == *previous-trap-ran* ]]; then
        pass "package_all.sh chains onto an existing EXIT trap"
    else
        fail "package_all.sh replaced the existing EXIT trap (output: ${trap_out})"
    fi
    if [[ -n "${trap_root}" && ! -e "${trap_root}" ]]; then
        pass "package_all.sh removes its private packaging copy on exit"
    else
        fail "package_all.sh left its private packaging copy behind: ${trap_root}"
    fi
    rm -rf "${trap_probe}"
else
    fail "package_all.sh EXIT trap block not found"
fi

echo ""
echo "========================================"
echo "Test: strip_staged_binaries / verify_binaries_stripped"
echo "========================================"
echo ""

for fn in _elf_is_strippable _elf_has_symbols strip_staged_binaries verify_binaries_stripped copy_staging_tree; do
    if ! grep -q "^${fn}()" "${FUNCTIONS_SH}"; then
        echo "FATAL: ${fn}() not found in ${FUNCTIONS_SH}"
        exit 1
    fi
    eval "$(sed -n "/^${fn}()/,/^}/p" "${FUNCTIONS_SH}")"
done

missing=""
for tool in cc strip readelf ar; do
    command -v "${tool}" > /dev/null 2>&1 || missing+=" ${tool}"
done
if [[ -n "${missing}" ]]; then
    echo "  SKIP: ELF fixture checks need${missing}"
    require_integration_deps "${missing# }"
    summary
fi

WORK="$(mktemp -d)"
# Test 7 makes directories read-only; restore write before removing.
trap 'chmod -R u+w "${WORK}" 2> /dev/null; rm -rf "${WORK}"' EXIT
SRC="${WORK}/src"
TREE="${WORK}/tree"
mkdir -p "${SRC}" "${TREE}/usr/bin" "${TREE}/usr/lib/x" "${TREE}/usr/share/man/man1"

cat > "${SRC}/hello.c" << 'EOF'
#include <stdio.h>
static int helper(int x) { return x * 2; }
int main(void) { printf("hello %d\n", helper(21)); return 0; }
EOF
cat > "${SRC}/lib.c" << 'EOF'
int libfn(int x) { return x + 1; }
EOF

cc -g -O0 -o "${TREE}/usr/bin/hello" "${SRC}/hello.c"
cc -g -O0 -shared -fPIC -Wl,-soname,libfoo.so.1 -o "${TREE}/usr/lib/x/libfoo.so.1" "${SRC}/lib.c"
# An executable that loads the fixture .so (DT_NEEDED libfoo.so.1).
cat > "${SRC}/usefoo.c" << 'EOF'
#include <stdio.h>
int libfn(int x);
int main(void) { printf("libfn %d\n", libfn(41)); return 0; }
EOF
cc -g -O0 -o "${TREE}/usr/bin/usefoo" "${SRC}/usefoo.c" "${TREE}/usr/lib/x/libfoo.so.1"
cc -g -O0 -c -o "${TREE}/usr/lib/x/obj.o" "${SRC}/lib.c"
ar rcs "${TREE}/usr/lib/x/libfoo.a" "${TREE}/usr/lib/x/obj.o"
printf '#!/bin/sh\necho script\n' > "${TREE}/usr/bin/script.sh"
chmod +x "${TREE}/usr/bin/script.sh"
printf '.TH HELLO 1\n' > "${TREE}/usr/share/man/man1/hello.1"
ln -s hello "${TREE}/usr/bin/hello-link"
# Symlink to an unstripped ELF outside the tree: must not be followed.
cp "${TREE}/usr/bin/hello" "${WORK}/outside-hello"
ln -s "${WORK}/outside-hello" "${TREE}/usr/bin/outside-link"

has_symbols() {
    local lrc=0
    _elf_has_symbols "$1" || lrc=$?
    [[ "${lrc}" -eq 0 ]]
}

assert_true "fixture executable starts with debug info" has_symbols "${TREE}/usr/bin/hello"
assert_true "fixture shared object starts with debug info" has_symbols "${TREE}/usr/lib/x/libfoo.so.1"

# dynamic_entries <file> -> its NEEDED and SONAME entries from `readelf -d`.
dynamic_entries() {
    local lout
    lout="$(LC_ALL=C readelf -d "$1")"
    grep -E '\((NEEDED|SONAME)\)' <<< "${lout}" | sed 's/^ *0x[0-9a-f]* *//'
}
dyn_usefoo_before="$(dynamic_entries "${TREE}/usr/bin/usefoo")"
dyn_libfoo_before="$(dynamic_entries "${TREE}/usr/lib/x/libfoo.so.1")"
assert_true "fixture executable records NEEDED libfoo.so.1" grep -q 'Shared library: \[libfoo.so.1\]' <<< "${dyn_usefoo_before}"
assert_true "fixture shared object records SONAME libfoo.so.1" grep -q 'Library soname: \[libfoo.so.1\]' <<< "${dyn_libfoo_before}"

echo ""
echo "Test 1: verify fails on an unstripped tree and names the file"
verify_out="$( (verify_binaries_stripped "${TREE}") 2>&1)" && verify_rc=0 || verify_rc=$?
assert_true "verify exits non-zero before strip" test "${verify_rc}" -ne 0
assert_true "verify names usr/bin/hello" grep -q "usr/bin/hello\$" <<< "${verify_out}"
assert_true "verify names libfoo.so.1" grep -q "libfoo.so.1\$" <<< "${verify_out}"
assert_false "verify does not flag the .o" grep -q "obj.o" <<< "${verify_out}"

echo ""
echo "Test 2: strip_staged_binaries strips EXEC/DYN and leaves the rest alone"
sum_of() { sha256sum "$1" | cut -d' ' -f1; }
sum_script="$(sum_of "${TREE}/usr/bin/script.sh")"
sum_man="$(sum_of "${TREE}/usr/share/man/man1/hello.1")"
sum_obj="$(sum_of "${TREE}/usr/lib/x/obj.o")"
sum_ar="$(sum_of "${TREE}/usr/lib/x/libfoo.a")"
sum_outside="$(sum_of "${WORK}/outside-hello")"

assert_true "strip_staged_binaries succeeds" strip_staged_binaries "${TREE}"
assert_false "executable has no .symtab/.debug_* after strip" has_symbols "${TREE}/usr/bin/hello"
assert_false "shared object has no .symtab/.debug_* after strip" has_symbols "${TREE}/usr/lib/x/libfoo.so.1"
assert_true "stripped executable still runs" bash -c "[[ \"\$('${TREE}/usr/bin/hello')\" == 'hello 42' ]]"
assert_true "stripped executable loads the stripped shared object" bash -c "[[ \"\$(LD_LIBRARY_PATH='${TREE}/usr/lib/x' '${TREE}/usr/bin/usefoo')\" == 'libfn 42' ]]"
assert_true "executable NEEDED entries unchanged by strip" test "$(dynamic_entries "${TREE}/usr/bin/usefoo")" == "${dyn_usefoo_before}"
assert_true "shared object NEEDED/SONAME entries unchanged by strip" test "$(dynamic_entries "${TREE}/usr/lib/x/libfoo.so.1")" == "${dyn_libfoo_before}"
assert_false "stripped usefoo has no .symtab/.debug_*" has_symbols "${TREE}/usr/bin/usefoo"
assert_true "script untouched" test "$(sum_of "${TREE}/usr/bin/script.sh")" == "${sum_script}"
assert_true "man page untouched" test "$(sum_of "${TREE}/usr/share/man/man1/hello.1")" == "${sum_man}"
assert_true "relocatable .o untouched" test "$(sum_of "${TREE}/usr/lib/x/obj.o")" == "${sum_obj}"
assert_true ".o still carries debug info" has_symbols "${TREE}/usr/lib/x/obj.o"
assert_true "ar archive untouched" test "$(sum_of "${TREE}/usr/lib/x/libfoo.a")" == "${sum_ar}"
assert_true "in-tree symlink still a symlink" test -L "${TREE}/usr/bin/hello-link"
assert_true "in-tree symlink target unchanged" test "$(readlink "${TREE}/usr/bin/hello-link")" == "hello"
assert_true "out-of-tree symlink target not followed" test "$(sum_of "${WORK}/outside-hello")" == "${sum_outside}"

echo ""
echo "Test 3: verify passes after strip; strip is idempotent"
assert_true "verify_binaries_stripped passes" verify_binaries_stripped "${TREE}"
sum_hello="$(sum_of "${TREE}/usr/bin/hello")"
assert_true "second strip pass succeeds" strip_staged_binaries "${TREE}"
assert_true "second pass leaves stripped executable byte-identical" test "$(sum_of "${TREE}/usr/bin/hello")" == "${sum_hello}"

echo ""
echo "Test 4: residual unstripped ELF fails verify, naming the file"
cc -g -O0 -o "${TREE}/usr/bin/late" "${SRC}/hello.c"
verify_out="$( (verify_binaries_stripped "${TREE}") 2>&1)" && verify_rc=0 || verify_rc=$?
assert_true "verify exits non-zero" test "${verify_rc}" -ne 0
assert_true "verify names usr/bin/late" grep -q "usr/bin/late\$" <<< "${verify_out}"
assert_false "verify does not name the stripped hello" grep -q "usr/bin/hello\$" <<< "${verify_out}"
rm -f "${TREE}/usr/bin/late"

echo ""
echo "Test 5: strip failure aborts"
fake_bin="${WORK}/fakebin"
mkdir -p "${fake_bin}"
printf '#!/bin/sh\nexit 1\n' > "${fake_bin}/strip"
chmod +x "${fake_bin}/strip"
cc -g -O0 -o "${TREE}/usr/bin/late" "${SRC}/hello.c"
assert_false "strip_staged_binaries returns non-zero when strip fails" \
    env PATH="${fake_bin}:${PATH}" bash -c "$(declare -f _elf_is_strippable _elf_has_symbols strip_staged_binaries); strip_staged_binaries '${TREE}'"
rm -f "${TREE}/usr/bin/late"

echo ""
echo "Test 6: empty tree and tree without ELF files are a no-op"
mkdir -p "${WORK}/empty" "${WORK}/noelf/etc"
printf 'key=value\n' > "${WORK}/noelf/etc/conf"
assert_true "strip on empty tree succeeds" strip_staged_binaries "${WORK}/empty"
assert_true "verify on empty tree succeeds" verify_binaries_stripped "${WORK}/empty"
assert_true "strip on non-ELF tree succeeds" strip_staged_binaries "${WORK}/noelf"
assert_true "verify on non-ELF tree succeeds" verify_binaries_stripped "${WORK}/noelf"
assert_false "strip on missing dir fails" strip_staged_binaries "${WORK}/does-not-exist"
assert_false "verify on missing dir fails" verify_binaries_stripped "${WORK}/does-not-exist"

echo ""
echo "Test 7: read-only staging tree is stripped through a private copy"
# setup.sh runs as root, so DESTDIR may be root-owned, while packaging may
# run package_all.sh as the runner user. Read-only directories reproduce that
# for a non-root test run: strip cannot create its temporary file.
RO="${WORK}/ro-tree"
mkdir -p "${RO}/usr/bin" "${RO}/etc/x"
cc -g -O0 -o "${RO}/usr/bin/hello" "${SRC}/hello.c"
cc -g -O0 -o "${RO}/usr/bin/ro-hello" "${SRC}/hello.c"
chmod 0555 "${RO}/usr/bin/ro-hello"
printf 'key=value\n' > "${RO}/etc/x/conf"
chmod 0640 "${RO}/etc/x/conf"
ln -s hello "${RO}/usr/bin/hello-link"
sum_ro_hello="$(sum_of "${RO}/usr/bin/hello")"
sum_ro_ro_hello="$(sum_of "${RO}/usr/bin/ro-hello")"
mode_ro_hello="$(stat -c %a "${RO}/usr/bin/hello")"
find "${RO}" -type d -exec chmod 0555 {} +
if [[ "${EUID}" -ne 0 ]]; then
    assert_false "strip in place fails on the read-only tree (the CI failure)" \
        bash -c "$(declare -f _elf_is_strippable _elf_has_symbols strip_staged_binaries); strip_staged_binaries '${RO}'"
else
    echo "  (running as root: read-only directories do not block root, in-place failure not reproducible)"
fi
COPY="${WORK}/pkg/destdir"
assert_true "copy_staging_tree succeeds from the read-only tree" copy_staging_tree "${RO}" "${COPY}"
assert_true "strip_staged_binaries succeeds on the copy" strip_staged_binaries "${COPY}"
assert_true "verify_binaries_stripped passes on the copy" verify_binaries_stripped "${COPY}"
assert_false "0755 binary in the copy is stripped" has_symbols "${COPY}/usr/bin/hello"
assert_false "0555 binary in the copy is stripped" has_symbols "${COPY}/usr/bin/ro-hello"
assert_true "stripped copy still runs" bash -c "[[ \"\$('${COPY}/usr/bin/ro-hello')\" == 'hello 42' ]]"
assert_true "copy keeps the staged file mode" test "$(stat -c %a "${COPY}/usr/bin/hello")" == "${mode_ro_hello}"
assert_true "copy keeps 0555 file mode after strip" test "$(stat -c %a "${COPY}/usr/bin/ro-hello")" == "555"
assert_true "copy keeps 0640 file mode" test "$(stat -c %a "${COPY}/etc/x/conf")" == "640"
assert_true "copy keeps the symlink" test -L "${COPY}/usr/bin/hello-link"
assert_true "copy keeps the symlink target" test "$(readlink "${COPY}/usr/bin/hello-link")" == "hello"
assert_true "copied directories are owner-writable" test -z "$(find "${COPY}" -type d ! -perm -u=w)"
assert_true "source tree binary untouched" test "$(sum_of "${RO}/usr/bin/hello")" == "${sum_ro_hello}"
assert_true "source tree 0555 binary untouched" test "$(sum_of "${RO}/usr/bin/ro-hello")" == "${sum_ro_ro_hello}"
assert_true "source tree still unstripped" has_symbols "${RO}/usr/bin/hello"
assert_true "source directories still read-only" test "$(stat -c %a "${RO}/usr/bin")" == "555"
assert_false "copy_staging_tree on missing source fails" copy_staging_tree "${WORK}/does-not-exist" "${WORK}/pkg2"

summary
