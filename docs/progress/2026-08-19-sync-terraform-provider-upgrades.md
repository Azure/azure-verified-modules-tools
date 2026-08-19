# Repository sync Terraform provider upgrades

**Status**: complete
**Started**: 2026-08-19
**Updated**: 2026-08-19
**Branch**: `jaredfholgate-fix-sync-terraform-warnings`

## Outcome

Update the repository-sync Terraform module to the latest stable provider
minor versions and remove all provider deprecation warnings without changing
the managed repository behaviour.

## Checklist

- [x] Confirm the latest stable AzAPI, AzureAD, and GitHub provider releases.
- [x] Align root and child-module provider constraints.
- [x] Replace deprecated GitHub secret arguments.
- [x] Run the repository pre-commit gate and focused Terraform validation.
- [x] Commit, push, and open the pull request.

## Validation

- Terraform Registry latest stable releases: AzAPI `2.12.0`, AzureAD `3.9.0`,
  and GitHub `6.13.0`.
- `terraform fmt -check -recursive -diff`.
- `terraform init -backend=false -upgrade -input=false -no-color` selected the
  three expected provider versions.
- `terraform validate -json`: valid, 0 errors, 0 warnings.
- `.\build.ps1 pre-commit`.

## Blockers or dependencies

None.
