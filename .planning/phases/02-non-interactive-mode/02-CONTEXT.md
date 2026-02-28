# Phase 2: Non-Interactive Mode - Context

**Gathered:** 2026-02-28
**Status:** Ready for planning

<domain>
## Phase Boundary

The installation completes without any user interaction or blocking prompts. User can start install.sh and walk away — it finishes successfully without any input required.

</domain>

<decisions>
## Implementation Decisions

### Error Handling Strategy
- Fail fast: stop immediately on any error with clear error message
- Leave partial state as-is on failure (no rollback, no resume capability)
- Error output: show failing command, exit code, and last few lines of output (context summary)
- No retries: fail immediately on first error, user can re-run manually

### Output Verbosity
- Default: minimal progress output (current step/phase, success/fail at end)
- apt-get and build output suppressed by default
- Log full output to file in script directory (e.g., `install.log`)
- Add --verbose/-v flag to enable full console output for debugging

### Debconf/Package Configuration
- Set DEBIAN_FRONTEND=noninteractive globally to accept all defaults
- No specific package pre-seeding required
- Rustup: pass -y flag to auto-accept installation (`rustup-init -y`)

### Read Command Handling
- Remove all `read` commands from scripts — true non-interactive mode
- Detection via manual review of each script
- Claude's discretion: also check for other input mechanisms (select, choose, dialog, whiptail)

### Audit Approach
- Audit all shell scripts for interactive prompts
- Use MCP tools to search documentation for each tool's non-interactive flags
- Check: apt-get (-y), rustup-init (-y), and any other installers

### Claude's Discretion
- Whether to check for input mechanisms beyond `read` (select, dialog, whiptail)
- Exact log file naming convention
- Format of progress messages

</decisions>

<specifics>
## Specific Ideas

- User discovered rustup-init has interactive prompt — needs -y flag
- Refer to CLAUDE.md for MCP tools to research documentation (Context7, Zread, Kindly-MCP)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 02-non-interactive-mode*
*Context gathered: 2026-02-28*
