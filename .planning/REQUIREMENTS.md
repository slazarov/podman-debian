# Requirements: Podman Debian Compiler

**Defined:** 2025-02-28
**Core Value:** Compile and install Podman on any Debian/Ubuntu system without user interaction.

## v1 Requirements

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

- [ ] **PERF-01**: All Make-based builds use parallel compilation with make -j$(nproc)
- [ ] **PERF-02**: Git clones use shallow clone (--depth 1) to reduce network transfer
- [ ] **PERF-03**: Go builds use optimization flags (gcflags, ldflags, GOGC=off)
- [ ] **PERF-04**: Cargo builds use CARGO_BUILD_JOBS for parallel compilation

## v2 Requirements

Deferred to future release.

### Pre-Flight Validation

- **PREF-01**: Check kernel features before build (seccomp, apparmor, etc.)
- **PREF-02**: Verify sufficient disk space for compilation
- **PREF-03**: Validate system meets minimum requirements

### Advanced Features

- **ADVN-01**: Resumable builds (continue from failed step)
- **ADVN-02**: Component selection (choose what to build)
- **ADVN-03**: Checksum verification for downloaded tarballs
- **ADVN-04**: Rootless configuration automation (subuid/subgid)

### Advanced Build Optimization

- **PERF-05**: Optional sccache remote caching support for CI/CD pipelines
- **PERF-06**: Optional mold linker for C/C++ components
- **PERF-07**: RAM disk (tmpfs) build option for systems with 16GB+ RAM

## Out of Scope

| Feature | Reason |
|---------|--------|
| ARM 32-bit support (armv7l) | Focusing on 64-bit ARM only per PROJECT.md |
| Version pinning | Always latest stable per PROJECT.md |
| CI/CD integration | Personal use only per PROJECT.md |
| Non-Debian/Ubuntu distros | Focus on Debian/Ubuntu per PROJECT.md |
| GUI wizard | CLI only per PROJECT.md |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| ARCH-01 | Phase 1: Architecture Support | Complete |
| ARCH-02 | Phase 1: Architecture Support | Complete |
| ARCH-03 | Phase 1: Architecture Support | Complete |
| ARCH-04 | Phase 1: Architecture Support | Complete |
| ARCH-05 | Phase 1: Architecture Support | Complete |
| NINT-01 | Phase 2: Non-Interactive Mode | Complete |
| NINT-02 | Phase 2: Non-Interactive Mode | Complete |
| NINT-03 | Phase 2: Non-Interactive Mode | Complete |
| NINT-04 | Phase 2: Non-Interactive Mode | Complete |
| ERRO-01 | Phase 3: Error Handling | Complete |
| ERRO-02 | Phase 3: Error Handling | Complete |
| ERRO-03 | Phase 3: Error Handling | Complete |
| ERRO-04 | Phase 3: Error Handling | Complete |
| UX-01 | Phase 4: User Experience | Complete |
| UX-02 | Phase 4: User Experience | Complete |
| UX-03 | Phase 4: User Experience | Complete |
| PERF-01 | Phase 5: Build Time Optimization | Planned |
| PERF-02 | Phase 5: Build Time Optimization | Planned |
| PERF-03 | Phase 5: Build Time Optimization | Planned |
| PERF-04 | Phase 5: Build Time Optimization | Planned |

**Coverage:**
- v1 requirements: 16 total
- Mapped to phases: 16
- Unmapped: 0
- Build optimization requirements: 4
- Total requirements: 20

---
*Requirements defined: 2025-02-28*
*Last updated: 2026-03-03 - Added Phase 5 build optimization requirements*
