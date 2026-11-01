# Configuration

The build is configured through environment variables. Every variable in `config.sh` uses the `${VAR:-default}` form, so you can override it by exporting it before running `setup.sh` or any script. Track policy lives in `versions-stable.env` and `versions-v5.env` (turned into concrete tags by `scripts/resolve_versions.sh`) and in `versions-nightly.env`.

Other configuration lives in files:

- Runtime defaults shipped to users: [`config/`](../config/), plus the files `build_container-libs.sh` produces.
- Package metadata: [`packaging/nfpm/`](../packaging/nfpm/).
- APT repository layout: [`packaging/repo/conf/`](../packaging/repo/conf/).

## Distro table

The supported releases are defined once, in `config.sh`. These are plain shell variables, not environment overrides; change them by editing `config.sh`.

| Variable | Value | Description |
|----------|-------|-------------|
| `VALID_TRACKS` | `stable v5 nightly` | Release tracks. |
| `VALID_ARCHES` | `amd64` | Architectures built and published. |
| `VALID_DISTROS` | `bookworm trixie` | Distro labels. Each label is a Debian codename and appears in suite names, CI artifact names and cache keys. |
| `DISTRO_VERSION_IDS` | `bookworm=12`, `trixie=13` | `VERSION_ID` for each label, used in the version suffix. |
| `DISTRO_IMAGES` | `docker.io/library/debian:bookworm`, `docker.io/library/debian:trixie` | Container image for CI build cells and the smoke tests. |
| `ALL_SUITES` | derived | Every `{track}-{label}` suite, for example `stable-bookworm`. |

Standalone scripts and the tests read only this block, from the `VALID_TRACKS=` line to the `unset _distro _track` line. Keep it free of side effects and keep those two lines intact.

## Environment variables

### Target and build orchestration

| Variable | Default | Description |
|----------|---------|-------------|
| `DISTRO` | detected | Target release, as a codename (`bookworm`) or `VERSION_ID` (`12`). When unset, `/etc/os-release` is read; it must have `ID=debian` and a `VERSION_ID` from the distro table. Anything else stops the build. `ci_publish.sh` and `repo_manage.sh` set it from their distro argument. |
| `OS_RELEASE_FILE` | `/etc/os-release` | File read when `DISTRO` is unset. Used by the tests. |
| `ARCH` | detected by `detect_architecture` | Target architecture. Only `amd64` is supported. Sets `GOARCH`, `PROTOC_ARCH`, `RUSTUP_ARCH` and `SCCACHE_ARCH`. |
| `NPROC` | `$(nproc)` | Parallel job count for `make` and `cargo`. |
| `SHALLOW_CLONE` | `true` | Shallow-clone upstream repositories. Must be `false` for nightly, which needs history for `git describe`. |
| `PACKAGE_REVISION` | `1` (in `scripts/package_revision.sh`) | The `N` in the `~deb{VERSION_ID}.podman{N}` suffix. Bump the default whenever packaging changes without an upstream version change. Otherwise apt sees an identical version and the publish step keeps the already-published `.deb`. |
| `DESTDIR` | none | Staging tree that build scripts install into and `package_all.sh` reads from. Required for packaging. |
| `BUILD_ROOT` | `${toolpath}/build` | Directory for cloned sources and downloads. |
| `SKIP_FUSE_CHECK` | `false` | Marks a build-only environment, such as a CI container, where `/dev/fuse` is not usable. It only changes the wording of the FUSE preflight warning. That check never fails the build: compilation never opens `/dev/fuse`. |

`config.sh` exports these derived values:

| Variable | Example | Description |
|----------|---------|-------------|
| `DISTRO_VERSION_ID` | `12` | Detected or overridden `VERSION_ID`. |
| `DISTRO_LABEL` | `bookworm` | Codename for `DISTRO_VERSION_ID`. |
| `VERSION_SUFFIX` | `~deb12.podman1` | Appended to every package version. |

### Component versions

These tags select the upstream version of each component. An empty tag means auto-detect, or stay on the default branch HEAD for nightly.

For stable and v5 you do not set tags by hand. The policy file declares `*_SERIES` caps and a soak window, and `resolve_versions.sh` prints concrete `*_TAG` values:

```bash
eval "$(./scripts/resolve_versions.sh versions-stable.env)" && sudo -E ./setup.sh  # Podman 6.x
eval "$(./scripts/resolve_versions.sh versions-v5.env)" && sudo -E ./setup.sh      # Podman 5.x
source versions-nightly.env && sudo -E ./setup.sh                                  # upstream HEAD
```

| Variable | Example | Description |
|----------|---------|-------------|
| `PODMAN_TAG` | `v5.8.0` | Podman release tag. |
| `BUILDAH_TAG` | `v1.43.0` | Buildah release tag. |
| `CRUN_TAG` | `1.26` | crun release tag. |
| `CONMON_TAG` | `v2.2.1` | conmon release tag. |
| `NETAVARK_TAG` | `v1.17.2` | Netavark release tag. |
| `AARDVARK_DNS_TAG` | `v1.17.0` | aardvark-dns release tag. |
| `SKOPEO_TAG` | `v1.22.0` | Skopeo release tag. |
| `GOMD2MAN_TAG` | `v2.0.7` | go-md2man release tag. |
| `TOOLBOX_TAG` | `0.3` | Toolbx release tag. |
| `FUSE_OVERLAYFS_TAG` | `v1.16` | fuse-overlayfs release tag. |
| `CATATONIT_TAG` | `v0.2.1` | catatonit release tag. |
| `PASTA_TAG` | `2026_10_02.cba3570` | passt release tag (`YYYY_MM_DD.<sha>`). The package version is the date, `20261002`. Empty builds upstream `master`, versioned by the build date; nightly always does this. |
| `CONTAINER_LIBS_TAG` | `common/v0.67.0` | containers/container-libs tag for the config files and `seccomp.json`. Uses namespaced `common/` tags. |
| `PROTOC_VERSION` | `34.0` | protoc version. Defaults to the latest release (`get_latest_protoc_version`). |
| `PROTOC_TAG` | `v34.0` | protoc tag. Defaults to `v${PROTOC_VERSION}`. |
| `GOVERSION` | `1.26.8` | Go version. Defaults to the version in Podman's `go.mod`. Sets `GOPATH` and `GOROOT` under `/opt/go/${GOVERSION}`. |
| `RUST_VERSION` | `1.88` | Rust version. Defaults to the minimum in Netavark's `Cargo.toml`. |

Policy variables read by `resolve_versions.sh`:

| Variable | Description |
|----------|-------------|
| `PODMAN_SERIES` | Series cap for Podman: `6` in `versions-stable.env`, `5` in `versions-v5.env`. The resolver picks the highest tag in that series. An exact `PODMAN_TAG` overrides it. |
| `NETAVARK_SERIES`, `AARDVARK_DNS_SERIES` | `2` on stable, `1` on v5. Netavark and aardvark-dns 2.x require Podman 6. |
| `BUILDAH_SERIES` | `1.44` on stable, `1.43` on v5. Buildah is derived from Podman's `go.mod`; the series caps the fallback and rejects a derived version outside it. |
| `STABLE_SOAK_DAYS` | Default `7`. A non-frozen tag is adopted only once its commit is at least this many days old. |

### Nightly

| Variable | Default | Description |
|----------|---------|-------------|
| `NIGHTLY_BUILD` | `false` | When `true`, `git_checkout` stays on the default branch HEAD and `package_all.sh` reads the version from source, producing for example `5.9.0~~git20260306.abc1234~deb12.podman1`. |

`versions-nightly.env` sets `NIGHTLY_BUILD=true` and `SHALLOW_CLONE=false` and leaves all tags empty.

The nightly marker is `~~git`, with two tildes. dpkg compares `~git` and `~deb` letter by letter and `g` sorts above `d`, so a single tilde would make a nightly build sort above the tagged release with the same base version. `~~` sorts below any `~d...`, so users on nightly upgrade when the release lands. `scripts/verify_versions.sh` checks this.

### Rust and Cargo

| Variable | Default | Description |
|----------|---------|-------------|
| `CARGO_BUILD_JOBS` | `$NPROC` | Parallel cargo jobs. |
| `SCCACHE_ENABLED` | `false` | Cache Rust builds with sccache. |
| `SCCACHE_VERSION` | `0.14.0` | sccache version, used when enabled. |
| `SCCACHE_DIR` | `/var/cache/sccache` | sccache cache directory. |
| `MOLD_ENABLED` | `false` | Link Rust binaries with mold. Installs `mold` and `clang`. |

### C

| Variable | Default | Description |
|----------|---------|-------------|
| `CCACHE_ENABLED` | `false` | Cache C builds with ccache. Installs `ccache`. |
| `CCACHE_DIR` | `/var/cache/ccache` | ccache cache directory. |
| `CCACHE_MAXSIZE` | `2G` | Maximum cache size. |
| `CCACHE_COMPILERCHECK` | `content` | Hash the compiler binary, so a GCC upgrade invalidates the cache. |

### Go

| Variable | Default | Description |
|----------|---------|-------------|
| `GO_GCFLAGS` | `-c=16` | Parallel compilation inside the Go compiler. |
| `GO_LDFLAGS` | `-s -w` | Strip debug symbols. |
| `GOGC_BUILD` | `off` | Disable the Go garbage collector during compilation. Faster, uses more memory. Set to empty to re-enable. |
| `GOCACHE` | `/var/cache/go-build` | Go build cache, shared by all components. |
| `GOMODCACHE` | `/var/cache/go-mod` | Go module cache. |

### Packaging and publishing

| Variable | Default | Description |
|----------|---------|-------------|
| `VERSION` | computed | Package version substituted into the nFPM YAML. Set per component by `package_all.sh`. |
| `GPG_PRIVATE_KEY` | none | Key imported by `repo_manage.sh` before signing. Accepts a base64-encoded key (`gpg --export-secret-keys --armor KEY_ID \| base64 -w0`) or a raw ASCII-armored key. When unset, a secret key must already be in the keyring. |
| `REPO_URL_DEFAULT` | `https://slazarov.github.io/podman-debian` | Live repository read by `check_republish_needed.sh` when no URL argument is given. |

`repo_manage.sh` takes the output directory as its fourth argument (default `${toolpath}/repo-output`). `package_all.sh` always writes to `${toolpath}/output`.

### Smoke tests

| Variable | Default | Description |
|----------|---------|-------------|
| `SMOKE_RUNTIME` | `docker`, else `podman` | Container runtime. Must be exactly `docker` or `podman`. |
| `SMOKE_IMAGE` | the label's `DISTRO_IMAGES` entry | Base image override. |
| `OUTPUT_DIR` | `${toolpath}/output` | Where `smoke_install.sh` looks for `.deb` files. |
| `TRACK` | `nightly` | Track `smoke_repo_install.sh` installs from. |
| `LIVE_REPO_URL` | none | Published repository for the upgrade scenario. Unset skips that scenario. Must be a plain `https://` URL. |

## Configuration files

### `config/containers.conf`

Installed to `/etc/containers/containers.conf` by `podman-container-configs`. See `containers.conf(5)`.

```ini
[containers]
seccomp_profile = "/usr/share/containers/seccomp.json"

[engine]
runtime = "crun"

[network]
network_backend = "netavark"
```

| Key | Section | Description |
|-----|---------|-------------|
| `seccomp_profile` | `[containers]` | Seccomp profile shipped by `podman-container-configs`. |
| `runtime` | `[engine]` | Default OCI runtime, `crun`. |
| `helper_binaries_dir` | `[engine]` | Not set. Podman's built-in default includes `/usr/libexec/podman`, where netavark and aardvark-dns are installed. Podman reads only the first main `containers.conf` it finds (user file, then `/etc`, then `/usr/share`), so a value set here would disappear once a user creates `~/.config/containers/containers.conf`. Put per-user settings in `~/.config/containers/containers.conf.d/*.conf` drop-ins, which layer on top. |
| `network_backend` | `[network]` | `netavark`. CNI was removed in Podman 5.0. |

`policy.json`, `registries.conf`, `storage.conf`, `registries.d/default.yaml` and `seccomp.json` come from upstream `containers/container-libs` through `build_container-libs.sh` and are shipped by `podman-container-configs`.

### `packaging/nfpm/`

One nFPM manifest per package. `${VERSION}`, `${ARCH}`, `${DESTDIR}` and `${DETECTED_DEPENDS}` are filled in at build time. Fields, using [`podman.yaml`](../packaging/nfpm/podman.yaml) as the example:

| Field | Value | Description |
|-------|-------|-------------|
| `name` | `podman-podman` | Package name. All packages are named `podman-*`. |
| `version_schema` | `none` | Turns off nFPM's semver normalization, so `~` versions pass through. |
| `maintainer` | `Podman Debian <noreply@github.com>` | Maintainer field. |
| `vendor` | `podman-debian` | Vendor field. |
| `depends` | other `podman-*` packages, `uidmap`, detected libraries | System libraries come from `detect_runtime_depends` and differ per release (for example `libgpgme11` on bookworm, `libgpgme11t64` on trixie). |
| `conflicts`, `replaces`, `provides` | `podman` | Lets the package replace Debian's own `podman`. |
| `contents` | binaries, man pages, systemd units, completions | Installed files. |

[`suite.yaml`](../packaging/nfpm/suite.yaml) builds the `podman-suite` meta-package, which has dependencies and no files. [`container-configs.yaml`](../packaging/nfpm/container-configs.yaml) marks the `/etc/containers/*` files as conffiles, so local edits survive upgrades; `seccomp.json` is a plain file replaced on upgrade. It conflicts with and replaces `golang-github-containers-common` and `golang-github-containers-image`, which own these files in Debian. [`toolbox.yaml`](../packaging/nfpm/toolbox.yaml) is named `podman-toolbx` because Debian already has a package called `podman-toolbox`.

### `packaging/repo/conf/`

[`distributions`](../packaging/repo/conf/distributions) defines one reprepro distribution per suite in `ALL_SUITES`. Each has `Origin: podman-debian`, `Label: Podman Debian`, `Architectures: amd64`, `Components: main` and `SignWith: yes`, with `Suite` equal to `Codename`.

| Suite | Contents |
|-------|----------|
| `stable-bookworm`, `stable-trixie` | Podman 6.x releases |
| `v5-bookworm`, `v5-trixie` | Podman 5.x releases |
| `nightly-bookworm`, `nightly-trixie` | Nightly builds of upstream main |

There are no bare `stable`, `v5` or `nightly` suites. `tests/test_distributions_suites.sh` checks that this file matches `ALL_SUITES`.

[`options`](../packaging/repo/conf/options) sets `verbose` and `basedir .`.

`repo_manage.sh` and `ci_publish.sh` take a track and a distro label. `resolve_publish_targets` validates them against `VALID_TRACKS` and `VALID_DISTROS` and returns `<track>-<distro>`.

`packaging/repo/pubkey.gpg`, when present, is published as `podman-debian.gpg`, so it must be the public half of the key in `GPG_PRIVATE_KEY`. When the file is absent, `repo_manage.sh` exports the public key from the signing keyring instead.

## Required settings

Packaging needs `DESTDIR`. `package_all.sh` checks it first:

```text
ERROR: DESTDIR environment variable is not set.
  DESTDIR must point to a populated staging tree.
  Example: export DESTDIR=/tmp/podman-staging
```

Publishing needs a GPG secret key, either through `GPG_PRIVATE_KEY` or already in the keyring:

```text
ERROR: No GPG secret key found in keyring.
  Either set GPG_PRIVATE_KEY environment variable (for CI)
  or import a key manually: gpg --import <private-key-file>
```

Building on a host that is not Debian 12 or 13 needs `DISTRO`, and fails without it:

```text
ERROR: unsupported distribution 'fedora' in /etc/os-release. This pipeline builds for Debian only.
```

Everything else has a default.

## Tracks

There are no per-environment config files. You select a track by resolving or sourcing its file before `setup.sh`:

- stable (Podman 6.x): `eval "$(./scripts/resolve_versions.sh versions-stable.env)"`. For each component an exact `*_TAG` wins, then the highest tag under the `*_SERIES` cap, then the latest release, and any non-frozen tag waits out `STABLE_SOAK_DAYS`. Buildah is derived from Podman's `go.mod`.
- v5 (Podman 5.x): `eval "$(./scripts/resolve_versions.sh versions-v5.env)"`. Same rules, with Podman capped at 5, netavark and aardvark-dns at 1.x and buildah at 1.43, since their next majors require Podman 6. crun, conmon, skopeo, container-configs and the toolchains are shared with stable.
- nightly: `source versions-nightly.env`. Builds upstream HEAD.

Users change runtime behavior through the normal Podman configuration files. The `/etc/containers/*` files are conffiles, so local edits are kept across upgrades.
