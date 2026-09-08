# Terraform AVM state bootstrap

**Status**: in-progress
**Started**: 2026-09-08
**Updated**: 2026-09-08
**Branch**: `jaredfholgate-terraform-state-migration`

## Outcome

Replace the Bicep bootstrap with pinned Terraform AVM modules. Use disposable
local bootstrap state, save only non-secret handoff outputs, and leave the
created infrastructure in Azure.

The user approved deployment to TME and changed the region to West US 3. Storage
must disable shared-key and anonymous access. Moving the live repo-sync state
or changing its GitHub settings is not authorized by this deployment request.

## Checklist

- [x] Replace Bicep with AVM resource-group, storage, and identity modules.
- [x] Preserve federation, least-privilege RBAC, versioning, soft delete, and lock.
- [x] Update build/CI/tests and both deployment/cutover runbooks.
- [ ] Validate and commit/push the updated existing contribution.
- [ ] Inspect the plan and deploy only the approved TME bootstrap resources.
- [ ] Verify Entra-only settings and save non-secret handoff outputs.
- [ ] Discard successful bootstrap state/plans without destroying resources.

## Validation

- `.\build.ps1 infra`: pinned AVM modules/providers initialized and validated.
- `.\build.ps1 pre-commit`: 1,058 unit tests passed, 8 skipped; 29 component
  tests passed. Existing analyzer warning/retry behavior is unchanged.
- Focused repository-management tests: 58 passed.
- Read-only Azure-backed Terraform plan: nine creates (including the local
  role-assignment UUID), no updates or deletes. Target is the dedicated West
  US 3 group and `stavmstate92172623a0c0c6`.
- Plan confirms shared-key/anonymous access disabled, OAuth default, exact
  federation, container-only RBAC, seven-day soft delete, and versioning.
- Independent diff review found no significant issues.
- West US 3 StorageV2 Standard_ZRS is advertised without restrictions.
  The dedicated resource group does not already exist; Storage and
  ManagedIdentity resource providers are registered.
- User activated deployment access; target permissions now include `*`.

## Blockers or dependencies

No dependency on the unreleased Terraform backend environment-variable feature.
Keep local state on an interrupted/failed apply until it can be reconciled.
