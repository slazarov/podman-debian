#!/bin/bash

# Abort on Error
set -euo pipefail

# smoke_repo_install.sh - apt-install the `podman-suite` meta-package by name
# from the assembled on-disk APT repo (a file:// source) inside a clean Debian
# container and use it the way users do: fresh install plus rootless bridge
# networking, migration from Debian's own podman, and upgrade from the live
# repo (see section 6). CI runs it before the GitHub Pages publish.
#
# The assembled repo-output (the signed tree produced by ci_publish.sh) is
# bind-mounted read-only into a throwaway container. A DEB822 source pointing
# at file:///opt/podman-repo with `Trusted: yes` lets apt resolve and install
# `podman-suite` by name. `podman info` must exit 0: a package that installs
# but whose runtime cannot introspect itself is still a regression.
#
# It shells out to a container runtime (docker or podman), so it runs the same
# in CI (the publish job calls it once per distro) and on any machine with a
# runtime. There is no silent skip: if no runtime or no assembled repo is
# present, the script fails.
#
# Usage: smoke_repo_install.sh <distro-label> [repo-dir]
#   distro-label   one of VALID_DISTROS in config.sh (bookworm, trixie)
#   repo-dir       path to the assembled repo (default: ${toolpath}/repo-output)
#
# Overrides:
#   SMOKE_RUNTIME=docker|podman   force the container runtime (validated)
#   SMOKE_IMAGE=<image[:tag]>      force the base image (default: the
#                                  distro's entry in DISTRO_IMAGES)
#   TRACK=<track>                 suite track (default: nightly);
#                                 SUITE = "${TRACK}-<label>"
#   LIVE_REPO_URL=https://...     published repo to upgrade from; unset skips
#                                 the upgrade scenario
#
# Security: the distro label, TRACK, SMOKE_RUNTIME and SMOKE_IMAGE end up in a
# container-run command or a suite name. All are checked against closed lists
# (VALID_DISTROS, VALID_TRACKS, {docker,podman}) or a strict pattern before
# use. `Trusted: yes` is intentional and confined to this CI-internal file://
# source. It does not exercise the GPG Signed-By path real users hit (the
# upgrade scenario does), and it must never appear in user-facing docs or
# index.html.

# ---------------------------------------------------------------------------
# Locate repo root and load the distro table from config.sh without running
# the rest of config.sh, so the helper runs in a minimal CI runner.
# ---------------------------------------------------------------------------
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}" 2>/dev/null \
        || (cd "${scriptpath}/${relativepath}" && pwd))
fi
eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${toolpath}/config.sh")"

echo ""
echo "========================================"
echo ">>> smoke_repo_install.sh: file:// install + podman info proof"
echo "========================================"

# ---------------------------------------------------------------------------
# 1. Validate the distro label and TRACK. Both go into the suite name, and the
#    label selects the image, so anything outside the known sets is rejected.
# ---------------------------------------------------------------------------
LABEL="${1:-}"
# Exact match against the list. The label is not used as an array subscript
# until it has passed this check.
label_ok=false
for valid_distro in "${VALID_DISTROS[@]}"; do
    [[ "${LABEL}" == "${valid_distro}" ]] && label_ok=true
done
if [[ "${label_ok}" != "true" ]]; then
    echo "ERROR: distro-label must be one of: ${VALID_DISTROS[*]} (got '${LABEL}')." >&2
    echo "  Usage: smoke_repo_install.sh <distro-label> [repo-dir]" >&2
    exit 1
fi

TRACK="${TRACK:-nightly}"
track_ok=false
for valid_track in "${VALID_TRACKS[@]}"; do
    [[ "${TRACK}" == "${valid_track}" ]] && track_ok=true
done
if [[ "${track_ok}" != "true" ]]; then
    echo "ERROR: TRACK must be one of: ${VALID_TRACKS[*]} (got '${TRACK}')." >&2
    exit 1
fi
SUITE="${TRACK}-${LABEL}"
echo "Distro label: ${LABEL}"
echo "Suite:        ${SUITE}"

# ---------------------------------------------------------------------------
# 2. Select and validate the container runtime. The value is used as a
#    command, so anything other than docker or podman is rejected. Without an
#    override, prefer docker, else podman.
# ---------------------------------------------------------------------------
RUNTIME=""
if [[ -n "${SMOKE_RUNTIME:-}" ]]; then
    case "${SMOKE_RUNTIME}" in
        docker|podman)
            if ! command -v "${SMOKE_RUNTIME}" &>/dev/null; then
                echo "ERROR: SMOKE_RUNTIME='${SMOKE_RUNTIME}' requested but '${SMOKE_RUNTIME}' is not on PATH." >&2
                exit 1
            fi
            RUNTIME="${SMOKE_RUNTIME}"
            ;;
        *)
            echo "ERROR: SMOKE_RUNTIME must be exactly 'docker' or 'podman' (got '${SMOKE_RUNTIME}')." >&2
            exit 1
            ;;
    esac
elif command -v docker &>/dev/null; then
    RUNTIME="docker"
elif command -v podman &>/dev/null; then
    RUNTIME="podman"
else
    echo "ERROR: no container runtime found. Install docker or podman." >&2
    exit 1
fi
echo "Container runtime: ${RUNTIME}"

# ---------------------------------------------------------------------------
# 3. Select the base image from DISTRO_IMAGES (amd64 only, like the builds).
#    An explicit SMOKE_IMAGE override wins and is checked against a
#    conservative image-name pattern.
# ---------------------------------------------------------------------------
IMAGE="${SMOKE_IMAGE:-${DISTRO_IMAGES[${LABEL}]}}"
if [[ ! "${IMAGE}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]]; then
    echo "ERROR: image '${IMAGE}' is not a valid image name." >&2
    exit 1
fi
echo ">>> Pulling image: ${IMAGE}"
if ! "${RUNTIME}" pull "${IMAGE}"; then
    echo "ERROR: could not pull ${IMAGE}." >&2
    exit 1
fi
echo "Base image: ${IMAGE}"

# ---------------------------------------------------------------------------
# 4. Resolve and validate the assembled repo directory. Arg $2 if given, else
#    ${toolpath}/repo-output. It must exist and carry a dists/ tree (the signed
#    suite indexes) — an empty or wrong dir is a hard failure, not a soft skip.
# ---------------------------------------------------------------------------
REPO_DIR="${2:-${toolpath}/repo-output}"
if [[ ! -d "${REPO_DIR}" ]]; then
    echo "ERROR: assembled repo directory not found: ${REPO_DIR}" >&2
    echo "  Assemble the repo first (ci_publish.sh ... repo-output)." >&2
    exit 1
fi
if [[ ! -d "${REPO_DIR}/dists" ]]; then
    echo "ERROR: ${REPO_DIR} contains no dists/ tree — not an assembled APT repo." >&2
    exit 1
fi
# Canonicalize so the bind-mount source is absolute regardless of CWD.
REPO_DIR=$(realpath "${REPO_DIR}")
echo "Assembled repo: ${REPO_DIR}"


# ---------------------------------------------------------------------------
# 5. Validate the optional live-repo URL. It is interpolated into
#    an apt source inside the container, so only a plain https URL is accepted.
#    Unset = the upgrade scenario is skipped.
# ---------------------------------------------------------------------------
LIVE_REPO_URL="${LIVE_REPO_URL:-}"
if [[ -n "${LIVE_REPO_URL}" && ! "${LIVE_REPO_URL}" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._-]+)*/?$ ]]; then
    echo "ERROR: LIVE_REPO_URL must be a plain https:// URL (got '${LIVE_REPO_URL}')." >&2
    exit 1
fi
LIVE_REPO_URL="${LIVE_REPO_URL%/}"

# ---------------------------------------------------------------------------
# 6. Scenario scripts. Each runs in its own throwaway container and covers
#    a path a real user takes (each one caught a shipped bug when added):
#      fresh    install podman-suite, podman info, then a ROOTLESS user with their
#               own ~/.config/containers/containers.conf runs a container on a
#               bridge network and resolves its own name via aardvark-dns
#               (missing uidmap; helpers outside helper_binaries_dir).
#      migrate  install Debian's own podman first, then podman-suite over it
#               (dpkg "trying to overwrite" from an incomplete Conflicts list).
#      upgrade  install from the LIVE published repo, then full-upgrade to the
#               assembled one (package renames, new Depends). Skipped when
#               LIVE_REPO_URL is unset or the suite is not published there yet.
#    Scripts are written to a temp dir and bind-mounted, avoiding nested-quoting
#    hazards. Trusted: yes is confined to the CI-internal file:// source.
# ---------------------------------------------------------------------------
SCENARIO_DIR=$(mktemp -d)
trap 'rm -rf "${SCENARIO_DIR}"' EXIT

cat > "${SCENARIO_DIR}/lib.sh" << 'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

add_local_repo() {
    cat > /etc/apt/sources.list.d/podman-smoke.sources << APTEOF
Types: deb
URIs: file:///opt/podman-repo
Suites: ${SUITE}
Components: main
Trusted: yes
APTEOF
}

# dpkg --audit prints any half-installed/unconfigured package; must be empty.
assert_dpkg_clean() {
    local laudit
    laudit=$(dpkg --audit)
    if [[ -n "${laudit}" ]]; then
        echo "${laudit}" >&2
        echo "FAIL: dpkg reports broken packages" >&2
        return 1
    fi
}

rootless_network_check() {
    useradd -m smoke
    grep -q '^smoke:' /etc/subuid || usermod --add-subuids 100000-165535 --add-subgids 100000-165535 smoke
    su - smoke -s /bin/bash << 'USEREOF'
set -euo pipefail
export XDG_RUNTIME_DIR="/tmp/xdg-$(id -u)"
mkdir -p -m 0700 "${XDG_RUNTIME_DIR}"
# A user containers.conf replaces /etc/containers/containers.conf entirely;
# nothing podman needs may depend on settings in the system file.
mkdir -p ~/.config/containers
printf '[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n' > ~/.config/containers/containers.conf
podman network create smokenet > /dev/null
podman run --rm --name smokectr --network smokenet quay.io/libpod/alpine:latest \
    nslookup smokectr
echo ">>> rootless bridge network + aardvark-dns OK"
USEREOF
}
EOF

cat > "${SCENARIO_DIR}/fresh.sh" << 'EOF'
source /smoke/lib.sh
add_local_repo
apt-get update -qq
# ca-certificates: present on almost every real Debian install, absent from the
# minimal image; the rootless check pulls from quay.io over TLS.
apt-get install -y -q ca-certificates podman-suite
assert_dpkg_clean
podman info --log-level=error > /dev/null
echo ">>> rootful podman info OK"
rootless_network_check
EOF

cat > "${SCENARIO_DIR}/migrate.sh" << 'EOF'
source /smoke/lib.sh
apt-get update -qq
apt-get install -y -q podman
echo ">>> distro podman installed: $(dpkg-query -W -f='${Version}' podman)"
add_local_repo
apt-get update -qq
apt-get install -y -q podman-suite
assert_dpkg_clean
podman info --log-level=error > /dev/null
echo ">>> migrated from distro podman OK"
EOF

cat > "${SCENARIO_DIR}/upgrade.sh" << 'EOF'
source /smoke/lib.sh
apt-get update -qq
apt-get install -y -q curl ca-certificates
# Probe before fetching the key: on the first deploy neither exists yet.
if ! curl -fsSI "${LIVE_REPO_URL}/dists/${SUITE}/InRelease" > /dev/null; then
    echo ">>> SKIP upgrade: ${SUITE} is not published at ${LIVE_REPO_URL} yet"
    exit 0
fi
mkdir -p /etc/apt/keyrings
curl -fsSL "${LIVE_REPO_URL}/podman-debian.gpg" -o /etc/apt/keyrings/podman-debian.gpg
cat > /etc/apt/sources.list.d/podman-live.sources << APTEOF
Types: deb
URIs: ${LIVE_REPO_URL}
Suites: ${SUITE}
Components: main
Signed-By: /etc/apt/keyrings/podman-debian.gpg
APTEOF
apt-get update -qq
apt-get install -y -q podman-suite
echo ">>> live podman-suite installed: $(dpkg-query -W -f='${Version}' podman-suite)"
add_local_repo
apt-get update -qq
apt-get full-upgrade -y -q
assert_dpkg_clean
echo ">>> upgraded podman-suite: $(dpkg-query -W -f='${Version}' podman-suite)"
podman info --log-level=error > /dev/null
echo ">>> upgrade from live repo OK"
EOF

# ---------------------------------------------------------------------------
# 7. Run each scenario. --privileged + --device /dev/fuse let podman initialize
#    storage and user namespaces. -v /home puts the rootless
#    user's storage on a real volume: overlay-on-overlay is refused, and the
#    container root is itself an overlay.
# ---------------------------------------------------------------------------
FAILED=()
for scenario in fresh migrate upgrade; do
    if [[ "${scenario}" == "upgrade" && -z "${LIVE_REPO_URL}" ]]; then
        echo ">>> SKIP scenario upgrade: LIVE_REPO_URL not set"
        continue
    fi
    echo ""
    echo ">>> Scenario ${scenario}: ${IMAGE} suite=${SUITE} via ${RUNTIME}"
    echo "----------------------------------------"
    if ! "${RUNTIME}" run --rm \
            --privileged \
            --device /dev/fuse \
            -v /home \
            -v "${REPO_DIR}:/opt/podman-repo:ro" \
            -v "${SCENARIO_DIR}:/smoke:ro" \
            -e SUITE="${SUITE}" \
            -e LIVE_REPO_URL="${LIVE_REPO_URL}" \
            "${IMAGE}" \
            bash "/smoke/${scenario}.sh"; then
        echo "SMOKE FAIL: scenario ${scenario} (${IMAGE}, suite ${SUITE})" >&2
        FAILED+=("${scenario}")
    fi
done

echo ""
echo "========================================"
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ">>> SMOKE FAIL: ${IMAGE} suite=${SUITE}, failed: ${FAILED[*]}"
    echo "========================================"
    exit 1
fi
echo ">>> SMOKE PASS: ${IMAGE} suite=${SUITE}"
echo "========================================"
exit 0
