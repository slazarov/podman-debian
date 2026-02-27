# Stack Research

**Domain:** Podman compilation from source on Debian/Ubuntu
**Researched:** 2025-02-28
**Confidence:** HIGH (verified with official Podman documentation and go.mod)

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **Go** | 1.24.x (or 1.23.x minimum) | Primary build compiler | Podman 6.x (main branch) requires Go 1.24.6 per official go.mod. Go 1.23.x is the minimum acceptable for Podman 5.x builds. Download from go.dev/dl. |
| **gcc** | System default | C compiler for native deps | Required for building conmon, crun, and linking against C libraries (libseccomp, libgpgme, etc.) |
| **make** | System default | Build orchestration | Podman uses Makefile-based build system with BUILDTAGS for feature selection |
| **git** | 2.x | Source code management | Required for cloning repositories and checking out specific release tags |

### Build Dependencies (apt packages)

| Package | Purpose | Architecture Notes |
|---------|---------|-------------------|
| **libseccomp-dev** | Syscall filtering (seccomp build tag) | Same on amd64 and arm64 |
| **libgpgme-dev** | GPG signature verification for images | Same on amd64 and arm64 |
| **libassuan-dev** | GPG communication library | Same on amd64 and arm64 |
| **libbtrfs-dev** | Btrfs storage driver support | Same on amd64 and arm64 |
| **libdevmapper-dev** | Device mapper storage support | Same on amd64 and arm64 |
| **libglib2.0-dev** | GLib development headers | Same on amd64 and arm64 |
| **libsystemd-dev** | systemd/journald integration | Same on amd64 and arm64 |
| **libselinux1-dev** | SELinux labeling support | Same on amd64 and arm64 |
| **libprotobuf-dev** | Protocol buffers for gRPC | Same on amd64 and arm64 |
| **libprotobuf-c-dev** | C bindings for protobuf | Same on amd64 and arm64 |
| **pkg-config** | Library detection for C deps | Same on amd64 and arm64 |
| **iptables** | Container networking rules | Same on amd64 and arm64 |
| **uidmap** | User namespace mapping for rootless | Critical for rootless containers |

### Runtime Dependencies (built from source)

| Component | Recommended Version | Purpose | Why Build From Source |
|-----------|--------------------|---------|-----------------------|
| **conmon** | 2.1.13+ | Container monitor process | Debian packages often outdated; needs latest for Podman 5.x/6.x compatibility |
| **crun** | 1.25.x (minimum 1.14.3) | OCI runtime (preferred) | Faster and lighter than runc; official Podman recommendation |
| **netavark** | 1.15.x+ | Network backend | Replaces CNI; required for Podman 4.0+ |
| **aardvark-dns** | 1.15.x+ | DNS resolution for containers | Companion to netavark |
| **passt/pasta** | 2024.01+ | Rootless networking | Replaces slirp4netns; better performance and source IP preservation |

### Supporting Libraries (Go-based, built via make)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| **buildah** | 1.42.x | Image building | Optional; if users need to build images |
| **skopeo** | 1.19.x | Image transport/inspection | Optional; useful for image operations |
| **go-md2man** | 2.0.7 | Man page generation | For generating documentation |

## Installation

```bash
# === Core Build Dependencies ===
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git \
  gcc \
  make \
  pkg-config \
  libseccomp-dev \
  libgpgme-dev \
  libassuan-dev \
  libbtrfs-dev \
  libdevmapper-dev \
  libglib2.0-dev \
  libsystemd-dev \
  libselinux1-dev \
  libprotobuf-dev \
  libprotobuf-c-dev \
  libc6-dev \
  libgpg-error-dev \
  libapparmor-dev \
  libcap-dev \
  libyajl-dev \
  iptables \
  uidmap \
  autoconf \
  automake \
  libtool \
  python3 \
  meson \
  cmake

# === Go Installation (Architecture-Aware) ===
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GOARCH="amd64" ;;
  aarch64) GOARCH="arm64" ;;
  *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

GOVERSION="1.24.4"
wget "https://go.dev/dl/go${GOVERSION}.linux-${GOARCH}.tar.gz"
sudo mkdir -p "/opt/go/${GOVERSION}"
sudo tar xzf "go${GOVERSION}.linux-${GOARCH}.tar.gz" -C "/opt/go/${GOVERSION}" --strip-components=1
export PATH="/opt/go/${GOVERSION}/bin:$PATH"

# === Build Podman ===
git clone https://github.com/containers/podman.git
cd podman
# Checkout latest stable release
git checkout v5.5.2  # or latest
make BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr
sudo make install PREFIX=/usr
```

## Architecture Differences: amd64 vs arm64

| Aspect | amd64 | arm64 |
|--------|-------|-------|
| **Go Download** | go1.24.x.linux-amd64.tar.gz | go1.24.x.linux-arm64.tar.gz |
| **Build Dependencies** | Identical | Identical |
| **Build Commands** | Identical | Identical |
| **Performance** | Generally faster compilation | May take longer to compile |
| **Protoc** | protoc-33.1-linux-x86_64.zip | protoc-33.1-linux-aarch64.zip |
| **Rust (for crun)** | rustup default host: x86_64 | rustup default host: aarch64 |

**Key Insight:** Podman compilation is architecture-agnostic in terms of dependencies and build process. The only difference is the binary downloads (Go, protoc, Rust toolchain). Both architectures use the same apt packages and Makefile commands.

## Build Tags

| Build Tag | Feature | Dependency | Recommended |
|-----------|---------|------------|-------------|
| **seccomp** | Syscall filtering | libseccomp | Yes (security) |
| **apparmor** | AppArmor profiles | libapparmor | Yes (Debian/Ubuntu) |
| **systemd** | journald logging | libsystemd | Yes (systemd systems) |
| **selinux** | SELinux labeling | libselinux | No (not default on Debian) |
| **exclude_graphdriver_btrfs** | Disable btrfs | - | Only if no btrfs |
| **exclude_graphdriver_devicemapper** | Disable dm | - | Mandatory (not officially supported) |

**Recommended BUILDTAGS for Debian/Ubuntu:**
```bash
make BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| **crun** | runc | Use runc only if crun has compatibility issues; runc minimum v1.1.11 |
| **passt/pasta** | slirp4netns | Use slirp4netns on older systems where passt unavailable |
| **netavark** | containernetworking-plugins | Use CNI on older Debian/Ubuntu where netavark not packaged |
| **Go 1.24.x** | System golang-go | Use system Go only if version >= 1.23.x; otherwise download binary |
| **Build from source** | apt install podman | Use apt only if distro version is recent enough (Debian 12+, Ubuntu 22.04+) |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| **System golang-go on Debian 11** | Too old (1.18); Podman 5.x+ requires Go 1.21+ | Download Go binary from go.dev/dl |
| **runc < 1.1.11** | Missing features Podman depends on | Build runc from source or update package |
| **crun < 1.14.3** | Missing features Podman depends on | Build crun from source |
| **slirp4netns for new installs** | Deprecated in favor of passt; performance issues | Install passt/pasta |
| **CNI networking** | Deprecated; removed in Podman 5.0 | Use netavark |
| **device-mapper storage driver** | Not officially supported by Podman | Use overlay (default) |
| **Hardcoded amd64** | Breaks on ARM systems | Use `uname -m` detection |

## Version Compatibility Matrix

| Podman Version | Min Go Version | Recommended Go |
|----------------|----------------|----------------|
| 5.0.x - 5.4.x | Go 1.20+ | Go 1.22.x |
| 5.5.x - 5.6.x | Go 1.21+ | Go 1.23.x |
| 6.x (main) | Go 1.24.6 | Go 1.24.x |

| Runtime | Minimum Version | Notes |
|---------|-----------------|-------|
| runc | 1.1.11 | OCI runtime |
| crun | 1.14.3 | Preferred runtime |
| conmon | 2.1.12+ | Container monitor |

## Non-Interactive Installation Pattern

For unattended installation (critical requirement from project):

```bash
# Set noninteractive mode globally
export DEBIAN_FRONTEND=noninteractive

# Use -y flag on all apt commands
sudo apt-get install -y <packages>

# Disable prompts for config file updates
sudo apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -y <packages>
```

## Sources

- [Podman Official Installation Documentation](https://podman.io/docs/installation) - HIGH confidence - Official docs with Debian/Ubuntu build dependencies
- [Podman GitHub go.mod](https://raw.githubusercontent.com/containers/podman/main/go.mod) - HIGH confidence - Verified Go 1.24.6 requirement for Podman 6.x
- [Podman GitHub README](https://github.com/containers/podman) - HIGH confidence - Official repository with build instructions
- [Go Official Downloads](https://go.dev/dl/) - HIGH confidence - Official Go binary downloads for both architectures
- [containers/conmon GitHub](https://github.com/containers/conmon) - HIGH confidence - Conmon source repository
- [containers/crun GitHub](https://github.com/containers/crun) - HIGH confidence - Crun OCI runtime repository
- [containers/netavark GitHub](https://github.com/containers/netavark) - HIGH confidence - Netavark network backend

---
*Stack research for: Podman compilation on Debian/Ubuntu (amd64 and arm64)*
*Researched: 2025-02-28*
