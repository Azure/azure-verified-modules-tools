# Telemetry branch reconciliation with Bicep and reviewer updates

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-mapotf-telemetry-alignment`

## Outcome

Bring the existing Terraform telemetry and candidate-validation branch onto
current `main` without undoing the newly published Bicep checks, metadata
requirements, or Terraform reviewer-routing fixes.

## Checklist

- [x] Review overlapping specification, public command, and test changes.
- [x] Merge current `main` without force and retain its intentional behavior.
- [x] Check the merged tree against `main` for unintended differences.
- [x] Align the local Bicep scaffold's telemetry description with its
      canonical prefix reader without changing the published alternate form.
- [x] Run the local pre-commit gate and relevant workflow checks.
- [x] Commit, push the existing branch, and verify the review is mergeable.

## Validation

The merged Bicep engine and workflow are byte-identical to `main`; overlapping
public command differences only forward the explicit module-version opt-out
and retain the Terraform telemetry transform. Focused checks passed for
credential-free Bicep test listing, nested version forwarding, and Git
environment restoration (2 unit and 2 component tests). The first full gate
passed 2,590 unit tests but exposed a mismatch between the local Bicep
scaffold's canonical telemetry reader and its alternate parameter
description. The corrected scaffold and both distinct telemetry forms pass
focused convention checks (2 tests), and root initialization passes (1 test).
`actionlint` passed for the existing Terraform and Bicep sync workflows;
the local linter does not recognize the unrelated new `code-quality` scope
in the unchanged CI workflow. The final `./build.ps1 pre-commit` gate passed
layout, lint, 2,590 unit tests (9 existing skips), and 1,287 component tests
(1 existing skip), with no failures.

## Blockers or dependencies

No source blocker remains for this reconciliation; normal review and CI
still apply. This slice did not perform live Azure operations, repository
publication, protected-job approval, or merge the review.
