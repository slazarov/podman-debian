---
phase: 13-man-pages-and-uninstall
plan: 01
subsystem: container-libs-manpages-uninstall
tags: [man-pages, uninstall, container-libs, go-md2man, cleanup]
dependency_graph:
  requires: [11-01, 12-01]
  provides: [man-page-install, container-libs-uninstall]
  affects: [setup.sh, uninstall.sh]
tech_stack:
  added: []
  patterns: [go-md2man-conversion, glob-based-cleanup, install-m0644]
key_files:
  created:
    - scripts/install_container-manpages.sh
  modified:
    - setup.sh
    - uninstall.sh
decisions:
  - Used glob patterns in uninstall.sh for container-libs man pages (consistent with existing patterns)
  - Installed .containerignore.5 alias alongside the 15 section-5 man pages
metrics:
  duration: 2min
  completed: "2026-03-04T11:27:35Z"
---

# Phase 13 Plan 01: Man Pages and Uninstall Summary

Container-libs man page build/install via go-md2man with full uninstall coverage for Phase 11-12 artifacts.

## What Was Done

### Task 1: Create install_container-manpages.sh and wire into setup.sh
**Commit:** `4bcd7c2`

Created `scripts/install_container-manpages.sh` following project conventions (boilerplate, step_start/step_done, install -m 0644). The script:

1. Iterates three source directories within `${BUILD_ROOT}/container-libs` to find all `.5.md` files:
   - `common/docs/*.5.md` (4 man pages: Containerfile, containerignore, containers-mounts.conf, containers.conf)
   - `image/docs/*.5.md` (10 man pages: containers-auth.json, containers-certs.d, containers-policy.json, containers-registries.conf, containers-registries.conf.d, containers-registries.d, containers-signature, containers-sigstore-signing-params.yaml, containers-tls-details.yaml, containers-transports)
   - `storage/docs/containers-storage.conf.5.md` (1 man page)

2. Converts each `.5.md` to `.5` format using `go-md2man`

3. Installs all 15 generated `.5` files plus the `.containerignore.5` alias to `/usr/share/man/man5/` using `install -m 0644`

4. Verifies installation by counting installed man pages

Wired into `setup.sh` as the final `run_script` call, after `install_container-configs.sh`.

### Task 2: Extend uninstall.sh to remove all container-libs artifacts
**Commit:** `093ed70`

Added three cleanup sections to `uninstall.sh`:

1. **Container-libs man pages** (after existing local man pages section): Glob pattern removes all `containers-*.5`, `Containerfile.5`, `containerignore.5`, and `.containerignore.5` from `/usr/share/man/man5/`

2. **seccomp.json and /usr/share/containers/** (after podman libexec section): Removes the seccomp profile file and the parent directory

3. **container-libs build directory** (after Go installation removal): Removes `${BUILD_ROOT}/container-libs`

All use existing `safe_rm_file` and `safe_rm_dir` functions for consistent tracking. The existing `safe_rm_dir "/etc/containers"` already covers Phase 12 config files.

## Deviations from Plan

None - plan executed exactly as written.

## Verification Results

| Check | Result |
|-------|--------|
| `bash -n scripts/install_container-manpages.sh` | PASS |
| `bash -n uninstall.sh` | PASS |
| `install_container-manpages.sh` wired in setup.sh | PASS |
| `seccomp.json` in uninstall.sh | PASS |
| `container-libs` in uninstall.sh | PASS |
| `go-md2man` in install script | PASS |
| `/usr/share/man/man5` in install script | PASS |

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `scripts/install_container-manpages.sh` | Created | Man page build and install script (85 lines) |
| `setup.sh` | Modified | Added run_script call as last step |
| `uninstall.sh` | Modified | Added 3 container-libs cleanup sections (+12 lines) |

## Self-Check: PASSED

- FOUND: scripts/install_container-manpages.sh
- FOUND: commit 4bcd7c2 (Task 1)
- FOUND: commit 093ed70 (Task 2)
