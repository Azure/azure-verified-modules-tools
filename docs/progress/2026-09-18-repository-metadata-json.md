# Repository metadata JSON lookup

**Status**: complete
**Started**: 2026-09-18
**Updated**: 2026-09-18
**Branch**: `jaredfholgate-metadata-json-migration`

## Outcome

Repository discovery reads and validates each selected repository's root
`metadata.json` on its default branch. GitHub supplies archive state; the full
owner list, including owning teams, supplies the existing JIT-admin exemption.
Missing metadata warns and suppresses collaborator cleanup during rollout;
invalid metadata or API failures exclude the repository with an error.

The tools-local CSV and inventory publisher are removed. New repositories
initialize metadata from explicit inputs before their first commit, temporarily
change only `rulesets-default-opt-in` for the initial push, and verify restoration
of its original value. Failures retain a recovery record and staged content.
The user chose to retire the obsolete CSV-only creation modes and display-name
parameters rather than repurpose them for existing repositories.

Generated public CSV indexes remain unchanged. Optional full-sync backfill still
supports roots and children using canonical public CSVs, without the deleted
tools-local fallback.

## Checklist

- [x] Trace metadata consumers, repository creation, and ruleset properties.
- [x] Replace CSV discovery and remove obsolete inventory publication.
- [x] Cover metadata initialization and ruleset restoration on failure.
- [x] Update repository guidance and the relevant aka.ms/avm documentation.
- [x] Run the local gate and prepare the feature changes for review.

## Validation

- `.\build.ps1 pre-commit`: 1,635 unit tests passed, 8 skipped; 696 component
  tests passed, 1 skipped; zero errors. Existing analyzer warnings remain.
- `.\build.ps1 component -TestName 'Component: repository creation*'`:
  64 passed. Coverage includes plan/WhatIf, host isolation, property snapshots,
  null reset, readback failures, ambiguous opt-out failure, failed push, and
  restoration failure after a successful push.
- Changed files pass whitespace, LF, and UTF-8-without-BOM checks.
- Public documentation updates are pushed in
  [Azure/Azure-Verified-Modules#2936](https://github.com/Azure/Azure-Verified-Modules/pull/2936)
  at `86b57a673565e5f454602fa11a5183b29273931f`. The three affected pages cover
  repository setup, advanced Terraform workflow, and module metadata.
  Local Hugo/Markdown checks and all seven hosted documentation checks passed;
  the existing draft's adoption gates remain unchecked.

No production repository creation, fleet-sync execution, or custom-property
writes were performed.

## Blockers or dependencies

The temporary initial-push exception needs maintainer/SFI approval and an
operator-approved canary before production adoption. Organization-wide rule
and property-schema reads were unavailable to the current GitHub token; this
change does not claim live policy or permission verification.

Existing CSV-only registrations
[#116](https://github.com/Azure/azure-verified-modules-tools/pull/116) and
[#117](https://github.com/Azure/azure-verified-modules-tools/pull/117) require
separate owner disposition; neither was changed or closed. The corresponding
[internal runbook](https://msft.ghe.com/azure-cloud-native/Azure-Verified-Modules-Docs)
should also be aligned.
