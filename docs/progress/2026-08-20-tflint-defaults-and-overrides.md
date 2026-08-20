# Align TFLint defaults and overrides

**Status**: blocked
**Started**: 2026-08-20
**Updated**: 2026-08-20
**Branch**: `jaredfholgate-align-tflint-tooling`

## Outcome

Align the packaged AVM TFLint configurations with the ruleset's default-enabled
policy, preserve intentional scope-specific exemptions, complete the MAPOTF
replacement transforms, and add safe per-scope customer TFLint overrides.

## Checklist

- [x] Reconcile packaged TFLint configurations with the coordinated ruleset
      changes and remove default-enabled AVM rule declarations.
- [x] Add deterministic MAPOTF transforms for Terraform version and provider
      declaration ordering, with regression coverage.
- [x] Support all-scope and safe per-example/per-submodule TFLint overrides with
      documented precedence and regression coverage.
- [x] Update direct user documentation for TFLint defaults and overrides.
- [ ] Publish the branch and open a dependency-blocked pull request.
- [ ] After the attested v0.20.0 AVM ruleset release, update the pin and run
      real TFLint configuration validation.

## Validation

- `./build.ps1 test`: 986 passed, 8 skipped, 0 failed.
- `./build.ps1 pre-commit`: passed with 986 unit tests passed, 8 skipped, and
  all 28 component tests passed. PSScriptAnalyzer retried its known transient
  engine exception twice and reported only the existing warning baseline.
- The locally pinned MAPOTF 0.1.9 binary validated the complete packaged
  transform bundle against `tests/fixtures/modules/terraform-azure-avm-res-mock`,
  including the new deterministic `terraform` declaration plan.
- `git diff --check`: passed.

## Blockers or dependencies

- The ruleset must merge [Azure/tflint-ruleset-avm#155](https://github.com/Azure/tflint-ruleset-avm/pull/155)
  and publish an attested `v0.20.0` release before this repository can update
  its AVM plugin pin or run real TFLint validation. This branch deliberately
  retains the current 0.19.1 pin and is not independently releasable until
  that dependency is complete.
