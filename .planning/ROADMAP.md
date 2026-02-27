# Roadmap: Podman Debian Compiler

## Overview

This roadmap transforms the existing amd64-only Podman compiler into a cross-platform, fully unattended installation tool. The journey starts with architecture detection (enabling ARM support), adds non-interactive mode (enabling headless installs), implements reliable error handling (enabling debugging), and finishes with user experience improvements.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Architecture Support** - Enable Podman compilation on both amd64 and ARM64 systems
- [ ] **Phase 2: Non-Interactive Mode** - Remove all blocking prompts for unattended installation
- [ ] **Phase 3: Error Handling** - Ensure scripts fail loudly and clearly on any error
- [ ] **Phase 4: User Experience** - Provide progress feedback and operational confidence

## Phase Details

### Phase 1: Architecture Support
**Goal**: The script works on both amd64 and ARM64 systems without modification
**Depends on**: Nothing (first phase)
**Requirements**: ARCH-01, ARCH-02, ARCH-03, ARCH-04, ARCH-05
**Success Criteria** (what must be TRUE):
  1. User can run install.sh on an ARM64 Ubuntu/Debian system and Podman compiles successfully
  2. User can run install.sh on an amd64 system and Podman compiles successfully (existing behavior preserved)
  3. All toolchain installers (Go, Protoc, Rust) download architecture-appropriate binaries automatically
  4. A single variable in config.sh controls architecture selection for the entire build
**Plans**: 4 plans in 2 waves

Plans:
- [ ] 01-01-PLAN.md — Add architecture detection and vendor mappings to config.sh.example
- [ ] 01-02-PLAN.md — Update Go installer for ARM64 support
- [ ] 01-03-PLAN.md — Update Protoc installer for ARM64 support
- [ ] 01-04-PLAN.md — Update Rust installer for ARM64 support

### Phase 2: Non-Interactive Mode
**Goal**: The installation completes without any user interaction or blocking prompts
**Depends on**: Phase 1
**Requirements**: NINT-01, NINT-02, NINT-03, NINT-04
**Success Criteria** (what must be TRUE):
  1. User can start install.sh and walk away - it completes without any input
  2. No apt-get commands prompt for confirmation (all use -y flag)
  3. No package configuration dialogs appear during installation
  4. No script contains `read` or other blocking input commands
**Plans**: TBD

Plans:
- [ ] 02-01: Add DEBIAN_FRONTEND=noninteractive globally
- [ ] 02-02: Audit and fix all apt commands for -y flag
- [ ] 02-03: Pre-answer package configuration prompts with debconf
- [ ] 02-04: Remove or guard any read commands

### Phase 3: Error Handling
**Goal**: Any error immediately stops execution with a clear message identifying what failed
**Depends on**: Phase 2
**Requirements**: ERRO-01, ERRO-02, ERRO-03, ERRO-04
**Success Criteria** (what must be TRUE):
  1. If any script encounters an error, it exits immediately (no cascading silent failures)
  2. Error output identifies which script and operation failed
  3. install.sh shows clear summary when sub-scripts fail
  4. All scripts consistently use `set -e` (or `set -euo pipefail`)
**Plans**: TBD

Plans:
- [ ] 03-01: Enable set -e consistently across all scripts
- [ ] 03-02: Add error trap handlers with context
- [ ] 03-03: Propagate errors properly in install.sh

### Phase 4: User Experience
**Goal**: User has visibility into build progress and confidence in script operations
**Depends on**: Phase 3
**Requirements**: UX-01, UX-02, UX-03
**Success Criteria** (what must be TRUE):
  1. User sees progress messages indicating current operation during installation
  2. Build output is captured to log files for troubleshooting
  3. User can cleanly uninstall all installed components using an uninstall script
**Plans**: TBD

Plans:
- [ ] 04-01: Add progress messages throughout installation
- [ ] 04-02: Ensure build logging works correctly
- [ ] 04-03: Verify uninstall script works for all components

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Architecture Support | 0/4 | Ready to execute | - |
| 2. Non-Interactive Mode | 0/4 | Not started | - |
| 3. Error Handling | 0/3 | Not started | - |
| 4. User Experience | 0/3 | Not started | - |
