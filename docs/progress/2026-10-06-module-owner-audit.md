# Module owner audit

**Status**: complete
**Started**: 2026-10-06
**Updated**: 2026-10-06
**Branch**: `jtracey93-module-owner-audit`

## Outcome

Add an operator-run audit under `repository-management/module-owner-audit`. It
checks every AVM root module owner in the published catalog against `Azure`
organization membership, which is the Microsoft FTE signal, and against
membership of the AVM module contributors team. It reports, in priority order:

- modules that would be orphaned
- orphaned modules missing an orphaned module issue
- owner reductions
- orphan issues that can be closed or need review
- active owners who must join the access package

It also reconciles open orphaned module issues. The report shows a matrix by
language and module type, and writes module and owner CSVs. `-Ecosystem`,
`-ModuleType` and `-ModuleFilter` narrow the scope.

`-Apply` is opt-in and gated by confirmation. It edits only the root
`owners` array, validated with `Test-AvmModuleMetadata`. It opens one batch PR
in `Azure/bicep-registry-modules` and one PR per Terraform repository. It
raises or reuses orphaned module issues and adds them to projects 529 and
1011. With `-CloseResolvedIssues` it closes orphan issues for modules that
are owned again.

This tool was first prototyped in Azure/Azure-Verified-Modules. It now lives
here and reuses the shared catalog reader, file reader and GitHub CLI retry
helpers. Promoting it to an `avm governance` verb belongs to Phase 5 of the
consolidation plan and is out of scope for this slice.

## Checklist

- [x] Read repository instructions and active or blocked slices.
- [x] Reuse `Get-AvmReviewerRoutingCatalog`, `Get-AvmRepositoryFileAtRef` and `Invoke-GitHubCliWithRetry` instead of private HTTP and retry code.
- [x] Make the entry script and lib StrictMode 3.0 compatible, with LF line endings and UTF-8 without a BOM.
- [x] Add unit tests under `tests/Pester/Unit/RepositoryManagement`.
- [x] Document usage, verdicts and apply behaviour.
- [x] Run a live read-only dry run.

## Validation

- `tests/Pester/Unit/RepositoryManagement/ModuleOwnerAudit.Tests.ps1`: 55 passed, 0 failed.
  The tests cover classification, issue matching, filters, report grouping, metadata text editing,
  issue and PR bodies, CSV export, the `gh` adapter, and the mocked apply flow, including
  `-WhatIf`, `-MaxChanges`, open-PR skipping and sandbox overrides.
- Live dry run against the published catalog, with the `src` build of Avm.Authoring: 485 root
  modules and 152 owners. Verdicts: 28 WouldOrphan, 12 OwnerReduction, 35 NeedsTeamJoin. No writes.
- Live read-only check of the root `metadata.json` read, owners edit and `Test-AvmModuleMetadata`
  validation for one Bicep and one Terraform module.
- `-Apply` has not been run against real repositories. The first real apply should use `-ModuleFilter`
  and `-MaxChanges 1`, after operator review of the dry-run report.
