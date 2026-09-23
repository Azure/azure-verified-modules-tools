# Repository ruleset team bypass

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-ruleset-admin-bypass`

## Outcome

Allow configured teams to bypass the AVM branch ruleset on pull requests
without granting direct-push bypass. Enable the engineering owners team only
for the `avm-ptn-example-repo` canary; retain the existing AVM App bypass.

## Checklist

- [x] Resolve and validate per-repository bypass teams from repository groups.
- [x] Pass team slugs into Terraform and resolve their GitHub team IDs.
- [x] Configure only the ring-0 canary and cover the ruleset behavior in tests.
- [x] Document the rollout scope and complete validation.

## Validation

- `./repository-management/repository-sync/scripts/Test-RepositoryConfig.ps1`
  and `Test-RepositorySyncInputs.ps1` passed.
- `./build.ps1 test-tenant-terraform` passed: 10 repository-sync Terraform
  tests (including mocked ruleset plans) and 2 identity Terraform tests.
- `./build.ps1 pre-commit` passed: 1,740 unit tests and 907 component tests
  passed; 10 tests skipped. The gate emitted fixture warnings but no errors.
- `terraform fmt -check -diff` on changed Terraform files and
  `git diff --check` passed.

## Blockers or dependencies

Security review and SFI sign-off are required before merging this
pull-request-only ruleset bypass. No live repository sync or Terraform apply
was run.
