# Representative telemetry qualification in BAMI

**Status**: in-progress
**Started**: 2026-10-07
**Updated**: 2026-10-07
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Qualify the telemetry replacement on representative modules after preserving
the recent main updates. The user explicitly approved the tests needed
against the BAMI test tenant. Start with the existing plan-only candidate
workflow, which runs candidate checks and existing unit suites without
publishing module changes.

No permission changes, group creation, state repair, releases, publication,
protected-gate approval, or merge to main is authorized by this slice.
Do not cancel or displace another workflow run.

## Representative coverage

The following repositories were verified active, unarchived, non-forks with
default branch `main`. Recheck their commits before dispatch.

| Module | Coverage | Observed source |
| --- | --- | --- |
| [Key Vault](https://github.com/Azure/terraform-azurerm-avm-res-keyvault-vault) | Resource root, key/secret children, existing provider mocks | `42e230776874d00448a98857a86ba0bff9ea3801` |
| [Virtual network](https://github.com/Azure/terraform-azurerm-avm-res-network-virtualnetwork) | Nested peering/subnet modules and authored example regions | `27c6371d189159506363f11b13bcb3641ffffc18` |
| [ALZ networking](https://github.com/Azure/terraform-azurerm-avm-ptn-alz-connectivity-hub-and-spoke-vnet) | Multi-region pattern and eight original mocked plans | `670c45d48b0c7c6a244cddac8715269b0fc06185` |
| [Windows Agent](https://github.com/Azure/terraform-azurerm-avm-ptn-azuremonitorwindowsagent) | Pattern module with an explicit location contract | `f81345c6b353b4646f9ddf5154c3f296fb18ed58` |
| [Regions](https://github.com/Azure/terraform-azurerm-avm-utl-regions) | Utility without Azure resources; no telemetry/location requirement introduced | `abcc7c4138028371e88aa8d0be60a6537b08c40e` |

The real-tool fixture selection additionally covers AzureRM and AzAPI-native
module layouts, provider retention, telemetry opt-outs, native test migration,
and transformation idempotency.

## Checklist

- [x] Record explicit BAMI test approval.
- [x] Identify active representative repositories and source commits.
- [x] Finish the main-preservation gate and real-tool checks.
- [ ] Commit and push the qualified Tools source without force.
- [ ] Verify automatic checks on the exact new Tools head.
- [x] Verify the configured BAMI tenant, controller, and admin subscription.
- [ ] Verify dedicated identities and no-op prerequisites in the executing run.
- [ ] Check all active/pending workflow states and exact-head duplicates.
- [ ] Run bounded representative candidate checks.
- [ ] Record actual results, candidate trees, receipts, and remaining blockers.

## Validation

No new BAMI run has been dispatched. The earlier ALZ group failure was
resolved; its later candidate ran all eight unit plans successfully but
failed full checks while acquiring TFLint through a rate-limited GitHub API.
Those results do not qualify the current merged source.

Candidate validation now uses the job's existing read-only `GITHUB_TOKEN`
for tool downloads, matching main's integration workflow. The historical
TFLint failure used GitHub's unauthenticated 60-request limit. No GitHub App
token or additional permissions are granted to candidate validation.

All eight BAMI settings are present in the `avm` environment. Its tenant,
controller and admin subscription match the approved test configuration.
The existing `avm` and `avm-validation` environments have no protection rules
or deployment-branch restrictions. No settings were changed; this inspection
is not controller-authenticated group-lookup evidence.

The released-tool local selection passed all 131 cases without failures or
skips. This used synthetic credentials, not the BAMI tenant. The automatic
configuration workflow also retains main's backend-disabled native
`infra,test-tenant-terraform` tests for the pushed source.
The completed main-preservation gate passed layout, lint, 3,301 unit cases
and 1,498 component cases with zero failures (nine and one platform skips).

Report `NoChange`, `Skipped`, and pending identity prerequisites separately
from executed tests. A prepared candidate is not a successful validation,
and plan/unit coverage is not evidence of a full live deployment test.

## Blockers or dependencies

The [main integration slice](2026-10-06-telemetry-main-integration.md) must
complete first. Retain its current-main behavior and do not bypass any
candidate identity, source, or publication guard to obtain a passing run.
