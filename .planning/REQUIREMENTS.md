# Requirements: Podman Ubuntu Compiler

**Defined:** 2026-03-04
**Core Value:** Compile and install Podman on any Debian/Ubuntu system without user interaction.

## v2.0 Requirements

Requirements for APT Packaging & CI/CD milestone. Each maps to roadmap phases.

### Packaging

- [x] **PKG-01**: User can install each component as an individual .deb package with podman-* prefix (podman-podman, podman-crun, podman-netavark, podman-aardvark-dns, podman-conmon, podman-pasta, podman-fuse-overlayfs, podman-catatonit, podman-buildah, podman-skopeo, podman-toolbox, podman-container-configs)
- [x] **PKG-02**: Each package declares Conflicts/Replaces/Provides against the corresponding official Ubuntu package name
- [x] **PKG-03**: Package dependencies are correctly declared (e.g. podman-podman depends on podman-crun, podman-netavark, podman-aardvark-dns, podman-conmon, podman-pasta, podman-fuse-overlayfs, podman-container-configs)
- [x] **PKG-04**: Each component has an nFPM YAML config with version and architecture substitution via placeholders
- [x] **PKG-05**: Build scripts support DESTDIR environment variable for staging-based packaging without modifying direct-install behavior
- [x] **PKG-06**: Meta-package podman-suite installs entire Podman stack with one command (depends on all individual packages)
- [x] **PKG-07**: Config files in /etc/containers/ are declared as conffiles so user modifications are preserved on upgrade

### CI/CD

- [ ] **CICD-01**: GitHub Actions build workflow compiles and packages all components for both architectures
- [ ] **CICD-02**: Builds run on native runners: ubuntu-24.04 for amd64, ubuntu-24.04-arm for arm64
- [ ] **CICD-03**: Builds can be triggered manually via workflow_dispatch
- [x] **CICD-04**: Two build tracks exist: stable (user-pinned versions) and edge (latest upstream tags)

### APT Repository

- [x] **REPO-01**: APT repository is hosted on GitHub Pages with reprepro-generated structure (dists/, pool/)
- [x] **REPO-02**: Repository is GPG-signed with Ed25519 key (InRelease + Release.gpg)
- [x] **REPO-03**: Repository serves two suites in one URL: stable and edge
- [x] **REPO-04**: User setup instructions document DEB822 .sources config, GPG key import via signed-by, and install commands
- [x] **REPO-05**: Public GPG key is published in the repository root for user download

### Automation

- [ ] **AUTO-01**: Scheduled cron workflow checks upstream GitHub repos for new release tags daily
- [ ] **AUTO-02**: New upstream versions auto-trigger edge suite builds
- [ ] **AUTO-03**: versions.json tracks last-built version per component for both stable and edge suites

## Future Requirements

Deferred to future release. Tracked but not in current roadmap.

### Distribution Expansion

- **DIST-01**: User can install packages on Ubuntu 22.04 (additional codename in reprepro)
- **DIST-02**: User can install packages on Debian 12 bookworm

### Quality

- **QUAL-01**: Installed packages pass lintian checks in CI
- **QUAL-02**: CI runs `podman run hello-world` after package installation as smoke test

### User Experience

- **UX-01**: One-line setup script (curl | bash) for simplified onboarding
- **UX-02**: Changelog generation from upstream release notes for `apt changelog` support

## Out of Scope

| Feature | Reason |
|---------|--------|
| Multi-distro support (Debian 12, Ubuntu 22.04) | Keep v2.0 focused on Ubuntu 24.04 only; add if demand materializes |
| Source packages (dpkg-buildpackage) | We wrap pre-built binaries; source packaging duplicates existing build system |
| RPM packages | Debian/Ubuntu focus only |
| QEMU emulation for ARM64 | Native runners available; QEMU is 10-30x slower and unreliable |
| CDN/CloudFront distribution | GitHub Pages sufficient for current scale |
| Private repository | Public repo simplifies access and enables free ARM64 runners |
| GUI package manager integration | CLI-focused project |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PKG-01 | Phase 14 | Complete |
| PKG-02 | Phase 14 | Complete |
| PKG-03 | Phase 14 | Complete |
| PKG-04 | Phase 14 | Complete |
| PKG-05 | Phase 14 | Complete |
| PKG-06 | Phase 14 | Complete |
| PKG-07 | Phase 14 | Complete |
| CICD-01 | Phase 16 | Pending |
| CICD-02 | Phase 16 | Pending |
| CICD-03 | Phase 16 | Pending |
| CICD-04 | Phase 16 | Complete |
| REPO-01 | Phase 15 | Complete |
| REPO-02 | Phase 15 | Complete |
| REPO-03 | Phase 15 | Complete |
| REPO-04 | Phase 15 | Complete |
| REPO-05 | Phase 15 | Complete |
| AUTO-01 | Phase 17 | Pending |
| AUTO-02 | Phase 17 | Pending |
| AUTO-03 | Phase 17 | Pending |

**Coverage:**
- v2.0 requirements: 19 total
- Mapped to phases: 19
- Unmapped: 0

---
*Requirements defined: 2026-03-04*
*Last updated: 2026-03-04 after roadmap creation*
