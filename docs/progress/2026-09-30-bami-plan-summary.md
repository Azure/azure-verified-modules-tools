# BAMI candidate plan summary

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Branch**: `jaredfholgate-bami-plan-summary`

## Outcome

Added a source-only, allow-listed console summary after candidate identity plan
validation. It shows the seven managed resources, actions, identity and
delegation scopes, directory membership, federation bindings, and full delegation
condition on the Information stream. Terraform unknown and sensitive masks are
honored; missing fields are not guessed. Raw plan/state/output documents,
variables, credentials, and environment values are excluded.

Validation, structured returns, plan-only behavior, coupled apply, and temporary
workspace cleanup are unchanged. Each invocation still generates and validates
its own saved plan; a later apply does not reuse an earlier preview binary.

## Checklist

- [x] Read repository guidance, current validator, and related open reviews.
- [x] Add the minimal post-validation summary and honest unknown markers.
- [x] Cover the real helper call path with synthetic plans and mocked boundaries.
- [x] Run focused tests, the existing pre-commit gate, and encoding checks.

## Validation

Baseline: `fb3f33ed92121c3a0d3e91c0d64063b7ba82affe`.

```powershell
.\build.ps1 pre-commit -TestName @(
    'Tools repository federation context*'
    'Terraform test tenant selection*'
    'Candidate plan and output safety*'
    'Terraform effective contract and state wiring*'
    'Isolated candidate identity orchestration*'
    'BAMI candidate plan summary*'
    'Repository sync test tenant selection*'
)
```

Passed layout, lint, 28 unit tests, and 85 component tests, including 24 new
summary cases; zero failures or skips. Nine warnings are the existing pending
identity guard cases. Tests exercise the real candidate orchestration,
Terraform wrapper, validator, and summary with mocked process/GitHub boundaries,
local synthetic saved plans, and sentinel secrets in unselected fields.
They cover exact output fields and actions, known/unknown IDs, sensitive masks,
unchanged result objects, invalid-plan rejection, no-write paths, cleanup, and
regeneration before coupled apply.

Changed files use UTF-8 without BOM and LF; `git diff --check` passed.

## Blockers or dependencies

No live execution is authorized. No workflow, cutover, identity permissions,
state access, or trust-condition changes are in scope.
[The coordinated change](https://github.com/Azure/azure-verified-modules-tools/pull/192)
also edits `TestTenant.ps1`; keep the summary hook immediately after
`Assert-AvmBamiIdentityPlan` and leave its run-context changes untouched.
The parent owns internal operating documentation and later rollout approval.
The existing validator is unchanged; the summary supplies human-review evidence,
not additional policy validation or a new runtime gate. No live candidate plan
or artifact was produced.
