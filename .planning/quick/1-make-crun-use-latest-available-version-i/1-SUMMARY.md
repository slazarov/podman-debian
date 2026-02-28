---
phase: quick
plan: 1
subsystem: configuration
tags: [crun, versioning, consistency, auto-detection]
dependency_graph:
  requires: []
  provides: [crun-latest-version-detection]
  affects: [config.sh.example, functions.sh]
tech_stack:
  added: []
  patterns: [bash-parameter-expansion, regex-version-matching]
key_files:
  created: []
  modified:
    - path: config.sh.example
      change: Updated CRUN_TAG to use ${CRUN_TAG:-} pattern
    - path: functions.sh
      change: Updated get_latest_tag regex to support numeric-only tags
decisions:
  - Use consistent ${TAG:-} pattern across all components for version handling
  - Update regex to handle both v-prefixed and numeric-only tag formats
metrics:
  duration: 5 min
  completed_date: 2026-02-28
  commits: 3
  files_modified: 2
---

# Quick Task 1: Make CRUN Use Latest Available Version Summary

## One-liner

Updated CRUN configuration to use consistent version pattern and enabled get_latest_tag function to detect numeric-only tags (crun uses `1.26` format instead of `v1.26`).

## Changes Made

### Task 1: Update CRUN_TAG pattern in config.sh.example

Changed the CRUN version configuration from hardcoded values to the consistent pattern used by all other components:

**Before:**
```bash
# Crun Version
export CRUN_VERSION="1.25.1"
export CRUN_TAG="${CRUN_VERSION}"
```

**After:**
```bash
# Crun Version
#export CRUN_VERSION="1.25.1"
#export CRUN_TAG="${CRUN_VERSION}"
export CRUN_TAG="${CRUN_TAG:-}"
```

This allows:
- Environment variable override: `CRUN_TAG=1.26 ./install.sh`
- Auto-detection of latest version when not specified

### Task 2: Update get_latest_tag to support numeric-only tags

Modified the regex in `get_latest_tag()` function to match both tag formats:

**Before:**
```bash
latest=$(git tag --list --sort -creatordate | grep -v rc | grep -E ^v | sort --reverse --version-sort | head -n1)
```

**After (initial):**
```bash
latest=$(git tag --list --sort -creatordate | grep -v rc | grep -E '^(v)?[0-9]' | sort --reverse --version-sort | head -n1)
```

**After (final fix):**
```bash
# Handle both v-prefixed (v5.5.2) and numeric-only (1.26) tags
# Sort by version (stripping v prefix for comparison) while preserving original tag name
latest=$(git tag --list --sort -creatordate | grep -v rc | grep -E '^v?[0-9]' | \
         while read tag; do echo "${tag#v} $tag"; done | \
         sort --reverse --version-sort -k1 | head -n1 | cut -d' ' -f2)
```

The initial regex `^(v)?[0-9]` matched both formats but `sort --version-sort` treats numeric-only and v-prefixed tags as separate groups, causing incorrect ordering (v0.3 appeared before 1.26).

The final fix strips the `v` prefix for sorting comparison while preserving the original tag name in output:
- v-prefixed tags: `v5.5.2`, `v1.40.1`, `v1.4.0`
- Numeric-only tags: `1.26`, `1.25.1` (crun's format)

## Verification Results

All verification steps passed:
- CRUN_TAG pattern matches other components
- CRUN_VERSION is properly commented out
- get_latest_tag regex updated correctly
- Both files pass bash syntax check (`bash -n`)

## Deviations from Plan

Initial implementation had a bug: `sort --version-sort` treats numeric-only and v-prefixed tags as separate groups, causing incorrect ordering for crun (v0.3 appeared before 1.26).

**Fix:** Strip `v` prefix for sorting comparison while preserving original tag name in output.

## Testing Results

Tested in Lima VM (`limactl shell 3pl-dev`):
- `get_latest_tag` for crun returns `1.26` ✓
- `get_latest_tag` for podman returns `v5.8.0` ✓

Build test failed due to missing `pkg-config` dependency in VM (unrelated to changes).

## Self-Check: PASSED

- Files modified: config.sh.example, functions.sh
- Commits created: 2d70f2f, d99b83e, 0f17912
- All verification criteria met
- Bug discovered in testing and fixed
