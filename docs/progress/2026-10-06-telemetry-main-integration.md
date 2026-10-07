# Telemetry branch integration with current main

**Status**: complete
**Started**: 2026-10-06
**Updated**: 2026-10-07
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Merge current main into the existing telemetry branch without rewriting its
published history. Preserve the telemetry migration and plan-only safeguards
alongside main's authoring refactor and repository-state consolidation.

The user authorized either a rebase or merge, then explicitly required that
recent main behavior be preserved. This slice uses a merge; rebuilding from
main remains an authorized fallback if preservation cannot be established.
On October 7 the user also approved the necessary tests against the BAMI test
tenant. Permission changes, releases, module publication, and merging to main
are not authorized. The earlier ALZ validation outcome remains recorded in
[the telemetry qualification slice](2026-10-02-telemetry-unit-test-scope.md).

## Inputs

- Telemetry branch: `78da7a92d5fd4f1c4d373e10d0bff0c0436eb724`.
- Fetched main: `d14117248e085baa80fb608b97c93e3c3619b90e`.
- Common ancestor: `a55f79c63e45fd0f141ffb2cd43eea5cad3522f0`.
- The working tree was clean and the published feature branch matched HEAD.
- Existing review: [#192](https://github.com/Azure/azure-verified-modules-tools/pull/192),
  verified open at the telemetry branch input.

## Checklist

- [x] Read the progress protocol and repository guidance.
- [x] Fetch main and verify the existing branch and open review.
- [x] Merge main and reconcile any overlapping changes.
- [x] Compare the final changes against recent main updates.
- [x] Verify the main-preservation regression tests.
- [x] Run the selected released-tool MaPoTF and TFLint integrations.
- [x] Run the full local pre-commit gate.
- [x] Record the qualified merge outcome for the existing feature branch.

## Validation

The 29 conflicted paths are resolved and staged. The initial focused unit run
passed 303 cases and failed two outdated assertions: the public WhatIf test
mocked the old context helper, and the retry test expected three transforms
instead of the root and module-call passes. Both assertions are corrected.
The focused rerun passed 62 unit and 427 component cases, with no failures or
skips (`out/telemetry-main-integration-focused-recheck.log`).
The first full gate passed layout and lint but found 15 unit failures
(3,286 passed, nine skipped). Ten exposed main's legacy TFLint override
migration being restricted to 1.0.0 despite the telemetry pin being 1.2.0;
the remaining failures were old duplicate-version-check and workflow binding
assertions. The compatibility path now recognizes both verified releases,
retains unknown/prerelease plugin handling, and the assertions follow the
new internal resolver and environment-bound inputs. The focused repair run
passed 108 cases. The next full gate passed all 3,305 unit cases (nine skipped)
but failed four component cases: three read the workflow steps from their old
file, and one expected the old duplicate version check. Their assertions now
target the reusable workflow and the single version check.

The additional main-preservation comparison found two behavioral regressions:
local `-WhatIf` was rejected outside Actions, and the moved project issue
reporter lost main's nonzero error exit. New component cases reproduced both
failures (66 passed, three failed). The fixes restore the local preview gate
without permitting actual execution outside Actions, and restore project
error propagation. All 69 focused preservation cases now pass, including
executing the project reporting step in a child process to check its exit
code. The subsequent full gate passed layout, lint, 3,299 unit cases (nine
skipped) and 1,498 component cases (one skipped), with no failures.

The workflow comparison also identified missing configuration-test triggers
for the new reusable workflow and candidate entry points. Those paths and a
regression assertion are now included without removing any main filters.
All five focused workflow cases pass. The selected released-tool integrations
passed all 131 cases without failures or skips, using synthetic Azure
credentials with CLI, managed identity and OIDC authentication disabled.
The final gate with the CI coverage correction passed layout, lint and all
3,300 unit cases (nine skipped), but two component cases failed (1,496 passed,
one skipped). Both new reporting exit-code cases depended on another test
file loading `Avm.Authoring`; a fresh shard correctly exposed the missing
test prerequisite. The reporting test file now imports the source module in
its own `BeforeAll`, matching the adjacent repository component suites.
All ten focused reporting cases pass. Native telemetry source is unchanged.

The candidate workflow still lacked the authenticated download token used
by main's integration workflow, leaving the historical TFLint API-rate-limit
failure unaddressed. A regression case reproduced the missing binding.
Candidate checks now receive the existing read-only job token through
`GITHUB_TOKEN`; the preparation App token and backend identity remain absent.
The intermediate gate was stopped before this workflow change so that the
next complete gate qualifies one consistent source tree. All six focused
workflow cases pass. The next complete gate stopped without recording a
result after 3,301 unit passes (nine skipped), at the component-stage start.
The morning check found no remaining build workers. Following the user's
instruction to complete the work autonomously, the full gate completed
successfully: layout, lint, 3,301 unit passes (nine skipped), and 1,498
component passes (one skipped), with zero failures. The run finished in
18m53s; evidence is in `out/telemetry-main-resumed-gate.log`.

## Reconciliation

- Retained main's internal context resolver and context-aware feature discovery;
  public commands still perform their version check once.
- Kept native MaPoTF 0.3.0 and AVM TFLint 1.2.0, with main's new managed
  PowerShell prerequisites and shared network retries.
- Retained telemetry and test migration helpers; removed the obsolete local
  provider retry classifier replaced by main's shared implementation.
- Kept the single repository/identity state from main. Its Terraform runner
  never repairs state locks or retries an uncertain apply, including previews.
  The obsolete separate identity root and its orchestration tests stay removed.
- Preserved separate candidate preparation, validation, and publication jobs.
  Moved main's backend resolution and GitHub-token safeguards into the reusable
  preparation job; removed its obsolete state-login and interactive gh login.
- Manual feature-branch previews remain plan-only. Candidates with pending
  identity/federation/membership changes are skipped before authoring. Ready
  candidates export only settings matching the verified dedicated identity and
  configured test subscriptions from the consolidated Terraform output.
- Ported preview and lock-failure assertions into the current driver and
  saved-plan component suites. Preserved main's catalog-fixture extraction
  while updating Terraform fixture prefixes to the seven-hex format.
- Verified the consolidated Terraform root, Terraform operations runner,
  build scripts, runtime tool helpers, and Bicep engine match main exactly.
  The PowerShell module prerequisites remain unchanged; only the required
  MaPoTF and AVM TFLint pins differ.
- Restored the unused legacy retry helper and its original tests to main's
  versions. Its older branch-only switch is no longer used by any caller;
  the current runner's no-lock-repair behavior has separate component coverage.
- Preserved main's project-token prerequisites and failure reporting when
  moving those steps into the per-repository reusable workflow.
- Kept configuration checks subscribed to the new workflow and candidate
  entry points. Hosted configuration checks retain main's backend-disabled
  `infra,test-tenant-terraform` validation.

## Blockers or dependencies

There are no remaining local integration blockers. Exact-head hosted checks
and representative BAMI results remain separate qualification steps.
The historical single-preview approval remains consumed; the October 7 BAMI
test approval is a new authorization, not a retry under the earlier permission.

Representative-module coverage is tracked in
[the BAMI qualification slice](2026-10-07-telemetry-representative-qualification.md).
