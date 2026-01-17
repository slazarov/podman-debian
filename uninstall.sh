#!/bin/bash

# Abort on Error
# set -e

# Determine toolpath if not set already
relativepath="./" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Uninstall AardvarkDNS
cd "${BUILD_ROOT}/aardvark-dns/"
make uninstall

# Uninstall Buildah
cd "${BUILD_ROOT}/buildah/"
make uninstall

# Uninstall Catatonit
cd "${BUILD_ROOT}/catatonit/"
make uninstall

# Uninstall CRUN
cd "${BUILD_ROOT}/crun/"
make uninstall

# Uninstall Fuse-OverlayFS
cd "${BUILD_ROOT}/fuse-overlayfs/"
make uninstall
make uninstall-am
make uninstall-man1
make uninstall-man

# Uninstall Netavark
cd "${BUILD_ROOT}/netavark/"
make uninstall

# Uninstall Pasta
cd "${BUILD_ROOT}/passt/"
make uninstall

# Uninstall Podman
cd "${BUILD_ROOT}/podman/"
make uninstall

# Uninstall slirp4netns
cd "${BUILD_ROOT}/slirp4netns/"
make uninstall
make uninstall-am
# make uninstall-bin
make uninstall-man
make uninstall-man1

# Uninstall RUNC
cd "${BUILD_ROOT}/runc/"
make uninstall

# Perform the remaining of the Uninstall manually
rm -f /usr/share/man/man1/podman*
rm -f /usr/share/man/man5/quadlet.5
rm -f /usr/share/man/man5/podman-systemd.unit.5
rm -f /usr/share/man/man7/podman-rootless.7
rm -f /usr/share/man/man7/podman-troubleshooting.7
rm -rf /var/lib/cni
rm -rf /usr/local/usr/local/share/toolbox
rm -rf /usr/local/usr/local/share/zsh/site-functions/_toolbox
rmdir --ignore-fail-on-non-empty /usr/local/usr/local/share/zsh/site-functions
rmdir --ignore-fail-on-non-empty /usr/local/usr/local/share/zsh
rm -f /usr/local/share/man/man1/buildah*
rm -f /usr/local/share/man/man1/crun*
rm -f /usr/local/share/man/man1/fuse-overlayfs*
rm -f /usr/local/share/man/man1/slirp4netns*
rm -f /usr/local/bin/runc

rm -f /usr/local/usr/lib/tmpfiles.d/toolbox.conf
rmdir --ignore-fail-on-non-empty /usr/local/usr/lib/tmpfiles.d
rm -f /usr/local/usr/local/etc/containers/toolbox.conf
rmdir --ignore-fail-on-non-empty /usr/local/usr/local/etc/containers
rmdir --ignore-fail-on-non-empty /usr/local/usr/local/etc

rm -f /usr/local/usr/local/bin/toolbox
rmdir --ignore-fail-on-non-empty /usr/local/usr/local/bin

rm -f /usr/libexec/podman/quadlet
rm -f /usr/libexec/podman/rootlessport
rm -rf /usr/libexec/podman

rm -f /usr/local/bin/aardvark-dns
rm -f /usr/local/bin/buildah
rm -f /usr/local/bin/catatonit
rm -f /usr/local/bin/crun
rm -f /usr/local/bin/fuse-overlayfs
rm -f /usr/local/bin/go
rm -f /usr/local/bin/go-md2man
rm -f /usr/local/bin/netavark
rm -f /usr/local/bin/netavark-dhcp-proxy-client
rm -f /usr/local/bin/passt
rm -f /usr/local/bin/passt.avx2
rm -f /usr/local/bin/pasta
rm -f /usr/local/bin/pasta.avx2
rm -f /usr/local/bin/protoc
rm -f /usr/local/bin/runc

rm -rf /opt/go/*

rm -rf /etc/cni

rm -rf /etc/containers
