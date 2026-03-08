# podman-ubuntu

Compile and install the latest Podman stack from source on Debian/Ubuntu, or install pre-built packages from the hosted APT repository.

| | |
|---|---|
| **License** | AGPL-3.0 |
| **Platform** | Ubuntu 24.04 (Noble Numbat) |
| **Architectures** | amd64 (x86_64), arm64 (aarch64) |

Forked from [luckylinux/podman-ubuntu](https://github.com/luckylinux/podman-ubuntu) with significant additions: arm64 support, fully non-interactive builds, hosted APT repository, CI/CD pipelines, 12 packaged components, build caching, and three release tracks (stable, edge, nightly).

---

## Install via APT (Recommended)

Add the repository and install the full Podman stack in 4 commands:

```bash
# Download the GPG signing key
sudo mkdir -p /etc/apt/keyrings
sudo wget -qO /etc/apt/keyrings/podman-ubuntu.gpg \
  https://slazarov.github.io/podman-ubuntu/podman-ubuntu.gpg

# Add the repository (DEB822 format)
sudo tee /etc/apt/sources.list.d/podman-ubuntu.sources << 'EOF'
Types: deb
URIs: https://slazarov.github.io/podman-ubuntu
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/podman-ubuntu.gpg
EOF

# Update and install
sudo apt update
sudo apt install -y podman-suite
```

The `podman-suite` meta-package installs all 12 components listed below.

### Release Tracks

Three suites are available, each serving a different use case:

| Suite | Description | Update Frequency |
|-------|-------------|------------------|
| **stable** | Pinned, tested release versions | Manual promotion |
| **edge** | Latest upstream release tags | On new upstream release |
| **nightly** | HEAD commits from upstream repos | Daily at 4:30 AM UTC |

Use **stable** for production systems. Use **edge** for the newest released features. Use **nightly** for bleeding-edge development.

### Switching Suites

To switch from one suite to another, change the `Suites:` line in your sources file:

```bash
# Example: switch from stable to edge
sudo sed -i 's/^Suites: .*/Suites: edge/' /etc/apt/sources.list.d/podman-ubuntu.sources
sudo apt update
sudo apt upgrade
```

For full details, troubleshooting, and individual package installation, see [docs/apt-repository.md](docs/apt-repository.md).

---

## Individual Packages

All packages use the `podman-*` prefix. They declare `Conflicts` and `Replaces` against official Ubuntu packages so the newer compiled-from-source versions take priority.

| Package | Description |
|---------|-------------|
| `podman-podman` | Container engine (core) |
| `podman-crun` | OCI runtime |
| `podman-conmon` | Container monitor |
| `podman-netavark` | Container networking |
| `podman-aardvark-dns` | DNS for container networks |
| `podman-pasta` | User-mode networking (passt) |
| `podman-fuse-overlayfs` | Rootless overlay filesystem |
| `podman-catatonit` | Minimal init for containers |
| `podman-buildah` | OCI image builder |
| `podman-skopeo` | Container image utility |
| `podman-toolbox` | Containerized development environments |
| `podman-container-configs` | Configuration files for /etc/containers/ |

Install only the core runtime (pulls required dependencies automatically):

```bash
sudo apt install podman-podman
```

---

## Build from Source

For users who prefer to compile everything locally rather than using the APT repository.

### Prerequisites

- Debian or Ubuntu system (tested on Ubuntu 24.04)
- Root or sudo access
- Internet access

### Build Steps

```bash
git clone https://github.com/slazarov/podman-ubuntu.git
cd podman-ubuntu

# Source version pins (stable track)
source versions-stable.env

# Run the build (as root)
sudo -E ./setup.sh
```

The build is fully non-interactive, auto-detects the system architecture (amd64 or arm64), and compiles all 12 components from source. A fresh build takes approximately 15-20 minutes depending on hardware.

### Build Options

Override environment variables before running `setup.sh` to customize the build:

```bash
# Enable sccache for Rust builds (50-90% rebuild speedup)
export SCCACHE_ENABLED=true

# Enable ccache for C builds (30x faster warm-cache rebuilds)
export CCACHE_ENABLED=true

# Enable mold linker for Rust builds (5-10x faster linking)
export MOLD_ENABLED=true

source versions-stable.env
sudo -E ./setup.sh
```

### Uninstall

To cleanly remove all components installed from source:

```bash
sudo ./uninstall.sh
```

---

## Components

The project builds and packages the following 12 components from upstream sources:

| Component | Upstream Repository | Description |
|-----------|-------------------|-------------|
| Podman | [containers/podman](https://github.com/containers/podman) | Daemonless container engine |
| Buildah | [containers/buildah](https://github.com/containers/buildah) | OCI image builder |
| Skopeo | [containers/skopeo](https://github.com/containers/skopeo) | Container image operations (copy, inspect, sign) |
| crun | [containers/crun](https://github.com/containers/crun) | Fast, low-memory OCI runtime (C) |
| conmon | [containers/conmon](https://github.com/containers/conmon) | Container monitor (stdio, exit code, logging) |
| Netavark | [containers/netavark](https://github.com/containers/netavark) | Container network stack (Rust) |
| Aardvark-DNS | [containers/aardvark-dns](https://github.com/containers/aardvark-dns) | Authoritative DNS for container networks |
| pasta/passt | [passt-top/passt](https://passt.top/) | User-mode networking (no root required) |
| fuse-overlayfs | [containers/fuse-overlayfs](https://github.com/containers/fuse-overlayfs) | FUSE overlay filesystem for rootless containers |
| catatonit | [openSUSE/catatonit](https://github.com/openSUSE/catatonit) | Minimal init process for containers |
| Toolbox | [containers/toolbox](https://github.com/containers/toolbox) | Containerized CLI development environments |
| containers-common | [containers/common](https://github.com/containers/common) | Shared config files, seccomp profiles, policy |

---

## Current Versions (Stable Track)

| Component | Version |
|-----------|---------|
| Podman | v5.8.0 |
| Buildah | v1.43.0 |
| Skopeo | v1.22.0 |
| crun | 1.26 |
| conmon | v2.2.1 |
| Netavark | v1.17.2 |
| Aardvark-DNS | v1.17.0 |
| fuse-overlayfs | v1.16 |
| catatonit | v0.2.1 |
| Toolbox | 0.3 |
| containers-common | common/v0.67.0 |

The **edge** track automatically pulls the latest upstream release tags. The **nightly** track builds from HEAD daily.

---

## Supported Platforms

| Platform | Architectures |
|----------|--------------|
| Ubuntu 24.04 (Noble Numbat) | amd64 (x86_64), arm64 (aarch64) |

Both architectures are built natively in CI (not cross-compiled). APT selects the correct architecture automatically.

---

## Build Caching

The build system supports opt-in caching layers for faster rebuilds:

| Layer | Purpose | Speedup | Enable |
|-------|---------|---------|--------|
| **sccache** | Rust compilation cache | 50-90% rebuild | `export SCCACHE_ENABLED=true` |
| **ccache** | C compilation cache | 30x warm-cache | `export CCACHE_ENABLED=true` |
| **Go cache** | Shared Go module/build cache | 20x rebuild | Enabled by default (`GOCACHE`, `GOMODCACHE`) |
| **mold** | Fast linker for Rust | 5-10x linking | `export MOLD_ENABLED=true` |

---

## License

[AGPL-3.0](LICENSE)

---

## Credits

- Forked from [luckylinux/podman-ubuntu](https://github.com/luckylinux/podman-ubuntu)
- Upstream: [Podman](https://github.com/containers/podman) by the Containers project
