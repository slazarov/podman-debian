---
phase: 11-build-container-libs
plan: 01
subsystem: infra
tags: [container-libs, seccomp, podman, go, bash, build-system]

# Dependency graph
requires:
  - phase: 10-tech-debt-cleanup
    provides: "Clean codebase with consistent patterns for new component scripts"
provides:
  - "build_container-libs.sh script that clones and builds container-libs"
  - "seccomp.json generated artifact ready for installation"
  - "CONTAINER_LIBS_TAG config variable for version pinning"
affects: [12-install-configuration-files, 13-man-pages-and-uninstall]

# Tech tracking
tech-stack:
  added: [container-libs]
  patterns: [go-codegen-build-target]

key-files:
  created:
    - scripts/build_container-libs.sh
  modified:
    - config.sh
    - setup.sh
    - scripts/install_dependencies.sh

key-decisions:
  - "Target only make seccomp.json, not make all or make install -- only the seccomp profile artifact is needed"
  - "Place container-libs build after go-md2man and before netavark in setup.sh build order"

patterns-established:
  - "Build-only scripts: scripts that build artifacts without installing them, deferring installation to a later phase"

requirements-completed: [BUILD-01, BUILD-02, BUILD-03]

# Metrics
duration: 2min
completed: 2026-03-04
---

# Phase 11 Plan 01: Build container-libs Summary

**Build script for container-libs that clones from GitHub, runs Go codegen to generate seccomp.json, and is wired into setup.sh build order after go-md2man**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-04T09:58:42Z
- **Completed:** 2026-03-04T10:01:05Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Created build_container-libs.sh following exact project conventions (boilerplate, step tracking, logging)
- Added CONTAINER_LIBS_TAG to config.sh following the same empty-default pattern as all other component tags
- Wired container-libs build into setup.sh at the correct position in the build order
- Build script targets only `make seccomp.json` (Go codegen) and verifies the artifact exists post-build

## Task Commits

Each task was committed atomically:

1. **Task 1: Create build_container-libs.sh and add config variable** - `51e1d99` (feat)
2. **Task 2: Wire build_container-libs.sh into setup.sh** - `63439f0` (feat)

## Files Created/Modified
- `scripts/build_container-libs.sh` - Build script that clones container-libs, checks out tag, runs make seccomp.json, verifies artifact
- `config.sh` - Added CONTAINER_LIBS_TAG version variable
- `setup.sh` - Added run_script call for build_container-libs.sh after go-md2man
- `scripts/install_dependencies.sh` - Added comment noting libseccomp-dev is also required by container-libs

## Decisions Made
- Target only `make seccomp.json` instead of full build -- we only need the seccomp profile, not all container-libs artifacts
- Placed container-libs after go-md2man and before netavark/podman in the build order to ensure Go toolchain availability and artifact readiness

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- seccomp.json artifact will be generated in build/container-libs/ during setup
- Phase 12 can install seccomp.json and other config files to their system paths
- CONTAINER_LIBS_TAG can be pinned by users or auto-detected (empty default = latest tag)

## Self-Check: PASSED

All files exist, all commits verified, all content checks passed.

---
*Phase: 11-build-container-libs*
*Completed: 2026-03-04*
