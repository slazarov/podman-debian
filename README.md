# podman-debian

> [!IMPORTANT]
> **The repository signing key was rotated on 2026-11-11.** Existing users must
> replace their copy of the key, otherwise `apt update` fails with
> `NO_PUBKEY BA5919253E6B3985`:
>
> ```bash
> wget -qO /tmp/podman-debian.gpg https://slazarov.github.io/podman-debian/podman-debian.gpg
> gpg --show-keys /tmp/podman-debian.gpg   # must show 186FB2050A782B871E3C798EBA5919253E6B3985
> sudo install -m 0644 /tmp/podman-debian.gpg /etc/apt/keyrings/podman-debian.gpg
> rm /tmp/podman-debian.gpg
> sudo apt update
> ```
>
> New key fingerprint: `186F B205 0A78 2B87 1E3C  798E BA59 1925 3E6B 3985`
>
> Revocation certificate for the old key `B7F2 FD05 0924 0BDA CD92  B1D1 E56C E5A0 B970 2F11`:
> [`packaging/repo/revocations/B7F2FD0509240BDACD92B1D1E56CE5A0B9702F11.asc`](packaging/repo/revocations/B7F2FD0509240BDACD92B1D1E56CE5A0B9702F11.asc)
<!-- REVOCATION-CERT-PLACEHOLDER: link the public revocation certificate for the
     old key 0B0622010F2A018D1FEB502C26507BEECFFC87BB here once available -->

Build the Podman container stack from upstream source for Debian, or install the prebuilt packages from the project's APT repository.

[![lint](https://github.com/slazarov/podman-debian/actions/workflows/lint.yml/badge.svg)](https://github.com/slazarov/podman-debian/actions/workflows/lint.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)

| | |
|---|---|
| Releases | Debian 12 (bookworm), Debian 13 (trixie) |
| Architecture | amd64 |
| APT repository | <https://slazarov.github.io/podman-debian/> |
| License | AGPL-3.0 |

Debian testing, unstable and other distributions are not supported. The build stops with an error if it detects one.

## Install from the APT repository

Download the signing key:

```bash
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/podman-debian.gpg \
  https://slazarov.github.io/podman-debian/podman-debian.gpg
```

Add the repository. The command fills in your release's suite from `/etc/os-release`: `stable-bookworm` on Debian 12, `stable-trixie` on Debian 13.

```bash
sudo tee /etc/apt/sources.list.d/podman-debian.sources << EOF
Types: deb
URIs: https://slazarov.github.io/podman-debian
Suites: stable-$(. /etc/os-release && echo "$VERSION_CODENAME")
Components: main
Signed-By: /etc/apt/keyrings/podman-debian.gpg
EOF
```

Install the stack:

```bash
sudo apt update
sudo apt install podman-suite
```

`podman-suite` is a meta-package that pulls in all 12 components. Setup details, track selection and troubleshooting are in [docs/apt-repository.md](docs/apt-repository.md).

### Release tracks

Each track is published once per Debian release, as a suite named `<track>-<codename>`:

| Track | Debian 12 suite | Debian 13 suite | Contents |
|-------|-----------------|-----------------|----------|
| stable | `stable-bookworm` | `stable-trixie` | Podman 6.x, follows new upstream releases after a soak period |
| v5 | `v5-bookworm` | `v5-trixie` | Podman 5.x, same update policy |
| nightly | `nightly-bookworm` | `nightly-trixie` | Upstream main branch, built daily |

To move to a newer track, for example from v5 to stable, change the `Suites:` line and upgrade:

```bash
sudo sed -i "s/^Suites: .*/Suites: stable-$(. /etc/os-release && echo "$VERSION_CODENAME")/" /etc/apt/sources.list.d/podman-debian.sources
sudo apt update
sudo apt upgrade
```

Moving to an older series (stable to v5, or nightly to stable) is a downgrade, which apt does not do on its own. See [Switching tracks](docs/apt-repository.md#switching-tracks).

## Packages

All packages use the `podman-` prefix. They declare `Conflicts`, `Replaces` and `Provides` against Debian's own packages (`podman`, `crun`, `conmon`, `golang-github-containers-common`, `podman-toolbox` and so on), so installing one removes the Debian package it stands in for.

| Package | Description | Binaries shipped |
|---------|-------------|------------------|
| `podman-podman` | Container engine | `podman`, `podman-remote`, `podmansh`; `quadlet` and `rootlessport` under `/usr/libexec/podman` |
| `podman-crun` | OCI runtime | `crun` |
| `podman-conmon` | Container monitor | `conmon` |
| `podman-netavark` | Container networking | `netavark`, `netavark-dhcp-proxy-client` |
| `podman-aardvark-dns` | DNS for container networks | `aardvark-dns` |
| `podman-pasta` | User-mode networking (passt) | `passt`, `pasta`, `pesto`, `passt-repair`; `passt.avx2` and `pasta.avx2` when built |
| `podman-fuse-overlayfs` | FUSE overlay filesystem (Recommends only) | `fuse-overlayfs` |
| `podman-catatonit` | Minimal init for containers | `catatonit` |
| `podman-buildah` | OCI image builder | `buildah` |
| `podman-skopeo` | Container image utility | `skopeo` |
| `podman-toolbx` | Containerized development environments | `toolbox` |
| `podman-container-configs` | Configuration files for `/etc/containers/` | none (configuration only) |

`scripts/verify_shipped_binaries.sh` runs at package time and warns when a build stages a binary that no package ships, so new upstream binaries are noticed.

To install only the engine and its required dependencies:

```bash
sudo apt install podman-podman
```

## Build from source

You need a Debian 12 or 13 host or container, root access and network access. The build installs Go, Rust and protoc itself. It reads the Go version from Podman's `go.mod` and the Rust version from Netavark's `Cargo.toml`.

The build writes to system paths. Use a disposable VM or container.

```bash
git clone https://github.com/slazarov/podman-debian.git
cd podman-debian

# Turn the stable-track policy into concrete version tags (Podman 6.x)
eval "$(./scripts/resolve_versions.sh versions-stable.env)"

sudo -E ./setup.sh
```

`setup.sh` runs preflight checks, then builds and installs all 12 components. It runs without prompts.

For the Podman 5.x track, resolve `versions-v5.env` instead. For a nightly build from upstream HEAD, run `sudo NIGHTLY_BUILD=true SHALLOW_CLONE=false ./setup.sh`.

### Build caches

These caches are off by default. Turn them on with environment variables before running `setup.sh`:

| Cache | Purpose | Enable |
|-------|---------|--------|
| sccache | Rust compilation cache | `export SCCACHE_ENABLED=true` |
| ccache | C compilation cache | `export CCACHE_ENABLED=true` |
| mold | Faster linker for Rust | `export MOLD_ENABLED=true` |
| Go cache | Shared Go module and build cache | on by default (`GOCACHE`, `GOMODCACHE`) |

Every variable is documented in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

### Uninstall

```bash
sudo ./uninstall.sh
```

This removes the components installed from source.

## Components

| Component | Upstream | Description |
|-----------|----------|-------------|
| Podman | [containers/podman](https://github.com/containers/podman) | Daemonless container engine |
| Buildah | [containers/buildah](https://github.com/containers/buildah) | OCI image builder |
| Skopeo | [containers/skopeo](https://github.com/containers/skopeo) | Copy, inspect and sign container images |
| crun | [containers/crun](https://github.com/containers/crun) | OCI runtime written in C |
| conmon | [containers/conmon](https://github.com/containers/conmon) | Container monitor (stdio, exit code, logging) |
| Netavark | [containers/netavark](https://github.com/containers/netavark) | Container network stack |
| Aardvark-DNS | [containers/aardvark-dns](https://github.com/containers/aardvark-dns) | DNS server for container networks |
| pasta/passt | [passt.top](https://passt.top/) | User-mode networking |
| fuse-overlayfs | [containers/fuse-overlayfs](https://github.com/containers/fuse-overlayfs) | FUSE overlay filesystem for rootless containers |
| catatonit | [openSUSE/catatonit](https://github.com/openSUSE/catatonit) | Minimal init process for containers |
| Toolbox | [containers/toolbox](https://github.com/containers/toolbox) | Containerized command line environments |
| container-libs | [containers/container-libs](https://github.com/containers/container-libs) | Shared configuration files, seccomp profile, policy |

### How versions are chosen

Versions are not pinned by hand. [`scripts/resolve_versions.sh`](scripts/resolve_versions.sh) reads a policy file ([`versions-stable.env`](versions-stable.env) or [`versions-v5.env`](versions-v5.env)) with a series cap per component and a soak period: a new upstream tag is used only after its commit is at least `STABLE_SOAK_DAYS` days old (default 7). Buildah's version is taken from Podman's `go.mod`. The nightly track builds upstream HEAD. The versions currently published are listed on the [repository page](https://slazarov.github.io/podman-debian/).

Package versions carry a per-release suffix, `~deb12.podmanN` on bookworm and `~deb13.podmanN` on trixie, where `N` is the packaging revision. Nightly versions look like `5.9.0~~git20260306.abc1234~deb13.podman1`, which sorts below the tagged release of the same version.

More detail is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/TESTING.md](docs/TESTING.md).

## Out of scope

The project does not provide pinning to an arbitrary version (each track follows its own policy), a GUI installer, distributions other than Debian 12 and 13, architectures other than amd64, partial or resumable builds, component selection, or CNI networking (removed upstream in Podman 5.0).

## License

[AGPL-3.0](LICENSE)

## Credits

- Started from [luckylinux/podman-debian](https://github.com/luckylinux/podman-debian)
- Upstream: [Podman](https://github.com/containers/podman) and the other projects listed above
