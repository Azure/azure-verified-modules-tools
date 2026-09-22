# Preview HasChanges accuracy + module-list-sync auto-merge

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: jaredfholgate-preview-haschanges-module-sync-automerge

## Context

Two Jared-approved, independent changes to the shared repository-sync engine
and the module-list-sync caller, branched fresh from `main` (not touching the
already-merged #176/#177 branches).

## Scope

1. `Invoke-RepositoryFileSync`'s `-WhatIf` preview short-circuit always
   returned `HasChanges = $false`, regardless of what the caller's own
   pre-check already found. Added `[switch] $PlanHasChanges`; the preview
   branch now sets `$result.HasChanges = $PlanHasChanges.IsPresent` while
   leaving `Status = 'Preview'` and the real post-clone
   `git status --porcelain`-derived `HasChanges` computation untouched.
2. `ModuleListSync.ps1`'s dropdown-sync call previously passed `-ReviewOnly`,
   so it always stopped at `Status = 'ReviewRequired'` and never merged.
   Removed `-ReviewOnly` so it falls through to the existing squash-merge
   path already used by the terraform pre-commit flow.

## Confirmations (required by task)

- **Terraform/`-PlanOnly` caller unaffected**: `AvmPreCommit.ps1` calls
  `Invoke-RepositoryFileSync -PlanOnly:$planOnly ...` with no `-WhatIf`
  argument. `$WhatIfPreference` is not set in that scope, so
  `$PSCmdlet.ShouldProcess(...)` evaluates true and the function never
  enters the changed preview branch; it always clones, prepares, and
  computes `HasChanges` from `git status --porcelain` at the existing line,
  then short-circuits separately at `if ($PlanOnly) { $result.Status =
  'Planned'; return $result }`, which is below (unaffected by) the preview
  branch. Confirmed by re-reading the function end-to-end.
- **Merge-path prerequisites already satisfied**: the merge path (from
  `if ($ReviewOnly) { ... }` removed, falling through to
  `if ($VerifyCandidate -and -not $repo.allow_squash_merge) { throw ... }`
  through `$result.Status = 'Merged'; return $result`) requires
  `$VerifyCandidate`/`$ExpectedActor` for its `Assert-RepositorySyncCandidate`
  / `Assert-RepositorySyncPullRequest` / `Assert-RepositorySyncActor` checks.
  `ModuleListSync.ps1`'s call already passes both
  (`-VerifyCandidate -ExpectedActor $expectedActor`), so no new parameters
  were required on that call site.
  - Status values this call site can now return: `'Merged'` (success),
    `'NoChange'` (no drift found before ever reaching the engine, handled by
    ModuleListSync's own early return), `'Preview'` (under `-WhatIf`), or an
    exception on any verification failure. It can no longer return
    `'ReviewRequired'`.
- The only other production/test use of `-ReviewOnly` together with a
  stable branch is
  `tests/Pester/Component/RepositoryFileSync.Component.Tests.ps1`'s
  `'avm-bot/bicep-metadata-backfill'` scenario, which is a synthetic,
  direct engine-level exercise of the `-ReviewOnly` switch itself (not a
  simulation of the module-list-sync caller). The switch is not being
  removed from the engine, only from this one call site, so that test was
  left unchanged.

## Risk note (carried into the PR body)

- No live (non-`-WhatIf`) module-list-sync run has happened yet; every run
  so far has been `what_if=true`.
- Target-repo ruleset (`Azure/bicep-registry-modules`, ruleset id
  `23285568`) config was independently verified by a reviewer: targets the
  default branch, includes the `Azure Verified Modules` app in its bypass
  list with mode "Allow for pull requests only", `allow_squash_merge=true`,
  `allowed_merge_methods=[squash]`. This is configuration evidence, not an
  observed successful merge — the first real run is the actual proof.
- `gh pr merge --admin` (same underlying call) is currently failing
  intermittently against three *different* repos in the pre-existing,
  unrelated `repository-management-sync.yml` workflow
  (microsoft/github-operations#1841), root-caused there to a recreated
  branch-protection rule on those specific repos — noted as context, not as
  evidence this change is unsafe.
- A `bypass_actors: null` result from `gh api repos/.../rulesets/23285568`
  (or similar) is a known API quirk on this ruleset and must not be treated
  as proof of missing bypass configuration.

## Checklist

- [x] Read `AGENTS.md`, `docs/progress.md`, `docs/avm-implementation-spec.md`,
      `docs/avm-consolidation-plan.md`, `docs/quality-standards.md`.
- [x] Add `[switch] $PlanHasChanges` to `Invoke-RepositoryFileSync`.
- [x] Wire `ModuleListSync.ps1`'s call with `-PlanHasChanges:$plan.Changed`.
- [x] Remove `-ReviewOnly` from that same call.
- [x] Update doc comments / PR body text / workflow header comment for the
      auto-merge behavior.
- [x] Add/adjust Pester coverage in `RepositoryFileSync.Tests.ps1` and
      `ModuleListSync.Tests.ps1`.
- [x] Targeted Pester green.
- [x] Full `./build.ps1 pre-commit` green.
- [x] Commit, push new branch off `main`, open draft PR.

## Validation

- Targeted: `./build.ps1 test -TestName '*RepositoryFileSync*','*ModuleListSync*'`
  — Tests Passed: 13, Failed: 0, Skipped: 0, Inconclusive: 0.
- Full: `./build.ps1 pre-commit` — layout OK; lint completed (0 errors; the
  known transient PSScriptAnalyzer `NullReferenceException` self-retried per
  `docs/quality-standards.md`, contributing to 55 warnings); unit tests
  Tests Passed: 1731, Failed: 0, Skipped: 9; component suites all passed
  (907 passed, 1 skipped, 0 failed across the six component test files).
  `Build succeeded with warnings. 5 tasks, 0 errors, 55 warnings.`

## Blockers / dependencies

None. Independent of merged PR #176/#177.
