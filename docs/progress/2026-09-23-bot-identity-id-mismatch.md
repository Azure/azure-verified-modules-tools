# Bot identity ID mismatch

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-fix-bot-identity-id-mismatch`

## Outcome

Fix the production-safe module-list-sync failure caused by using the GitHub App
ID where GitHub API actor checks require the bot user account database ID. The
fix must not hard-code replacement bot identity values; it reads the expected
bot login and user database ID from GitHub Actions environment variables in the
existing `avm` environment.

## Checklist

- [x] Verified no existing open PR or similarly named remote branch covers this
      fix.
- [x] Verified `azure-verified-modules[bot]` has bot user database ID
      `187664033`.
- [x] Confirmed Terraform `github_avm_app_id` remains the distinct GitHub App
      ID `1049636` and must not change.
- [x] Wired `AVM_APP_BOT_LOGIN` and `AVM_APP_BOT_USER_ID` into the
      module-list-sync and Terraform repository-sync workflow run steps.
- [x] Replaced hard-coded module-list-sync expected actor construction with
      validated configured identity.
- [x] Replaced the reachable no-`ExpectedActor` git author fallback with
      validated configured identity.
- [x] Strengthened unit/component coverage for configured identity and invalid
      configuration.
- [x] Swept repository uses of `1049636` for other App-ID-vs-bot-user-ID
      mismatches.
- [x] Run targeted Pester tests.
- [x] Run `./build.ps1 pre-commit`.
- [x] Commit, push, and open a draft PR.

## Validation

- Targeted Pester:
  `Invoke-Pester -Path @('tests/Pester/Unit/RepositoryManagement/ModuleListSync.Tests.ps1','tests/Pester/Unit/RepositoryManagement/RepositoryFileSync.Tests.ps1','tests/Pester/Component/RepositoryFileSync.Component.Tests.ps1')`
  with strict error handling: 95 passed, 0 failed.
- Affected component rerun:
  `Invoke-Pester -Path @('tests/Pester/Component/RepositoryFileSync.Component.Tests.ps1','tests/Pester/Component/MetadataBackfill.RepositorySync.Tests.ps1')`
  with strict error handling: 59 passed, 0 failed.
- `./build.ps1 pre-commit`: succeeded with warnings.
  - Unit tests: 1,737 passed, 0 failed, 9 skipped.
  - Component test batches: 908 passed, 0 failed, 1 skipped.
  - Layout and lint completed successfully.

## Notes

- `AVM_APP_BOT_LOGIN` and `AVM_APP_BOT_USER_ID` are GitHub Actions environment
  variables, not secrets.
- `AVM_APP_CLIENT_ID` and `AVM_APP_PRIVATE_KEY` remain unchanged.
- No workflow dispatch, merge, or second live module-list-sync run is authorized
  by this slice.
