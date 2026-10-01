# Reviewer routing missing-label warnings

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-reviewer-label-warnings`

## Outcome

An exact GitHub CLI missing-requested-label error now produces a `MissingLabel`
outcome and warning rather than a failed request or repository sweep.
Newly installed repositories can be discovered before repository sync
provisions their standard labels. Deferred outcomes list their request URL,
missing label, and required sync in a separate job-summary warnings section;
they do not claim successful reviewer or label updates.

Other GitHub, permission, reviewer, unexpected-label, and compound errors
still propagate. Reviewer routing neither creates labels nor retries writes;
normal scheduled routing retries after provisioning.

## Checklist

- [x] Inspect the corrected run and confirm the prior change is merged.
- [x] Start a new app-managed feature worktree from current main.
- [x] Handle only the exact missing-requested-label error as a warning.
- [x] Cover deferred summaries, subsequent requests, dry runs, and real errors.
- [x] Update the existing operational documentation.
- [x] Run the focused pre-commit gate and prepare the slice for publication.

## Validation

`.\build.ps1 pre-commit -TestName ...` passed layout, lint, 214 unit tests,
and 114 shared-metadata component tests, with no failures or skips.
Selectors covered reviewer routing, issue routing, workflow-failure routing,
module-list synchronization, repository-file access, shared summaries, and
the shared metadata schema. All GitHub calls in the tests were mocked.

Regression coverage includes all three routing labels, a newline-terminated
CLI error, continued request and repository processing, warning-only job
summaries, successful routing after provisioning, and write-free `WhatIf`.
Unrelated missing handles, permission failures, GraphQL failures, unexpected
labels, and mixed errors remain fatal.

The first focused run exposed an inherited mock in a nested test context.
Moving that context to its independent top-level scope fixed the fixture;
the final gate passed without loosening assertions.

`git diff --check` passed. No workflow, token, label catalog, repository-sync,
or tenant configuration was changed.

## Blockers or dependencies

The user confirmed that the affected repository's app installation preceded
its first repository sync. Inspection found only GitHub's nine default labels
on the repository, consistent with the missing standard-label prerequisite.
The affected request was
[Azure/terraform-azure-avm-res-signalrservice-webpubsub#2](https://github.com/Azure/terraform-azure-avm-res-signalrservice-webpubsub/pull/2),
not the initially supplied AVD workflow link.

The [corrected routing run](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36880981310/job/110432717909)
also contained three separate GraphQL errors, which remain outside this
warning-only change and would still fail a run.
No live labels, reviewer requests, or workflow dispatches were performed.
Team documentation should record the warning-only onboarding case.
