# Testing

The tests are plain Bash scripts in `tests/`. There is no test framework and no runner. Each script defines its own assertion helpers, prints a `PASS` or `FAIL` line per check, ends with a `Results: N passed, M failed` line, and exits non-zero if any check failed.

## Running the tests

Run one test:

```bash
bash tests/test_suite_routing.sh
```

Run all of them:

```bash
for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done
```

Most tests need only Bash, `git`, `sed`, `awk` and coreutils, and run on any host. Some checks need Debian tools and skip themselves when the tools are missing:

- `dpkg` and `dpkg-query`, `ldd`, `objdump`, `gcc`: the version-sort checks and the real-binary checks in `test_detect_distro_depends.sh`.
- `reprepro`, `gpg`, `dpkg-deb`, `python3`, `curl`: the repository assembly tests (`test_repo_assemble_byhash.sh`, `test_ci_publish_multipass.sh`, `test_ci_publish_shared_pool.sh`).

To run every check, use a Debian container:

```bash
podman run --rm -it -v "$PWD:/src:ro" docker.io/library/debian:trixie bash -c '
  apt-get update -qq &&
  apt-get install -y -qq reprepro gnupg dpkg-dev python3 python3-yaml curl git gcc libc6-dev libsystemd-dev binutils gettext-base &&
  cp -a /src /work && cd /work &&
  for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done'
```

The tests never touch the live repository. The assembly tests generate a throwaway GPG key in a temporary `GNUPGHOME`, build fixture `.deb` files, and serve a mock "live" repository from a local `python3 -m http.server`.

Scripts that source `config.sh` detect the distro from `/etc/os-release` and fail on anything that is not Debian 12 or 13. The tests that run them export `DISTRO=bookworm` first, so they also run on other hosts. Tests that need only the distro table read it with:

```bash
eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' config.sh)"
```

## What each test covers

| Test | Covers |
|------|--------|
| `test_detect_distro_depends.sh` | Distro detection from `/etc/os-release` (via `OS_RELEASE_FILE`) and from `DISTRO` given as codename or VERSION_ID; rejection of other distributions, Debian testing/unstable (no VERSION_ID), unsupported releases and malformed values; amd64-only architecture detection; `detect_runtime_depends` (direct `DT_NEEDED` only, static binaries, base packages excluded) |
| `test_suite_routing.sh` | The distro table, the derived `ALL_SUITES`, `resolve_publish_targets` (one `<track>-<distro>` suite, no aliases) and `is_valid_suite` |
| `test_distributions_suites.sh` | `packaging/repo/conf/distributions` has exactly one signed stanza per suite in `ALL_SUITES`, amd64 only, Origin `podman-debian` |
| `test_version_ordering.sh` | Runs `scripts/verify_versions.sh` and checks that `config.sh` and `package_all.sh` still build versions in the form it tests |
| `test_extract_version_nightly.sh` | Nightly version extraction per component (`{base}~~git{date}.{sha}`, pasta `{date}~~git{sha}`) and that nightly sorts below the tagged release |
| `test_resolve_versions.sh` | The stable/v5 resolver, offline: `*_SERIES` caps, the soak window, deriving buildah from podman's `go.mod`, and holding on uncertainty |
| `test_check_republish.sh` | Helpers of the republish guard and its use of the distro table |
| `test_ci_matrix.sh` | `scripts/ci_matrix.sh` output and the workflow structure: matrix from `config.sh`, Debian containers, per-distro cache keys and artifacts, per-distro publish and smoke, the refusal to deploy when nothing was published, amd64 only |
| `test_index_html_distro.sh` | Runs `generate_index_html` on a fixture repository: distro toggle, one DEB822 snippet per suite, keyring path, per-distro package tables, HTML escaping |
| `test_docs_suites.sh` | `docs/apt-repository.md` names every suite, uses the documented keyring and sources paths, has no bare aliases and no `trusted=yes` |
| `test_mirror_verbatim.sh` | `mirror_suite_verbatim` against a path-segmented `file://` URL, by-hash reconstruction, and the cases where a suite must not be served verbatim |
| `test_byhash_parse.sh` | The `Release` section parser used by `scripts/repo_byhash.sh` |
| `test_verify_repo_integrity.sh` | `scripts/verify_repo_integrity.sh` passes a consistent repository and fails on index/pool and Release/index mismatches |
| `test_verify_shipped_binaries.sh` | The set-difference helper of `scripts/verify_shipped_binaries.sh` |
| `test_repo_assemble_byhash.sh` | Real reprepro assembly: `Acquire-By-Hash`, by-hash copies, signatures after re-signing, no clobbering between suites, an empty signed suite, and that a trixie publish leaves the bookworm suite untouched |
| `test_ci_publish_multipass.sh` | Two `ci_publish.sh` passes (bookworm, then trixie) into one output directory: the second pass must not revert the first pass's fresh suite |
| `test_ci_publish_shared_pool.sh` | The shared pool: a rebuild of an already-published version adopts the published bytes, and a corrupted live repository is healed without dropping a suite |

## Writing a test

- Put it in `tests/` as `test_<subject>.sh` and start it with `set -euo pipefail`.
- Find the project root relative to the script, so it runs from any directory:

  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
  ```

- Copy the `assert_*` helpers and `PASS_COUNT`/`FAIL_COUNT` counters from an existing test. Use `PASS_COUNT=$((PASS_COUNT + 1))`, not `((PASS_COUNT++))`, which returns non-zero under `set -e` when the counter is 0.
- Most scripts do work when sourced. Extract just the function under test:

  ```bash
  eval "$(sed -n '/^extract_version_nightly()/,/^}/p' "${PROJECT_ROOT}/scripts/package_all.sh")"
  ```

- Create fixtures under `mktemp -d` and remove them in an `EXIT` trap.
- Guard checks that need Debian tools with `command -v`, and print `SKIP` with the reason.
- Exit non-zero when any check failed.

## CI

`.github/workflows/lint.yml` runs on every push to `main` and every pull request:

- ShellCheck at `severity=error`, blocking.
- An shfmt diff (`shfmt -i 4 -ci -sr`), informational.
- Every `tests/test_*.sh`, blocking.
- A gitleaks scan of the full history, informational.

`.github/workflows/build-packages.yml` runs `scripts/verify_versions.sh` in every build cell before the build starts. Its publish job runs `test_docs_suites.sh`, `test_index_html_distro.sh` and the repository assembly tests before assembling the repository, then `scripts/verify_repo_integrity.sh` on the result.

The last check before deploying is `scripts/smoke_repo_install.sh`, run once per distro that has a suite for the track in the assembled repository. Each scenario runs in a fresh privileged Debian container of that release:

- fresh: install `podman-suite`, run `podman info` as root, then, as a rootless user with their own `~/.config/containers/containers.conf`, run a container on a bridge network and resolve its name through aardvark-dns.
- migrate: install Debian's own `podman`, then `podman-suite` over it. `dpkg --audit` must be clean.
- upgrade: install from the live repository, then `apt-get full-upgrade` to the new build. Skipped when the suite is not published yet.

Any failure stops the job before the Pages deploy. To run it against a locally assembled repository:

```bash
TRACK=stable LIVE_REPO_URL=https://slazarov.github.io/podman-debian \
  ./scripts/smoke_repo_install.sh trixie repo-output
```

`scripts/smoke_install.sh <distro>` is a smaller check you can run after `package_all.sh`: it installs the locally built `podman-skopeo` and `podman-container-configs` `.deb` files into a clean container of that release, which proves their system-library dependencies resolve from the Debian archive.
