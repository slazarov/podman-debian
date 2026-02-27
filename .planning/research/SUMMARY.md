# Project Research Summary

**Project:** Podman Debian Compiler
**Domain:** Shell-based compilation scripts for building Podman from source
**Researched:** 2026-02-28
**Confidence:** HIGH

## Executive Summary

This is a build automation toolchain for compiling Podman and its runtime dependencies from source on Debian/Ubuntu systems. The project automates a complex multi-component build process involving Go, Rust, and C-based projects, each with their own toolchain requirements and build systems. The key value proposition is providing a single-command installation that handles dependency resolution, toolchain setup, and component building in correct order.

The recommended approach centers on fixing the critical architecture detection gap (currently hardcoded for amd64) and implementing consistent error handling across all scripts. The existing modular architecture with centralized configuration (config.sh) and shared functions (functions.sh) provides a solid foundation. The build order is well-established: toolchains first (Go, Rust, Protoc), then runtime dependencies (conmon, crun, netavark), and finally Podman core.

Key risks include silent failures from inconsistent `set -e` usage, blocking prompts from missing `DEBIAN_FRONTEND=noninteractive`, and complete failure on ARM systems due to hardcoded download URLs. All three can be addressed in a focused Phase 1 that establishes the foundation for reliable multi-architecture support.

## Key Findings

### Recommended Stack

The project uses a shell-based architecture orchestrating multiple build systems. Go 1.24.x is required for Podman 6.x (1.23.x minimum for Podman 5.x). Rust is needed for netavark, aardvark-dns, and crun. Protoc handles protocol buffer compilation. All runtime components (conmon, crun, netavark, aardvark-dns, fuse-overlayfs, passt/pasta) must be built before Podman itself.

**Core technologies:**
- **Go 1.24.x:** Primary build compiler for Podman and Go-based components
- **Rust (via rustup):** Required for netavark, aardvark-dns, and crun builds
- **gcc/make:** C compiler and build orchestration for conmon and native dependencies
- **apt packages:** libseccomp-dev, libgpgme-dev, libsystemd-dev, libapparmor-dev, and 15+ other build dependencies

**Critical version requirements:**
- Go 1.24.6 required for Podman 6.x (main branch)
- crun minimum 1.14.3, runc minimum 1.1.11
- conmon 2.1.12+ required for Podman 5.x/6.x compatibility

### Expected Features

The existing codebase provides dependency installation, build logging, version detection, and uninstall capability. The primary gaps are architecture detection (hardcoded amd64), consistent error handling, and non-interactive mode.

**Must have (table stakes):**
- **Architecture Detection** - Currently missing; script fails on ARM systems
- **Non-Interactive Mode** - Add DEBIAN_FRONTEND=noninteractive throughout
- **Error Handling** - Uncomment `set -e` and add trap handlers across all scripts
- **Build Logging** - Already implemented via `log_component()` function

**Should have (competitive):**
- **Progress Indicator** - Visual feedback during long compilation (10+ minutes)
- **Pre-flight Validation** - Check disk space, OS version before starting
- **Idempotent Operations** - Safe to run multiple times without errors
- **Rootless Configuration** - Post-install setup for rootless Podman usage

**Defer (v2+):**
- **Resumable Builds** - Checkpoint-based resume requires significant complexity
- **Component Selection** - CLI flags to skip optional components
- **Multi-Distro Support** - Each distro has different package naming

### Architecture Approach

The existing modular architecture is well-designed: entry point (install.sh) sources configuration and functions, then orchestrates component builds in dependency order. Each build script handles its own clone, checkout, make, and install steps.

**Major components:**
1. **config.sh** - Centralized version and path configuration
2. **functions.sh** - Shared git operations, logging, utility functions
3. **scripts/install_*.sh** - Toolchain installation (Go, Rust, Protoc)
4. **scripts/build_*.sh** - Individual component builds (15+ scripts)
5. **install.sh** - Main entry point, orchestration

**Key architectural patterns:**
- Source-Then-Execute: Each script sources config.sh and functions.sh
- Idempotent Git Operations: Clone if missing, fetch if exists
- Version Centralization: All versions in config.sh
- Build Tag Selection: `make BUILDTAGS="seccomp apparmor systemd"`

### Critical Pitfalls

1. **Hardcoded x86_64 Architecture in Download URLs** - Scripts fail silently on ARM; use `uname -m` detection with proper mapping to Go's `arm64`, Protoc's `aarch_64`, Rust's `aarch64-unknown-linux-gnu`

2. **Inconsistent `set -e` Usage** - Some scripts have it commented out; cascading silent failures; must use `set -euo pipefail` with trap handlers consistently

3. **Missing DEBIAN_FRONTEND=noninteractive** - apt-get hangs on config prompts even with `-y`; must set globally for unattended operation

4. **Architecture Naming Convention Mismatches** - Different tools use different ARM naming (`arm64` vs `aarch_64` vs `aarch64`); create central detection function outputting all variants

5. **Overwriting Package-Managed Binaries** - Using `/usr/bin` for compiled binaries conflicts with apt; always use `/usr/local/bin`

## Implications for Roadmap

Based on combined research, suggested phase structure:

### Phase 1: Foundation - Architecture Support and Error Handling
**Rationale:** These are the critical blockers preventing the script from working on ARM and from failing cleanly on errors. Must be fixed before any other enhancements.
**Delivers:** Working multi-architecture support with reliable error reporting
**Addresses:** Architecture Detection (P1), Error Handling (P1)
**Avoids:** Pitfall 1 (hardcoded x86_64), Pitfall 2 (inconsistent set -e), Pitfall 4 (naming mismatches)

### Phase 2: Unattended Installation
**Rationale:** Once the script works reliably, make it fully automatable for headless/server use cases
**Delivers:** True non-interactive mode, safe installation paths
**Addresses:** Non-Interactive Mode (P1)
**Avoids:** Pitfall 3 (missing DEBIAN_FRONTEND), Pitfall 5 (overwriting package files)
**Uses:** DEBIAN_FRONTEND pattern from STACK.md, /usr/local/bin pattern from PITFALLS.md

### Phase 3: User Experience Enhancements
**Rationale:** With core functionality solid, improve the operator experience
**Delivers:** Progress indication, pre-flight validation, clear success/failure messages
**Addresses:** Progress Indicator (P2), Pre-flight Validation (P2)
**Avoids:** UX pitfalls from PITFALLS.md (silent failures, no progress, blocking on config)

### Phase 4: Idempotency and Robustness
**Rationale:** Make the script safe to re-run and resilient to edge cases
**Delivers:** Idempotent operations, resume capability, checksum verification
**Addresses:** Idempotent Operations (P2), Rootless Configuration (P2)
**Implements:** Check-before-action pattern from ARCHITECTURE.md

### Phase Ordering Rationale

- **Dependencies first:** Architecture detection and error handling are prerequisites for all other work
- **Core before polish:** Unattended mode is more valuable than progress bars for the target audience
- **Foundation before features:** UX improvements and idempotency build on stable foundation
- **Security last:** Checksum verification requires stable download infrastructure

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 4:** Rootless configuration has complex sysctl and subuid/subgid requirements that may need additional research
- **Phase 3:** Pre-flight validation should check kernel features (user namespaces, cgroups) - may need research on detection methods

Phases with standard patterns (skip research-phase):
- **Phase 1:** Architecture detection is well-documented with clear patterns in PITFALLS.md
- **Phase 2:** Non-interactive mode has standard DEBIAN_FRONTEND pattern

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Verified against official Podman documentation and go.mod |
| Features | MEDIUM | Based on analysis of existing codebase + community patterns |
| Architecture | HIGH | Direct code review of existing project + official docs |
| Pitfalls | HIGH | Verified against official documentation and multiple community sources |

**Overall confidence:** HIGH

### Gaps to Address

- **Rootless configuration details:** The research identified this as a P2 feature but did not fully document the sysctl settings, subuid/subgid setup, and systemd user session requirements. Address during Phase 4 planning with targeted research.

- **Kernel feature detection:** Pre-flight validation should check for user namespace support, cgroup v2, and other kernel features. May need `/gsd:research-phase` during Phase 3 to identify complete checklist.

- **ARM testing strategy:** The architecture detection code needs validation on actual ARM hardware or VMs. Consider creating test matrix for amd64, arm64, and armv7l during Phase 1 implementation.

## Sources

### Primary (HIGH confidence)
- [Podman Official Installation Documentation](https://podman.io/docs/installation) - Build dependencies, architecture support
- [Podman GitHub Repository](https://github.com/containers/podman) - go.mod for Go version, build instructions
- [Go Official Downloads](https://go.dev/dl/) - Architecture naming conventions
- [containers/conmon GitHub](https://github.com/containers/conmon) - Version requirements
- [containers/crun GitHub](https://github.com/containers/crun) - OCI runtime requirements
- [containers/netavark GitHub](https://github.com/containers/netavark) - Network backend requirements

### Secondary (MEDIUM confidence)
- [Debian Wiki - Podman](https://wiki.debian.org/Podman) - Distribution-specific notes
- [Protocol Buffers Releases](https://github.com/protocolbuffers/protobuf/releases) - aarch_64 naming
- [Rustup Architecture Support](https://rust-lang.github.io/rustup/) - Target triples
- Existing project script analysis - Direct code review

### Tertiary (LOW confidence)
- Community blog posts on build patterns - Validated against primary sources
- Shell scripting best practices guides - General patterns, not Podman-specific

---
*Research completed: 2026-02-28*
*Ready for roadmap: yes*
