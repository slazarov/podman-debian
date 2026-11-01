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
- `reprepro`, `gpg`, `gpgv`, `dpkg-deb`, `python3`, `curl`: the repository assembly tests (`test_repo_assemble_byhash.sh`, `test_ci_publish_multipass.sh`, `test_ci_publish_shared_pool.sh`).
- `gpg` and `gpgv`: the signature checks in `test_verify_repo_integrity.sh`.
- `python3`, `curl`, `git`: `test_ci_helpers.sh` and the server-error checks in `test_mirror_verbatim.sh`.

A skipped check passes, which is convenient on a laptop and dangerous in CI. Set `REQUIRE_INTEGRATION_DEPS=1` and every skip caused by a missing tool becomes a failure. Both CI workflows set it.

To run every check, use a Debian container:

```bash
podman run --rm -it -v "$PWD:/src:ro" docker.io/library/debian:trixie bash -c '
  apt-get update -qq &&
  apt-get install -y -qq reprepro gnupg gpgv dpkg-dev python3 python3-yaml curl git gcc libc6-dev libsystemd-dev binutils gettext-base &&
  cp -a /src /work && cd /work &&
  export REQUIRE_INTEGRATION_DEPS=1 &&
  for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done'
```

The tests never touch the live repository. The assembly tests generate a throwaway GPG key in a temporary `GNUPGHOME`, build fixture `.deb` files, and serve a mock "live" repository from a local `python3 -m http.server`. Tests that need a misbehaving server use `tests/lib/mock_http_server.py`, which serves a directory and answers chosen paths with an HTTP error or a cut-off body, for every request or only the first few. `tests/lib/mock_http.sh` starts and stops it and holds `require_integration_deps`.

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
| `test_check_republish.sh` | Helpers of the republish guard, its use of the distro table, and its decision with a resolved-env file against a `file://` repository: all current skips; a stale distro, a differing `podman-suite` or an unpublished suite builds; an invalid file fails |
| `test_ci_helpers.sh` | `scripts/ci_helpers.sh`: `fetch_url` against injected 404, 410, 429, 503, 403 and cut-off bodies (absent versus error, retry counts, no partial files); `validate_resolved_env` (and that its names match the resolver); recording, detecting and merging nightly revisions, including a failed distro keeping its old entries; `published_distros`; `wait_for_propagation`; the cache statistics parsers |
| `test_ci_matrix.sh` | `scripts/ci_matrix.sh` output and the workflow structure: matrix from `config.sh`, Debian containers, per-distro cache keys and artifacts, queued concurrency, least-privilege permissions, no persisted checkout credentials, a single resolver run whose hold stops the build even with `force_rebuild`, the nightly checkpoint saved only after deploy and propagation, publish and smoke for the distros whose cell succeeded, the refusal to deploy when nothing was published, compiler caches, amd64 only |
| `test_index_html_distro.sh` | Runs `generate_index_html` on a fixture repository: distro toggle, one DEB822 snippet per suite, keyring path, per-distro package tables, HTML escaping |
| `test_docs_suites.sh` | `docs/apt-repository.md` names every suite, uses the documented keyring and sources paths, has no bare aliases and no `trusted=yes` |
| `test_mirror_verbatim.sh` | `mirror_suite_verbatim` against a path-segmented `file://` URL, by-hash reconstruction, the cases where a suite must not be served verbatim, and that a server error is reported as an error, never as an unpublished suite |
| `test_byhash_parse.sh` | The `Release` section parser used by `scripts/repo_byhash.sh` |
| `test_verify_repo_integrity.sh` | `scripts/verify_repo_integrity.sh` passes a consistent repository and an empty signed suite, and fails on index/pool and Release/index mismatches, a missing `Codename` or `SHA256` section, an unlisted architecture, a stanza without `Size`/`SHA256`, an `InRelease` that signs different text, a foreign signature and a missing `Release.gpg` |
| `test_verify_shipped_binaries.sh` | The set-difference helper of `scripts/verify_shipped_binaries.sh` |
| `test_repo_assemble_byhash.sh` | Real reprepro assembly: `Acquire-By-Hash`, by-hash copies, signatures after re-signing, no clobbering between suites, an empty signed suite, that a trixie publish leaves the bookworm suite untouched, and that a failing clearsign or detached sign is reported |
| `test_ci_publish_multipass.sh` | Two `ci_publish.sh` passes (bookworm, then trixie) into one output directory: the second pass must not revert the first pass's fresh suite, both keep the previous by-hash generation, and the result verifies against the signing key. Then: a pool file answering 503 or cut off every time, or a `Release` answering 503, stops the publish; one 503 is retried; a failing signature step stops the publish |
| `test_ci_publish_shared_pool.sh` | The shared pool: a rebuild of an already-published version adopts the published bytes (from another suite, or from the live target index itself), and a corrupted live repository is healed without dropping a suite and with its previous by-hash generation kept |

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
- Guard checks that need Debian tools with `command -v`, and print `SKIP` with the reason. Call `require_integration_deps` from `tests/lib/mock_http.sh` there, so the skip fails under `REQUIRE_INTEGRATION_DEPS=1`.
- Exit non-zero when any check failed.

## CI

`.github/workflows/lint.yml` runs on every push to `main` and every pull request:

- ShellCheck at `severity=error`, blocking.
- An shfmt diff (`shfmt -i 4 -ci -sr`), informational.
- Every `tests/test_*.sh`, blocking. The job installs `reprepro`, `gnupg`, `gpgv` and `dpkg-dev` and sets `REQUIRE_INTEGRATION_DEPS=1`, so the integration tests run rather than skip.
- A gitleaks scan of the full history, informational.

`.github/workflows/build-packages.yml` runs `scripts/verify_versions.sh` in every build cell before the build starts. Its publish job runs `test_docs_suites.sh`, `test_index_html_distro.sh` and the repository assembly tests before assembling the repository, then `scripts/verify_repo_integrity.sh` on the result.

The last check before deploying is `scripts/smoke_repo_install.sh`, run once per distro this run built and published (suites carried over from the live repository were tested when they were published). apt reads the assembled repository with `Signed-By` set to its `podman-debian.gpg`, so the signatures are checked as on a user's machine. Each scenario runs in a fresh privileged Debian container of that release:

- fresh: install `podman-suite`, run `podman info` as root, then, as a rootless user with their own `~/.config/containers/containers.conf`, run a container on a bridge network and resolve its name through aardvark-dns.
- migrate: install Debian's own `podman`, then `podman-suite` over it. `dpkg --audit` must be clean.
- upgrade: install from the live repository, then `apt-get full-upgrade` to the new build, and check that every installed package of the suite (and `podman-suite`) is `install ok installed` at the assembled version. Skipped when the live `InRelease` returns 404 (the suite is not published yet); a network or server error fails instead.

Any failure stops the job before the Pages deploy. To run it against a locally assembled repository:

```bash
TRACK=stable LIVE_REPO_URL=https://slazarov.github.io/podman-debian \
  ./scripts/smoke_repo_install.sh trixie repo-output
```

`scripts/smoke_install.sh <distro>` is a smaller check you can run after `package_all.sh`: it installs the locally built `podman-skopeo` and `podman-container-configs` `.deb` files into a clean container of that release, which proves their system-library dependencies resolve from the Debian archive.
