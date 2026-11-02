# Contributing to podman-debian

This project builds the Podman container stack from upstream source, packages it as `.deb` files and publishes them in an APT repository for Debian 12 (bookworm) and Debian 13 (trixie) on amd64. Changes to the build scripts, packaging, CI and documentation are welcome.

## Development setup

The project is a set of Bash scripts. There is nothing to compile for the project itself.

You can edit and test the scripts on any machine with Bash. A real build needs a Debian 12 or 13 host or container, run as root:

```bash
git clone https://github.com/slazarov/podman-debian.git
cd podman-debian
eval "$(./scripts/resolve_versions.sh versions-stable.env)"
sudo -E ./setup.sh
```

The build installs toolchains and system packages, so use a disposable VM or container. A quick way to get one:

```bash
podman run --rm -it -v "$PWD:/src" -w /src docker.io/library/debian:trixie bash
```

Cloned sources go to `build/` and logs to `log/`. Both are ignored by git. When a component fails, read its log in `log/`. `sudo ./uninstall.sh` removes what the build installed.

The pipeline stages are described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Every build variable is listed in [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

### Build tracks

The same scripts build all three tracks. Only the environment differs:

| Track | Command | What it builds |
|-------|---------|----------------|
| stable | `eval "$(./scripts/resolve_versions.sh versions-stable.env)" && sudo -E ./setup.sh` | Podman 6.x, tags chosen by the resolver from the `versions-stable.env` policy |
| v5 | `eval "$(./scripts/resolve_versions.sh versions-v5.env)" && sudo -E ./setup.sh` | Podman 5.x, from the `versions-v5.env` policy |
| nightly | `sudo NIGHTLY_BUILD=true SHALLOW_CLONE=false ./setup.sh` | Upstream HEAD with full clones |

To build for a release other than the host's, set `DISTRO` (`bookworm`, `trixie`, `12` or `13`). The version suffix follows it.

## Coding standards

All build logic is Bash. `.shellcheckrc`, `.editorconfig` and `.pre-commit-config.yaml` (ShellCheck, shfmt, gitleaks) define the rules, and `.github/workflows/lint.yml` runs ShellCheck and the test suite on every pull request. Follow the patterns in `scripts/`:

- Start scripts with `#!/bin/bash` and `set -euo pipefail`.
- Bootstrap the tool path, source `config.sh` and `functions.sh`, then install the error trap, so a script works on its own and when called from `setup.sh`:

  ```bash
  relativepath="../"
  if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi
  source "${toolpath}/config.sh"
  source "${toolpath}/functions.sh"
  trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR
  ```

- Use the helpers in `functions.sh` (`git_clone_update`, `git_checkout`, `run_logged`, `step_start`, `step_done`, `detect_architecture`) instead of repeating their logic.
- Keep versions, distro values and cache switches in `config.sh` or `versions-*.env`, using the `${VAR:-default}` pattern. Do not hard-code them in build scripts.
- Quote expansions (`"${VAR}"`) and indent function bodies by 4 spaces.
- To run the checks before you push: `pipx install pre-commit && pre-commit install`.

## Where to add code

| Change | Where |
|--------|-------|
| New component | `scripts/build_<name>.sh` (copy an existing header), `packaging/nfpm/<name>.yaml`, a tag in both `versions-*.env`, and a `run_script` line in `setup.sh` after its dependencies |
| New toolchain installer | `scripts/install_<tool>.sh`, called from `setup.sh` before anything that needs it |
| New configuration variable | `config.sh` (`${VAR:-default}` and `export`), documented in [docs/CONFIGURATION.md](docs/CONFIGURATION.md) |
| Packaging | `packaging/nfpm/<name>.yaml` for one package, `scripts/package_all.sh` for all of them |
| New Debian release or track | The distro table in `config.sh` (`VALID_TRACKS`, `VALID_DISTROS`, `DISTRO_VERSION_IDS`, `DISTRO_IMAGES`), plus a stanza per new suite in `packaging/repo/conf/distributions`, a baseline in `scripts/verify_depends.sh`, and any release-specific build dependency in `scripts/install_dependencies.sh`. CI, the smoke tests and the repository page read the table. |

## Pull requests

`.github/workflows/lint.yml` runs on every pull request: ShellCheck at `severity=error`, an informational shfmt diff, the `tests/` suite and a gitleaks scan. Package builds run in `.github/workflows/build-packages.yml` on a schedule or by manual dispatch. The pull request template contains the checklist.

- Branch from `main` with a short descriptive name, such as `fix/crun-json-c-dependency`.
- Use Conventional Commits (`feat:`, `fix(ci):`, `chore:`, `docs:`).
- Keep each pull request to one change: one component, one packaging fix, or one CI adjustment.
- Build the component you changed, and run the tests.
- Update `README.md` and `docs/` when behavior, supported releases or commands change.
- In the description, say what changed, how you checked it, and which tracks and Debian releases you built.

### Running tests

Tests are standalone Bash scripts in `tests/`:

```bash
for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done
```

Some tests need `dpkg`, `reprepro` and `gpg` and skip themselves when those are missing. To run all of them, use a Debian container with `reprepro gnupg dpkg-dev python3 curl` installed. [docs/TESTING.md](docs/TESTING.md) lists what each test covers.

### Running a CI build

Maintainers can start **Build and Publish Packages** from the Actions tab and choose the `stable`, `v5` or `nightly` track. The workflow also runs daily, once per track: nightly at 04:37, stable at 05:37 and v5 at 06:37 UTC.

## Reporting issues

Use GitHub Issues at <https://github.com/slazarov/podman-debian/issues>. The templates are in `.github/ISSUE_TEMPLATE/`. For a build or packaging problem, include:

- the track (`stable`, `v5` or `nightly`) and the component;
- your Debian release (12 or 13);
- whether you installed from the APT repository or built with `setup.sh`;
- the command you ran and the end of the failing component's log from `log/`;
- what you expected and what happened.

For a feature request, describe the use case and which components or tracks it affects.
