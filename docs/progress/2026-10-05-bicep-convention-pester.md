# Bicep convention checks as a packaged Pester suite

- Status: complete
- Started: 2026-10-05
- Branch: jaredfholgate-avm-authoring-refactor

## Outcome

`avm check convention` for Bicep runs its rules through Pester instead of a hand-rolled loop.

- The 12 `Test-AvmBicepConvention*` rule files moved from `Engines/Bicep` to `Resources/bicep/conventions/rules`. `Resources/bicep/conventions/Conventions.Tests.ps1` dot-sources them and runs one Pester test per compiled module, scope, workflow and repository-wide rule.
- `Invoke-AvmBicepConventionSuite` runs that file in process through the existing `Invoke-AvmPesterSuite` runner (new `Convention` mode) and maps the outcome back to the existing issue objects.
- Compilation, Git state, API-spec and MCR lookups, workflow discovery and repository test-file discovery stay in the engine (`Get-AvmBicepPublicationInput`, `Get-AvmBicepConventionWorkflowInput`, `Get-AvmBicepRepositoryTestFile`). The suite does no network or process work, so retries, offline mode and test mocks apply where they did before. Outer Pester mocks do not reach into a nested run.
- `Invoke-AvmBicepCheckConvention` keeps its result object. Issue codes, severities, files and lines are unchanged.

Terraform convention checks keep their native rule engine.

## Behaviour changes

- Pester 5.5.0 or later is now required for Bicep `check convention`, and so for Bicep `pre-commit` and `pr-check`. If the suite cannot start, the command reports `avm.bicep.convention-suite-unavailable` with install guidance.
- Issues are grouped by rule family instead of interleaved per module. Within publication checks, target and tag lookup issues come before CHANGELOG issues.
- A rule that throws is reported as `avm.bicep.convention-rule-failed` instead of aborting the command. A run with fewer passed or failed tests than expected (for example, skipped tests) is reported as `avm.bicep.convention-suite-incomplete`, so missing checks never count as a pass.

## Checklist

- [x] Move the rules and split out preparation
- [x] Suite, runner mode and engine invoker
- [x] Tests load moved rules through `tests/Pester/Import-AvmBicepConventionRule.ps1`, which reads the loaded module's `ModuleBase`
- [x] Unit tests for the suite invoker: no-op, findings, crash, failed test without finding, incomplete and skipped counts, runner diagnostics, missing Pester; allowlist unreadable-directory path
- [x] Package qualification asserts the suite, the 12 rules and the invoker are in the package
- [x] Help and CHANGELOG
- [x] `./build.ps1 pre-commit`

## Validation

- Focused unit tests (suite invoker, API version, compiled template): 26 passed.
- `BicepConvention.Component.Tests.ps1` plus `BicepScaffoldTelemetry.Integration.Tests.ps1`: 119 passed, 1 skipped (Pester 5.7.1).
- `./build.ps1 pre-commit`: lint clean; 2,977 unit tests passed; component shards 1,274 passed, 1 skipped, 1 failed. The failure was a Windows `Access denied` on a temporary-directory move in `ModuleCatalog.Component.Tests.ps1`, code this slice does not touch. Rerunning that file alone: 159 passed.
- Earlier gate attempts found CRLF line endings in the new files (now LF) and two transient PSScriptAnalyzer engine crashes in unchanged files.

## Timings

Measured on the same machine, running `BicepConvention.Component.Tests.ps1` alone (114 passed, 1 skipped both times):

| Tree | Elapsed |
| --- | --- |
| `9d16866` (before) | 71.3s |
| this slice | 75.3s |

The test that simulates MCR being unavailable no longer sleeps between real retries (about 11s saved). Even so, the file is about 4s slower overall, because each of its roughly 100 convention runs now starts a nested `Invoke-Pester` (about 0.15s each). A real `pre-commit` runs the suite once, so the cost there is negligible.
