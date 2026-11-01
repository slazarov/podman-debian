#!/bin/bash

# Abort on Error
set -euo pipefail

# verify_versions.sh - check the ordering of the per-distro version suffix
# with `dpkg --compare-versions`.
#
# Every version below is a literal fixture, so the script needs only `dpkg`
# (no config.sh, no nfpm, no build output). It runs on any host with dpkg,
# including in CI before any package is built.
#
# The suffix is ~deb{VERSION_ID}.podman{N} (see config.sh). These checks make
# sure that bookworm builds sort below trixie builds, nightly builds sort below
# tagged builds, and a packaging-revision bump upgrades existing installs.

# assert_lt <lower> <higher>
# Prints OK when <lower> sorts strictly below <higher> per dpkg version
# semantics; otherwise prints FAIL to stderr and exits 1.
assert_lt() {
  if dpkg --compare-versions "$1" lt "$2"; then
    echo "OK: $1 < $2"
  else
    echo "FAIL: expected $1 < $2" >&2
    exit 1
  fi
}

# 1. bookworm sorts below trixie, so a dist-upgrade from 12 to 13 moves to
#    the trixie build: after the shared `~deb` prefix, 12 < 13 numerically.
assert_lt "5.5.2~deb12.podman1" "5.5.2~deb13.podman1"
assert_lt "20250302~deb12.podman1" "20250302~deb13.podman1"

# 2. The comparison is numeric, not lexical, so a future two-digit release
#    still sorts above a one-digit one.
assert_lt "5.5.2~deb9.podman1" "5.5.2~deb12.podman1"

# 3. A newer upstream version wins regardless of the distro suffix.
assert_lt "5.5.2~deb13.podman1" "5.6.0~deb12.podman1"

# 4. Nightly form ({base}~~git{YYYYMMDD}.{sha}~deb{VERSION_ID}.podman1) sorts
#    below the tagged release for the same distro. `~~` sorts below `~d`, so
#    the nightly marker needs the double tilde: a single `~git` would sort
#    above `~deb` because `g` > `d`. The last check guards against that form
#    coming back.
assert_lt "5.9.0~~git20260306.abc1234~deb12.podman1" "5.9.0~deb12.podman1"
assert_lt "5.9.0~~git20260306.abc1234~deb13.podman1" "5.9.0~deb13.podman1"
assert_lt "20260306~~gitabc1234~deb12.podman1" "20260306~deb12.podman1"
assert_lt "5.9.0~deb12.podman1" "5.9.0~git20260306.abc1234~deb12.podman1"

# 5. A packaging-revision bump (scripts/package_revision.sh) upgrades installs
#    of the same upstream version.
assert_lt "6.1.3~deb12.podman1" "6.1.3~deb12.podman2"
assert_lt "6.1.3~deb12.podman9" "6.1.3~deb12.podman10"

# 6. Position relative to Debian's own package of the same upstream version.
#    The tilde sorts the suffix below the bare upstream version, and Debian's
#    own packages (e.g. 5.4.2+ds1-2 in trixie) sort above that. Our packages
#    use different names (podman-podman, podman-crun, ...) and switch over
#    through Conflicts/Replaces/Provides, so apt never compares the two
#    versions to pick one. This check pins the current behavior so a change
#    to the suffix form is a deliberate decision.
assert_lt "5.4.2~deb13.podman1" "5.4.2"
assert_lt "5.4.2~deb13.podman1" "5.4.2+ds1-2"

echo "All version ordering assertions passed"
exit 0
