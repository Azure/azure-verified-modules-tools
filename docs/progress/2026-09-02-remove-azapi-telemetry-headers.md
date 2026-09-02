# Remove AzAPI telemetry headers

**Status**: complete
**Started**: 2026-09-02
**Updated**: 2026-09-02
**Branch**: `jaredfholgate-cleanup-azapi-telemetry-headers`

## Outcome

Remove the legacy AVM telemetry headers from AzAPI resources and remove the
header-only helper locals from `main.telemetry.tf` while preserving the
`modtm_telemetry` resource-based telemetry path.

## Checklist

- [x] Replace the AzAPI header injection transforms with header removal.
- [x] Remove obsolete AzAPI header helper locals from telemetry files.
- [x] Decouple telemetry variable and provider-version management from the old
      header rule.
- [x] Update fixtures, tests, and directly related documentation.
- [x] Validate the complete pre-commit and integration gates.

## Validation

- `./build.ps1 pre-commit`: passed.
  - Unit: 1,019 passed, 8 skipped.
  - Component: 29 passed.
  - Layout and lint passed.
- `$env:AVM_INTEGRATION_FIXTURE = 'terraform-azure-avm-res-mock';
  ./build.ps1 integration`: passed, 19 passed and 1 fixture-specific skip.
- Released MaPoTF 0.1.10 removed all lifecycle headers and the four obsolete
  helper locals while preserving both AzAPI resource blocks and
  `local.main_location`.

## Blockers or dependencies

None.
