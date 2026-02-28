---
phase: quick
plan: 2
type: execute
wave: 1
depends_on: []
files_modified: [config.sh.example, functions.sh, scripts/install_protoc.sh, scripts/install_go.sh]
autonomous: true
requirements: []
must_haves:
  truths:
    - "PROTOC_VERSION defaults to empty and triggers auto-detection if not specified"
    - "GOVERSION defaults to empty and triggers auto-detection if not specified"
    - "Both components follow the same pattern as other components (CRUN_TAG, PODMAN_TAG, etc.)"
  artifacts:
    - path: "config.sh.example"
      contains: "PROTOC_TAG=\"${PROTOC_TAG:-}\""
    - path: "config.sh.example"
      contains: "GOVERSION=\"${GOVERSION:-}\""
    - path: "functions.sh"
      contains: "get_latest_protoc_version"
    - path: "functions.sh"
      contains: "get_latest_go_version"
  key_links:
    - from: "config.sh.example"
      to: "functions.sh"
      via: "get_latest_protoc_version() and get_latest_go_version()"
      pattern: "get_latest_.*_version"
    - from: "scripts/install_protoc.sh"
      to: "PROTOC_VERSION"
      via: "config.sh sourcing"
      pattern: "PROTOC_TAG|PROTOC_VERSION"
    - from: "scripts/install_go.sh"
      to: "GOVERSION"
      via: "config.sh sourcing"
      pattern: "GOVERSION|GOTAG"
---

<objective>
Make PROTOC_VERSION and GOVERSION use latest version unless specified, matching the pattern used by other components (CRUN_TAG, PODMAN_TAG, etc.).

Purpose: Maintain consistency across all component version handling - all should support override via environment variable and auto-detect latest when not specified.
Output: Updated config.sh.example with new patterns, functions.sh with version detection helpers, updated install scripts.
</objective>

<execution_context>
@./.claude/get-shit-done/workflows/execute-plan.md
@./.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/STATE.md

## Current State

**config.sh.example lines 53-56 (GOVERSION):**
```bash
export GOVERSION="1.23.3"
export GOTAG="go${GOVERSION}"
export GOPATH="/opt/go/${GOVERSION}/bin"
export GOROOT="/opt/go/${GOVERSION}"
```

**config.sh.example lines 119-124 (PROTOC_VERSION):**
```bash
export PROTOC_VERSION="33.1"
export PROTOC_TAG="v${PROTOC_VERSION}"
export PROTOC_ROOT_FOLDER="/opt/protoc"
export PROTOC_PATH="${PROTOC_ROOT_FOLDER}/${PROTOC_VERSION}/bin/protoc"
```

**Pattern established by CRUN (config.sh.example lines 74-76):**
```bash
#export CRUN_VERSION="1.25.1"
#export CRUN_TAG="${CRUN_VERSION}"
export CRUN_TAG="${CRUN_TAG:-}"
```

**Key difference from git-based components:**
- CRUN, PODMAN, etc.: Use `git_clone_update` + `git_checkout` which calls `get_latest_tag()`
- protoc/go: Download via wget from release URLs - need new API-based detection functions

**API endpoints for version detection:**
- Go: `https://go.dev/dl/?mode=json` returns `{"version": "go1.26.0", ...}`
- Protobuf: `https://api.github.com/repos/protocolbuffers/protobuf/releases/latest` returns `{"tag_name": "v34.0", ...}`
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add version detection functions to functions.sh</name>
  <files>functions.sh</files>
  <action>
    Add two new functions after the existing `get_latest_tag()` function (around line 57):

    ```bash
    get_latest_protoc_version() {
        # Fetch latest protoc release from GitHub API
        # Returns version WITHOUT v prefix (e.g., "34.0" not "v34.0")
        local latest_tag
        latest_tag=$(curl -s "https://api.github.com/repos/protocolbuffers/protobuf/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
        # Strip v prefix if present (tag_name is "v34.0", we want "34.0")
        echo "${latest_tag#v}"
    }

    get_latest_go_version() {
        # Fetch latest Go version from go.dev JSON API
        # Returns version WITHOUT go prefix (e.g., "1.26.0" not "go1.26.0")
        local latest_version
        latest_version=$(curl -s "https://go.dev/dl/?mode=json" | grep -m1 '"version"' | sed 's/.*"version": *"\([^"]*\)".*/\1/')
        # Strip go prefix if present (version is "go1.26.0", we want "1.26.0")
        echo "${latest_version#go}"
    }
    ```

    These functions:
    - Use curl to fetch version info from public APIs
    - Extract version numbers using grep/sed (no jq dependency)
    - Return clean version strings (no prefixes)
  </action>
  <verify>
    <automated>bash -n functions.sh && grep -q "get_latest_protoc_version" functions.sh && grep -q "get_latest_go_version" functions.sh</automated>
  </verify>
  <done>Both detection functions exist in functions.sh with proper extraction logic</done>
</task>

<task type="auto">
  <name>Task 2: Update config.sh.example for PROTOC_VERSION auto-detection</name>
  <files>config.sh.example</files>
  <action>
    Replace lines 119-124 with the new pattern:

    **Before:**
    ```bash
    # Protoc Version and Path
    export PROTOC_VERSION="33.1"
    export PROTOC_TAG="v${PROTOC_VERSION}"
    export PROTOC_ROOT_FOLDER="/opt/protoc"
    export PROTOC_PATH="${PROTOC_ROOT_FOLDER}/${PROTOC_VERSION}/bin/protoc"
    ```

    **After:**
    ```bash
    # Protoc Version and Path
    #export PROTOC_VERSION="33.1"
    #export PROTOC_TAG="v${PROTOC_VERSION}"
    export PROTOC_VERSION="${PROTOC_VERSION:-}"
    export PROTOC_TAG="${PROTOC_TAG:-}"
    export PROTOC_ROOT_FOLDER="/opt/protoc"
    export PROTOC_PATH="${PROTOC_ROOT_FOLDER}/${PROTOC_VERSION}/bin/protoc"
    ```

    Note: PROTOC_VERSION and PROTOC_TAG are separate overrides (user can specify either). If PROTOC_VERSION is set, PROTOC_TAG should derive from it. If only PROTOC_TAG is set, extract version from it.
  </action>
  <verify>
    <automated>bash -n config.sh.example && grep -q 'PROTOC_VERSION="\${PROTOC_VERSION:-}"' config.sh.example</automated>
  </verify>
  <done>PROTOC_VERSION and PROTOC_TAG use the ${VAR:-} pattern matching other components</done>
</task>

<task type="auto">
  <name>Task 3: Update config.sh.example for GOVERSION auto-detection</name>
  <files>config.sh.example</files>
  <action>
    Replace lines 53-56 with the new pattern:

    **Before:**
    ```bash
    export GOVERSION="1.23.3"
    export GOTAG="go${GOVERSION}"
    export GOPATH="/opt/go/${GOVERSION}/bin"
    export GOROOT="/opt/go/${GOVERSION}"
    ```

    **After:**
    ```bash
    #export GOVERSION="1.23.3"
    #export GOTAG="go${GOVERSION}"
    #export GOPATH="/opt/go/${GOVERSION}/bin"
    #export GOROOT="/opt/go/${GOVERSION}"
    export GOVERSION="${GOVERSION:-}"
    export GOPATH="/opt/go/${GOVERSION}/bin"
    export GOROOT="/opt/go/${GOVERSION}"
    ```

    Note: GOTAG is derived from GOVERSION, so no separate GOTAG override is needed. The GOTAG variable is only used in install_go.sh for the download URL.
  </action>
  <verify>
    <automated>bash -n config.sh.example && grep -q 'GOVERSION="\${GOVERSION:-}"' config.sh.example</automated>
  </verify>
  <done>GOVERSION uses the ${VAR:-} pattern matching other components</done>
</task>

<task type="auto">
  <name>Task 4: Update install_protoc.sh to detect version if not set</name>
  <files>scripts/install_protoc.sh</files>
  <action>
    Add version detection logic after sourcing config.sh (around line 17, after the error trap):

    ```bash
    # Auto-detect latest protoc version if not specified
    if [[ -z "${PROTOC_VERSION:-}" ]]; then
        export PROTOC_VERSION=$(get_latest_protoc_version)
        echo "Auto-detected protoc version: ${PROTOC_VERSION}"
    fi

    # Derive PROTOC_TAG from PROTOC_VERSION if not set
    if [[ -z "${PROTOC_TAG:-}" ]]; then
        export PROTOC_TAG="v${PROTOC_VERSION}"
    fi
    ```

    This ensures:
    - If PROTOC_VERSION is empty, fetch latest from GitHub API
    - If PROTOC_TAG is empty, derive from PROTOC_VERSION
    - User can override either via environment variable
  </action>
  <verify>
    <automated>bash -n scripts/install_protoc.sh && grep -q "get_latest_protoc_version" scripts/install_protoc.sh</automated>
  </verify>
  <done>install_protoc.sh auto-detects version when PROTOC_VERSION is not specified</done>
</task>

<task type="auto">
  <name>Task 5: Update install_go.sh to detect version if not set</name>
  <files>scripts/install_go.sh</files>
  <action>
    Add version detection logic after sourcing config.sh (around line 17, after the error trap):

    ```bash
    # Auto-detect latest Go version if not specified
    if [[ -z "${GOVERSION:-}" ]]; then
        export GOVERSION=$(get_latest_go_version)
        echo "Auto-detected Go version: ${GOVERSION}"
    fi

    # Derive GOTAG from GOVERSION
    export GOTAG="go${GOVERSION}"

    # Update GOPATH and GOROOT with detected version
    export GOPATH="/opt/go/${GOVERSION}/bin"
    export GOROOT="/opt/go/${GOVERSION}"
    ```

    This ensures:
    - If GOVERSION is empty, fetch latest from go.dev API
    - GOTAG is always derived from GOVERSION
    - GOPATH and GOROOT are updated with the detected/specified version
  </action>
  <verify>
    <automated>bash -n scripts/install_go.sh && grep -q "get_latest_go_version" scripts/install_go.sh</automated>
  </verify>
  <done>install_go.sh auto-detects version when GOVERSION is not specified</done>
</task>

</tasks>

<verification>
1. All files pass `bash -n` syntax check
2. config.sh.example has PROTOC_VERSION and GOVERSION using ${VAR:-} pattern
3. functions.sh has both get_latest_protoc_version and get_latest_go_version functions
4. install_protoc.sh calls get_latest_protoc_version when PROTOC_VERSION is empty
5. install_go.sh calls get_latest_go_version when GOVERSION is empty
</verification>

<success_criteria>
- PROTOC_VERSION and GOVERSION follow the same pattern as CRUN_TAG, PODMAN_TAG, etc.
- Both support environment variable override
- Both auto-detect latest version when not specified
- No breaking changes to existing functionality
</success_criteria>

<output>
After completion, create `.planning/quick/2-make-protoc-version-and-goversion-use-la/2-SUMMARY.md`
</output>
