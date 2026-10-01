# Bicep API-version advisories

**Status**: complete
**Started**: 2026-09-30
**Updated**: 2026-09-30
**Completed**: 2026-09-30
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Cover pinned registry assertion M:2385 against all compiled root/child
resources, including resources nested in child arrays and nested
deployments. Use the registry's published API-specification list only
through its exact read-only HTTPS endpoint, with no live request during
development. Match its extension-resource remapping, preview/stable
version windows, outdated-version warning and oldest-approved warning.
An uninspectable source must fail with a named error, and missing entries
must produce actionable warnings rather than silently skipping checks.
Keep the unrelated README, folder-naming and telemetry parity families
fail-closed; do not change registry CI.

## Checklist

- [x] Implement the fixed-endpoint API-spec reader and nested compiled
      resource advisory rules with required versus advisory diagnostics.
- [x] Cover valid, outdated and near-expiry versions, special extension
      types, missing data, nested resources, offline and invalid responses.
- [x] Independently review, update the coverage ledger and run the
      unfiltered `./build.ps1 pre-commit`.
- [x] Commit and push this slice on the existing feature branch and
      update its review body.

## Validation

Focused `./build.ps1 test,component -TestName
'*Get-AvmBicepApiSpecList*','*Test-AvmBicepConventionApiVersion*',
'Bicep static convention checks*'`: 15 unit passed, 88 component passed,
one Windows-only component skipped. An independent code review found that
a 200 response containing `{"error":"upstream unavailable"}` could be
misreported as an unknown provider warning; the reader now rejects
error-shaped catalogues, with a regression test. The unfiltered
`./build.ps1 pre-commit` passed layout, clean lint, 1,974 unit tests (nine
skipped), and 1,018 component tests (one Windows-only skip); 49 warnings
come from existing negative-path tests. HTTP is mocked; no live API,
MCR, or Azure request was made during development.

## Blockers or dependencies

README byte-parity qualification, folder singularization and both authored
telemetry forms remain separate convention work. No live Azure/MCR calls,
registry CI switch, release or merge occur in this slice.
