# Bicep e2e required feature registration

- Status: complete
- Started: 2026-10-04
- Branch: `jaredfholgate-avm-authoring-refactor`
- Upstream reference: `Azure/bicep-registry-modules` main `7c31eb81`, repository-root `.required-features.json` and `Register-AzFeature` step in the e2e workflow

## Outcome

Upstream parity behaviour change, separate from the refactor commits. Bicep
`avm test e2e` registers a module's required Azure features in the selected
test subscription before validation. Registry modules use their exact entry in
the repository-root manifest; other modules keep the module-root array.

## Decisions

- The manifest is read and fully validated before confirmation, so a bad file fails before any Azure call. `Complete` does not re-read it.
- Registration runs after the Azure identity check and before cleanup state is written. A registration `AvmException` fails the case with `feature-registration-failed`, no state and nothing to clean up; other errors propagate.
- Registration runs once per subscription per run; later cases on the same subscription skip the repeat lookups.
- `Register-AvmFeature` and e2e share `Invoke-AvmFeatureRegistration`; `avm register-features` also understands the registry manifest.

## Checklist

- [x] `ConvertTo-AvmRequiredFeature`, `Get-AvmContextRequiredFeature`, `Invoke-AvmFeatureRegistration`; registry object support in `Read-AvmRequiredFeature`.
- [x] Engine and native test case wiring.
- [x] Unit tests for the manifest reader; component tests for registration order, failure and invalid manifests.
- [x] Spec and CHANGELOG.
- [x] `./build.ps1 pre-commit` green; commit and push.

## Validation

- Targeted feature, `Register-AvmFeature` and scoped Bicep e2e suites: 77 passed in 11s.
- `./build.ps1 pre-commit`: green in 11m26s (2,906 unit tests; component shards all passed, 1 existing skip).
