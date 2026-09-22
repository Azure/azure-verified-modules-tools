---
status: complete
---

# Workflow failure issue management (slice 3 of 4)

## Context

Part of porting the metadata-driven AVM PR/issue routing tooling that
`Azure/bicep-registry-modules#7378` removes from that repository (see
`docs/progress/2026-09-22-pr-reviewer-routing.md` and
`docs/progress/2026-09-22-issue-owner-routing.md` for slices 1 and 2). This
slice ports `Set-AvmGitHubIssueForWorkflow.ps1` /
`platform.manage-workflow-issue.yml`, recovered from
`Azure/bicep-registry-modules` git history at commit `2eb210dbb`.

The original watches every AVM module CI workflow (`avm.res.*`,
`avm.ptn.*`, `avm.utl.*`) plus the shared cross-module check/publish
pipeline in `bicep-registry-modules`, and for each one's latest completed
run on `main`:

- a **failure** with no existing tracking issue creates one, tags/assigns
  the module owner (or the tooling-contributors team for a platform
  workflow or an orphaned module), and applies `Type: AVM`/`Type: Bug`
  labels;
- a **failure** with an existing open tracking issue comments on it (once
  per day, to avoid spam), and cleans up any older duplicate issues for the
  same workflow (labels them `Type: Duplicate`, closes as not planned);
- a **success** closes every open tracking issue for that workflow with a
  closing comment.

## What changed for this port

- Runs cross-repo against `Azure/bicep-registry-modules` from this repo's
  scheduled workflow, instead of from a local checkout inside that repo.
- Module owner resolution reuses `lib/ModuleOwners.ps1` (index-first,
  `metadata.json` fallback) instead of a direct local file read, so it
  shares the exact same owner data source as slices 1 and 2.
- New shared library `repository-management/workflow-failure-issues/scripts/lib/WorkflowFailureIssues.ps1`,
  entry point `Invoke-AvmWorkflowFailureIssues.ps1`, and workflow
  `.github/workflows/repository-management-workflow-failure-issues.yml`
  (`workflow_dispatch` only while live validation is pending; the disabled
  daily schedule `41 5 * * *` is preserved in a comment).

## Scope reductions from the original

- **GitHub Project assignment** ("AVM - Issue Triage" / "AVM - Module
  Issues") is not re-ported here, for the same reason as slice 2: the
  existing generic `Add-RepositoryItemsToProject.ps1` already syncs
  project membership on its own schedule and will pick up newly created
  issues without a dedicated call at creation time.
- The original's created/commented/closed console counters (informational
  only) are dropped.

## Bug found while porting

`Resolve-AvmWorkflowFailureRouting` (the side-effect-free decision
function) originally returned a hashtable containing only the keys
relevant to the branch taken (e.g. only `IssuesToClose`/`CloseComment` on
the success path). `Set-AvmWorkflowFailureIssueForRun`, and the real entry
point, run under `Set-StrictMode -Version 3`, under which dot-notation
access to an absent hashtable key throws `PropertyNotFoundException`
rather than returning `$null`. This reproduced only when the full
`tests/Pester/Unit` suite ran together (some earlier test file's
`Set-StrictMode -Version 3` call was leaking into this file's scope), not
in isolation — the same symptom seen in slice 2's array-unrolling bug.
Fixed by always returning a fully-keyed hashtable with every field
defaulted (`$null` / `@()`), regardless of which branch is taken.

## Checklist

- [x] `WorkflowFailureIssues.ps1` library (workflow/run discovery, open
      issue discovery, module-vs-platform classification, side-effect-free
      routing decision, apply function).
- [x] `Invoke-AvmWorkflowFailureIssues.ps1` entry point.
- [x] `.github/workflows/repository-management-workflow-failure-issues.yml`.
- [x] 15 Pester tests, including a workflow-safety guard context.
- [x] `./build.ps1 pre-commit` green (0 errors), including at full-suite
      scale (where the `Set-StrictMode` bug above only reproduced).

## Open items (carried over / new)

- Same open items as slices 1-2: `workflow_dispatch whatIf:true` live dry
  run blocked until these workflows reach `main`, followed by a trigger-only
  pull request restoring all four schedules; AVM GitHub App
  `Issues: write`/`Actions: read` on `bicep-registry-modules` not verified
  from this session; `Add-RepositoryItemsToProject.ps1` wiring deferred.
- The label/comment text still references `Type: AVM`, `Type: Bug`,
  `Type: Duplicate` labels exactly as the original did; not verified that
  these labels still exist with these exact names in
  `bicep-registry-modules` (they predate this port and are outside its
  scope to create/rename).
