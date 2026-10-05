# Automated repository state cutover

**Status**: complete
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-single-state-repository-sync`

## Outcome

Prepared temporary migration execution in the existing repository-sync workflow in
[the same draft](https://github.com/Azure/azure-verified-modules-tools/pull/224).
The user requested that an approved run perform the final migration; cleanup
of this temporary code is a separate future change. Preserve one ordinary
Terraform root, state, and saved plan/apply per repository, template ignore,
folded native diagnostics, and the decision not to add an activation setting.

Prepare and test code only. Do not access live state, change authentication or
permissions, cancel or dispatch workflows, merge, or execute the migration.
The user coordinates the writer freeze and approval of the eventual run.

## Checklist

- [x] Confirm the existing draft is open and the worktree is clean.
- [x] Trace native move/push, backend scope, existing inspection, and concurrency.
- [x] Send the coordinator the temporary execution and recovery sequence.
- [x] Inventory all former source keys independently of selected/excluded workers.
- [x] Add create-only private backup/checkpoint persistence and validated transfer.
- [x] Recognize exact interruption/completion states without force or blind retry.
- [x] Wire migration ahead of normal workers with coherent plan-only behavior.
- [x] Prove the actual orchestration with native local states and negative cases.
- [x] Run the full local gate and prepare same-draft publication.
- [x] Update existing documentation and prepare the replacement draft description.

## Validation

`.\build.ps1 pre-commit` passed: layout, lint, 2,897 unit tests and 1,374
component tests, with nine unit skips and one component skip. The final run used
the documented `AVM_LINT_MAX_ATTEMPTS=32` allowance; lint passed on attempt five.
No analyzer rules, dependencies, or module source were changed. A preceding run
hit a Windows directory-move access failure in the unchanged catalog component;
both affected case variants and then the complete gate passed without a fix.

`.\build.ps1 integration -TestName 'Integration: *repository state*'`
executed all 14 selected cases with zero skips. Native local Terraform covered
the real migration entry point, whole-module transfer and preservation,
source-first publication, lost responses after either push, completion-record
interruption, exact recovery, completed reruns, and legitimate later destination
changes. A built-in-provider unified saved-plan/apply preserved the existing
resources and IDs with no initial create/delete actions. Azure-shaped states
separately exercised strict ownership, federation, provider, private-data,
output, lineage, and serial checks; this is not a live Azure provider apply.

Component cases covered the complete inventory, excluded and failed-before-sync
repositories, missing/foreign/aliased ownership, default preview, WhatIf,
state-only identity separation, private storage and conditional readback,
backend binding checks, competing writers, and folded failure diagnostics.
Every changed file passed LF/UTF-8-without-BOM checks.

Exact published-head hosted outcomes are recorded in the existing draft
description and session evidence, not an additional evidence-only commit.
Prior source correction and its distinct 24-case hosted transfer proof remain
recorded in [the preceding slice](2026-10-04-single-state-repository-sync.md).

## Blockers or dependencies

No operational approval is implied. The temporary migration rejects other
active/old queued workflow revisions, changed snapshots, foreign scopes,
duplicate owners, uncertain partial states, and unreleased backend locks.
Backups and staged images stay in a separate create-only prefix of the existing
private state container, never in GitHub artifacts. Native publication remains
source-first and non-atomic; a durable checkpoint precedes either push.
The entry script defaults to preview. The workflow uses the existing
`plan_only` input, with no replacement approval flag. Scheduled and dispatch
runs retain apply mode, so the coordinating operator must control their launch
through merge, migration, verification, and resumption. No live inventory or
state operation was performed; the temporary support stays until the separately
requested cleanup change.
