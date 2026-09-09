# Isolated backend storage variables

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-terraform-state-migration`

## Outcome

Stage TME state storage independently of the original workflow's storage
settings. Use `ARM_BACKEND_STORAGE_ACCOUNT_NAME` and
`ARM_BACKEND_STORAGE_CONTAINER_NAME` with the backend identity, remove the
unnecessary runtime resource-group argument, and update bootstrap outputs and
runbooks. Keep the original variables, live state, and Azure resources unchanged.

## Checklist

- [x] Select identity and storage together; reject partial overrides.
- [x] Remove resource-group configuration from runtime state access.
- [x] Update outputs, local-only handoff values, regression coverage, and docs.
- [x] Add the two `avm` environment variables without altering existing values.
- [x] Complete the local gate and prepare the existing branch update.

## Validation

- `.\build.ps1 test-repository-management`: 72 passed, including every partial
  override combination and the actual workflow's backend resolution script.
- `.\build.ps1 pre-commit`: 1,072 unit tests passed, 8 skipped; 29 component
  tests passed. Existing analyzer warnings/retry behavior remains.
- `.\build.ps1 infra`: updated output contract validated without applying.
- Independent diff review found no significant issues.
- Added `ARM_BACKEND_STORAGE_ACCOUNT_NAME=stavmstate92172623a0c0c6` and
  `ARM_BACKEND_STORAGE_CONTAINER_NAME=tfstate` to the `avm` environment.
  Readback verified both and confirmed every pre-existing variable unchanged.
- Runbook PowerShell snippets parse without execution. Updated local handoff
  JSON remains ignored; no bootstrap state or plan was recreated.

## Blockers or dependencies

No state copy, workflow dispatch, merge, or apply is authorized by this change.
Testing with copied state must be plan-only. Freeze and drain all state writers
before copying or cutting over; two state files must not independently manage
the same resources.
