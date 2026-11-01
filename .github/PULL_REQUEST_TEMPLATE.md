<!-- Keep pull requests to one change. See CONTRIBUTING.md. -->

## What and why

<!-- What does this change, and why? Link a related issue: Closes #NN -->

## Type of change

- [ ] `fix`: bug fix
- [ ] `feat`: new capability
- [ ] `ci`: CI or workflow change
- [ ] `chore` / `docs` / `test` / `refactor`

## Checklist

- [ ] Commits follow Conventional Commits (`feat:`, `fix(ci):`, ...)
- [ ] `shellcheck` is clean on touched scripts, or new findings are explained
- [ ] `bash -n` passes on touched scripts
- [ ] Relevant `tests/*.sh` pass; a test was added or updated if logic changed
- [ ] No hard-coded version or distro; values go through `config.sh` (`${VAR:-default}`)
- [ ] Packaging changed? `package_all.sh` was run and the `.deb` output checked (CI or a Debian VM)
- [ ] Docs updated if behavior, configuration or repository layout changed
- [ ] No secrets, credentials or machine-local paths committed

## Testing

<!-- How did you check this? Unit tests, a build in a Debian 12/13 container
     or VM, a CI run. Builds only run on Debian; see CONTRIBUTING.md. -->
