# Repository-management run logs

Status: complete
Started: 2026-09-23
Updated: 2026-09-23
Branch: jaredfholgate-workflow-naming-consistency

## Outcome

The Bicep repository-management sweeps logged the raw `gh` commands but not
the decisions behind them. For example,
[run 35892094794](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35892094794/job/107286800080)
requested four reviewers without saying which module each one owned. Each sweep
now logs its reasoning, ends with a summary, and writes the same summary to the
GitHub Actions job summary. Dry runs (`what_if`) write the summary too and are
labelled as dry runs.

- **PR Routing** lists each changed module with its owners, where they came
  from (catalog or the pull request's `metadata.json`), orphaned modules, files
  that need the core team, each requested reviewer with the modules they own,
  owners not requested with the reason, and the labels added. The per-module
  orphan warnings become one warning per pull request.
- **Issue Routing** logs the module, its owners, who is assigned or unassigned
  and why, labels, and whether the owner comment is posted.
- **Workflow Failures** logs each issue it creates (with the assignee and who
  is notified), comments on, or closes, and counts workflows without a
  completed run.
- **Module List Sync** lists the modules added to and removed from the
  dropdown, and the pull request status. Its log lines drop the `[AVM]` prefix.

The shared log and job summary helpers are in
`repository-management/reviewer-routing/scripts/lib/RunSummary.ps1`. Routing
decisions and write conditions are unchanged; the per-item functions now return
an outcome record that the summary uses.

## Checklist

- [x] Return the routing reasoning from the `Resolve-*` functions without changing decisions.
- [x] Log per-item plans and return per-item outcomes.
- [x] Write log and job summaries, including for WhatIf runs.
- [x] Add unit tests for the reasoning, logs, outcomes and job summaries.
- [x] Confirm the new tests fail when the reviewer-to-module mapping is broken.

## Validation

`./build.ps1 pre-commit` passes. The focused repository-management suites
(`RunSummary`, `ReviewerRouting`, `IssueOwnerRouting`, `WorkflowFailureIssues`,
`ModuleListSync`, `TerraformOperations`) pass 188 tests, 33 of them new.
