---
gsd_state_version: 1.0
milestone: v2.0
milestone_name: APT Packaging & CI/CD
status: executing
stopped_at: Completed 18-02-PLAN.md
last_updated: "2026-03-06T12:08:00Z"
last_activity: 2026-03-06 — Completed plan 18-02 (nightly CI pipeline, three-suite publisher)
progress:
  total_phases: 5
  completed_phases: 3
  total_plans: 8
  completed_plans: 8
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-04)

**Core value:** Compile and install Podman on any Debian/Ubuntu system without user interaction.
**Current focus:** Phase 18 — Edge Track: Build from Latest Upstream Commits

## Current Position

Phase: 18 (Edge Track: Build from Latest Upstream Commits)
Plan: 2 of 2 complete
Status: Phase complete
Last activity: 2026-03-06 — Completed plan 18-02 (nightly CI pipeline, three-suite publisher)

Progress: [██████████] 100%

## Performance Metrics

**Velocity:**
- Total plans completed: 8 (v2.0) / 30 (all milestones)
- Average duration: 3min
- Total execution time: 24min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 14. Debian Package Building | 2/2 | 8min | 4min |
| 15. APT Repository and Signing | 2/2 | 5min | 2.5min |
| 16. CI/CD Pipeline | 1/2 | 1min | 1min |
| 18. Edge Track: Build from Latest Upstream Commits | 2/2 | 10min | 5min |

## Previous Milestones

### v1.2 Include Common Libraries (Shipped 2026-03-04)
**Phases:** 3/3 | **Plans:** 3/3

### v1.1 Ecosystem Audit (Shipped 2026-03-04)
**Phases:** 5/5 | **Plans:** 7/7

### v1.0 MVP (Shipped 2026-03-03)
**Phases:** 5/5 | **Plans:** 13/13

## Accumulated Context

### Decisions

All decisions logged in PROJECT.md Key Decisions table.

- Phase 14-01: Switched conmon from `make podman` to `make install PREFIX=/usr` for proper DESTDIR support
- Phase 14-01: Used nFPM `type: tree` for glob-based directory inclusion (man pages, systemd units, completions)
- Phase 14-01: Pasta avx2 variants excluded from base nFPM config; orchestrator handles conditionally
- Phase 14-02: Used associative array for component-to-tag mapping rather than case statement
- Phase 14-02: Pasta version uses live date calculation matching build_pasta.sh pattern
- Phase 15-01: Used SignWith: yes instead of hardcoded fingerprint for GPG signing flexibility in CI
- Phase 15-01: Set Codename = Suite name (stable/edge) to avoid createsymlinks complexity
- Phase 15-01: Script exports public key from keyring if pubkey.gpg not yet committed
- Phase 15-02: Used Ed25519 algorithm for GPG key (smaller, faster, modern standard)
- Phase 15-02: Binary GPG public key format (not ASCII-armored) for APT signed-by compatibility
- Phase 16-01: Used curl -sfL with || true for graceful first-deploy handling (no live repo)
- Phase 16-01: Download other suite's .deb files to temp dir then add via reprepro includedeb
- Phase 18-01: Nightly versions use tilde (~git) convention for dpkg sort below tagged releases
- Phase 18-01: Pasta uses plain YYYYMMDD datestamp (no tilde) since already date-based
- Phase 18-01: extract_version_nightly is parallel code path, does not modify existing stable/edge functions
- Phase 18-01: git_checkout nightly mode detects default branch via git symbolic-ref with fallback to main
- Phase 18-02: Nightly env values inlined in workflow (not sourced from versions-nightly.env) to avoid sudo env sourcing complexity
- Phase 18-02: Removed redundant Set version tags step from build jobs (already handled inline in Build step)
- Phase 18-02: Go cache key uses track + run_number for better cache isolation between tracks

### Tech Debt
- Minor: install_dependencies.sh lacks DEBIAN_FRONTEND (relies on setup.sh)
- Minor: Circular sourcing pattern config.sh <-> functions.sh (guarded but fragile)

### Roadmap Evolution
- Phase 18 added: Edge Track: Build from Latest Upstream Commits

### Research Flags
- Phase 16: morph027/apt-repo-action import-from-repo-url multi-arch behavior needs validation
- Phase 17: pasta/passt date-based versioning and container-libs namespaced tags need specific parsing logic

### Blockers/Concerns

None yet.

## Session Continuity

Last session: 2026-03-06T12:08:00Z
Stopped at: Completed 18-02-PLAN.md (Phase 18 complete)
Resume file: None
