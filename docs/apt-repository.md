# APT Repository Setup

This project provides a custom APT repository for Podman and its ecosystem tools, compiled from source for Ubuntu 24.04 (Noble Numbat). Packages are available for both amd64 and arm64 architectures.

The repository is hosted on GitHub Pages and serves two suites:

- **stable** -- tested release versions
- **edge** -- latest upstream tags, rebuilt automatically

## Quick Start

Add the repository and install the full Podman stack in 4 commands:

```bash
# Download the GPG signing key
sudo mkdir -p /etc/apt/keyrings
sudo wget -qO /etc/apt/keyrings/podman-debian.gpg \
  https://slazarov.github.io/podman-debian/podman-debian.gpg

# Add the repository (DEB822 format)
sudo tee /etc/apt/sources.list.d/podman-debian.sources << 'EOF'
Types: deb
URIs: https://slazarov.github.io/podman-debian
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/podman-debian.gpg
EOF

# Update and install
sudo apt update
sudo apt install -y podman-suite
```

The `podman-suite` meta-package installs all components. See below for installing individual packages.

## Using the Edge Suite

The edge suite tracks the latest upstream release tags. To use edge instead of stable, change the `Suites` line in the DEB822 source file:

```bash
sudo tee /etc/apt/sources.list.d/podman-debian.sources << 'EOF'
Types: deb
URIs: https://slazarov.github.io/podman-debian
Suites: edge
Components: main
Signed-By: /etc/apt/keyrings/podman-debian.gpg
EOF

sudo apt update
```

Edge packages are rebuilt when new upstream releases are detected. Use edge if you want the newest features; use stable for production systems.

## Installing Individual Packages

The `podman-suite` meta-package pulls in all components. You can also install them individually:

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

Example installing only the core runtime:

```bash
sudo apt install podman-podman
```

This automatically pulls in required dependencies (crun, conmon, netavark, aardvark-dns, pasta, fuse-overlayfs, and container-configs).

## Supported Architectures

- **amd64** (x86_64)
- **arm64** (aarch64)

Both architectures are built natively (not cross-compiled) and included in the same repository. APT selects the correct architecture automatically.

## Troubleshooting

### GPG key not found or download fails

Verify the key was downloaded correctly:

```bash
file /etc/apt/keyrings/podman-debian.gpg
```

Expected output should show "PGP/GPG key public ring" or similar binary key format. If it shows HTML or text, the download URL may have changed. Re-download:

```bash
sudo wget -qO /etc/apt/keyrings/podman-debian.gpg \
  https://slazarov.github.io/podman-debian/podman-debian.gpg
```

### Signature verification errors on apt update

If you see errors like `The following signatures couldn't be verified` or `NO_PUBKEY`:

1. Ensure the key file is binary format (not ASCII-armored). Check with `file /etc/apt/keyrings/podman-debian.gpg` -- it should not start with `-----BEGIN`.

2. If you have an ASCII-armored key (.asc file), convert it:

```bash
sudo gpg --dearmor -o /etc/apt/keyrings/podman-debian.gpg /etc/apt/keyrings/podman-debian.asc
```

3. Verify the `Signed-By` path in your sources file matches the key location:

```bash
cat /etc/apt/sources.list.d/podman-debian.sources
```

### Repository returns 404

The repository URL is `https://slazarov.github.io/podman-debian`. Ensure:

- The `URIs` line in your sources file has no trailing slash
- GitHub Pages is live (check the URL in a browser)
- The `Suites` value matches an available suite (`stable` or `edge`)

### Packages conflict with official Ubuntu packages

The podman-debian packages use `Conflicts`, `Replaces`, and `Provides` declarations to handle coexistence with official Ubuntu packages. Installing a `podman-*` package will replace the corresponding official package if present. This is by design -- the compiled-from-source versions are newer.

To revert to official packages, remove the podman-debian packages and reinstall from the official repository:

```bash
sudo apt remove podman-suite
sudo apt install podman
```

## Important Notes

- This repository uses the modern DEB822 `.sources` format with `Signed-By` for per-repository key binding. Legacy one-line source format and global key trust are not supported.
- The GPG signing key is Ed25519, which is supported by Ubuntu 24.04 and later.
- All packages use the `~podman1` version suffix to ensure official Ubuntu packages (when available at the same upstream version) take priority during upgrades.
