---
phase: quick
plan: 1
type: execute
wave: 1
depends_on: []
files_modified: [config.sh.example, functions.sh]
autonomous: true
requirements: []
must_haves:
  truths:
    - "CRUN_TAG defaults to empty when not specified"
    - "Empty CRUN_TAG triggers automatic latest version detection"
    - "get_latest_tag works with crun's numeric-only tags"
  artifacts:
    - path: "config.sh.example"
      provides: "CRUN version configuration"
      contains: 'CRUN_TAG="\${CRUN_TAG:-}'
    - path: "functions.sh"
      provides: "Latest tag detection"
      contains: "get_latest_tag"
  key_links:
    - from: "config.sh.example"
      to: "functions.sh"
      via: "CRUN_TAG environment variable"
      pattern: "CRUN_TAG"
---

<objective>
Make CRUN use latest available version if CRUN_TAG not specified, matching the pattern used by other components (PODMAN_TAG, BUILDAH_TAG, CONMON_TAG, etc.)

**Purpose:** Consistency across all component version handling - users can override specific versions or let the system auto-detect latest.

**Output:** Updated config.sh.example and functions.sh
</objective>

<execution_context>
@./.claude/get-shit-done/workflows/execute-plan.md
@./.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
## Current State

**config.sh.example (lines 73-75):**
```bash
# Crun Version
export CRUN_VERSION="1.25.1"
export CRUN_TAG="${CRUN_VERSION}"
```

**Pattern used by other components (e.g., PODMAN_TAG, line 61):**
```bash
export PODMAN_TAG="${PODMAN_TAG:-}"
```

**functions.sh get_latest_tag (line 49):**
```bash
latest=$(git tag --list --sort -creatordate | grep -v rc | grep -E ^v | sort --reverse --version-sort | head -n1)
```
The `grep -E ^v` filters for "v"-prefixed tags only, which does NOT work for crun's numeric-only tags (e.g., `1.26`, `1.25.1`).

## Tag Format Analysis

| Component | Tag Format | Example |
|-----------|------------|---------|
| Podman | v-prefixed | v5.5.2 |
| Buildah | v-prefixed | v1.40.1 |
| Runc | v-prefixed | v1.4.0 |
| Crun | **numeric-only** | 1.26, 1.25.1 |
| Fuse-overlayfs | v-prefixed | v1.16 |
</context>

<tasks>

<task type="auto">
  <name>Task 1: Update CRUN_TAG pattern in config.sh.example</name>
  <files>config.sh.example</files>
  <action>
    Modify lines 73-75 in config.sh.example to match the pattern used by other components:

    **Change FROM:**
    ```bash
    # Crun Version
    export CRUN_VERSION="1.25.1"
    export CRUN_TAG="${CRUN_VERSION}"
    ```

    **Change TO:**
    ```bash
    # Crun Version
    #export CRUN_VERSION="1.25.1"
    #export CRUN_TAG="${CRUN_VERSION}"
    export CRUN_TAG="${CRUN_TAG:-}"
    ```

    This matches the pattern used by PODMAN_TAG, BUILDAH_TAG, CONMON_TAG, etc.
  </action>
  <verify>
    <automated>grep -q 'CRUN_TAG="\${CRUN_TAG:-}"' config.sh.example && grep -q '#export CRUN_VERSION=' config.sh.example</automated>
  </verify>
  <done>CRUN_TAG defaults to empty string, allowing override via environment variable or auto-detection</done>
</task>

<task type="auto">
  <name>Task 2: Update get_latest_tag to support numeric-only tags</name>
  <files>functions.sh</files>
  <action>
    Modify the get_latest_tag function (line 49) to handle both v-prefixed tags AND numeric-only tags (for crun compatibility).

    **Change FROM:**
    ```bash
    latest=$(git tag --list --sort -creatordate | grep -v rc | grep -E ^v | sort --reverse --version-sort | head -n1)
    ```

    **Change TO:**
    ```bash
    latest=$(git tag --list --sort -creatordate | grep -v rc | grep -E '^(v)?[0-9]' | sort --reverse --version-sort | head -n1)
    ```

    The regex `^(v)?[0-9]` matches:
    - v-prefixed tags: v5.5.2, v1.40.1
    - Numeric-only tags: 1.26, 1.25.1

    The sort still works correctly because version-sort handles both formats.
  </action>
  <verify>
    <automated>grep -q "grep -E '^(v)?\[0-9\]'" functions.sh</automated>
  </verify>
  <done>get_latest_tag function detects latest tag for both v-prefixed and numeric-only tag formats</done>
</task>

</tasks>

<verification>
1. config.sh.example has CRUN_TAG pattern matching other components
2. functions.sh get_latest_tag supports numeric-only tags
3. No syntax errors in modified files (bash -n passes)
</verification>

<success_criteria>
- CRUN_TAG uses `${CRUN_TAG:-}` pattern (consistent with PODMAN_TAG, BUILDAH_TAG, etc.)
- get_latest_tag regex updated to match both v-prefixed and numeric-only tags
- Files pass bash syntax check
</success_criteria>

<output>
After completion, create `.planning/quick/1-make-crun-use-latest-available-version-i/1-SUMMARY.md`
</output>
