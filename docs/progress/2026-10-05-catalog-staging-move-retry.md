# Catalog staging-directory move prerequisite

**Status**: blocked
**Started**: 2026-10-05
**Updated**: 2026-10-05
**Branch**: `jaredfholgate-bicep-workflow-templates`

## Outcome

Unblock the ordinary local gate for the Bicep workflow migration without
changing the gate or Windows security settings. Two full runs failed at
`Write-AvmCatalogBundle`'s staging-directory rename, with the same
access-denied `IOException` in different catalog cases. The locking process
was not identified.

Apply only the matching bounded move helper and three catalog regression
cases from coordinator-identified prior art
`4c087e2238599ac2de6edd51f309b82e9eb68063`. No mixed commit is cherry-picked
and no other refactor code is copied. Retry only while the source directory
exists and the destination is absent; preserve the existing output contract
and fail after the bounded attempts.

## Checklist

- [x] Compare the exact operation, exception and path with the prior art.
- [x] Apply only the catalog helper, call-site replacement and regression cases.
- [x] Pass targeted component cases and the complete ordinary local gate.
- [x] Commit the narrow prerequisite separately from workflow orchestration.
- [ ] Publish after the coordinator's workflow-scope authorization resolution.

## Validation

Focused supported component selectors passed all three move regressions and
the prior deprecation/output failure case (4 passed). Both modified catalog
files have exactly the same Git blob hashes as the identified prior art.
The complete `.\build.ps1 pre-commit` passed layout, lint, 2,938 unit tests
(9 skipped) and 1,548 component tests (1 skipped), with zero failures.

The added cases use local temporary directories and controlled file handles.
No OS/security changes, test exclusions or cloud operations are involved.

## Blockers or dependencies

This is a prerequisite of
[`2026-10-05-bicep-workflow-templates.md`](2026-10-05-bicep-workflow-templates.md).
The coordinator explicitly confirmed that publication authorization was not
granted. Keep all qualified commits local; do not selectively push this
prerequisite around the workflow-file hold. Hosted review-triggered CI remains
on hold too.

The two catalog files exactly match the existing refactor source blobs.
During later normal integration, retain the single helper and single
regression context rather than reapplying them or creating a second copy.
The separately recorded provenance is not a request to cherry-pick the mixed
refactor commit.
