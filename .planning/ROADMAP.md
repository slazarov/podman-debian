# Roadmap: Podman Debian Compiler

## Milestones

- **v1.0 MVP** - Phases 1-5 (shipped 2026-03-03)
- **v1.1 Ecosystem Audit** - Phases 6-10 (shipped 2026-03-04)
- **v1.2 Include Common Libraries** - Phases 11-13 (in progress)

## Phases

<details>
<summary>v1.0 MVP (Phases 1-5) - SHIPPED 2026-03-03</summary>

- [x] Phase 1: Architecture Support (4/4 plans) - completed 2026-03-03
- [x] Phase 2: Non-Interactive Mode (1/1 plan) - completed 2026-03-03
- [x] Phase 3: Error Handling (3/3 plans) - completed 2026-03-03
- [x] Phase 4: User Experience (3/3 plans) - completed 2026-03-03
- [x] Phase 5: Build Time Optimization (2/2 plans) - completed 2026-03-03

</details>

<details>
<summary>v1.1 Ecosystem Audit (Phases 6-10) - SHIPPED 2026-03-04</summary>

- [x] Phase 6: Component Cleanup (1/1 plan) - completed 2026-03-03
- [x] Phase 7: Pre-flight Validation (1/1 plan) - completed 2026-03-03
- [x] Phase 8: Build Optimization & Configuration (2/2 plans) - completed 2026-03-04
- [x] Phase 9: Build Optimization - Go Cache, ccache, mold (2/2 plans) - completed 2026-03-04
- [x] Phase 10: Tech Debt Cleanup (1/1 plan) - completed 2026-03-04

</details>

### v1.2 Include Common Libraries (In Progress)

- [ ] **Phase 11: Build container-libs** - Clone, install C dependencies, build container-libs and generate seccomp.json
- [ ] **Phase 12: Install Configuration Files** - Install all runtime config files to system paths
- [ ] **Phase 13: Man Pages and Uninstall** - Install man pages and extend uninstall to cover all new artifacts

## Phase Details

### Phase 11: Build container-libs
**Goal**: container-libs builds from source with all generated artifacts ready for installation
**Depends on**: Nothing (first phase of v1.2)
**Requirements**: BUILD-01, BUILD-02, BUILD-03
**Success Criteria** (what must be TRUE):
  1. Running the build script clones container-libs and completes without errors
  2. libgpgme-dev and libseccomp-dev are installed as build dependencies automatically
  3. seccomp.json exists as a generated artifact after build completes
**Plans:** 1 plan
Plans:
- [ ] 11-01-PLAN.md -- Create build_container-libs.sh, add config variable, wire into setup.sh

### Phase 12: Install Configuration Files
**Goal**: All container runtime config files are installed to their standard system paths
**Depends on**: Phase 11
**Requirements**: CONFIG-01, CONFIG-02, CONFIG-03, CONFIG-04, CONFIG-05
**Success Criteria** (what must be TRUE):
  1. seccomp.json exists at /usr/share/containers/seccomp.json and containers.conf reference resolves
  2. policy.json exists at /etc/containers/policy.json
  3. registries.d/default.yaml exists at /etc/containers/registries.d/default.yaml
  4. storage.conf exists at /etc/containers/storage.conf
  5. registries.conf exists at /etc/containers/registries.conf
**Plans**: TBD

### Phase 13: Man Pages and Uninstall
**Goal**: Config file documentation is accessible and all new artifacts are removable via uninstall
**Depends on**: Phase 12
**Requirements**: DOCS-01, UNINST-01
**Success Criteria** (what must be TRUE):
  1. Man pages for container config files are accessible via `man` command
  2. Running uninstall.sh removes all config files installed by Phase 12
  3. Running uninstall.sh removes the container-libs build directory
  4. After uninstall, none of the Phase 12 file paths exist on disk
**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Architecture Support | v1.0 | 4/4 | Complete | 2026-03-03 |
| 2. Non-Interactive Mode | v1.0 | 1/1 | Complete | 2026-03-03 |
| 3. Error Handling | v1.0 | 3/3 | Complete | 2026-03-03 |
| 4. User Experience | v1.0 | 3/3 | Complete | 2026-03-03 |
| 5. Build Time Optimization | v1.0 | 2/2 | Complete | 2026-03-03 |
| 6. Component Cleanup | v1.1 | 1/1 | Complete | 2026-03-03 |
| 7. Pre-flight Validation | v1.1 | 1/1 | Complete | 2026-03-03 |
| 8. Build Optimization & Configuration | v1.1 | 2/2 | Complete | 2026-03-04 |
| 9. Build Optimization - Go Cache, ccache, mold | v1.1 | 2/2 | Complete | 2026-03-04 |
| 10. Tech Debt Cleanup | v1.1 | 1/1 | Complete | 2026-03-04 |
| 11. Build container-libs | v1.2 | 0/1 | Planned | - |
| 12. Install Configuration Files | v1.2 | 0/? | Not started | - |
| 13. Man Pages and Uninstall | v1.2 | 0/? | Not started | - |

---

*See `.planning/milestones/v1.0-ROADMAP.md` for archived v1.0 phase details.*
*See `.planning/milestones/v1.1-ROADMAP.md` for archived v1.1 phase details.*
