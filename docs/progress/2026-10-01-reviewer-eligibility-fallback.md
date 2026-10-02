# Reviewer eligibility and owners-group fallback

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-reviewer-eligibility-fallback`

## Outcome

Reviewer routing now reads effective user or team repository permissions
before requesting owners and caches the results per repository for the run.
Ineligible owners are replaced by the existing AVM module-owners group.
That group also reviews modules whose sole owner is the request author.
Eligible co-owners are preserved; fallback requests are deduplicated with
their exact changed-module mappings.

Ineligible owners produce warning records and escaped native workflow
annotations containing the owner, request URL, repository, and reason.
Warnings remain visible in job summaries, including already-routed requests.
Declared ownership remains intact: neither fallback marks an owned module
orphaned or grants permissions.

Completed reviews stay in history and do not create another pending request.
Unsubmitted pending reviews are not mistaken for completed reviews.
After an edit, routing reads labels and reviewers back before reporting
`Updated`; missing changes remain errors instead of false success.

## Checklist

- [x] Check merged routing changes and start a feature worktree from current main.
- [x] Read routing, ownership, warning, and access-helper conventions.
- [x] Add cached read-only eligibility checks and module-specific fallback.
- [x] Emit workflow annotations and retain warnings in summaries.
- [x] Verify routing writes and preserve missing-label warning behavior.
- [x] Cover both ecosystems, cache/error boundaries, and fallback idempotency.
- [x] Update related documentation and run the local pre-commit gate.
- [x] Prepare the validated slice for commit and publication.

## Validation

`.\build.ps1 pre-commit` passed layout, lint, 2,196 unit tests, and 939
component tests with zero failures. Nine unit tests were skipped. The
existing analyzer retry recovered its transient engine exception without
lint findings.

Focused routing tests passed before the full gate. Coverage includes user
and team eligibility, repository-scoped caching, genuine 404 responses versus
failed reads, malformed permissions, mixed owners, sole-owner authors,
already-reviewed co-owners, pending requests, duplicate fallback groups,
case-insensitive owner identity, both ecosystems, escaped workflow warnings,
and idempotent API round trips. Successful CLI edits with silently missing
reviewers or labels fail verification. `WhatIf` remains write-free.

Read-only control queries confirmed the user-permission and team-specific
permission response shapes. No app-token dry run or live routing write was
performed. All mutations in tests used mocked GitHub calls.

Changed files use LF and UTF-8 without BOM. `git diff --check` passed.

## Blockers or dependencies

No source blockers. The fallback must have existing repository write access;
an ineligible group or a failed permission lookup remains a request-level
error, without guessing, granting access, or stopping remaining requests.
Missing labels keep the existing warning-only deferral.

No permission grants, team changes, live reviewer writes, or workflow
dispatches were performed. Merging activates the new behavior through the
existing schedule. The team routing documentation should also describe
eligibility warnings, fallback rules, and post-write verification.
