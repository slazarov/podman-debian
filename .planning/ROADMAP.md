# Roadmap: Podman Debian Compiler

## Milestones

- ✅ **v1.0 MVP** — Phases 1-5 (shipped 2026-03-03)
- ✅ **v1.1 Ecosystem Audit** — Phases 6-10 (shipped 2026-03-04)
- ✅ **v1.2 Include Common Libraries** — Phases 11-13 (shipped 2026-03-04)
- 🚧 **v2.0 APT Packaging & CI/CD** — Phases 14-17 (in progress)

## Phases

<details>
<summary>✅ v1.0 MVP (Phases 1-5) — SHIPPED 2026-03-03</summary>

- [x] Phase 1: Architecture Support (4/4 plans) — completed 2026-03-03
- [x] Phase 2: Non-Interactive Mode (1/1 plan) — completed 2026-03-03
- [x] Phase 3: Error Handling (3/3 plans) — completed 2026-03-03
- [x] Phase 4: User Experience (3/3 plans) — completed 2026-03-03
- [x] Phase 5: Build Time Optimization (2/2 plans) — completed 2026-03-03

</details>

<details>
<summary>✅ v1.1 Ecosystem Audit (Phases 6-10) — SHIPPED 2026-03-04</summary>

- [x] Phase 6: Component Cleanup (1/1 plan) — completed 2026-03-03
- [x] Phase 7: Pre-flight Validation (1/1 plan) — completed 2026-03-03
- [x] Phase 8: Build Optimization & Configuration (2/2 plans) — completed 2026-03-04
- [x] Phase 9: Build Optimization - Go Cache, ccache, mold (2/2 plans) — completed 2026-03-04
- [x] Phase 10: Tech Debt Cleanup (1/1 plan) — completed 2026-03-04

</details>

<details>
<summary>✅ v1.2 Include Common Libraries (Phases 11-13) — SHIPPED 2026-03-04</summary>

- [x] Phase 11: Build container-libs (1/1 plan) — completed 2026-03-04
- [x] Phase 12: Install Configuration Files (1/1 plan) — completed 2026-03-04
- [x] Phase 13: Man Pages and Uninstall (1/1 plan) — completed 2026-03-04

</details>

### v2.0 APT Packaging & CI/CD (In Progress)

**Milestone Goal:** Package all compiled Podman components as .deb packages, automate builds with GitHub Actions, and distribute via a GitHub Pages APT repository.

- [x] **Phase 14: Debian Package Building** — DESTDIR staging, nFPM configs, and verified .deb packages for all 12 components + meta-package (completed 2026-03-05)
- [x] **Phase 15: APT Repository and Signing** — GPG-signed reprepro repository with stable and edge suites, user setup documentation (completed 2026-03-05)
- [ ] **Phase 16: CI/CD Pipeline** — GitHub Actions workflows with native ARM64 runners, manual trigger, and dual build tracks
- [ ] **Phase 17: Upstream Automation** — Scheduled version detection, auto-triggered edge builds, and version state tracking

## Phase Details

### Phase 14: Debian Package Building
**Goal**: Users can install any Podman component or the full stack as .deb packages built from the existing build system
**Depends on**: Phase 13 (v1.2 complete build system)
**Requirements**: PKG-01, PKG-02, PKG-03, PKG-04, PKG-05, PKG-06, PKG-07
**Success Criteria** (what must be TRUE):
  1. Running a build script with DESTDIR set produces a complete filesystem staging tree without modifying the host system, and omitting DESTDIR preserves the existing direct-install behavior
  2. Each of the 12 component .deb packages installs cleanly via dpkg -i with correct file placement, and podman-suite meta-package pulls in all components via apt install
  3. Installing a podman-* package on a system with the corresponding official Ubuntu package succeeds without conflict (Conflicts/Replaces/Provides declarations work correctly)
  4. Upgrading podman-container-configs preserves user modifications to files in /etc/containers/ (conffiles declaration prompts dpkg merge)
  5. Each package declares correct inter-package dependencies so that apt install podman-podman automatically installs crun, conmon, netavark, aardvark-dns, pasta, fuse-overlayfs, and container-configs
**Plans**: 2 plans

Plans:
- [x] 14-01-PLAN.md — DESTDIR staging support in all build scripts + 13 nFPM YAML package configs
- [x] 14-02-PLAN.md — Packaging orchestrator script (version extraction, nFPM invocation)

### Phase 15: APT Repository and Signing
**Goal**: Users can add a GPG-signed APT repository and install packages via standard apt commands from either the stable or edge suite
**Depends on**: Phase 14
**Requirements**: REPO-01, REPO-02, REPO-03, REPO-04, REPO-05
**Success Criteria** (what must be TRUE):
  1. apt update against the repository URL succeeds without --allow-insecure-repositories or [trusted=yes] (GPG signature chain is valid: InRelease + Release.gpg both present and signed with Ed25519 key)
  2. Repository serves two suites (stable and edge) at the same URL, and apt install from either suite installs the correct package versions
  3. Following the documented DEB822 .sources setup instructions, a user on a fresh Ubuntu 24.04 system can add the repo, import the GPG key via signed-by, and install podman-suite in under 5 commands
  4. Public GPG key is downloadable from the repository root URL for user import
**Plans**: 2 plans

Plans:
- [x] 15-01-PLAN.md — Reprepro configuration, repository management script, and user setup documentation
- [x] 15-02-PLAN.md — GPG Ed25519 key generation and GitHub Secrets setup

### Phase 16: CI/CD Pipeline
**Goal**: Packages for both architectures are built and published to the APT repository automatically when a workflow is triggered
**Depends on**: Phase 15
**Requirements**: CICD-01, CICD-02, CICD-03, CICD-04
**Success Criteria** (what must be TRUE):
  1. Triggering workflow_dispatch builds .deb packages for all components on both amd64 (ubuntu-24.04) and arm64 (ubuntu-24.04-arm) native runners, and publishes them to the APT repository
  2. If either architecture build fails, the publish step does not run and the existing repository remains intact (atomic publishing)
  3. The workflow accepts a parameter choosing between stable (user-pinned versions) and edge (latest upstream tags) build tracks, producing packages in the corresponding APT suite
  4. Build artifacts (individual .deb files) are retained as downloadable GitHub Actions artifacts for debugging
**Plans**: 2 plans

Plans:
- [ ] 16-01-PLAN.md — Stable version pinning file and CI two-suite publish script
- [ ] 16-02-PLAN.md — GitHub Actions three-job workflow (build-amd64, build-arm64, publish)

### Phase 17: Upstream Automation
**Goal**: New upstream releases are detected automatically and trigger edge suite rebuilds without manual intervention
**Depends on**: Phase 16
**Requirements**: AUTO-01, AUTO-02, AUTO-03
**Success Criteria** (what must be TRUE):
  1. A daily cron workflow checks all upstream component repos for new release tags and correctly identifies when a newer version exists compared to what was last built
  2. When new upstream versions are detected, the edge build workflow is triggered automatically and produces updated packages in the edge suite
  3. versions.json accurately reflects the last-built version per component for both stable and edge suites, and is updated after each successful build
**Plans**: TBD

Plans:
- [ ] 17-01: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 14 -> 15 -> 16 -> 17

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
| 11. Build container-libs | v1.2 | 1/1 | Complete | 2026-03-04 |
| 12. Install Configuration Files | v1.2 | 1/1 | Complete | 2026-03-04 |
| 13. Man Pages and Uninstall | v1.2 | 1/1 | Complete | 2026-03-04 |
| 14. Debian Package Building | v2.0 | 2/2 | Complete | 2026-03-05 |
| 15. APT Repository and Signing | v2.0 | 2/2 | Complete | 2026-03-05 |
| 16. CI/CD Pipeline | 1/2 | In Progress|  | - |
| 17. Upstream Automation | v2.0 | 0/? | Not started | - |

### Phase 18: Edge Track: Build from Latest Upstream Commits

**Goal:** Users can install bleeding-edge packages built from the latest upstream commits via a nightly APT suite, with correct Debian snapshot versioning that auto-upgrades to tagged releases
**Requirements**: EDGE-01, EDGE-02, EDGE-03, EDGE-04, EDGE-05
**Depends on:** Phase 17
**Success Criteria** (what must be TRUE):
  1. Nightly version strings (e.g., 6.0.0~git20260306.abc1234~podman1) sort below tagged releases via dpkg, so users auto-upgrade when a real release lands
  2. Dev versions are correctly extracted from each upstream component's source files (version.go, Cargo.toml, configure.ac, VERSION, meson.build)
  3. Nightly .deb packages are valid and installable via dpkg -i
  4. reprepro accepts nightly packages into a dedicated nightly suite alongside stable and edge
  5. A daily cron workflow triggers nightly builds automatically, and the nightly track is also available via manual dispatch
**Plans**: 2 plans

Plans:
- [ ] 18-01-PLAN.md — Nightly env config, nightly-aware git_checkout, reprepro nightly suite, and dev version extraction in package_all.sh
- [ ] 18-02-PLAN.md — Three-suite CI publish script and GitHub Actions workflow with nightly option and cron trigger

---

*See `.planning/milestones/v1.0-ROADMAP.md` for archived v1.0 phase details.*
*See `.planning/milestones/v1.1-ROADMAP.md` for archived v1.1 phase details.*
*See `.planning/milestones/v1.2-ROADMAP.md` for archived v1.2 phase details.*
