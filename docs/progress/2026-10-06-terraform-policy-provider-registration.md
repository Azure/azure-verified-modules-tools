# Terraform policy provider-registration prevention

**Status**: blocked
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
stopped live plans and owns all authenticated reruns. This slice runs no Azure
operations and makes no universal read-only claim about authored hooks or data.
Source implementation and the full local gate are complete. The remaining
dependency is the parent-owned authenticated canary matrix, not a source failure.

## Checklist

- [x] Read the canonical contracts and verify the existing branch/review.
- [x] Resolve provider identities and schemas through existing tool helpers.
- [x] Enforce per-example safeguards across root, local and downloaded modules.
- [x] Reject unsafe or unsupported configurations before planning.
- [x] Cover aliases, overrides, environment conflicts, ordering and cleanup.
- [x] Run credential-free native checks and the full local gate.
- [x] Build the qualified package and preserve the complete case inventory.
- [ ] Record the parent's approved canary qualification.

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

## Blockers or dependencies

Continue [#229](https://github.com/Azure/azure-verified-modules-tools/pull/229);
no new review, merge or release. Parent owns the complete canary matrix and
approved plan-only BAMI credentials. DevOps-pool policy remains blocked by the
user-selected missing organization/PAT inputs; do not acquire or invent them.
The version-override checksum exception still needs SFI sign-off before merge.
CDN retains its independently reproduced provider-deprecation blocker. Regions
now passes legacy rule parsing but has an unchanged
`terraform_unused_required_providers` warning for AzAPI in
`modules/cached-data/terraform.tf:5`; the parent reproduced it on the original
module snapshot with native TFLint. Naming and IP-addresses standalone lint pass.
Do not weaken checks or alter module sources to conceal these matrix results.
