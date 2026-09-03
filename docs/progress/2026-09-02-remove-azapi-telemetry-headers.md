# Remove AzAPI telemetry headers

**Status**: complete
**Started**: 2026-09-02
**Updated**: 2026-09-03
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
- [x] Run the updated pre-commit chain against current AzAPI and AzureRM
      modules, including modules with no AzAPI resources.
- [x] Validate the transformed real modules and record the results.

## Validation

- `./build.ps1 pre-commit`: passed.
  - Unit: 1,019 passed, 8 skipped.
  - Component: 29 passed.
  - Layout and lint passed.
- `$env:AVM_INTEGRATION_FIXTURE = 'terraform-azure-avm-res-mock';
  ./build.ps1 integration`: passed, 19 passed and 1 fixture-specific skip.
- Released MaPoTF 0.1.10 removed the AVM lifecycle-header contributions and
  four obsolete helper locals while preserving custom headers, both AzAPI
  resource blocks, and `local.main_location`.
- Fresh real-module validation used the local PR build for two modules with no
  AzAPI resources and two modules with AzAPI resources:
  - `terraform-azurerm-avm-res-keyvault-vault`: pre-commit and validation
    passed; second transform changed zero files.
  - `terraform-azurerm-avm-res-network-networksecuritygroup`: pre-commit and
    validation passed; second transform changed zero files.
  - `terraform-azapi-avm-res-network-networksecurityperimeter`: six
    `azapi_resource` blocks; pre-commit and validation passed; second transform
    changed zero files.
  - `terraform-azurerm-avm-res-storage-storageaccount`: 84 `azapi_resource`
    blocks, six `azapi_update_resource` blocks, and one
    `azapi_resource_action`; pre-commit and validation passed; second transform
    changed zero files. All 30 executable `local.avm_azapi_header` references
    were removed and all 58 unrelated tracing-header attributes were preserved.
- The cleanup remains a single MaPoTF invocation. Header removal runs before
  resource and module attribute ordering through `depends_on`; no MaPoTF code
  change or post-transform bundle is required.

## Blockers or dependencies

None.
