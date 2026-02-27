# Pitfalls Research

**Domain:** Podman compilation from source on Debian/Ubuntu (amd64 and ARM)
**Researched:** 2026-02-28
**Confidence:** HIGH (verified against official documentation and multiple community sources)

## Critical Pitfalls

### Pitfall 1: Hardcoded x86_64 Architecture in Download URLs

**What goes wrong:**
Scripts download pre-built binaries (Go, Protoc, Rust) using hardcoded `x86_64` or `linux-amd64` in URLs. On ARM systems, these fail silently or with cryptic "cannot execute binary file" errors after download.

**Why it happens:**
Developers write and test scripts on x86_64 machines. The architecture part of download URLs is often overlooked until someone tries to run on ARM.

**How to avoid:**
Detect architecture dynamically and map to the correct naming convention:

```bash
# Architecture detection with proper mapping
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GOARCH="amd64"; PROTOC_ARCH="x86_64"; RUST_TARGET="x86_64-unknown-linux-gnu" ;;
    aarch64) GOARCH="arm64"; PROTOC_ARCH="aarch_64"; RUST_TARGET="aarch64-unknown-linux-gnu" ;;
    armv7l)  GOARCH="arm";   PROTOC_ARCH="armv7l";   RUST_TARGET="armv7-unknown-linux-gnueabihf" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
```

**Warning signs:**
- Download URLs contain literal `amd64`, `x86_64`, or `x86_64-unknown-linux-gnu`
- Script works on one architecture without testing architecture detection
- wget/curl succeeds but subsequent extraction or execution fails

**Phase to address:** Phase 1 (Architecture Detection)

---

### Pitfall 2: Inconsistent `set -e` Usage Across Scripts

**What goes wrong:**
Some scripts have `set -e` enabled, others have it commented out. When `source`d from a main script, failures in sub-scripts may silently continue, causing cascading failures or partial installations.

**Why it happens:**
Developers toggle `set -e` during debugging and forget to re-enable it, or copy-paste from different sources with inconsistent patterns.

**How to avoid:**
1. Use consistent error handling across ALL scripts
2. Combine `set -e` with `trap` for cleanup and logging:
```bash
#!/bin/bash
set -euo pipefail
trap 'echo "ERROR: Line $LINENO - Command: $BASH_COMMAND" >&2' ERR
```
3. Never source scripts that should fail independently - use subshells or explicit error checking

**Warning signs:**
- Scripts continue running after `wget` or `git clone` failures
- Build errors reported but installation continues
- Mixed `set -e` and `# set -e` patterns in codebase

**Phase to address:** Phase 1 (Core Script Improvements)

---

### Pitfall 3: Missing `DEBIAN_FRONTEND=noninteractive` for True Unattended Installation

**What goes wrong:**
`apt-get install` commands hang waiting for user input during configuration prompts (keyboard layout, service restarts, config file conflicts). The script appears stuck with no visible prompt.

**Why it happens:**
Even with `-y` flag, some packages prompt for configuration choices. Without `DEBIAN_FRONTEND=noninteractive`, these prompts block execution.

**How to avoid:**
```bash
# Set per-command, NOT globally (global setting breaks interactive shells later)
DEBIAN_FRONTEND=noninteractive apt-get install -y package_name

# For config file prompts, add dpkg options:
DEBIAN_FRONTEND=noninteractive apt-get install -o Dpkg::Options::="--force-confold" -y package_name
```

**Warning signs:**
- Script hangs during apt-get install
- Works on some systems but not others (depends on pending config prompts)
- Log files show partial installation

**Phase to address:** Phase 2 (Non-Interactive Mode)

---

### Pitfall 4: Architecture Naming Convention Mismatches

**What goes wrong:**
Different tools use different naming conventions for ARM64:
- `uname -m` returns `aarch64` (Linux) or `arm64` (macOS)
- Go uses `arm64`
- Protoc uses `aarch_64` (with underscore)
- Rust uses `aarch64-unknown-linux-gnu`
- Debian packages use `arm64`

Scripts checking for a single variant miss valid alternatives.

**Why it happens:**
No universal standard for architecture naming; each project chose their own convention.

**How to avoid:**
Create a central architecture detection function that outputs ALL needed variants:

```bash
detect_architecture() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            ARCH_GO="amd64"
            ARCH_PROTOC="x86_64"
            ARCH_RUST="x86_64-unknown-linux-gnu"
            ARCH_DEB="amd64"
            ;;
        aarch64|arm64)
            ARCH_GO="arm64"
            ARCH_PROTOC="aarch_64"  # Note the underscore!
            ARCH_RUST="aarch64-unknown-linux-gnu"
            ARCH_DEB="arm64"
            ;;
    esac
    export ARCH_GO ARCH_PROTOC ARCH_RUST ARCH_DEB
}
```

**Warning signs:**
- Code checks only `aarch64` or only `arm64`
- Download URLs built with wrong convention
- 404 errors when downloading ARM binaries

**Phase to address:** Phase 1 (Architecture Detection)

---

### Pitfall 5: Overwriting Package-Managed Binaries with `make install`

**What goes wrong:**
Compiling from source and using `make install` or `cp` to `/usr/bin` overwrites package-managed files. This breaks package manager tracking and can cause system instability or "file conflict" errors later.

**Why it happens:**
`make install` defaults to `/usr/local` but some scripts explicitly copy to `/usr/bin`, conflicting with apt packages.

**How to avoid:**
1. Always use `/usr/local/bin` for compiled binaries (not `/usr/bin`)
2. Or use `checkinstall` to create proper deb packages
3. Verify target directory with `dpkg -S` before overwriting:
```bash
if dpkg -S /usr/local/bin/binary &>/dev/null; then
    echo "WARNING: /usr/local/bin/binary is managed by dpkg"
fi
```

**Warning signs:**
- `sudo make install PREFIX=/usr` (overwrites system directories)
- Direct `cp` to `/usr/bin/` without checking ownership
- Subsequent apt-get operations fail with file conflicts

**Phase to address:** Phase 2 (Installation Safety)

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Skip architecture detection | Faster initial development | Complete failure on ARM | Never for multi-arch projects |
| Disable `set -e` during debug | Easier debugging | Silent failures in production | Only during active debugging, re-enable before commit |
| Use `/usr/bin` for compiled binaries | Easier PATH management | Package manager conflicts, upgrade problems | Never - use `/usr/local/bin` |
| Hardcode Go/Protoc versions | Simpler config | Security vulnerabilities, miss bug fixes | Only if pinning for compatibility, document why |
| Skip dependency checks | Faster script execution | Cryptic build failures mid-process | Never - fail fast is better |

## Integration Gotchas

Common mistakes when connecting to external services or tooling.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Go installation | Download once, assume forever | Check if correct version exists, download only if missing or version mismatch |
| Git clone | Clone every run | Check if directory exists with `.git`, use `git fetch` for updates |
| Rust via rustup | Hardcode x86_64 binary | Use `rustup-init.sh` which auto-detects architecture |
| Protoc releases | Assume x86_64 | Use `aarch_64` naming for ARM downloads |
| Build dependencies | Split across multiple apt calls | Combine into single `DEBIAN_FRONTEND=noninteractive apt-get install` call |

## Performance Traps

Patterns that work at small scale but fail as usage grows.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Re-downloading tarballs every run | Slow builds, wasted bandwidth | Check if file exists and is valid before downloading | First run on new machine |
| Re-building all components | Hours of compilation | Use `make`'s incremental build, check if binary exists | After clean |
| No parallel make | Slow ARM compilation | Use `make -j$(nproc)` for parallel builds | Always on multi-core ARM |
| Full git history clone | Slow clone, large disk usage | Use `git clone --depth 1` for build-only | When contributing code needed |

## Security Mistakes

Domain-specific security issues beyond general web security.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Downloading binaries without verification | Supply chain attack, MITM | Verify SHA256 checksums from releases |
| Running rustup-init without inspection | Arbitrary code execution | Review script or download specific version binary |
| Installing to `/usr/bin` as root | System corruption, conflicts | Use `/usr/local/bin` or user-writable directories |
| No checksum verification for tarballs | Corrupted or malicious downloads | `sha256sum -c checksumfile` after download |

## UX Pitfalls

Common user experience mistakes in this domain.

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Silent failures | User thinks install succeeded when it didn't | Check return codes, print clear success/failure messages |
| No progress indication | User thinks script hung | Print "Installing X...", "Building Y..." messages |
| Blocking on missing config | Script hangs forever with no visible prompt | Always use `DEBIAN_FRONTEND=noninteractive` |
| Running as root by default | Security risk, file ownership issues | Check for root, suggest sudo only for specific commands |
| No resume capability | Network blip requires full restart | Check each component, skip completed steps |

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **Architecture Detection:** Often only checks x86_64 - verify ARM detection with all naming variants
- [ ] **Go Installation:** Often hardcoded amd64 - verify uses detected architecture
- [ ] **Protoc Installation:** Often uses x86_64 - verify uses `aarch_64` for ARM
- [ ] **Rust Installation:** Often downloads x86_64 binary - verify uses architecture-appropriate rustup-init
- [ ] **Non-interactive Mode:** Often has `-y` but not `DEBIAN_FRONTEND=noninteractive` - verify full non-interactive
- [ ] **Error Handling:** Often has `set -e` but disabled in some scripts - verify consistent across all
- [ ] **Build Dependencies:** Often missing some packages - verify against official Podman build requirements
- [ ] **Post-Install Config:** Often missing containers.conf, registries.conf - verify configuration files created

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Wrong architecture binary downloaded | LOW | Delete binary, re-download with correct architecture |
| Partial installation (apt interrupted) | MEDIUM | `apt-get install -f`, then re-run script |
| `set -e` disabled, cascading failure | HIGH | Identify failed step from logs, clean up partial state, re-run |
| Overwrote package-managed file | HIGH | `apt-get install --reinstall package`, then fix installation method |
| Missing build dependencies | LOW | Install missing package, re-run from failed component |
| Go version mismatch | MEDIUM | Clean Go cache, reinstall correct version |

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Hardcoded x86_64 URLs | Phase 1: Architecture Detection | Run script on ARM VM, verify correct binaries downloaded |
| Inconsistent set -e | Phase 1: Core Script Improvements | Run with intentionally failing command, verify proper exit |
| Missing DEBIAN_FRONTEND | Phase 2: Non-Interactive Mode | Run in VM with pending config prompts, verify no blocking |
| Architecture naming mismatches | Phase 1: Architecture Detection | Test all architecture variant strings in URLs |
| Overwriting package files | Phase 2: Installation Safety | Run `dpkg -S` on installed binaries, verify no conflicts |
| Missing error messages | Phase 3: UX Improvements | Run with network disconnected, verify clear error message |
| No checksum verification | Phase 3: Security Hardening | Tamper with tarball, verify checksum failure |

## Sources

- [Podman GitHub - Building from Source](https://github.com/containers/podman/blob/main/install.md)
- [Go Downloads Page](https://go.dev/dl/) - architecture naming conventions
- [Protocol Buffers Releases](https://github.com/protocolbuffers/protobuf/releases) - `aarch_64` naming
- [Rustup Architecture Support](https://rust-lang.github.io/rustup/) - target triples
- [Debian Policy - File Overwrites](http://www.chiark.greenend.org.uk/doc/debian-policy/policy.html/ch-maintainerscripts.html)
- [Fedora Package Management](https://docs.fedoraproject.org/en-US/quick-docs/package-management/) - source install warnings
- [ShellCheck Common Issues](https://m.blog.csdn.net/gitblog_00253/article/details/150622042) - SC2086 and error handling
- [DEBIAN_FRONTEND Best Practices](https://gist.github.com/0x416e746f6e/b05f527f9d0c6c6c5f77e2f1e0e6f8d9) - non-interactive patterns

---
*Pitfalls research for: Podman Debian Compilation*
*Researched: 2026-02-28*
