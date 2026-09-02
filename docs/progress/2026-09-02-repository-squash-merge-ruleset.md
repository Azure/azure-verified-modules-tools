# Repository squash merge ruleset

**Status**: complete
**Started**: 2026-09-02
**Updated**: 2026-09-02
**Branch**: `jaredfholgate-harden-repo-sync-rulesets`

## Outcome

Enforce squash as the only merge method in the repository-sync branch ruleset,
matching the repository-level merge settings already applied across AVM
Terraform repositories.

## Checklist

- [x] Configure the ruleset to allow only squash merges.
- [x] Add a regression test for repository and ruleset merge-method alignment.
- [x] Run the repository pre-commit gate.

## Validation

- `./build.ps1 pre-commit`
- `terraform fmt -check -recursive repository-management/repository-sync/terraform`
- `git diff --check`

## Blockers or dependencies

None.
