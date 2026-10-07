# Terraform scaffold AzAPI interfaces and version-check opt-out

**Status**: complete
**Started**: 2026-10-03
**Updated**: 2026-10-03
**Branch**: `jaredfholgate-avm-authoring-refactor`

## Outcome

The packaged Terraform scaffold (`Resources/Scaffolds/Terraform`) published by
`avm init` was a resource group with a minimal example. It is now an AzAPI
virtual network that takes `parent_id` and follows the AVM AzAPI interface
specifications (TFFR6 `resource_types`, TFFR7 `retry`/`timeouts`, TFFR8
`ignore_body_changes`). The default example selects a recommended region with
`Azure/avm-utl-regions/azurerm` 0.12.0, names resources with
`Azure/avm-utl-naming/azure` 0.2.0, creates its resource group through AzAPI, and
declares the `enable_telemetry` variable that the example telemetry transform
would otherwise generate.

While verifying the scaffold with `Invoke-AvmTransform -SkipModuleVersionCheck`,
the run failed with `AvmModuleVersionException` because the PowerShell Gallery
had a newer release. Each public command checked the version with the caller's
opt-out, then called the public `Get-AvmModuleContext`, which checked again
without it. Fourteen public commands now resolve context through the private
`Get-AvmModuleContextInternal`, so one check honours the caller's choice. The
public `Get-AvmModuleContext` keeps its own check.

## Checklist

- [x] Rewrite the scaffold module and example.
- [x] Validate a scaffold copy: `terraform fmt -check`, `init`, `validate`, and
  tflint with the shipped module and example configs.
- [x] Confirm `Invoke-AvmTransform` changes no authored scaffold file (it adds
  only the generated `main.telemetry.tf`) and `Invoke-AvmLint` reports no
  issues on the transformed copy.
- [x] Fix the repeated version check and update the unit-test mocks.
- [x] Add a behaviour regression across Lint, Format, Transform, Docs and Test;
  it failed for four commands before the fix and passes after it.
- [x] Update the implementation spec, module README and CHANGELOG.
- [x] Pass `./build.ps1 pre-commit`.

## Validation

- Targeted Pester run of `tests/Pester/Unit/Public`, `Test-AvmModuleVersion`
  and `Get-AvmTerraformScaffoldPlan`: 343 passed, 0 failed.
- `./build.ps1 pre-commit` (Pester 5.7.1): passed in 9m25s. Unit 2,859 passed
  and 9 skipped; component 1,264 passed and 1 skipped.
