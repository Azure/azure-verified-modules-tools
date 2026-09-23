# CI test and lint signal integrity

**Status**: complete
**Started**: 2026-09-23
**Updated**: 2026-09-23
**Branch**: `jaredfholgate-avm-authoring-upgrade-prompts`

## Outcome

Make the cross-platform CI gate pass without `GH_TOKEN`, prevent expected test
warnings and errors from becoming GitHub Actions annotations or step summaries,
require zero PSScriptAnalyzer warnings, and lint only once in the CI matrix.
Normal Avm.Authoring commands must
retain their GitHub annotations. Transient analyzer retry notices remain in the
job log as information rather than warning annotations.

## Checklist

- [x] Incorporate main's absent-token cleanup fix for the release-assets unit test.
- [x] Scope GitHub reporting away from tests while preserving explicit tests of
      normal annotation behavior.
- [x] Log transient analyzer retries as information.
- [x] Fix analyzer findings and fail lint on warnings as well as errors.
- [x] Run lint once on Ubuntu while retaining the three-OS test matrix and
      the full local CI gate.
- [x] Validate the tokenless test, output isolation, lint, and CI gate.
- [x] Commit and push the completed slice.

## Validation

- The `integrations/github` provider error in CI is simulated input in
  `RetryHelpers.Tests.ps1` and that test passes; the actual failing test
  attempted to remove an already absent `GH_TOKEN` during cleanup.
- The token cleanup fix from main (`4ada076`) is incorporated without a
  duplicate test-file change.
- Focused tokenless release-asset, Mapotf, WhatIf, test-output isolation, and
  CI workflow tests pass.
- `./build.ps1 lint` passes with zero warnings after a negative run failed on
  four remaining warnings.
- After merging `origin/main` at `18dd609`, the combined
  `./build.ps1 pre-commit,ci-tests,test-workflows` run passed with `GH_TOKEN`
  unset and simulated `GITHUB_ACTIONS=true`: 1768 unit tests, 908 component
  tests, 45 workflow tests, and 82.94% coverage against the 70% floor.
  Expected fixture warnings remained in the log; the simulated GitHub step
  summary was untouched.

## Dependencies

None.
