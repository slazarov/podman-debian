# Requirements: Podman Debian Compiler

**Defined:** 2025-02-28
**Core Value:** Compile and install Podman on any Debian/Ubuntu system without user interaction.

---

## v1 Requirements (COMPLETE)

Requirements for ARM support and non-interactive installation.

### Architecture Support

- [x] **ARCH-01**: Script detects system architecture (amd64 vs arm64)
- [x] **ARCH-02**: Go installer uses correct architecture URL (linux-arm64 vs linux-amd64)
- [x] **ARCH-03**: Protoc installer uses correct architecture URL (aarch_64 vs x86_64)
- [x] **ARCH-04**: Rust installer uses correct architecture target (aarch64-unknown-linux-gnu)
- [x] **ARCH-05**: Centralized architecture variable in config.sh

### Non-Interactive Mode

- [x] **NINT-01**: All apt commands use DEBIAN_FRONTEND=noninteractive
- [x] **NINT-02**: All apt commands use -y flag (no confirmation prompts)
- [x] **NINT-03**: No script uses `read` or other blocking input
- [x] **NINT-04**: Package configuration prompts pre-answered (debconf-set-selections where needed)

### Error Handling

- [x] **ERRO-01**: set -e enabled consistently across all scripts
- [x] **ERRO-02**: Scripts fail immediately on any error
- [x] **ERRO-03**: Error messages identify which script and line failed
- [x] **ERRO-04**: install.sh propagates errors from sub-scripts

### User Experience

- [x] **UX-01**: Progress messages show current operation
- [x] **UX-02**: Build output logged to files
- [x] **UX-03**: Uninstall script exists and works

### Build Time Optimization

- [x] **PERF-01**: All Make-based builds use parallel compilation with make -j$(nproc)
- [x] **PERF-02**: Git clones use shallow clone (--depth 1) to reduce network transfer
- [x] **PERF-03**: Go builds use optimization flags (gcflags, ldflags, GOGC=off)
- [x] **PERF-04**: Cargo builds use CARGO_BUILD_JOBS for parallel compilation

---

## v1.1 Requirements (Ecosystem Audit)

**Goal:** Research and optimize the Podman build ecosystem — audit dependencies, evaluate version pinning, compare runtimes, and identify optimization opportunities.

### Cleanup (CLNP)

- [x] **CLNP-01**: Remove build_runc.sh — crun is 50% faster, 8x less memory, Podman's default since 2021
- [x] **CLNP-02**: Remove build_slirp4netns.sh — pasta is the documented replacement with better performance
- [x] **CLNP-03**: Remove runc and slirp4netns references from install.sh and config.sh
- [x] **CLNP-04**: Clean up unused SCCACHE_ENABLED dead code (now implemented, see BLD)

### Configuration (CONF)

- [x] **CONF-01**: Enhance config/containers.conf with runtime default (crun)
- [x] **CONF-02**: Add network backend configuration (netavark) to containers.conf
- [x] **CONF-03**: Install containers.conf to /etc/containers/containers.conf during setup
- [x] **CONF-04**: Add seccomp_profile default configuration

### Validation (VAL)

- [x] **VAL-01**: Add pre-flight check for cgroups v2 availability (required for rootless)
- [x] **VAL-02**: Add pre-flight check for subuid/subgid configuration (rootless requirement)
- [x] **VAL-03**: Add pre-flight check for kernel FUSE support (fuse-overlayfs requirement)
- [x] **VAL-04**: Add pre-flight check for minimum kernel version (5.11+ recommended)
- [x] **VAL-05**: Add pre-flight check for noexec mount on /tmp and /home (builds fail)

### Build Optimization (BLD)

- [x] **BLD-01**: Implement sccache for Rust builds (50-90% rebuild speedup)
- [x] **BLD-02**: Add sccache installation to install_rust.sh (via cargo install sccache)
- [x] **BLD-03**: Configure RUSTC_WRAPPER=sccache when SCCACHE_ENABLED=true
- [x] **BLD-04**: Add sccache directory setup and environment configuration

---

## v2 Requirements

Deferred to future release.

### Advanced Optimization

- **PERF-05**: Profile-guided optimization (PGO) for crun/podman binaries
- **PERF-06**: mold linker integration (5x faster than ld)

### Documentation

- **DOC-01**: Generate man pages during build (go-md2man integration)
- **DOC-02**: Add --help documentation to all scripts

### Advanced Features

- **ADVN-01**: Resumable builds (continue from failed step)
- **ADVN-02**: Component selection (choose what to build)
- **ADVN-03**: Checksum verification for downloaded tarballs

---

## Out of Scope

| Feature | Reason |
|---------|--------|
| ARM 32-bit support (armv7l) | Focusing on 64-bit ARM only per PROJECT.md |
| Version pinning | Always latest stable per PROJECT.md |
| CI/CD integration | Personal use only per PROJECT.md |
| Non-Debian/Ubuntu distros | Focus on Debian/Ubuntu per PROJECT.md |
| GUI wizard | CLI only per PROJECT.md |
| runc restoration | crun is superior in all metrics; fallback not needed |
| slirp4netns restoration | pasta is the documented successor |
| CNI networking | Removed in Podman 5.0 |

---

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| ARCH-01 | Phase 1 | Complete |
| ARCH-02 | Phase 1 | Complete |
| ARCH-03 | Phase 1 | Complete |
| ARCH-04 | Phase 1 | Complete |
| ARCH-05 | Phase 1 | Complete |
| NINT-01 | Phase 2 | Complete |
| NINT-02 | Phase 2 | Complete |
| NINT-03 | Phase 2 | Complete |
| NINT-04 | Phase 2 | Complete |
| ERRO-01 | Phase 3 | Complete |
| ERRO-02 | Phase 3 | Complete |
| ERRO-03 | Phase 3 | Complete |
| ERRO-04 | Phase 3 | Complete |
| UX-01 | Phase 4 | Complete |
| UX-02 | Phase 4 | Complete |
| UX-03 | Phase 4 | Complete |
| PERF-01 | Phase 5 | Complete |
| PERF-02 | Phase 5 | Complete |
| PERF-03 | Phase 5 | Complete |
| PERF-04 | Phase 5 | Complete |
| CLNP-01 | Phase 6 | Complete |
| CLNP-02 | Phase 6 | Complete |
| CLNP-03 | Phase 6 | Complete |
| CLNP-04 | Phase 8 | Complete |
| CONF-01 | Phase 8 | Complete |
| CONF-02 | Phase 8 | Complete |
| CONF-03 | Phase 8 | Complete |
| CONF-04 | Phase 8 | Complete |
| VAL-01 | Phase 7 | Complete |
| VAL-02 | Phase 7 | Complete |
| VAL-03 | Phase 7 | Complete |
| VAL-04 | Phase 7 | Complete |
| VAL-05 | Phase 7 | Complete |
| BLD-01 | Phase 8 | Complete |
| BLD-02 | Phase 8 | Complete |
| BLD-03 | Phase 8 | Complete |
| BLD-04 | Phase 8 | Complete |

**Coverage:**
- v1 requirements: 20 total (Complete)
- v1.1 requirements: 17 total
- Mapped to phases: 37
- Unmapped: 0

---
*Requirements defined: 2025-02-28*
*Last updated: 2026-03-04 - BLD-01 through BLD-04, CLNP-04 completed (Phase 8 Plan 1)*
