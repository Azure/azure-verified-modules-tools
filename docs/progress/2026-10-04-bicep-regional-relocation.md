# Bicep regional deployment relocation

- Status: complete
- Started: 2026-10-04
- Branch: `jaredfholgate-avm-authoring-refactor`
- Upstream reference: `Azure/bicep-registry-modules` main `7c31eb81`, `Invoke-TemplateDeploymentWithRetry.ps1` (regional retry with `Remove-Deployment` between regions)

## Outcome

Upstream parity behaviour change, separate from the refactor commits. A
confirmed deployment failure whose operation errors are all regional
(capacity, SKU or location eligibility) relocates an eligible case to another
region, but only after strict cleanup proves the failed attempt is gone.

## Decisions

- Eligibility is unchanged from validation relocation: unpinned, non-global, non-resource-group scope, not `-KeepResources`.
- Classification re-reads the exact deployment (must be `Failed`) and raw operation pages; any non-regional, unknown, malformed or mixed error retries in place. Classification read errors log a warning and retry in place; cancellation propagates.
- Strict cleanup (`Invoke-AvmBicepCleanup -RequireCompleteRemoval`) requires: failed root and terminal nested deployments, every operation terminal, Create operations with a target, no absent nested records, no workflow-excluded resources retained, soft-deleted names freed, and every deployment record deleted and confirmed absent (deepest first; records under a removed parent are skipped).
- If strict cleanup does not confirm removal, relocation stops with `relocation-blocked`, the case fails, and ordinary cleanup still runs.
- Regions already tried count towards `ValidationRetryLimit`; deployment attempts continue numbering, so total attempts never exceed `DeploymentRetryLimit`.
- `ResourceDeploymentFailure` is now a recognised wrapper code.

## Checklist

- [x] `Test-AvmBicepRegionalDeploymentFailure`, `Assert-AvmBicepCleanupDeploymentTerminal`, `Test-AvmBicepSoftDeletedResource`, `Remove-AvmBicepDeploymentRecord`.
- [x] Strict mode in discovery, removal, remainder purge and `Invoke-AvmBicepCleanup`.
- [x] `Test-AvmBicepNativeDeployment` `-UnavailableRegions`; `New-AvmBicepNativeDeployment` `-FirstAttempt`/`-AllowRelocation`; relocation loop in `Invoke-AvmBicepNativeTestCase`.
- [x] Unit tests: `BicepRelocationCleanup.Tests.ps1`.
- [x] Component tests: relocation succeeds in an unused region after record removal; blocked relocation still runs ordinary cleanup; pinned region retries in place.
- [x] Spec and CHANGELOG.
- [x] `./build.ps1 pre-commit` green; commit and push.

## Validation

- Targeted unit and component suites: 253 passed; fixture-based component suites: 90 passed.
- `./build.ps1 pre-commit`: 2,890 unit and 1,268 component tests passed (1 skipped) in 11m40s.
- Earlier gate runs failed in unrelated suites with `Expected [AvmProcessException] but was [AvmProcessException]`. Cause: when PowerShell evicts its parsed-script cache, reimporting reparsed `AvmExceptions.ps1` and created a second copy of each class. Adding files moved when eviction happened. Fixed separately in `Avm.Authoring.psm1` (see that commit's regression test).
