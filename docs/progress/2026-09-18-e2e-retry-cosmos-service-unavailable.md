# e2e retry: Cosmos DB high-demand ServiceUnavailable

**Status**: complete
**Started**: 2026-09-18
**Updated**: 2026-09-18
**Branch**: `jaredfholgate-telemetry-default-mapotf`

## Outcome

Added a pattern to `Test-AvmTerraformTransientError` for the Cosmos DB
`ServiceUnavailable` failure ("currently experiencing high demand in
<region>") seen in
[terraform-azurerm-avm-res-documentdb-databaseaccount#221](https://github.com/Azure/terraform-azurerm-avm-res-documentdb-databaseaccount/actions/runs/35353249359/job/105626330417?pr=221),
so e2e now retries it as a transient capacity error instead of failing hard.

## Checklist

- [x] Add the new retry pattern to `Test-AvmTerraformTransientError`.
- [x] Add a focused unit test asserting the new pattern is classified as retryable.
- [x] Run the repository gate.
- [x] Commit and push the slice.

## Validation

- `./build.ps1 test -TestName 'Test-AvmTerraformTransientError'` — passed, 3 tests.
- `./build.ps1 pre-commit` — passed (run prior to rebasing this change onto `main`
  after PR #141 merged; only the retry-pattern change is included here).

## Blockers or dependencies

None.
