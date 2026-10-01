# Terraform feature preflight logs

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-feature-preflight-logs`

## Outcome

The reusable Terraform workflow now names the step "Validate required features
offline". For a nonempty manifest it calls `Register-AvmFeature -WhatIf`
directly, preserving offline validation without the CLI rendering the
registration result as `skipped`. On success the log confirms the feature
count and selected subscription, says no Azure calls or registration occurred,
and points to the later login and registration steps. Absent and empty
manifests explicitly report that feature-specific login and registration are
skipped. No public cmdlet output or registration behavior changed.

## Checklist

- [x] Read repository guidance and check current main and open reviews.
- [x] Clarify the offline preflight log without changing registration contracts.
- [x] Cover validation, no-op, and no-Azure-call behavior in workflow tests.
- [x] Run the pre-commit gate, actionlint, and diff checks.
- [x] Prepare the validated change for a focused review.

## Validation

`./build.ps1 pre-commit` passed: layout, lint, 2,055 unit tests (9 existing
skips), and 938 component tests. The existing fixture tests produced 49
nonfatal warnings. `actionlint .github/workflows/terraform-module.yml` and
`git diff --check` passed. Component tests execute the workflow's preflight
script with a two-feature manifest and assert the success message, correct
job output, zero Azure CLI calls, and no `skipped` rendering. Missing and
empty manifests stay no-ops; a subscription mismatch or invalid later entry
blocks login. No live Azure calls were made.

## Blockers or dependencies

None. No Azure registration, protected-job run, release, or production
operation is part of this slice.
