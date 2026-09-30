# Bicep end-to-end post-deployment assertions

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bicep-test-support`

## Outcome

After a resource-group example has deployed successfully, run its authored
Pester assertions in an isolated child process, passing the ARM deployment
outputs and the example directory as `TestInputData`. Preserve the existing
ownership-checked resource-group cleanup on every assertion outcome.

## Contract

The registry deployment action runs case-local Pester tests after deployment
with `TestInputData.DeploymentOutputs` and
`TestInputData.ModuleTestFolderPath`; its separate local-testing script runs
only unit/compliance tests before deployment. Match the deployment action's
data contract. A case without authored assertion files is a successful
deployment with assertions explicitly marked `not-present`, not a passing
assertion run. Once files exist, require at least one passing assertion and no
failed, skipped, inconclusive, filtered, or missing tests. Runner setup errors
and timeouts fail that case. A failed or unverifiable cleanup still fails the
case and reports the group for manual inspection.

## Checklist

- [x] Reuse the unit tier's isolated Pester runner with the legacy e2e input
      data; discover only assertions belonging to each selected example.
- [x] Run assertions only after confirming the ARM deployment succeeded and
      before counting the example as passed.
- [x] Report missing, passing, failing, skipped, empty, and interrupted
      assertions distinctly without bypassing resource-group cleanup.
- [x] Cover success and failure paths with fake Azure/Pester processes and a
      real child-Pester contract test; update public help.
- [x] Run the full pre-commit gate and push this slice to the existing review.

## Validation

`./build.ps1 pre-commit`: layout and lint passed; 1,941 unit tests passed
(9 skipped) and 986 component tests passed. Focused Bicep assertions,
cleanup and unit-tier regressions: 58 component tests passed.
`./build.ps1 coverage`: 72.68% (5,117/7,040 commands), above the 70% floor.
Azure calls in component tests were mocked; real child-Pester contract tests
ran locally without Azure credentials or a live deployment.

## Blockers or dependencies

Subscription-, management-group-, and tenant-scoped deployments remain
unsupported until a separately reviewed isolation and teardown design is
approved. Legacy registry scripts and CI remain unchanged.
