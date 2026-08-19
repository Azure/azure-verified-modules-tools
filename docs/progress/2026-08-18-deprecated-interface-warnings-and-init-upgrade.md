# Deprecated interface warnings and Terraform init upgrades

**Status**: complete
**Started**: 2026-08-18
**Updated**: 2026-08-18
**Branch**: `jaredfholgate-fix-deprecated-interface-warnings`

## Outcome

Render AVM TFLint deprecated-interface notices immediately as warning-level
diagnostics without changing lint or pull-request-check outcomes, retain the
findings in structured results, and avoid duplicate pass-level summary output.
Ensure every production Terraform init path opts into dependency upgrades.

## Checklist

- [x] Add scoped inline warning presentation for AVM deprecated-interface notices.
- [x] Preserve structured notice issues without duplicate final rendering.
- [x] Cover lint, nested pull-request check, GitHub annotation, integration, and controls.
- [x] Add `-upgrade` to every production Terraform init path.
- [x] Update argv assertions, relevant help, changelog, and a static regression guard.
- [x] Run targeted unit, component, and integration validation.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit, push, and open a pull request.

## Validation

- `./build.ps1 test`: 977 passed, 0 failed, 8 skipped.
- `./build.ps1 integration`: the pinned TFLint 0.64.0 / AVM ruleset 0.19.0
  attestation test passed for deprecated and canonical lock interfaces. The
  complete integration run reported 19 passed, 1 failed, and 2 skipped; the
  unrelated existing Azurerm policy fixture could not refresh an expired Azure
  CLI token (`AADSTS70043`).
- Production Terraform init audit: six PowerShell argument constructions found;
  all include `-upgrade`, and none use `-upgrade=false`.
- `./build.ps1 pre-commit`: 977 unit tests passed with 8 skipped; 28 component
  tests passed; layout and lint completed successfully.
- `git diff --check`: passed.

## Dependencies and blockers

No implementation blocker. Re-running the complete Azure-backed integration
suite requires local Azure CLI reauthentication; the changed real TFLint
integration completed successfully.
