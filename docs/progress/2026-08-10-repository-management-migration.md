# Repository management migration

**Status**: complete
**Started**: 2026-08-10
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-migrate-repository-management`

## Outcome

Move the active Terraform repository-management automation from
`Azure/avm-terraform-governance` into isolated folders in this repository
without changing sync behavior. Schedule activation is deferred for cutover.

## Checklist

- [x] Copy managed-file overlays and repository configuration.
- [x] Move repository sync Terraform, scripts, action, and metadata.
- [x] Separate repository creation from repository sync.
- [x] Migrate supporting workflows and Dependabot paths.
- [x] Add migration integrity and validator tests.
- [x] Complete PowerShell and Terraform validation.
- [x] Commit, push, and open the focused pull request.
- [x] Remove the redundant repository-management PR cleanup workflow.
- [x] Align repository-sync settings with scoped variables and one secret.
- [x] Disable scheduled sync until the manual cutover is validated.
- [x] Repoint Avm.Authoring managed-file defaults to this repository.
- [x] Remove the retired repository from supported MAPOTF maintenance tooling.
- [x] Validate and prepare the runtime repointing correction for release.

## Validation

- `./build.ps1 test`: 867 passed, 7 skipped.
- `./build.ps1 pre-commit`: 867 unit and 26 component tests passed.
- All migrated PowerShell files parsed without errors.
- Migrated repository configuration and Avm.Authoring upgrade tests passed.
- VS Code Marketplace validation passed for all managed recommendations.
- `terraform fmt -recursive`, `terraform init -backend=false`, and
  `terraform validate`: succeeded.
- `Invoke-Pester` for `MigrationLayout.Tests.ps1`: 2 passed.
- `./build.ps1 pre-commit`: 867 unit and 26 component tests passed after
  removing the redundant cleanup workflow.
- `Invoke-Pester` for `MigrationLayout.Tests.ps1`: 3 passed after validating
  the repository variable and secret references.
- `./build.ps1 pre-commit`: 868 unit and 26 component tests passed after
  aligning the workflow configuration contexts.
- `Invoke-Pester` for `MigrationLayout.Tests.ps1`: 4 passed with the schedule
  cutover guard.
- `./build.ps1 pre-commit`: 869 unit and 26 component tests passed with the
  schedule disabled.
- Focused managed-file and migration tests: 52 passed.
- `./build.ps1 pre-commit`: 872 unit tests passed, 7 skipped, and 26 component
  tests passed after repointing the runtime defaults and removing the obsolete
  MAPOTF upstream refresh.

## Provenance

Source snapshot: `Azure/avm-terraform-governance` commit
`59078e1bde61af0a5881331d2d26a41f791f5624`.

## Blockers or dependencies

All configuration is present: all 10 settings are `avm` environment variables,
including the three ARM identifiers and all 21 test subscription IDs;
`AVM_APP_PRIVATE_KEY` is the sole `avm` environment secret. The schedule remains
commented out for cutover. Merge with it disabled, manually dispatch a plan-only
sync on target `main`, disable the source schedule, then restore the target
schedule in a follow-up.

The corrected Avm.Authoring defaults are recorded under `CHANGELOG.md`
`[Unreleased]`. The in-repository module manifest remains unchanged by design;
the existing release pipeline stamps the next tag into the published package.
