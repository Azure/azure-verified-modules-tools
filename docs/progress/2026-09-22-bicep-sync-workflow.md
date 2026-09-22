# Bicep sync workflow

**Status**: complete
**Started**: 2026-09-22
**Updated**: 2026-09-22
**Branch**: `jaredfholgate-fix-bicep-sync-workflow`

## Outcome

Repair the Repository Management - Bicep Sync workflow by keeping its diff, pull request, and merge publication path aligned with the shared repository sync publisher used by the other repository-management workflows.

## Checklist

- [x] Diagnose the current workflow failure.
- [x] Reuse the standard shared publisher branch and pull request behavior.
- [x] Add or update regression coverage for the workflow contract.
- [x] Run the focused validation.
- [x] Commit, push, and open the pull request.

## Validation

- `./build.ps1 test-repository-management`
- `./build.ps1 component -TestName 'Existing repository-sync publication core*'`
- `./build.ps1 pre-commit` (succeeded with the known transient PSScriptAnalyzer retry warnings)

## Notes

The latest scheduled run fails while verifying the retained stable CODEOWNERS candidate because the open pull request reports changes outside `.github/CODEOWNERS` even though the current branch-to-main comparison is scoped to CODEOWNERS.

The fix keeps Bicep CODEOWNERS on `Invoke-RepositoryFileSync` but removes the retained stable branch options. New apply runs use the standard timestamped branch, PR create, exact-head app merge, and branch deletion flow used by the shared publisher.

Pull request: https://github.com/Azure/azure-verified-modules-tools/pull/168
