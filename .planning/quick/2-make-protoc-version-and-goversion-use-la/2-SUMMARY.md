---
gsd_state_version: 1.0
phase: quick
plan: 2
subsystem: version-detection
tags: [protoc, go, auto-detection, api, consistency]
dependencies:
  requires: []
  provides: [proto-version-detection, go-version-detection]
  affects: [install_protoc.sh, install_go.sh]
tech_stack:
  added: [curl-api-calls, json-parsing]
  patterns: [env-override, api-version-detection]
key_files:
  created: []
  modified:
    - functions.sh
    - config.sh.example
    - scripts/install_protoc.sh
    - scripts/install_go.sh
decisions:
  - Use curl with grep/sed for API parsing (no jq dependency)
  - Return clean version strings without prefixes
  - Derive GOTAG, GOPATH, GOROOT from detected GOVERSION
  - Derive PROTOC_TAG from detected PROTOC_VERSION
metrics:
  duration: 2 min
  completed_date: 2026-02-28
  tasks_completed: 5
  files_modified: 4
---

# Quick Task 2: PROTOC and GO Version Auto-Detection

## One-Liner

PROTOC_VERSION and GOVERSION now use the same auto-detection pattern as CRUN_TAG and PODMAN_TAG - empty by default, fetch latest from API when not specified.

## Summary of Changes

### Files Modified

1. **functions.sh** - Added two new version detection functions:
   - `get_latest_protoc_version()` - Fetches latest protoc release from GitHub API
   - `get_latest_go_version()` - Fetches latest Go version from go.dev JSON API

2. **config.sh.example** - Updated version variables to use `${VAR:-}` pattern:
   - PROTOC_VERSION and PROTOC_TAG now default to empty
   - GOVERSION now defaults to empty (GOTAG derived at runtime)

3. **scripts/install_protoc.sh** - Added auto-detection logic:
   - Calls `get_latest_protoc_version()` when PROTOC_VERSION is empty
   - Derives PROTOC_TAG from PROTOC_VERSION

4. **scripts/install_go.sh** - Added auto-detection logic:
   - Calls `get_latest_go_version()` when GOVERSION is empty
   - Derives GOTAG, GOPATH, and GOROOT from detected version

## Tasks Completed

| Task | Description | Commit | Status |
|------|-------------|--------|--------|
| 1 | Add version detection functions to functions.sh | cf7f18f | Done |
| 2-3 | Update config.sh.example for PROTOC_VERSION/GOVERSION auto-detection | ea7c815 | Done |
| 4 | Update install_protoc.sh to detect version if not set | 2610a1d | Done |
| 5 | Update install_go.sh to detect version if not set | 1fc59fb | Done |

## Implementation Details

### API Endpoints Used

- **Go**: `https://go.dev/dl/?mode=json` - Returns JSON with `"version": "go1.26.0"` field
- **Protobuf**: `https://api.github.com/repos/protocolbuffers/protobuf/releases/latest` - Returns JSON with `"tag_name": "v34.0"` field

### Version String Handling

Both functions strip prefixes to return clean version numbers:
- protoc: `"v34.0"` -> `"34.0"`
- go: `"go1.26.0"` -> `"1.26.0"`

### Pattern Consistency

All version variables now follow the same pattern:

```bash
# Before (hardcoded)
export GOVERSION="1.23.3"

# After (auto-detect or override)
export GOVERSION="${GOVERSION:-}"
```

## Deviations from Plan

None - plan executed exactly as written.

## Success Criteria Verification

- [x] PROTOC_VERSION and GOVERSION follow the same pattern as CRUN_TAG, PODMAN_TAG, etc.
- [x] Both support environment variable override
- [x] Both auto-detect latest version when not specified
- [x] No breaking changes to existing functionality

## Self-Check

All files verified:
- `functions.sh`: EXISTS, syntax valid
- `config.sh.example`: EXISTS, syntax valid
- `scripts/install_protoc.sh`: EXISTS, syntax valid
- `scripts/install_go.sh`: EXISTS, syntax valid

All commits verified:
- cf7f18f: feat(quick-2): add version detection functions for protoc and go
- ea7c815: feat(quick-2): update PROTOC_VERSION and GOVERSION for auto-detection
- 2610a1d: feat(quick-2): add auto-detection to install_protoc.sh
- 1fc59fb: feat(quick-2): add auto-detection to install_go.sh

## Self-Check: PASSED
