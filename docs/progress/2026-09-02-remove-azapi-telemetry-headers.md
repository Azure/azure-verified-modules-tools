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
- [x] Remove MaPoTF-generated telemetry headers and helper locals from local
      submodules without applying root-only telemetry rules.
- [x] Validate recursive cleanup against real modules containing generated
      submodule telemetry.
- [x] Remove the legacy `tracing_tags_header` -> `tracing_headers` submodule
      forwarding chain associated with AVM telemetry.
- [x] Confirm the storage-account module no longer contains the 58 lifecycle
      header attributes, 15 helper locals, or 15 input variables.
- [x] Partition MaPoTF rules into common, module, and root profiles without
      duplicating rule files.
- [x] Apply common in-place transforms to examples without moving blocks
      between files.
- [x] Capture and review full Storage Account and Web Site module diffs.

## Validation

- `./build.ps1 pre-commit`: passed.
  - Unit: 1,022 passed, 8 skipped.
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
    changed zero files.
- MaPoTF-generated submodule telemetry was confirmed in
  `terraform-azurerm-avm-res-compute-virtualmachine/modules/backup` and
  `terraform-azurerm-avm-res-app-containerapp/modules/auth-config`.
- Profile design: root modules run `root,module,common`; local submodules run
  `module,common`; examples run `common` only. Module-only file-layout rules
  cannot move example blocks out of an authored single-file `main.tf`.
- Fresh VM and Container App runs removed all executable
  `local.avm_azapi_header` references from the root and submodules, passed
  `avm test`, and produced zero transform changes on the second pre-commit run.
- Storage Account cleanup removed all 58 nested lifecycle header attributes,
  15 `tracing_headers` locals, 15 `tracing_tags_header` variables, and
  transitive module arguments. Terraform validation passed and the second
  pre-commit transform changed zero files.
- Managed HSM cleanup removed its root `tracing_headers` chain, including
  merged and direct header uses, and passed Terraform validation.
- Fleet search enumerated 209 active Azure Terraform AVM repositories. The
  indexed matches across 187 affected repositories classified as 544
  executable AzAPI header attributes, 186 helper-local definitions, and 16
  executable forwarding expressions; every executable shape is handled by the
  cleanup rule. The only other match was documentation text. The inventory was
  independently reproduced with searches for all nine supported repository
  name prefixes; both enumeration methods returned the same 209 repositories.
- Every repository with indexed generated telemetry under `modules/` was
  exercised: ALZ hub/spoke, ALZ virtual WAN, Container App, Cognitive Services,
  and Virtual Machine. Each passed pre-commit and Terraform validation and
  produced zero changes from a repeat transform.
- Scoped profile validation passed with released MaPoTF 0.1.10:
  root=`root,module,common`, submodule=`module,common`, example=`common`.
  An example containing variable and output blocks in `main.tf` retained both
  blocks in that file and no `variables.tf` or `outputs.tf` was created.
- Storage Account and Web Site both passed pre-commit and Terraform validation;
  repeat transforms changed zero files. Complete diffs were saved under the
  session artifacts as `profile-module-validation/storage-account.diff` and
  `profile-module-validation/web-site.diff`.
  - Storage Account: 83 files changed, 56 insertions, 403 deletions; transform
    duration 12m 21s.
  - Web Site: 20 files changed, 111 insertions, 162 deletions; transform
    duration 14m 03s.

## Blockers or dependencies

None.
