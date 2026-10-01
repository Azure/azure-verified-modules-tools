# Bicep static convention CI mock isolation

**Status**: complete
**Started**: 2026-10-01
**Updated**: 2026-10-01
**Branch**: `jaredfholgate-bicep-static-check-parity`

## Outcome

Resolve the one child publishing allowlist component-test failure in the
Windows, Ubuntu, and macOS CI jobs without changing the convention rules or
weakening the required Bicep coverage gates. CI uses Pester 6.2.0; it no
longer falls through to the real command when a filtered mock does not match.
The local gate uses Pester 5.7.1, which allowed that test to pass without a
default mock. An unfiltered mock now forwards other calls to the original
`Get-ChildItem` cmdlet with Pester's original bound parameters; the two
deliberate unreadable-directory calls still throw.

## Checklist

- [x] Identify the named failure from all three uploaded CI test reports.
- [x] Correct the test's filesystem mock boundary and cover the behavior
      exercised by the CI runner.
- [x] Run focused component tests and unfiltered `./build.ps1 pre-commit`.
- [x] Check that convention implementation and coverage failures remain
      unchanged.

## Validation

The uploaded test reports for
[CI run 36801210665](https://github.com/Azure/azure-verified-modules-tools/actions/runs/36801210665)
all fail the same `Child publishing allowlist` component case: its
`Get-ChildItem` mock rejects a `-Filter '*.tf'` lookup under the module fixture.
The old test passed locally with Pester 5.7.1. Using `$PSBoundParameters` in
the passthrough would discard the original filter and misclassify the fixture
as both Terraform and Bicep; `$PesterBoundParameters` preserves the original
arguments. Focused component execution passed all 14 allowlist cases. The
unfiltered `./build.ps1 pre-commit` passed layout and lint, 1,993 unit tests
(nine skipped) and 1,045 component tests (one skipped), with zero errors and
49 existing negative-path warnings. `git diff --check` passed. The new
head's automatic CI run must still confirm Pester 6 compatibility; a local
Pester 5 pass is not a remote green result.

## Blockers or dependencies

None identified. The separate README parity blocker remains tracked in
`2026-10-01-bicep-readme-current-registry-parity.md`.
