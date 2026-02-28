# Phase 3: Error Handling - Research

**Researched:** 2026-02-28
**Domain:** Bash script error handling, error propagation, and failure context
**Confidence:** HIGH

## Summary

This phase requires implementing robust error handling across all installation scripts. The current codebase has inconsistent error handling: some scripts have `set -e` (active or commented out), others do not. The main `install.sh` sources all sub-scripts, which means errors can silently cascade. We need to enable `set -euo pipefail` consistently, add error trap handlers for contextual error messages, and ensure `install.sh` properly propagates and summarizes failures from sub-scripts.

**Primary recommendation:** Use the "unofficial bash strict mode" (`set -euo pipefail`) in all scripts, implement a shared error trap handler in `functions.sh` that captures script name and line number, and modify `install.sh` to wrap sourced scripts with error-checking wrappers.

<phase_requirements>

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| ERRO-01 | set -e enabled consistently across all scripts | Strict Mode section, set -euo pipefail pattern |
| ERRO-02 | Scripts fail immediately on any error | Trap ERR section, error propagation patterns |
| ERRO-03 | Error messages identify which script and line failed | Error Trap Handler pattern with LINENO and BASH_SOURCE |
| ERRO-04 | install.sh propagates errors from sub-scripts | Sourced Script Error Propagation pattern |

</phase_requirements>

## Standard Stack

### Core
| Tool/Option | Purpose | Why Standard |
|-------------|---------|--------------|
| `set -e` | Exit immediately on command failure | Prevents cascading silent failures |
| `set -u` | Treat undefined variables as errors | Catches typos and missing config |
| `set -o pipefail` | Pipeline fails if any command fails | Catches errors mid-pipeline |

### Supporting
| Pattern | Purpose | When to Use |
|---------|---------|-------------|
| `trap 'handler' ERR` | Catch errors for logging | All scripts needing error context |
| `trap 'cleanup' EXIT` | Resource cleanup on exit | Scripts creating temp files |
| `shopt -s inherit_errexit` | Subshells inherit errexit | Bash 4.4+ (Debian 10+) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `set -e` | Manual error checking after every command | Verbose; easy to miss errors |
| `set -euo pipefail` | `set -e` only | Misses undefined variables and pipeline failures |
| Trap-based handling | Check `$?` after each command | Repetitive; clutters code |

## Architecture Patterns

### Current State Analysis

| Script | Has `set -e` | Active | Comments |
|--------|--------------|--------|----------|
| install.sh | Yes | No | Commented out on line 7 |
| config.sh | No | N/A | Sourced, uses guards |
| functions.sh | No | N/A | Sourced, uses guards |
| install_dependencies.sh | Yes | Yes | Active on line 4 |
| install_go.sh | Yes | Yes | Active on line 4 |
| install_protoc.sh | Yes | Yes | Active on line 4 |
| install_rust.sh | Yes | Yes | Active on line 4 |
| build_podman.sh | Yes | No | Commented out on line 4 |
| build_crun.sh | Yes | No | Commented out on line 4 |
| build_conmon.sh | Yes | No | Commented out on line 4 |

### Recommended Project Structure
```
.
├── config.sh              # Sourced - no set -e (uses guards)
├── functions.sh           # Add error_handler() function here
├── install.sh             # Main entry - enable set -euo pipefail + error trap
└── scripts/
    ├── install_*.sh       # Enable set -euo pipefail + error trap
    └── build_*.sh         # Enable set -euo pipefail + error trap
```

### Pattern 1: Strict Mode Header (All Executable Scripts)
**What:** Enable bash strict mode at the top of every executable script
**When to use:** All scripts in scripts/ directory and install.sh

```bash
#!/bin/bash

# Strict Mode - Exit on error, undefined vars, pipe failures
set -euo pipefail

# Determine toolpath if not set already
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}")
fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions (includes error handler)
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing (config/functions may not support strict mode)
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR
```

### Pattern 2: Error Trap Handler (Add to functions.sh)
**What:** Centralized error handler that provides script context
**When to use:** All scripts call this via trap

```bash
# Add to functions.sh (after existing content)

# ============================================
# Error Handling
# ============================================

# Error handler - provides context on failure
# Usage: trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR
error_handler() {
    local exit_code=$1
    local line_number=$2
    local script_name="${3##*/}"  # basename

    echo ""
    echo "========================================" >&2
    echo "ERROR: Script failed" >&2
    echo "========================================" >&2
    echo "  Script:   ${script_name}" >&2
    echo "  Line:     ${line_number}" >&2
    echo "  Exit code: ${exit_code}" >&2
    echo "========================================" >&2
    echo ""

    # If running in install.sh context, set a flag for summary
    export INSTALL_ERROR_SCRIPT="${script_name}"
    export INSTALL_ERROR_LINE="${line_number}"
    export INSTALL_ERROR_CODE="${exit_code}"

    exit "${exit_code}"
}
```

### Pattern 3: Sourced Script Error Propagation (install.sh)
**What:** Wrap sourced scripts with error checking to provide summary context
**When to use:** In install.sh when calling sub-scripts

**Current approach (problematic):**
```bash
source "${toolpath}/scripts/install_dependencies.sh"
# No error checking - errors may be silently ignored
```

**Recommended approach:**
```bash
#!/bin/bash

# Strict Mode
set -euo pipefail

# ... toolpath setup ...

# Load Configuration (sourced - may not use strict mode)
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set global error trap
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# Track successful/failed components
COMPONENTS_INSTALLED=()
COMPONENTS_FAILED=()

# Wrapper function for sourcing scripts with error handling
run_script() {
    local script_name="$1"
    local script_path="${toolpath}/scripts/${script_name}"

    echo ">>> Starting: ${script_name}"

    if [[ -f "${script_path}" ]]; then
        if source "${script_path}"; then
            COMPONENTS_INSTALLED+=("${script_name}")
            echo ">>> Completed: ${script_name}"
            echo ""
        else
            COMPONENTS_FAILED+=("${script_name}")
            echo ">>> FAILED: ${script_name}" >&2
            exit 1
        fi
    else
        echo ">>> ERROR: Script not found: ${script_path}" >&2
        exit 1
    fi
}

# Install sequence
run_script "install_dependencies.sh"
run_script "install_rust.sh"
run_script "install_protoc.sh"
run_script "install_go.sh"
# ... etc

# Final summary
echo "========================================"
echo "Installation Complete"
echo "========================================"
echo "Successfully installed: ${#COMPONENTS_INSTALLED[@]} components"
```

### Pattern 4: Handling Commands That May Fail
**What:** Allow specific commands to fail without triggering exit
**When to use:** Commands where failure is acceptable or expected

```bash
# Command that may fail (e.g., checking if something exists)
command_may_fail || true

# Or capture the exit code explicitly
if ! some_command; then
    echo "Command failed, handling gracefully..."
fi

# Or use || with specific handling
some_command || {
    echo "Fallback action"
    fallback_command
}
```

### Anti-Patterns to Avoid
- **Commenting out `set -e`:** This defeats the purpose of error handling. Instead, use `|| true` for commands that may legitimately fail.
- **Using `set -e` in sourced files:** Sourced files (config.sh, functions.sh) should use guard patterns, not `set -e`, because `exit` would exit the parent shell.
- **Missing `pipefail`:** Without `pipefail`, `command_that_fails | tail` returns success because tail succeeded.
- **Ignoring subshell errors:** Command substitution `$()` swallows errors unless using `shopt -s inherit_errexit` (Bash 4.4+).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Error message formatting | Custom echo statements | Standardized `error_handler()` trap | Consistency, captures line numbers |
| Checking $? after every command | Manual checks everywhere | `set -e` + trap | Less code, automatic |
| Pipeline error detection | Checking PIPESTATUS array | `set -o pipefail` | Simpler, more reliable |
| Tracking which script failed | Custom logging in each script | `BASH_SOURCE` in trap | Automatic, accurate |

**Key insight:** Bash provides built-in mechanisms for error handling. Use them instead of building custom solutions that add complexity and can miss edge cases.

## Common Pitfalls

### Pitfall 1: set -e in Sourced Files
**What goes wrong:** Adding `set -e` to config.sh or functions.sh causes unexpected exits when sourced by other scripts.
**Why it happens:** When a sourced file exits, it exits the entire calling shell, not just returning from the source.
**How to avoid:** Use recursive sourcing guards in sourced files, but do NOT use `set -e`:
```bash
# In config.sh and functions.sh
[[ -n "${_CONFIG_SH_SOURCED:-}" ]] && return 0
export _CONFIG_SH_SOURCED=1
# No set -e here!
```

### Pitfall 2: Pipeline Failures Masked
**What goes wrong:** `failing_command | grep pattern` returns success because grep succeeded.
**Why it happens:** Default bash behavior only returns the exit status of the last command in a pipeline.
**How to avoid:** Always use `set -o pipefail` alongside `set -e`:
```bash
set -euo pipefail
```

### Pitfall 3: Conditional Commands Don't Trigger set -e
**What goes wrong:** Commands in `if`, `while`, `&&`, `||` contexts don't trigger `set -e` exit.
**Why it happens:** Bash assumes these commands are being used for their exit status intentionally.
**How to avoid:** Be aware of this behavior; use explicit checks if needed:
```bash
# This won't exit on failure
if some_command; then
    ...
fi

# This WILL exit on failure (because of set -e)
some_command
```

### Pitfall 4: Command Substitution Swallows Errors
**What goes wrong:** `var=$(failing_command)` doesn't cause exit even with `set -e` (in older bash).
**Why it happens:** Before Bash 4.4, command substitution doesn't inherit errexit.
**How to avoid:** Use `shopt -s inherit_errexit` (Bash 4.4+) or check explicitly:
```bash
shopt -s inherit_errexit  # Bash 4.4+
var=$(failing_command)
```

### Pitfall 5: cd Failures Not Caught
**What goes wrong:** `cd /nonexistent` followed by `rm -rf *` can be catastrophic if cd fails silently.
**Why it happens:** Without `set -e`, cd failure is ignored and subsequent commands run in wrong directory.
**How to avoid:** Always use `set -e` OR use `cd dir || exit`:
```bash
set -e
cd "${BUILD_ROOT}"

# Or without set -e:
cd "${BUILD_ROOT}" || exit 1
```

## Code Examples

### Complete Error Handler for functions.sh
```bash
# Add to functions.sh

# ============================================
# Error Handling
# ============================================

# Error handler - call via: trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR
error_handler() {
    local exit_code=$1
    local line_number=$2
    local script_name="${3##*/}"

    echo "" >&2
    echo "========================================" >&2
    echo "ERROR: Installation Failed" >&2
    echo "========================================" >&2
    echo "  Script:    ${script_name}" >&2
    echo "  Line:      ${line_number}" >&2
    echo "  Exit Code: ${exit_code}" >&2
    echo "========================================" >&2

    # Hint for debugging
    echo "" >&2
    echo "To debug, run: bash -x ${script_name}" >&2
    echo "" >&2

    exit "${exit_code}"
}

# Check if running as root (useful helper for error messages)
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root" >&2
        echo "Try: sudo $0" >&2
        exit 1
    fi
}

# Verify a command exists (fail early if missing)
require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: Required command not found: ${cmd}" >&2
        exit 1
    fi
}
```

### Updated install.sh with Error Propagation
```bash
#!/bin/bash

# Non-Interactive Mode - MUST be set before ANY apt commands
export DEBIAN_FRONTEND=noninteractive

# Strict Mode - Exit on error, undefined vars, pipe failures
set -euo pipefail

# Determine toolpath if not set already
relativepath="./"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}")
fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# Track installation progress
COMPONENTS_OK=()
CURRENT_SCRIPT=""

# Wrapper for running sub-scripts
run_script() {
    local script="$1"
    CURRENT_SCRIPT="${script}"
    echo ""
    echo "========================================"
    echo ">>> Starting: ${script}"
    echo "========================================"

    source "${toolpath}/scripts/${script}"

    COMPONENTS_OK+=("${script}")
    echo ">>> Completed: ${script}"
}

# Main installation sequence
main() {
    echo "Podman Debian Compiler - Starting Installation"
    echo "Architecture: ${ARCH}"
    echo ""

    # Dependencies
    run_script "install_dependencies.sh"

    # Toolchains
    run_script "install_rust.sh"
    run_script "install_protoc.sh"
    run_script "install_go.sh"

    # Build components
    run_script "build_aardvark_dns.sh"
    run_script "build_buildah.sh"
    run_script "build_catatonit.sh"
    run_script "build_conmon.sh"
    run_script "build_crun.sh"
    run_script "build_fuse-overlayfs.sh"
    run_script "build_go-md2man.sh"
    run_script "build_netavark.sh"
    run_script "build_pasta.sh"
    run_script "build_podman.sh"
    run_script "build_runc.sh"
    run_script "build_skopeo.sh"
    run_script "build_slirp4netns.sh"
    run_script "build_toolbox.sh"

    # Success summary
    echo ""
    echo "========================================"
    echo "INSTALLATION COMPLETE"
    echo "========================================"
    echo "Successfully installed ${#COMPONENTS_OK[@]} components"
    echo ""
}

# Run main with error handling
main "$@"
```

### Updated build_podman.sh (Example Build Script)
```bash
#!/bin/bash

# Strict Mode
set -euo pipefail

# Determine toolpath if not set already
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)
    toolpath=$(realpath --canonicalize-missing "${scriptpath}/${relativepath}")
fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# Change Folder to Build Root
cd "${BUILD_ROOT}"

# Required Fix otherwise go complains about version mismatch
export PATH="$GOPATH:$PATH"

# Clone/Update repository
git_clone_update https://github.com/containers/podman.git podman
cd "${BUILD_ROOT}/podman"
git_checkout "${PODMAN_TAG}"

# Log Component
log_component "podman"

# Patch go.mod version
sed -Ei "s|^go 1.22.6$|go 1.23|" go.mod

# Build and install
make BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr
sudo make install PREFIX=/usr
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Commented `set -e` | `set -euo pipefail` | This phase | Catches all failure modes |
| No error context | Trap-based error handler | This phase | Clear failure identification |
| Direct source calls | run_script() wrapper | This phase | Better error propagation |

**Deprecated/outdated:**
- `# set -e` (commented out): Remove comments, enable strict mode
- Silent continuation on error: No longer acceptable

## Open Questions

1. **Should we use `shopt -s inherit_errexit`?**
   - What we know: Bash 4.4+ feature, ensures subshells inherit errexit
   - What's unclear: Minimum bash version on target Debian/Ubuntu systems
   - Recommendation: Check Debian 10+ has Bash 5.0, so safe to use. Add to install.sh header.

2. **How to handle partial installations (resume capability)?**
   - What we know: Current design doesn't track progress across runs
   - What's unclear: Whether this is needed for v1
   - Recommendation: Out of scope for this phase (deferred to v2 PREF requirements)

3. **Should error handler include stack trace?**
   - What we know: Can use `caller` builtin for call stack
   - What's unclear: Whether complexity is worth it for this use case
   - Recommendation: Keep simple - script name and line number sufficient for this project

## Sources

### Primary (HIGH confidence)
- GNU Bash Manual: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html - Official set builtin documentation
- GNU Bash Manual: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-trap - Official trap documentation

### Secondary (MEDIUM confidence)
- [Bash error handling mechanisms - CSDN](https://blog.csdn.net/) - Multi-line command handling and trap ERR patterns
- [Getting decent error reports in Bash when using 'set -e' - Hacker News](https://news.ycombinator.com/) - Community discussion on practical error handling
- [Robust error handling in Bash - DEV Community](https://dev.to/banks/stop-ignoring-errors-in-bash-3co5) - Subshell error propagation patterns

### Tertiary (LOW confidence)
- Codebase analysis of existing scripts - Reviewed all 18 scripts for current error handling patterns

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Bash error handling primitives are well-documented and stable
- Architecture: HIGH - Clear patterns from bash best practices community
- Pitfalls: HIGH - Common issues well-documented in bash scripting literature

**Research date:** 2026-02-28
**Valid until:** 2027-02-28 (12 months - bash error handling patterns are stable)
