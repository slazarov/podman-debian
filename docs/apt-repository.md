# APT repository

The repository at <https://slazarov.github.io/podman-debian> serves Podman and its companion tools, built from upstream source, for Debian 12 (bookworm) and Debian 13 (trixie) on amd64. It is hosted on GitHub Pages and signed with a single GPG key.

There are three tracks. Each one is published per Debian release as a suite named `<track>-<codename>`:

| Track | Debian 12 suite | Debian 13 suite | Contents |
|-------|-----------------|-----------------|----------|
| stable | `stable-bookworm` | `stable-trixie` | Podman 6.x. Use this one unless you have a reason not to. |
| v5 | `v5-bookworm` | `v5-trixie` | Podman 5.x, for hosts not ready for the [Podman 6.0 changes](https://github.com/containers/podman/releases) (notably netavark 2.0). |
| nightly | `nightly-bookworm` | `nightly-trixie` | Upstream main branch, built daily. Newest code, least tested. |

The stable and v5 tracks pick up a new upstream release once it has been public for a soak period (7 days by default).

Debian testing and unstable are not supported. There are no suites for them.

## Setup

You need `curl` (`sudo apt install curl`) to download the key.

### 1. Install the signing key

The key is the same for every release and track:

```bash
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/podman-debian.gpg \
  https://slazarov.github.io/podman-debian/podman-debian.gpg
```

### 2. Add the repository

On Debian 12 (bookworm):

```bash
sudo tee /etc/apt/sources.list.d/podman-debian.sources << 'EOF'
Types: deb
URIs: https://slazarov.github.io/podman-debian
Suites: stable-bookworm
Components: main
Signed-By: /etc/apt/keyrings/podman-debian.gpg
EOF
```

On Debian 13 (trixie):

```bash
sudo tee /etc/apt/sources.list.d/podman-debian.sources << 'EOF'
Types: deb
URIs: https://slazarov.github.io/podman-debian
Suites: stable-trixie
Components: main
Signed-By: /etc/apt/keyrings/podman-debian.gpg
EOF
```

For another track, replace `stable` in the `Suites:` line with `v5` or `nightly`. Always use the suite that matches your release. The packages are linked against that release's libraries.

### 3. Install

```bash
sudo apt update
sudo apt install podman-suite
```

## Switching tracks

Change the `Suites:` line and upgrade. For example, to move a bookworm host from v5 to stable:

```bash
sudo sed -i 's/^Suites: .*/Suites: stable-bookworm/' /etc/apt/sources.list.d/podman-debian.sources
sudo apt update
sudo apt full-upgrade
```

Moving to an older Podman series (stable to v5, or nightly to stable) is a downgrade, and apt does not downgrade on its own. Remove the packages with `sudo apt remove 'podman-*'`, change the suite, then install `podman-suite` again.

## Upgrading from Debian 12 to 13

Change the suite from `-bookworm` to `-trixie` at the same time as you change your Debian sources, then run the release upgrade. The trixie builds have a higher version (`~deb13` sorts above `~deb12`), so apt replaces the bookworm builds.

## Installing individual packages

`podman-suite` pulls in everything. The packages can also be installed one by one:

| Package | Description |
|---------|-------------|
| `podman-podman` | Container engine |
| `podman-crun` | OCI runtime |
| `podman-conmon` | Container monitor |
| `podman-netavark` | Container networking |
| `podman-aardvark-dns` | DNS for container networks |
| `podman-pasta` | User-mode networking (passt) |
| `podman-fuse-overlayfs` | FUSE overlay filesystem (Recommends only) |
| `podman-catatonit` | Minimal init for containers |
| `podman-buildah` | OCI image builder |
| `podman-skopeo` | Container image utility |
| `podman-toolbx` | Containerized development environments |
| `podman-container-configs` | Configuration files for `/etc/containers/` |

To install only the engine:

```bash
sudo apt install podman-podman
```

This also installs crun, conmon, netavark, aardvark-dns, pasta, catatonit, container-configs and `uidmap`. `podman-fuse-overlayfs` is a Recommends: apt installs it by default, and you can leave it out with `--no-install-recommends`. See [fuse-overlayfs is optional](#fuse-overlayfs-is-optional).

## Versions

Package versions end in a per-release suffix: `~deb12.podmanN` on bookworm and `~deb13.podmanN` on trixie. `N` is the packaging revision. It goes up when the packaging changes without a new upstream release, so the change reaches installed systems.

Nightly versions add a snapshot marker, for example `5.9.0~~git20260306.abc1234~deb13.podman1`. The double tilde makes a nightly sort below the tagged release of the same version.

Because the suffix starts with a tilde, these versions sort below the bare upstream version and below Debian's own package of the same release (for example `5.4.2~deb13.podman1` is lower than Debian's `5.4.2+ds1-2`). That does not matter in practice: the packages here have different names (`podman-podman`, `podman-crun`, ...), so apt never chooses between the two by version.

## Coexistence with Debian's packages

Each `podman-*` package declares `Conflicts`, `Replaces` and `Provides` for the Debian package it stands in for:

| Package | Replaces Debian packages |
|---------|--------------------------|
| `podman-podman` | `podman` |
| `podman-crun` | `crun` |
| `podman-conmon` | `conmon` |
| `podman-netavark` | `netavark` |
| `podman-aardvark-dns` | `aardvark-dns` |
| `podman-pasta` | `passt` |
| `podman-fuse-overlayfs` | `fuse-overlayfs` |
| `podman-catatonit` | `catatonit` |
| `podman-buildah` | `buildah` |
| `podman-skopeo` | `skopeo` |
| `podman-toolbx` | `podman-toolbox`, `toolbox` |
| `podman-container-configs` | `golang-github-containers-common`, `golang-github-containers-image` |

Installing a `podman-*` package removes the corresponding Debian package if it is installed.

Toolbx is packaged as `podman-toolbx`, not `podman-toolbox`, because Debian already has a package called `podman-toolbox`. Sharing the name would let a Debian update with a higher version replace this build.

To go back to Debian's packages:

```bash
sudo apt remove 'podman-*'
sudo rm /etc/apt/sources.list.d/podman-debian.sources
sudo apt update
sudo apt install podman
```

## Troubleshooting

### The key does not download or looks wrong

Check the file:

```bash
file /etc/apt/keyrings/podman-debian.gpg
```

It should be reported as a PGP/GPG public key ring. If it is HTML or text, download it again with the command in [Setup](#setup).

### Signature errors on `apt update`

For errors such as `The following signatures couldn't be verified` or `NO_PUBKEY`:

1. Make sure the key file is binary, not ASCII-armored. It must not start with `-----BEGIN`. To convert an armored key:

   ```bash
   sudo gpg --dearmor -o /etc/apt/keyrings/podman-debian.gpg /path/to/podman-debian.asc
   ```

2. Make sure the `Signed-By:` path in `/etc/apt/sources.list.d/podman-debian.sources` is the key's location.

### The repository returns 404

Check that:

- the `URIs:` line is `https://slazarov.github.io/podman-debian`, with no trailing slash;
- the `Suites:` value is one of the six suites listed at the top of this page;
- the site loads in a browser.

### `podman-suite` is kept back

`apt upgrade` never removes packages. If an upgrade needs to remove one (for example a package was renamed), it holds `podman-suite` back. Run:

```bash
sudo apt full-upgrade
```

### Customizing `containers.conf` per user

Podman reads only the first main `containers.conf` it finds: `~/.config/containers/containers.conf`, then `/etc/containers/containers.conf`, then `/usr/share/containers/containers.conf`. A user file therefore discards every setting in the system file. For per-user changes, use a drop-in, which is layered on top of the system file:

```bash
mkdir -p ~/.config/containers/containers.conf.d
$EDITOR ~/.config/containers/containers.conf.d/10-local.conf
```

### Rootless prerequisites

Rootless Podman needs a few host features. A source build checks them in `scripts/preflight_check.sh`. APT users should check them too:

- cgroups v2. Debian 12 and 13 use it by default.
- A subordinate UID/GID range for the user:
  `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"`.
- `newuidmap` and `newgidmap`, from the `uidmap` package. `podman-podman` depends on it, so apt installs it.
- FUSE (`/dev/fuse` and the `fuse3` package), only if you use fuse-overlayfs.
- No `noexec` on `/tmp` or `$HOME`. Remove it from the mount options, or point `TMPDIR` at a filesystem that allows execution.

### fuse-overlayfs is optional

On Debian 12 and 13 kernels, rootless Podman uses native kernel overlay, so `podman-fuse-overlayfs` is only a Recommends. You still need it if your storage was created with fuse-overlayfs (older setups, `mount_program` in `storage.conf`, or a backing filesystem that native overlay cannot use). Podman expects such storage to keep using fuse-overlayfs. If the binary is removed, Podman does not report an error: it uses kernel overlay on fuse-format layers, which can break in subtle ways. Check before removing it (repeat with `sudo` for rootful storage in `/var/lib/containers/storage`):

```bash
cat ~/.local/share/containers/storage/overlay/.has-mount-program 2>/dev/null  # "true" = fuse-format
grep -rs mount_program ~/.config/containers/storage.conf /etc/containers/storage.conf | grep -v '^[^:]*:\s*#'
```

If the flag is `true` or an uncommented `mount_program` is set, keep the package. `sudo apt-mark manual podman-fuse-overlayfs` protects it from `apt autoremove`. Alternatively, move to native overlay with `podman system reset`. That deletes all images, containers and volumes, so `podman save` anything you need first.

## Repository format

- Sources use the DEB822 `.sources` format with a per-repository `Signed-By` key. The one-line format and global key trust are not supported.
- The signing key is Ed25519, which apt on Debian 12 and later supports.
- Indexes are published with `Acquire-By-Hash`, which avoids hash-sum mismatches while GitHub Pages updates.
- Packages are built for amd64 only.
