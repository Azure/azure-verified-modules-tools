# BAMI workflow contract tests

**Status**: complete
**Started**: 2026-10-04
**Updated**: 2026-10-04
**Branch**: `jaredfholgate-test-identity-group-access`

## Outcome

Correct two stale workflow assertions on the existing
[review](https://github.com/Azure/azure-verified-modules-tools/pull/218),
on top of the user's merge commit
`89b9e14074ea7333bbc7b0fe30ba353935c5578f`.
Verify the eight BAMI source variables, app-private-key-only secret contract,
and separation between the BAMI provisioning controller and state-only CLI
login. Do not restore retired provider inputs or change production wiring.

## Checklist

- [x] Hold edits until the user's new-head CI results are available.
- [x] Fast-forward the clean worktree without a new merge or history rewrite.
- [x] Inspect new-head failure logs and reproduce both cases locally.
- [x] Check the actual workflow and both Terraform provider contracts.
- [x] Update assertions and add negative identity-isolation coverage.
- [x] Run focused cases and the broader relevant local gates.
- [x] Prepare the verified append-only commit and same-review publication.

## Validation

New-head Ubuntu logs and the smallest local selection both fail the two
retired-variable assertions in `MigrationLayout.Tests.ps1` and
`TerraformOperations.Tests.ps1`. The focused baseline is zero passed and two
failed. The new-head Ubuntu run reports 2,818 passed, two failed, and eight
skipped before the correction.

After correction, the smallest selection passes all three cases: the two
updated assertions and the new provider-root isolation case.
`.\build.ps1 test-repository-management` passes all 763 repository-management
unit tests, with zero failures or skips. The focused
`.\build.ps1 pre-commit -TestName` gate passes layout, lint, 98 unit and
92 component tests, with zero failures or skips. The gate covers both formerly
omitted test groups plus the BAMI configuration, provider, state, plan, summary,
and driver boundaries. Expected negative-path warnings remain.

`git diff --check` passes. Only the two test files and this slice record change;
the production workflow, scripts, Terraform roots, configuration, and backend
are untouched. Assertions now reject retired source variables and state-identity
provider fallbacks instead of weakening the original separation coverage.

## Blockers or dependencies

None in the source correction. The review remains open at the user's merge
head immediately before publication. Existing CI may continue independently;
no workflow dispatch/retry, repository sync, ALZ/bootstrap run, tenant call,
permission change, environment publication, merge, or history rewrite is
authorized.
