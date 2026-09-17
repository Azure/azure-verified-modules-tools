# Remove the extra canary activation switch

**Status**: complete
**Started**: 2026-09-17
**Updated**: 2026-09-17
**Branch**: `jaredfholgate-remove-canary-activation-switch`

## Outcome

Use the existing `testTenant` canary selections without the additional
`AVM_BAMI_TEST_TENANT_SYNC_ENABLED` variable or matching script parameter.
Preserve legacy defaults, trusted Tools/main restrictions, complete bundle and
target validation, isolated state, and existing plan/write and manual-dispatch
controls. Do not change canary membership or execute any live consumer.

## Checklist

- [x] Read the repository protocol and confirm the clean base matches current
      GitHub main at `84ba91ff4c6c85150f4d56f1392f2b558be9ab98`.
- [x] Report the ten Terraform repository IDs, single Bicep module path, and
      unchanged execution controls to the coordinating session.
- [x] Remove the extra workflow binding, script parameter, and pending status.
- [x] Cover selection-only routing and failures before mutation with mocks.
- [x] Update directly related behavior documentation.
- [x] Run focused local tests and the required pre-commit gate.
- [x] Prepare the validated slice for commit, push, and a focused source review.

## Validation

- `.\build.ps1 test-repository-management`: 443 passed, no failures or skips.
- `.\build.ps1 component -TestName @('Repository sync test tenant selection*',
  'Component: Terraform metadata workflow scope*',
  'Isolated candidate identity orchestration*',
  'Bicep test tenant entry point with real configuration and mocked GitHub*')`:
  63 passed, no failures or skips.
- `.\build.ps1 pre-commit`: layout and lint passed; 1,588 unit tests passed
  with eight existing skips, and 685 component tests passed with one existing
  skip. No failures. The analyzer reported 180 warnings in unchanged module
  source.
- All commands used `AVM_OFFLINE=1` and the repository's documented
  `DOTNET_MultiCoreJitMinNumCpus=7fffffff` runtime workaround. No dependencies
  needed installation. Tenant provisioning and publication used mocked
  subprocess/API boundaries only.
- Regression cases prove that an absent or false retired environment flag
  cannot skip selected BAMI repositories, untrusted Actions contexts fail
  before cleanup, all eight source values remain required, and legacy and
  repository-creation paths retain their behavior.
- Both central selection files, backend helpers, Terraform roots, shared
  bundle validation, and Bicep publication implementation remain unchanged.
  Remaining retired-switch references are regression tests and progress history,
  not runtime consumers or current operator instructions.

No live variables, credentials, workflow state, consumer jobs, Azure resources,
or Terraform state were changed.

## Dependencies and limits

- The separate [Owner-delegation fix](https://github.com/Azure/azure-verified-modules-tools/pull/111)
  remains a candidate-plan prerequisite and is not part of this change.
- Bicep variable publication remains a manual operation. Scheduled Bicep Sync
  continues to synchronize CODEOWNERS only. Manual `enable_test_tenant_sync`
  selects the operation; `plan_only` controls writes. Terraform's existing
  schedule and repository-dispatch applies will attempt BAMI preparation for
  the ten selected canaries once this source reaches trusted main.
- Complete-bundle validation does not prove that separately published values
  belong to the same publication. No atomic-publication claim or replacement
  activation control is introduced.
- The coordinating session owns live-variable cleanup and the matching update
  to [azure-cloud-native/Azure-Verified-Modules-Docs#48](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/48).
- The paired publisher removal is
  [azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI#41](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI/pull/41).
  Keep live-variable cleanup separate while deployed consumer code still
  requires the retired variable. Neither source review authorizes a merge or
  consumer run.
