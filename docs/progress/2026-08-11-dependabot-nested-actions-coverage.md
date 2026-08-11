# Cover nested GitHub Actions with Dependabot

**Status**: complete
**Started**: 2026-08-11
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-fix-governance-guard-test`

## Outcome

Extend the repository Dependabot configuration so the SHA-pinned actions that
live outside the root `.github/workflows` directory are kept up to date. This
makes the "GitHub Actions dependencies are managed centrally" decision recorded
in `docs/progress/2026-08-11-managed-dependabot-actions.md` actually hold.

Dependabot does not recurse for the `github-actions` ecosystem. With
`directory: /` it fetches only root `.github/workflows/*.y{a,}ml` plus a root
`action.yml`/`action.yaml`. For any non-root directory it fetches `*.y{a,}ml`
directly inside that directory and does not descend further. One set of pins
was therefore unmonitored:

| Path | Pinned `uses:` |
| --- | --- |
| `repository-management/repository-sync/actions/avm-repos/action.yml` | 2 |

Globs are supported by `directories` but not by `directory`, so the composite
action entry is written as `actions/*` and picks up any sibling action added
later.

This is a reduced form of PR #56, which was opened before the managed files
tree moved to `Azure/azure-verified-modules-managed-files`. That pull request
also listed
`/repository-management/managed-files/files/*/.github/workflows`, which no
longer exists in this repository. Those 44 pins are now the managed files
repository's responsibility, which carries its own Dependabot configuration.
PR #56 is superseded and closed.

## Checklist

- [x] Confirm Dependabot fetch behaviour against `dependabot-core` and the
      GitHub options reference.
- [x] Enumerate the nested workflow and composite action directories that
      survive the managed files migration.
- [x] Add the composite action directory, and drop the managed files path.
- [x] `./build.ps1 pre-commit` green.
- [x] Close PR #56 as superseded.

## Validation

`./build.ps1 pre-commit` — exit 0.

## Blockers or dependencies

Out of scope here, and now owned by the managed files repository:
`terraform/files/root/.github/workflows/pr-check.yml` calls
`Azure/azure-verified-modules-tools/.github/workflows/terraform-module.yml@main`.
A floating branch ref is not covered by Dependabot and conflicts with the SHA
pinning stance in `docs/avm-implementation-spec.md`.
