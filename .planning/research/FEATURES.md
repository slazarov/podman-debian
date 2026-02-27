# Feature Research

**Domain:** Podman Compilation/Installation Scripts
**Researched:** 2026-02-28
**Confidence:** MEDIUM

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Dependency Installation** | Compilation requires many dev packages; users expect script to handle this | LOW | apt-get install with -y flags; current script has this |
| **Non-Interactive Mode** | Set-and-forget installation; no blocking prompts | LOW | DEBIAN_FRONTEND=noninteractive; apt -y flags |
| **Error Handling** | Build failures should be caught and reported, not silently ignored | MEDIUM | Current script has `set -e` commented out; needs improvement |
| **Uninstall Capability** | Users need a way to remove compiled software | LOW | Current script has uninstall.sh |
| **Build Logging** | Users need to debug build failures; logs capture output | LOW | Current script has `log_component` function writing to timestamped log files |
| **Version Detection** | Script should detect and use latest stable release automatically | MEDIUM | Current script has `get_latest_tag` function for git tags |

### Differentiators (Competitive Advantage)

Features that set the product apart. Not required, but valuable.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Multi-Architecture Support** | One script works on both amd64 and ARM; no manual intervention | MEDIUM | Use `uname -m` or `dpkg --print-architecture` to detect architecture |
| **Resumable/Checkpoint Builds** | Long builds can be interrupted and resumed without starting over | MEDIUM | Track completed steps in checkpoint file |
| **Progress Indicator** | Visual feedback during long compilation process | LOW | Simple progress bar or step counter |
| **Dependency Component Selection** | Allow building only needed components vs. full suite | MEDIUM | Command-line flags to skip optional components |
| **Pre-flight Validation** | Check for known issues before starting build | MEDIUM | Verify disk space, OS version, required kernel features |
| **Idempotent Operations** | Running script multiple times produces same result; no errors | MEDIUM | Check state before action; use conditions |
| **Companion Tool Building** | Build related tools (buildah, skopeo, toolbox) alongside Podman | LOW | Current script already does this |
| **Rootless Configuration** | Configure system for rootless Podman after compilation | MEDIUM | Setup subuid/subgid, sysctl settings |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **Version Pinning** | Predictability, reproducibility | Adds complexity, requires maintaining version maps; go against "latest stable" simplicity | Document how to manually set version in config.sh; don't build full version management |
| **CI/CD Integration** | Automated pipelines | Out of scope for personal use; adds complexity | Keep script simple; CI/CD can wrap this script if needed |
| **GUI Installation Wizard** | Easier for beginners | Massive scope increase; not target audience | CLI-only is appropriate for compilation scripts |
| **Multi-Distro Support** | Wider compatibility | Each distro has different package names, paths, init systems; Debian/Ubuntu focus is sufficient | Document that other distros need adaptation |
| **Binary Caching/Reuse** | Faster rebuilds | Binary compatibility issues across kernel/glibc versions; defeats purpose of compiling | Recompile from source for consistency |

## Feature Dependencies

```
[Multi-Architecture Support]
    └──requires──> [Architecture Detection (uname -m)]
                       └──requires──> [Architecture-aware download URLs]

[Resumable Builds]
    └──requires──> [Checkpoint File Tracking]
                       └──requires──> [Step State Persistence]

[Rootless Configuration]
    └──requires──> [Successful Podman Build]
    └──requires──> [subuid/subgid setup]

[Non-Interactive Mode]
    └──enhances──> [All Features] (makes everything automatable)

[Pre-flight Validation]
    └──conflicts──> [Blind Installation] (validates vs. proceeds)

[Progress Indicator]
    └──enhances──> [User Experience]
```

### Dependency Notes

- **Multi-Architecture requires Architecture Detection:** The script must detect the architecture before downloading Go, Protoc, or any architecture-specific binaries
- **Resumable Builds require Checkpoint File Tracking:** Need to persist state between runs to know what completed
- **Rootless Configuration requires Successful Podman Build:** Can only configure rootless after Podman is installed
- **Non-Interactive Mode enhances All Features:** Makes every feature usable in automated/headless scenarios
- **Pre-flight Validation conflicts with Blind Installation:** User must choose between checking first or just proceeding

## MVP Definition

### Launch With (v1)

Minimum viable product -- what's needed to validate the concept.

- [x] **Dependency Installation** -- Already exists; needed for any compilation
- [x] **Non-Interactive Mode** -- Add DEBIAN_FRONTEND=noninteractive; apt -y flags everywhere
- [x] **Build Logging** -- Already exists with `log_component` function
- [ ] **Architecture Detection** -- Core requirement for ARM support (PROJECT.md requirement)
- [ ] **Error Handling** -- Uncomment `set -e` and add proper error messages

### Add After Validation (v1.x)

Features to add once core is working.

- [ ] **Progress Indicator** -- Visual feedback for long builds
- [ ] **Pre-flight Validation** -- Check disk space, OS compatibility
- [ ] **Idempotent Operations** -- Safe to run multiple times
- [ ] **Rootless Configuration** -- Post-install setup for rootless mode

### Future Consideration (v2+)

Features to defer until product-market fit is established.

- [ ] **Resumable Builds** -- Checkpoint-based build resume
- [ ] **Component Selection** -- Skip optional components via flags
- [ ] **Dry-Run Mode** -- Show what would be done without doing it

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Architecture Detection | HIGH | MEDIUM | P1 |
| Non-Interactive Mode | HIGH | LOW | P1 |
| Error Handling | HIGH | MEDIUM | P1 |
| Pre-flight Validation | MEDIUM | MEDIUM | P2 |
| Progress Indicator | MEDIUM | LOW | P2 |
| Idempotent Operations | MEDIUM | MEDIUM | P2 |
| Rootless Configuration | MEDIUM | MEDIUM | P2 |
| Resumable Builds | LOW | HIGH | P3 |
| Component Selection | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add when possible
- P3: Nice to have, future consideration

## Competitor Feature Analysis

| Feature | Official Podman Docs | Manual Compilation | Our Approach |
|---------|---------------------|-------------------|--------------|
| Dependency Installation | Lists packages; manual install | User finds and installs | Auto-install all deps |
| Architecture Support | Generic instructions | User adapts manually | Auto-detect and adapt |
| Non-Interactive | Not addressed | Not addressed | Full -y flags, no prompts |
| Logging | Not addressed | Manual `2>&1 \| tee` | Automatic timestamped logs |
| Uninstall | `make uninstall` | Manual | Dedicated uninstall script |
| Companion Tools | Separate builds | Separate builds | All-in-one build |

## Current Script Feature Assessment

Based on analysis of existing codebase:

| Feature | Status | Location |
|---------|--------|----------|
| Dependency Installation | Partial | `scripts/install_dependencies.sh` |
| Non-Interactive Mode | Missing | Needs `DEBIAN_FRONTEND=noninteractive` |
| Error Handling | Partial | `set -e` commented out |
| Build Logging | Implemented | `functions.sh` - `log_component()` |
| Version Detection | Implemented | `functions.sh` - `get_latest_tag()` |
| Architecture Detection | Missing | Hardcoded `linux-amd64` in `scripts/install_go.sh` |
| Uninstall Capability | Implemented | `uninstall.sh` |
| Git Repository Management | Implemented | `functions.sh` - `git_clone_update()`, `git_checkout()` |

## Sources

- [Podman Official GitHub Repository](https://github.com/containers/podman) - Official documentation and build instructions (HIGH confidence)
- [Podman Build from Source Guide](https://m.blog.csdn.net/weixin_39660059/article/details/151677459) - Build steps for Rocky/RHEL (MEDIUM confidence)
- [Architecture Detection Methods](https://m.blog.csdn.net/weixin_35749440/article/details/156438242) - arm64/amd64 detection patterns (MEDIUM confidence)
- [Idempotent Shell Script Design](https://www.php.cn/link/5b19b0dc3d8cba8cc94af0cc23b2bca1) - Best practices for idempotent scripts (MEDIUM confidence)
- [Production Shell Script Guide](https://my.oschina.net/jojo7677/blog/17379570) - Production-grade scripting patterns (MEDIUM confidence)
- [Shell Progress Bar Implementation](https://cloud.tencent.com/developer/article/2391433) - Progress indicator patterns (MEDIUM confidence)
- [Go Installation Script Examples](https://go.dev/dl/) - Official Go download URL patterns (HIGH confidence)

---
*Feature research for: Podman Debian Compiler*
*Researched: 2026-02-28*
