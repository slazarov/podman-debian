# Podman Debian Compiler

## What This Is

A shell script that compiles and installs the latest stable Podman from source on Debian/Ubuntu systems. Works on both amd64 and ARM architectures with automatic detection. Designed for fully unattended, non-interactive installation.

## Core Value

Compile and install Podman on any Debian/Ubuntu system without user interaction.

## Requirements

### Validated

- ✓ Compile Podman from source on amd64 — existing
- ✓ Install compiled Podman to system — existing

### Active

- [ ] Auto-detect system architecture (amd64 vs ARM)
- [ ] Compile Podman on ARM Ubuntu/Debian VMs
- [ ] Run fully unattended/non-interactive (no apt prompts, no config choices, accept all defaults)
- [ ] No blocking prompts during installation

### Out of Scope

- CI/CD pipeline integration — personal use only
- Podman version pinning — always latest stable
- GUI installation wizard — CLI only
- Non-Debian/Ubuntu distributions — focus on Debian/Ubuntu

## Context

Existing script compiles Podman on amd64. User needs ARM support for personal ARM VMs running Ubuntu/Debian. The script should work without any user interaction - suitable for running and walking away.

ARM compilation may require different dependencies or build flags compared to amd64.

## Constraints

- **Platform:** Debian/Ubuntu only (amd64 and ARM)
- **Interaction:** Zero interactive prompts (DEBIAN_FRONTEND=noninteractive, apt -y flags, etc.)
- **Architecture:** Must auto-detect and work on both amd64 and ARM

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Auto-detect architecture | One script works everywhere, no branching needed | — Pending |
| Latest stable version only | Simplicity over flexibility for personal use | — Pending |
| Non-interactive mode | Set-and-forget installation experience | — Pending |

---
*Last updated: 2025-02-28 after initialization*
