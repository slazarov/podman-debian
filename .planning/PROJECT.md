# Podman Debian Compiler

## What This Is

A shell script suite that compiles and installs the latest stable Podman from source on Debian/Ubuntu systems. Works on both amd64 and ARM64 architectures with automatic detection. Features fully unattended installation, pre-flight system validation, multi-layer build caching (sccache, Go cache, ccache, mold), production-ready container runtime configuration with seccomp profiles, and complete man page documentation.

## Core Value

Compile and install Podman on any Debian/Ubuntu system without user interaction.

## Requirements

### Validated

- ✓ Compile Podman from source on amd64 — existing
- ✓ Install compiled Podman to system — existing
- ✓ Auto-detect system architecture (amd64 vs ARM) — v1.0
- ✓ Compile Podman on ARM Ubuntu/Debian VMs — v1.0
- ✓ Run fully unattended/non-interactive — v1.0
- ✓ No blocking prompts during installation — v1.0
- ✓ Architecture-aware toolchain installers (Go, Protoc, Rust) — v1.0
- ✓ Robust error handling with immediate failure and context — v1.0
- ✓ Progress tracking with elapsed time — v1.0
- ✓ Build output logging — v1.0
- ✓ Clean uninstall script — v1.0
- ✓ Parallel compilation with make -j NPROC — v1.0
- ✓ Shallow git clones for faster downloads — v1.0
- ✓ Go compiler optimizations (GOGC, gcflags, ldflags) — v1.0
- ✓ Cargo parallelization — v1.0
- ✓ Remove deprecated runc and slirp4netns (crun+pasta only) — v1.1
- ✓ Pre-flight system validation (cgroups, subuid, FUSE, kernel, noexec) — v1.1
- ✓ sccache for Rust build caching (50-90% rebuild speedup) — v1.1
- ✓ Enhanced containers.conf (crun runtime, netavark network, seccomp) — v1.1
- ✓ Persistent Go cache shared across component builds — v1.1
- ✓ Opt-in ccache for C builds — v1.1
- ✓ Opt-in mold linker for Rust builds — v1.1
- ✓ Symmetric uninstall (removes everything install adds) — v1.1
- ✓ Build container-libs from source with seccomp.json generation — v1.2
- ✓ Install runtime config files (seccomp, policy, registries, storage) — v1.2
- ✓ Man pages for container config files — v1.2
- ✓ Symmetric uninstall of all container-libs artifacts — v1.2

### Active

(No active requirements — start next milestone to define)

### Out of Scope

- CI/CD pipeline integration — personal use only
- Podman version pinning — always latest stable
- GUI installation wizard — CLI only
- Non-Debian/Ubuntu distributions — focus on Debian/Ubuntu
- ARM 32-bit support (armv7l) — focusing on 64-bit ARM only
- Resumable builds — complexity not needed for personal use
- Component selection — full installation is the goal
- Parallel build orchestration — complexity disproportionate to gain
- CNI networking — removed in Podman 5.0
- Building container-libs Go libraries as importable packages — only config files and generated artifacts needed
- Custom seccomp profile modifications — default upstream profile is sufficient

## Context

Shipped v1.2 with 2,404 LOC shell code across 22 scripts.
Tech stack: Bash, Git, Go, Rust, Make, Cargo, Meson, sccache, ccache, mold, go-md2man.
v1.0 shipped 2026-03-03, v1.1 shipped 2026-03-04, v1.2 shipped 2026-03-04.

Build caching layers: sccache (Rust), ccache (C), Go cache (Go), mold linker (Rust linking). Fresh build ~15-20 min, cached rebuild dramatically faster.

container-libs (https://github.com/containers/container-libs) is the monorepo for containers-common: provides seccomp.json, policy.json, default.yaml, storage.conf, and man pages needed by Podman at runtime. Build requires Go and go-md2man (both already in our toolchain).

All v1.1 tech debt resolved: seccomp.json now properly built and installed.

## Constraints

- **Platform:** Debian/Ubuntu only (amd64 and ARM64)
- **Interaction:** Zero interactive prompts (DEBIAN_FRONTEND=noninteractive, apt -y flags, etc.)
- **Architecture:** Must auto-detect and work on both amd64 and ARM64

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Auto-detect architecture | One script works everywhere, no branching needed | ✓ Good - Centralized detect_architecture() |
| Latest stable version only | Simplicity over flexibility for personal use | ✓ Good - No version pinning complexity |
| Non-interactive mode | Set-and-forget installation experience | ✓ Good - DEBIAN_FRONTEND=noninteractive throughout |
| Use uname -m for arch detection | More portable than dpkg-based methods | ✓ Good - Works on all systems |
| Circular sourcing config.sh <-> functions.sh | Enables shared utilities and config | ⚠️ Revisit - Guarded but fragile pattern |
| set -euo pipefail everywhere | Catch all errors immediately | ✓ Good - Consistent strict mode |
| Parallel make with NPROC | 2-4x build speedup on multi-core | ✓ Good - Auto-detects CPU count |
| Shallow git clones (--depth 1) | ~95% network transfer reduction | ✓ Good - User can override |
| Go compiler optimizations (GOGC=off) | ~30% faster Go compilation | ✓ Good - Uses more RAM but worth it |
| Environment variable overrides | User control over optimizations | ✓ Good - All settings configurable |
| Remove runc/slirp4netns | crun 50% faster, 8x less memory; pasta is documented successor | ✓ Good - Cleaner codebase, better defaults |
| Pre-flight validation | Fail early with clear messages vs cryptic build failures | ✓ Good - 5 checks in <5 seconds |
| sccache via pre-built binary | No compilation needed, musl binary works everywhere | ✓ Good - Clean install/uninstall |
| Opt-in build caching (default off) | Zero behavior change for existing users | ✓ Good - Progressive enhancement |
| Local disk caching for sccache | Simpler than S3/WebDAV, no external deps | ✓ Good - Matches personal use case |
| mold via .cargo/config.toml | Avoids RUSTFLAGS conflicts with sccache RUSTC_WRAPPER | ✓ Good - Clean integration |
| ccache with COMPILERCHECK=content | Correct cache invalidation on GCC upgrades | ✓ Good - Avoids stale cache hits |
| Centralized Go cache in config.sh | Single source of truth, no per-script overrides | ✓ Good - DRY principle |
| Target only make seccomp.json | Only seccomp profile needed, not full container-libs build | ✓ Good - Minimal build, fast execution |
| install -m 0644 for config files | Matches upstream Makefile conventions | ✓ Good - Consistent permissions |
| go-md2man for man pages | Already in toolchain from other builds | ✓ Good - No new dependencies |

---
*Last updated: 2026-03-04 after v1.2 milestone*
