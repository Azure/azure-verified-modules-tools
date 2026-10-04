# Bicep deployment timeout watch

- Status: complete
- Started: 2026-10-04
- Branch: `jaredfholgate-avm-authoring-refactor`
- Upstream reference: `Azure/bicep-registry-modules` main `7c31eb81`, `Invoke-TemplateDeploymentWithRetry.ps1` (`Wait-TemplateDeployment`)

## Outcome

Upstream parity behaviour change, separate from the refactor commits. A native
e2e submission that times out no longer ends immediately as `Unknown`; the same
deployment is read by exact ID until terminal.

## Checklist

- [x] `Wait-AvmBicepNativeDeployment`: REST GET of the exact deployment, 3600s window, 15s poll, stop after three consecutive read timeouts; 404, wrong ID, unsupported state or non-timeout read errors throw (outcome stays unknown); cancellation propagates.
- [x] `New-AvmBicepNativeDeployment` watches only on `Timeout` with no confirmed status, never resubmits that name, and treats a recovered `Failed` as a confirmed failure (retry with the next name).
- [x] Confirmed-failure message pattern accepts upstream's optional `Showing N out of M error(s). Status Message: …` segment.
- [x] Unit tests: watch success/failure/unreadable, summary-message retry, watch boundaries (timeouts, 404, wrong ID, unsupported state, window expiry, cancellation).
- [x] Spec §e2e and CHANGELOG updated.
- [x] Window loop also capped by poll count (241), so a stubbed `Start-Sleep` cannot spin indefinitely.
- [x] Component: a late-success submission passes; a late-failed one runs post and cleanup like any confirmed failure.
- [x] `./build.ps1 pre-commit` green; commit and push.

## Validation

- `BicepNativeDeployment.Tests.ps1`: 35 passed in 9s.
- Full gate: 2,871 unit and 1,265 component tests passed (1 skipped) in 15m24s (lint 1m56s, unit 7m11s, component 6m15s).
