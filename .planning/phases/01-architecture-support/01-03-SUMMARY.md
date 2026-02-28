---
phase: 01-architecture-support
plan: 03
subsystem: protoc-installer
tags: [architecture, protoc, arm64, amd64]
dependency_graph:
  requires: [01-01]
  provides: [architecture-aware-protoc-installation]
  affects: [scripts/install_protoc.sh]
tech-stack:
  added: []
  patterns: [variable-expansion, architecture-detection]
key-files:
  created: []
  modified:
    - scripts/install_protoc.sh
decisions:
  - Use ${PROTOC_ARCH} variable for dynamic architecture selection in download URL
  - Use generic protoc.zip filename to simplify script logic
metrics:
  duration: 1 min
  completed_date: 2026-02-28
---

# Phase 1 Plan 3: Protoc Architecture-Aware Download Summary

## One-Liner

Updated Protoc installer to use ${PROTOC_ARCH} variable for architecture-aware binary downloads, enabling installation on both amd64 and ARM64 systems.

## What Changed

### Files Modified

| File | Change | Lines |
|------|--------|-------|
| scripts/install_protoc.sh | Replaced hardcoded x86_64 with ${PROTOC_ARCH} variable | 6 |

### Key Changes

1. **Dynamic architecture in download URL**
   - Changed from hardcoded `linux-x86_64.zip` to `linux-${PROTOC_ARCH}.zip`
   - Uses PROTOC_ARCH variable set in config.sh (mapped from ARCH)

2. **Simplified output filename**
   - Changed from architecture-specific `protoc-${PROTOC_VERSION}-linux-x86_64.zip` to generic `protoc.zip`
   - Cleaner script with fewer variable interpolations

3. **Improved variable quoting**
   - Added quotes around variables in mkdir and unzip commands for safety

## Deviations from Plan

None - plan executed exactly as written.

## Verification Results

| Check | Result |
|-------|--------|
| PROTOC_ARCH variable used | PASS |
| No hardcoded x86_64 | PASS |
| Bash syntax valid | PASS |
| Symlink/PATH unchanged | PASS |

## Technical Details

### URL Pattern Change

**Before:**
```bash
wget https://github.com/protocolbuffers/protobuf/releases/download/${PROTOC_TAG}/protoc-${PROTOC_VERSION}-linux-x86_64.zip -O protoc-${PROTOC_VERSION}-linux-x86_64.zip
```

**After:**
```bash
wget "https://github.com/protocolbuffers/protobuf/releases/download/${PROTOC_TAG}/protoc-${PROTOC_VERSION}-linux-${PROTOC_ARCH}.zip" -O protoc.zip
```

### Architecture Mapping (from config.sh)

- `amd64` -> `x86_64` -> downloads `protoc-VERSION-linux-x86_64.zip`
- `arm64` -> `aarch_64` -> downloads `protoc-VERSION-linux-aarch_64.zip`

## Commits

- 4eac842: feat(01-03): use architecture-aware PROTOC_ARCH variable in protoc installer
- 446bb62: docs(01-03): complete protoc architecture-aware installation plan

## Self-Check: PASSED

- [x] SUMMARY.md exists at .planning/phases/01-architecture-support/01-03-SUMMARY.md
- [x] Commit 4eac842 exists in git history
- [x] scripts/install_protoc.sh modified and committed
- [x] REQUIREMENTS.md updated with ARCH-03 complete
- [x] ROADMAP.md updated with plan 01-03 progress
