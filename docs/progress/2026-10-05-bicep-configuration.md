# Bicep e2e ownership, convention exemptions and module pins in configuration

- Status: complete
- Started: 2026-10-05
- Branch: jaredfholgate-avm-authoring-refactor

## Outcome

Repeated Bicep domain literals and PowerShell module versions now live in packaged configuration under `Resources`, resolved from the loaded module.

- `Resources/bicep/settings.json`: e2e ownership tag (`avm-e2e-run-id`), run-ID pattern, and convention exemptions (e2e ignore list, optional defaults test, major-version allowance, parameter-name exceptions). Read through the cached `Get-AvmBicepConfiguration`.
- `Resources/avm.pins.jsonc` gains a `powerShellModules` section (`powershell-yaml`, `PSRule`, `PSRule.Rules.Azure`). `Test-AvmPins` validates it; `Get-AvmPowerShellModulePin` reads it. `Import-AvmBicepPolicyModule`, the convention workflow, `scripts/Install-AvmBuildPrerequisites.ps1` and the package qualification script use it instead of their own literals.
- `Test-AvmBicepRunId` and `Get-AvmBicepRunOwnership` replace eleven copies of the run-ID regex and the owner-tag lookup across cleanup, what-if, scoped state and isolation code.
- Az minimum versions in `Get-AvmBicepAzureRequirement` stay in code: they are a per-command requirement mapping, not a shared pin.

## Deliberate tightenings

- The run-ID pattern uses `\z` instead of `$`; .NET `$` also matched before a trailing newline.
- Saved cleanup state rejects a non-string `runId`.
- Scoped resource state refuses ownership when several case-variant owner tags exist without a group name, instead of depending on key order.
- Scoped what-if no longer treats a group carrying only a case-variant owner key as owned.

`Select-AvmBicepTestPoolSubscription` still validates `RunSeed` with its own pattern; it is a different value and was left unchanged.

## Checklist

- [x] Settings file, reader and ownership helpers
- [x] Call sites rewired; no remaining `avm-e2e-run-id` literals in engine code
- [x] Pins section, validation and getter; scripts read pins
- [x] Package qualification asserts the settings and pins resolve from the installed module
- [x] Tests: `BicepRunOwnership.Tests.ps1`, `Test-AvmPins.Tests.ps1` (expected values are literals, not read from the config under test)
- [x] `./build.ps1 pre-commit`

## Validation

- Focused: 258 passed, 0 failed, 1 skipped (pins, ownership, convention, cleanup state, policy, convention workflow).
