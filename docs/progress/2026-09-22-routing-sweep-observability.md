# Routing sweep observability hardening

Status: complete
Branch: jaredfholgate-routing-sweep-observability

## Incident

A live `workflow_dispatch whatIf=true` dry run of pr-reviewer-routing
(run [35769732529](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35769732529))
processed 44 pull requests, produced 39 correct routing decisions, then died
with **zero diagnostic output** partway through PR 6484:

```
2026-09-22T18:50:24.0291955Z Running gh with arguments: api --paginate repos/Azure/bicep-registry-modules/pulls/6484/files?per_page=100 --hostname github.com
2026-09-22T18:50:24.6996897Z ##[error]Process completed with exit code 1.
```

No exception message, no stack trace, no `Write-Warning`, nothing --
despite `Invoke-AvmPrReviewerRouting` already wrapping each pull request's
processing in a `try { ... } catch { ...; Write-Warning ... }`. A normal
.NET/PowerShell exception thrown anywhere in that call path would have been
caught and printed by that handler.

## Investigation

The leading hypothesis was that `Get-AvmModuleOwners`/`Get-AvmRepositoryFileAtRef`
hit a 404 fetching `metadata.json` for a stale fork. This was investigated and
ruled out:

- PR 6484 only touches `avm/ptn/lz/sub-vending/modules/subResourceWrapper.bicep`,
  never `metadata.json`.
- `avm/ptn/lz/sub-vending` **is** present in the published catalog index with
  2 real owners.
- Under the index-first design in `ModuleOwners.ps1`, `ForceMetadataLookup` is
  only set when the pull request itself touches that module's
  `metadata.json` -- which PR 6484 does not -- so no `metadata.json` fetch is
  attempted for this module at all.
- Replaying the entire real sweep locally against live GitHub data with
  `-WhatIf` (dot-sourcing the exact library code: `RetryHelpers.ps1`,
  `RepoTree.ps1`, `RepositoryFileAccess.ps1`, `ModuleOwners.ps1`,
  `PrReviewerRouting.ps1`), including PR 6484 specifically, completed
  end-to-end with zero errors; PR 6484 evaluated cleanly as "already routed,
  skipping" (a no-op).

The actual cause was confirmed through three further live dispatches:

1. A second full sweep reproduced the same failure byte-for-byte.
2. Dispatching PR 6484 alone reproduced it.
3. Dispatching control PR 6883 logged a successful routing decision and then
   failed with the same exit code 1, with no later `gh` call.

Each work step set `GH_TOKEN`, then ran `gh auth login -h 'GitHub.com'`.
GitHub CLI refuses to store credentials while `GH_TOKEN` is set, prints that
the environment variable is already being used, and exits 1. All later `gh`
calls go through `Invoke-AvmProcess`, which starts
`[System.Diagnostics.Process]` directly. Those calls do not update
PowerShell's `$LASTEXITCODE`, so it remained 1 from `gh auth login` even after
the sweep completed successfully. GitHub Actions' `pwsh` wrapper then exited
with that stale value.

**Conclusion**: this was a deterministic `$LASTEXITCODE` poisoning bug, not a
runner crash and not a PR-specific library defect. No special case was added
for PR 6484 or its module.

## Root-cause fix

All four workflow work steps now:

1. rely directly on the already-set `GH_TOKEN` and do not run the redundant,
   failing `gh auth login`;
2. set `$global:LASTEXITCODE = 0` as the final line after a successful
   entry-point invocation, preventing an otherwise tolerated native command
   status from silently failing the step.

An exception from the entry point still terminates the block before the reset,
so real routing failures continue to fail the workflow.

## Real gap: observability

Regardless of the root cause of this particular run, the architecture had a
real gap: only failures *inside* the per-item `try/catch` were diagnosed, and
even that relied on `Write-Warning` alone with no per-item "start" marker
independent of the `gh` argument echo. There was no safety net around the
pre-loop setup calls (fetching candidates, fetching the catalog index) or
around the entry-point script's invocation of the sweep function.

## Hardening applied (identical across all four routing sweeps)

- `repository-management/reviewer-routing/scripts/lib/PrReviewerRouting.ps1`
  (`Invoke-AvmPrReviewerRouting`)
- `repository-management/reviewer-routing/scripts/lib/IssueOwnerRouting.ps1`
  (`Invoke-AvmIssueOwnerRouting`)
- `repository-management/workflow-failure-issues/scripts/lib/WorkflowFailureIssues.ps1`
  (`Invoke-AvmWorkflowFailureIssues`)
- `repository-management/module-list-sync/scripts/lib/ModuleListSync.ps1`
  (`Invoke-AvmModuleListSync`)
- Their four entry-point `.ps1` scripts.

1. **Per-item progress marker.** `PrReviewerRouting`, `IssueOwnerRouting`, and
   `WorkflowFailureIssues` each print an unconditional
   `Write-Verbose "[$index/$total] Routing/Checking ... [$url]" -Verbose`
   inside their `foreach` loop, before any network call for that item, so a
   run that dies without an exception still leaves an unambiguous last-seen
   item in the log. `ModuleListSync` has no per-item loop (it is a single
   repo-level file sync), so it gets an equivalent single
   `"[1/1] Syncing module dropdown for [...]"` marker before its setup.
   The existing per-item `try/catch` + `Write-Warning` + `$failures`
   accumulation is unchanged.
2. **Defense-in-depth around pre-loop/pre-sync setup.** The "fetch
   candidates"/"fetch workflows" call plus `Get-AvmReviewerRoutingCatalogIndex`
   (or, for `ModuleListSync`, its whole single-item fetch/diff pipeline) is
   now wrapped in a `try/catch` that on failure writes the full exception
   detail via `Write-Host` (`$_.Exception.GetType().FullName`,
   `$_.Exception.Message`, `$_.ScriptStackTrace`) and then re-throws the
   original exception unchanged.
3. **Top-level entry-point safety net.** Each of the four entry-point
   `.ps1` scripts now wraps its final call to `Invoke-Avm*` in a
   `try/catch` that on any exception writes a `"FATAL: <type>: <message>"`
   `Write-Host` banner plus `$_.ScriptStackTrace`, then `throw`s so the
   workflow step still fails with a non-zero exit code exactly as before.
   `$ErrorActionPreference = 'Stop'` and `Set-StrictMode -Version 3.0` are
   unchanged.

No routing logic, labels, reviewers, or write conditions changed -- this is
an execution-wrapper fix plus additive diagnostics.

## Separate pre-existing production issue (not fixed here)

The same `GH_TOKEN` + `gh auth login` + `Invoke-AvmProcess` pattern also exists
in `.github/workflows/repository-management-sync.yml`. Its last five scheduled
runs on `main` were all failures, including run
[35729368568](https://github.com/Azure/azure-verified-modules-tools/actions/runs/35729368568),
where a repository matrix job reported `found: 0, added: 0, failed: 0` and then
failed from the poisoned exit code. That already-scheduled production workflow
needs a separate follow-up fix. This slice deliberately does not modify
`repository-management-sync.yml` or `terraform-module.yml`.

## Checklist

- [x] Per-item progress markers added to `PrReviewerRouting.ps1`,
      `IssueOwnerRouting.ps1`, `WorkflowFailureIssues.ps1`; equivalent
      single-item marker added to `ModuleListSync.ps1`.
- [x] Pre-loop/pre-sync setup wrapped in diagnostic `try/catch` + rethrow in
      all four library files.
- [x] Entry-point `FATAL:` safety net added to all four `.ps1` scripts.
- [x] Removed redundant `gh auth login` from all four workflow work steps and
      reset `$global:LASTEXITCODE = 0` after successful entry-point execution.
- [x] Added workflow-safety regression guards asserting the work block has no
      `gh auth login` and ends with the exit-code reset after the entry point.
- [x] Pester coverage added for all four areas: progress-marker emission
      (`-Verbose 4>&1`), pre-loop/pre-sync setup failure diagnostics
      (`Write-Host` output contains exception type/message, function still
      throws), and entry-point script structure (regex-verified `try`/`catch`/
      `FATAL:`/`throw` shape, following this repo's existing convention of
      structurally testing script/workflow text rather than executing
      self-sourcing entry-point scripts end-to-end).
- [x] All pre-existing tests (idempotency, per-item `try/catch`,
      workflow-safety guards) remain green and unmodified in behaviour.

## Validation

- Targeted Pester run (`ReviewerRouting.Tests.ps1`, `IssueOwnerRouting.Tests.ps1`,
  `WorkflowFailureIssues.Tests.ps1`, `ModuleListSync.Tests.ps1`):
  **114 passed, 0 failed, 0 skipped**.
- `./build.ps1 pre-commit` (layout + lint + test + component):
  - layout: OK
  - lint: OK (0 errors; the only warnings are pre-existing, unrelated to
    this change)
  - unit test: **1637 passed, 0 failed, 9 skipped**
  - component: **903 passed, 0 failed, 1 skipped**
  - Overall: build succeeded, 0 errors, 54 warnings (pre-existing, unrelated).
