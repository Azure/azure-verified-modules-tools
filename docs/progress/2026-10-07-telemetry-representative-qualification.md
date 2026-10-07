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
- [x] Commit and push the qualified Tools source without force.
- [x] Verify automatic checks on the exact new Tools head.
- [x] Verify the configured BAMI tenant, controller, and admin subscription.
- [x] Verify dedicated identities and no-op prerequisites in the executing run.
- [x] Check all active/pending workflow states and exact-head duplicates.
- [x] Run bounded representative candidate checks.
- [x] Repair newly generated example locations without changing module
      requirements, authored regions, or main's policy safeguards.
- [ ] Qualify the repair locally and rerun the affected BAMI candidates.
- [ ] Record actual results, candidate trees, receipts, and remaining blockers.

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

ALZ and virtual-network lint passed. Their current blocker is not a group,
permission, or download failure: the example transform introduces a required
`location` input but gives previously runnable examples no value for it.
The repair must make newly generated example inputs runnable without adding
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

The unchanged Regions source at `abcc7c4138028371e88aa8d0be60a6537b08c40e`
passed its 56 existing provider-mocked unit runs across 12 files locally.
These are mocked applies with synthetic credentials and Azure CLI, managed
identity, and OIDC authentication disabled, not live deployments.
Its metadata has no `telemetryIdPrefix`, so the telemetry replacement profile
does not run. Its existing modtm telemetry remains; this is utility-exemption
coverage, not evidence of modtm removal.

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
complete. ALZ and virtual-network qualification remains blocked on the
repair's exact-head hosted checks and a successful bounded rerun. The
example-only repair is locally qualified; the already-passing Key Vault and
Windows Agent candidates contain no example changes affected by it. No
second run has been dispatched. Retain current-main behavior and do not bypass any
candidate identity, source, policy, or publication guard to obtain a pass.
