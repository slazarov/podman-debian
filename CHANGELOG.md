# Changelog

Notable changes to this project are recorded here, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This file covers the build and publishing pipeline. Package versions follow upstream and are listed on the [repository page](https://slazarov.github.io/podman-debian/).

## [Unreleased]

### Added

- Build pipeline for the Podman stack (12 components) from upstream source on Debian 12 (bookworm) and Debian 13 (trixie), amd64.
- `podman-*` packages built with nFPM. They declare `Conflicts`, `Replaces` and `Provides` against Debian's own packages, and their library dependencies are detected from the built binaries.
- Signed APT repository on GitHub Pages, built with reprepro, with `Acquire-By-Hash` indexes and six suites: `{stable,v5,nightly}-{bookworm,trixie}`.
- Three tracks: stable (Podman 6.x) and v5 (Podman 5.x), whose tags are chosen by `scripts/resolve_versions.sh` from a policy file with series caps and a soak period, and nightly (upstream HEAD).
- Version suffix `~deb12.podmanN` / `~deb13.podmanN`, with orderings checked by `scripts/verify_versions.sh`. Nightly versions use a `~~git` marker so they sort below the tagged release.
- Distro table in `config.sh` as the single list of supported releases. The CI matrix, smoke tests, republish check and repository page read it.
- Distro detection that accepts the codename or the VERSION_ID and rejects other distributions, Debian testing and unstable, and architectures other than amd64.
- GitHub Actions workflow that builds each release in a clean Debian container, checks repository integrity, installs the result in Debian containers (fresh install, migration from Debian's podman, upgrade from the live repository), and deploys to Pages in one step.
- Lint workflow (ShellCheck, shfmt, unit tests, gitleaks), pre-commit configuration, Dependabot, and issue and pull request templates.

[Unreleased]: https://github.com/slazarov/podman-debian/commits/main
