---
status: complete
---

# Workflow failure issues: `gh api --paginate`/`--jq` pagination fix

## Context

Production dry-run validation of the workflow-failure-issues routing sweep
(part of the metadata-driven AVM PR/issue routing rollout in #171/#173/#174,
all merged to `main`) failed on run `35781059727`. A linked reviewer session
root-caused and empirically reproduced the bug against live GitHub data
before this fix was written.

## Symptom

`Get-AvmWorkflowFailureWorkflows` in
`repository-management/workflow-failure-issues/scripts/lib/WorkflowFailureIssues.ps1`
threw during the sweep:

```
Conversion from JSON failed with error: Additional text encountered after
finished reading JSON content: {
```

## Root cause

`gh api --paginate` behaves differently depending on the JSON shape of the
underlying endpoint response, and this code was calling `Invoke-RepositoryGitHub
-AsJson` (a single-document `ConvertFrom-Json` parse) against combinations
that are incompatible with that parse:

- **Object endpoint + `--paginate`**: `GET /repos/{repo}/actions/workflows`
  returns `{total_count, workflows: [...]}` per page. `--paginate` alone
  concatenates whole page objects back-to-back (`{...}{...}`), which is not
  valid JSON as a single document.
- **Streaming `--jq` filter**: a `--jq` expression that can emit multiple
  JSON values (`.workflows[] | select(...) | {id, name}`) or raw non-JSON
  text (`.[].body` against markdown comment bodies) is incompatible with a
  single-document parse regardless of the endpoint's page shape.

Two call sites in this file were affected. `Get-AvmWorkflowFailureIssueCommentsToday`'s
bug (a streaming `.[].body` `--jq` filter on an otherwise-safe array
endpoint) did not surface in the reviewer's dry run only because
`Get-AvmWorkflowFailureWorkflows` threw first and aborted the sweep before
that code path was reached; it would have thrown on the very next run once
the first bug was fixed.

## Fixes

1. **`Get-AvmWorkflowFailureWorkflows`** (object endpoint + streaming
   `--jq`): added `--slurp` (wraps pages into a JSON array of page-objects)
   and dropped `--jq`, projecting `.workflows` / filtering `state -eq
   'active'` / selecting `id, name` in PowerShell after parsing. Verified
   by the reviewer against live data as behaviour-preserving (237 active
   workflows, exact parity with what the broken call emitted per-line
   before it started throwing).
2. **`Get-AvmWorkflowFailureIssueCommentsToday`** (safe array endpoint,
   streaming `--jq`): kept `--paginate` (correct here — this endpoint is a
   top-level array) and dropped `--jq '.[].body'`, projecting `.body`
   client-side instead. Verified by the reviewer: 5 comments in, 5 bodies
   out.

## Explicitly not touched

- `repository-management/reviewer-routing/scripts/lib/PrReviewerRouting.ps1:74`,
  `IssueOwnerRouting.ps1:84`, and
  `repository-management/repository-sync/scripts/lib/TeamsAndUsers.ps1:185`
  — these `--paginate` calls are all against array endpoints and are
  correct as-is (the reviewer proved this empirically by forcing 40 pages
  against `pulls/7380/files?per_page=2` and confirming the merged result
  parses correctly with the right count).
- `Get-AvmWorkflowFailureLatestRun` (single-page, no `--paginate`, `--jq
  '.workflow_runs'` against an object endpoint) returns one JSON array with
  no pagination-concatenation risk; left unchanged per the reported scope.
- Any other file in the four routing/sync workflow slices.

## Checklist

- [x] `Get-AvmWorkflowFailureWorkflows` fixed: `--slurp` added, `--jq`
      dropped, client-side `.workflows` projection.
- [x] `Get-AvmWorkflowFailureIssueCommentsToday` fixed: `--jq` dropped,
      client-side `.body` projection; `--paginate` alone kept (endpoint is
      a safe top-level array).
- [x] Regression unit tests added to
      `tests/Pester/Unit/RepositoryManagement/WorkflowFailureIssues.Tests.ps1`
      asserting the exact `gh api` argument shape for both functions
      (`--slurp` present / `--jq` absent, and `--jq` absent respectively).
- [x] `./build.ps1 pre-commit` green.

## Validation

- Targeted: `tests/Pester/Unit/RepositoryManagement/WorkflowFailureIssues.Tests.ps1`
  — 25 passed, 0 failed, 0 skipped.
- Full gate: `./build.ps1 pre-commit` (layout + lint + test + component) —
  see PR description for the final counts recorded at push time.
