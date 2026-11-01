# AGENTS.md

Guidance for AI agents working in this repository.

## What this project is

A shell-orchestrated build pipeline, not an application. It compiles the Podman container stack (12 components) from upstream source on Debian 12 (bookworm) and Debian 13 (trixie), amd64 only, packages it into `.deb` files with nFPM, and publishes a reprepro APT repository on GitHub Pages (`https://slazarov.github.io/podman-debian`).

There are three release tracks:

- stable: Podman 6.x, updated within the major by a resolver.
- v5: Podman 5.x, same resolver.
- nightly: upstream HEAD, built daily.

Each track is published once per Debian release, as `{track}-{codename}`: `stable-bookworm`, `v5-trixie`, and so on. There are no bare `stable`/`v5`/`nightly` suites. stable and v5 read a policy file (`versions-{stable,v5}.env`: `*_SERIES` caps plus the `STABLE_SOAK_DAYS` soak window) that `scripts/resolve_versions.sh` turns into concrete `*_TAG` values.

Package versions end in `~deb{VERSION_ID}.podman{N}` (`~deb12.podman1`, `~deb13.podman1`). Nightly versions use `{base}~~git{date}.{sha}`; the double tilde keeps them below the tagged release. `scripts/verify_versions.sh` checks these orderings.

There is no package.json, no compiler, no app server. Everything is Bash.

## Critical constraints

- Builds only run on Debian 12 or 13 (amd64). The dev machine may be something else: you can edit scripts and run the tests there, but do not try to run `setup.sh` or `build_*.sh`. Use `bash -n` for syntax checks and reason through the logic. For real execution, use a disposable Debian VM or container, or CI.
- `config.sh` detects the distro at load time (`DISTRO` override, else `/etc/os-release`) and exits on anything that is not a supported Debian release or on a non-amd64 architecture. Scripts that source it on another host need `DISTRO=bookworm` or `DISTRO=trixie`.
- `setup.sh` writes to system paths and requires root. Full builds belong in a disposable VM, container, or CI.
- The same scripts serve all three tracks, selected entirely by environment variables (`${VAR:-default}` in `config.sh`). Never hard-code a version or distro value into a build script; thread it through `config.sh` with an overridable default.
- The supported releases are listed once, in the distro table in `config.sh` (from `VALID_TRACKS=` to `unset _distro _track`: `VALID_TRACKS`, `VALID_ARCHES`, `VALID_DISTROS`, `DISTRO_VERSION_IDS`, `DISTRO_IMAGES`, derived `ALL_SUITES`). The CI matrix, publish and smoke steps, the republish guard, the repository page and the tests read that block with `sed`, so keep it free of side effects and keep its first and last lines as they are. Adding a release also needs a stanza per suite in `packaging/repo/conf/distributions` and a baseline in `scripts/verify_depends.sh`.

## Repo layout

| Path | Purpose |
|------|---------|
| `setup.sh` | Top-level orchestrator: preflight, toolchain, build all components |
| `uninstall.sh` | Remove everything installed from source |
| `config.sh` | Central config: distro table, distro and arch detection, version suffix, version vars, cache toggles |
| `functions.sh` | Shared helpers: `detect_distro_version_id`, `detect_runtime_depends`, `git_clone_update`, `run_logged`, `error_handler`, `step_start`/`step_done` |
| `scripts/build_<component>.sh` | One script per component; each runs standalone |
| `scripts/install_*.sh` | Toolchain and dependency installers (Go, Rust, protoc, apt build dependencies per release) |
| `scripts/package_all.sh` | DESTDIR staging tree to `.deb` files in `output/` |
| `scripts/repo_manage.sh`, `scripts/ci_publish.sh` | APT repo assembly (reprepro); the distro argument doubles as the `DISTRO` override |
| `scripts/index_html.sh` | Generates the repository landing page from the distro table |
| `scripts/ci_matrix.sh` | Prints the CI build matrix (one cell per distro) from the distro table |
| `scripts/ci_helpers.sh` | Shared CI logic, sourceable without `config.sh`: `fetch_url` (absent versus failed, with retries), resolved-env validation, nightly revision checkpoint, build cell selection, deploy propagation, compiler cache report |
| `scripts/verify_depends.sh`, `scripts/verify_versions.sh` | Post-build dependency baselines per release; version-ordering checks |
| `scripts/smoke_install.sh`, `scripts/smoke_repo_install.sh` | Install proofs in clean Debian containers (local `.deb` files; assembled repo) |
| `packaging/nfpm/*.yaml` | nFPM package definitions (one per component) |
| `packaging/repo/conf/distributions` | reprepro suites, one per entry in `ALL_SUITES` |
| `versions-stable.env` / `versions-v5.env` | Track version policy; resolved by `scripts/resolve_versions.sh` |
| `versions-nightly.env` | Nightly behavior flags (sourced before `setup.sh`) |
| `tests/` | Bash unit tests, run directly: `bash tests/<test>.sh`. `tests/lib/` holds a fault-injecting mock HTTP server and `require_integration_deps` |
| `.github/workflows/build-packages.yml` | CI: per-distro builds in Debian containers (amd64), repo publish |
| `.github/workflows/lint.yml` | CI gate: ShellCheck, shfmt, `tests/`, gitleaks (every PR) |
| `docs/` | Architecture (including CI and publishing), configuration, APT repo, testing |

Component source checkouts (`podman/`, `crun/`, etc.) are cloned into `build/` (`BUILD_ROOT`) at build time and are gitignored. Never commit them. Loading `config.sh` creates an empty `build/` as a side effect.

## Commands

```bash
# Syntax-check a script (works anywhere)
bash -n scripts/build_podman.sh

# Run unit tests (work anywhere with bash; some checks skip without dpkg/reprepro)
for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done
# Same, but a missing integration tool fails instead of skipping (what CI does)
REQUIRE_INTEGRATION_DEPS=1 bash tests/test_ci_publish_multipass.sh

# Full build (Debian 12/13, as root)
eval "$(./scripts/resolve_versions.sh versions-stable.env)" && sudo -E ./setup.sh  # stable (Podman 6.x)
eval "$(./scripts/resolve_versions.sh versions-v5.env)" && sudo -E ./setup.sh      # v5 (Podman 5.x)
sudo NIGHTLY_BUILD=true SHALLOW_CLONE=false ./setup.sh                             # nightly (HEAD)

# Single component (sources config.sh/functions.sh itself)
./scripts/build_conmon.sh

# Package staging tree into .debs (needs DESTDIR set + nfpm)
./scripts/package_all.sh

# Check the built .debs install on their release
./scripts/smoke_install.sh trixie
```

## Code style

- `#!/bin/bash` and `set -euo pipefail` at the top of every script.
- Toolpath bootstrap before any work (copy from an existing script): source `config.sh` then `functions.sh`, then install the error trap `trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR`.
- Use `functions.sh` helpers instead of inlining: `git_clone_update`/`git_checkout` for cloning, `run_logged` for build output, `detect_architecture` for arch, `enable_rust_compiler_cache`/`enable_c_compiler_cache` for sccache and ccache.
- In CI scripts, download from the live repository with `fetch_url` (`scripts/ci_helpers.sh`), never `curl ... || true`. Only its "absent" result (HTTP 404/410) may be read as "not published"; any other failure must stop the publish.
- Variables: `UPPERCASE` for env/config, `lowercase` locals, function-local parameters prefixed `l` (`lcomponent`, `lfolder`). Always quote expansions: `"${VAR}"`. 4-space indent inside functions.
- snake_case function names; guard sourced files with the `_SOURCED` pattern.
- Run ShellCheck over touched scripts before finishing (CI enforces `severity=error` via `.github/workflows/lint.yml`).

## Conventions

- Commits: Conventional Commits (`feat:`, `fix(ci):`, `chore:`, `ci:`).
- Branch off `main` with descriptive names (`fix/...`, `feat/...`).
- Packages are named `podman-*` and declare Conflicts/Replaces/Provides against Debian's own packages (`podman`, `crun`, `conmon`, `golang-github-containers-common`, `podman-toolbox`, and so on). Keep that intact when touching `packaging/nfpm/*.yaml`.
- If you change packaging, versioning, or repo layout, run `scripts/package_all.sh` in CI or a Debian VM and confirm the `.deb` output. Bump `PACKAGE_REVISION` in `scripts/package_revision.sh` when packaging changes without an upstream version change.

## Where things are documented

- `docs/ARCHITECTURE.md`: pipeline stages end to end, including CI and publishing
- `docs/CONFIGURATION.md`: every environment variable and config file
- `docs/apt-repository.md`: end-user APT setup and troubleshooting
- `docs/TESTING.md`: test suite and CI integration
