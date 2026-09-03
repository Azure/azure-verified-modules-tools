# Credential-free Terraform policy plans

**Status**: complete
**Started**: 2026-09-03
**Updated**: 2026-09-03
**Branch**: `jaredfholgate-mock-azure-credentials`

## Outcome

Run the Terraform policy stage with native `terraform test` provider mocks so
`avm pr-check` can evaluate APRL and AVMSEC without Azure credentials. Keep
credentialled integration and end-to-end tests separate from the static PR
gate.

## Checklist

- [x] Generate an isolated mock-provider test for each active example.
- [x] Convert the Terraform test plan event into Conftest-compatible JSON.
- [x] Preserve hooks, `.env` variables, policy exceptions, and parallelism.
- [x] Prepare the reusable PR check change for a separate post-release pull
  request.
- [x] Keep credentialled integration and end-to-end jobs trusted-only.
- [x] Update unit, component, integration, and workflow coverage.
- [x] Run `./build.ps1 pre-commit`.

## Validation

- `./build.ps1 test`
- `./build.ps1 component`
- `./build.ps1 pre-commit`
- `./build.ps1 integration` with the
  `terraform-azurerm-avm-res-mock` fixture and all Azure authentication
  mechanisms disabled: 17 passed, 2 skipped.
- Direct real-binary policy checks with Azure authentication disabled:
  the AzureRM fixture passed 130 evaluations; the adversarial AzAPI fixture
  failed with the expected three APRL/AVMSEC findings.
- A synthetic AzAPI storage account/private-endpoint fixture triggered
  `AVM_SEC_STORAGE_PE_PUBLIC_ACCESS`, proving configuration-reference policies
  still evaluate against the credential-free plan.
- A real Terraform mock-provider alias plan completed without credentials.

## Blockers or dependencies

The reusable `terraform-module.yml` change is deliberately split into a
separate pull request. It must merge only after this module implementation is
released to PSGallery, otherwise consumers would invoke credential-free
behavior before their installed module supports it.
