# Metadata-driven PR reviewer routing (Bicep)

Status: in-progress
Branch: jaredfholgate-avm-reviewer-issue-routing

## Outcome

First slice of the metadata-driven AVM reviewer/issue routing effort. Ports
`Set-AvmGitHubPrLabels`/`Set-AvmGitHubPrLabelsForPr` from the retired
`bicep-registry-modules` platform tooling (git history commit `2eb210dbb`,
removed in `Azure/bicep-registry-modules#7378`) into this repository, adapted
to run cross-repo against the published module catalog
(`docs/static/module-indexes/v1/modules.json` in `Azure/Azure-Verified-Modules`)
with a `metadata.json` fallback, instead of reading a local checkout.

Because `avm-module-metadata.schema.json` forbids an `owners` property on
child module metadata (only the top-level module `metadata.json` may declare
it), the original script's "walk up parent folders" search is provably
unnecessary here and was simplified to a single direct read at the top-level
(4-segment) module path.

Owner resolution accepts both the current bare-string `owners` shape in
`metadata.json` and the enriched `{handle, type, displayName}` object shape
already shipped in the published catalog, converging both on the same bare
`org/team-slug` team-handle format that `gh pr edit --add-reviewer` expects
(the catalog keeps a leading `@`; `metadata.json` team handles do too).

## Checklist

- [x] `repository-management/reviewer-routing/scripts/lib/RepositoryFileAccess.ps1`
      -- generic, integrity-verified (blob-SHA + size check), 404-tolerant
      single-file GitHub contents-API reader (`Get-AvmRepositoryFileAtRef`).
- [x] `repository-management/reviewer-routing/scripts/lib/ModuleOwners.ps1`
      -- owner resolution: `Get-AvmBicepTopLevelModulePath`,
      `ConvertTo-AvmReviewerRoutingOwner` (catalog shape),
      `ConvertTo-AvmReviewerRoutingMetadataOwner` (metadata.json shape),
      `Get-AvmReviewerRoutingCatalogIndex`, `Get-AvmBicepModuleMetadataOwners`,
      `Get-AvmModuleOwners` (index-first, metadata.json fallback,
      `-ForceMetadataLookup` for modules whose metadata.json the pull request
      itself edits, or that are absent from the catalog index).
- [x] `repository-management/reviewer-routing/scripts/lib/PrReviewerRouting.ps1`
      -- faithful port of the original label/reviewer computation
      (`Resolve-AvmPrReviewerRouting`, kept side-effect free and unit
      testable) and its application (`Set-AvmPrReviewerRoutingForPullRequest`,
      conditional `gh pr edit` -- only writes when labels/reviewers actually
      differ, to avoid bumping `updatedAt` and permanently re-trapping the
      pull request in the scheduled lookback window), plus the top-level
      sweep (`Invoke-AvmPrReviewerRouting`, one failing pull request does not
      abort the run).
- [x] `repository-management/reviewer-routing/scripts/Invoke-AvmPrReviewerRouting.ps1`
      entry point.
- [x] `.github/workflows/repository-management-pr-reviewer-routing.yml` --
      `schedule` (offset crons `7,22,37,52 * * * *` plus a daily `13 3 * * *`
      full-sweep backstop) + `workflow_dispatch` only, cross-repo
      `create-github-app-token` scoped to `bicep-registry-modules`
      (`pull-requests: write`, `members: read`), `environment: avm` gate.
- [x] `tests/Pester/Unit/RepositoryManagement/ReviewerRouting.Tests.ps1` (27
      tests): owner-path reduction, both owner normalizers, catalog-index /
      metadata.json fallback / forced-refresh resolution, routing computation
      (owned, orphaned, out-of-module, author/reviewer/review skip,
      idempotent no-op, forced metadata re-read on metadata.json edits),
      draft-skip and conditional-write application, and a
      `'Reviewer routing workflow safety'` guard context asserting the
      workflow is schedule/`workflow_dispatch`-only (never
      `pull_request`/`pull_request_target`), uses offset (not round-minute)
      cron fields, and never interpolates `${{ }}` directly into a `run:`
      body.
- [x] Fixed a real bug found while porting: PowerShell unrolls a
      single-element array every time it crosses a function-call boundary
      via the output stream, regardless of comma-wrapping at the return
      site. The fix (matching this repo's existing convention, e.g.
      `Invoke-RepositoryGitHubApi`/`RepoTree.ps1`) is for every *consuming*
      call site to wrap the callee's result in `@(...)`, not to change how
      the callee returns.
- [x] Fixed a second real bug: several GitHub API response fields
      (`previous_filename` on a changed-file entry, `login`/`slug`/`name` on
      a review request, `author`/`name` on a review or label) are optional
      and absent from some payload shapes. Regular `ConvertFrom-Json`
      produces `PSCustomObject`s, so referencing an absent property throws
      `PropertyNotFoundException` once `Set-StrictMode -Version 3.0` is in
      effect (as the entry-point script sets, matching this repo's other
      entry points) -- not just a test artifact. Guarded every optional
      property access with the repo's existing
      `$obj.PSObject.Properties['name']` idiom (see
      `RepositoryFileSync.ps1`).
- [x] Ran `./build.ps1 pre-commit` (full suite, 1545+ unit tests, 0 failures).

## Follow-ups / open items still to confirm with Jared

- Whether the AVM GitHub App has org-level `Members: read` (needed to
  request team reviews) and `Issues: write` on `bicep-registry-modules` --
  not verified from this session; flagged rather than worked around.
- A `workflow_dispatch whatIf: true` dry run against live pull requests in
  `bicep-registry-modules` is still required before enabling the schedule.
- This is slice 1 of 4 (PR reviewer routing). Issue-owner routing,
  workflow-failure issue management, and module-dropdown sync are separate,
  not-yet-started slices tracked under the same branch.
