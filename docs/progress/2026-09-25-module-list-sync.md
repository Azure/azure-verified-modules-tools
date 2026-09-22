---
status: complete
---

# Module dropdown auto-sync (slice 4 of 4)

## Context

Final slice of porting the metadata-driven AVM PR/issue routing tooling
that `Azure/bicep-registry-modules#7378` removes from that repository (see
`docs/progress/2026-09-22-pr-reviewer-routing.md`,
`docs/progress/2026-09-23-issue-owner-routing.md`, and
`docs/progress/2026-09-24-workflow-failure-issues.md` for slices 1-3).
This slice ports `Sync-AvmModulesList.ps1` /
`platform.sync-avm-modules-list.yml`, recovered from
`Azure/bicep-registry-modules` git history at commit `2eb210dbb`.

The original keeps the `module` dropdown in
`.github/ISSUE_TEMPLATE/avm_module_issue.yml` in sync with the modules
that actually exist, so users filing a module issue can only pick a real,
published module. It walks the local module tree, builds the sorted list
of `ptn`/`res`/`utl` module paths, diffs that against the dropdown's
current active (non-commented) entries per category, and opens a PR when
they differ.

## What changed for this port

- Runs cross-repo against `Azure/bicep-registry-modules` from this repo's
  scheduled workflow, instead of walking a local checkout inside that
  repository.
- Module path data comes from the published catalog index
  (`Get-AvmReviewerRoutingCatalogIndex`, the same helper slices 1-2 use)
  filtered to `moduleStatus -eq 'Available'`, instead of a
  `Get-ChildItem -Recurse` walk of `metadata.json` files. The catalog's
  ~4 hour regeneration lag is immaterial here: an unpublished-yet module
  simply doesn't get a dropdown entry until the catalog catches up, and
  the dropdown is not on any owner-routing critical path the way slice 1's
  new-module case is.
- New shared library
  `repository-management/module-list-sync/scripts/lib/ModuleListSync.ps1`,
  entry point `Invoke-AvmModuleListSync.ps1`, and workflow
  `.github/workflows/repository-management-module-list-sync.yml`
  (`schedule` + `workflow_dispatch` only, daily — there is no reason for
  this sweep to run more than once a day).
- Opens (or updates) the sync PR through the existing
  `Invoke-RepositoryFileSync` engine (`repository-management/repository-sync`)
  rather than a bespoke PR-creation path, using its `-ReviewOnly
  -VerifyCandidate -ExpectedActor -StableBranch` combination so the PR:
  - is verified to have actually been opened by the AVM bot app
    (`azure-verified-modules[bot]`, id `1049636`) before being trusted,
  - reuses a single stable branch (`avm-bot/sync-module-dropdown`) across
    runs instead of opening a new PR every day, and
  - is never auto-merged — a human always reviews the dropdown diff.
    This is the first real caller of that hardened parameter combination
    in this repo; every existing caller only uses the simpler
    `PlanOnly`/`GeneratedFiles` mode (a guard test in
    `Test-RepositorySyncInputs.ps1` explicitly asserts the Terraform
    pre-commit auto-fix path does *not* use `ExpectedActor`/
    `VerifyCandidate`/`ReviewOnly`/`StableBranch`), so this path is unit
    tested at the engine level but not yet exercised in a live cross-repo
    scenario.

## Scope reductions from the original

- Interleaved position of commented-out (`# "avm/..."`) hidden-module
  lines within a category is not preserved exactly; they are re-appended
  after the regenerated active-line block for their category instead.
  The original's own diff logic already ignores commented lines entirely
  for comparison purposes, and a human reviews the resulting PR, so exact
  interleave position is not load-bearing.

## Bugs found while building this slice

- `Sort-Object -Culture 'invariant'` is not a valid `.NET` culture name
  and throws `CultureNotFoundException`; removed the `-Culture` argument
  entirely since module paths are lowercase ASCII kebab-case and ordinal
  sort is sufficient.
- The regex that locates the dropdown block's commented-out lines uses an
  optional named capture group. When that group doesn't match, PowerShell
  omits the key from `$Matches` entirely rather than setting it to `$null`
  — dot-notation access (`$Matches.comment`) then throws
  `PropertyNotFoundException` under `Set-StrictMode -Version 3`, the same
  class of bug found while building slice 3. Fixed by switching every
  `$Matches.xxx` access in `ModuleListSync.ps1` to bracket notation
  (`$Matches['xxx']`).
- `New-AvmModuleListSyncPullRequestBody`'s `[string[]]` parameters
  rejected an explicit empty array (`-Added @()`) with a
  `ParameterBindingValidationException`; fixed by adding
  `[AllowEmptyCollection()]`.

## Checklist

- [x] `ModuleListSync.ps1` library (catalog module-path grouping, dropdown
      block parse/diff/regenerate, PR body rendering, orchestrator).
- [x] `Invoke-AvmModuleListSync.ps1` entry point (`SupportsShouldProcess`,
      forwards `-WhatIf` to `Invoke-RepositoryFileSync`).
- [x] `.github/workflows/repository-management-module-list-sync.yml`.
- [x] 14 Pester tests, including a workflow-safety guard context.
- [x] `./build.ps1 pre-commit` green (0 errors) at full-suite scale
      (1598 unit tests passed, 903 component tests passed / 1 skipped).

## Open items (carried over / new)

- Same `workflow_dispatch whatIf:true` live-dry-run and AVM GitHub App
  permission-verification open items as slices 1-3
  (`Contents: write`/`Pull requests: write` needed here, in addition to
  the `Members: read`/`Issues: write` needed by slices 1-3).
- This slice is the first real exerciser of `Invoke-RepositoryFileSync`'s
  `ExpectedActor`/`VerifyCandidate`/`StableBranch`/`ReviewOnly` path
  against a live repository; the recommended `whatIf:true` dry run should
  specifically confirm the actor-identity and single-repo-token checks
  behave as expected before the schedule is enabled.
