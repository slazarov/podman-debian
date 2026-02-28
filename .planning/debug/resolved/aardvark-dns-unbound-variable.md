---
status: resolved
trigger: "Build fails with AARDVARK_DNS_TAG: unbound variable at line 28 of build_aardvark_dns.sh"
created: 2026-02-28T12:00:00Z
updated: 2026-02-28T12:20:00Z
---

## Current Focus

hypothesis: CONFIRMED - AARDVARK_DNS_TAG was undefined because export commented out, set -u caused failure
test: Applied fix - added default empty exports for all 12 undefined tags
expecting: Scripts will now use empty tag, git_checkout will get latest version
next_action: User to verify fix in Lima VM

## Symptoms

expected: build_aardvark_dns.sh should complete successfully
actual: Script exits with "unbound variable" error on line 28
errors: `/opt/podman-debian/scripts/build_aardvark_dns.sh: line 28: AARDVARK_DNS_TAG: unbound variable`
reproduction: Run install.sh in the Lima VM at /opt/podman-debian
started: Started after Phase 03 added `set -euo pipefail` strict mode to all scripts

## Eliminated

- hypothesis: AARDVARK_DNS_TAG missing from config.sh entirely
  evidence: Variable IS in config.sh but commented out (lines 86-88)
  timestamp: 2026-02-28T12:02:00Z

## Evidence

- timestamp: 2026-02-28T12:01:00Z
  checked: scripts/build_aardvark_dns.sh
  found: Line 28 uses `${AARDVARK_DNS_TAG}` in git_checkout call
  implication: Variable must be defined when script runs with set -u

- timestamp: 2026-02-28T12:02:00Z
  checked: config.sh lines 86-88
  found: AARDVARK_DNS_TAG is commented out:
    ```
    #export AARDVARK_DNS_VERSION="1.15.0"
    #export AARDVARK_DNS_TAG="v${AARDVARK_DNS_VERSION}"
    ```
  implication: Variable is intentionally undefined (user wants latest)

- timestamp: 2026-02-28T12:03:00Z
  checked: config.sh for all TAG exports
  found: Only 3 tags defined: GOTAG, CRUN_TAG, PROTOC_TAG
  implication: 11 other tags are undefined and will cause same error

- timestamp: 2026-02-28T12:04:00Z
  checked: functions.sh git_checkout function (lines 84-96)
  found: Function handles empty tag by getting latest: `if [[ -n "${ltag}" ]]`
  implication: Design intent is to allow empty tags for "use latest" behavior

- timestamp: 2026-02-28T12:05:00Z
  checked: All build scripts using *_TAG
  found: 14 scripts use git_checkout with tag variables:
    - GOMD2MAN_TAG (commented out)
    - RUNC_TAG (commented out)
    - AARDVARK_DNS_TAG (commented out)
    - CRUN_TAG (DEFINED)
    - SKOPEO_TAG (commented out)
    - TOOLBOX_TAG (commented out)
    - CONMON_TAG (commented out)
    - FUSE_OVERLAYFS_TAG (never existed)
    - NETAVARK_TAG (commented out)
    - SLIRP4NETNS_TAG (commented out)
    - CATATONIT_TAG (never existed)
    - PODMAN_TAG (commented out)
    - BUILDAH_TAG (commented out)
  implication: Widespread issue - need to define all missing tags with empty defaults

## Resolution

root_cause: config.sh has most version tag exports commented out (intentional "use latest" behavior), but build scripts reference these variables directly with set -u enabled, causing "unbound variable" failures
fix: Added default empty exports for all 11 undefined tags in config.sh using `${VAR:-}` syntax. This allows set -u to pass while preserving "use latest" behavior via git_checkout's empty tag handling.
verification: User confirmed in Lima VM - all 12 previously undefined tags now export as empty strings, satisfying set -u. Source commands for functions.sh and config.sh complete without errors.
files_changed:
  - config.sh: Added default empty exports for PODMAN_TAG, BUILDAH_TAG, RUNC_TAG, CONMON_TAG, SLIRP4NETNS_TAG, NETAVARK_TAG, AARDVARK_DNS_TAG, SKOPEO_TAG, GOMD2MAN_TAG, TOOLBOX_TAG, FUSE_OVERLAYFS_TAG, CATATONIT_TAG
