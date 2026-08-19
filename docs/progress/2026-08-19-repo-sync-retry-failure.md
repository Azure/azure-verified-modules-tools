# Repository sync retry failure propagation

**Status**: complete
**Started**: 2026-08-19
**Updated**: 2026-08-19
**Branch**: `jaredfholgate-fix-repo-sync-failures`

## Outcome

Make an exhausted Terraform plan/apply retry fail the repository sync job, cap
generated GitHub repository descriptions at 350 characters, and correct the
overlong Commercial Marketplace metadata entry.

## Checklist

- [x] Correct mixed retry result handling.
- [x] Add regression coverage for a later command failure.
- [x] Cap generated repository descriptions at GitHub's limit.
- [x] Shorten the overlong metadata display name.
- [x] Complete the repository validation gate.
- [x] Commit, push, and open the pull request.

## Validation

- Confirmed run `32254610860`, job `96073633364` returned a successful
  re-plan result followed by a failed apply result; PowerShell treated the
  resulting non-empty `success` array as truthy.
- The corrected Commercial Marketplace repository description is 98 characters,
  below GitHub's 350-character limit.
- `./build.ps1 pre-commit` passed: layout and lint completed, 981 unit tests
  passed with 8 skipped, and 28 component tests passed.

## Blockers or dependencies

None.
