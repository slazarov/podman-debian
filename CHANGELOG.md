# Changelog

Notable changes to this project are recorded here, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This file covers the build and publishing pipeline. Package versions follow upstream and are listed on the [repository page](https://slazarov.github.io/podman-debian/).

## [Unreleased]

### Security

- The repository signing key was rotated on 2026-11-11. New key: `186F B205 0A78 2B87 1E3C  798E BA59 1925 3E6B 3985`. Retired: `0B06 2201 0F2A 018D 1FEB  502C 2650 7BEE CFFC 87BB` and `B7F2 FD05 0924 0BDA CD92  B1D1 E56C E5A0 B970 2F11`. Existing users must download the new `podman-debian.gpg`; see the README.
- `ci_publish.sh` re-signs a suite it serves verbatim when that suite's signatures do not verify against the published key, leaving `Release` and its indexes unchanged. Without this, no run could publish after a key rotation, because the integrity gate rejected the old signatures on the suites the run did not rebuild.

### Added

- Build pipeline for the Podman stack (12 components) from upstream source on Debian 12 (bookworm) and Debian 13 (trixie), amd64.
- `podman-*` packages built with nFPM. They declare `Conflicts`, `Replaces` and `Provides` against Debian's own packages, and their library dependencies are detected from the built binaries.
- Signed APT repository on GitHub Pages, built with reprepro, with `Acquire-By-Hash` indexes and six suites: `{stable,v5,nightly}-{bookworm,trixie}`.
- Three tracks: stable (Podman 6.x) and v5 (Podman 5.x), whose tags are chosen by `scripts/resolve_versions.sh` from a policy file with series caps and a soak period, and nightly (upstream HEAD).
- On stable and v5, pasta is built from the newest soaked passt release and versioned by its release date (`20261002`). Nightly builds passt `master`.
- Version suffix `~deb12.podmanN` / `~deb13.podmanN`, with orderings checked by `scripts/verify_versions.sh`. Nightly versions use a `~~git` marker so they sort below the tagged release.
- Distro table in `config.sh` as the single list of supported releases. The CI matrix, smoke tests, republish check and repository page read it.
- Distro detection that accepts the codename or the VERSION_ID and rejects other distributions, Debian testing and unstable, and architectures other than amd64.
- GitHub Actions workflow that builds each release in a clean Debian container, checks repository integrity, installs the result in Debian containers (fresh install, migration from Debian's podman, upgrade from the live repository), and deploys to Pages in one step.
- Lint workflow (ShellCheck, shfmt, unit tests, gitleaks), pre-commit configuration, Dependabot, and issue and pull request templates.
- Rust (sccache) and C (ccache) compiler caches in CI, keyed by distro, architecture, track, Rust version and sccache version, with bounded sizes. `CACHE_STRICT=true` fails a build whose enabled wrapper is missing, and each build cell checks that the caches saw compile requests. The sccache download is checked against a pinned SHA256.
- `scripts/ci_helpers.sh`, shared CI helpers that tests can call directly, and `tests/lib/mock_http_server.py`, a mock server that injects HTTP errors and cut-off downloads.

### Changed

- Workflow runs queue per track (`queue: max`) instead of replacing pending runs, and publish jobs share one `pages-deploy` queue, so only one run assembles and deploys at a time. The publish job waits until the deploy reaches the live site.
- The stable/v5 resolver runs once per run, in `resolve-track`. The republish guard and the build cells validate and use its output. A resolver hold now skips the build and publish cleanly, even with `force_rebuild`.
- The nightly cron's change detection keeps one checkpoint per distro of the commits that were built and deployed. It is saved only after a successful deploy and only for the distros that were published.
- The publish job reads each build cell's conclusion, publishes and smoke-tests only the distros whose cell succeeded, and fails if a successful cell's artifact did not download.
- Each workflow job gets only the permissions it needs, and no checkout keeps its credentials.
- The republish guard also compares `podman-suite`.
- The lint workflow installs reprepro, gpg and dpkg-dev and sets `REQUIRE_INTEGRATION_DEPS=1`, so the integration tests run instead of skipping.
- `podman-podman` recommends `dbus-user-session`, as Debian's `podman` does. Without a per-user D-Bus socket, rootless Podman on a minimal system falls back to the cgroupfs cgroup manager. The packaging revision goes to 2 (`~deb12.podman2`, `~deb13.podman2`) so both releases republish. `apt upgrade` installs the new Recommends; `apt-get upgrade` and unattended-upgrades do not, so `docs/apt-repository.md` tells those hosts to install it. The repository smoke test checks that a fresh install gets it.

### Fixed

- A network error, HTTP 5xx or 429, or a cut-off download from the live repository no longer makes a suite look unpublished or silently drops a package. Downloads are retried and then stop the publish.
- A rebuilt package with the same name, version and architecture as one in the live target suite no longer replaces the published file; the published bytes are kept.
- Regenerated suites keep the previous generation of their indexes under `by-hash/`, so a client holding the old `Release` during a deploy still finds them.
- A failing `gpg --clearsign` is no longer hidden by a successful detached signature. Signing failures stop the publish, and the integrity gate checks every suite's signatures against the published key.
- The integrity gate fails on a `Release` without `Suite`, `Codename`, a `SHA256` section or a `Packages` entry per architecture, and on a `Packages` stanza without `Size` or `SHA256`.
- The README's example `.sources` block used `stable-bookworm` while the text told Debian 13 users to pick `stable-trixie`. It now fills in the suite from `/etc/os-release`, and so do the track-switch examples in the README and `docs/apt-repository.md`, which hard-coded `stable-bookworm`.
- The smoke test reads the assembled repository with `Signed-By` instead of `Trusted: yes`, fails on a network error while probing the live repository instead of skipping the upgrade scenario, and checks the installed versions after the upgrade.

[Unreleased]: https://github.com/slazarov/podman-debian/commits/main
