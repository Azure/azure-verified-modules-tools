# Terraform policy provider-registration prevention

**Status**: in-progress
**Started**: 2026-10-06
**Updated**: 2026-10-06
**Branch**: `jaredfholgate-terraform-runtime-regression-fixes`

## Outcome

Prevent automatic AzureRM and AzAPI resource-provider registration in standalone
Terraform policy checks and the policy step of `pr-check`. Enforce safeguards in
isolated staging before provider configuration, preserving source files,
authentication, subscription, tenant and provider features. Leave deployment,
E2E and explicit feature-registration behavior unchanged.

The user authorized this tooling correction after canary inspection found that
AzureRM's modern registration setting does not protect AzAPI, while the shared
legacy environment flag conflicts with modern AzureRM settings. The parent
paused live plans until the safety package was qualified, then performed the
approved plan-only canary runs. This source session ran no Azure operations.
The safeguards do not make arbitrary authored hooks or data sources read-only.
Source implementation, the full local gate and the parent-owned canary matrix
are complete. The matrix is not all green: existing module findings, accepted
missing inputs and authored exclusions remain explicit below. Hosted CI failures
and pending Secure Future Initiative (SFI) sign-off still block overall
publication qualification.

## Checklist

- [x] Read the canonical contracts and verify the existing branch/review.
- [x] Resolve provider identities and schemas through existing tool helpers.
- [x] Enforce per-example safeguards across root, local and downloaded modules.
- [x] Reject unsafe or unsupported configurations before planning.
- [x] Cover aliases, overrides, environment conflicts, ordering and cleanup.
- [x] Run credential-free native checks and the full local gate.
- [x] Build the qualified package and preserve the complete case inventory.
- [x] Commit/push the source and hand the frozen package inventory to the parent.
- [x] Record the parent's completed approved canary qualification.
- [x] Identify the two hosted test-harness defects on the exact frozen candidate.
- [x] Repair concurrent trace writes and cross-platform Git file-URI construction.
- [x] Repeat focused controls and run native checks plus the full local gate.
- [ ] Qualify every current-head hosted CI leg without changing runtime files.

## Validation

- `.\build.ps1 test -TestName '*Terraform policy*','*Invoke-AvmTerraformCheckPolicy*'`:
  61 passed. Includes native filename selection, UTF-8 override ordering,
  escaped/linked module paths, invalid schemas/manifests and early failures.
- `.\build.ps1 component -TestName '*Invoke-AvmPreCommit + Invoke-AvmPrCheck*'`:
  13 passed. Real process fixtures require safeguards before both standalone
  and composite policy plans, verify per-example isolation/source preservation,
  and prove unsupported schemas prevent planning and trigger cleanup.
- `.\build.ps1 integration -IntegrationGroup Terraform -TestName '*Terraform policy provider registration safeguards*'`:
  2 passed with Terraform 1.16.5, AzureRM 3.117.1/4.81.0 and AzAPI 2.13.0.
  Native HCL parsing, schema acquisition and validation cover renamed/default/
  aliased providers, inherited proxy blocks, authored overrides, hash-prefixed
  filenames and a downloaded Git module. Invalid original provider attributes
  fail native validation; the safeguarded copies pass. No plan or Azure call
  is made; credential variables are removed from these child processes.
- `.\build.ps1 lint`: passed. The initial test iterations exposed fixture
  scope collisions and a misplaced Conftest stub switch branch; both were fixed.
  The component fixture now prohibits auto-install so a broken stub cannot be
  hidden by downloading a real policy runner.
- Full unfiltered `.\build.ps1 pre-commit`: passed, including layout/lint,
  **3,139 unit passes / nine existing skips** and
  **1,421 component passes / one existing skip**. Every prior c634 case/result
  identity is retained: 3,099 units and 1,418 components, with 49 and four new
  cases respectively. Comparison preserves duplicate identities and normalizes
  unordered NUnit argument serialization. No case or container failures.
  The first full run caught CRLF in the new source file; it was normalized to
  LF, and the entire gate was rerun successfully.
- `.\build.ps1 build`: passed after the gate. Full XML, reconciliation and
  native evidence are retained under the session's `policy-safety-gate-results`
  and `policy-safety-*.log` artifacts for the frozen-package handoff.

The implementation uses the already-pinned Conftest HCL2 parser and Terraform
provider schemas; no extra prerequisite or provider upgrade is introduced.
Explicit modern AzureRM configurations get `none`, an empty registration list
and `skip_provider_registration=false` where supported. Legacy AzureRM/AzAPI
get `skip_provider_registration=true`. Implicit configurations use child-only
`true`/`legacy` environment defaults (or modern `none` when legacy skip is not
in the installed AzureRM schema), avoiding new provider blocks that would
change inheritance. Authored query/state-migration files, backends/cloud
execution and extra CLI-argument injection are rejected rather than run without
a provable safeguard. Terraform 1.16.5 appends query provider blocks after
ordinary overrides, so treating them as normal `.tf` files would be unsafe.

### Completed parent-owned canary qualification

The final `protected-final-matrix.json` and
`protected-final-qualification.json` artifacts under
`terraform-canary-fixes-20261006` record local canary qualification for
`a7a4bf88cd5c1659ebebbdbed00679c455ee5c5f`. The final package rehash matches all
404 inventory entries; the frozen inventory SHA-256 remains
`3afc6d6bd7b28d07ca1659df7cfa991c56a0f896b60b26fb00a05dd1c92821e0`.
The doc-only handoff does not change that runtime candidate or its inventory.

All **26 commands** ran against the ten canaries and three utility controls:
**13/13 `pre-commit` passes** and **6/13 `pr-check` passes**, comprising four
canaries plus Naming and IP-addresses. Seven canaries and all three utilities
pass policy. No authored files changed. Every default run verified Terraform
1.16.5 and Pester 5.7.1 with clean PowerShell module visibility and all
prerequisites ready before step 1. The caller left both provider-registration
flags unset, so protection came from the qualified package rather than a
harness or module-source override.

| Case | Module | `pr-check` | Policy | Remaining finding |
| --- | --- | --- | --- | --- |
| canary-01 | Example repository | pass | pass | None |
| canary-02 | DevOps pool | error | error | User-accepted missing organization/PAT inputs |
| canary-03 | Virtual Network | pass | pass | All 15 examples passed policy |
| canary-04 | Cosmos DB account | pass | pass | None |
| canary-05 | Managed Environment | pass | pass | None |
| canary-06 | MongoDB cluster | fail | pass | Existing replacement-reference/private-endpoint lint findings |
| canary-07 | Disk | fail | pass | Existing private-endpoint interface lint finding |
| canary-08 | MySQL Flexible Server | fail | pass | Existing customer-managed-key/private-endpoint interface and comment-style lint findings |
| canary-09 | CDN profile | error | error | Established CDN retirement prohibition and three baseline lint warnings |
| canary-10 | AVS private cloud | fail | skipped | Existing tags/style/unused-provider lint findings; all six examples retain `.e2eignore` |
| control-01 | Naming | pass | pass | None |
| control-02 | IP-addresses | pass | pass | None |
| control-03 | Regions | fail | pass | Original-source unused AzAPI requirement in `modules/cached-data/terraform.tf:5` |

Actual standalone lint with unchanged `ed7497a` tooling reproduces every
non-notice finding for MongoDB, Disk, MySQL and AVS. The final MongoDB comparison
matches all five findings; MySQL matches all three and AVS all 16. Evidence
includes `mongodb-lint-baseline-reconciliation.json`,
`mysql-lint-baseline-reconciliation.json` and
`avs-lint-baseline-reconciliation.json`. Regions' native original-source
comparison reproduces its unused-provider warning. These are module-source
findings, not regressions introduced by this candidate; no checks were weakened
or module files edited to conceal them. No new tooling regression was identified
within this local matrix, which does not establish overall publication readiness.

A separate fresh-process Naming probe with Terraform 1.15.8 and Pester 6.2.0
passes both composite commands without Azure authentication. Both default
module-upgrade guards still reject with AVM1050 / exit 10.

The parent's post-run and delayed activity-log queries for
2026-10-06 19:38:55-20:47:28 UTC both returned zero events; the final query was
at 20:52:48 UTC. This is time-bounded observation, not an absolute side-effect
guarantee. No canary jobs remain running.

### Hosted test-harness correction

Hosted run 37519851922 used the exact `a7a4bf88` runtime. Concurrent stub
`Add-Content` calls corrupted or lost JSON trace records in Windows/Ubuntu
component jobs, even though both workers emitted their safeguard messages.
The fixture now takes an exclusive file handle only while appending each
complete UTF-8 record, with a bounded wait and explicit failure. Policy
execution still uses two workers; plan count, separate data directories,
command order, registration settings, cleanup and source-hash assertions remain.
An additional eight-worker fixture test requires all 24 records and exit codes.

Linux/macOS native cases constructed an empty Git source from a relative URI
cast of an absolute filesystem path. An explicit file-scheme `UriBuilder` now
produces the local Git source. The test asserts a nonempty absolute file URI
and a local-path round trip before use, and exercises a repository path with
spaces. Real Git download, negative original validation and safeguarded
validation remain required. These corrections touch tests only; runtime source,
the frozen 404-file package and its inventory remain unchanged.

The two-worker policy controls and eight-worker trace control passed in three
consecutive focused runs (three cases per run). The complete affected
public-command group passed all 14 cases, and both credential-free native
provider cases passed. The unfiltered `.\build.ps1 pre-commit` passed layout,
lint, **3,139 units / nine existing skips** and **1,422 components / one existing
skip**. All 3,148 prior unit and 1,422 prior component case/result identities
remain, plus the new trace case; both native case identities remain unchanged.
Evidence is retained in `hosted-harness-targeted`,
`hosted-harness-gate-results` and `hosted-harness-pre-commit.log`. A fresh
404-file rehash and source comparison to `a7a4bf88` passed, and the draft
description hash is unchanged.

## Blockers or dependencies

Continue [#229](https://github.com/Azure/azure-verified-modules-tools/pull/229);
keep its current draft description unchanged for this handoff. Hosted
[CI run 37519851922](https://github.com/Azure/azure-verified-modules-tools/actions/runs/37519851922):
Windows/Ubuntu test jobs and four Linux/macOS Terraform integration jobs failed;
lint and Bicep integration passed. The parent verified the run SHA and the two
test-harness defects above. Current-head hosted qualification is still required
after local verification and publication of the test-only correction. The
completed local canary matrix does not supersede those hosted failures.

DevOps-pool policy retains the user-selected missing
`azure_devops_organization_name` and `azure_devops_personal_access_token`
blocker; do not acquire credentials or invent values. Preserve the other
baseline findings and the AVS policy skips above. The version-override checksum
exception still requires SFI review/sign-off before merge/release; no sign-off
is recorded. No merge or release is authorized.
