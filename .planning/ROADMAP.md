# Roadmap: Podman Debian Compiler

## Milestones

- **v1.0 MVP** - Phases 1-5 (shipped 2026-03-03)
- **v1.1 Ecosystem Audit** - Phases 6-10 (in progress)

## Phases

<details>
<summary>v1.0 MVP (Phases 1-5) - SHIPPED 2026-03-03</summary>

- [x] Phase 1: Architecture Support (4/4 plans) - completed 2026-03-03
- [x] Phase 2: Non-Interactive Mode (1/1 plan) - completed 2026-03-03
- [x] Phase 3: Error Handling (3/3 plans) - completed 2026-03-03
- [x] Phase 4: User Experience (3/3 plans) - completed 2026-03-03
- [x] Phase 5: Build Time Optimization (2/2 plans) - completed 2026-03-03

</details>

### v1.1 Ecosystem Audit (In Progress - 2026-03-04)

**Milestone Goal:** Research and optimize the Podman build ecosystem - remove deprecated components, add pre-flight validation, and implement build caching.

- [x] **Phase 6: Component Cleanup** - Remove deprecated runc and slirp4netns components
- [x] **Phase 7: Pre-flight Validation** - Add system requirement checks before installation
- [x] **Phase 8: Build Optimization & Configuration** - Implement sccache and enhanced containers.conf
- [x] **Phase 10: Tech Debt Cleanup** - Resolve audit-identified integration gaps (mold/clang uninstall, redundant containers.conf copy)

## Phase Details

### Phase 6: Component Cleanup
**Goal**: Project no longer contains deprecated components that confuse users or waste build time
**Depends on**: Phase 5 (v1.0)
**Requirements**: CLNP-01, CLNP-02, CLNP-03
**Success Criteria** (what must be TRUE):
  1. User sees no build_runc.sh or build_slirp4netns.sh in scripts directory
  2. Running install.sh does not attempt to build runc or slirp4netns
  3. config.sh contains no references to runc or slirp4netns variables
**Plans**: 1 plan

Plans:
- [x] 06-01: Remove deprecated build scripts and references

### Phase 7: Pre-flight Validation
**Goal**: Installation fails early with clear messages when system does not meet requirements
**Depends on**: Phase 6
**Requirements**: VAL-01, VAL-02, VAL-03, VAL-04, VAL-05
**Success Criteria** (what must be TRUE):
  1. User without cgroups v2 sees clear error message before build starts
  2. User without subuid/subgid configuration sees warning about rootless mode
  3. User with noexec mount on /tmp or /home sees error before build fails
  4. All pre-flight checks complete in under 5 seconds
  5. Pre-flight check script can be run independently for system verification
**Plans**: 1 plan

Plans:
- [x] 07-01: Create pre-flight validation script

### Phase 8: Build Optimization & Configuration
**Goal**: Rust builds are cached for 50-90% rebuild speedup and containers.conf provides sensible defaults
**Depends on**: Phase 7
**Requirements**: BLD-01, BLD-02, BLD-03, BLD-04, CONF-01, CONF-02, CONF-03, CONF-04, CLNP-04
**Success Criteria** (what must be TRUE):
  1. User with SCCACHE_ENABLED=true sees Rust builds use sccache (verify with sccache --show-stats)
  2. Running install.sh creates /etc/containers/containers.conf with runtime=crun and network_backend=netavark
  3. Rebuilding netavark or aardvark-dns after first build completes 50-90% faster
  4. containers.conf includes seccomp_profile default configuration
  5. SCCACHE_ENABLED variable is functional (not dead code)
**Plans**: 2 plans

Plans:
- [x] 08-01: Implement sccache for Rust builds
- [x] 08-02: Enhance and install containers.conf

### Phase 9: Build Optimization - Go Cache, ccache, and mold
**Goal**: All three toolchains (Go, Rust, C) have layered build caching for dramatically faster rebuilds
**Depends on**: Phase 8
**Requirements**: CACHE-01, CACHE-02, CACHE-03, CACHE-04, CACHE-05, CACHE-06, CACHE-07, CACHE-08, CACHE-09
**Success Criteria** (what must be TRUE):
  1. Go build cache persists across component builds (podman, buildah, skopeo share cached artifacts)
  2. Go module cache persists across component builds (shared modules downloaded once)
  3. User with CCACHE_ENABLED=true sees C builds (crun, catatonit, fuse-overlayfs, pasta) use ccache
  4. User with MOLD_ENABLED=true sees Rust builds (netavark, aardvark-dns) use mold linker
  5. Default behavior unchanged (all new features disabled by default)
  6. All new cache directories are cleaned up during uninstall
**Plans**: 2 plans

Plans:
- [x] 09-01-PLAN.md -- Persist Go build/module cache across component builds
- [x] 09-02-PLAN.md -- Add ccache for C builds and mold linker for Rust builds

### Phase 10: Tech Debt Cleanup
**Goal**: Asymmetric cleanup and redundant operations identified by milestone audit are resolved
**Depends on**: Phase 9
**Requirements**: CACHE-07, CACHE-08, CONF-03 (integration gap closure)
**Gap Closure**: Closes MISSING-01 and BROKEN-01 from v1.1-MILESTONE-AUDIT.md
**Success Criteria** (what must be TRUE):
  1. Running uninstall.sh removes mold and clang apt packages when they were installed
  2. containers.conf is installed exactly once during setup (no redundant copy)
  3. All tech debt items from v1.1 audit are resolved
**Plans**: 1 plan

Plans:
- [x] 10-01-PLAN.md -- Add mold/clang uninstall cleanup and remove redundant containers.conf copy

## Progress

**Execution Order:**
Phases execute in numeric order: 6 -> 7 -> 8 -> 9 -> 10

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

---

*See `.planning/milestones/v1.0-ROADMAP.md` for archived v1.0 phase details.*
