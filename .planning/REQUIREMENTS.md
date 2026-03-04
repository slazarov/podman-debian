# Requirements: Podman Debian Compiler

**Defined:** 2026-03-04
**Core Value:** Compile and install Podman on any Debian/Ubuntu system without user interaction.

## v1.2 Requirements

Requirements for v1.2 Include Common Libraries. Each maps to roadmap phases.

### Build Integration

- [x] **BUILD-01**: container-libs is cloned from source and built during setup
- [x] **BUILD-02**: seccomp.json is generated via container-libs Go codegen (`make seccomp.json`)
- [x] **BUILD-03**: Required C build dependencies (libgpgme-dev, libseccomp-dev) are installed automatically

### Configuration

- [ ] **CONFIG-01**: seccomp.json is installed to `/usr/share/containers/seccomp.json`
- [ ] **CONFIG-02**: policy.json is installed to `/etc/containers/policy.json`
- [ ] **CONFIG-03**: default.yaml is installed to `/etc/containers/registries.d/default.yaml`
- [ ] **CONFIG-04**: storage.conf is installed to `/etc/containers/storage.conf`
- [ ] **CONFIG-05**: registries.conf is installed to `/etc/containers/registries.conf`

### Documentation

- [ ] **DOCS-01**: Man pages from common and image libraries are installed to system man paths

### Uninstall

- [ ] **UNINST-01**: Uninstall script removes all container-libs installed files and build directory

## Future Requirements

None identified for v1.2.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Building container-libs Go libraries as importable packages | We only need the config files and generated artifacts, not the Go API |
| Custom seccomp profile modifications | Default upstream profile is sufficient |
| Registry mirror configuration | Template registries.conf is installed; user configures mirrors post-install |
| Shortnames configuration (registries.conf.d) | Only Red Hat-specific shortnames exist in repo; not relevant for Debian |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUILD-01 | Phase 11 | Complete |
| BUILD-02 | Phase 11 | Complete |
| BUILD-03 | Phase 11 | Complete |
| CONFIG-01 | Phase 12 | Pending |
| CONFIG-02 | Phase 12 | Pending |
| CONFIG-03 | Phase 12 | Pending |
| CONFIG-04 | Phase 12 | Pending |
| CONFIG-05 | Phase 12 | Pending |
| DOCS-01 | Phase 13 | Pending |
| UNINST-01 | Phase 13 | Pending |

**Coverage:**
- v1.2 requirements: 10 total
- Mapped to phases: 10
- Unmapped: 0

---
*Requirements defined: 2026-03-04*
*Last updated: 2026-03-04 after roadmap creation*
