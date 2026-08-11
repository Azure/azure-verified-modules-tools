# Repository management migration

**Status**: complete
**Started**: 2026-08-10
**Updated**: 2026-08-11
**Branch**: `jaredfholgate-migrate-repository-management`

## Outcome

Move the active Terraform repository-management automation from
`Azure/avm-terraform-governance` into isolated folders in this repository
without changing its scheduled behavior.

## Checklist

- [x] Copy managed-file overlays and repository configuration.
- [x] Move repository sync Terraform, scripts, action, and metadata.
- [x] Separate repository creation from repository sync.
- [x] Migrate supporting workflows and Dependabot paths.
- [x] Add migration integrity and validator tests.
- [x] Complete PowerShell and Terraform validation.
- [x] Commit, push, and open the focused pull request.
- [x] Remove the redundant repository-management PR cleanup workflow.
- [x] Align repository-sync settings with repository variables and one secret.

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

## Provenance

Source snapshot: `Azure/avm-terraform-governance` commit
`59078e1bde61af0a5881331d2d26a41f791f5624`.

## Blockers or dependencies

The target has the known repository variables configured, including all 21 test
subscription IDs. `AVM_APP_CLIENT_ID` still needs to be supplied; the `avm`
environment also needs the `AVM_APP_PRIVATE_KEY` secret.
