# Require Bicep README checks in pr-check

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Completed**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Make the Bicep `docs` step of `avm pr-check` a required static result,
like policy and convention. A missing, unsupported, skipped, or invalid
result must not read as a passing gauntlet. A reported pass must account
for every selected source-backed README. Keep Terraform's existing
behavior and retain the convention-incomplete failure while the current
registry README comparison remains blocked.

## Checklist

- [x] Reject missing, unsupported, skipped, malformed, or incomplete
      Bicep documentation results with actionable diagnostics.
- [x] Test passing, failing, and missing-result Bicep cases and preserve
      Terraform's existing skip behavior.
- [x] Independently review the change, run `./build.ps1 pre-commit`,
      commit, push, and update the existing review.

## Validation

`./build.ps1 test` passed 1,993 unit tests (nine skipped). Mocked
results cover unsupported/skipped/missing/invalid or array status,
missing result fields, incomplete and negative render counts, reported
errors, and missing/null/unknown/array issue severities. A legitimate
source-less warning remains a pass; an unsupported Terraform docs step
remains skipped. Independent review found a mixed-case Bicep bypass and
malformed status/severity bypass; case-insensitive ecosystem checks
and strict result-shape validation closed both. Focused re-review
found no further significant issue.

The first full gate found 12 metadata component fixtures with a
status-only mocked docs result; their shared mock now returns a complete
Bicep docs result. The focused metadata component run passed 89 tests.
The final unfiltered `./build.ps1 pre-commit` passed layout, lint,
1,993 unit tests (nine skipped), and 1,045 component tests (one skipped),
with zero errors and 49 existing negative-path warnings.

## Blockers or dependencies

This result contract is independent of the current registry README
drift described in
[current-registry README parity](2026-10-01-bicep-readme-current-registry-parity.md).
It does not authorize crediting M:651 or switching registry CI.
