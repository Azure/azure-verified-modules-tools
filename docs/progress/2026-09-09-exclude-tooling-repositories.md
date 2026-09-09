# Exclude tooling repositories from sync discovery

**Status**: complete
**Started**: 2026-09-09
**Updated**: 2026-09-09
**Branch**: `jaredfholgate-terraform-state-migration`

## Outcome

Exclude `policy-library-avm`, `mapotf`, and `azure-verified-modules-tools` before
module naming validation. These tooling repositories are installed on the AVM
GitHub App but are not module repositories and should not emit discovery errors.

## Checklist

- [x] Extend the existing built-in skip list.
- [x] Assert tooling exclusions produce no warning or issue artifact.
- [x] Retain naming validation for unexpected repositories and normal modules.
- [x] Complete the local gate for the existing feature branch.

## Validation

- `.\build.ps1 test-repository-management`: 79 passed.
- `.\build.ps1 pre-commit`: unit and component suites passed. Existing
  analyzer warnings remain; the negative discovery test intentionally reports
  an unexpected repository.
- Six tooling-name cases cover the three requested names and their uppercase
  equivalents. Each produces neither warnings nor an issue artifact and still
  discovers the normal module fixture. Unexpected names retain error diagnostics.

## Blockers or dependencies

No Azure or GitHub configuration changes; scheduled behavior changes only when
the reviewed workflow code is merged.
