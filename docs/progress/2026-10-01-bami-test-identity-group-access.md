# BAMI test identity group access

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-test-identity-group-access`

The [configuration correction](2026-10-02-configured-test-identity-groups.md)
supersedes the fixed group-ID and Fabric-capability design below. This record
preserves the initial implementation and validation, not the current contract.

## Outcome

Implemented pinned BAMI group object IDs for each repository test identity's Directory
Readers and test-management-group Owner permissions. Repository sync owns only
individual membership edges. Fabric admin API membership requires explicit,
default-off repository opt-in. Preserve legacy identity configuration, isolated
state, controller/execution separation, and federation boundaries.

Obsolete Terraform-managed direct Owner assignments can be removed only through
a validated migration plan on a future separately approved apply. No
`removed { destroy = false }` blocks or broader deletion permissions are added.
The legacy Owner condition and all four federation subjects are retained.

Repository sync requires the three new `TEST_BAMI_*_GROUP_ID` variables in an
eleven-field projection. Existing eight-field source and five-field Bicep
projections, `test_identity`, consumer secrets, and backend settings are unchanged.
`repositoryGroups[].testCapabilities.fabricAdminApis` defaults to false;
true requires explicit canonical repository IDs and rejects wildcard selectors.
No repository configuration is opted in.

The private `test_group_contract` output exposes only observed provider IDs
and six allow-listed fields per group. Terraform's mocked-test JSON omits data
sources, so the gate reconstructs those records from actual output evidence,
not fixture assumptions, before running the production guard.

## Checklist

- [x] Read repository guidance and active or blocked progress records.
- [x] Rename the dedicated feature branch and check concurrent open work.
- [x] Confirm and communicate the group and Fabric opt-in contracts.
- [x] Wire workflow inputs, validation, Terraform memberships, and migration.
- [x] Preserve bounded identity plans and allow-listed summaries.
- [x] Add offline positive, negative, legacy, and migration coverage.
- [x] Update directly related repository documentation.
- [x] Finish the local gate and prepare the source-only publication handoff.

## Validation

`.\build.ps1 pre-commit -TestName` covering central tenant selection, complete
and pinned group bundles, explicit Fabric capabilities, tools federation
context, candidate plan/output safety, Terraform wiring, legacy Owner
delegation, isolated candidate orchestration, allow-listed summaries,
repository-sync entry-point gates, and Bicep publication/readback boundaries:
layout and lint passed; 187 unit and 100 component tests passed, zero failures
or skips. Eleven expected negative-path warnings remain.

`.\build.ps1 test-tenant-terraform`: format, init with `-backend=false`, validate,
and 29 mocked-provider plan cases passed across the existing Terraform root
(11), BAMI root (4), and shared Azure module (14). The actual BAMI plan passes
the group/federation guard; the deletion guard's UUID matches Terraform's
actual legacy `uuidv5` assignment name. All test runs use `command = plan`.

Declared public providers were restored after an offline cache-miss failure,
without upgrades, using private session `TF_DATA_DIR` directories and a provider
cache. No live Azure, Entra, Fabric, ADO, or GitHub provider data was read.
`git diff --check` passed. No cloud command, Terraform apply, workflow dispatch,
variable publication, tenant registration, licensing, or browser sign-in occurred.

## Blockers or dependencies

Source implementation and local validation are complete. The bootstrap owner
delivers groups, the shared conditioned Owner assignment, and publisher values in
[azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI#43](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Tooling-BAMI/pull/43),
commit `f6a58ce`. Internal operating guidance is maintained in
[azure-cloud-native/Azure-Verified-Modules-Docs#52](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs/pull/52).
Future live reconciliation requires separate explicit approval, verified Graph
read/membership readiness, and retention of the controller's existing Owner
assignment-deletion permission. Offline cases do not prove effective live
permissions or the role-only route.
