# Phase 2: Non-Interactive Mode - Research

**Researched:** 2026-02-28
**Domain:** Debian/Ubuntu package management non-interactive installation, bash script automation
**Confidence:** HIGH

## Summary

This phase ensures the Podman installation completes without any user interaction. The research identified three key areas: (1) apt-get commands need `DEBIAN_FRONTEND=noninteractive` environment variable and `-y` flag, (2) rustup-init requires the `-y` flag for silent installation, and (3) no blocking input commands (`read`, `select`, `dialog`, `whiptail`) should exist in any script.

The current codebase analysis found: all apt commands already use `-y` flag (correct), `DEBIAN_FRONTEND=noninteractive` is NOT set anywhere (needs addition), and rustup-init is missing the `-y` flag (line 20 in scripts/install_rust.sh). No `read`, `select`, `dialog`, or `whiptail` commands were found in any script.

**Primary recommendation:** Add `export DEBIAN_FRONTEND=noninteractive` at the top of install.sh (after shebang but before sourcing scripts), and add `-y` flag to the rustup-init command.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Error Handling Strategy:**
- Fail fast: stop immediately on any error with clear error message
- Leave partial state as-is on failure (no rollback, no resume capability)
- Error output: show failing command, exit code, and last few lines of output (context summary)
- No retries: fail immediately on first error, user can re-run manually

**Output Verbosity:**
- Default: minimal progress output (current step/phase, success/fail at end)
- apt-get and build output suppressed by default
- Log full output to file in script directory (e.g., `install.log`)
- Add --verbose/-v flag to enable full console output for debugging

**Debconf/Package Configuration:**
- Set DEBIAN_FRONTEND=noninteractive globally to accept all defaults
- No specific package pre-seeding required
- Rustup: pass -y flag to auto-accept installation (`rustup-init -y`)

**Read Command Handling:**
- Remove all `read` commands from scripts — true non-interactive mode
- Detection via manual review of each script
- Claude's discretion: also check for other input mechanisms (select, choose, dialog, whiptail)

**Audit Approach:**
- Audit all shell scripts for interactive prompts
- Use MCP tools to search documentation for each tool's non-interactive flags
- Check: apt-get (-y), rustup-init (-y), and any other installers

### Claude's Discretion

- Whether to check for input mechanisms beyond `read` (select, dialog, whiptail)
- Exact log file naming convention
- Format of progress messages

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| NINT-01 | All apt commands use DEBIAN_FRONTEND=noninteractive | Set `export DEBIAN_FRONTEND=noninteractive` in install.sh before sourcing sub-scripts |
| NINT-02 | All apt commands use -y flag (no confirmation prompts) | All apt commands already have `-y` flag — verified in install_dependencies.sh |
| NINT-03 | No script uses `read` or other blocking input | Grep search confirmed no `read`, `select`, `dialog`, or `whiptail` commands exist |
| NINT-04 | Package configuration prompts pre-answered (debconf-set-selections where needed) | DEBIAN_FRONTEND=noninteractive accepts all defaults; no specific pre-seeding needed per user decision |
</phase_requirements>

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| apt-get | Debian/Ubuntu native | Package installation | Script-stable interface vs `apt` CLI |
| debconf | Debian native | Package configuration database | Handles all package prompts uniformly |
| rustup-init | Latest | Rust toolchain installer | Official Rust installation method |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| DEBIAN_FRONTEND=noninteractive | N/A | Environment variable | Set before ANY apt command runs |
| `-y` flag | N/A | Auto-confirm prompts | Every apt-get install/upgrade command |
| debconf-set-selections | N/A | Pre-seed package answers | Only for packages with custom prompts (not needed per user decision) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| apt-get | apt | apt is for interactive use, apt-get is stable for scripts |
| DEBIAN_FRONTEND per-command | Global export | Per-command is verbose; global ensures no command is missed |
| debconf pre-seeding | Accept defaults | Pre-seeding is complex; defaults work for most packages |

**Implementation:**
No installation needed — these are standard Debian/Ubuntu tools.

## Architecture Patterns

### Recommended Pattern: Global Non-Interactive Setup

Place environment configuration at the TOP of the main entry script, before any sub-scripts are sourced:

```bash
#!/bin/bash

# Abort on Error
set -e

# Non-Interactive Mode - MUST be set before ANY apt commands
export DEBIAN_FRONTEND=noninteractive

# Determine toolpath if not set already
relativepath="./"
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# ... rest of script
```

**Why this location:** Sub-scripts are sourced after, so the environment variable propagates automatically to all child processes.

### Pattern 1: apt-get Commands with -y Flag

**What:** Every apt-get install/upgrade/remove command includes `-y`
**When to use:** Always in non-interactive scripts

**Example:**
```bash
# Correct - non-interactive
apt-get install -y package-name

# Also correct with sudo
sudo apt-get install -y package-name

# Wrong - will prompt for confirmation
apt-get install package-name
```

**Source:** Debian best practices for scripted installations

### Pattern 2: rustup-init Silent Installation

**What:** Pass `-y` flag to skip confirmation prompt
**When to use:** When running rustup-init in scripts

**Example:**
```bash
# Correct - non-interactive
./rustup-init -y

# Alternative via curl pipe (official method)
curl https://sh.rustup.rs -sSf | sh -s -- -y

# Wrong - will prompt for confirmation
./rustup-init
```

**Source:** [Rust Forge - Other Installation Methods](https://forge.rust-lang.org/infra/other-installation-methods.html)

### Anti-Patterns to Avoid

- **Forgetting DEBIAN_FRONTEND:** Setting it mid-script after some apt commands have already run
- **Using `apt` instead of `apt-get`:** `apt` is designed for interactive use, output format may change
- **Missing `-y` flag:** Any apt-get command without `-y` will hang waiting for user input
- **Using `read` for configuration:** Blocking input commands break automation entirely

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Package configuration prompts | Custom expect scripts | DEBIAN_FRONTEND=noninteractive | Built-in, reliable, no dependencies |
| Confirming apt actions | Manual yes echo piped to apt | apt-get -y | Native flag, handles all cases |
| Rust installation confirmation | Custom input handling | rustup-init -y | Official flag, always works |

**Key insight:** These are solved problems with native flags. Custom solutions add complexity and failure points.

## Common Pitfalls

### Pitfall 1: DEBIAN_FRONTEND Set Too Late
**What goes wrong:** Some apt commands run before DEBIAN_FRONTEND is set, causing interactive prompts
**Why it happens:** Environment variable is set after early apt commands in sub-scripts
**How to avoid:** Set `export DEBIAN_FRONTEND=noninteractive` at the VERY TOP of install.sh, before sourcing any sub-scripts
**Warning signs:** Script hangs on "Configuring packages..." dialog

### Pitfall 2: Inconsistent apt Command Styles
**What goes wrong:** Mix of `apt`, `apt-get`, with/without `sudo`, missing `-y` on some commands
**Why it happens:** Different scripts written at different times or by different people
**How to avoid:** Audit ALL scripts, standardize on `apt-get install -y` pattern everywhere
**Warning signs:** Some apt commands have `-y`, others don't; some use `apt`, others `apt-get`

### Pitfall 3: rustup-init Without -y Flag
**What goes wrong:** Script hangs at "Proceed with installation? (y/N)" prompt
**Why it happens:** rustup-init is interactive by default
**How to avoid:** Always add `-y` flag: `./rustup-init -y`
**Warning signs:** Script stops at Rust installation step with no error

### Pitfall 4: Hidden Interactive Commands
**What goes wrong:** Commands like `read`, `select`, `dialog`, `whiptail` block execution
**Why it happens:** Developer added user prompt for configuration or confirmation
**How to avoid:** Grep for `\bread\b`, `\bselect\b`, `dialog`, `whiptail` in all .sh files
**Warning signs:** Script pauses unexpectedly with no visible prompt

## Code Examples

### Non-Interactive apt-get Installation Pattern

```bash
#!/bin/bash
set -e

# Non-Interactive Mode - MUST be first
export DEBIAN_FRONTEND=noninteractive

# Update and install
apt-get update -y
apt-get install -y \
    curl \
    git \
    build-essential

# Clean up (optional)
apt-get autoremove -y
apt-get clean
```

**Source:** Debian/Ubuntu best practices for automation

### rustup-init Non-Interactive Pattern

```bash
#!/bin/bash
set -e

# Download Rustup
wget "https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init" -O rustup-init
chmod +x rustup-init

# Install silently
./rustup-init -y

# Clean up
rm rustup-init
```

**Source:** [Rust Forge - Other Installation Methods](https://forge.rust-lang.org/infra/other-installation-methods.html)

### Debconf Pre-Seeding (Only If Needed)

```bash
# Only needed for packages with custom prompts that require non-default answers
# NOT needed for this project per user decision

# Example pattern if ever needed:
echo "package-name package-name/question string value" | debconf-set-selections
```

**Source:** [Debian Wiki - debconf](https://wiki.debian.org/debconf)

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Per-command DEBIAN_FRONTEND | Global export at script start | Standard practice | Ensures no command is missed |
| debconf pre-seeding for all packages | Accept defaults with noninteractive | Simplified over time | Less maintenance, works for 99% of packages |
| Manual Rust installation | rustup-init with -y flag | Since rustup became standard | One-line silent install |

**Deprecated/outdated:**
- `yes | apt-get install`: Use `-y` flag instead (cleaner, no pipe overhead)
- `expect` scripts for apt: Use DEBIAN_FRONTEND=noninteractive instead (native, no dependency)

## Current Codebase Analysis

### Files Requiring Modification

| File | Line(s) | Issue | Fix |
|------|---------|-------|-----|
| install.sh | 4-6 | Missing DEBIAN_FRONTEND | Add `export DEBIAN_FRONTEND=noninteractive` after shebang |
| scripts/install_rust.sh | 20 | Missing `-y` flag | Change `./rustup-init` to `./rustup-init -y` |

### Files Already Correct

| File | Status | Notes |
|------|--------|-------|
| scripts/install_dependencies.sh | `-y` flag present on all apt commands | 8 apt commands all have `-y` |
| functions.sh | No interactive commands | Only utility functions |
| config.sh | No interactive commands | Only variable exports |
| uninstall.sh | No interactive commands | Only make uninstall and rm commands |

### Verification Commands

```bash
# Verify no read commands exist
grep -rn '\bread\b' *.sh scripts/*.sh

# Verify no select commands exist
grep -rn '\bselect\b' *.sh scripts/*.sh

# Verify no dialog/whiptail commands exist
grep -rn 'dialog\|whiptail' *.sh scripts/*.sh

# Verify DEBIAN_FRONTEND is set
grep -n 'DEBIAN_FRONTEND' install.sh

# Verify rustup-init has -y flag
grep -n 'rustup-init' scripts/install_rust.sh
```

## Open Questions

1. **Log File Naming Convention**
   - What we know: User decided "log file in script directory (e.g., `install.log`)"
   - What's unclear: Exact naming (timestamp-based vs simple name)
   - Recommendation: Use `install.log` as specified in CONTEXT.md, placed in `$toolpath/install.log`

2. **Progress Message Format**
   - What we know: User decided "minimal progress output (current step/phase, success/fail at end)"
   - What's unclear: Exact format/wording
   - Recommendation: Simple format like `[1/N] Installing dependencies...` followed by `[OK]` or `[FAIL]`

## Sources

### Primary (HIGH confidence)
- Debian Wiki - debconf: https://wiki.debian.org/debconf - Package configuration documentation
- Rust Forge - Other Installation Methods: https://forge.rust-lang.org/infra/other-installation-methods.html - Official rustup silent install

### Secondary (MEDIUM confidence)
- Debian Handbook - Automatic Upgrades: https://www.debian.org/doc/manuals/debian-handbook/sect.automatic-upgrades.zh-cn.html - Non-interactive apt practices
- Ansible debconf Module: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/debconf_module.html - Practical debconf usage patterns

### Tertiary (LOW confidence)
- Codebase analysis of existing scripts - Direct file reading and grep searches

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - These are well-documented Debian/Ubuntu standard practices
- Architecture: HIGH - Clear patterns from official documentation
- Pitfalls: HIGH - Common issues well-documented in community resources

**Research date:** 2026-02-28
**Valid until:** These practices are stable Debian/Ubuntu fundamentals - valid indefinitely
