# Architecture Research

**Domain:** Podman Compilation Scripts (Shell/Bash)
**Researched:** 2026-02-28
**Confidence:** HIGH (Based on existing project analysis + official Podman documentation)

## Standard Architecture

### System Overview

```
+-----------------------------------------------------------------------------+
|                           Entry Point (install.sh)                          |
|  - Loads configuration                                                      |
|  - Sources shared functions                                                 |
|  - Orchestrates build order                                                 |
+-----------------------------------+-----------------------------------------+
                                    |
            +-----------------------+-----------------------+
            |                       |                       |
            v                       v                       v
+-------------------+   +-------------------+   +-------------------+
|  Toolchain Layer  |   |  Dependencies     |   |  Component Layer  |
|  (install_*.sh)   |   |  (apt packages)   |   |  (build_*.sh)     |
+-------------------+   +-------------------+   +-------------------+
|  - Go (golang)    |   |  - libseccomp     |   |  - podman         |
|  - Rust (cargo)   |   |  - libgpgme       |   |  - conmon         |
|  - Protoc         |   |  - libbtrfs       |   |  - crun/runc      |
|                   |   |  - libsystemd     |   |  - netavark       |
|                   |   |  - libapparmor    |   |  - aardvark-dns   |
|                   |   |  - build-essent.  |   |  - fuse-overlayfs |
|                   |   |  - ...            |   |  - slirp4netns    |
|                   |   |                   |   |  - pasta/passt    |
|                   |   |                   |   |  - buildah        |
|                   |   |                   |   |  - skopeo         |
|                   |   |                   |   |  - toolbox        |
+---------+---------+   +---------+---------+   +---------+---------+
          |                       |                       |
          +-----------+-----------+-----------------------+
                      |
                      v
+-----------------------------------------------------------------------------+
|                         Shared Functions (functions.sh)                     |
|  - git_clone_update()  : Clone or update git repositories                   |
|  - git_checkout()      : Checkout specific tag or latest                    |
|  - get_latest_tag()    : Determine latest stable version                     |
|  - log_component()     : Record installation/upgrade to log                  |
|  - remove_if_user_installed() : Safe file removal for uninstall             |
+-----------------------------------------------------------------------------+
                      |
                      v
+-----------------------------------------------------------------------------+
|                         Configuration (config.sh)                           |
|  - Version variables (PODMAN_VERSION, GOVERSION, CRUN_VERSION, etc.)        |
|  - Path variables (BUILD_ROOT, GOPATH, GOROOT, PROTOC_PATH)                 |
|  - Build root directory creation                                            |
+-----------------------------------------------------------------------------+
                      |
                      v
+-----------------------------------------------------------------------------+
|                         Build Directory (./build/)                          |
|  - Contains cloned source repositories                                      |
|  - Each component has its own subdirectory                                  |
|  - Persists across runs for incremental updates                             |
+-----------------------------------------------------------------------------+
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| `install.sh` | Main entry point, orchestrates build order | Sources config, functions, then all build scripts |
| `config.sh` | Centralized version and path configuration | Environment variables for all component versions |
| `functions.sh` | Reusable shell functions | Git operations, logging, utility functions |
| `scripts/install_*.sh` | Install build toolchains (Go, Rust, Protoc) | Download binaries or run installers |
| `scripts/install_dependencies.sh` | Install apt/build dependencies | apt-get install commands |
| `scripts/build_*.sh` | Build individual Podman components | Clone, checkout, make, install |
| `uninstall.sh` | Remove all installed components | make uninstall + manual cleanup |
| `./build/` | Source code repository storage | Git clones of all components |
| `./log/` | Installation history | Date-stamped log files |

### Component Dependency Graph

```
                    ┌─────────────┐
                    │    Go       │ (Required for Go-based builds)
                    └──────┬──────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         v                 v                 v
   ┌───────────┐    ┌───────────┐    ┌───────────┐
   │  Podman   │    │  Buildah  │    │  Skopeo   │
   └─────┬─────┘    └───────────┘    └───────────┘
         │
         v
   ┌───────────┐
   │  Conmon   │ (Requires Go for build)
   └───────────┘

                    ┌─────────────┐
                    │    Rust     │ (Required for Rust-based builds)
                    └──────┬──────┘
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         v                 v                 v
   ┌───────────┐    ┌───────────┐    ┌───────────┐
   │  Netavark │    │ Aardvark  │    │   Crun    │
   │           │    │    DNS    │    │           │
   └───────────┘    └───────────┘    └───────────┘

                    ┌─────────────┐
                    │   Protoc    │ (Protocol buffers compiler)
                    └──────┬──────┘
                           │
         ┌─────────────────┼─────────────────┐
         v                 v                 v
   ┌───────────┐    ┌───────────┐    ┌───────────┐
   │  Podman   │    │  Netavark │    │  Crun     │
   └───────────┘    └───────────┘    └───────────┘

   Runtime Dependencies (Podman requires these to be installed first):
   ┌───────────────────────────────────────────────────────────────┐
   │  Conmon → Crun/Runc → Netavark → Aardvark-DNS → Fuse-OverlayFS│
   │  → Slirp4netns/Pasta → Catatonit                               │
   └───────────────────────────────────────────────────────────────┘
```

## Recommended Project Structure

```
podman-debian/
├── install.sh              # Main entry point
├── uninstall.sh            # Cleanup script
├── config.sh               # Version configuration (user creates from .example)
├── config.sh.example       # Example configuration template
├── functions.sh            # Shared shell functions
├── scripts/
│   ├── install_dependencies.sh  # apt-get dependencies
│   ├── install_go.sh            # Go toolchain installation
│   ├── install_rust.sh          # Rust toolchain installation
│   ├── install_protoc.sh        # Protoc installation
│   ├── build_podman.sh          # Core: Podman binary
│   ├── build_buildah.sh         # Image builder
│   ├── build_conmon.sh          # Container monitor
│   ├── build_crun.sh            # OCI runtime (C)
│   ├── build_runc.sh            # OCI runtime (Go)
│   ├── build_netavark.sh        # Network stack
│   ├── build_aardvark_dns.sh    # DNS for containers
│   ├── build_fuse-overlayfs.sh  # Rootless storage
│   ├── build_slirp4netns.sh     # Rootless networking
│   ├── build_pasta.sh           # Modern rootless networking
│   ├── build_skopeo.sh          # Image transport
│   ├── build_catatonit.sh       # Container init
│   ├── build_go-md2man.sh       # Man page generator
│   └── build_toolbox.sh         # Toolbox utility
├── build/                  # Source repositories (created at runtime)
├── log/                    # Installation logs (created at runtime)
└── disabled/               # Deprecated scripts
```

### Structure Rationale

- **Root-level scripts**: Entry points (`install.sh`, `uninstall.sh`) stay at root for easy access
- **scripts/**: All component builds isolated in subdirectory for organization
- **config.sh**: Separate file allows version pinning without code changes
- **functions.sh**: DRY principle - shared git/logging logic centralized
- **build/**: Persistent build directory enables incremental updates (git pull vs clone)

## Architectural Patterns

### Pattern 1: Source-Then-Execute

**What:** Each build script sources config.sh and functions.sh before executing logic.

**When to use:** All shell scripts that need shared configuration or utilities.

**Trade-offs:**
- Pros: Consistent environment, centralized configuration
- Cons: Requires files exist at expected paths, slight overhead

**Example:**
```bash
#!/bin/bash

# Determine toolpath if not set already
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
    toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath})
fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Build logic here...
```

### Pattern 2: Idempotent Git Operations

**What:** Clone if missing, fetch/update if exists. Enables re-running without errors.

**When to use:** All scripts that retrieve source code from git repositories.

**Trade-offs:**
- Pros: Safe to re-run, supports incremental updates
- Cons: More complex than simple clone

**Example:**
```bash
git_clone_update() {
    local lrepository="$1"
    local lfolder="$2"

    if [ -d "${lfolder}" ] && [ -d "${lfolder}/.git" ]; then
        cd "${lfolder}"
        git fetch --all
        git fetch --tags
    else
        git clone "${lrepository}" "${lfolder}"
    fi
}
```

### Pattern 3: Version Configuration Centralization

**What:** All version numbers defined in single config file, not scattered in scripts.

**When to use:** Any project with multiple versioned components.

**Trade-offs:**
- Pros: Easy version updates, supports pinning, reproducible builds
- Cons: Requires config file management

**Example (config.sh):**
```bash
export GOVERSION="1.23.3"
export PODMAN_VERSION="5.5.2"
export CRUN_VERSION="1.25.1"
export CONMON_VERSION="2.1.13"
```

### Pattern 4: Toolpath Resolution

**What:** Scripts determine their location relative to project root, enabling execution from any directory.

**When to use:** Shell scripts that need to reference other project files.

**Trade-offs:**
- Pros: Scripts work from any working directory
- Cons: Adds boilerplate to every script

**Example:**
```bash
relativepath="../"
if [[ ! -v toolpath ]]; then
    scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
    toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath})
fi
```

### Pattern 5: Build Tag Selection

**What:** Use Make BUILDTAGS to enable/disable features based on available dependencies.

**When to use:** Go-based builds with optional features (seccomp, selinux, apparmor, systemd).

**Trade-offs:**
- Pros: Adaptable to different system configurations
- Cons: Requires understanding of available tags

**Example:**
```bash
# Debian/Ubuntu typically use:
make BUILDTAGS="seccomp apparmor systemd" PREFIX=/usr

# Fedora/RHEL use:
make BUILDTAGS="selinux seccomp systemd" PREFIX=/usr
```

## Data Flow

### Installation Flow

```
[User runs install.sh]
        |
        v
[Source config.sh] --> Load version variables, paths
        |
        v
[Source functions.sh] --> Load utility functions
        |
        v
[install_dependencies.sh] --> apt-get install build dependencies
        |
        v
[install_rust.sh] --> Install Rust toolchain
        |
        v
[install_protoc.sh] --> Install Protocol Buffers
        |
        v
[install_go.sh] --> Install Go toolchain
        |
        v
[build_aardvark_dns.sh] --> Clone, build, install aardvark-dns
        |
        v
[build_netavark.sh] --> Clone, build, install netavark
        |
        v
[build_crun.sh] --> Clone, build, install crun
        |
        v
[build_conmon.sh] --> Clone, build, install conmon
        |
        v
... (other components) ...
        |
        v
[build_podman.sh] --> Clone, build, install podman (LAST)
        |
        v
[Installation Complete]
```

### Version Detection Flow

```
[Build Script Starts]
        |
        v
[Check if VERSION_TAG is set in config.sh]
        |
        +-- Set --> Use specified version
        |
        +-- Not Set --> Call get_latest_tag()
                            |
                            v
                      [git tag --list --sort -creatordate]
                            |
                            v
                      [Filter out -rc tags]
                            |
                            v
                      [Sort by version, take highest]
                            |
                            v
                      [Return latest stable tag]
```

### State Flow

```
[Empty System]
      |
      v
[./build/ directory created]
      |
      v
[Git repos cloned into ./build/<component>/]
      |
      v
[Source checked out to specified tag]
      |
      v
[make && make install]
      |
      v
[Binaries installed to /usr/local/bin/ or /usr/bin/]
      |
      v
[Log entry written to ./log/YYYYMMDD.log]
```

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| Single user | Current architecture is optimal |
| Multiple machines | Add configuration profiles (e.g., config.arm.sh, config.amd64.sh) |
| CI/CD integration | Add --non-interactive flags, structured logging, exit codes |

### Scaling Priorities

1. **First bottleneck:** Architecture detection - currently hardcoded amd64 in Go download
   - Fix: Detect architecture with `uname -m` and download appropriate binary

2. **Second bottleneck:** Error handling - scripts continue on failure
   - Fix: Implement proper error handling with `set -e` and trap handlers

## Anti-Patterns

### Anti-Pattern 1: Hardcoded Architecture

**What people do:** Hardcode `x86_64` or `amd64` in download URLs.

**Why it's wrong:** Fails on ARM systems (Raspberry Pi, ARM VMs).

**Do this instead:**
```bash
ARCH=$(uname -m)
case $ARCH in
    x86_64) GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    armv7l) GOARCH="armv6l" ;;
esac
wget "https://go.dev/dl/${GOTAG}.linux-${GOARCH}.tar.gz"
```

### Anti-Pattern 2: Mixed Error Handling

**What people do:** Some scripts have `set -e`, others don't, inconsistent error handling.

**Why it's wrong:** Silent failures, partial installations, debugging nightmare.

**Do this instead:** Consistent error handling strategy across all scripts:
```bash
set -e  # Exit on error
trap 'echo "Error on line $LINENO in $0"' ERR
```

### Anti-Pattern 3: Scattered Version Numbers

**What people do:** Version numbers hardcoded in individual build scripts.

**Why it's wrong:** Updates require editing multiple files, version drift between components.

**Do this instead:** Centralize in config.sh with clear documentation:
```bash
# === Core Components ===
export PODMAN_VERSION="5.5.2"
export CONMON_VERSION="2.1.13"

# === Runtimes ===
export CRUN_VERSION="1.25.1"
export RUNC_VERSION="1.3.0"
```

### Anti-Pattern 4: Interactive Prompts

**What people do:** Use apt-get without -y flag, allow interactive prompts.

**Why it's wrong:** Blocks automated/unattended installations.

**Do this instead:**
```bash
export DEBIAN_FRONTEND=noninteractive
apt-get install -y package-name
```

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| GitHub (containers/*) | git clone/fetch | Primary source for most components |
| go.dev | wget tarball | Go binary downloads |
| static.rust-lang.org | wget binary | Rust installer downloads |
| passt.top | git clone | Pasta/Passt source |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| config.sh <-> build scripts | Environment variables | Read-only from build scripts |
| functions.sh <-> build scripts | Function calls | Shared utilities |
| build scripts <-> system | make install, cp | System-wide binary installation |
| uninstall.sh <-> build/ | make uninstall | Requires source present |

## Build Order Requirements

**Critical:** Components must be built in dependency order:

```
1. apt dependencies (install_dependencies.sh)
2. Go toolchain (install_go.sh)
3. Rust toolchain (install_rust.sh) - for netavark, aardvark-dns, crun
4. Protoc (install_protoc.sh) - for podman, netavark, crun
5. Runtime dependencies (any order after toolchains):
   - crun or runc (OCI runtime)
   - conmon (container monitor)
   - netavark (networking)
   - aardvark-dns (DNS)
   - fuse-overlayfs (storage)
   - slirp4netns or pasta (rootless networking)
   - catatonit (init process)
6. Podman core (build_podman.sh) - depends on all above
7. Optional tools: buildah, skopeo, toolbox
```

## Sources

- [Podman Official Installation Documentation](https://podman.io/docs/installation) - HIGH confidence
- [Podman GitHub Repository](https://github.com/containers/podman) - HIGH confidence
- [Debian Wiki - Podman](https://wiki.debian.org/Podman) - MEDIUM confidence
- Existing project script analysis - HIGH confidence (direct code review)
- [Tencent Cloud - Podman Architecture Analysis](https://cloud.tencent.com/developer/article/2549650) - MEDIUM confidence

---
*Architecture research for: Podman Debian Compilation Scripts*
*Researched: 2026-02-28*
