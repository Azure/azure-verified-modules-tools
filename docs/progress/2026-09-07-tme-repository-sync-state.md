# TME repository-sync state

**Status**: complete
**Started**: 2026-09-07
**Updated**: 2026-09-07
**Branch**: `jaredfholgate-terraform-state-migration`

## Outcome

Prepare repository sync to keep state in TME while retaining the existing
provider identity and tenant. Source-control the North Europe ZRS storage
infrastructure and deployment/cutover runbook. No resources were deployed, no
state was copied, and no GitHub configuration was changed.

Use released Terraform with explicit, non-secret backend identity configuration;
do not depend on the unreleased environment-suffix feature.

## Checklist

- [x] Confirm the active branch, existing contributions, and runtime approach.
- [x] Add isolated backend identity configuration and state CLI authentication.
- [x] Preserve existing behavior until an operator enables the new backend.
- [x] Add Bicep for the resource group, protected blob storage, UAMI, federation,
      and container-scoped role assignment.
- [x] Document deployment, safe state copy, cutover, and rollback.
- [x] Add regression coverage and complete the pre-commit gate.
- [x] Prepare the feature branch for review and operator-controlled cutover.

## Validation

- `.\build.ps1 infra`: root Bicep and parameters compile without deployment.
- `.\build.ps1 pre-commit`: 1,057 unit tests passed, 8 skipped; 29 component
  tests passed; no failures. Existing module lint warnings and retry handling
  remain unchanged.
- State-identity, workflow, recovery, and infrastructure regression coverage
  runs in the normal Pester gate; a focused
  `.\build.ps1 test-repository-management` entry point is also available.
- Both runbooks' PowerShell snippets parse without execution. Azure CLI help
  confirms the copy/authentication options.
- ARM advertises North Europe StorageV2 Standard_ZRS for the TME subscription
  with no listed restrictions. This is not a reservation or capacity guarantee.
- Independent diff review found no significant issues.

## Blockers or dependencies

Production deployment, copying state, and changing GitHub environment variables
require operator confirmation. The state identities must trust the existing
repository-ID/environment-based GitHub OIDC subject.
