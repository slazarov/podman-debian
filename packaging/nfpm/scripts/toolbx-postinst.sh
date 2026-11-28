#!/bin/sh
# postinst for podman-toolbx.
#
# Upstream links /usr/bin/toolbox with the dynamic loader at
# /run/host/usr/lib/.../ld-linux-*.so, so the same binary also runs inside
# toolbox containers, where the host's root is mounted at /run/host. On the
# host, /usr/lib/tmpfiles.d/toolbox.conf (shipped in this package) links
# /run/host to /. systemd-tmpfiles applies it at every boot; this applies it
# right after installation, so toolbox works without a reboot. This is what
# debhelper's dh_installtmpfiles generates for Debian's own podman-toolbox.
set -e

case "$1" in
    configure | abort-upgrade | abort-deconfigure | abort-remove)
        if command -v systemd-tmpfiles > /dev/null 2>&1; then
            systemd-tmpfiles ${DPKG_ROOT:+--root="$DPKG_ROOT"} --create toolbox.conf || true
        fi
        ;;
esac

exit 0
