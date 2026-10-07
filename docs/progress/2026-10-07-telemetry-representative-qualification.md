# Representative telemetry qualification in BAMI

**Status**: complete
**Started**: 2026-10-07
**Updated**: 2026-10-07
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Qualified the telemetry replacement on representative modules after preserving
the recent main updates. The user explicitly approved the tests needed
against the BAMI test tenant. The existing plan-only candidate workflow
passed for Key Vault, virtual network, ALZ networking and Windows Agent,
including their 97 original unit runs across the two batches below.
Regions remained unchanged and is not a migrated telemetry result.

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
- [x] Commit and push the qualified Tools source without force.
- [x] Verify automatic checks on the exact new Tools head.
- [x] Verify the configured BAMI tenant, controller, and admin subscription.
- [x] Verify dedicated identities and no-op prerequisites in the executing run.
- [x] Check all active/pending workflow states and exact-head duplicates.
- [x] Run bounded representative candidate checks.
- [x] Repair newly generated example locations without changing module
      requirements, authored regions, or main's policy safeguards.
- [x] Qualify the repair locally and rerun the affected BAMI candidates.
- [x] Record actual results, candidate trees, receipts, and remaining blockers.

## Validation

The main integration was committed and pushed as
`a12660b1a08c91bd65e15513c8e66176092e6c2f`. All 22 exact-head checks passed,
including all 16 jobs in
[Authoring CI](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37590697782).
The bounded, plan-only
[representative run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37592597034)
used that checked-out Tools source and only the five repositories above.
All five preparation plans reported no infrastructure changes, and every
publication job was skipped.

| Module | Candidate tree | Executed result |
| --- | --- | --- |
| Key Vault | `9e6c7dcebb78376430d95513f9db9156f8ac9454` | All nine checks and 34 unit runs passed; matching receipt |
| Virtual network | `435f7914042c7ca7c3f35be4daab83b8ca20ba7e` | Policy planning failed on an unset new example location; 53 unit runs across three directories passed |
| ALZ networking | `b1b3c0a7b7a7740ec353438b46f9fcd97a0f0ec5` | Same policy input failure; all eight unit runs passed |
| Windows Agent | `11af19c862b6cfe889c259634007a71be2221b08` | Checks and two unit runs passed; policy skipped by existing configuration; matching receipt |
| Regions | No changed tree | `NoChange` receipt; remote module checks and unit tests did not run |

ALZ and virtual-network lint passed. That run's policy failure was not a group,
permission, or download failure: the example transform introduced a required
`location` input but gave previously runnable examples no value for it.
The repair makes newly generated example inputs runnable without adding
defaults to reusable modules or replacing authored example declarations.
Actual Terraform plans, rather than configuration validation alone, cover
the regression.

The regression reproduced the same unset-variable failure with the released
MaPoTF 0.3.0 and Terraform 1.16.5, using a provider-free local module. Its
authored-default and authored-required counterparts passed. The central fix
gives only newly created example `location` declarations an `"eastus"`
default. Reusable module inputs remain required; existing example defaults,
required declarations, and per-item regions are not changed. No policy
engine or workflow input fallback was added.

The repaired example and deployment-telemetry integration selection passed
all 72 cases with no failures or skips. It verifies actual noninteractive
plans, authored defaults and required inputs, per-item regions, unchanged
canonical examples, utility exemptions, opt-outs, state migration, and
second-pass stability. The full `./build.ps1 pre-commit` gate passed layout,
lint, 3,301 unit tests and 1,498 component tests (nine and one platform skips)
in 25 minutes 13 seconds. The known intermittent analyzer crash recovered
within the existing retry limit; no lint rule was disabled.

### Successful repaired-source rerun

The repair was committed and pushed as
`a1df0e7976e9e7db70dc6532d91dffa88d410f99`. All 22 exact-head checks passed,
including all 16 jobs in
[Authoring CI](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37600188116)
and the
[configuration workflow](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37600188102).
Main `d14117248e085baa80fb608b97c93e3c3619b90e` remains an ancestor through
the history-preserving merge; no main changes were discarded.

The scheduled repository sync completed successfully before the next
dispatch. Fresh preflight checks found no active or pending sync, no
same-head duplicate, unchanged selected source commits, and the approved
BAMI configuration. The bounded
[ALZ and virtual-network rerun](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37605021337)
then executed exactly once on the qualified repair head, with
`plan_only=true` and checked-out authoring source. Both preparation plans
reported no infrastructure changes.

| Module | Candidate tree | Executed result |
| --- | --- | --- |
| ALZ networking | `1e3a26670ab6c35f0aff5aef33851b9aa72592fc` | All nine checks, including policy, and all eight original unit runs passed |
| Virtual network | `688e332c9a1c5d0f83eea930b838df61c966bacd` | All nine checks, including policy, and all 53 original root/child unit runs passed |

Both validation receipts match their prepared candidate's repository, phase,
base commit, changed-state flag and tree. Each candidate retains its own
dedicated validation client in the approved BAMI tenant, distinct from the
controller, Bicep client and other candidate. The 28 configured test
subscriptions are unchanged. The workflow completed successfully, and both
publication jobs were skipped.

Archive comparisons verified the new default in eight ALZ examples and five
virtual-network examples, with corresponding README updates. The other
differences were ordering in regenerated telemetry files; original module
calls, authored regions and unit-test files were byte-identical to the first
candidates. No policy or identity safeguard was weakened.

Key Vault and Windows Agent were not rerun: their earlier candidates contain
no example changes affected by this repair. Their matching receipts remain
bound to the first run and its Tools head, not to the rerun or a later
documentation-only commit.

### Utility and rollout boundaries

The unchanged Regions source at `abcc7c4138028371e88aa8d0be60a6537b08c40e`
passed its 56 existing provider-mocked unit runs across 12 files locally.
These are mocked applies with synthetic credentials and Azure CLI, managed
identity, and OIDC authentication disabled, not live deployments.
Its metadata has no `telemetryIdPrefix`, so the telemetry replacement profile
does not run. Its existing modtm telemetry remains; this is utility-exemption
coverage, not evidence of modtm removal. Legacy utility retirement needs a
separate disposition before claiming fleet-wide removal. Published module
dependencies were not rewritten and may still require modtm.

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

The [main integration slice](2026-10-06-telemetry-main-integration.md) is
complete. No blocker remains for the bounded candidate qualification recorded
here. The former group, plugin-download and example-input failures are
resolved for these candidates.

Live deployment and end-to-end idempotency checks, protected environment
approvals, release, consumer publication and wider rollout are not completion
claims of this slice. No further workflow dispatch is needed for its outcome.
Before wider rollout, update the internal
[team migration documentation](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs)
with the location contract, non-destructive state retirement, test migration
and utility boundary, reusing an existing open documentation review where
applicable. No internal documentation or authentication was changed here.
