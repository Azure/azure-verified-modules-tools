# Terraform AVM state bootstrap

**Status**: complete
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
- [x] Validate and commit/push the updated existing contribution.
- [x] Inspect the plan and deploy only the approved TME bootstrap resources.
- [x] Verify Entra-only settings and save non-secret handoff outputs.
- [x] Discard successful bootstrap state/plans without destroying resources.

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
- Apply completed with nine additions, zero changes, zero destroys.
- Azure readback confirms `allowSharedKeyAccess=false`,
  `allowBlobPublicAccess=false`, `defaultToOAuthAuthentication=true`,
  private container access, ZRS/West US 3, versioning, seven-day retention,
  exact federation, and the deletion lock.
- UAMI client ID: `1634c564-8f0f-4a24-8de9-1531d9dcc6ec`.
  Its only role is Blob Data Contributor at the `tfstate` container.
  Role assignment ID: `6ed9c0be-f855-898b-e7e2-c91e10aebb47`.
- Saved `infra/tme.outputs.json` and compared all six values with Terraform
  outputs before deleting local state, its backup, and the apply plan.
- CI exposed missing Linux package hashes with a readonly lock file.
  Refreshed signed provider checksums for Linux AMD64/ARM64, Windows AMD64,
  and macOS AMD64/ARM64 without changing provider versions.

## Blockers or dependencies

No dependency on the unreleased Terraform backend environment-variable feature.
The infrastructure is deployed; the live repo-sync state migration and GitHub
configuration switch remain separate, unapproved operations. Do not reapply
the bootstrap after discarding its local state without importing resources.
