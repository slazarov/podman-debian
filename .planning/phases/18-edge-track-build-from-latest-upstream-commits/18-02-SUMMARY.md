---
phase: 18-edge-track-build-from-latest-upstream-commits
plan: 02
subsystem: ci
tags: [github-actions, cron, nightly, reprepro, apt, ci-cd]

# Dependency graph
requires:
  - phase: 18-01
    provides: "versions-nightly.env, nightly version extraction, git_checkout nightly mode, distributions config with nightly stanza"
provides:
  - "Three-suite CI publisher (stable, edge, nightly) with multi-suite preservation"
  - "GitHub Actions workflow with nightly option and daily cron schedule"
  - "Landing page with nightly track description and setup tab"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Multi-suite preservation via associative arrays (OTHER_SUITES loop)"
    - "Workflow track resolution step for cron vs manual dispatch"
    - "Inlined nightly env vars in workflow (avoid sudo env sourcing complexity)"

key-files:
  created: []
  modified:
    - scripts/ci_publish.sh
    - .github/workflows/build-packages.yml

key-decisions:
  - "Nightly env values inlined in workflow rather than sourced from versions-nightly.env to avoid sudo env sourcing complexity"
  - "Removed redundant Set version tags step from build jobs (already handled inline in Build step)"
  - "Go cache key uses track + run_number for better cache isolation between tracks"

patterns-established:
  - "Multi-suite publisher: ALL_SUITES array with OTHER_SUITES exclusion pattern"
  - "Track resolution: steps.track.outputs.track defaults to nightly for cron-triggered runs"

requirements-completed: [EDGE-04, EDGE-05]

# Metrics
duration: 4min
completed: 2026-03-06
---

# Phase 18 Plan 02: CI/CD Nightly Pipeline Summary

**Three-suite CI publisher with daily cron scheduling, multi-suite package preservation, and nightly track on landing page**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-06T12:03:32Z
- **Completed:** 2026-03-06T12:07:51Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Updated ci_publish.sh to handle three suites (stable, edge, nightly) with two non-current suites preserved during each publish
- Added daily cron schedule (4:30 AM UTC) and nightly build track to GitHub Actions workflow
- Added nightly track description and setup tab to the landing page HTML
- Removed redundant "Set version tags" step from both build jobs

## Task Commits

Each task was committed atomically:

1. **Task 1: Update ci_publish.sh for three-suite handling** - `81e2b61` (feat)
2. **Task 2: Add nightly option and cron trigger to GitHub Actions workflow** - `c9b4314` (feat)

## Files Created/Modified
- `scripts/ci_publish.sh` - Three-suite publisher with OTHER_SUITES array, nightly validation, nightly landing page tab
- `.github/workflows/build-packages.yml` - Nightly build track option, cron trigger, track resolution step, NIGHTLY_BUILD env passing

## Decisions Made
- Nightly env values (NIGHTLY_BUILD=true, SHALLOW_CLONE=false) inlined in workflow steps rather than sourced from versions-nightly.env, matching the established pattern for stable env sourcing and avoiding sudo env complexity
- Removed the standalone "Set version tags (stable)" step from both build jobs since the same logic already exists inline in the "Build all components" step, eliminating the GITHUB_ENV quote-stripping bugs from phase 16
- Updated Go cache key from `hashFiles('versions-stable.env')` to `track-run_number` for proper cache isolation between stable/edge/nightly tracks

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 18 complete: nightly build infrastructure is fully integrated into the CI/CD pipeline
- The workflow can now be triggered manually with any of three tracks (stable, edge, nightly) or automatically via daily cron for nightly builds
- Ready for end-to-end testing via GitHub Actions workflow dispatch

## Self-Check: PASSED

- All 2 source files found on disk
- Both task commits verified in git log (81e2b61, c9b4314)
- SUMMARY.md exists at expected path

---
*Phase: 18-edge-track-build-from-latest-upstream-commits*
*Completed: 2026-03-06*
