# Security policy

This project builds and publishes a signed APT repository of the Podman container stack. There are two kinds of security issue:

1. Issues in this project: the build scripts, the packaging, CI, or the signing and publishing of the repository.
2. Issues in the upstream components (podman, crun, conmon, buildah, skopeo, netavark, aardvark-dns, fuse-overlayfs, catatonit, pasta, toolbox, container-libs). Report those to the upstream project. The packages here are rebuilt from upstream source and pick up their fixes.

## Reporting a vulnerability

Do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting (Security, then Report a vulnerability) at <https://github.com/slazarov/podman-debian/security/advisories/new>.

If that is not available, email stanislav@lazarov.group with:

- the affected script or package, and the version or suite (for example `stable-trixie`);
- a description and, if you can, steps to reproduce;
- the impact you saw.

You should get an acknowledgement within a few days. Fixes are prioritized by severity. Coordinated disclosure is appreciated.

## Package integrity

- Every suite is GPG-signed. The public key is published as `podman-debian.gpg` and installed by users in `/etc/apt/keyrings/`.
- Indexes are published with `Acquire-By-Hash` to avoid mismatches while GitHub Pages updates.
- Before each deploy, CI checks that every suite's signed index matches its `Release` file and the `.deb` files in the pool.

Report any concern about signatures, the key or index integrity through the private channel above.

## Signing key rotation

The private signing key exists only as the `GPG_PRIVATE_KEY` GitHub Actions secret. Its public half is `packaging/repo/pubkey.gpg` in this repository and is published as `podman-debian.gpg`.

apt rejects a suite signed by a key it does not already trust, so rotate with a transition period:

1. Generate the new key pair. Add its public key to `packaging/repo/pubkey.gpg` next to the current one, so the published `podman-debian.gpg` contains both.
2. Publish once with the combined key file. Users' next `apt update` picks up the new public key while the old signature is still trusted.
3. After the transition period (announce it in the README and the changelog), replace the `GPG_PRIVATE_KEY` secret with the new private key.
4. Remove the old public key from `pubkey.gpg` in a later release.

If the private key may be compromised, rotate at once without a transition period and disclose through the channel above. Never commit a private key.

## Supported versions

Only the latest published build of each track (stable, v5, nightly) for each supported Debian release (12 and 13) gets fixes. Older builds are not maintained.
